import FluidAudio
import Foundation
import os.log

/// **Release T §D existing-vs-new-user English engine default.**
///
/// See `docs/dictation-engine-rework/v2-carry-forward-migration-design.md`. The
/// §A carry-forward COPY machinery this file used to own was generalized to
/// three assets and moved to `ModelCarryForward` (see
/// `docs/plans/model-externalization-sub-50mb.md` §A1). What remains here is the
/// one responsibility that is specific to the English dictation engine and has
/// no analogue for the other two models:
///
/// **§D existing-vs-new-user default** (`resolveEnglishEngineDefaultIfNeeded`):
/// keep an *existing* Parakeet user on Parakeet across the update; leave a *new*
/// user on Apple's default engine. Resolved SYNCHRONOUSLY and EARLY in
/// `JotApp.init`, off a cheap synchronous store-file existence check — never a
/// racy SwiftData query, and never so late a UI-less dictation start (Action
/// Button / DictateIntent / cold `jot://dictate`) could read the global-true
/// default before we've flipped it (§E launch-ordering).
enum V2CarryForwardMigration {

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "v2-carry-forward"
    )

    // MARK: - §D — existing-vs-new-user English engine default

    /// Resolve, ONCE, whether English dictation defaults to Apple (new user) or
    /// stays on Parakeet (existing user). Synchronous + guarded — call it EARLY
    /// in `JotApp.init`, before the recording subsystem can service any start,
    /// so an existing user's first post-update English dictation never slips
    /// onto Apple before we've flipped them back (§E launch-ordering ⚠️).
    ///
    /// - **Existing user** (SwiftData store file already on disk) on a
    ///   Parakeet-capable device → `useAppleDictationForEnglish = false` (keep
    ///   their working engine).
    /// - **New user**, or an existing user on a device that can't run Parakeet
    ///   at all → leave the shipped Apple default (`true`). On sub-tier devices
    ///   we never flip to Parakeet, so they stay on Apple regardless.
    ///
    /// Runs at most once (guard flag). Never re-runs, so a later explicit
    /// Settings toggle always wins thereafter. Touches only a UserDefaults /
    /// App-Group value — **no** SwiftData `@Model` change (schema impact: NONE).
    static func resolveEnglishEngineDefaultIfNeeded() {
        let defaults = AppGroup.defaults
        guard !defaults.bool(forKey: engineDefaultResolvedKey) else { return }

        let existingUser = swiftDataStoreFileExists()
        let parakeetUsable = TranscriptionService.parakeetUsable
        // Has the user actually been dictating on APPLE? A user who installed
        // during the Apple-default era and has been happily using Apple must NOT
        // be flipped to Parakeet — that would be an unrequested engine change
        // (adversarial review HIGH). Only keep GENUINE prior-Parakeet users
        // (zero Apple dictations) on Parakeet.
        let hasAppleHistory = DictationStats.appleDictationCount > 0

        // Set the VALUE before marking resolved (flag-after-work), even though
        // a UserDefaults write can't fail — order-of-writes discipline.
        if existingUser && parakeetUsable && !hasAppleHistory {
            AppGroup.useAppleDictationForEnglish = false
        }
        // else: leave the global Apple default (true). New user → Apple.
        // Existing user on a sub-tier device → Apple (can't run Parakeet).
        // Existing user WITH Apple history → stay on Apple (their choice/engine).

        defaults.set(true, forKey: engineDefaultResolvedKey)

        DiagnosticsLog.record(
            source: "main-app",
            category: .modelLoad,
            message: "english engine default resolved",
            metadata: [
                "existingUser": "\(existingUser)",
                "parakeetUsable": "\(parakeetUsable)",
                "useApple": "\(AppGroup.useAppleDictationForEnglish)",
                "kind": "carry-forward",
            ]
        )
        log.info(
            "English engine default resolved — existingUser=\(existingUser, privacy: .public) parakeetUsable=\(parakeetUsable, privacy: .public) useApple=\(AppGroup.useAppleDictationForEnglish, privacy: .public)"
        )
    }

    /// UserDefaults/App-Group guard so §D resolves at most once per install.
    private static let engineDefaultResolvedKey = "jot.englishEngineDefault.resolved_v1"

    /// Cheap SYNCHRONOUS "is this an established install" signal: does the
    /// SwiftData store FILE exist on disk in the App Group container? This is a
    /// plain `fileExists` — NOT a SwiftData query, which loads async/heavy/racy
    /// and isn't reliably answerable this early in launch (§E). The store file
    /// (`JotTranscripts.store`) is created by SwiftData on first container
    /// access and persists across app updates, so its presence means the user
    /// ran a prior build (an existing user); its absence on a fresh Release T
    /// install means a new user. Checked before anything in `init` touches
    /// `JotModelContainer.shared`, so a new user is never mis-read as existing.
    private static func swiftDataStoreFileExists() -> Bool {
        guard let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier
        ) else {
            return false
        }
        let store = base
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("JotTranscripts.store")
        return FileManager.default.fileExists(atPath: store.path)
    }
}
