#if JOT_APP_HOST
import Foundation
import OSLog

/// Arrival hook fired the moment the background-downloaded Parakeet 600M v2
/// weights land on disk (`ParakeetModelFetcher`), completing the keyboard
/// nudge's "download-on-charge + auto-enable" flow
/// (docs/plans/parakeet-upgrade-nudge-download.md).
///
/// Its one job is the engine auto-switch, applied at a **safe boundary**: the
/// dictation engine is chosen at recording START, so flipping
/// `useAppleDictationForEnglish` while a recording / pipeline is in flight is the
/// one thing to avoid. So the flip is ARMED on arrival and applied the first
/// moment nothing is recording — immediately if idle, otherwise drained at the
/// next recording-end (`HomeScreen`) or app launch (`JotApp`). Once applied it
/// posts a cross-process signal so the home "you're now on Jot's engine"
/// confirmation surfaces, and best-effort prewarms Parakeet so the first English
/// dictation isn't cold.
enum ParakeetModelArrival {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "parakeet-model-arrival"
    )

    /// Called when the v2 weights become available (fetch install, or a launch
    /// resume that found them already present). Arms the switch and tries to apply
    /// it right away; if busy, `applyPendingSwitchIfSafe()` defers it.
    static func handleModelInstalled(reason: String) {
        log.info("Parakeet v2 arrived (\(reason, privacy: .public)) — arming engine switch")
        Task { @MainActor in
            AppGroup.parakeetSwitchArmed = true
            applyPendingSwitchIfSafe()
        }
    }

    /// Flip English dictation to Jot's engine IF armed AND at a safe boundary
    /// (nothing recording / no pipeline in flight). Idempotent and cheap — safe to
    /// call from the arrival hook, from recording-end, and from launch.
    @MainActor
    static func applyPendingSwitchIfSafe() {
        guard AppGroup.parakeetSwitchArmed else { return }
        // Never claim the switch if the weights aren't actually usable on device.
        guard TranscriptionService.parakeetV2ReadyOnDevice() else { return }

        let busy = RecordingService.shared.isRecording || RecordingService.shared.isPipelineInFlight
        guard !busy else {
            log.notice("engine switch deferred — recording in flight; will apply at next safe boundary")
            return
        }

        // Disarm regardless — the safe-boundary work is being done now.
        AppGroup.parakeetSwitchArmed = false

        // Only fire the "we switched you" confirmation if the flip actually
        // CHANGES the engine. A user who manually switched to Jot's engine in
        // Settings before the download landed is already on it (`useApple` false)
        // — re-announcing it would be a redundant, confusing popup. Still prewarm
        // the now-on-disk model so their first English dictation isn't cold.
        guard AppGroup.useAppleDictationForEnglish else {
            log.notice("engine already on Jot (manual switch before arrival); no confirmation — prewarming only")
            prewarmWhenIdle()
            return
        }

        AppGroup.useAppleDictationForEnglish = false
        AppGroup.parakeetSwitchedNotice = true
        // The nudge is moot now; make sure it can't re-surface, and reset the
        // Apple-dictation counter so a later Apple re-enable doesn't instantly
        // re-nudge (mirrors `UpgradeEngineView.useJotsEngine`).
        AppGroup.showParakeetUpgradeNudge = false
        DictationStats.resetAppleDictationCount()

        CrossProcessNotification.post(name: CrossProcessNotification.parakeetEngineActivated)
        CrossProcessNotification.post(name: CrossProcessNotification.parakeetUpgradeNudgeChanged)

        DiagnosticsLog.record(
            source: "main-app",
            category: .modelLoad,
            message: "switched English engine to Parakeet after background download",
            metadata: ["kind": "nudge-download"]
        )
        log.info("English engine switched to Parakeet (background download complete)")

        prewarmWhenIdle()
    }

    /// Best-effort prewarm so the first English dictation isn't cold. Lowest
    /// priority, after any in-flight load settles, and skipped if a capture
    /// starts in the meantime (never steal the ANE from a live dictation).
    @MainActor
    private static func prewarmWhenIdle() {
        Task(priority: .utility) {
            await TranscriptionService.shared.awaitWarmSettled()
            let busyNow = await MainActor.run {
                RecordingService.shared.isRecording || RecordingService.shared.isPipelineInFlight
            }
            guard !busyNow else { return }
            await MainActor.run { TranscriptionService.shared.warmIfNeeded() }
        }
    }
}
#endif
