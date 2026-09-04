import Foundation
import JotVocabCore

/// Where the term the user is teaching ended up in their spoken sentence, and
/// what the vocabulary pipeline did about it.
///
/// This is deliberately the PURE half of teach-by-voice: no SwiftUI, no store,
/// no recorder, nothing app-only beyond `JotVocabCore`. `docs/harnesses/
/// teach_locator_check.sh` compiles this exact file (not a mirror of it)
/// together with its cases, which is the only test coverage the logic has while
/// the `JotTests` target can't build.
///
/// **The invariant it exists to protect:** Jot never classifies a take as right
/// or wrong. Every case below is a DESCRIPTION of what the pipeline did — it
/// applied the term, or it found the term and deliberately held back, or it
/// found nothing — and the user is the only judge of whether that was correct.
/// Build 296 shipped the opposite (Jot grading itself, with the grade inverted);
/// nothing here may grow a verdict.
enum TeachSentenceLocator {

    /// One gate proposal, reduced to what locating needs and with its span
    /// already mapped into the FINAL transcript's character space.
    ///
    /// The mapping is the caller's job because it needs `gatedText`, which only
    /// the transcription run has: a proposal's `publishedStart` is valid for
    /// the gate's output text and nothing else, and four transforms (paragraph
    /// segmenter, filler sweep, number normalizer, punctuation model) rewrite
    /// the string afterwards. `locate` re-checks every span against the
    /// sentence it was handed and drops the ones that no longer stand up, so a
    /// bad mapping degrades to "not found" rather than to a wrong highlight.
    struct Proposal: Equatable, Sendable {
        /// The vocabulary term this proposal is about.
        let term: String
        /// What the recognizer wrote — the heard form.
        let originalWord: String
        /// `"applied"` (the text became `term`) or `"kept"` (the gate found the
        /// term here and left the original standing — the common-word brake).
        let outcome: String
        /// Character offset of the span in the final transcript.
        let start: Int
        /// Character length of that span.
        let length: Int
    }

    /// A character range in the sentence, in the same Character-offset space
    /// `CorrectionProvenance.mapOffsets` works in.
    struct Span: Equatable, Sendable {
        let start: Int
        let length: Int

        var end: Int { start + length }
    }

    enum Result: Equatable, Sendable {
        /// The term stands in the sentence — the corrector applied it, or the
        /// engine wrote it unaided. Spans cover every occurrence.
        case applied([Span])
        /// The gate found the term at these spans and did not apply it. This is
        /// the common-word brake doing its job: in a real dictation the same
        /// proposal reaches the user as an ask instead of a silent rewrite.
        /// `heard` is what the recognizer wrote there.
        case heldBack(spans: [Span], heard: String)
        /// No proposal named the term and it is nowhere in the sentence.
        case notFound
    }

    /// Locate `term` in `sentence`.
    ///
    /// Precedence (resolved question 4 of the design): proposals win, including
    /// `"kept"` ones — they answer "what did the pipeline do", which the final
    /// text cannot. A verbatim search is the fallback for "no proposal survived
    /// at all", i.e. the engine already got it right on its own.
    ///
    /// Comparison is through `CorrectionKey.normalize` — the same NFC +
    /// case-fold + whitespace-collapse + outer-punctuation trim the corrector
    /// keys on — never raw equality, because the punctuation model strips and
    /// re-adds case and punctuation after the gate has run.
    static func locate(term: String, in sentence: String, proposals: [Proposal]) -> Result {
        let termKey = CorrectionKey.normalize(term)
        guard !termKey.isEmpty, !sentence.isEmpty else { return .notFound }
        let characters = Array(sentence)

        let mine = proposals.filter { CorrectionKey.normalize($0.term) == termKey }
        // A span is trusted only when the text standing at it still reads as
        // what the proposal says stands there. Anything else is drift from the
        // post-gate transform chain, and a guessed highlight is worse than none.
        let applied = mine
            .filter { $0.outcome == "applied" }
            .compactMap { validated($0, expecting: termKey, in: characters) }
        // Carry each surviving kept span WITH the word it stands for: validation
        // drops spans, so the heard text has to come from a proposal that
        // survived, not from the first one that was offered.
        let kept: [(span: Span, heard: String)] = mine
            .filter { $0.outcome == "kept" }
            .compactMap { proposal in
                validated(proposal, expecting: CorrectionKey.normalize(proposal.originalWord), in: characters)
                    .map { (span: $0, heard: proposal.originalWord) }
            }
            .sorted { $0.span.start < $1.span.start }

        let verbatim = verbatimSpans(termKey: termKey, in: characters)

        if !applied.isEmpty {
            // The user may have said the term twice with the gate correcting
            // only one of them; the other is a verbatim hit at a different
            // span. Both are occurrences of the term, and the design highlights
            // all of them.
            let extra = verbatim.filter { candidate in
                !applied.contains { $0.start < candidate.end && candidate.start < $0.end }
            }
            return .applied((applied + extra).sorted { $0.start < $1.start })
        }
        if let first = kept.first {
            return .heldBack(spans: kept.map(\.span), heard: first.heard)
        }
        if !verbatim.isEmpty { return .applied(verbatim) }
        return .notFound
    }

