#if JOT_APP_HOST
import FluidAudio
import Foundation
import OSLog

/// **Background, charging-gated downloader for the Parakeet 600M English v2
/// weights** — the "download-on-charge + auto-enable" path behind the keyboard's
/// Parakeet-upgrade nudge (docs/plans/parakeet-upgrade-nudge-download.md).
///
/// On a stripped build (`TranscriptionService.bundled600mDirectory() == nil`)
/// where the user has never opted into Jot's engine, the model isn't on disk.
/// Tapping **Use Jot's engine** on the nudge used to either dead-tap (the opener
/// bug, now fixed) or fall through to the first-dictation download backstop. This
/// class is the designed alternative the owner asked for: enqueue the fetch on a
/// **discretionary, Wi-Fi + charging** background `URLSession` so it lands
/// overnight with no cellular spend, then auto-switch the engine at a safe
/// boundary (`ParakeetModelArrival`).
///
/// It is the exact shape of `EmbeddingModelFetcher` — same discretionary session,
/// per-file staging across relaunches, pinned byte-size verify, atomic install,
/// app-delegate relaunch handoff — differing only in the model (Parakeet v2, a
/// tree of `.mlmodelc` bundles) and the trigger: this fetch is **user-initiated**
/// (the nudge tap), not an unprompted overnight courtesy, so it runs only while
/// `AppGroup.parakeetDownloadPending` is set and resumes off that flag at launch.
///
/// ## Install target
///
/// Files stage under `FluidAudio/Models/.parakeet-v2-staging/` and install into
/// `MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetV2)` — the
/// SAME directory `V2CarryForwardMigration` / `ModelCarryForward` copy into and
/// the loader/`AsrModels.modelsExist` read from. One Parakeet install dir, not
/// two. It lives under `FluidAudio/`, so the per-launch
/// `BackupExclusion.excludeFluidAudioModels()` sweep already covers it; we also
/// exclude at install time so the weights never enter an iCloud backup even for
/// one launch.
///
/// ## Verification
///
/// A stripped build has no bundle to compare a signature against, so we verify
/// each staged file against a **manifest pinned at build time** — the
/// mass-dominant `weight.bin` files are matched to exact HF byte counts (parity
/// confirmed live 2026-07-14 against `FluidInference/parakeet-tdt-0.6b-v2-coreml`),
/// the small companions are presence + non-zero checked — then require the full
/// `.mlmodelc` tree to resolve before an atomic install. A bad download is
/// discarded and re-fetched next launch, never half-installed.
final class ParakeetModelFetcher: NSObject, @unchecked Sendable {

