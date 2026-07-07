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

    /// Populate `cached`/`appleCodes` from the live Speech framework APIs.
    /// Idempotent — always resolves against the same live locale set, so
    /// calling it more than once (app launch + a picker's own `.task`) just
    /// re-derives the same answer. Await once before reading `cached`/
    /// `appleCodes` for the first time.
    static func resolve() async {
        let codes = await activeAppleLangCodes()
        appleCodes = codes
        cached = Set(LanguageChoice.allCases.filter { isAvailable($0, appleCodes: codes) })
    }

    /// Language codes the ACTIVE Apple engine on this device actually
    /// supports — `SpeechTranscriber.supportedLocales` when `.isAvailable`
    /// (modern hardware), else `DictationTranscriber.supportedLocales` (the
    /// older/under-6GB-RAM fallback, broader but no `isAvailable` gate of its
    /// own). Cantonese/Mandarin resolve through `Locale.language.languageCode`
    /// the same way `LanguageChoice.fromSystemLocale` already does, so "yue"
    /// and "zh" come out distinct.
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
        let appleCanDo = appleCodes.contains(lang.isoCode)
        let parakeetCanDo = !lang.isAppleOnly && TranscriptionService.parakeetUsable
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
