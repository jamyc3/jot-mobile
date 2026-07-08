#if JOT_APP_HOST
import CoreMLLLM
import Foundation
import OSLog

/// **Net-new overnight downloader for EmbeddingGemma-300M** (⚠️REVIEW H1/H2,
/// docs/plans/model-externalization-sub-50mb.md §A3).
///
/// Once the model is stripped from the IPA (Build B), a fresh install / iCloud
/// restore has no EmbeddingGemma on disk. This fetches it out-of-process on a
/// **background, discretionary, Wi-Fi-only** `URLSession` so it lands overnight
/// (charging + unmetered) with zero user friction and no cellular spend — the
/// non-negotiable "no silent cellular spend" invariant. The moment the user
/// actually wants Ask/search, the FOREGROUND promote (`AskController`) takes
/// over on any network; this class is purely the courtesy overnight path.
///
/// ## Why not reuse `Gemma3BundleDownloader.download`
///
/// That path uses a foreground `URLSessionConfiguration.default` — it dies when
/// the app suspends. Only the *manifest* (`Model.embeddingGemma300m.bundleFiles`)
/// and the repo constant are reusable. A background `URLSession` transfer runs
/// in the system daemon and survives app suspension by design, which is the
/// whole point of an overnight fetch.
///
/// ## Relaunch survival
///
/// Background download tasks persist across app launches. Each file is a
/// separate `downloadTask`; completed files are staged under
/// `CoreMLLLM/.embeddinggemma-staging/` (a per-file checklist that survives
/// relaunches — presence + size on disk IS the checklist, no separate flag).
/// `enqueueIfNeeded()` at every launch re-checks presence and enqueues only the
/// still-missing files — idempotent, and the recovery path for the force-quit
/// caveat (⚠️REVIEW H3: force-quit cancels discretionary tasks and
/// `handleEventsForBackgroundURLSession` won't fire afterward; the per-launch
/// re-enqueue restarts them with no stuck flag).
///
/// ## Verification (⚠️REVIEW H2)
///
/// A stripped build has no bundle to compare a signature against, so we verify
/// staged files against a **byte-size manifest pinned at build time** (the
/// mass-dominant files are byte-count-verified against the live HF repo; the
/// tiny JSON companions are presence + non-zero checked, with
/// `Gemma3BundleDownloader.localBundle` confirming the required-file set). A bad
/// download is discarded and re-fetched next launch, never half-installed.
final class EmbeddingModelFetcher: NSObject, @unchecked Sendable {

