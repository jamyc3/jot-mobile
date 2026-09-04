// Teach-by-voice sentence-locator harness.
//
// RUN (from the jot-mobile repo root):
//
//     docs/harnesses/teach_locator_check.sh
//
// The script concatenates jot-shared's `CorrectionKey.swift` and the app's
// `Jot/App/Vocabulary/TeachSentenceLocator.swift` ahead of these cases and
// compiles the lot as one script — so this exercises the SHIPPING locator, not
// a mirror of it. If the concatenation is missing, this file simply won't
// compile: a loud failure, not a silent pass.
//
// What it guards, in one line each:
//   - proposals win over the final text, INCLUDING the ones the gate held back
//     (the case the whole redesign exists for: an everyday-word original is
//     never silently rewritten, so the term is absent from the text even though
//     the pipeline found it);
//   - a span is trusted only if the sentence still reads that way there, so
//     offset drift from the post-gate transforms degrades to "not found"
//     instead of to a wrong highlight;
//   - comparison runs through the shared normalization, because the punctuation
//     model re-cases and re-punctuates everything the gate produced;
//   - the alias merge dedupes on the same key — it writes real vocabulary.

import Foundation

var failures = 0

func check(_ name: String, _ got: TeachSentenceLocator.Result, _ want: TeachSentenceLocator.Result) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name): got=\(describe(got)) want=\(describe(want))")
}

func check(_ name: String, _ got: [String], _ want: [String]) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name): got=\(got) want=\(want)")
}

func check(_ name: String, _ got: String, _ want: String) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name): got=\"\(got)\" want=\"\(want)\"")
}

func describe(_ result: TeachSentenceLocator.Result) -> String {
    switch result {
    case .applied(let spans): "applied\(spans.map { ($0.start, $0.length) })"
    case .heldBack(let spans, let heard): "heldBack\(spans.map { ($0.start, $0.length) })/\"\(heard)\""
    case .notFound: "notFound"
    }
}

func span(_ start: Int, _ length: Int) -> TeachSentenceLocator.Span {
    TeachSentenceLocator.Span(start: start, length: length)
}

func proposal(
    term: String, heard: String, outcome: String, at start: Int, length: Int
) -> TeachSentenceLocator.Proposal {
    TeachSentenceLocator.Proposal(
        term: term, originalWord: heard, outcome: outcome, start: start, length: length)
}

// MARK: - Located via an APPLIED proposal
//
// The corrector fired: the text already says the term, and the proposal points
// at where.

check(
    "applied proposal",
    TeachSentenceLocator.locate(
        term: "Vineet",
        in: "I met Vineet yesterday.",
        proposals: [proposal(term: "Vineet", heard: "we need", outcome: "applied", at: 6, length: 6)]),
    .applied([span(6, 6)]))

// The punctuation model strips existing case before re-adding its own, so the
// applied span can come back re-cased. Raw string equality would miss it; the
// shared normalization does not.
check(
    "applied proposal, punctuation model re-cased the term",
    TeachSentenceLocator.locate(
        term: "JWT",
        in: "The Jwt is rotated nightly.",
        proposals: [proposal(term: "JWT", heard: "J W T", outcome: "applied", at: 4, length: 3)]),
    .applied([span(4, 3)]))

// MARK: - Located via a KEPT proposal
//
// The design's own acceptance case. The gate BLOCKS applying a term over an
// everyday-word original by design and surfaces an ask per occurrence instead —
// so the sentence still says what was heard. Reading only the final text would
// report "not found" and teach the user their vocabulary is broken, on the one
// case picked to prove the feature works.

check(
    "kept proposal — common-word original, held back on purpose",
    TeachSentenceLocator.locate(
        term: "Vineet",
        in: "I think we need to ship it.",
        proposals: [proposal(term: "Vineet", heard: "we need", outcome: "kept", at: 8, length: 7)]),
    .heldBack(spans: [span(8, 7)], heard: "we need"))

// The heard text must come from a proposal that SURVIVED validation. Here the
// first kept proposal's span has drifted onto the wrong words and is dropped;
// reporting its `originalWord` anyway would show the user a phrase that is not
// the one highlighted.
check(
    "kept proposal — heard text follows the surviving span, not the first offered",
    TeachSentenceLocator.locate(
        term: "Vineet",
        in: "I think we need to ship it.",
        proposals: [
            proposal(term: "Vineet", heard: "vin eat", outcome: "kept", at: 0, length: 7),
            proposal(term: "Vineet", heard: "we need", outcome: "kept", at: 8, length: 7),
        ]),
    .heldBack(spans: [span(8, 7)], heard: "we need"))

// MARK: - Verbatim fallback
//
// No proposal was generated at all — the engine simply got it right. Whole-word
// matching, through the same normalization, so a trailing comma or a re-cased
// token still counts.

check(
    "verbatim, no proposals",
    TeachSentenceLocator.locate(term: "Vineet", in: "Vineet said hello.", proposals: []),
    .applied([span(0, 6)]))

check(
    "verbatim, re-cased and punctuated token",
    TeachSentenceLocator.locate(term: "JWT", in: "Rotate the jwt, please.", proposals: []),
    .applied([span(11, 4)]))

check(
    "verbatim, multi-word term",
    TeachSentenceLocator.locate(term: "Ramaa Nathan", in: "Ask Ramaa Nathan about it.", proposals: []),
    .applied([span(4, 12)]))

