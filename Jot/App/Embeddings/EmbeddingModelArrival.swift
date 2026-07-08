#if JOT_APP_HOST
import Foundation
import OSLog

/// Arrival hooks fired the moment EmbeddingGemma lands on disk — whether via the
/// overnight `EmbeddingModelFetcher` or the foreground promote in `AskController`
/// (docs/plans/model-externalization-sub-50mb.md §A4/work-item 6). Two jobs:
///
/// 1. **Prewarm** the encoder so the first Ask/search after arrival doesn't pay
///    the one-time ANE specialization inline — but ROUTED so it never contends
///    with an in-flight dictation. We honor the serial cold-load chain's spirit:
///    wait for the dictation model to settle, then bail if a recording /
///    transcription is actually running (the ANE belongs to dictation then).
///    `prewarm()` is idempotent + coalesced, so a later warm-chain / first-use
///    load simply shares this one.
/// 2. **Backfill** every transcript dictated during the gap (⚠️REVIEW M3):
///    `EmbeddingBackfillTask` has no model-arrival trigger of its own, so kick
///    `submitIfBacklog()` here immediately on install.
enum EmbeddingModelArrival {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "embedding-model-arrival"
    )

    static func handleModelInstalled(reason: String) {
        log.info("EmbeddingGemma arrived (\(reason, privacy: .public)) — scheduling prewarm + backfill")

        // Backfill kick: just submits a BG task, safe from any state. Guarded
        // by iOS availability (the task type is 26.0+).
        Task { @MainActor in
            if #available(iOS 26.0, *) {
                EmbeddingBackfillTask.submitIfBacklog()
            }
        }

        // Prewarm, lowest priority, after the dictation model settles and only
        // when no capture/transcription is in flight (never steal the ANE from
        // a live dictation). If busy, skip — the next launch's warm chain or the
        // first Ask/search use loads it.
        Task(priority: .utility) {
            await TranscriptionService.shared.awaitWarmSettled()
            let busy = await MainActor.run {
                RecordingService.shared.isRecording || RecordingService.shared.isPipelineInFlight
            }
            guard !busy else {
                log.notice("prewarm skipped — dictation in flight; will warm on next trigger")
                return
            }
            try? await EmbeddingGemmaService.shared.prewarm()
        }
    }
}
#endif
