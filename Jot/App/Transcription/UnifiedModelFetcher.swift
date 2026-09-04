import Foundation
import os.log

/// Background downloader for the Parakeet Unified 0.6B (English) streaming set.
///
/// ## Why this exists rather than FluidAudio's `DownloadUtils`
///
/// `DownloadUtils.downloadRepo` uses a FOREGROUND `URLSession`. iOS suspends
/// those the moment the app backgrounds or the screen locks, and this payload is
/// **581.8 MB across 19 files** — one of which (`weights/weight.bin`) is 563 MB
/// on its own. On a real device that reliably produced a truncated `.mlmodelc`,
/// which CoreML then rejected with *"Compile the model with Xcode or
/// `MLModel.compileModel(at:)`"*.
///
/// Worse, it was **unrecoverable**: a `.mlmodelc` is a directory, so
/// `FileManager.fileExists` — which is what FluidAudio checks before deciding to
/// re-download — returned true for the wreckage. Every retry skipped the fetch
/// and re-failed forever.
///
/// So this mirrors `ParakeetModelFetcher`, the pattern already proven in this
/// app for the 443 MB v2 model: a **background**, **discretionary**,
/// **Wi-Fi-only** session that survives suspension and is re-attached on
/// relaunch, per-file staging, size verification against a pinned manifest, and
/// an atomic install that only publishes a bundle once every byte is present.
///
/// Nobody is watching this run. Since build 297 it is started unprompted by
/// `UnifiedEnglishModel.syncWithRouting()` for English users, and English keeps
/// working on the bundled v2 engine the whole time it is in flight — so the
/// system is free to pick its moment.
///
/// ## Manifest
///
/// Sizes are the exact HuggingFace blob sizes, pinned so a truncated or
/// substituted file is caught before install rather than by CoreML at load.
@MainActor
final class UnifiedModelFetcher: NSObject, @unchecked Sendable {

    static let shared = UnifiedModelFetcher()

