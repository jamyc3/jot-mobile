import FluidAudio
import Foundation

/// Process-wide coalescing lock so two concurrent setup/Settings/Vocab
/// taps for the boost-model load don't compile the same CoreML packages
/// twice in parallel. The bundle resources are read-only and the
/// `loadDirect` path doesn't touch the network, but the underlying
/// `MLModel(contentsOf:)` calls are non-trivial and we keep a single
/// in-flight load for symmetry with the old download-coordinator.
@MainActor
private final class CtcLoadCoordinator {
    static let shared = CtcLoadCoordinator()
    private var inFlight: Task<CtcModels, Error>?

    func ensureLoaded(directory: URL, variant: CtcModelVariant) async throws -> CtcModels {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task<CtcModels, Error> {
            try await CtcModels.loadDirect(from: directory, variant: variant)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

/// Single in-flight gate for the CTC DOWNLOAD (⚠️REVIEW M4). Two triggers race
/// the same directory otherwise: the B1 launch auto-trigger and the vocab
/// Settings "Download" button. Mirrors `CtcLoadCoordinator` so both callers
/// share one download Task rather than pulling the same 99 MB twice.
@MainActor
private final class CtcDownloadCoordinator {
    static let shared = CtcDownloadCoordinator()
    private var inFlight: Task<URL, Error>?

    func ensureDownloaded(to directory: URL, variant: CtcModelVariant) async throws -> URL {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task<URL, Error> {
            // `to:` is the leaf target; `CtcModels.download` resolves its parent
            // internally and skips files already on disk. Network only — the
            // ANE load happens later in `ensureLoaded`, which is where the
            // serial cold-load chain gates it.
            try await CtcModels.download(to: directory, variant: variant)
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

/// Bundle location for the Parakeet CTC 110M bundle used by the
/// vocabulary-boosting pipeline.
///
/// The CTC aux bundle (~100 MB — MelSpectrogram + AudioEncoder +
/// CtcHead CoreML packages + vocabulary/tokenizer JSON) ships inside
/// the IPA at
/// `<Bundle>/Models/Parakeet/parakeet-ctc-110m-coreml/`, so
/// vocabulary biasing is available immediately on install with no
/// separate user-initiated download. `CtcModels.loadDirect(from:)`
/// reads the `.mlmodelc` packages straight from the bundle —
/// `DownloadUtils` is bypassed entirely.
public struct CtcModelCache: Sendable {
    public let root: URL
    public let variant: CtcModelVariant

    public init(root: URL, variant: CtcModelVariant = .ctc110m) {
        self.root = root
        self.variant = variant
    }

    /// Two-step root resolution (⚠️REVIEW M1). This is a `static let`, so its
    /// `root` is captured ONCE at process start — the resolution MUST NOT bake
    /// in a dead path. Order:
    ///
    ///   1. **App-Support copy** (`FluidAudio/Models/`) if the scorer's required
    ///      files are already there — carry-forward landed OR a prior download.
    ///      Preferred even while the bundle still ships (Build A) so the
    ///      post-strip read path is field-proven early (mirrors v2/§A2).
    ///   2. **Bundle** (`<Bundle>/Models/Parakeet/`) if it still ships the
    ///      scorer (Build A, before carry-forward has run this launch).
    ///   3. **App-Support** as the STABLE DOWNLOAD TARGET when neither exists
    ///      (stripped Build B / iCloud restore / skip-A). A later download lands
    ///      at `root/<leaf>` and is found on next access — never a dead bundle
    ///      path captured at process start.
    public static let shared: CtcModelCache = {
        let variant: CtcModelVariant = .ctc110m
        let leaf = variant.repo.folderName // "parakeet-ctc-110m-coreml"
        let appSupportRoot = MLModelConfigurationUtils.defaultModelsDirectory() // …/FluidAudio/Models
        let bundleRoot = Bundle.main.bundleURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Parakeet", isDirectory: true)

        if CtcModels.modelsExist(at: appSupportRoot.appendingPathComponent(leaf, isDirectory: true)) {
            return CtcModelCache(root: appSupportRoot, variant: variant)
        }
        if CtcModels.modelsExist(at: bundleRoot.appendingPathComponent(leaf, isDirectory: true)) {
            return CtcModelCache(root: bundleRoot, variant: variant)
        }
        return CtcModelCache(root: appSupportRoot, variant: variant)
    }()

    /// The stable Application-Support DOWNLOAD target for this variant,
    /// independent of `root` — always
    /// `…/FluidAudio/Models/parakeet-ctc-110m-coreml/`, exactly the directory a
    /// carry-forward installs into and `CtcModels.download(to:)` writes. When a
    /// download is possible at all (bundle absent), `root` already resolves to
    /// the App-Support root, so `directory == appSupportDownloadDirectory`.
    public var appSupportDownloadDirectory: URL {
        MLModelConfigurationUtils.defaultModelsDirectory(for: variant.repo)
    }

    /// Directory containing the CTC `.mlmodelc` packages and `vocab.json`.
    /// `CtcModels.loadDirect(from:)` reads
    /// `MelSpectrogram.mlmodelc`, `AudioEncoder.mlmodelc`, and
    /// `vocab.json` relative to this URL.
    public var directory: URL {
        switch variant {
        case .ctc110m:
            return root.appendingPathComponent("parakeet-ctc-110m-coreml", isDirectory: true)
        case .ctc06b:
            return root.appendingPathComponent("parakeet-ctc-06b-coreml", isDirectory: true)
        }
    }

    /// True when every file FluidAudio requires is on disk. Delegates to
    /// the SDK — only it knows the exact required file set. On a healthy
    /// install this is always true because the bundle ships the full
    /// required-set.
    public var isCached: Bool {
        CtcModels.modelsExist(at: directory)
    }

    public func ensureRootExists() throws {
        // Bundle resources are read-only; nothing to create.
    }

    /// Download the CTC scorer into the stable App-Support target if it isn't
    /// already on disk. Coalesced via `CtcDownloadCoordinator` so the B1 launch
    /// auto-trigger and the vocab Settings button can't pull it twice (M4).
    /// Network only — no ANE load (that's `ensureLoaded`). Returns the target
    /// directory. In Build A the bundle already satisfies `isCached`, so no
    /// caller reaches this path; it's the download backstop for the stripped
    /// build / iCloud restore / skip-A cohorts.
    @discardableResult
    public func ensureDownloaded() async throws -> URL {
        try await CtcDownloadCoordinator.shared.ensureDownloaded(
            to: appSupportDownloadDirectory,
            variant: variant
        )
    }

    /// Download (if needed) THEN load — the vocab Settings "Download vocabulary
    /// model" action. Downloads to App Support, then loads via the shared
    /// `CtcLoadCoordinator`. When `root` already resolves to App Support (the
    /// only cohort that reaches a download), `directory` points at the freshly
    /// downloaded files.
    @discardableResult
    public func downloadAndLoad() async throws -> CtcModels {
        _ = try await ensureDownloaded()
        return try await ensureLoaded()
    }

    /// Load the CTC aux models from the bundled directory. On healthy
    /// installs this is a pure in-process CoreML load; there is no
    /// network or download branch — `CtcModels.loadDirect(from:)` reads
    /// the `.mlmodelc` packages straight from the bundle.
    ///
    /// Coalesced via `CtcLoadCoordinator` so concurrent callers (vocab
    /// pane, settings re-warm, transcription pipeline) share a single
    /// in-flight load.
    public func ensureLoaded() async throws -> CtcModels {
        return try await CtcLoadCoordinator.shared.ensureLoaded(
            directory: directory,
            variant: variant
        )
    }

    /// No-op for bundled resources — the bundle is read-only.
    /// Retained for source-compatibility with callers that previously
    /// drove a re-download via this method.
    func removeCache() {
        // No-op.
    }
}
