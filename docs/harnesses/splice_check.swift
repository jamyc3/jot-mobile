// Paste-edit resolution + application harness.
//
// RUN (from the jot-mobile repo root):
//
//     docs/harnesses/splice_check.sh
//
// or, equivalently, by hand:
//
//     cat ../jot-shared/Sources/JotVocabCore/PasteEditResolver.swift \
//         docs/harnesses/splice_check.swift | swift -
//
// This file used to carry its own MIRROR of the resolution algorithm, which
// made three copies of it in the tree (here, the keyboard controller, and
// jot-shared) — the harness could pass while the code it was meant to guard had
// drifted. It now exercises the SHARED `PasteEditResolver` itself: the source is
// concatenated ahead of these cases and compiled as one script, so `swift` still
// runs it standalone with no package, no build, and no Xcode. If the concatenation
// is missing, this file simply won't compile — a loud failure, not a silent one.
//
// jot-shared has its own XCTest coverage of the same type (golden fixtures in
// Tests/JotVocabCoreTests). This harness stays because it is the fast, no-Xcode
// loop for the keyboard's paste behaviour, and because it exercises the
// CONSUMER's composition (resolve → verify → apply) end to end.

import Foundation

var failures = 0

func check(_ name: String, _ got: String, _ want: String) {
    let ok = got == want; if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name): got=\"\(got)\" want=\"\(want)\"")
}

func span(_ name: String, _ got: PasteEditResolver.Span?, _ want: (Int, Int)?) {
    let ok = got?.start == want?.0 && got?.end == want?.1
    if !ok { failures += 1 }
    // Every span that exists must also be well-formed — it replaces at least one
    // character and its carried text is exactly what stands there.
    if let got, !got.isWellFormed { failures += 1; print("FAIL \(name): degenerate span") }
    print("\(ok ? "PASS" : "FAIL") \(name): got=\(got.map { "(\($0.start), \($0.end))" } ?? "nil") "
        + "want=\(want.map { "\($0)" } ?? "nil")")
}

func flag(_ name: String, _ got: Bool, _ want: Bool) {
    let ok = got == want; if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name): got=\(got) want=\(want)")
}

// MARK: - The consumer's composition
//
// What the keyboard does with ONE answered ask: resolve the span the pick edits,
// skip it when the text already reads that way, else apply the replacement.
// The no-op test is `replacement == span.text` — CASE-SENSITIVE. Comparing
// case-INsensitively (as the keyboard's deleted copy did) made every casing-only
// correction a guaranteed silent no-op while its verdict still flipped the saved
// transcript.

/// outcome "applied", pick "original".
func splice(_ text: String, term: String, original: String, anchor: Int,
            before: String = "", after: String = "") -> String {
    let inCore = PasteEditResolver.trimGatedWord(term)
    let wantCore = PasteEditResolver.trimGatedWord(original)
    guard !wantCore.isEmpty else { return text }
    guard let s = PasteEditResolver.resolve(needle: inCore, anchoredAt: anchor, in: text,
                                            contextBefore: before, contextAfter: after)
    else { return text }
    guard wantCore != s.text else { return text }
    return PasteEditResolver.apply(
        [.init(start: s.start, end: s.end, text: wantCore)], to: Array(text)) ?? text
}

/// alt0: the needle is `altFind` (primary word + tail); `contextAfter` starts
/// after the PRIMARY word, i.e. INSIDE that tail.
func spliceAlt(_ text: String, altFind: String, altTerm: String, primaryLen: Int, anchor: Int,
               before: String = "", after: String = "") -> String {
    let inCore = PasteEditResolver.trimGatedWord(altFind)
    let wantCore = PasteEditResolver.trimGatedWord(altTerm)
    guard !wantCore.isEmpty else { return text }
    guard let s = PasteEditResolver.resolve(needle: inCore, anchoredAt: anchor, in: text,
                                            contextBefore: before, contextAfter: after,
                                            primaryLengthInNeedle: primaryLen)
    else { return text }
    guard wantCore != s.text else { return text }
    return PasteEditResolver.apply(
        [.init(start: s.start, end: s.end, text: wantCore)], to: Array(text)) ?? text
}

// MARK: - Resolution (must stay green)

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

// Codex round-2 cases.
// 1: overlapping matches must not defeat strict priority. Needle "go go", anchor 3 -> 3..<8.
span("1 go-go-go strict over overlap",
     PasteEditResolver.resolve(needle: "go go", anchoredAt: 3, in: "go go go",
                               contextBefore: "", contextAfter: ""), (3, 8))
// 2: right-edge window crop — the 's' of "cats" falls outside the window; the
//    full-text boundary check still rejects it.
let catsCrop = String(repeating: "x", count: 55) + " cats"   // "cat" at 56..58, 's' at 59; hi=59
span("2 cats window-crop -> nil",
     PasteEditResolver.resolve(needle: "cat", anchoredAt: 0, in: catsCrop,
                               contextBefore: "", contextAfter: ""), nil)
// 3: left-edge crop — the 's' of "scat" falls before lo.
let scatCrop = String(repeating: "y", count: 11) + "scat" + String(repeating: "z", count: 65)
span("3 scat leading-edge crop -> nil",
     PasteEditResolver.resolve(needle: "cat", anchoredAt: 60, in: scatCrop,
                               contextBefore: "", contextAfter: ""), nil)
// 4: out-of-range / end anchor -> fail safe.
span("4 end-anchor cat/3 -> nil",
     PasteEditResolver.resolve(needle: "cat", anchoredAt: 3, in: "cat",
                               contextBefore: "", contextAfter: ""), nil)
