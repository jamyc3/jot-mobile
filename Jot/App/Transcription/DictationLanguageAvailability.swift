import Speech
import Foundation

/// Resolves which `LanguageChoice`s actually work on THIS device, computed
/// from LIVE runtime capability — never a hardcoded device list. RULE #1:
/// never show a dictation language, or a "download Parakeet" affordance, that
/// can't actually work here. E.g. the 2020 A12Z iPad Pro can't run the newer
/// `SpeechTranscriber` (falls back to the older, narrower `DictationTranscriber`)
/// AND can't run FluidAudio's Parakeet at all (`TranscriptionService.parakeetUsable`)
/// — so its working language set is much smaller than a modern iPhone's.
///
/// Mirrors `TranscriptionService.appleEngineIsSpeechTranscriber` for which
/// Apple engine is ACTIVE on this hardware (same branch the real transcribe
/// path uses) rather than re-deriving a second capability check — this
/// resolver just asks that engine which languages it actually supports here,
/// instead of trusting `LanguageChoice.isAppleSupported`'s static list.
///
/// Named `DictationLanguageAvailability` (not the shorter `LanguageAvailability`)
/// because Apple's own `Translation` framework already exports a type called
/// `LanguageAvailability` (`TranslationGateway.swift`) — same module, so the
/// shorter name collides and picks the wrong one.
@MainActor
enum DictationLanguageAvailability {
    /// The full set of `LanguageChoice`s usable on this device, once
    /// resolved. `nil` until the first `resolve()` completes — callers
    /// should show the FULL list while nil rather than an empty picker.
    private(set) static var cached: Set<LanguageChoice>?

    /// ISO-639 codes (`LanguageChoice.isoCode`) the ACTIVE Apple engine
    /// supports on this device, from the most recent `resolve()`.
    private(set) static var appleCodes: Set<String> = []

    /// The `isAppleOnly` languages whose EXACT `appleLocaleIdentifier` resolves
    /// to a real supported locale on this device (equivalence-aware, via the
    /// same `supportedLocale(equivalentTo:)` check the reservation path uses),
    /// from the most recent `resolve()`. Keyed on the full identifier — NOT the
    /// reduced `isoCode` — so Cantonese (Hong Kong)=`zh-HK` and Cantonese
    /// (Mainland China)=`yue-CN` are distinguished even though they share
    /// isoCode "yue", and each row shows iff Apple can actually run it here.
    private(set) static var appleOnlyAvailable: Set<LanguageChoice> = []

    /// Populate `cached`/`appleCodes`/`appleOnlyAvailable` from the live Speech
    /// framework APIs. Idempotent — always resolves against the same live
    /// locale set, so calling it more than once (app launch + a picker's own
    /// `.task`) just re-derives the same answer. Await once before reading the
    /// cached values for the first time.
    static func resolve() async {
        let codes = await activeAppleLangCodes()
        appleCodes = codes
        // Precompute the Apple-only rows' availability by exact-locale
        // equivalence (async, so it can't live inside the sync `isAvailable`).
        var appleOnly: Set<LanguageChoice> = []
        for lang in LanguageChoice.allCases where lang.isAppleOnly {
            if await appleSupportsExactLocale(lang) { appleOnly.insert(lang) }
        }
        appleOnlyAvailable = appleOnly
        cached = Set(LanguageChoice.allCases.filter { isAvailable($0, appleCodes: codes) })
    }

    /// Whether the ACTIVE Apple engine supports `lang`'s exact
    /// `appleLocaleIdentifier` here, using Apple's own equivalence resolver
    /// (`supportedLocale(equivalentTo:)`) — the SAME check
    /// `AppleStreamingSession.resolveReservedLocale` runs before reserving, so
    /// availability can't disagree with what the record path will actually do.
    private static func appleSupportsExactLocale(_ lang: LanguageChoice) async -> Bool {
        guard let identifier = lang.appleLocaleIdentifier else { return false }
        let requested = Locale(identifier: identifier)
        if TranscriptionService.appleEngineIsSpeechTranscriber {
            return await SpeechTranscriber.supportedLocale(equivalentTo: requested) != nil
        } else {
            return await DictationTranscriber.supportedLocale(equivalentTo: requested) != nil
        }
    }

    /// Language codes the ACTIVE Apple engine on this device actually
    /// supports — `SpeechTranscriber.supportedLocales` when `.isAvailable`
    /// (modern hardware), else `DictationTranscriber.supportedLocales` (the
    /// older/under-6GB-RAM fallback, broader but no `isAvailable` gate of its
    /// own). Gates the NON-Apple-only languages (Latin/Cyrillic codes shared
    /// with Parakeet). The Apple-only rows (CJK / Cantonese) are gated
    /// separately by exact-locale equivalence in `appleSupportsExactLocale`,
    /// not by this reduced code set.
    private static func activeAppleLangCodes() async -> Set<String> {
        let locales = TranscriptionService.appleEngineIsSpeechTranscriber
            ? await SpeechTranscriber.supportedLocales
            : await DictationTranscriber.supportedLocales
        return Set(locales.compactMap { $0.language.languageCode?.identifier })
    }

    /// Whether `lang` can be transcribed on this device at all — by the
    /// active Apple engine, or by Parakeet (every language except the 4
    /// Apple-only CJK ones has a FluidAudio model, but only on a device
    /// where Parakeet can actually run — see `TranscriptionService.parakeetUsable`).
    static func isAvailable(_ lang: LanguageChoice, appleCodes: Set<String>) -> Bool {
        // Apple-only rows (no Parakeet model exists): gated on their EXACT
        // `appleLocaleIdentifier` resolving to a supported locale here
        // (precomputed by `resolve()`), not the reduced `isoCode` — so a shared
        // isoCode (both Cantonese rows are "yue") can't make one row borrow the
        // other's availability. Reads the resolved static set; callers await
        // `resolve()` before filtering, so it is populated.
        if lang.isAppleOnly {
            return appleOnlyAvailable.contains(lang)
        }
        // Non-Apple-only languages: unchanged languageCode-based gating.
        let appleCanDo = appleCodes.contains(lang.isoCode)
        let parakeetCanDo = TranscriptionService.parakeetUsable
        return appleCanDo || parakeetCanDo
    }

    /// Does picking `lang` need OUR OWN Parakeet-download affordance on this
    /// device? Only when the active Apple engine genuinely can't do it here
    /// (Apple's own asset handling is separate and silent — never our UI to
    /// show) AND Parakeet can AND it isn't English (bundled v2, never
    /// downloads).
    static func usesParakeetDownload(_ lang: LanguageChoice, appleCodes: Set<String>) -> Bool {
        !appleCodes.contains(lang.isoCode)
            && !lang.isAppleOnly
            && TranscriptionService.parakeetUsable
            && !lang.isEnglish
    }
}
