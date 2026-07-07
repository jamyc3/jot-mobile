import FluidAudio
import Foundation
import os.log

/// **Release T carry-forward migration** — the safe first step toward stripping
/// the bundled Parakeet 600M **v2** English model from the app binary.
///
/// See `docs/dictation-engine-rework/v2-carry-forward-migration-design.md` for
/// the full design + the Opus adversarial review's must-fix gaps (C / C2 / E /
/// F / G) folded in here. Two responsibilities, both driven from `JotApp.init`:
///
/// 1. **§A carry-forward copy** (`runIfNeeded`): copy the bundled 600M v2 into
///    FluidAudio's Application-Support cache — the exact directory a *future*
///    stripped build's loader (`TranscriptionService.modelDirectory()`) falls
///    through to for English — so the eventual bundle strip (Release S) is a
///    pure data move with zero re-download. Copies ONLY the 600M v2; the CTC
///    vocabulary scorer + EmbeddingGemma stay bundled (§A2).
/// 2. **§D existing-vs-new-user default** (`resolveEnglishEngineDefaultIfNeeded`):
///    keep an *existing* Parakeet user on Parakeet across the update; leave a
///    *new* user on Apple's default engine. Resolved SYNCHRONOUSLY and EARLY in
///    `JotApp.init`, off a cheap synchronous store-file existence check — never
///    a racy SwiftData query, and never so late a UI-less dictation start
///    (Action Button / DictateIntent / cold `jot://dictate`) could read the
///    global-true default before we've flipped it (§E launch-ordering).
///
/// This build still **bundles v2** — it is NOT the strip (that is the later
/// Release S). It only makes the future strip safe.
enum V2CarryForwardMigration {

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "v2-carry-forward"
    )

    /// Free space (bytes) required before attempting the copy. The transient
    /// footprint is the ~443 MB temp copy alongside the still-present bundle
    /// (~443 MB); we require ~900 MB of *important-usage* headroom so a
    /// nearly-full device skips cleanly and retries next launch rather than
    /// failing mid-copy (§F free-space preflight).
    private static let requiredFreeBytes: Int64 = 900 * 1024 * 1024

    /// The Application-Support destination leaf for the carried v2 model:
    /// `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2/`.
    /// Its last path component is exactly `parakeet-tdt-0.6b-v2` (NO `-coreml`) —
    /// this MUST equal `Repo.parakeetV2.folderName` or `AsrModels.modelsExist` /
    /// the stripped-build loader look one directory over and find nothing
    /// (the build-142 trap, §B). It resolves to the same directory the
    /// `modelDirectory()` English fallthrough returns once the bundle is gone.
    static var destinationDirectory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetV2)
    }

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

    // MARK: - §A — carry-forward copy

    /// Idempotent per-launch carry-forward: if this device can run Parakeet and
    /// the bundle still ships v2, ensure a VERIFIED-complete copy of the 600M v2
    /// exists in the Application-Support cache. Off the main thread, best-effort,
    /// self-healing. No flag — a cheap presence+verify check every launch, a
    /// no-op once the copy is complete (§A "no stuck-flag").
    static func runIfNeeded() {
        Task.detached(priority: .utility) {
            performCarryForward()
        }
    }

    private static func performCarryForward() {
        // Gate 1 — only on devices that can actually run Parakeet (iPhone 14
        // Pro+/iPad M1+). A sub-tier device is Apple-only for English, so
        // copying ~443 MB it will never load is pure waste.
        guard TranscriptionService.parakeetUsable else { return }

        // Gate 2 — only while v2 is still bundled (this IS Release T; after the
        // strip `bundled600mDirectory()` is nil and there's nothing to carry).
        guard let bundleLeaf = TranscriptionService.bundled600mDirectory() else { return }

        let fm = FileManager.default
        let dest = destinationDirectory
        let modelsParent = dest.deletingLastPathComponent() // .../FluidAudio/Models/

        // Compute the bundle's signature once (recursive file-count + total
        // size). This is the yardstick for BOTH the "already done?" check and
        // the post-copy verify — a check STRONGER than `modelsExist`, which only
        // stats the four top-level `.mlmodelc` dirs and so cannot detect a
        // truncated copy (§C).
        guard let bundleSig = signature(of: bundleLeaf) else {
            log.error("Carry-forward: could not read bundle signature at \(bundleLeaf.path, privacy: .public)")
            return
        }

        // Already carried-forward and complete? Cheap no-op forever after (§A).
        if fm.fileExists(atPath: dest.path) {
            if let destSig = signature(of: dest), destSig == bundleSig {
                return
            }
            // A partial/mismatched copy in the leaf (interrupted earlier run,
            // corrupt, or a shape change). Fall through — we rebuild it via a
            // fresh temp + atomic swap below; the stale leaf is removed only in
            // the final atomic install so the bundle keeps serving until then.
            log.notice("Carry-forward: destination present but incomplete/mismatched; rebuilding")
        }

        // §F free-space preflight — skip cleanly + retry next launch if short.
        // Harmless in Release T: the bundle still serves dictation.
        if let free = availableImportantCapacity(at: modelsParent), free < requiredFreeBytes {
            log.notice(
                "Carry-forward: skipped — low free space (\(free, privacy: .public) < \(requiredFreeBytes, privacy: .public) bytes); retry next launch"
            )
            return
        }

        do {
            try fm.createDirectory(at: modelsParent, withIntermediateDirectories: true)
        } catch {
            log.error("Carry-forward: could not create models parent \(modelsParent.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        // Sweep any abandoned temp siblings from an interrupted prior run before
        // starting a fresh one (crash-mid-copy leaves only a temp, never a
        // half-model in the leaf — §C).
        sweepTempSiblings(in: modelsParent)

        // §C — copy into a TEMP sibling, verify, then atomically install. Never
        // copy in place. `copyItem` on the whole leaf brings the four
        // `.mlmodelc` package dirs + vocab across in one shot — do NOT copy them
        // individually and do NOT pre-create the leaf (§B build-142 mechanics).
        let temp = modelsParent.appendingPathComponent(
            "parakeet-tdt-0.6b-v2.carry-tmp-\(UUID().uuidString)",
            isDirectory: true
        )

        let startedAt = Date()
        do {
            try fm.copyItem(at: bundleLeaf, to: temp)
        } catch {
            log.error("Carry-forward: copy to temp failed: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: temp)
            return
        }

        // Verify the temp is byte-count/file-count complete vs the bundle —
        // STRONGER than `modelsExist` (§C). A truncated copy is caught here and
        // discarded, never installed.
        guard let tempSig = signature(of: temp), tempSig == bundleSig else {
            log.error("Carry-forward: temp copy failed verification; discarding")
            try? fm.removeItem(at: temp)
            return
        }

        // Atomic install: remove any stale (incomplete) leaf, then rename the
        // verified temp into place. `moveItem` on the same volume is an atomic
        // rename; the only window is "leaf briefly absent" (safe — the bundle
        // still serves in Release T), never "half-model in the leaf".
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: temp, to: dest)
        } catch {
            log.error("Carry-forward: atomic install failed: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: temp)
            return
        }

        // Backup-exclude the carried weights so a ~443 MB model doesn't bloat
        // iCloud backups. The per-launch `BackupExclusion.excludeFluidAudioModels`
        // sweep also covers this tree, but exclude explicitly now so the copy is
        // excluded from the moment it lands, not only after the next launch.
        let excluded = BackupExclusion.setExcludedFromBackupRecursively(at: dest)

        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        DiagnosticsLog.record(
            source: "main-app",
            category: .modelLoad,
            message: "carried v2 forward to App Support",
            metadata: [
                "files": "\(bundleSig.fileCount)",
                "bytes": "\(bundleSig.totalSize)",
                "copyMS": "\(elapsedMS)",
                "excluded": "\(excluded)",
                "kind": "carry-forward",
            ]
        )
        log.info(
            "Carry-forward: installed \(bundleSig.fileCount, privacy: .public) files (\(bundleSig.totalSize, privacy: .public) bytes) at \(dest.path, privacy: .public) in \(elapsedMS, privacy: .public)ms"
        )
    }

    // MARK: - Helpers

    /// Recursive (file-count, total-logical-size) of a directory tree, counting
    /// only regular files. This is the completeness yardstick used to detect a
    /// truncated/partial copy that `modelsExist` (dir-existence only) would miss.
    private static func signature(of dir: URL) -> (fileCount: Int, totalSize: Int64)? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return nil
        }
        var count = 0
        var size: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            count += 1
            size += Int64(values.fileSize ?? 0)
        }
        return (count, size)
    }

    /// Available important-usage capacity on the volume backing `url`, or `nil`
    /// if it can't be read (in which case we proceed rather than block on an
    /// unreadable metric).
    private static func availableImportantCapacity(at url: URL) -> Int64? {
        // Resolve against an existing ancestor — the leaf may not exist yet.
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

    /// Remove abandoned `parakeet-tdt-0.6b-v2.carry-tmp-*` temp dirs left by an
    /// interrupted copy (crash/jetsam mid-`copyItem`).
    private static func sweepTempSiblings(in parent: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }
        let prefix = "parakeet-tdt-0.6b-v2.carry-tmp-"
        for url in entries where url.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: url)
        }
    }
}
