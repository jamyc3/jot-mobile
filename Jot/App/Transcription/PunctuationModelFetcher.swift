import Foundation
import os.log

/// Background downloader for the punctuation / true-casing / segmentation model
/// (`punct_cap_seg_en`, CoreML INT8, ~57 MB).
///
/// ## Why this is downloaded rather than bundled
///
/// Owner call (2026-08-30): "because it is mobile, I would not want it to be
/// bundled in, it needs to be auto-downloaded when the app is there, like the
/// rest of them". Bundling would push the stripped IPA from ~44 MB to ~105 MB
/// for a feature most users never explicitly ask for.
///
/// ## Why it mirrors `UnifiedModelFetcher` rather than reusing it
///
/// Two background `URLSession`s must never share an identifier or their delegate
/// callbacks interleave onto the wrong fetcher, and each fetcher owns its own
/// manifest/staging/install triple. The shape is deliberately identical so the
/// same invariants (exact-size verification, atomic install) hold — see that
/// file's header for why `fileExists` on a `.mlmodelc` is not a completeness
/// check.
///
/// ## Differences from `UnifiedModelFetcher`
///
/// - **Discretionary.** Nobody is watching a progress bar; this should ride a
///   good moment on Wi-Fi like `ParakeetModelFetcher`, not compete with the
///   foreground.
/// - **Pinned to a revision SHA, not `main`.** The source is a small third-party
///   repo, so `main` could change under us. A revision URL is immutable.
@MainActor
final class PunctuationModelFetcher: NSObject, @unchecked Sendable {

    static let shared = PunctuationModelFetcher()

