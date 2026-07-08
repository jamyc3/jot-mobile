import FluidAudio
import Foundation
import OSLog

/// Owns the offline speaker-diarization model — FluidAudio's VBx pipeline
/// (pyannote community-1: segmentation + embedding + PLDA, ~22 MB total).
/// Experimental **Diarization Lab** feature (Settings → About, revealed by the
/// same 5-tap-on-Version gesture as the TTS Lab).
///
/// Ported from the validated Mac Jot research at
/// `docs/speaker-diarization/design.md` (D1: offline VBx over every streaming
/// alternative — 12% DER, 120–220× real-time on Mac, no hardware gate needed).
/// Mirrors `VocabularyRescorerHolder`'s generation-guarded actor shape: a
/// monotonic `generation` defends every resume point after an `await` so a
/// stale/cancelled prepare can't clobber a newer one's state.
actor DiarizerHolder {
    static let shared = DiarizerHolder()

    enum ModelState: Equatable, Sendable {
        case notLoaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var modelState: ModelState = .notLoaded
    private(set) var isProcessing = false
    private var manager: ManagerBox?
    private var generation = 0

    private let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "Diarizer")

    var isReady: Bool {
        if case .ready = modelState { return true }
        return false
    }

    /// Whether the offline diarizer weights are already on disk — a best-effort
    /// existence check of the default models directory. `nonisolated` (touches
    /// no actor state) so the launch prefetch can consult it synchronously to
    /// skip a needless network monitor when nothing needs downloading.
    nonisolated static var modelsAreDownloaded: Bool {
        let dir = OfflineDiarizerModels.defaultModelsDirectory()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !contents.isEmpty
    }

    /// Downloads (first run only — cached after) and loads the offline
    /// diarizer models. Safe to call repeatedly; a second caller mid-flight
    /// just no-ops until the first completes.
    func prepareIfNeeded() async {
        switch modelState {
        case .ready, .downloading, .loading: return
        case .notLoaded, .failed: break
        }
        generation += 1
        let myGeneration = generation
        modelState = .downloading(0)
        do {
            let directory = OfflineDiarizerModels.defaultModelsDirectory()
            let models = try await OfflineDiarizerModels.load(
                from: directory,
                progressHandler: { [weak self] progress in
                    guard let self else { return }
                    Task { await self.updateDownloadProgress(progress.fractionCompleted, generation: myGeneration) }
                }
            )
            guard myGeneration == generation else { return }
            modelState = .loading
            let mgr = OfflineDiarizerManager()
            mgr.initialize(models: models)
            guard myGeneration == generation else { return }
            manager = ManagerBox(manager: mgr)
            modelState = .ready
            log.info("offline diarizer models ready")
        } catch {
            guard myGeneration == generation else { return }
            modelState = .failed(error.localizedDescription)
            log.error("prepare failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateDownloadProgress(_ fraction: Double, generation myGeneration: Int) {
        guard myGeneration == generation, case .downloading = modelState else { return }
        modelState = .downloading(fraction)
    }

    /// Runs the offline VBx pipeline over a retained-audio file (FluidAudio
    /// auto-converts sample rate / channels from the file). Single-in-flight —
    /// mirrors `TranscriptionService.isTranscribing`'s fast-fail shape. Callers
    /// should also check `TranscriptionService.shared.isBusy` first: FluidAudio's
    /// shared CoreML/BNNS state is not safe under two concurrently-running
    /// inference graphs from different pipelines.
    func diarize(audioFileURL url: URL) async throws -> DiarizationResult {
        guard !isProcessing else { throw DiarizerHolderError.busy }
        await prepareIfNeeded()
        guard let manager, isReady else { throw DiarizerHolderError.notReady }
        isProcessing = true
        defer { isProcessing = false }
        return try await manager.process(url)
    }
}

/// `@unchecked Sendable` wrapper: `OfflineDiarizerManager` is a non-`Sendable`
/// reference type (FluidAudio documents its `models` property as
/// `nonisolated(unsafe)`, written only once during `initialize` and read-only
/// after). The wrapper confines the reference so the actor can `await` its
/// `process` call without a "sending risks data races" diagnostic. Same shape
/// as `DictationLiveActivityController`'s `ActivityHandle`.
private struct ManagerBox: @unchecked Sendable {
    let manager: OfflineDiarizerManager
    func process(_ url: URL) async throws -> DiarizationResult {
        try await manager.process(url)
    }
}

enum DiarizerHolderError: Error, LocalizedError {
    case notReady
    case busy

    var errorDescription: String? {
        switch self {
        case .notReady: return "The speaker diarization model isn't ready yet."
        case .busy: return "Already detecting speakers in another recording."
        }
    }
}