    /// `nonisolated` because the `URLSessionDownloadDelegate` callbacks below
    /// are nonisolated and must be able to log without hopping to the MainActor.
    nonisolated private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot", category: "unified-fetch"
    )

    /// Distinct from `ParakeetModelFetcher.sessionIdentifier` — two background
    /// sessions must never share an identifier or their delegate callbacks
    /// interleave onto the wrong fetcher.
    static let sessionIdentifier = "com.vineetu.jot.mobile.Jot.parakeet-unified-fetch"

    private static let repo = "FluidInference/parakeet-unified-en-0.6b-coreml"

    /// Every file of the streaming-int8 set, with its exact byte size.
    ///
    /// Enumerated explicitly rather than discovered at runtime: the download must
    /// know up front what "complete" means, otherwise a partial fetch is
    /// indistinguishable from a finished one — which is the exact bug this type
    /// exists to kill.
    static let manifest: [(path: String, size: Int64)] = [
        ("config.json", 1355),
        ("metadata.json", 1046),
        ("vocab.json", 15088),

        ("parakeet_unified_preprocessor.mlmodelc/analytics/coremldata.bin", 243),
        ("parakeet_unified_preprocessor.mlmodelc/coremldata.bin", 495),
        ("parakeet_unified_preprocessor.mlmodelc/model.mil", 29955),
        ("parakeet_unified_preprocessor.mlmodelc/weights/weight.bin", 592384),

        ("parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc/analytics/coremldata.bin", 243),
        ("parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc/coremldata.bin", 515),
        ("parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc/model.mil", 949_815),
        ("parakeet_unified_encoder_streaming_70_13_13_int8.mlmodelc/weights/weight.bin", 590_571_264),

        ("parakeet_unified_decoder.mlmodelc/analytics/coremldata.bin", 243),
        ("parakeet_unified_decoder.mlmodelc/coremldata.bin", 560),
        ("parakeet_unified_decoder.mlmodelc/model.mil", 13102),
        ("parakeet_unified_decoder.mlmodelc/weights/weight.bin", 14_429_952),

        ("parakeet_unified_joint_decision_single_step.mlmodelc/analytics/coremldata.bin", 243),
        ("parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin", 556),
        ("parakeet_unified_joint_decision_single_step.mlmodelc/model.mil", 9611),
        ("parakeet_unified_joint_decision_single_step.mlmodelc/weights/weight.bin", 3_446_978),
    ]

    static var totalBytes: Int64 { manifest.reduce(0) { $0 + $1.size } }

    /// Free space required before starting: the payload plus headroom for the
    /// staging copy during install (staging and install coexist briefly).
    static var requiredFreeBytes: Int64 { totalBytes * 2 + 200 * 1024 * 1024 }

    // MARK: - State published to the UI

    enum Phase: Equatable {
        case idle
        case downloading(completedBytes: Int64, totalBytes: Int64)
        case installing
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle {
        didSet { onPhaseChange?(phase) }
    }

    /// Set by `UnifiedEnglishModel` so it can mirror progress into its own state
    /// without this type importing the UI.
    var onPhaseChange: ((Phase) -> Void)?

    // MARK: - Session

    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1   // serialize delegate callbacks
        return q
    }()

    private var _session: URLSession?

    /// Instantiating this on relaunch is what re-attaches to the background
    /// daemon and redelivers callbacks for downloads that finished while the app
    /// was not running.
    private func makeOrGetSession() -> URLSession {
        if let _session { return _session }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // DISCRETIONARY, like `ParakeetModelFetcher` and the punctuation model.
        // It was `false` while a switch in Settings started this fetch and the
        // user sat watching a progress bar — a deferred task would have read as
        // "broken". Nobody asks for it any more (build 297 made this the default
        // English engine and `UnifiedEnglishModel.syncWithRouting()` starts the
        // fetch unprompted), so the opposite is now true: 582 MB should ride a
        // moment the system likes rather than compete with whatever the user is
        // actually doing. Nothing waits on it — English keeps using the bundled
        // v2 engine until this lands.
        config.isDiscretionary = true
        config.allowsCellularAccess = false     // never spend 582 MB of cellular
        config.sessionSendsLaunchEvents = true  // relaunch us to finish in background
        let s = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        _session = s
        return s
    }

    private override init() { super.init() }

    // MARK: - Paths

    private var installDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-unified-en-0.6b", isDirectory: true)
    }

    private var stagingDirectory: URL {
        installDirectory.deletingLastPathComponent()
            .appendingPathComponent(".parakeet-unified-staging", isDirectory: true)
    }

    // MARK: - Completeness

    /// Is the INSTALLED tree complete and correctly sized?
    ///
    /// Every file of the manifest must exist at its exact size. This is the check
    /// that replaces `fileExists` on the `.mlmodelc` directory — the flaw that let
    /// a truncated bundle report itself as installed.
    var isInstalled: Bool { treeIsComplete(at: installDirectory) }

    private func treeIsComplete(at root: URL) -> Bool {
        let fm = FileManager.default
        for entry in Self.manifest {
            let url = root.appendingPathComponent(entry.path)
            guard let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64,
                  size == entry.size
            else { return false }
        }
        return true
    }

    private func stagedBytes() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for entry in Self.manifest {
            let url = stagingDirectory.appendingPathComponent(entry.path)
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64,
               size == entry.size {
                total += size
            }
        }
        return total
    }

    private func stagedFileIsComplete(_ relativePath: String) -> Bool {
        guard let entry = Self.manifest.first(where: { $0.path == relativePath }) else { return false }
        let url = stagingDirectory.appendingPathComponent(relativePath)
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64 else { return false }
        return size == entry.size
    }

    var hasEnoughFreeDisk: Bool {
        let base = stagingDirectory.deletingLastPathComponent()
        guard let values = try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage
        else { return true }   // unreadable metric → don't block
        return free >= Self.requiredFreeBytes
    }

    // MARK: - Entry points

    /// Start (or resume) the fetch. Idempotent — already-staged files are
    /// skipped, so a resumed download does not re-pull the 563 MB weights.
    @discardableResult
    func start() -> Bool {
        if isInstalled {
            phase = .done
            return true
        }
        guard hasEnoughFreeDisk else {
            phase = .failed("Not enough free space — this needs about 1.2 GB while it installs.")
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory, withIntermediateDirectories: true
            )
        } catch {
            phase = .failed("Couldn't prepare storage for the download.")
            Self.log.error("staging dir create failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let session = makeOrGetSession()
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                let live = Set(tasks.compactMap { $0.taskDescription })
                self.enqueueMissing(excluding: live, into: session)
            }
        }
        phase = .downloading(completedBytes: stagedBytes(), totalBytes: Self.totalBytes)
        return true
    }

    /// Re-attach at launch so a download that completed (or is still running)
    /// while the app was closed gets installed rather than silently stranded.
    func resumeIfPending() {
        guard !isInstalled else { return }
        guard FileManager.default.fileExists(atPath: stagingDirectory.path) else { return }
        _ = makeOrGetSession()   // reconnect the delegate
        attemptInstallIfComplete()
    }

    /// Wipe staging AND any partially-installed tree. This is what makes a retry
    /// mean something after a truncated install.
    func reset() {
        try? FileManager.default.removeItem(at: stagingDirectory)
        if !isInstalled {
            try? FileManager.default.removeItem(at: installDirectory)
        }
        phase = .idle
    }

    private func enqueueMissing(excluding live: Set<String>, into session: URLSession) {
        var enqueued = 0
        for entry in Self.manifest {
            if live.contains(entry.path) { continue }
            if stagedFileIsComplete(entry.path) { continue }
            // A short/garbage partial must go before re-requesting, or the
            // size check would keep rejecting the same stale bytes.
            try? FileManager.default.removeItem(
                at: stagingDirectory.appendingPathComponent(entry.path)
            )
            guard let url = URL(string: "https://huggingface.co/\(Self.repo)/resolve/main/\(entry.path)")
            else { continue }
            let task = session.downloadTask(with: url)
            task.taskDescription = entry.path   // maps the finished file back to its slot
            task.resume()
            enqueued += 1
        }
        Self.log.info("unified fetch — enqueued \(enqueued, privacy: .public) of \(Self.manifest.count, privacy: .public) files")
        if enqueued == 0 { attemptInstallIfComplete() }
    }

    /// Handoff for `JotAppDelegate.handleEventsForBackgroundURLSession`.
    private var backgroundCompletionHandler: (() -> Void)?

    func handleBackgroundSessionEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        _ = makeOrGetSession()
    }

    // MARK: - Install

    /// Publish the staged tree only when EVERY manifest file is present at its
    /// exact size, and only via an atomic move — so a reader can never observe a
    /// half-built bundle. This is the invariant CoreML's loader depends on.
    private func attemptInstallIfComplete() {
        guard treeIsComplete(at: stagingDirectory) else {
            phase = .downloading(completedBytes: stagedBytes(), totalBytes: Self.totalBytes)
            return
        }
        phase = .installing

        let fm = FileManager.default
        let parent = installDirectory.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(
            "parakeet-unified-install-\(UUID().uuidString)", isDirectory: true
        )
        do {
            try fm.copyItem(at: stagingDirectory, to: temp)
        } catch {
            try? fm.removeItem(at: temp)
            phase = .failed("Couldn't finish installing the model.")
            Self.log.error("stage→temp copy failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Re-verify at temp: the copy itself can truncate on a full disk.
        guard treeIsComplete(at: temp) else {
            try? fm.removeItem(at: temp)
            phase = .failed("The copied model was incomplete — please try again.")
            return
        }
        do {
            if fm.fileExists(atPath: installDirectory.path) {
                try fm.removeItem(at: installDirectory)
            }
            try fm.moveItem(at: temp, to: installDirectory)
        } catch {
            try? fm.removeItem(at: temp)
            phase = .failed("Couldn't finish installing the model.")
            Self.log.error("atomic install failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard isInstalled else {
            try? fm.removeItem(at: installDirectory)
            phase = .failed("The installed model failed its check — please try again.")
            return
        }
        _ = BackupExclusion.setExcludedFromBackupRecursively(at: installDirectory)
        try? fm.removeItem(at: stagingDirectory)
        Self.log.info("unified fetch — installed \(Self.totalBytes / 1_048_576, privacy: .public) MB")
        phase = .done
    }
}

// MARK: - URLSessionDownloadDelegate

extension UnifiedModelFetcher: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let relativePath = downloadTask.taskDescription else { return }
        // HuggingFace answers 4xx/5xx with a BODY, which would otherwise be
        // written out as a plausible-looking file. Reject on status first.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            Self.log.error("unified fetch — HTTP \(http.statusCode, privacy: .public) for \(relativePath, privacy: .public)")
            return
        }
        // Must move synchronously here: the temp file is deleted the moment this
        // delegate call returns.
        let fm = FileManager.default
        let staging = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(".parakeet-unified-staging", isDirectory: true)
        let dest = staging.appendingPathComponent(relativePath)
        do {
            try fm.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
        } catch {
            Self.log.error("unified fetch — stage move failed for \(relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        Task { @MainActor in
            UnifiedModelFetcher.shared.attemptInstallIfComplete()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // Progress is derived from what is actually STAGED plus this task's
        // in-flight bytes, so it survives a relaunch instead of restarting at 0.
        Task { @MainActor in
            let fetcher = UnifiedModelFetcher.shared
            guard case .downloading = fetcher.phase else { return }
            let staged = fetcher.stagedBytes()
            fetcher.phase = .downloading(
                completedBytes: min(staged + totalBytesWritten, UnifiedModelFetcher.totalBytes),
                totalBytes: UnifiedModelFetcher.totalBytes
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let path = task.taskDescription ?? "?"
        Self.log.error("unified fetch — task failed \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            let fetcher = UnifiedModelFetcher.shared
            // A cancel is a deliberate teardown, not a failure to report.
            if (error as NSError).code == NSURLErrorCancelled { return }
            fetcher.phase = .failed(error.localizedDescription)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let fetcher = UnifiedModelFetcher.shared
            fetcher.attemptInstallIfComplete()
            fetcher.backgroundCompletionHandler?()
            fetcher.backgroundCompletionHandler = nil
        }
    }
}
