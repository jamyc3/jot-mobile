import Foundation

/// Post-transcription number normalizer. Pure enum with no I/O — safe
/// to call from any batch-transcription path (in-app hero, keyboard,
/// wizard mic test, Shortcuts intent, etc.).
///
/// This runs AFTER `FillerWordCleaner.clean(...)` so filler-strip can
/// never split a multi-word spelled cardinal (e.g. "twenty uh five")
/// before we walk it.
///
/// Deterministic, AP-style-ish rules — converts spelled numbers in
/// transcripts to digits when the context calls for digits, leaves
/// idioms / ordinals / single-digit cardinals alone, and bails out on
/// anything that looks like a dictated phone number. Any number-word
/// sequence that contains the scale word `million`, `billion`, or
/// `trillion` is left as words (top-priority pass-through, overrides
/// money/percent/cardinal rules). Always on; no toggle. Pure Foundation.
enum NumberNormalizer {

    // MARK: - Public entry point

    /// Walk `text` token-by-token, identify maximal spelled-cardinal
    /// sequences, and rewrite each one according to the first matching
    /// context rule (money, percent, year, time-of-day, address,
    /// cardinal-≥-10). Whitespace, punctuation, and paragraph breaks
    /// (`\n\n`) are preserved.
    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }

        // Phone-shape guard: if anywhere in the text we see ≥7
        // consecutive spelled single-digit words, bail out entirely.
        // Phone numbers are out of scope for v1.
        if containsPhoneShape(tokens) { return text }

        var out: [Token] = []
        out.reserveCapacity(tokens.count)

        var i = 0
        while i < tokens.count {
            let tok = tokens[i]

            // Top-priority pass-through: any word token that IS or
            // CONTAINS a large-scale word (million/billion/trillion) is
            // emitted verbatim. Catches the standalone case ("million"
            // alone, "300 million" where "300" is .other and "million"
            // is reached on its own) and prevents the cardinal branch
            // from trying to convert a bare scale word into 1,000,000.
            if tok.kind == .word, isLargeScaleToken(tok.core) {
                out.append(tok)
                i += 1
                continue
            }

            // DATE: MONTH + day-ordinal → "Month Nth". Runs before the
            // tens-ordinal combiner so an invalid day ("March
            // thirty-second") is emitted verbatim rather than
            // half-converted into a fake "32nd". A trailing year folds
            // in for free on the next iteration (the hyphenated year
            // rule catches "July fourth twenty twenty-six" → "2026").
            if tok.kind == .word,
               let maxDay = monthDayMax[tok.core.lowercased()],
               !tok.hasTrailingPunct,
               monthDateAllowed(tok),
               let ws = nextNonWhitespace(after: i, tokens: tokens),
               let day = parseDayOrdinal(tokens: tokens, start: ws.index) {
                if day.value >= 1, day.value <= maxDay {
                    // Valid date → "Month Nth".
                    out.append(tok)
                    for k in (i + 1)..<ws.index { out.append(tokens[k]) }
                    let rendered = renderOrdinal(day.value)
                    out.append(Token(
                        kind: .word,
                        raw: rendered,
                        core: rendered,
                        leading: "",
                        trailing: tokens[day.endExclusive - 1].trailing
                    ))
                    i = day.endExclusive
                    continue
                } else {
                    // Day out of range for this month → not a real date.
                    // Emit month + ordinal verbatim so the combiner never
                    // manufactures a fake day number.
                    for k in i..<day.endExclusive { out.append(tokens[k]) }
                    i = day.endExclusive
                    continue
                }
            }

            // Tens-ordinal combiner. Runs BEFORE the cardinal branch so
            // it can handle ordinal forms ("twenty-third", "twentieth")
            // that the main cardinal branch deliberately skips. Also
            // catches the split form "twenty third" so we don't emit
            // "20 third street". Falls through if no rewrite applies.
            if tok.kind == .word,
               let combined = parseTensOrdinal(tokens: tokens, start: i) {
                let lastIdx = max(0, min(combined.endExclusive - 1, tokens.count - 1))
                out.append(Token(
                    kind: .word,
                    raw: combined.text,
                    core: combined.text,
                    leading: "",
                    trailing: tokens[lastIdx].trailing
                ))
                i = combined.endExclusive
                continue
            }

            // Only words (not whitespace/punctuation) can open a
            // spelled-cardinal run. Ordinals stop the walker
            // immediately so we never fold them into a cardinal run.
            if tok.kind == .word,
               !isOrdinal(tok.core),
               cardinalWords[tok.core.lowercased().split(separator: "-").first.map(String.init) ?? ""] != nil
                || isSplittableCardinalWord(tok.core) {

                let prevWordLower = previousWord(in: out)?.lowercased()

                // Year-shape detection FIRST. These paired-halves
                // shapes ("nineteen ninety-eight", "twenty twenty-six")
                // are NOT valid normal cardinals and the standard parser
                // would split them ("19 98"), so we resolve them up front.
                // Gating (precision over recall):
                //  - hyphenated tens+ones low half ("twenty-four") is an
                //    unambiguous year → fire on shape alone;
                //  - any other low half needs an immediate temporal
                //    context word and must not be a bare 1-9 (blocks
                //    "room twenty one" → 2001, "twenty four seven");
                //  - "two thousand" forms always require context.
                if let yr = parseYearShape(tokens: tokens, start: i) {
                    let ctx = isYearContext(prevWordLower: prevWordLower)
                    let fire: Bool
                    switch yr.kind {
                    case .twoThousand:
                        fire = ctx
                    case .pairedHalves(let lowHyphenated, let lowBareOnes):
                        fire = lowHyphenated || (ctx && !lowBareOnes)
                    }
                    if fire {
                        let trailing = tokens[yr.endExclusive - 1].trailing
                        out.append(Token(
                            kind: .word,
                            raw: String(yr.value),
                            core: String(yr.value),
                            leading: "",
                            trailing: trailing
                        ))
                        i = yr.endExclusive
                        continue
                    }
                }

                // Address-digit-sequence detection — only when prev
                // word is an address-context word. Greedily consume
                // a run of single-digit words ("four oh seven") and
                // emit the literal digit string. Falls back to the
                // standard cardinal parser otherwise (e.g. "two
                // hundred and three" → 203).
                if let prev = prevWordLower,
                   addressContextWords.contains(prev),
                   let addr = parseAddressDigitRun(tokens: tokens, start: i) {
                    let trailing = tokens[addr.endExclusive - 1].trailing
                    out.append(Token(
                        kind: .word,
                        raw: addr.digits,
                        core: addr.digits,
                        leading: "",
                        trailing: trailing
                    ))
                    i = addr.endExclusive
                    continue
                }

                if let parsed = parseCardinalSequence(tokens: tokens, start: i) {
                    let endExclusive = i + parsed.consumed

                    // DECIMAL: <integer-cardinal> "point" <digit>+ [unit].
                    // Narrowed rule (Codex round 1): require an integer
                    // cardinal immediately BEFORE "point" AND a digit word
                    // immediately after; parse forward; no leading decimals;
                    // reject newline/sentence-punctuation crossings. This
                    // single "spelled digit right after point" condition is
                    // the entire idiom guard.
                    if let dec = parseDecimalTail(
                        integerValue: parsed.value,
                        cardinalEndExclusive: endExclusive,
                        tokens: tokens
                    ) {
                        out.append(Token(
                            kind: .word,
                            raw: dec.text,
                            core: dec.text,
                            leading: "",
                            trailing: dec.trailing
                        ))
                        i = dec.consumedUpTo
                        continue
                    }

                    // Top-priority pass-through: if the parsed sequence
                    // includes million/billion/trillion (e.g.
                    // "twenty-five million", "two million users", or a
                    // hyphenated compound containing one), emit every
                    // token in the run verbatim. Overrides money,
                    // percent, and cardinal rules.
                    if sequenceContainsLargeScale(parsed.sequence) {
                        for k in i..<endExclusive {
                            out.append(tokens[k])
                        }
                        i = endExclusive
                        continue
                    }

                    let result = rewriteSequence(
                        sequence: parsed.sequence,
                        value: parsed.value,
                        startIndex: i,
                        endExclusive: endExclusive,
                        tokens: tokens,
                        prevWordLower: prevWordLower,
                        outSoFar: &out
                    )

                    if let result = result {
                        let lastIdx = max(0, min(result.consumedUpTo - 1, tokens.count - 1))
                        let trailing = tokens[lastIdx].trailing
                        out.append(Token(
                            kind: .word,
                            raw: result.text,
                            core: result.text,
                            leading: "",
                            trailing: trailing
                        ))
                        i = result.consumedUpTo
                        continue
                    }

                    // Idiom / skip: emit the original tokens verbatim.
                    for k in i..<endExclusive {
                        out.append(tokens[k])
                    }
                    i = endExclusive
                    continue
                }
            }

            out.append(tok)
            i += 1
        }

        return reassemble(out)
    }

    // MARK: - Token model

    /// A lightweight token. `raw` is the exact original substring
    /// (without leading whitespace — whitespace lives in its own
    /// `.whitespace` token). `core` strips trailing punctuation so we
    /// can match number-words cleanly. `trailing` is any trailing
    /// punctuation that was stripped (e.g. "twenty-five," →
    /// core="twenty-five", trailing=",") and is reattached on
    /// reassembly. `hasTrailingPunct` is a convenience flag the parser
    /// uses to know it MUST stop here (the punctuation ends the
    /// sequence in the input — we can't merge across it).
    struct Token {
        enum Kind { case word, whitespace, other }
        let kind: Kind
        var raw: String
        var core: String
        var leading: String
        var trailing: String
        var hasTrailingPunct: Bool { !trailing.isEmpty }
    }

    /// Result of a single context-rewrite. `text` is the digit form to
    /// emit; `consumedUpTo` is the EXCLUSIVE token index the main loop
    /// should advance past (covers both the cardinal sequence and any
    /// consumed unit/meridiem tokens).
    private struct Rewrite {
        let text: String
        let consumedUpTo: Int
    }

    /// Characters that may attach to the trailing edge of a word and
    /// that we strip into `Token.trailing` for clean matching.
    private static let trailingPunct: Set<Character> = [
        ",", ".", "!", "?", ";", ":", "\"", "'", ")", "]", "}", "”", "’", "»"
    ]

    /// Pure-text tokenizer. Splits on whitespace runs but preserves
    /// the EXACT whitespace (so we keep "\n\n" paragraph breaks) by
    /// emitting a `.whitespace` token between words.
    private static func tokenize(_ text: String) -> [Token] {
        var out: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace || c.isNewline {
                let start = i
                while i < text.endIndex,
                      text[i].isWhitespace || text[i].isNewline {
                    i = text.index(after: i)
                }
                out.append(Token(
                    kind: .whitespace,
                    raw: String(text[start..<i]),
                    core: "",
                    leading: "",
                    trailing: ""
                ))
                continue
            }
            let start = i
            while i < text.endIndex,
                  !text[i].isWhitespace,
                  !text[i].isNewline {
                i = text.index(after: i)
            }
            var raw = String(text[start..<i])
            var trailing = ""
            while let last = raw.last, trailingPunct.contains(last) {
                trailing.insert(last, at: trailing.startIndex)
                raw.removeLast()
            }
            if raw.isEmpty {
                out.append(Token(
                    kind: .other, raw: trailing, core: trailing,
                    leading: "", trailing: ""
                ))
            } else {
                let kind: Token.Kind = isWordish(raw) ? .word : .other
                out.append(Token(
                    kind: kind, raw: raw, core: raw,
                    leading: "", trailing: trailing
                ))
            }
        }
        return out
    }

    /// True if `s` is a hyphen/letter/apostrophe-only string — i.e.
    /// looks like a single English word ("twenty-five", "o'clock").
    private static func isWordish(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for c in s {
            if !(c.isLetter || c == "-" || c == "'" || c == "’") { return false }
        }
        return true
    }

    /// Reassemble tokens into a single string. Whitespace tokens are
    /// emitted verbatim; word/other tokens are emitted as `core` +
    /// `trailing`.
    private static func reassemble(_ tokens: [Token]) -> String {
        var out = ""
        out.reserveCapacity(tokens.reduce(0) { $0 + $1.raw.count + $1.trailing.count })
        for t in tokens {
            switch t.kind {
            case .whitespace:
                out += t.raw
            case .word, .other:
                out += t.core
                out += t.trailing
            }
        }
        return out
    }

    // MARK: - Vocabulary

    /// Word → numeric value table for spelled cardinals. "oh" is
    /// treated as 0 only inside an address context (rule 5); the
    /// parser accepts it in any sequence but the context-checker
    /// rejects sequences containing "oh" when not in address mode.
    private static let cardinalWords: [String: Int] = [
        "zero": 0, "oh": 0,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "hundred": 100, "thousand": 1_000, "million": 1_000_000
    ]

    /// Subset of `cardinalWords` containing only the single-digit
    /// words. Used by the phone-shape guard.
    private static let singleDigitWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five",
        "six", "seven", "eight", "nine"
    ]

    /// Word-form ordinals we explicitly preserve. Detection also falls
    /// back on a "ends with -st/-nd/-rd/-th" suffix check and a
    /// "hyphen-compound whose tail is an ordinal" check.
    private static let ordinalWords: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth",
        "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth",
        "thirteenth", "fourteenth", "fifteenth", "sixteenth",
        "seventeenth", "eighteenth", "nineteenth", "twentieth",
        "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth",
        "eightieth", "ninetieth", "hundredth", "thousandth", "millionth"
    ]

    /// Address-context preceding words (lowercased). Triggers literal
    /// digit conversion for the following spelled-out sequence,
    /// including treating "oh" as 0.
    private static let addressContextWords: Set<String> = [
        "apartment", "apt", "room", "suite", "floor", "building",
        "unit", "office"
    ]

    /// Year-context preceding words (lowercased) — when one of these
    /// precedes a "twenty NN" / "nineteen NN" / "two thousand NN"
    /// sequence we apply the year rule.
    private static let yearContextWords: Set<String> = [
        "in", "since", "back", "year", "from", "until", "before", "after",
        "of", "to", "by",
        // Seasonal cues — "summer twenty twenty-five" → "summer 2025".
        "summer", "winter", "spring", "fall", "autumn"
    ]

    /// Duration/measure nouns that, right after "<tens> second", mark
    /// "second" as the time UNIT, not the ordinal — so "thirty second
    /// timeout" is a 30-second duration, not "32nd". Keeps the ordinal
    /// reading for places/positions ("thirty second avenue" → "32nd").
    private static let durationNounsAfterSecond: Set<String> = [
        "timeout", "timeouts", "delay", "delays", "pause", "pauses",
        "window", "interval", "intervals", "break", "gap", "timer",
        "countdown", "wait", "clip", "clips", "video", "videos", "ad",
        "ads", "buffer", "cooldown", "lull", "mark", "burst", "sprint",
        "warning", "head", "start", "rule", "silence", "loop"
    ]

    /// Century-lead words that can open a paired-halves year shape.
    /// "fourteen ninety-two" → 1400 + 92 = 1492 … "twenty twenty-four"
    /// → 2000 + 24 = 2024. Value is the century multiplier's hundreds
    /// digit (fourteen → 14 → base 1400).
    private static let centuryLeadWords: [String: Int] = [
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19, "twenty": 20
    ]

    /// Months — also trigger year context ("January nineteen
    /// ninety-eight" → "January 1998").
    private static let monthWords: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december"
    ]

    /// Words that, when they precede a single small cardinal (1–9),
    /// trigger the sub-10 time-of-day override ("at four" → "at 4").
    private static let timePrecedingWords: Set<String> = [
        "at", "by", "around", "about"
    ]

    /// Phone-shape detection threshold — ≥ this many consecutive
    /// spelled single-digit words anywhere in the input causes the
    /// normalizer to bail out wholesale.
    private static let phoneShapeThreshold = 7

    /// Scale words that trigger the top-priority pass-through rule —
    /// any number-word sequence containing one of these (alone or as a
    /// hyphen-compound piece) is left unchanged.
    private static let largeScaleWords: Set<String> = [
        "million", "billion", "trillion"
    ]

    // MARK: - Detection helpers

    /// True if the token's core, lowercased and split on hyphen, contains
    /// any of `million` / `billion` / `trillion`. Used by the top-priority
    /// pass-through gate.
    private static func isLargeScaleToken(_ s: String) -> Bool {
        let lower = s.lowercased()
        if largeScaleWords.contains(lower) { return true }
        for part in lower.split(separator: "-") {
            if largeScaleWords.contains(String(part)) { return true }
        }
        return false
    }

    /// True if any piece in `sequence` is a large-scale word
    /// (`million`/`billion`/`trillion`).
    private static func sequenceContainsLargeScale(_ sequence: [String]) -> Bool {
        for p in sequence {
            if largeScaleWords.contains(p.lowercased()) { return true }
        }
        return false
    }

    /// True if the token core looks like a word-form ordinal — known
    /// vocabulary, hyphenated compound ending in a known ordinal, or
    /// digit-form ordinal ("21st").
    private static func isOrdinal(_ s: String) -> Bool {
        let lower = s.lowercased()
        if ordinalWords.contains(lower) { return true }
        if let dash = lower.lastIndex(of: "-") {
            let tail = String(lower[lower.index(after: dash)...])
            if ordinalWords.contains(tail) { return true }
        }
        for sfx in ["st", "nd", "rd", "th"] {
            if lower.hasSuffix(sfx), lower.count > sfx.count {
                let head = String(lower.dropLast(sfx.count))
                if head.allSatisfy({ $0.isNumber }) { return true }
            }
        }
        return false
    }

    /// True if `s` is a single-token cardinal word OR a hyphenated
    /// compound whose every piece is a cardinal word. Used by the
    /// main loop as a cheap gate before invoking the year-shape /
    /// cardinal parsers.
    private static func isSplittableCardinalWord(_ s: String) -> Bool {
        let parts = s.lowercased().split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { cardinalWords[$0] != nil }
    }

    /// True if there are ≥`phoneShapeThreshold` consecutive `.word`
    /// tokens whose lowercase `core` is in `singleDigitWords`.
    private static func containsPhoneShape(_ tokens: [Token]) -> Bool {
        var run = 0
        for t in tokens {
            guard t.kind == .word else { continue }
            if singleDigitWords.contains(t.core.lowercased()) {
                run += 1
                if run >= phoneShapeThreshold { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    /// Last `.word` token already in `out` (skipping whitespace).
    private static func previousWord(in out: [Token]) -> String? {
        for t in out.reversed() {
            if t.kind == .word { return t.core }
        }
        return nil
    }

    /// The second-most-recent word token in `out` (the word before the
    /// immediately-previous one). Used to detect the "cardinal by
    /// cardinal" idiom ("one by one").
    private static func wordBeforePrevious(in out: [Token]) -> String? {
        var seen = 0
        for t in out.reversed() where t.kind == .word {
            seen += 1
            if seen == 2 { return t.core }
        }
        return nil
    }

    /// Next non-whitespace token AFTER index `start`.
    private static func nextWord(after start: Int, tokens: [Token]) -> (index: Int, token: Token)? {
        var i = start + 1
        while i < tokens.count {
            if tokens[i].kind == .word || tokens[i].kind == .other {
                return (i, tokens[i])
            }
            i += 1
        }
        return nil
    }

    // MARK: - Year-shape pre-parser

    /// Try to greedily parse a year-shape sequence starting at token
    /// `start`. Recognized shapes:
    ///   - "nineteen NN"          → 1900–1999
    ///   - "nineteen NN NN"       → reject (overflow)
    ///   - "twenty NN"            → 2000–2099
    ///   - "two thousand NN"      → 2000–2099
    ///   - "two thousand and NN"  → 2000–2099
    /// Returns the year value + endExclusive token index, or nil. Only
    /// called when prev word is a year-context trigger.
    /// Distinguishes the two year shapes so the caller can gate them
    /// differently: paired-halves carry the low-half form (a hyphenated
    /// tens+ones like "twenty-four" is an unambiguous year and may fire
    /// on shape alone; anything else needs temporal context and must not
    /// be a bare 1-9). "two thousand" forms always require context.
    enum YearKind {
        case pairedHalves(lowHyphenated: Bool, lowBareOnes: Bool)
        case twoThousand
    }

    private static func parseYearShape(
        tokens: [Token],
        start: Int
    ) -> (value: Int, endExclusive: Int, kind: YearKind)? {
        guard start < tokens.count, tokens[start].kind == .word else { return nil }
        let firstCore = tokens[start].core.lowercased()

        if let lead = centuryLeadWords[firstCore] {
            let base = lead * 100
            // If token has trailing punctuation, the sequence cannot
            // continue past it. "in twenty," can't form a year.
            if tokens[start].hasTrailingPunct { return nil }
            // Need the NN word/compound next.
            guard let nn = readTwoDigitWord(tokens: tokens, start: start + 1) else { return nil }
            // Range check: year-NN must be 00..99.
            guard nn.value >= 0, nn.value <= 99 else { return nil }
            let year = base + nn.value
            // Plausible-year band (1400–2099).
            guard year >= 1400, year <= 2099 else { return nil }
            return (year, nn.endExclusive,
                    .pairedHalves(lowHyphenated: nn.hyphenated, lowBareOnes: nn.bareOnes))
        }

        if firstCore == "two" {
            // Need "thousand" next.
            guard !tokens[start].hasTrailingPunct else { return nil }
            guard let nextOne = nextNonWhitespace(after: start, tokens: tokens),
                  tokens[nextOne.index].core.lowercased() == "thousand" else { return nil }
            let thousandIdx = nextOne.index
            // Bare "two thousand" → 2000.
            if tokens[thousandIdx].hasTrailingPunct {
                return (2000, thousandIdx + 1, .twoThousand)
            }
            // Optional "and".
            var nnStart = thousandIdx + 1
            if let afterThou = nextNonWhitespace(after: thousandIdx, tokens: tokens),
               tokens[afterThou.index].core.lowercased() == "and",
               !tokens[afterThou.index].hasTrailingPunct {
                nnStart = afterThou.index + 1
            }
            if let nn = readTwoDigitWord(tokens: tokens, start: nnStart),
               nn.value >= 0, nn.value <= 99 {
                return (2000 + nn.value, nn.endExclusive, .twoThousand)
            }
            // "two thousand" with no NN tail — accept as 2000.
            return (2000, thousandIdx + 1, .twoThousand)
        }

        return nil
    }

    /// Read a two-digit word starting at `start`. Accepts:
    ///   - a single teen (10–19) or single ones (1–9, e.g. "five" → 5)
    ///   - a single tens word (20, 30, ...)
    ///   - a hyphenated tens+ones ("twenty-six")
    ///   - a space-separated tens+ones ("twenty six")
    /// Returns the value + endExclusive token index, or nil.
    private static func readTwoDigitWord(
        tokens: [Token],
        start: Int
    ) -> (value: Int, endExclusive: Int, hyphenated: Bool, bareOnes: Bool)? {
        // Skip leading whitespace.
        var idx = start
        while idx < tokens.count, tokens[idx].kind == .whitespace { idx += 1 }
        guard idx < tokens.count, tokens[idx].kind == .word else { return nil }

        let core = tokens[idx].core.lowercased()
        let parts = core.split(separator: "-").map(String.init)

        // Hyphenated compound "twenty-six" — an unambiguous two-digit form.
        if parts.count == 2,
           let tens = cardinalWords[parts[0]], tens % 10 == 0, tens >= 20, tens <= 90,
           let ones = cardinalWords[parts[1]], ones >= 1, ones <= 9 {
            return (tens + ones, idx + 1, true, false)
        }

        // Single word.
        if parts.count == 1, let v = cardinalWords[core] {
            // Teen or single ones or single tens.
            if v >= 0 && v <= 19 {
                // A bare single-digit (0–9) is the dangerous low half
                // ("twenty one" → not 2001); flag it so the year gate can
                // refuse it. Teens (10–19) are genuine two-digit forms.
                return (v, idx + 1, false, v <= 9)
            }
            if v % 10 == 0, v >= 20, v <= 90 {
                // Optional space + ones word ("twenty four" → 24).
                if !tokens[idx].hasTrailingPunct,
                   let nextOne = nextNonWhitespace(after: idx, tokens: tokens) {
                    let nc = tokens[nextOne.index].core.lowercased()
                    if let ones = cardinalWords[nc], ones >= 1, ones <= 9 {
                        return (v + ones, nextOne.index + 1, false, false)
                    }
                }
                return (v, idx + 1, false, false)
            }
        }
        return nil
    }

    /// Address-mode pre-parser. Greedily consume a run of ≥2
    /// single-digit cardinal words ("four oh seven", "one two three")
    /// and concatenate their digit values into a literal string. The
    /// run must contain at LEAST one "oh" or have ≥ 2 single-digit
    /// words — otherwise we let the standard cardinal parser handle
    /// it (so "apartment two hundred" still resolves via rule 6).
    /// Returns nil if the start token is not a single-digit cardinal.
    private static func parseAddressDigitRun(
        tokens: [Token],
        start: Int
    ) -> (digits: String, endExclusive: Int)? {
        guard start < tokens.count, tokens[start].kind == .word else { return nil }
        let firstCore = tokens[start].core.lowercased()
        // Reject hyphenated tokens — "four-oh" isn't a real input.
        if firstCore.contains("-") { return nil }
        guard let firstVal = cardinalWords[firstCore], firstVal >= 0, firstVal <= 9
        else { return nil }

        var digits = "\(firstVal)"
        var lastIdx = start
        var hasOh = (firstCore == "oh")

        var i = start
        if tokens[i].hasTrailingPunct {
            // Single digit — no run.
            return nil
        }
        i = start + 1

        while i < tokens.count {
            guard tokens[i].kind == .whitespace else { break }
            guard i + 1 < tokens.count, tokens[i + 1].kind == .word else { break }
            let nextTok = tokens[i + 1]
            let nextCore = nextTok.core.lowercased()
            if nextCore.contains("-") { break }
            guard let v = cardinalWords[nextCore], v >= 0, v <= 9 else { break }
            digits.append(String(v))
            lastIdx = i + 1
            if nextCore == "oh" { hasOh = true }
            if nextTok.hasTrailingPunct { break }
            i = i + 2
        }

        let consumed = lastIdx - start + 1
        // Need either an "oh" anywhere in the run OR at least 2
        // tokens — otherwise "apartment four" should fall through to
        // the standard cardinal parser (which won't fire for 4).
        if hasOh || consumed >= 2 {
            return (digits, lastIdx + 1)
        }
        return nil
    }

    /// Helper: next index that is NOT whitespace, after `start`.
    private static func nextNonWhitespace(after start: Int, tokens: [Token]) -> (index: Int, token: Token)? {
        var i = start + 1
        while i < tokens.count {
            if tokens[i].kind != .whitespace { return (i, tokens[i]) }
            i += 1
        }
        return nil
    }

    // MARK: - Tens-ordinal combiner

    /// Ones-range ordinal words → numeric value (1..9). Used by the
    /// tens-ordinal combiner to compose forms like "twenty third" or
    /// "twenty-third" into "23rd". Standalone ones-ordinals
    /// ("first".."ninth") are intentionally NOT rewritten; they only
    /// participate as the ones-piece of a tens+ones ordinal.
    private static let onesOrdinalValues: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9
    ]

    /// Standalone tens-ordinal words → numeric value (20, 30, ..., 90).
    /// Emit form is always "<value>th" (20th, 30th, ..., 90th).
    private static let tensOrdinalValues: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90
    ]

    /// Ordinal suffix for a numeric value's units digit. 1 → "st",
    /// 2 → "nd", 3 → "rd", everything else → "th". (No teen exception
    /// needed — this helper is only called with values 20..99 where the
    /// units digit drives the suffix unambiguously.)
    private static func ordinalSuffix(forUnits units: Int) -> String {
        switch units {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// Try to consume a tens-ordinal shape starting at `start`. Returns
    /// the emit text and endExclusive token index, or nil. Recognized
    /// shapes (case-insensitive on input, lowercase output):
    ///   - hyphenated tens+ones ordinal: "twenty-third"  → "23rd"
    ///   - standalone tens-ordinal word: "twentieth"     → "20th"
    ///   - space-separated tens cardinal + ones-ordinal: "twenty third" → "23rd"
    /// Does NOT fire for hyphenated standalone tens-ordinals (none
    /// exist) or for the bare ones-ordinals "first..ninth" (spec says
    /// keep those as words).
    private static func parseTensOrdinal(
        tokens: [Token],
        start: Int
    ) -> (text: String, endExclusive: Int)? {
        guard start < tokens.count, tokens[start].kind == .word else { return nil }
        let core = tokens[start].core.lowercased()

        // Hyphenated form: "twenty-third".
        if core.contains("-") {
            let parts = core.split(separator: "-").map(String.init)
            if parts.count == 2,
               let tensVal = cardinalWords[parts[0]],
               tensVal % 10 == 0, tensVal >= 20, tensVal <= 90,
               let onesVal = onesOrdinalValues[parts[1]] {
                let combined = tensVal + onesVal
                return ("\(combined)\(ordinalSuffix(forUnits: onesVal))", start + 1)
            }
            // Hyphenated form that isn't a tens+ones ordinal — let the
            // main loop handle it (it'll either be an ordinal that gets
            // emitted verbatim, or a cardinal compound).
            return nil
        }

        // Standalone tens-ordinal word: "twentieth".
        if let tensVal = tensOrdinalValues[core] {
            return ("\(tensVal)th", start + 1)
        }

        // Space-separated: "twenty third". Require the start token to
        // be a plain tens cardinal (20..90) with no trailing
        // punctuation, then a single ones-ordinal follower.
        guard let tensVal = cardinalWords[core],
              tensVal % 10 == 0, tensVal >= 20, tensVal <= 90,
              !tokens[start].hasTrailingPunct
        else { return nil }
        guard let next = nextNonWhitespace(after: start, tokens: tokens),
              tokens[next.index].kind == .word
        else { return nil }
        let nextCore = tokens[next.index].core.lowercased()
        guard let onesVal = onesOrdinalValues[nextCore] else { return nil }
        // Homograph guard: "<tens> second <duration-noun>" is a duration
        // ("thirty second timeout" = 30-second), not an ordinal. Suppress
        // the combine so the cardinal path yields "30 second timeout".
        if nextCore == "second",
           let after = nextNonWhitespace(after: next.index, tokens: tokens),
           durationNounsAfterSecond.contains(tokens[after.index].core.lowercased()) {
            return nil
        }
        let combined = tensVal + onesVal
        return ("\(combined)\(ordinalSuffix(forUnits: onesVal))", next.index + 1)
    }

    // MARK: - Date parser

    /// Maximum valid day per month (February capped at 29 — we accept a
    /// leap-day but reject Feb 30/31). A month word not in this table is
    /// not a month.
    private static let monthDayMax: [String: Int] = [
        "january": 31, "february": 29, "march": 31, "april": 30,
        "may": 31, "june": 30, "july": 31, "august": 31,
        "september": 30, "october": 31, "november": 30, "december": 31
    ]

    /// Teen ordinals → value (10–19). Days can be teens ("the eleventh").
    private static let teenOrdinalValues: [String: Int] = [
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
        "fourteenth": 14, "fifteenth": 15, "sixteenth": 16,
        "seventeenth": 17, "eighteenth": 18, "nineteenth": 19
    ]

    /// Homographic months (may/march/august double as verb/adjective)
    /// only read as a month when Capitalized — "March 3rd" is a date but
    /// "they march third" is not. Non-homographic months always qualify.
    private static func monthDateAllowed(_ tok: Token) -> Bool {
        let lower = tok.core.lowercased()
        if lower == "may" || lower == "march" || lower == "august" {
            return tok.core.first?.isUppercase ?? false
        }
        return true
    }

    /// Render a 1–31 day number as an ordinal ("1st", "11th", "22nd",
    /// "31st"), honoring the 11/12/13 → "th" exception.
    private static func renderOrdinal(_ n: Int) -> String {
        let mod = n % 100
        let suffix = (mod >= 11 && mod <= 13) ? "th" : ordinalSuffix(forUnits: n % 10)
        return "\(n)\(suffix)"
    }

    /// Parse a day-of-month ordinal (1–31) starting at `start`. Accepts
    /// ones ("fourth"), teens ("eleventh"), round tens ("twentieth",
    /// "thirtieth"), and hyphenated/space tens+ones ("twenty-first",
    /// "thirty first"). Returns the numeric value + endExclusive.
    private static func parseDayOrdinal(
        tokens: [Token],
        start: Int
    ) -> (value: Int, endExclusive: Int)? {
        guard start < tokens.count, tokens[start].kind == .word else { return nil }
        let core = tokens[start].core.lowercased()

        // Hyphenated tens+ones ordinal: "twenty-first" → 21, "thirty-first" → 31.
        if core.contains("-") {
            let parts = core.split(separator: "-").map(String.init)
            if parts.count == 2,
               let tens = cardinalWords[parts[0]], tens % 10 == 0, tens >= 20, tens <= 30,
               let ones = onesOrdinalValues[parts[1]] {
                return (tens + ones, start + 1)
            }
            return nil
        }

        if let v = onesOrdinalValues[core] { return (v, start + 1) }   // first..ninth
        if let v = teenOrdinalValues[core] { return (v, start + 1) }   // tenth..nineteenth
        if let v = tensOrdinalValues[core], v <= 30 {                  // twentieth, thirtieth
            return (v, start + 1)
        }

        // Space tens + ones ordinal: "twenty first" → 21, "thirty first" → 31.
        if let tens = cardinalWords[core], tens % 10 == 0, tens >= 20, tens <= 30,
           !tokens[start].hasTrailingPunct,
           let next = nextNonWhitespace(after: start, tokens: tokens),
           let ones = onesOrdinalValues[tokens[next.index].core.lowercased()] {
            return (tens + ones, next.index + 1)
        }
        return nil
    }

    // MARK: - Cardinal parser

    /// Parse a maximal spelled-cardinal sequence starting at token
    /// `start`. Returns the matched lowercase `sequence` pieces, the
    /// numeric `value`, and `consumed` token count (covering all
    /// tokens INCLUDING any internal whitespace and "and" connectors).
    ///
    /// Honors English number grammar:
    ///   - A "ones" piece (1–9) may be followed only by a "scale"
    ///     (hundred/thousand/million).
    ///   - A "teen" piece (10–19) may be followed only by a "scale".
    ///   - A "tens" piece (20, 30, …, 90) may be followed by a single
    ///     "ones" (1–9), then a "scale", then nothing.
    ///   - After a "scale" piece, the parser restarts a fresh
    ///     sub-cardinal that contributes to the running total.
    ///   - The connector "and" is allowed once between sub-cardinals
    ///     (e.g. "two hundred AND thirty").
    ///   - A token with trailing punctuation (",", ".", etc.) ends
    ///     the sequence; the next token after it can't extend it.
    private static func parseCardinalSequence(
        tokens: [Token],
        start: Int
    ) -> (sequence: [String], value: Int, consumed: Int)? {
        guard start < tokens.count, tokens[start].kind == .word else { return nil }
        guard let firstParts = splitCardinalPieces(tokens[start].core) else { return nil }
        // Reject if the first piece is "and" (impossible standalone).
        guard !firstParts.isEmpty, firstParts.first != "and" else { return nil }

        var pieces = firstParts
        var lastConsumedIdx = start

        // Helper: can we extend with `nextPieces`?
        // Returns true if appending preserves a valid grammar.
        func canExtend(currentLast: String, nextFirst: String) -> Bool {
            guard let lastVal = cardinalWords[currentLast],
                  let nextVal = cardinalWords[nextFirst] else { return false }
            // Scales after anything except "and" — handled separately.
            if nextVal == 100 {
                // "hundred" valid after ones (1-9) and teen (10-19).
                return lastVal >= 1 && lastVal <= 19
            }
            if nextVal == 1_000 || nextVal == 1_000_000 {
                // "thousand"/"million" valid after pretty much any
                // sub-thousand value (ones, teens, tens, hundreds).
                return lastVal >= 1 && lastVal < nextVal
            }
            // Non-scale follower:
            if lastVal == 100 || lastVal == 1_000 || lastVal == 1_000_000 {
                // After a scale, a new sub-cardinal can start with
                // anything (ones, teens, tens).
                return nextVal >= 1
            }
            if lastVal % 10 == 0, lastVal >= 20, lastVal <= 90 {
                // After a tens word, only ones (1-9) may follow.
                return nextVal >= 1 && nextVal <= 9
            }
            // After ones (1-9) or teens (10-19), only a scale may
            // follow — and we handled scales above.
            return false
        }

        // Validate the internal hyphenated compound of the FIRST token
        // (e.g. "twenty-five" must be valid tens+ones).
        if firstParts.count > 1 {
            for k in 0..<(firstParts.count - 1) {
                if !canExtend(currentLast: firstParts[k], nextFirst: firstParts[k + 1]) {
                    return nil
                }
            }
        }

        var i = start
        // If first token has trailing punctuation, stop immediately.
        if tokens[i].hasTrailingPunct {
            guard let value = computeValue(from: pieces) else { return nil }
            return (pieces, value, 1)
        }

        // Walk forward.
        i = start + 1
        while i < tokens.count {
            guard tokens[i].kind == .whitespace else { break }
            guard i + 1 < tokens.count, tokens[i + 1].kind == .word else { break }
            let nextTok = tokens[i + 1]
            let nextCore = nextTok.core.lowercased()

            // "and" connector — only valid AFTER a scale (commonly
            // "two hundred AND thirty"). We use a relaxed rule: accept
            // "and" only if the current last piece is a scale word.
            if nextCore == "and" {
                guard let last = pieces.last,
                      let lastVal = cardinalWords[last],
                      lastVal == 100 || lastVal == 1_000 || lastVal == 1_000_000
                else { break }
                // No trailing punctuation on "and" either.
                if nextTok.hasTrailingPunct { break }
                // Look one more step ahead — must be a cardinal word.
                guard let after = nextNonWhitespace(after: i + 1, tokens: tokens),
                      tokens[after.index].kind == .word,
                      !isOrdinal(tokens[after.index].core),
                      let afterParts = splitCardinalPieces(tokens[after.index].core)
                else { break }
                // Validate that afterParts can extend after "scale".
                if !canExtend(currentLast: last, nextFirst: afterParts[0]) { break }
                // Validate internal compound of afterParts.
                var validInternal = true
                for k in 0..<(afterParts.count - 1) {
                    if !canExtend(currentLast: afterParts[k], nextFirst: afterParts[k + 1]) {
                        validInternal = false; break
                    }
                }
                if !validInternal { break }
                pieces.append("and")
                pieces.append(contentsOf: afterParts)
                lastConsumedIdx = after.index
                if tokens[after.index].hasTrailingPunct { break }
                i = after.index + 1
                continue
            }

            // Ordinary cardinal-piece extension.
            if isOrdinal(nextTok.core) { break }
            guard let nextParts = splitCardinalPieces(nextTok.core) else { break }
            // Validate transition.
            guard let last = pieces.last else { break }
            if !canExtend(currentLast: last, nextFirst: nextParts[0]) { break }
            // Validate internal compound of nextParts.
            var validInternal = true
            for k in 0..<(nextParts.count - 1) {
                if !canExtend(currentLast: nextParts[k], nextFirst: nextParts[k + 1]) {
                    validInternal = false; break
                }
            }
            if !validInternal { break }

            pieces.append(contentsOf: nextParts)
            lastConsumedIdx = i + 1
            if nextTok.hasTrailingPunct { break }
            i = i + 2
        }

        guard let value = computeValue(from: pieces) else { return nil }
        return (pieces, value, lastConsumedIdx - start + 1)
    }

    /// Split a token's `core` into one or more cardinal pieces by
    /// hyphen, validating that EVERY piece is in `cardinalWords`.
    /// Returns nil if any piece is not a cardinal word.
    private static func splitCardinalPieces(_ s: String) -> [String]? {
        let parts = s.lowercased().split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }
        for p in parts {
            if cardinalWords[p] == nil { return nil }
        }
        return parts
    }

    /// Compute numeric value from cardinal-word pieces. Supports
    /// hundreds, thousands, millions, and "and" composition.
    private static func computeValue(from pieces: [String]) -> Int? {
        let filtered = pieces.filter { $0 != "and" }
        guard !filtered.isEmpty else { return nil }

        var total = 0
        var current = 0
        for p in filtered {
            guard let v = cardinalWords[p] else { return nil }
            if v == 100 {
                if current == 0 { current = 1 }
                current *= 100
            } else if v == 1_000 || v == 1_000_000 {
                if current == 0 { current = 1 }
                total += current * v
                current = 0
            } else {
                current += v
            }
        }
        total += current
        return total
    }

    // MARK: - Context-aware rewriter

    /// Apply the first matching context rule and return a Rewrite
    /// (synthetic text + new advance position). Returns nil for
    /// idiom / skip cases — the main loop will emit the original
    /// tokens verbatim.
    ///
    /// `outSoFar` is `inout` so that idiom-override rules (e.g.
    /// "a thousand dollars" → "$1,000") can drop the preceding "a" /
    /// "one" article from the already-emitted output.
    private static func rewriteSequence(
        sequence: [String],
        value: Int,
        startIndex: Int,
        endExclusive: Int,
        tokens: [Token],
        prevWordLower: String?,
        outSoFar: inout [Token]
    ) -> Rewrite? {
        let containsOh = sequence.contains("oh")

        // Was this sequence preceded by a bare "a" / "one" article AND
        // is it exactly a one-piece scale ("hundred"/"thousand"/
        // "million")? Used by money / percent / idiom overrides so we
        // can drop the article when emitting "$1,000" / "100%".
        let articlePrefixIdx: Int? = articleIndexBeforeIdiom(
            startIndex: startIndex,
            tokens: tokens,
            sequence: sequence
        )

        // === Rule 1: Money ===
        if value >= 1, let unit = nextWord(after: endExclusive - 1, tokens: tokens) {
            let unitTrimmed = unit.token.core.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))

            if ["dollars", "dollar", "bucks", "buck"].contains(unitTrimmed) {
                // "dollars and <m> cents" extension.
                if let andTok = nextWord(after: unit.index, tokens: tokens),
                   andTok.token.core.lowercased() == "and",
                   let cents = nextCardinal(after: andTok.index, tokens: tokens),
                   let centsUnit = nextWord(after: cents.endExclusive - 1, tokens: tokens),
                   ["cents", "cent"].contains(
                    centsUnit.token.core.lowercased()
                        .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
                   ) {
                    dropArticleIfPresent(at: articlePrefixIdx, in: &outSoFar)
                    return Rewrite(
                        text: "$\(formatThousands(value)).\(String(format: "%02d", cents.value))",
                        consumedUpTo: centsUnit.index + 1
                    )
                }
                dropArticleIfPresent(at: articlePrefixIdx, in: &outSoFar)
                return Rewrite(text: "$\(formatThousands(value))", consumedUpTo: unit.index + 1)
            }

            if ["cents", "cent"].contains(unitTrimmed) {
                return Rewrite(text: "\(value)¢", consumedUpTo: unit.index + 1)
            }

            // === Rule 2: Percent ===
            if unitTrimmed == "percent" {
                dropArticleIfPresent(at: articlePrefixIdx, in: &outSoFar)
                return Rewrite(text: "\(value)%", consumedUpTo: unit.index + 1)
            }
        }

        // === Rule 3: Year-shape (post-parser fallback) ===
        // The year shape is already handled by the year pre-parser in
        // normalize(), but we leave a fallback for "two thousand
        // twenty-six" which IS a valid standard cardinal (2026) AND
        // year-context-shaped.
        if isYearContext(prevWordLower: prevWordLower), value >= 1000, value <= 2999 {
            let filtered = sequence.filter { $0 != "and" }
            if filtered.count >= 2, filtered[0] == "two", filtered[1] == "thousand" {
                if !containsOh {
                    return Rewrite(text: String(value), consumedUpTo: endExclusive)
                }
            }
        }

        // === Rule 4: Time-of-day ===
        if value >= 1, value <= 12, sequence.count == 1, !containsOh {
            // (a) Compound time.
            if let next = nextWord(after: endExclusive - 1, tokens: tokens) {
                let nextCore = next.token.core.lowercased()
                if nextCore == "thirty" || nextCore == "fifteen" || nextCore == "forty-five" {
                    let minutes = nextCore == "thirty" ? 30 :
                                  nextCore == "fifteen" ? 15 : 45
                    let base = "\(value):\(String(format: "%02d", minutes))"
                    if let meridiem = trailingMeridiem(after: next.index, tokens: tokens) {
                        return Rewrite(text: "\(base) \(meridiem.text)", consumedUpTo: meridiem.consumedUpTo)
                    }
                    return Rewrite(text: base, consumedUpTo: next.index + 1)
                }
                if nextCore == "o'clock" || nextCore == "o’clock" {
                    return Rewrite(text: "\(value) o'clock", consumedUpTo: next.index + 1)
                }
            }

            // (b) Sub-10 override.
            // Idiom guard: "cardinal by cardinal" ("one by one", "two by
            // two") is not a time — don't convert the trailing digit.
            let byIdiom = (prevWordLower == "by")
                && (wordBeforePrevious(in: outSoFar).map {
                    cardinalWords[$0.lowercased()] != nil || isSplittableCardinalWord($0)
                } ?? false)
            if value >= 1, value <= 9,
               let prev = prevWordLower,
               timePrecedingWords.contains(prev),
               !byIdiom {
                if let meridiem = trailingMeridiem(after: endExclusive - 1, tokens: tokens) {
                    return Rewrite(text: "\(value) \(meridiem.text)", consumedUpTo: meridiem.consumedUpTo)
                }
                return Rewrite(text: "\(value)", consumedUpTo: endExclusive)
            }
        }

        // === Rule 5: Address / room number ===
        if let prev = prevWordLower, addressContextWords.contains(prev) {
            if let addrValue = addressDigitString(sequence: sequence) {
                return Rewrite(text: addrValue, consumedUpTo: endExclusive)
            }
            return nil
        }

        // === Rule 8: Idiom exception (bare standalone) ===
        if isStandaloneIdiom(startIndex: startIndex, tokens: tokens, value: value) {
            return nil
        }

        // === Rule 6: Cardinals ≥ 10 ===
        if value >= 10 {
            if containsOh { return nil }
            // Drop a leading "a" article when the cardinal is emitted
            // as a digit. Covers "a thousand and twenty things" →
            // "1,020 things" and "a million and one ways" →
            // "1,000,001 ways". The standalone-idiom guard above has
            // already returned nil for the bare "a thousand"/"a
            // million"/"a hundred" cases, so this only fires when we
            // ARE about to emit digits.
            dropArticleIfPresent(at: articlePrefixIdx, in: &outSoFar)
            return Rewrite(text: formatThousands(value), consumedUpTo: endExclusive)
        }

        // === Rule 7: Cardinals 1–9 stay as words ===
        return nil
    }

    /// If the sequence is a bare "hundred" / "thousand" / "million"
    /// preceded by "a" or "A", or is "one" + scale, return the index
    /// of the preceding "a" / "one" / "A" token (so callers can drop
    /// it when overriding the idiom with a unit like dollars/percent).
    /// Returns nil otherwise.
    private static func articleIndexBeforeIdiom(
        startIndex: Int,
        tokens: [Token],
        sequence: [String]
    ) -> Int? {
        let startCore = tokens[startIndex].core.lowercased()
        if startCore == "hundred" || startCore == "thousand" || startCore == "million" {
            // Search backwards for the "a" article.
            for j in stride(from: startIndex - 1, through: 0, by: -1) {
                if tokens[j].kind == .whitespace { continue }
                return tokens[j].core.lowercased() == "a" ? j : nil
            }
        }
        if startCore == "one", sequence.count == 2,
           let scaleVal = cardinalWords[sequence[1]],
           scaleVal == 100 || scaleVal == 1_000 || scaleVal == 1_000_000 {
            // "one hundred"/"one thousand"/"one million" — drop the
            // "one" token (which IS startIndex itself).
            return startIndex
        }
        return nil
    }

    /// Remove the article token at `index` from `outSoFar` if it's the
    /// last word emitted. Also strip the trailing whitespace token if
    /// the article was followed by whitespace.
    private static func dropArticleIfPresent(at index: Int?, in outSoFar: inout [Token]) {
        guard let index = index else { return }
        // Find the corresponding entry in outSoFar by searching from
        // the tail. We match by `core` ("a" / "one") + position
        // heuristic: it's the most recent word.
        // Since "one" is part of the cardinal sequence itself, it
        // won't be in outSoFar (the parser hasn't emitted it yet);
        // we only need to drop trailing "a" tokens that already landed
        // in outSoFar before the cardinal.
        if index < 0 { return }
        // Walk back over whitespace, then check the word.
        var i = outSoFar.count - 1
        while i >= 0, outSoFar[i].kind == .whitespace { i -= 1 }
        guard i >= 0, outSoFar[i].kind == .word else { return }
        let core = outSoFar[i].core.lowercased()
        guard core == "a" else { return }
        // Drop article AND following whitespace tokens.
        outSoFar.removeSubrange(i..<outSoFar.count)
    }

    /// True if the cardinal at `startIndex` is a standalone idiom
    /// phrase ("a hundred" / "one hundred" / "a thousand" / ...).
    /// Money / percent / time / address / year already had their shot
    /// upstream, so this only fires on bare-noun followups.
    private static func isStandaloneIdiom(
        startIndex: Int,
        tokens: [Token],
        value: Int
    ) -> Bool {
        guard value == 100 || value == 1_000 || value == 1_000_000 else { return false }
        let startCore = tokens[startIndex].core.lowercased()
        if startCore == "hundred" || startCore == "thousand" || startCore == "million" {
            // Form: "a hundred" — preceded by "a" / "A".
            for j in stride(from: startIndex - 1, through: 0, by: -1) {
                if tokens[j].kind == .whitespace { continue }
                return tokens[j].core.lowercased() == "a"
            }
            return false
        }
        if startCore == "one" {
            // Form: "one hundred" / "one thousand" / "one million".
            return true
        }
        return false
    }

    /// Address-mode digit conversion. "four oh seven" → "407". Falls
    /// back to thousands-formatted cardinal value for "two hundred and
    /// three" → "203".
    private static func addressDigitString(sequence: [String]) -> String? {
        let filtered = sequence.filter { $0 != "and" }
        let allSingle = filtered.allSatisfy {
            if let v = cardinalWords[$0], v >= 0, v <= 9 { return true }
            return false
        }
        if allSingle {
            return filtered.map { String(cardinalWords[$0]!) }.joined()
        }
        if let v = computeValue(from: sequence) {
            return formatThousands(v)
        }
        return nil
    }

    /// True if `prevWordLower` is in the year-context set or is a month
    /// name.
    private static func isYearContext(prevWordLower: String?) -> Bool {
        guard let prev = prevWordLower else { return false }
        return yearContextWords.contains(prev) || monthWords.contains(prev)
    }

    /// If the next non-whitespace token is "AM" / "PM" (with or
    /// without dots), return the canonical form + the consume-up-to
    /// index that the caller should advance past.
    private static func trailingMeridiem(
        after index: Int,
        tokens: [Token]
    ) -> (text: String, consumedUpTo: Int)? {
        guard let next = nextWord(after: index, tokens: tokens) else { return nil }
        let normalized = next.token.core.lowercased()
            .replacingOccurrences(of: ".", with: "")
        if normalized == "am" || normalized == "pm" {
            return (normalized.uppercased(), next.index + 1)
        }
        return nil
    }

    /// Parse a cardinal sequence starting at the next non-whitespace
    /// token AFTER `index`. Returns nil if none found.
    private static func nextCardinal(
        after index: Int,
        tokens: [Token]
    ) -> (sequence: [String], value: Int, endExclusive: Int)? {
        var j = index + 1
        while j < tokens.count, tokens[j].kind == .whitespace { j += 1 }
        guard j < tokens.count, tokens[j].kind == .word else { return nil }
        guard let parsed = parseCardinalSequence(tokens: tokens, start: j) else { return nil }
        return (parsed.sequence, parsed.value, j + parsed.consumed)
    }

    // MARK: - Decimal parser

    /// Single-digit words that may appear in a spoken fractional run.
    /// Spoken decimals are read digit-by-digit, so only single digits
    /// (plus "oh"/"o" → 0) are accepted after "point".
    private static let fracDigitWords: [String: String] = [
        "zero": "0", "oh": "0", "o": "0",
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9"
    ]

    /// Like `nextWord`, but only crosses PLAIN whitespace — returns nil
    /// if a newline intervenes (a sentence/paragraph break must never be
    /// merged into a decimal span).
    private static func nextWordPlainSpace(
        after start: Int,
        tokens: [Token]
    ) -> (index: Int, token: Token)? {
        var i = start + 1
        while i < tokens.count {
            if tokens[i].kind == .whitespace {
                if tokens[i].raw.contains("\n") { return nil }
                i += 1
                continue
            }
            return (i, tokens[i])
        }
        return nil
    }

    /// Try to consume `"point" <digit>+ [percent|dollars]` immediately
    /// after an integer cardinal that ended at `cardinalEndExclusive`.
    /// Returns the rendered decimal + trailing punctuation + the token
    /// index to resume from, or nil if this is not a decimal.
    ///
    /// Guards (precision over recall):
    /// - the integer cardinal's last token must carry NO trailing
    ///   punctuation (blocks "…missed the point. Five…");
    /// - "point" must be a bare word with no trailing punctuation;
    /// - at least one single-digit word must follow "point";
    /// - the whole span must not cross a newline (`nextWordPlainSpace`);
    /// - the fractional part is kept as a String so trailing zeros and
    ///   leading fractional zeros survive ("one point oh" → "1.0",
    ///   "zero point zero five" → "0.05").
    private static func parseDecimalTail(
        integerValue: Int,
        cardinalEndExclusive: Int,
        tokens: [Token]
    ) -> (text: String, trailing: String, consumedUpTo: Int)? {
        let lastIntIdx = cardinalEndExclusive - 1
        guard lastIntIdx >= 0, !tokens[lastIntIdx].hasTrailingPunct else { return nil }

        // Require the word "point" immediately after (plain space only).
        guard let p = nextWordPlainSpace(after: lastIntIdx, tokens: tokens),
              p.token.kind == .word,
              p.token.core.lowercased() == "point",
              !p.token.hasTrailingPunct else { return nil }

        // Collect the fractional digit run (digit-by-digit).
        var digits = ""
        var lastFracIdx = p.index
        var cursor = p.index
        while let d = nextWordPlainSpace(after: cursor, tokens: tokens),
              d.token.kind == .word,
              let ch = fracDigitWords[d.token.core.lowercased()] {
            digits += ch
            lastFracIdx = d.index
            if d.token.hasTrailingPunct { break }  // sentence ends the fraction
            cursor = d.index
        }
        guard !digits.isEmpty else { return nil }

        var text = "\(integerValue).\(digits)"
        var trailing = tokens[lastFracIdx].trailing
        var consumedUpTo = lastFracIdx + 1

        // Optional trailing unit: "percent" → %, "dollars" → $ prefix.
        // (Scale words like "million" are intentionally left to the
        // large-scale pass-through, e.g. "two point five million".)
        if trailing.isEmpty,
           let u = nextWordPlainSpace(after: lastFracIdx, tokens: tokens),
           u.token.kind == .word {
            let uc = u.token.core.lowercased()
            if uc == "percent" {
                text += "%"
                trailing = u.token.trailing
                consumedUpTo = u.index + 1
            } else if uc == "dollars" || uc == "dollar" {
                text = "$" + text
                trailing = u.token.trailing
                consumedUpTo = u.index + 1
            }
        }
        return (text, trailing, consumedUpTo)
    }

    /// Format an integer with US-style thousands commas.
    private static func formatThousands(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}
