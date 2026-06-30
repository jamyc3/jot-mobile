import Foundation

/// Watch-safe mirror of the phone's `LanguageChoice`
/// (`Jot/App/Transcription/LanguageChoice.swift`), trimmed to ONLY what the
/// Apple Watch needs to drive a Digital-Crown language picker and to tag a
/// recording with the language the user spoke in.
///
/// ## Why this file exists (the hard constraint)
/// `LanguageChoice` `import`s **FluidAudio** (for its `fluidAudioLanguage`
/// script-hint accessor). The watchOS target **cannot link FluidAudio**, so it
/// cannot compile `LanguageChoice.swift`. This type re-declares the same
/// language set with NO FluidAudio dependency — Foundation only — so it builds
/// cleanly into `JotWatch`.
///
/// ## Stable-identity contract (must stay lossless)
/// `rawValue` here is byte-for-byte the SAME stable identifier the phone
/// persists to `AppGroup.transcriptionLanguage` (key `jot.transcription.language`)
/// and that `LanguageChoice(rawValue:)` / `LanguageChoice.fromStored(_:)` round-
/// trips. The watch sends `WatchLanguage.code` (== this `rawValue`) over
/// WCSession; the phone feeds it straight into `LanguageChoice.fromStored(_:)`.
/// As long as the case names + spellings match `LanguageChoice`, the mapping is
/// lossless. KEEP THIS LIST IN SYNC with `LanguageChoice` (same set, same
/// codes, same display strings, same presentation order).
enum WatchLanguage: String, CaseIterable, Sendable, Identifiable {
    case english
    // European — Latin script:
    case spanish, french, german, italian, portuguese, romanian,
         polish, czech, slovak, slovenian, croatian, bosnian
    // European — Cyrillic script:
    case russian, ukrainian, belarusian, bulgarian, serbian
    // v3-supported, auto-detect script:
    case danish, dutch, finnish, greek, hungarian, swedish

    var id: String { rawValue }

    /// Stable identifier — the string persisted phone-side in
    /// `AppGroup.transcriptionLanguage`. Identical to `rawValue`; exposed under
    /// a clearer name for the WCSession metadata + local-persistence call sites.
    var code: String { rawValue }

    /// (English name, native endonym). Native == English where there is no
    /// distinct endonym (English). Mirrors `LanguageChoice.names`.
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
        }
    }

    /// English name — the stable sort key.
    var englishName: String { names.english }

    /// Native endonym (may be non-Latin). Shown big on the Crown picker so the
    /// user recognizes their own language at a glance.
    var nativeName: String { names.native }

    /// Picker row label: "English — native" (just the English name when the
    /// endonym is identical, e.g. English). Mirrors `LanguageChoice.displayName`.
    var displayName: String {
        let n = names
        return n.native == n.english ? n.english : "\(n.english) — \(n.native)"
    }

    /// Resolve a stored code (`AppGroup.transcriptionLanguage` value, or a
    /// locally-persisted watch choice) to a `WatchLanguage`. Unknown / `nil`
    /// → `.english` — exactly the phone's `LanguageChoice.fromStored` contract,
    /// so a stale write can never brick the picker.
    static func fromStored(_ raw: String?) -> WatchLanguage {
        guard let raw, let lang = WatchLanguage(rawValue: raw) else { return .english }
        return lang
    }

    /// Alphabetical by English name — the single predictable list the Crown
    /// scrolls through. Mirrors `LanguageChoice.presentationOrder`.
    static var presentationOrder: [WatchLanguage] {
        allCases.sorted {
            $0.englishName.localizedCaseInsensitiveCompare($1.englishName) == .orderedAscending
        }
    }
}

/// Watch-local persistence of the chosen dictation language. Stored in the
/// watch's own `UserDefaults.standard` (the watch app already uses standard
/// defaults for `WatchSyncQueue`; it does NOT share the iOS App Group). The
/// authoritative phone-side value still lives in `AppGroup.transcriptionLanguage`
/// — this is purely so the Crown picker remembers the last choice between
/// launches and so each recording can be tagged.
enum WatchLanguageStore {
    private static let key = "watch.dictationLanguage.v1"

    /// The current watch-chosen language; `.english` when never set.
    static var current: WatchLanguage {
        get { WatchLanguage.fromStored(UserDefaults.standard.string(forKey: key)) }
        set { UserDefaults.standard.set(newValue.code, forKey: key) }
    }
}
