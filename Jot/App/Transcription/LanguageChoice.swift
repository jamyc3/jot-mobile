import FluidAudio
import Foundation

/// User-facing dictation **language** — the control that backs the Settings
/// language picker (and, later, a wizard step). The user picks a language; the
/// transcription stack resolves the model + the FluidAudio script hint
/// automatically. Mirrors the shipped Jot **Mac** app's `LanguageChoice`
/// (`~/code/jot/Sources/Transcription/LanguageChoice.swift`,
/// `docs/multilingual-dictation/design.md`), trimmed to the mobile bucket set:
/// English + the Parakeet v3 European union, plus four Apple-only languages
/// FluidAudio has no model for at all (Japanese, Korean, Mandarin, Cantonese —
/// see `isAppleOnly`). No Qwen3 / Nemotron on mobile.
///
/// ## Mapping
/// - **English → bundled Parakeet v2** (or the 110M on sub-6GB devices) — the
///   existing device-capability path, **no download**.
/// - **Every European language → Parakeet v3** (one shared multilingual model,
///   downloaded once) + the FluidAudio Latin/Cyrillic script hint where one
///   exists. Languages with no hint case (Danish, Dutch, Finnish, Greek,
///   Hungarian, Swedish) fall back to v3 auto-detect.
/// - **Japanese / Korean / Mandarin / Cantonese → Apple's on-device
///   `SpeechTranscriber`, always** (`isAppleOnly`) — FluidAudio ships no model
///   for these, so there is no fallback engine and no vocabulary rescore.
///
/// ## FIRST PASS scope
/// European resolves to **int8 v3 (`AsrModelVersion.v3`) on every device** — no
/// int4 variant, no device-RAM gating yet (both tracked in the design doc §4,
/// pending an on-device memory measurement). The persisted raw value lives in
/// `AppGroup.transcriptionLanguage`; any unknown/unset tag resolves to
/// `.english`, so a stale write can never brick dictation.
enum LanguageChoice: String, CaseIterable, Sendable, Identifiable {
    case english
    // European — Latin script:
    case spanish, french, german, italian, portuguese, romanian,
         polish, czech, slovak, slovenian, croatian, bosnian
    // European — Cyrillic script:
    case russian, ukrainian, belarusian, bulgarian, serbian
    // v3-supported but no FluidAudio hint case (auto-detect):
    case danish, dutch, finnish, greek, hungarian, swedish
    // Apple-only — FluidAudio has NO model for these at all (not even
    // auto-detect); they route exclusively through Apple's on-device
    // `SpeechTranscriber` (see `isAppleOnly`/`appleLocaleIdentifier` below).
    case japanese, korean, chineseMandarin, cantonese

    var id: String { rawValue }

    /// The active language, resolved from `AppGroup.transcriptionLanguage`.
    /// Unknown / unset / malformed → `.english`.
    static var current: LanguageChoice {
        LanguageChoice(rawValue: AppGroup.transcriptionLanguage) ?? .english
    }

    var isEnglish: Bool { self == .english }

    /// `true` for languages FluidAudio has no model for at all (not bundled,
    /// not v3, not even auto-detect) — these MUST route through Apple's
    /// on-device `SpeechTranscriber` for every pass (streaming + stop-pass),
    /// and MUST NOT fall back to FluidAudio on an Apple failure the way
    /// English's Apple-engine toggle does, because there is no FluidAudio
    /// model to fall back to. `fluidAudioLanguage` is irrelevant/unused for
    /// these.
    var isAppleOnly: Bool {
        switch self {
        case .japanese, .korean, .chineseMandarin, .cantonese: return true
        default: return false
        }
    }

    /// BCP-47 locale identifier for Apple's `SpeechTranscriber`, threaded into
    /// `AppleStreamingSession`/`AppleDictationEngine`. Non-nil for EVERY
    /// language Apple's modern engine actually supports (device-verified:
    /// de/en/es/fr/it/pt/ja/ko/zh/yue) — Apple is the DEFAULT engine for all
    /// of them. `nil` for the European languages Apple can't do (Polish,
    /// Czech, Ukrainian, …), which stay FluidAudio-only.
    var appleLocaleIdentifier: String? {
        switch self {
        case .english:         return "en-US"
        case .spanish:         return "es-ES"
        case .french:          return "fr-FR"
        case .german:          return "de-DE"
        case .italian:         return "it-IT"
        case .portuguese:      return "pt-BR"
        case .japanese:        return "ja-JP"
        case .korean:          return "ko-KR"
        case .chineseMandarin: return "zh-CN"
        case .cantonese:       return "yue-CN"
        default:               return nil
        }
    }

