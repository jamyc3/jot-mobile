import Foundation

// Standalone mirror of the keyboard's applyVerdicts span-resolution (F2 round 2:
// direct-anchored strict test, full-text boundaries, out-of-range guard, fold slack,
// overlap-safe scan, context corroboration).

func trimGatedWord(_ s: String) -> String {
    s.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"'\u{2019}\u{201D})]}"))
}

func contextCorroborates(matchStart: Int, matchEnd: Int, in text: String,
                         contextBefore: String, contextAfter: String,
                         afterSearchStart: Int? = nil) -> Bool {
    func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\u{2026}" })
            .map { trimGatedWord(String($0)) }
            .filter { $0.count >= 2 }
    }
    let before = words(contextBefore)
    let after = words(contextAfter)
    if before.isEmpty && after.isEmpty { return true }
    let n = text.count
    func idx(_ off: Int) -> String.Index { text.index(text.startIndex, offsetBy: off) }
    func isLetterAt(_ off: Int) -> Bool {
        guard off >= 0, off < n else { return false }
        return text[idx(off)].isLetter
    }
    func anyWholeWord(_ list: [String], from lo: Int, to hi: Int) -> Bool {
        guard lo < hi, !list.isEmpty else { return false }
        let hiIdx = idx(hi)
        for w in list {
            var searchLo = idx(lo)
            while let r = text.range(of: w, options: [.caseInsensitive], range: searchLo..<hiIdx) {
                let s = text.distance(from: text.startIndex, to: r.lowerBound)
                let e = text.distance(from: text.startIndex, to: r.upperBound)
                if !isLetterAt(s - 1) && !isLetterAt(e) { return true }
                searchLo = text.index(after: r.lowerBound)
                if searchLo >= hiIdx { break }
            }
        }
        return false
    }
    if anyWholeWord(before, from: max(0, matchStart - 24), to: matchStart) { return true }
    let aStart = afterSearchStart ?? matchEnd
    let aEnd = min(n, max(matchEnd, aStart) + 24)
    if anyWholeWord(after, from: aStart, to: aEnd) { return true }
    return false
}

func spliceRange(of word: String, anchoredAtChar anchor: Int, in text: String,
                 contextBefore: String, contextAfter: String,
                 primaryLengthInNeedle: Int? = nil) -> (Int, Int)? {
    let n = text.count
    guard !word.isEmpty else { return nil }
    guard anchor >= 0, anchor < n else { return nil }
    func charOffset(_ i: String.Index) -> Int { text.distance(from: text.startIndex, to: i) }
    func idx(_ off: Int) -> String.Index { text.index(text.startIndex, offsetBy: off) }
    func isLetterAt(_ off: Int) -> Bool {
        guard off >= 0, off < n else { return false }
        return text[idx(off)].isLetter
    }
    func wholeWord(start: Int, end: Int) -> Bool { !isLetterAt(start - 1) && !isLetterAt(end) }

    let anchorIdx = idx(anchor)
    if let r = text.range(of: word, options: [.caseInsensitive, .anchored], range: anchorIdx..<text.endIndex) {
        let end = charOffset(r.upperBound)
        if wholeWord(start: anchor, end: end) { return (anchor, end) }
    }

    let radius = 48
    let lo = max(0, anchor - radius)
    let hi = min(n, anchor + word.count + radius + 8)
    guard lo < hi else { return nil }
    var matches: [(start: Int, end: Int)] = []
    var searchLo = idx(lo)
    let hiIdx = idx(hi)
    while let r = text.range(of: word, options: [.caseInsensitive], range: searchLo..<hiIdx) {
        let start = charOffset(r.lowerBound)
        let end = charOffset(r.upperBound)
        if wholeWord(start: start, end: end) { matches.append((start, end)) }
        searchLo = text.index(after: r.lowerBound)
        if searchLo >= hiIdx { break }
    }
    guard matches.count == 1 else { return nil }
    let match = matches[0]
    let afterSearchStart = primaryLengthInNeedle.map { min(match.start + $0, match.end) } ?? match.end
    guard contextCorroborates(matchStart: match.start, matchEnd: match.end, in: text,
                              contextBefore: contextBefore, contextAfter: contextAfter,
                              afterSearchStart: afterSearchStart) else { return nil }
    return match
}

// outcome "applied", pick "original".
func splice(_ text: String, term: String, original: String, anchor: Int,
            before: String = "", after: String = "") -> String {
    var chars = Array(text)
    let inCore = trimGatedWord(term)
    let wantCore = trimGatedWord(original)
    guard !wantCore.isEmpty, wantCore.caseInsensitiveCompare(inCore) != .orderedSame else { return text }
    guard let (s, e) = spliceRange(of: inCore, anchoredAtChar: anchor, in: text,
                                   contextBefore: before, contextAfter: after) else { return text }
    chars.replaceSubrange(s..<e, with: Array(wantCore))
    return String(chars)
}

var failures = 0
func check(_ name: String, _ got: String, _ want: String) {
    let ok = got == want; if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name): got=\"\(got)\" want=\"\(want)\"")
}
func rng(_ name: String, _ got: (Int, Int)?, _ want: (Int, Int)?) {
    let ok = got?.0 == want?.0 && got?.1 == want?.1; if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name): got=\(got.map { "\($0)" } ?? "nil") want=\(want.map { "\($0)" } ?? "nil")")
}

