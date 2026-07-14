import Foundation
import os.log

/// The bundled high-frequency English word set used by the vocabulary gate's
/// **common-word guard** (`VocabularyGate`). A custom vocabulary correction is
/// never allowed to silently overwrite a word in this set — that is what stops
/// "name" → "Jamy" and "cloud" → "Claude" on confident, correct words.
///
/// Asset: `Resources/common-words.txt` — the top ~24k English words by
/// frequency, **with popular given names removed** so a name a user adds to
/// vocab (Jamie, John, Sarah…) is NOT treated as an untouchable common word and
/// can be learned/applied. Names were stripped via SSA name-popularity (peak
/// share ≥ 0.005) minus a curated dual-meaning allowlist (may/will/mark/rose/
/// grace/april… stay protected — they're common words that happen to also be
/// names). The removed list is audited in
/// `docs/plans/correction-review-names-excluded.txt`. This is a *universal*
/// signal (works for every user, no per-term computation); see
/// docs/plans/adaptive-vocabulary-correction.md §3.2.
///
/// **Per-language.** The vocabulary CTC correction runs for every non-Apple-only
/// language (English + the Parakeet-v3 European union), so the common-word guard
/// needs the RIGHT language's list — an English list can't protect an everyday
/// Spanish word. Each language's list is loaded lazily and cached; only the
/// language(s) actually dictated in are ever read into memory (one set at a time
/// in practice), which keeps this cheap on the memory-constrained keyboard.
/// English is `common-words.txt`; the European set is `common-words-<code>.txt`.
/// A language with no list (`commonWordsResource == nil` — Belarusian, the
/// Apple-only CJK languages) simply gets no common-word guard, exactly as every
/// non-English language did before per-language lists shipped.
enum CommonWords {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot", category: "VocabularyGate")
    private static let lock = NSLock()
    /// Lazily-loaded sets keyed by resource base name. `nonisolated(unsafe)`:
    /// all access goes through `set(forResource:)` under `lock`, so the mutation
    /// is manually serialized (the compiler can't see the lock invariant).
    private nonisolated(unsafe) static var cache: [String: Set<String>] = [:]

    /// Is `word` an everyday word in the list named `resource`
    /// (`<resource>.txt` in the bundle)? False when `resource` is nil (no list
    /// ships for that language — the guard then degrades to plausibility/
    /// confidence, still safe). Takes the resource NAME rather than a
    /// `LanguageChoice` on purpose: this type is compiled into the keyboard
    /// extension, which must not link FluidAudio (`LanguageChoice` does). The
    /// main-app caller maps `LanguageChoice.commonWordsResource`; the keyboard
    /// uses the English default (it only bundles `common-words.txt`).
    static func isCommon(_ word: String, resource: String? = "common-words") -> Bool {
        guard let resource else { return false }
        return set(forResource: resource).contains(word.lowercased())
    }

    private static func set(forResource resource: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[resource] { return cached }
        let loaded = load(resource)
        cache[resource] = loaded
        return loaded
    }

    private static func load(_ resource: String) -> Set<String> {
        guard
            let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            log.error("\(resource, privacy: .public).txt NOT found in bundle — common-word guard DISABLED for it")
            return []
        }
        let set = Set(text.split(separator: "\n").map { String($0).lowercased() })
        log.info("common-words[\(resource, privacy: .public)] loaded: \(set.count, privacy: .public) words")
        return set
    }
}