    /// The sentence's word tokens with their character spans — the substrate
    /// the sheet renders as tappable words, and the unit a tap snaps to. Shared
    /// with the verbatim search so a tap and a match can never disagree about
    /// where a word begins.
    static func words(in sentence: String) -> [Span] {
        var spans: [Span] = []
        var start: Int?
        let characters = Array(sentence)
        for (index, character) in characters.enumerated() {
            if character.isWhitespace {
                if let begin = start { spans.append(Span(start: begin, length: index - begin)) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let begin = start { spans.append(Span(start: begin, length: characters.count - begin)) }
        return spans
    }

    /// The text at `span`, for the sheet's highlight and for the alias a tap
    /// learns.
    static func text(of span: Span, in sentence: String) -> String {
        let characters = Array(sentence)
        guard span.start >= 0, span.end <= characters.count, span.length > 0 else { return "" }
        return String(characters[span.start..<span.end])
    }

    /// The PRE-CLEANUP text that produced `finalSpan` — the region of
    /// `gatedText` whose characters landed inside that span.
    ///
    /// Needed because the alias a tap learns is read off the published text,
    /// which the number pass has already rewritten: a term misheard as "four"
    /// arrives as the span "4", and learning "4" as a sounds-like would arm a
    /// correction that fires on every numeral in every future dictation. The
    /// check has to be SPAN-SCOPED — asking whether the whole sentence contains
    /// a digit disarms it the moment the user says any unrelated number.
    ///
    /// `gatedToFinal` is the forward map of every `gatedText` character offset
    /// into the final text (`CorrectionProvenance.mapOffsets` over `0..<count`);
    /// empty means the two strings are identical and the span maps to itself.
    static func sourceSpanText(
        finalSpan: Span, gatedText: String, gatedToFinal: [Int]
    ) -> String {
        let characters = Array(gatedText)
        guard !gatedToFinal.isEmpty else { return text(of: finalSpan, in: gatedText) }
        var low: Int?
        var high: Int?
        for index in 0..<min(characters.count, gatedToFinal.count) {
            let mapped = gatedToFinal[index]
            guard mapped >= finalSpan.start, mapped < finalSpan.end else { continue }
            if low == nil { low = index }
            high = index
        }
        guard let low, let high else { return "" }
        return String(characters[low...high])
    }

    /// Fold newly observed hearings into a term's existing sounds-like list,
    /// deduped on the shared correction key so a re-heard form never lands
    /// twice under different casing or punctuation. Order is preserved:
    /// existing aliases first, new ones in the order they were heard.
    ///
    /// Lives beside the locator (rather than with the sheet) so the harness
    /// covers it — a wrong merge here writes real vocabulary to disk.
    static func mergeAliases(latestAliases: [String], provisionalAliases: [String]) -> [String] {
        var merged = latestAliases
        var knownKeys = Set(latestAliases.map(CorrectionKey.normalize))
        for alias in provisionalAliases where knownKeys.insert(CorrectionKey.normalize(alias)).inserted {
            merged.append(alias)
        }
        return merged
    }

    // MARK: - Internals

    /// Returns the proposal's span only if the sentence still reads that way at
    /// those offsets. Fail-safe by construction: an offset shifted by the
    /// post-gate transforms produces a mismatch, not a wrong highlight.
    private static func validated(
        _ proposal: Proposal, expecting key: String, in characters: [Character]
    ) -> Span? {
        let start = proposal.start
        let end = proposal.start + proposal.length
        guard proposal.length > 0, start >= 0, end <= characters.count else { return nil }
        guard CorrectionKey.normalize(String(characters[start..<end])) == key else { return nil }
        return Span(start: start, length: proposal.length)
    }

    /// Whole-word occurrences of the term, matched on normalized word tokens so
    /// a re-cased or re-punctuated term ("JWT" written back as "Jwt.") still
    /// counts. A multi-word term matches a run of that many tokens.
    private static func verbatimSpans(termKey: String, in characters: [Character]) -> [Span] {
        let termWords = termKey.split(separator: " ").map(String.init)
        guard !termWords.isEmpty else { return [] }
        let tokens = words(in: String(characters))
        guard tokens.count >= termWords.count else { return [] }

        var spans: [Span] = []
        var index = 0
        while index + termWords.count <= tokens.count {
            let run = tokens[index..<(index + termWords.count)]
            let joined = run
                .map { CorrectionKey.normalize(String(characters[$0.start..<$0.end])) }
                .joined(separator: " ")
            if joined == termKey, let first = run.first, let last = run.last {
                spans.append(Span(start: first.start, length: last.end - first.start))
                index += termWords.count
            } else {
                index += 1
            }
        }
        return spans
    }
}