    /// Whether Apple's modern `SpeechTranscriber` supports this language at
    /// all — i.e. Apple is a usable engine for it. The 10 languages with an
    /// `appleLocaleIdentifier`. Apple is the DEFAULT engine for these;
    /// FluidAudio/Parakeet is the optional upgrade where it also exists
    /// (English + the 5 European overlaps) and the ONLY engine for the
    /// European languages Apple lacks.
    var isAppleSupported: Bool { appleLocaleIdentifier != nil }

    /// (English name, native endonym). Native == English where there is no
    /// distinct endonym (English).
    private var names: (english: String, native: String) {
        switch self {
        case .english:    return ("English", "English")
        case .spanish:    return ("Spanish", "Español")
        case .french:     return ("French", "Français")
        case .german:     return ("German", "Deutsch")
        case .italian:    return ("Italian", "Italiano")
        case .portuguese: return ("Portuguese", "Português")
        case .romanian:   return ("Romanian", "Română")
        case .polish:     return ("Polish", "Polski")
        case .czech:      return ("Czech", "Čeština")
        case .slovak:     return ("Slovak", "Slovenčina")
        case .slovenian:  return ("Slovenian", "Slovenščina")
        case .croatian:   return ("Croatian", "Hrvatski")
        case .bosnian:    return ("Bosnian", "Bosanski")
        case .russian:    return ("Russian", "Русский")
        case .ukrainian:  return ("Ukrainian", "Українська")
        case .belarusian: return ("Belarusian", "Беларуская")
        case .bulgarian:  return ("Bulgarian", "Български")
        case .serbian:    return ("Serbian", "Српски")
        case .danish:     return ("Danish", "Dansk")
        case .dutch:      return ("Dutch", "Nederlands")
        case .finnish:    return ("Finnish", "Suomi")
        case .greek:      return ("Greek", "Ελληνικά")
        case .hungarian:  return ("Hungarian", "Magyar")
        case .swedish:    return ("Swedish", "Svenska")
        case .japanese:        return ("Japanese", "日本語")
        case .korean:          return ("Korean", "한국어")
        case .chineseMandarin: return ("Chinese (Mandarin)", "中文（简体）")
        case .cantonese:       return ("Cantonese", "粵語")
        }
    }

    /// English name — the stable sort key.
    var englishName: String { names.english }

    /// Native endonym (may be non-Latin).
    var nativeName: String { names.native }

    /// Picker row label: "English — native" (just the English name when the
    /// endonym is identical, e.g. English).
    var displayName: String {
        let n = names
        return n.native == n.english ? n.english : "\(n.english) — \(n.native)"
    }

    /// The FluidAudio v3 script hint (Latin/Cyrillic filter). `nil` for English
    /// (v2 is monolingual and ignores it) and for European languages with no
    /// hint case (auto-detect). Only the v3 European paths exercise the filter.
    var fluidAudioLanguage: Language? {
        switch self {
        case .english:    return nil
        case .spanish:    return .spanish
        case .french:     return .french
        case .german:     return .german
        case .italian:    return .italian
        case .portuguese: return .portuguese
        case .romanian:   return .romanian
        case .polish:     return .polish
        case .czech:      return .czech
        case .slovak:     return .slovak
        case .slovenian:  return .slovenian
        case .croatian:   return .croatian
        case .bosnian:    return .bosnian
        case .russian:    return .russian
        case .ukrainian:  return .ukrainian
        case .belarusian: return .belarusian
        case .bulgarian:  return .bulgarian
        case .serbian:    return .serbian
        // v3-supported but no FluidAudio hint case → auto-detect.
        case .danish, .dutch, .finnish, .greek, .hungarian, .swedish:
            return nil
        // Apple-only — FluidAudio has no model at all, so there is no
        // script hint to give it; these never reach a FluidAudio call.
        case .japanese, .korean, .chineseMandarin, .cantonese:
            return nil
        }
    }