    static let shared = ParakeetModelFetcher()

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "parakeet-model-fetcher"
    )

    /// Background session identifier. iOS keys the out-of-process daemon and the
    /// relaunch handoff on this exact string — it must be stable across builds
    /// and distinct from the EmbeddingGemma fetcher's identifier.
    static let sessionIdentifier = "com.vineetu.jot.mobile.Jot.parakeet-v2-fetch"

    /// HuggingFace repo hosting the v2 CoreML weights (same repo the shipped
    /// `AsrModels.download` backstop and the v3/v2 European download use).
    private static let repo = "FluidInference/parakeet-tdt-0.6b-v2-coreml"

    /// The v2 file manifest — the exact subset the loader needs, enumerated from
    /// the bundled `parakeet-tdt-0.6b-v2` tree and confirmed present at identical
    /// sizes on HF. The four `.mlmodelc` bundles (`Encoder`/`Decoder`/
    /// `JointDecision`/`Preprocessor`) plus `parakeet_vocab.json` are what
    /// `AsrModels.modelsExist(at:version:.v2)` and the CoreML loader require.
    private static let requiredRelativePaths: [String] = [
        "Encoder.mlmodelc/weights/weight.bin",
        "Encoder.mlmodelc/model.mil",
        "Encoder.mlmodelc/metadata.json",
        "Encoder.mlmodelc/coremldata.bin",
        "Encoder.mlmodelc/analytics/coremldata.bin",
        "Decoder.mlmodelc/weights/weight.bin",
        "Decoder.mlmodelc/model.mil",
        "Decoder.mlmodelc/metadata.json",
        "Decoder.mlmodelc/coremldata.bin",
        "Decoder.mlmodelc/analytics/coremldata.bin",
        "JointDecision.mlmodelc/weights/weight.bin",
        "JointDecision.mlmodelc/model.mil",
        "JointDecision.mlmodelc/metadata.json",
        "JointDecision.mlmodelc/coremldata.bin",
        "JointDecision.mlmodelc/analytics/coremldata.bin",
        "Preprocessor.mlmodelc/weights/weight.bin",
        "Preprocessor.mlmodelc/model.mil",
        "Preprocessor.mlmodelc/metadata.json",
        "Preprocessor.mlmodelc/coremldata.bin",
        "Preprocessor.mlmodelc/analytics/coremldata.bin",
        "parakeet_vocab.json",
    ]

    /// Tiny companion that ships in the repo but isn't read by the loader —
    /// downloaded opportunistically, never required for install-complete (a 3-byte
    /// file shouldn't be able to block the whole switch on a transient failure).
    private static let optionalRelativePaths: [String] = ["config.json"]

    /// Byte-size manifest pinned at build time. The mass-dominant weight files are
    /// matched EXACTLY to catch a truncated transfer; the rest are presence +
    /// non-zero checked (their exact bytes aren't independently pinned, so an
    /// exact match could spuriously fail on a benign re-export).
    private static let exactSizes: [String: Int64] = [
        "Encoder.mlmodelc/weights/weight.bin": 445_187_200,
        "Decoder.mlmodelc/weights/weight.bin": 14_429_952,
        "JointDecision.mlmodelc/weights/weight.bin": 3_453_388,
        "Preprocessor.mlmodelc/weights/weight.bin": 298_880,
    ]

    /// Free-disk headroom required before enqueuing. Peak transient footprint is
    /// the staged tree (~464 MB) plus its verified temp copy (~464 MB) during the
    /// atomic install, before the staging cleanup — round up to ~1.1 GB so a
    /// low-disk device parks cleanly instead of half-installing (owner: "~1 GB").
    static let requiredFreeBytes: Int64 = 1_100 * 1024 * 1024

    /// Free-disk headroom re-checked at INSTALL time (staging is already on disk;
    /// only the verified temp copy — ~464 MB — still has to fit). Re-checking here
    /// stops a device that filled up mid-download from wedging on "Downloading…".
    static let installHeadroomBytes: Int64 = 550 * 1024 * 1024

    /// Ceiling on install-time verify/rollback failures before the download is
    /// promoted to a terminal, user-retriable failure (rather than looping).
    private static let maxInstallFailures = 3

    /// State lock guarding the completion handler + install guard (delegate
    /// callbacks are serial on `delegateQueue`, but `requestBackgroundDownload` /
    /// `resumeIfPending` / the app-delegate handoff touch shared state off it).
    private let lock = NSLock()
    private var backgroundCompletionHandler: (() -> Void)?
    private var isInstalling = false

    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "com.vineetu.jot.mobile.Jot.parakeet-v2-fetch.delegate"
        return q
    }()

    /// The one background session for the process. Created ONCE — two background
    /// sessions with the same identifier trap, and a plain `lazy var` isn't
    /// thread-safe. On relaunch, instantiating it reconnects to the daemon and
    /// redelivers pending completion callbacks.
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

    private var installDirectory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetV2)
    }

    private var stagingDirectory: URL {
        installDirectory.deletingLastPathComponent()
            .appendingPathComponent(".parakeet-v2-staging", isDirectory: true)
    }

    // MARK: - Eligibility (read by UpgradeEngineView)

    /// Whether this device has enough free disk to fetch + install the model.
    var hasEnoughFreeDisk: Bool {
        guard let free = availableImportantCapacity(at: stagingDirectory.deletingLastPathComponent()) else {
            return true   // unreadable metric → don't block on it (proceed)
        }
        return free >= Self.requiredFreeBytes
    }

    // MARK: - Public entry points

    /// Kick off the background fetch in response to the nudge's "Use Jot's engine"
    /// tap. Assumes the caller already confirmed eligibility (`parakeetUsable` +
    /// `hasEnoughFreeDisk` + model-not-on-disk); this is the mechanism only.
    /// Returns `false` synchronously if we can't even create the staging dir, so
    /// the UI never shows a fake "downloading" state (does the staging-dir create
    /// up front as the fail-fast check). Otherwise enqueues the still-missing files
    /// and persists `parakeetDownloadPending` — but ONLY when files were actually
    /// enqueued (`enqueued > 0`); if the staged set was already complete the inline
    /// install has already run and cleared the flag, so re-setting it would wedge.
    @discardableResult
    func requestBackgroundDownload() -> Bool {
        // Fail-fast filesystem check (Fix 7): report inability to stage
        // synchronously rather than optimistically flipping the UI to
        // "downloading". `enqueueMissing` re-creates the dir idempotently.
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            Self.log.error("staging dir create failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        // Fresh attempt: clear any prior terminal-failure + failure counter.
        AppGroup.parakeetDownloadFailed = false
        AppGroup.parakeetDownloadInstallFailures = 0

        let session = makeOrGetSession()
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let live = Set(tasks.compactMap { $0.taskDescription })
            let enqueued = self.enqueueMissing(excluding: live, into: session)
            // Fix 5: only mark pending when files were actually enqueued. If
            // `enqueued == 0` the staged set was already complete and
            // `enqueueMissing` ran `attemptInstallIfComplete` (which installs +
            // clears pending / fires arrival) — re-setting pending here would
            // re-wedge the UI on "Downloading…".
            if enqueued > 0 {
                AppGroup.parakeetDownloadPending = true
            }
        }
        return true
    }

    /// User-recoverable exit from the "Downloading…" state ("Stop download" /
    /// keep Apple): cancel the discretionary tasks, clear the pending flag, and
    /// drop the partially-staged files so a later retry starts clean.
    func stopDownload() {
        cancelDiscretionaryFetch()
        cleanUpStaging()
        AppGroup.parakeetDownloadPending = false
        AppGroup.parakeetDownloadInstallFailures = 0
    }

    /// Cancel the discretionary session's in-flight tasks (mirrors
    /// `EmbeddingModelFetcher.cancelDiscretionaryFetch`). Called by `stopDownload`
    /// and on a terminal failure; the cancellations are expected and not surfaced.
    func cancelDiscretionaryFetch() {
        makeOrGetSession().getAllTasks { tasks in
            for task in tasks { task.cancel() }
        }
    }

    /// Resume an in-flight fetch at launch. No-op unless `parakeetDownloadPending`
    /// is set (this fetch is user-initiated — nothing runs unprompted). Presence-
    /// checked + idempotent, so it also recovers a force-quit-cancelled session
    /// (⚠️H3: force-quit cancels discretionary tasks and the relaunch handoff
    /// won't fire; the per-launch re-enqueue restarts them with no stuck flag).
    func resumeIfPending() {
        guard AppGroup.parakeetDownloadPending else { return }

        // Already installed (or the bundle is present) while the flag lingered —
        // e.g. a crash between install and clear. Finish the handoff cleanly.
        if TranscriptionService.parakeetV2ReadyOnDevice() {
            cleanUpStaging()
            AppGroup.parakeetDownloadPending = false
            ParakeetModelArrival.handleModelInstalled(reason: "resume-already-present")
            return
        }

        let session = makeOrGetSession() // reconnect to the daemon
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let live = Set(tasks.compactMap { $0.taskDescription })
            _ = self.enqueueMissing(excluding: live, into: session)
        }
    }

    @discardableResult
    private func enqueueMissing(excluding live: Set<String>, into session: URLSession) -> Int {
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            Self.log.error("staging dir create failed: \(error.localizedDescription, privacy: .public)")
            return -1
        }

        var enqueued = 0
        for relativePath in Self.requiredRelativePaths + Self.optionalRelativePaths {
            if live.contains(relativePath) { continue }           // already downloading
            if stagedFileIsAcceptable(relativePath) { continue }  // already done
            guard let url = URL(string: "https://huggingface.co/\(Self.repo)/resolve/main/\(relativePath)") else {
                continue
            }
            let task = session.downloadTask(with: url)
            task.taskDescription = relativePath   // maps the finished file back to its path
            task.resume()
            enqueued += 1
        }
        if enqueued > 0 {
            Self.log.info("enqueued \(enqueued, privacy: .public) Parakeet v2 file task(s) (discretionary, Wi-Fi-only)")
        } else {
            // Nothing left to enqueue → the staged set may now be complete (last
            // file landed on a prior launch). Try the install.
            attemptInstallIfComplete()
        }
        return enqueued
    }

    /// Stash the system's completion handler for a background-session relaunch,
    /// invoked from `JotAppDelegate.handleEventsForBackgroundURLSession`. Touching
    /// `session` reconnects the delegate so pending callbacks are delivered.
    func handleBackgroundSessionEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundCompletionHandler = completionHandler
        lock.unlock()
        _ = makeOrGetSession()
    }

    // MARK: - Staging / verification

    private func stagedFileIsAcceptable(_ relativePath: String) -> Bool {
        let url = stagingDirectory.appendingPathComponent(relativePath)
        guard let size = fileSize(url), size > 0 else { return false }
        if let pinned = Self.exactSizes[relativePath] {
            return size == pinned
        }
        return true
    }

    private func requiredSetComplete() -> Bool {
        Self.requiredRelativePaths.allSatisfy { stagedFileIsAcceptable($0) }
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    // MARK: - Install

    /// If every required file is staged + verified, atomically install the staging
    /// tree into the Parakeet v2 home, backup-exclude it, clean up, clear the
    /// pending flag, and fire the arrival hooks. Guarded so two near-simultaneous
    /// file completions can't both install.
    private func attemptInstallIfComplete() {
        guard requiredSetComplete() else { return }

        lock.lock()
        if isInstalling { lock.unlock(); return }
        isInstalling = true
        lock.unlock()
        defer { lock.lock(); isInstalling = false; lock.unlock() }

        // A parallel path (carry-forward, first-dictation backstop) may have
        // installed the model while we were downloading.
        if TranscriptionService.parakeetV2ReadyOnDevice() {
            cleanUpStaging()
            AppGroup.parakeetDownloadPending = false
            ParakeetModelArrival.handleModelInstalled(reason: "parallel-install")
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

        // Install-time free-disk re-check (Fix 2): staging is already on disk, but
        // the verified temp copy still needs ~464 MB. If the device filled up
        // mid-download, clear pending + drop staging so the UI surfaces the
        // retriable lowDisk state instead of wedging on "Downloading…".
        if let free = availableImportantCapacity(at: parent), free < Self.installHeadroomBytes {
            Self.log.notice(
                "install aborted — low disk (\(free, privacy: .public) < \(Self.installHeadroomBytes, privacy: .public)); pending cleared, retriable"
            )
            cancelDiscretionaryFetch()
            cleanUpStaging()
            AppGroup.parakeetDownloadPending = false
            CrossProcessNotification.post(name: CrossProcessNotification.parakeetEngineActivated)
            return
        }

        // Atomic install: COPY the staged tree to a verified temp sibling, then
        // rename it into place. We copy (rather than move staging directly) so a
        // failure leaves the staged files intact for a retry, mirroring
        // ModelCarryForward / EmbeddingModelFetcher.
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

        // Confirm the full `.mlmodelc` tree resolves at temp BEFORE the swap.
        // `AsrModels.modelsExist` can't be used against `temp` directly — it
        // resolves `repoPath = temp.deletingLastPathComponent()/folderName`, i.e.
        // it looks at the real install leaf, not `temp` (the build-142 "one dir
        // over" trap). So check the required relative paths against `temp`
        // directly here; assert `modelsExist` only after the leaf is in place.
        guard requiredFilesResolve(atBundleRoot: temp) else {
            try? fm.removeItem(at: temp)
            recordInstallFailure("temp tree failed required-file resolution")
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

        // Final sanity: `modelsExist` at the real leaf (its last component IS
        // `parakeet-tdt-0.6b-v2`, so `repoPath` points back at it). Roll back and
        // retry next launch if it somehow fails — never leave a bad leaf that the
        // loader would try to use.
        guard AsrModels.modelsExist(at: dest, version: .v2) else {
            try? fm.removeItem(at: dest)
            recordInstallFailure("post-install modelsExist=false")
            return
        }

        let excluded = BackupExclusion.setExcludedFromBackupRecursively(at: dest)
        cleanUpStaging()
        AppGroup.parakeetDownloadPending = false
        AppGroup.parakeetDownloadInstallFailures = 0
        AppGroup.parakeetDownloadFailed = false

        DiagnosticsLog.record(
            source: "main-app",
            category: .modelLoad,
            message: "Parakeet v2 background fetch installed",
            metadata: ["excluded": "\(excluded)", "kind": "nudge-download"]
        )
        Self.log.info("Parakeet v2 installed at \(dest.path, privacy: .public) (excluded=\(excluded, privacy: .public))")

        // Arrival: flip the engine at a safe boundary + confirmation + prewarm.
        ParakeetModelArrival.handleModelInstalled(reason: "nudge-download")
    }

    private func requiredFilesResolve(atBundleRoot bundleRoot: URL) -> Bool {
        for rel in Self.requiredRelativePaths {
            let url = bundleRoot.appendingPathComponent(rel)
            guard let size = fileSize(url), size > 0 else { return false }
        }
        return true
    }

    private func cleanUpStaging() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    /// Count an install-time verify/rollback failure; on hitting the ceiling,
    /// promote to a terminal, user-retriable failure so a persistently corrupt
    /// download can't retry-loop forever (Fix 1).
    private func recordInstallFailure(_ why: String) {
        let n = AppGroup.parakeetDownloadInstallFailures + 1
        AppGroup.parakeetDownloadInstallFailures = n
        Self.log.error("install failure #\(n, privacy: .public): \(why, privacy: .public)")
        if n >= Self.maxInstallFailures {
            markTerminalFailure("repeated install/verify failure (\(why))")
        }
    }

    /// Promote the download to a terminal, user-retriable failure: cancel the
    /// fetch, drop staged files, clear pending, raise the `failed` flag, and ping
    /// any open sheet so it re-resolves to its "failed" state.
    private func markTerminalFailure(_ why: String) {
        Self.log.error("Parakeet v2 download terminal failure: \(why, privacy: .public)")
        cancelDiscretionaryFetch()
        cleanUpStaging()
        AppGroup.parakeetDownloadInstallFailures = 0
        AppGroup.parakeetDownloadPending = false
        AppGroup.parakeetDownloadFailed = true
        // `parakeetEngineActivated` doubles as an "upgrade state changed" ping: an
        // open UpgradeEngineView re-resolves (→ failed), and HomeScreen's observer
        // just re-reads the still-false switched-notice (no popup — harmless).
        CrossProcessNotification.post(name: CrossProcessNotification.parakeetEngineActivated)
        DiagnosticsLog.record(
            source: "main-app",
            category: .modelLoad,
            message: "Parakeet v2 download failed",
            metadata: ["why": why, "kind": "nudge-download"]
        )
    }

    private func availableImportantCapacity(at url: URL) -> Int64? {
        var probe = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent == probe { break }
            probe = parent
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func callBackgroundCompletionHandler() {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        guard let handler else { return }
        // UIKit requires the stored completion handler run on the main thread once
        // all session events are delivered. It's a plain non-Sendable closure,
        // invoked here exactly once, so hop to main without tripping Sendable.
        nonisolated(unsafe) let h = handler
        DispatchQueue.main.async { h() }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ParakeetModelFetcher: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let relativePath = downloadTask.taskDescription else { return }

        // A 4xx/5xx still "finishes downloading" (the body is the error page); guard
        // on the HTTP status so we never stage an error page as a model file. A 404
        // on an OPTIONAL file is expected and simply skipped.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            if http.statusCode == 404 && Self.optionalRelativePaths.contains(relativePath) {
                Self.log.debug("optional file 404 (skipped): \(relativePath, privacy: .public)")
            } else if http.statusCode == 404 {
                // A 404 on a REQUIRED file means the repo/path is gone — no amount
                // of retrying fixes it. Promote to a terminal, user-retriable
                // failure rather than looping forever (Fix 1).
                markTerminalFailure("required file 404 (repo/path gone): \(relativePath)")
            } else {
                // Transient 5xx / rate-limit — leave unstaged; a later launch
                // re-enqueues. (Bounded elsewhere by the install-failure ceiling.)
                Self.log.error("file \(relativePath, privacy: .public) HTTP \(http.statusCode, privacy: .public); leaving unstaged for retry")
            }
            return
        }

        // The tmp file at `location` is deleted the instant this returns; move it
        // into staging synchronously here.
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

        // Reject (and re-fetch next launch) a byte-pinned file that came back the
        // wrong size — a corrupt/partial CDN response.
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
        // Cancellations (force-quit) are expected — the per-launch re-enqueue is
        // the recovery; don't surface them.
        if (error as NSError).code == NSURLErrorCancelled {
            Self.log.debug("task cancelled \(path, privacy: .public)")
            return
        }
        Self.log.notice("task failed \(path, privacy: .public): \(error.localizedDescription, privacy: .public) (retries next launch)")
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // All queued background events delivered — try a final install pass (in
        // case the last file just landed), then release the system.
        attemptInstallIfComplete()
        callBackgroundCompletionHandler()
    }
}
#endif