// --- previous 10 (must stay green) ---
check("A strict-anchor", splice("I met Jamy today", term: "Jamy", original: "Jamie", anchor: 6), "I met Jamie today")
check("B off-anchor unique fallback", splice("I met Jamy today", term: "Jamy", original: "Jamie", anchor: 3), "I met Jamie today")
check("C ambiguous fail-safe (in-range drifted)", splice("Jamy and Jamy", term: "Jamy", original: "Jamie", anchor: 1), "Jamy and Jamy")
check("D strict wins over ambiguity", splice("Jamy and Jamy", term: "Jamy", original: "Jamie", anchor: 9), "Jamy and Jamie")
check("E trailing punctuation", splice("hi Rama.", term: "Rama", original: "Ramaa", anchor: 3), "hi Ramaa.")
let farText = "Jonas said hello. " + String(repeating: "x", count: 80) + " Jamy waved."
check("a removed-word + far survivor -> no splice", splice(farText, term: "Jamy", original: "Jamie", anchor: 5), farText)
check("b survivor within window -> splice", splice("um so Jamy waved", term: "Jamy", original: "Jamie", anchor: 2), "um so Jamie waved")
check("c variable-length unicode fold", splice("die STRASSE hier", term: "Straße", original: "Hauptweg", anchor: 4), "die Hauptweg hier")
check("d1 apostrophe drifted-anchor -> fail safe", splice("I don't think Don came", term: "Don", original: "Dawn", anchor: 99), "I don't think Don came")
check("d2 apostrophe strict-anchor -> right splice", splice("I don't think Don came", term: "Don", original: "Dawn", anchor: 14), "I don't think Dawn came")

// --- Codex round-2 cases ---
// 1: overlapping matches must not defeat strict priority. word "go go", anchor 3 -> 3..<8.
rng("1 go-go-go strict over overlap", spliceRange(of: "go go", anchoredAtChar: 3, in: "go go go", contextBefore: "", contextAfter: ""), (3, 8))
// 2: right-edge window crop — 's' of "cats" falls outside the window; full-text boundary rejects.
let catsCrop = String(repeating: "x", count: 55) + " cats"   // "cat" at 56..58, 's' at 59; hi=59
rng("2 cats window-crop -> nil", spliceRange(of: "cat", anchoredAtChar: 0, in: catsCrop, contextBefore: "", contextAfter: ""), nil)
// 3: left-edge crop — 's' of "scat" falls before lo; full-text boundary rejects.
let scatCrop = String(repeating: "y", count: 11) + "scat" + String(repeating: "z", count: 65)  // 's'@11 'cat'@12..14, anchor 60 -> lo=12
rng("3 scat leading-edge crop -> nil", spliceRange(of: "cat", anchoredAtChar: 60, in: scatCrop, contextBefore: "", contextAfter: ""), nil)
// 4: out-of-range / end anchor -> fail safe.
rng("4 end-anchor cat/3 -> nil", spliceRange(of: "cat", anchoredAtChar: 3, in: "cat", contextBefore: "", contextAfter: ""), nil)
// 5: variable-length fold at the far window edge (anchor+48) fits thanks to +8 fold slack.
let foldEdge = String(repeating: "x", count: 2) + String(repeating: " ", count: 48) + "STRASSE done"  // "STRASSE" at 50..56
rng("5 STRASSE at anchor+48 -> match", spliceRange(of: "Straße", anchoredAtChar: 2, in: foldEdge, contextBefore: "", contextAfter: ""), (50, 57))
// 6: removed-word survivor WITHOUT context corroboration -> nil.
check("6 survivor no-corroboration -> nil",
      splice("Carol saw Jamy there", term: "Jamy", original: "Jamie", anchor: 0, before: "Alice met", after: "today"),
      "Carol saw Jamy there")
// 7: genuine drift WITH context corroboration -> splice.
check("7 survivor corroborated -> splice",
      splice("um Alice met Jamy today", term: "Jamy", original: "Jamie", anchor: 0, before: "Alice met", after: "today"),
      "um Alice met Jamie today")

// --- Codex round-3 cases ---
// alt0 splice: needle is altFind (primary + tail); contextAfter starts after the
// PRIMARY span, i.e. INSIDE the altFind tail.
func spliceAlt(_ text: String, altFind: String, altTerm: String, primaryLen: Int, anchor: Int,
               before: String = "", after: String = "") -> String {
    var chars = Array(text)
    let inCore = trimGatedWord(altFind)
    let wantCore = trimGatedWord(altTerm)
    guard !wantCore.isEmpty, wantCore.caseInsensitiveCompare(inCore) != .orderedSame else { return text }
    guard let (s, e) = spliceRange(of: inCore, anchoredAtChar: anchor, in: text,
                                   contextBefore: before, contextAfter: after,
                                   primaryLengthInNeedle: primaryLen) else { return text }
    chars.replaceSubrange(s..<e, with: Array(wantCore))
    return String(chars)
}
// 8 (Codex r3-1): San-hose — after-context ("hose") lives inside the altFind tail;
// pre-fix corroboration searched only after the full match and found nothing -> no splice.
check("8 alt0 tail-context corroborates -> splice",
      spliceAlt("San hose", altFind: "San hose", altTerm: "San Jose", primaryLen: 3, anchor: 1,
                before: "", after: "hose"),
      "San Jose")
// 9 (Codex r3-2): substring must not corroborate — "he" inside "breathe" is not a word hit.
let rama = "he 12345678901234567890 breathe Rama"
rng("9 he-inside-breathe -> nil",
    spliceRange(of: "Rama", anchoredAtChar: 3, in: rama, contextBefore: "he", contextAfter: ""),
    nil)

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