check(
    "verbatim never matches a word INSIDE a longer word",
    TeachSentenceLocator.locate(term: "Jot", in: "The jotter is on the desk.", proposals: []),
    .notFound)

// MARK: - Double occurrence
//
// Said twice, corrected once: the proposal covers one occurrence and the other
// is a verbatim hit. Both are the term, so both are highlighted.

check(
    "double occurrence — proposal plus verbatim",
    TeachSentenceLocator.locate(
        term: "Vineet",
        in: "Vineet met Vineet again.",
        proposals: [proposal(term: "Vineet", heard: "we need", outcome: "applied", at: 11, length: 6)]),
    .applied([span(0, 6), span(11, 6)]))

// MARK: - Not found
//
// The term is nowhere and nothing proposed it. This is the tap-correction
// branch: what the user taps becomes another sounds-like.

check(
    "not found",
    TeachSentenceLocator.locate(term: "Vineet", in: "I think we should ship.", proposals: []),
    .notFound)

check(
    "a proposal for a DIFFERENT term is not this term's evidence",
    TeachSentenceLocator.locate(
        term: "Vineet",
        in: "Ask Osiris about it.",
        proposals: [proposal(term: "Osiris", heard: "oh sirus", outcome: "applied", at: 4, length: 6)]),
    .notFound)

// MARK: - Fail safe
//
// Four transforms run after the gate; a span whose text no longer reads as the
// proposal claims is drift, and a guessed highlight is worse than none. The
// term is genuinely absent here, so it degrades all the way to not-found.

check(
    "drifted applied span, term absent — fail safe",
    TeachSentenceLocator.locate(
        term: "Vineet",
        in: "I think we should ship.",
        proposals: [proposal(term: "Vineet", heard: "we need", outcome: "applied", at: 2, length: 6)]),
    .notFound)

check(
    "out-of-range span cannot crash or highlight",
    TeachSentenceLocator.locate(
        term: "Vineet",
        in: "Short.",
        proposals: [proposal(term: "Vineet", heard: "we need", outcome: "applied", at: 40, length: 6)]),
    .notFound)

// ...but a drifted span over a term that IS in the text still finds it, via the
// verbatim pass. Reporting "not found" with the term sitting right there would
// be the same lie from the other direction.
check(
    "drifted applied span, term present — verbatim recovers it",
    TeachSentenceLocator.locate(
        term: "Vineet",
        in: "I met Vineet yesterday.",
        proposals: [proposal(term: "Vineet", heard: "we need", outcome: "applied", at: 0, length: 6)]),
    .applied([span(6, 6)]))

// MARK: - Word tokens (the tap substrate)

let tokens = TeachSentenceLocator.words(in: "  I think we need. ")
check("word tokens", tokens.map { TeachSentenceLocator.text(of: $0, in: "  I think we need. ") },
      ["I", "think", "we", "need."])
check("multi-word tap span",
      TeachSentenceLocator.text(
        of: span(tokens[2].start, tokens[3].end - tokens[2].start), in: "  I think we need. "),
      "we need.")

// MARK: - Tracing a tapped span back to the words that produced it
//
// The number pass rewrites spelled cardinals to digits AFTER the gate, so an
// alias read off the published text can be something the user never said. The
// guard has to be span-scoped: an unrelated number elsewhere in the sentence
// must not disarm it.

let gated = "I said for teen to him"
let final = "I said 14 to him"
// Hand-built forward map standing in for CorrectionProvenance.mapOffsets: the
// eight characters of "for teen" collapse onto the two of "14".
var handMap: [Int] = []
for i in 0...gated.count {
    if i <= 7 { handMap.append(i) }              // "I said " unchanged
    else if i <= 14 { handMap.append(7) }        // "for teen" (7...14) collapsed onto "14"
    else { handMap.append(i - 6) }               // the space at 15 onward, shifted left
}
check("tapped span maps back to the words that produced it",
      TeachSentenceLocator.sourceSpanText(
        finalSpan: span(7, 2), gatedText: gated, gatedToFinal: handMap),
      "for teen")
check("an unrelated span maps back to itself",
      TeachSentenceLocator.sourceSpanText(
        finalSpan: span(2, 4), gatedText: gated, gatedToFinal: handMap),
      "said")
check("identity map (nothing drifted) returns the span verbatim",
      TeachSentenceLocator.sourceSpanText(
        finalSpan: span(0, 6), gatedText: "Vineet said hello.", gatedToFinal: []),
      "Vineet")

// MARK: - Alias merge (what a tap, and every take, writes to disk)

check("merge appends new aliases in heard order",
      TeachSentenceLocator.mergeAliases(latestAliases: ["we need"], provisionalAliases: ["vin eat", "vineeth"]),
      ["we need", "vin eat", "vineeth"])
check("merge dedupes on the shared key (case + outer punctuation)",
      TeachSentenceLocator.mergeAliases(latestAliases: ["we need"], provisionalAliases: ["We need.", "(WE NEED)"]),
      ["we need"])
check("merge dedupes within the provisional list too",
      TeachSentenceLocator.mergeAliases(latestAliases: [], provisionalAliases: ["we need", "We Need"]),
      ["we need"])
check("merge preserves internal punctuation and word boundaries",
      TeachSentenceLocator.mergeAliases(latestAliases: ["cant"], provisionalAliases: ["can't"]),
      ["cant", "can't"])

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