    nonisolated private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot", category: "punct-fetch"
    )

    static let sessionIdentifier = "com.vineetu.jot.mobile.Jot.punctuation-fetch"

    private static let repo = "soloish90/punct-cap-seg-en-coreml-int8"

    /// Immutable revision. A third-party repo's `main` can be force-pushed or
    /// re-quantized; pinning the SHA means the bytes we verified are the bytes
    /// we install.
    private static let revision = "99eb3adab360034ec59d5f7dff2aaa0c13f7a4df"

    /// Exact HuggingFace blob sizes, pinned so a truncated or substituted file is
    /// caught before install rather than by CoreML at load.
    static let manifest: [(path: String, size: Int64)] = [
        ("punctuation.mlmodelc/analytics/coremldata.bin", 243),
        ("punctuation.mlmodelc/coremldata.bin", 458),
        ("punctuation.mlmodelc/metadata.json", 3170),
        ("punctuation.mlmodelc/model.mil", 86569),
        ("punctuation.mlmodelc/weights/weight.bin", 59_374_976),
    ]

    static var totalBytes: Int64 { manifest.reduce(0) { $0 + $1.size } }

    /// Staging + install copies coexist during the atomic move, plus headroom.
    static var requiredFreeBytes: Int64 { totalBytes * 2 + 50 * 1024 * 1024 }

    // MARK: - State

    enum Phase: Equatable {
        case idle
        case downloading(completedBytes: Int64, totalBytes: Int64)
        case installing
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle {
        didSet {
            onPhaseChange?(phase)
            // Surface phase TRANSITIONS in the in-app Diagnostics log — the
            // fetch is otherwise invisible (discretionary, no UI), and per-tick
            // progress would flood the log, so `.downloading` records only on
            // entry from a different phase.
            switch (oldValue, phase) {
            case (.downloading, .downloading):
                break
            case (_, .downloading):
                DiagnosticsLog.record(
                    source: "main-app", category: .punctuationModel,
                    message: "Punctuation model download started",
                    metadata: ["totalMB": "\(Self.totalBytes / 1_048_576)"]
                )
            case (_, .done):
                DiagnosticsLog.record(
                    source: "main-app", category: .punctuationModel,
                    message: "Punctuation model installed"
                )
            case (_, .failed(let why)):
                DiagnosticsLog.record(
                    source: "main-app", category: .punctuationModel,
                    message: "Punctuation model download FAILED",
                    metadata: ["reason": why]
                )
            default:
                break
            }
        }
    }

    var onPhaseChange: ((Phase) -> Void)?

    // MARK: - Session

    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private var _session: URLSession?

    private func makeOrGetSession() -> URLSession {
        if let _session { return _session }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Discretionary: this starts on its own, so let the system pick a moment
        // when the device is on Wi-Fi and ideally charging.
        config.isDiscretionary = true
        config.allowsCellularAccess = false
        config.sessionSendsLaunchEvents = true
        let s = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        _session = s
        return s
    }

    private override init() { super.init() }

    // MARK: - Paths

    /// `nonisolated`: the `URLSessionDownloadDelegate` callbacks are nonisolated
    /// and must resolve the staging path synchronously, before the temp file is
    /// deleted out from under them.
    nonisolated static var installDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Jot", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("punct-cap-seg-en", isDirectory: true)
    }

    private var installDirectory: URL { Self.installDirectory }

    nonisolated fileprivate static var stagingDirectory: URL {
        installDirectory.deletingLastPathComponent()
            .appendingPathComponent(".punct-staging", isDirectory: true)
    }

    private var stagingDirectory: URL { Self.stagingDirectory }

    /// The compiled model inside the installed tree.
    nonisolated static var compiledModelURL: URL {
        installDirectory.appendingPathComponent("punctuation.mlmodelc", isDirectory: true)
    }

    // MARK: - Completeness

    var isInstalled: Bool { treeIsComplete(at: installDirectory) }

    private func treeIsComplete(at root: URL) -> Bool {
        let fm = FileManager.default
        for entry in Self.manifest {
            let url = root.appendingPathComponent(entry.path)
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64,
                  size == entry.size
            else { return false }
        }
        return true
    }

    private func stagedFileIsComplete(_ relativePath: String) -> Bool {
        guard let entry = Self.manifest.first(where: { $0.path == relativePath }) else { return false }
        let url = stagingDirectory.appendingPathComponent(relativePath)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
        else { return false }
        return size == entry.size
    }

    fileprivate func stagedBytes() -> Int64 {
        var total: Int64 = 0
        for entry in Self.manifest {
            let url = stagingDirectory.appendingPathComponent(entry.path)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 {
                total += min(size, entry.size)
            }
        }
        return total
    }

    var hasEnoughFreeDisk: Bool {
        guard let values = try? installDirectory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let free = values.volumeAvailableCapacityForImportantUsage
        else { return true }   // unknown → let the download try
        return free > Self.requiredFreeBytes
    }

    // MARK: - Control

    /// Begin (or resume) the download. Safe to call repeatedly — already-staged
    /// files are skipped and live tasks are not duplicated.
    @discardableResult
    func start() -> Bool {
        if isInstalled {
            phase = .done
            return true
        }
        guard hasEnoughFreeDisk else {
            phase = .failed("Not enough free space for the punctuation model.")
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
                self.enqueueMissing(excluding: Set(tasks.compactMap { $0.taskDescription }), into: session)
            }
        }
        phase = .downloading(completedBytes: stagedBytes(), totalBytes: Self.totalBytes)
        return true
    }

    /// Called at launch. Re-attaches the background session so a download that
    /// finished while the app was closed gets installed, and kicks off a fresh
    /// one if the model is still missing.
    func resumeIfPending() {
        guard !isInstalled else {
            phase = .done
            return
        }
        _ = makeOrGetSession()
        if FileManager.default.fileExists(atPath: stagingDirectory.path) {
            attemptInstallIfComplete()
        }
        if !isInstalled { start() }
    }

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
            try? FileManager.default.removeItem(
                at: stagingDirectory.appendingPathComponent(entry.path)
            )
            guard let url = URL(
                string: "https://huggingface.co/\(Self.repo)/resolve/\(Self.revision)/\(entry.path)"
            ) else { continue }
            let task = session.downloadTask(with: url)
            task.taskDescription = entry.path
            task.resume()
            enqueued += 1
        }
        Self.log.info("punct fetch — enqueued \(enqueued, privacy: .public)/\(Self.manifest.count, privacy: .public)")
        if enqueued == 0 { attemptInstallIfComplete() }
    }

    private var backgroundCompletionHandler: (() -> Void)?

    func handleBackgroundSessionEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        _ = makeOrGetSession()
    }

    // MARK: - Install

    fileprivate func attemptInstallIfComplete() {
        guard treeIsComplete(at: stagingDirectory) else {
            if case .downloading = phase {
                phase = .downloading(completedBytes: stagedBytes(), totalBytes: Self.totalBytes)
            }
            return
        }
        phase = .installing

        let fm = FileManager.default
        let parent = installDirectory.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(
            "punct-install-\(UUID().uuidString)", isDirectory: true
        )
        do {
            try fm.copyItem(at: stagingDirectory, to: temp)
        } catch {
            try? fm.removeItem(at: temp)
            phase = .failed("Couldn't finish installing the punctuation model.")
            Self.log.error("stage→temp copy failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Re-verify at temp: the copy itself can truncate on a full disk.
        guard treeIsComplete(at: temp) else {
            try? fm.removeItem(at: temp)
            phase = .failed("The copied model was incomplete.")
            return
        }
        do {
            if fm.fileExists(atPath: installDirectory.path) {
                try fm.removeItem(at: installDirectory)
            }
            try fm.moveItem(at: temp, to: installDirectory)
        } catch {
            try? fm.removeItem(at: temp)
            phase = .failed("Couldn't finish installing the punctuation model.")
            Self.log.error("atomic install failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard isInstalled else {
            try? fm.removeItem(at: installDirectory)
            phase = .failed("The installed model failed its check.")
            return
        }
        _ = BackupExclusion.setExcludedFromBackupRecursively(at: installDirectory)
        try? fm.removeItem(at: stagingDirectory)
        Self.log.info("punct fetch — installed \(Self.totalBytes / 1_048_576, privacy: .public) MB")
        phase = .done
    }
}

// MARK: - URLSessionDownloadDelegate

extension PunctuationModelFetcher: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let relativePath = downloadTask.taskDescription else { return }
        // HuggingFace answers 4xx/5xx with a BODY, which would otherwise be
        // written out as a plausible-looking file. Reject on status first.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            Self.log.error("punct fetch — HTTP \(http.statusCode, privacy: .public) for \(relativePath, privacy: .public)")
            return
        }
        // Must move synchronously: the temp file is deleted when this returns.
        let fm = FileManager.default
        let dest = PunctuationModelFetcher.stagingDirectory.appendingPathComponent(relativePath)
        do {
            try fm.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
        } catch {
            Self.log.error("punct fetch — stage move failed for \(relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        Task { @MainActor in
            PunctuationModelFetcher.shared.attemptInstallIfComplete()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            let fetcher = PunctuationModelFetcher.shared
            guard case .downloading = fetcher.phase else { return }
            fetcher.phase = .downloading(
                completedBytes: min(fetcher.stagedBytes() + totalBytesWritten,
                                    PunctuationModelFetcher.totalBytes),
                totalBytes: PunctuationModelFetcher.totalBytes
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
        Self.log.error("punct fetch — task failed \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            if (error as NSError).code == NSURLErrorCancelled { return }
            PunctuationModelFetcher.shared.phase = .failed(error.localizedDescription)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let fetcher = PunctuationModelFetcher.shared
            fetcher.attemptInstallIfComplete()
            fetcher.backgroundCompletionHandler?()
            fetcher.backgroundCompletionHandler = nil
        }
    }
}