// 5: variable-length fold at the far window edge (anchor+48) fits on the +8 slack.
let foldEdge = String(repeating: "x", count: 2) + String(repeating: " ", count: 48) + "STRASSE done"
span("5 STRASSE at anchor+48 -> match",
     PasteEditResolver.resolve(needle: "Straße", anchoredAt: 2, in: foldEdge,
                               contextBefore: "", contextAfter: ""), (50, 57))
// 6: removed-word survivor WITHOUT context corroboration -> no splice.
check("6 survivor no-corroboration -> nil",
      splice("Carol saw Jamy there", term: "Jamy", original: "Jamie", anchor: 0, before: "Alice met", after: "today"),
      "Carol saw Jamy there")
// 7: genuine drift WITH context corroboration -> splice.
check("7 survivor corroborated -> splice",
      splice("um Alice met Jamy today", term: "Jamy", original: "Jamie", anchor: 0, before: "Alice met", after: "today"),
      "um Alice met Jamie today")

// Codex round-3 cases.
// 8: San-hose — the after-context ("hose") lives inside the altFind tail; before
//    the fix, corroboration searched only after the FULL match and found nothing.
check("8 alt0 tail-context corroborates -> splice",
      spliceAlt("San hose", altFind: "San hose", altTerm: "San Jose", primaryLen: 3, anchor: 1,
                before: "", after: "hose"),
      "San Jose")
// 9: a substring must not corroborate — "he" inside "breathe" is not a word hit.
let rama = "he 12345678901234567890 breathe Rama"
span("9 he-inside-breathe -> nil",
     PasteEditResolver.resolve(needle: "Rama", anchoredAt: 3, in: rama,
                               contextBefore: "he", contextAfter: ""), nil)

// MARK: - F3 descriptors (D2a + review finding 8)

// 10: THE casing bug. A pick that differs from the text only in case is a REAL
//     edit. The keyboard's old `caseInsensitiveCompare` guard made this exact
//     shape — the canonical 3-option alt0 — a 100%-reproducible silent no-op.
check("10 casing-only pick is an edit",
      spliceAlt("I use Claude code daily", altFind: "Claude code", altTerm: "Claude Code",
                primaryLen: 6, anchor: 6, before: "I use ", after: " daily"),
      "I use Claude Code daily")
// 11: the text already reads as the pick -> no edit, and that is a SUCCESS, not
//     a splice failure.
check("11 already-desired -> untouched",
      splice("I met Jamie today", term: "Jamie", original: "Jamie", anchor: 6),
      "I met Jamie today")

// 12: a producer descriptor verifies against the consumer's own baseline...
let published = "I met Jamy at noon."
guard let baseSpan = PasteEditResolver.resolve(needle: "Jamy", anchoredAt: 6, in: published,
                                               contextBefore: "I met ", contextAfter: " at noon.")
else { fatalError("fixture: expected a resolved span") }
flag("12 descriptor verifies on the same baseline",
     PasteEditResolver.verify(start: baseSpan.start, text: baseSpan.text,
                              in: Array(published)) != nil, true)
// 13: ...and can only fail closed on a different one.
flag("13 descriptor fails closed on a shifted baseline",
     PasteEditResolver.verify(start: baseSpan.start, text: baseSpan.text,
                              in: Array("Well, I met Jamy at noon.")) != nil, false)
// 14: verification is case-SENSITIVE — the descriptor carries the baseline's own
//     casing, so a casing difference means the two sides hold different strings.
flag("14 verification is case-sensitive",
     PasteEditResolver.verify(start: 6, text: "jamy", in: Array(published)) != nil, false)

// 15: review finding 8 — an alternate's `find` widens through the FOLLOWING
//     words, so it can cover a separate ask's word. Each span resolves fine on
//     its own; only interval validation catches the collision.
let altBase = "I use Claude code daily"
guard let altWide = PasteEditResolver.resolve(needle: "Claude code", anchoredAt: 6, in: altBase,
                                              contextBefore: "I use ", contextAfter: " daily",
                                              primaryLengthInNeedle: 6),
      let nextAsk = PasteEditResolver.resolve(needle: "code", anchoredAt: 13, in: altBase,
                                              contextBefore: "I use Claude ", contextAfter: " daily")
else { fatalError("fixture: expected two resolved spans") }
flag("15 alt span covers the next ask", PasteEditResolver.overlaps(altWide.range, nextAsk.range), true)
// 16: and the consumer rejects that batch WHOLE — half-applying it would leave
//     text matching neither the pick nor the proposal.
flag("16 overlapping batch rejected whole",
     PasteEditResolver.apply([.init(start: altWide.start, end: altWide.end, text: "Claude Code"),
                              .init(start: nextAsk.start, end: nextAsk.end, text: "Code")],
                             to: Array(altBase)) == nil, true)
// 17: two independent edits apply in descending order, so the first never
//     shifts the second's offsets.
check("17 multi-edit batch applies cleanly",
      PasteEditResolver.apply([.init(start: 0, end: 4, text: "Jamie"),
                               .init(start: 12, end: 16, text: "Ramaa")],
                              to: Array("Jamy called Rama today")) ?? "<nil>",
      "Jamie called Ramaa today")
// 18: a degenerate (zero-width) edit is an unvalidated INSERT — an empty range
//     is invisible to overlap checking — so the whole batch is refused.
flag("18 degenerate edit rejected whole",
     PasteEditResolver.apply([.init(start: 6, end: 10, text: "Jamie"),
                              .init(start: 14, end: 14, text: "INSERTED")],
                             to: Array(published)) == nil, true)
// 19: an out-of-bounds edit likewise.
flag("19 out-of-bounds edit rejected whole",
     PasteEditResolver.apply([.init(start: 3, end: 99, text: "nope")],
                             to: Array("short")) == nil, true)

print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
