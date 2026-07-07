import Foundation

/// Device-capability resolution for batch-only streaming
/// (`docs/plans/batch-only-streaming.md`, FINAL DIRECTION).
///
/// One boolean, RAM-gated — deliberately NOT a device-ID table (future
/// devices auto-qualify; no list to maintain).
enum DeviceCapability {

    /// 6 GB-RAM class and up = iPhone 12 Pro / 14 and later — the
    /// functional line for the 600M model (~2 GB resident at inference).
    ///
    /// `physicalMemory` reports BELOW nominal (kernel carve-out): 6 GB
    /// devices report ~5.5–5.9e9, 4 GB ~3.7e9. The 4.6e9 threshold splits
    /// the classes with uniform margin (adversarial review #2 F3 — a naive
    /// `>= 6e9` could misclassify real 6 GB hardware). Calibrate against
    /// the Diagnostics `physicalMemory` log before tightening.
    ///
    /// NOTE the two-line policy (owner): OFFICIAL support is iPhone 14 Pro
    /// and later (Store/Help copy promises only that); this gate is the
    /// backward-compatibility functional line — the 12 Pro → 14 Plus band
    /// works best-effort, unsupported.
    static var is600MCapable: Bool {
        ProcessInfo.processInfo.physicalMemory >= 4_600_000_000
    }

    /// Curated hardware-tier floor for Parakeet: **iPhone 14 Pro+ and
    /// iPad M1+ only** — the owner's exact cutoff. This is deliberately
    /// NARROWER than `is600MCapable`: Parakeet's CoreML model actually
    /// LOADS on some devices below this line (iPhone 12 Pro / 13 Pro both
    /// have 6GB RAM and build the model fine) but the owner wants those
    /// devices on Apple's engine only, not Jot's own. So unlike
    /// `is600MCapable` (a RAM measurement), this genuinely IS a device-ID
    /// table — by design, per the curated cutoff, not something to
    /// generalize away.
    ///
    /// Parses the raw device-model string (`hw.machine` on a real device,
    /// `SIMULATOR_MODEL_IDENTIFIER` on the simulator — e.g. `"iPhone15,2"`,
    /// `"iPad13,4"`) into (idiom, major). `major` is the number before the
    /// comma, Apple's model-generation counter — monotonic within each
    /// idiom, so a single `>=` threshold per idiom captures "this
    /// generation and every later one" with no future devices to add.
    ///
    /// **iPhone major ≥ 15** = 14 Pro and later:
    /// - iPhone15,2 / 15,3 = 14 Pro / 14 Pro Max — first INCLUDED gen.
    /// - iPhone14,7 / 14,8 = 14 / 14 Plus (non-Pro) — excluded.
    /// - iPhone14,2 / 14,3 = 13 Pro / 13 Pro Max — excluded.
    /// - iPhone13,3 / 13,4 = 12 Pro / 12 Pro Max — excluded (this is the
    ///   device the owner explicitly wants OFF Parakeet despite it having
    ///   6GB RAM and loading the model fine).
    ///
    /// **iPad major ≥ 13** = M1 and later:
    /// - iPad13,4–13,7 = 11"/12.9" iPad Pro (M1, 2021) — first INCLUDED gen.
    /// - iPad8,1–8,12 = 2018 (A12X) / 2020 (A12Z) iPad Pro — excluded (the
    ///   A12Z is the device that can't actually BUILD Parakeet's CoreML
    ///   model at all, despite 6GB RAM — the original motivation for this
    ///   whole tier floor).
    /// - iPad13,1/13,2 (Air 4, A14) and iPad13,18/13,19 (10th-gen) also
    ///   fall in the ≥13 major band but are NOT M-series and have 4GB RAM
    ///   on most configurations — the `is600MCapable` RAM floor (always
    ///   AND'd alongside this one, see `TranscriptionService.parakeetUsable`)
    ///   is what excludes them; this property alone doesn't need to.
    ///
    /// Anything that doesn't parse as `"iPhoneN,M"` or `"iPadN,M"` (Mac
    /// Catalyst, an unset simulator env var) returns `true` — no known
    /// false-positive on that branch, and `is600MCapable` is the real gate
    /// there regardless.
    static var parakeetTierDevice: Bool {
        guard let (idiom, major) = parsedDeviceModel else { return true }
        switch idiom {
        case .iPhone: return major >= 15
        case .iPad: return major >= 13
        }
    }

    private enum DeviceIdiom {
        case iPhone
        case iPad
    }

    /// (idiom, major) parsed from `hw.machine` / `SIMULATOR_MODEL_IDENTIFIER`.
    /// `nil` for anything that isn't a recognized `"iPhoneN,M"` /
    /// `"iPadN,M"` model string.
    private static var parsedDeviceModel: (idiom: DeviceIdiom, major: Int)? {
        let machine: String
        #if targetEnvironment(simulator)
        machine = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        #else
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        machine = String(cString: buffer)
        #endif

        let idiom: DeviceIdiom
        let prefix: String
        if machine.hasPrefix("iPhone") {
            idiom = .iPhone
            prefix = "iPhone"
        } else if machine.hasPrefix("iPad") {
            idiom = .iPad
            prefix = "iPad"
        } else {
            return nil
        }
        let rest = machine.dropFirst(prefix.count)
        guard let comma = rest.firstIndex(of: ","), let major = Int(rest[rest.startIndex..<comma]) else {
            return nil
        }
        return (idiom, major)
    }

    /// Resolved "Live text while dictating" state. Explicit user choice
    /// (`"on"`/`"off"`) always wins; `"auto"` follows the capability
    /// default so a future revision of the default reaches auto users
    /// without clobbering anyone's choice (review #2 F8).
    ///
    /// Read at recording start (never mid-session). Ask captures bypass
    /// this — their live text is the input mechanism, not a preview.
    static var liveTextEnabled: Bool {
        switch AppGroup.liveTextSetting {
        case "on": return true
        case "off": return false
        default: return is600MCapable
        }
    }
}
