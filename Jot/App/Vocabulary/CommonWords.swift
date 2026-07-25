import Foundation
import JotVocabCore

/// Thin shim over `JotVocabCore.BundledCommonWordsProvider`, preserving the
/// `CommonWords.isCommon(...)` call shape the app and keyboard use for the
/// "Add to Vocabulary" common-word hint.
///
/// The high-frequency word lists and their loading/cache now live in the
/// `JotVocabCore` package (served from `Bundle.module`); the app and keyboard
/// no longer bundle their own copies. Compiled into BOTH targets (the keyboard
/// lists this file explicitly in `project.yml`).
///
/// This convenience instance backs only the non-gate *hint* callers — a missing
/// list here is harmless (the hint just doesn't fire). The GATE's provider is
/// wired separately with the app's diagnostics sink (`AppVocabCore.commonWords`,
/// main-app only) so a missing list there fails LOUDLY.
///
/// **Per-language.** English is `common-words`; the Parakeet-v3 European set is
/// `common-words-<code>`. A language with no list (`resource == nil`) simply
/// gets no guard, exactly as before per-language lists shipped. The main-app
/// caller maps `LanguageChoice.commonWordsResource`; the keyboard uses the
/// English default (it only ever hints in English).
enum CommonWords {
    static func isCommon(_ word: String, resource: String? = "common-words") -> Bool {
        guard let resource else { return false }
        return BundledCommonWordsProvider.shared.words(forResource: resource).contains(word.lowercased())
    }
}
