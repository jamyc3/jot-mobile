import Foundation
import JotVocabCore

/// **App-side wiring for the shared `JotVocabCore` package's injection seams.**
///
/// The vocabulary-correction brains (gate, correction/provenance stores, ask
/// policy, common-words loading) now live in `JotVocabCore` (see
/// `../../jot-shared`, same no-forks rule as `JotTextPipeline`). The package is
/// a pure Foundation island; everything platform-specific crosses one of its
/// four seams. This file supplies the iOS side of all four:
///   1. engine-neutral rescore input — mapped at the rescorer call site
///      (`VocabularyRescorerHolder`), not here;
///   2. `CommonWordsProvider` — `AppVocabCore.commonWords` (loud-fail sink);
///   3. `DiagnosticsSink` — `AppVocabDiagnosticsSink` → `DiagnosticsLog`;
///   4. storage root — `AppVocabCore.containerRoot` (Application Support).
///
/// It also re-establishes the `.shared` singletons the app called before the
/// stores moved into the package (the package types are unopinionated about
/// process/paths and take injected roots/sinks), so every existing call site
/// keeps compiling unchanged.

/// Maps the package's typed diagnostics category onto the app's
/// `DiagnosticsLog.Category` (a 2-case switch — the moved code emits exactly
/// these two). Replaces the `os.Logger` + `DiagnosticsLog.record` calls that
/// the in-tree stores/gate made directly.
struct AppVocabDiagnosticsSink: JotVocabCore.DiagnosticsSink {
    func record(category: JotVocabCore.DiagnosticsCategory, message: String, metadata: [String: String]) {
        let appCategory: DiagnosticsCategory
        switch category {
        case .vocabularyGate: appCategory = .vocabularyGate
        case .vocabularySaveFailed: appCategory = .vocabularySaveFailed
        }
        DiagnosticsLog.record(source: "main-app", category: appCategory, message: message, metadata: metadata)
    }
}

/// Canonical app-process instances of the package's injected dependencies.
enum AppVocabCore {
    static let diagnostics = AppVocabDiagnosticsSink()

    /// The container root the package's `Vocabulary/…` subtree lives under.
    /// Resolves the **same** `Application Support` directory the in-tree
    /// `CorrectionStore.fileURL` / `CorrectionProvenance.fileURL` /
    /// `VocabularyStore.fileURL` used, so the package's fixed
    /// `<root>/Vocabulary/{corrections.json, provenance/, vocabulary.txt}`
    /// layout lands BYTE-IDENTICALLY on top of the existing files — zero data
    /// migration on iOS (design §3: iOS is already the unified layout).
    static let containerRoot: URL? = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)

    /// The gate's common-words provider — package-resource-backed, loud-fails a
    /// missing/unreadable list through the app sink (the exact over-correction
    /// class the guard exists to prevent). Wired into `VocabularyGate.apply`
    /// at the rescorer seam.
    static let commonWords = BundledCommonWordsProvider(diagnostics: diagnostics)
}

/// The single main-app correction store (was `CorrectionStore.shared`, now the
/// package actor with the app's root + sink injected). App-sandbox only — the
/// keyboard never touches this (it reads `CorrectionBridge`).
extension CorrectionStore {
    static let shared = CorrectionStore(
        containerRoot: AppVocabCore.containerRoot, diagnostics: AppVocabCore.diagnostics)
}

/// The single main-app provenance store (was `CorrectionProvenance.shared`).
extension CorrectionProvenance {
    static let shared = CorrectionProvenance(
        containerRoot: AppVocabCore.containerRoot, diagnostics: AppVocabCore.diagnostics)
}