    static let shared = EmbeddingModelFetcher()

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "embedding-model-fetcher"
    )

    /// Background session identifier. iOS keys the out-of-process daemon and the
    /// relaunch handoff on this exact string — it must be stable across builds.
    static let sessionIdentifier = "com.vineetu.jot.mobile.Jot.embeddinggemma-fetch"

    private let model = Gemma3BundleDownloader.Model.embeddingGemma300m
    private let repo = Gemma3BundleDownloader.Model.embeddingGemma300m.defaultRepo

    /// Byte-size manifest pinned at build time. The four HF-verified files
    /// (weight.bin, encoder coremldata, model_config, tokenizer — parity
    /// confirmed live 2026-07-06, plan V1) are matched EXACTLY to catch a
    /// truncated transfer of the mass-dominant bytes; the remaining required
    /// companions are tiny JSON/MIL and only presence + non-zero checked (their
    /// HF-vs-bundle parity wasn't independently pinned, so an exact match could
    /// spuriously fail the whole overnight path). Optional files (metadata,
    /// analytics, special_tokens_map) may 404 and are not verified.
    private static let exactSizes: [String: Int64] = [
        "encoder.mlmodelc/weights/weight.bin": 308_616_576,
        "encoder.mlmodelc/coremldata.bin": 408,
        "model_config.json": 2_351,
        "hf_model/tokenizer.json": 33_385_008,
    ]

    /// State lock. Delegate callbacks arrive on `delegateQueue` (serial), but
    /// `enqueueIfNeeded` / the app-delegate handoff can touch shared state from
    /// other threads, so guard the completion handler + install guard.
    private let lock = NSLock()
    private var backgroundCompletionHandler: (() -> Void)?
    private var isInstalling = false

    /// Serial queue for delegate callbacks so file staging + the completeness
    /// check never race each other.
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "com.vineetu.jot.mobile.Jot.embeddinggemma-fetch.delegate"
        return q
    }()

    /// The one background session for the process. Created ONCE — constructing
    /// two background sessions with the same identifier in one process traps,
    /// and a plain `lazy var` is NOT thread-safe: the warm-chain enqueue (a
    /// background Task) and the app-delegate handoff (main thread) can first-
    /// touch it concurrently. `makeOrGetSession()` guards creation with `lock`.
    /// On relaunch, instantiating it reconnects to the daemon and redelivers
    /// pending completion callbacks.
    private var _session: URLSession?

    private func makeOrGetSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let _session { return _session }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = true             // system schedules for Wi-Fi + power
        config.allowsCellularAccess = false       // never spend cellular unprompted
        config.sessionSendsLaunchEvents = true    // relaunch us to finish in background
        let s = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        _session = s
        return s
    }

    private override init() { super.init() }

    // MARK: - Paths

    private var stagingDirectory: URL {
        EmbeddingGemmaService.applicationSupportBundleParent
            .appendingPathComponent(".embeddinggemma-staging", isDirectory: true)
    }

    private var installDirectory: URL {
        EmbeddingGemmaService.applicationSupportModelDirectory
    }

    /// Non-optional files that must be present + verified before install.
    private var requiredFiles: [String] {
        model.bundleFiles.filter { !model.optionalFiles.contains($0) }
    }

    // MARK: - Public entry points

    /// Enqueue the overnight fetch if the model is absent. Presence-checked and
    /// idempotent — safe to call every launch. Instantiates the background
    /// session (reconnecting to any in-flight daemon transfer) and enqueues only
    /// the files not already staged, skipping any that already have a live task.
    /// Placed at the serial warm-chain tail in `JotApp.init` (out-of-process, no
    /// ANE contention, order-free).
    func enqueueIfNeeded() {
        // Already installed (carry-forward, a prior fetch, or still-bundled
        // Build A) → nothing to do; tidy any leftover staging.
        if EmbeddingGemmaService.resolvedModelDirectory() != nil {
            cleanUpStaging()
            return
        }

        let session = makeOrGetSession() // reconnect to the daemon
        // Enumerate live tasks so we don't double-enqueue a file already in
        // flight from a previous launch (H3 recovery is only for CANCELLED
        // tasks, not still-running ones).
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let liveDescriptions = Set(tasks.compactMap { $0.taskDescription })
            self.enqueueMissing(excluding: liveDescriptions, into: session)
        }
    }

    private func enqueueMissing(excluding live: Set<String>, into session: URLSession) {
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            Self.log.error("staging dir create failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        var enqueued = 0
        for relativePath in model.bundleFiles {
            if live.contains(relativePath) { continue }              // already downloading
            if stagedFileIsAcceptable(relativePath) { continue }     // already done
            guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(relativePath)") else {
                continue
            }
            let task = session.downloadTask(with: url)
            task.taskDescription = relativePath   // maps the finished file back to its path
            task.resume()
            enqueued += 1
        }
        if enqueued > 0 {
            Self.log.info("enqueued \(enqueued, privacy: .public) EmbeddingGemma file task(s) (discretionary, Wi-Fi-only)")
        } else {
            // Nothing left to enqueue and nothing installed → the staged set may
            // now be complete (last file just landed on a prior launch). Try.
            attemptInstallIfComplete()
        }
    }

    /// Cancel the overnight session's tasks — called by the foreground promote
    /// when the user wants the model NOW (the promote runs its own
    /// any-network foreground download instead).
    func cancelDiscretionaryFetch() {
        makeOrGetSession().getAllTasks { tasks in
            for task in tasks { task.cancel() }
        }
    }

    /// Stash the system's completion handler for a background-session relaunch
    /// (⚠️REVIEW H1). Invoked from the app-delegate adaptor's
    /// `handleEventsForBackgroundURLSession`. Touching `session` here reconnects
    /// the delegate so the pending `didFinishDownloadingTo` / completion
    /// callbacks are delivered.
    func handleBackgroundSessionEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            // Not ours — call it back immediately so we don't strand the system.
            completionHandler()
            return
        }
        lock.lock()
        backgroundCompletionHandler = completionHandler
        lock.unlock()
        // Reconnect the delegate (outside the lock — makeOrGetSession takes it
        // itself; NSLock isn't recursive) to receive redelivered events.
        _ = makeOrGetSession()
    }

    // MARK: - Staging / verification

    /// A staged file is acceptable if it exists and — for a byte-pinned file —
    /// matches its exact size; unpinned required + optional files just need to
    /// exist non-empty. (Optional files that legitimately 404 never get staged;
    /// they're excluded from the required-set check below.)
    private func stagedFileIsAcceptable(_ relativePath: String) -> Bool {
        let url = stagingDirectory.appendingPathComponent(relativePath)
        guard let size = fileSize(url), size > 0 else { return false }
        if let pinned = Self.exactSizes[relativePath] {
            return size == pinned
        }
        return true
    }

    private func requiredSetComplete() -> Bool {
        requiredFiles.allSatisfy { stagedFileIsAcceptable($0) }
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    // MARK: - Install

    /// If every required file is staged + verified, atomically install the
    /// staging tree into the model's private home, backup-exclude it, clean up,
    /// and fire the arrival hooks. Guarded so two near-simultaneous file
    /// completions can't both install.
    private func attemptInstallIfComplete() {
        guard requiredSetComplete() else { return }

        lock.lock()
        if isInstalling { lock.unlock(); return }
        isInstalling = true
        lock.unlock()
        defer {
            lock.lock(); isInstalling = false; lock.unlock()
        }

        // Nothing to do if a parallel path (carry-forward, promote) already
        // installed the model while we were downloading.
        if EmbeddingGemmaService.resolvedModelDirectory() != nil {
            cleanUpStaging()
            return
        }

        let fm = FileManager.default
        let dest = installDirectory
        let parent = dest.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            Self.log.error("install parent create failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Atomic install: rename a verified temp copy of the staging tree into
        // place (temp-sibling + rename, same posture as ModelCarryForward). We
        // COPY staging→temp rather than move staging directly so a failure
        // leaves the staged files intact for a retry.
        let temp = parent.appendingPathComponent(
            "\(dest.lastPathComponent).fetch-tmp-\(UUID().uuidString)", isDirectory: true
        )
        do {
            try fm.copyItem(at: stagingDirectory, to: temp)
        } catch {
            Self.log.error("stage→temp copy failed: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: temp)
            return
        }

        // Confirm the required-file set resolves at the temp location before we
        // swap it in (belt-and-suspenders over the staged-size checks). `temp`
        // IS the bundle root (its contents are `encoder.mlmodelc/…` directly),
        // so check the required files relative to it — not via
        // `localBundle(_:under:)`, which expects the PARENT of a `<model>/` dir.
        guard localBundleResolves(atBundleRoot: temp) else {
            Self.log.error("temp bundle failed required-file resolution; discarding")
            try? fm.removeItem(at: temp)
            return
        }

        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: temp, to: dest)
        } catch {
            Self.log.error("atomic install failed: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: temp)
            return
        }

        // Install-time backup exclusion (⚠️REVIEW-2): the CoreMLLLM tree is a
        // brand-new writable ~330 MB dir the package flags nothing on. Exclude
        // it the moment it lands, not only after the next per-launch sweep.
        let excluded = BackupExclusion.setExcludedFromBackupRecursively(at: dest)
        cleanUpStaging()

        DiagnosticsLog.record(
            source: "main-app",
            category: .modelLoad,
            message: "EmbeddingGemma overnight fetch installed",
            metadata: ["excluded": "\(excluded)", "kind": "overnight-fetch"]
        )
        Self.log.info("EmbeddingGemma installed at \(dest.path, privacy: .public) (excluded=\(excluded, privacy: .public))")

        // Arrival hooks: prewarm (behind the serial warm chain) + backfill kick.
        EmbeddingModelArrival.handleModelInstalled(reason: "overnight-fetch")
    }

    /// `localBundle(_:under:)` expects the PARENT of the `<model>/` folder; here
    /// the temp dir IS the bundle root (its contents are the model files
    /// directly, since staging holds `encoder.mlmodelc/...` etc). Resolve the
    /// required-file set relative to `bundleRoot` directly.
    private func localBundleResolves(atBundleRoot bundleRoot: URL) -> Bool {
        for rel in requiredFiles {
            if !FileManager.default.fileExists(atPath: bundleRoot.appendingPathComponent(rel).path) {
                return false
            }
        }
        return true
    }

    private func cleanUpStaging() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    private func callBackgroundCompletionHandler() {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        guard let handler else { return }
        // UIKit requires the stored completion handler be called on the main
        // thread once all events for the session have been delivered. The
        // handler is a plain non-Sendable `() -> Void`; it is only ever invoked
        // here, once, so hop it to main without tripping Sendable checking.
        nonisolated(unsafe) let h = handler
        DispatchQueue.main.async { h() }
    }
}

// MARK: - URLSessionDownloadDelegate

extension EmbeddingModelFetcher: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let relativePath = downloadTask.taskDescription else { return }

        // A 4xx/5xx still "finishes downloading" (the body is the error page);
        // guard on the HTTP status so we don't stage an error page as a model
        // file. A 404 on an OPTIONAL file is expected and simply skipped.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            if http.statusCode == 404 && model.optionalFiles.contains(relativePath) {
                Self.log.debug("optional file 404 (skipped): \(relativePath, privacy: .public)")
            } else {
                Self.log.error("file \(relativePath, privacy: .public) HTTP \(http.statusCode, privacy: .public); leaving unstaged for retry")
            }
            return
        }

        // The tmp file at `location` is deleted the instant this returns, so
        // move it into staging synchronously here.
        let dest = stagingDirectory.appendingPathComponent(relativePath)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
        } catch {
            Self.log.error("stage move failed \(relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        // Reject (and re-fetch next launch) a byte-pinned file that came back
        // the wrong size — a corrupt/partial CDN response.
        if !stagedFileIsAcceptable(relativePath) {
            Self.log.error("staged file \(relativePath, privacy: .public) failed size check; discarding")
            try? fm.removeItem(at: dest)
            return
        }

        attemptInstallIfComplete()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        let path = task.taskDescription ?? "?"
        // Cancellations (foreground promote, force-quit) are expected — not an
        // error worth surfacing; the per-launch re-enqueue is the recovery.
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled {
            Self.log.debug("task cancelled \(path, privacy: .public)")
            return
        }
        Self.log.notice("task failed \(path, privacy: .public): \(error.localizedDescription, privacy: .public) (retries next launch)")
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // All queued background events for this session have been delivered —
        // try a final install pass (in case the last file just landed), then
        // release the system by calling the stored completion handler.
        attemptInstallIfComplete()
        callBackgroundCompletionHandler()
    }
}
#endif