    /// ISO-639 language code (e.g. `"en"`, `"fr"`). Inverse of
    /// `fromLanguageCode`. Used by the Translate sheet to exclude the
    /// transcript's own language from the target list and to pass a source-
    /// language hint to Apple Translation.
    var isoCode: String {
        switch self {
        case .english:    return "en"
        case .spanish:    return "es"
        case .french:     return "fr"
        case .german:     return "de"
        case .italian:    return "it"
        case .portuguese: return "pt"
        case .romanian:   return "ro"
        case .polish:     return "pl"
        case .czech:      return "cs"
        case .slovak:     return "sk"
        case .slovenian:  return "sl"
        case .croatian:   return "hr"
        case .bosnian:    return "bs"
        case .russian:    return "ru"
        case .ukrainian:  return "uk"
        case .belarusian: return "be"
        case .bulgarian:  return "bg"
        case .serbian:    return "sr"
        case .danish:     return "da"
        case .dutch:      return "nl"
        case .finnish:    return "fi"
        case .greek:      return "el"
        case .hungarian:  return "hu"
        case .swedish:    return "sv"
        case .japanese:        return "ja"
        case .korean:          return "ko"
        case .chineseMandarin: return "zh"
        case .cantonese:       return "yue"
        }
    }

    /// Resolve a stored `Transcript.language` raw value (or `nil`) to a
    /// `LanguageChoice`, treating unknown/`nil` as English (multilingual
    /// dictation only just shipped, so historical rows are English).
    static func fromStored(_ raw: String?) -> LanguageChoice {
        guard let raw, let lang = LanguageChoice(rawValue: raw) else { return .english }
        return lang
    }

    /// Alphabetical by English name — a single predictable list (the picker can
    /// add type-to-search later).
    static var presentationOrder: [LanguageChoice] {
        allCases.sorted {
            $0.englishName.localizedCaseInsensitiveCompare($1.englishName) == .orderedAscending
        }
    }

    // MARK: - Recent languages (MRU quick-switch)

    private static let recentsKey = "jot.dictation.recentLanguages"

    /// How many recent languages the picker surfaces at the top.
    static let maxRecents = 5

    /// Most-recently-used dictation languages (≤ `maxRecents`), the active one
    /// always first. Shared across the wizard + Settings pickers via the App
    /// Group, so it's consistent everywhere and survives app updates. The active
    /// language is forced to the front so the list always reflects the current
    /// selection even if it was set outside the picker (watch, deep link).
    static var recentLanguages: [LanguageChoice] {
        let stored = (AppGroup.defaults.stringArray(forKey: recentsKey) ?? [])
            .compactMap { LanguageChoice(rawValue: $0) }
        var list = stored
        let active = current
        list.removeAll { $0 == active }
        list.insert(active, at: 0)
        return Array(list.prefix(maxRecents))
    }

    /// Move `language` to the front of the recents list (cap `maxRecents`).
    /// Call whenever the user selects a dictation language.
    static func recordRecent(_ language: LanguageChoice) {
        var raws = AppGroup.defaults.stringArray(forKey: recentsKey) ?? []
        raws.removeAll { $0 == language.rawValue }
        raws.insert(language.rawValue, at: 0)
        AppGroup.defaults.set(Array(raws.prefix(maxRecents)), forKey: recentsKey)
    }

    /// Seed the current language into the recents on first ever use, so the
    /// first language switch still keeps the prior (default) language visible.
    /// Idempotent — a no-op once anything has been recorded.
    static func seedRecentsIfNeeded() {
        let stored = AppGroup.defaults.stringArray(forKey: recentsKey) ?? []
        if stored.isEmpty { recordRecent(current) }
    }

    /// Default language from the system locale, falling back to `.english` when
    /// the locale isn't a supported transcription language. (Not wired as the
    /// persisted default in the first pass — kept for the wizard step.)
    static func fromSystemLocale(_ locale: Locale = .current) -> LanguageChoice {
        guard let code = locale.language.languageCode?.identifier.lowercased() else {
            return .english
        }
        return fromLanguageCode(code) ?? .english
    }

    /// Map an ISO-639 code (e.g. `"de"`) to a `LanguageChoice`; `nil` if
    /// unsupported.
    static func fromLanguageCode(_ code: String) -> LanguageChoice? {
        switch code.lowercased() {
        case "en": return .english
        case "es": return .spanish
        case "fr": return .french
        case "de": return .german
        case "it": return .italian
        case "pt": return .portuguese
        case "ro": return .romanian
        case "pl": return .polish
        case "cs": return .czech
        case "sk": return .slovak
        case "sl": return .slovenian
        case "hr": return .croatian
        case "bs": return .bosnian
        case "ru": return .russian
        case "uk": return .ukrainian
        case "be": return .belarusian
        case "bg": return .bulgarian
        case "sr": return .serbian
        case "da": return .danish
        case "nl": return .dutch
        case "fi": return .finnish
        case "el": return .greek
        case "hu": return .hungarian
        case "sv": return .swedish
        case "ja": return .japanese
        case "ko": return .korean
        case "zh": return .chineseMandarin
        case "yue": return .cantonese
        default:   return nil
        }
    }
}
