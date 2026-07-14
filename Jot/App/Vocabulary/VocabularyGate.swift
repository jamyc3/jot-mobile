import FluidAudio
import Foundation
import os.log

/// **v1a — the gate.** A safety filter over FluidAudio's proposed vocabulary
/// replacements so a custom term can *never silently overwrite a word the
/// transcriber already got right.*
///
/// FluidAudio's rescorer (CTC word-spotting, NeMo arXiv:2406.07096) proposes
/// "replace word X with term Y when Y's acoustic score beats X". That swap has
/// no brake — it fires even on a 0.998-confidence correct word (the shipped
/// over-correction bug: adding "Jamy" turned every "name" into "Jamy"). This
/// gate adds the brake:
///   1. **Plausibility** — the heard word must be an acoustic cousin of the
///      term/alias (edit-distance bound). Kills "Vikram"→"Sriram"-class garbage.
///   2. **Confidence ceiling** — never auto-correct a word the TDT transcriber
///      was very sure about (the 0.998 protector).
///   3. **Common-word guard** — never overwrite an everyday word (frequency set)
///      unless the override is earned.
///   4. **Earned override** — a shaky word, or a term that wins by a large
///      margin, may still be corrected.
/// Multi-word phrase *terms* ("Claude Code") are precise and self-gating → allowed
/// (but only after plausibility).
///
/// Per-occurrence: TDT gives a separate confidence for each word occurrence
/// (no FluidAudio fork needed). See docs/plans/adaptive-vocabulary-correction.md
/// §3.2 / §0d / §0g.
///
/// NOTE: thresholds below are START values. A wider on-device calibration is a
/// pre-enable task; keep the master vocabulary toggle off until calibrated.
enum VocabularyGate {

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "VocabularyGate"
    )

    /// A word above this TDT confidence is never auto-corrected unless the term
    /// wins by a large margin. The 0.998-"name" protector.
    static let confidenceCeiling: Float = 0.95
    /// Below this confidence a word is "unsure" enough to be override-eligible.
    static let lowConfidence: Float = 0.85
    /// Boosted CTC margin (`replacementScore − originalScore`; includes the
    /// engine's cbw≈3.0) above which a correction counts as "earned" even
    /// against a confident or common word.
    static let earnedMargin: Float = 4.0

    /// An alternate candidate term for a proposal's span (3-option ask,
    /// 2026-07-13). `term` is the vocab term to offer; `find` is the EXACT
    /// in-text string it would replace (the winning span's published text
    /// plus the following transcript words the longer term extends over,
    /// e.g. find "Claude code" → term "Claude Code"). Computed at gate time
    /// because FluidAudio's merge prefers the SHORTER span and drops the
    /// longer term inside the package — Jot re-detects it here.
    struct Alternate: Codable, Sendable, Equatable {
        let term: String
        let find: String
    }

    /// One proposal the CTC spotter surfaced, with the gate's verdict — kept so
    /// the review surface can persist it per-transcript and let the owner
    /// adjudicate each **occurrence** later (plan §v2-A).
    struct Proposal: Sendable, Equatable {
        let originalWord: String     // what TDT wrote (e.g. "Jamie")
        let term: String             // the vocab term (e.g. "Jamy")
        let decision: String         // "APPLY" | "BLOCK" | "OVERRIDE"
        let outcome: String          // "applied" (text became `term`) | "kept" (text left `original`)
        let confidence: Float
        let margin: Float
        let unsure: Bool             // gate confidence near the decision boundary
        let occurrenceIndex: Int     // DISPLAY-ONLY FIFO arrival index — NOT an identity key
        // STABLE identity: char offset of the matched span in the ORIGINAL
        // (pre-rescore) transcript. Immutable provenance → safe as a verdict key.
        let originalStart: Int
        let originalLength: Int
        // Char span in the GATE-OUTPUT text. Becomes the provenance record's
        // LIVE anchor — kept valid across every later text change by
        // CorrectionProvenance's reconcile; resolution is strict (exact offset
        // or fail-safe), never proximity-guessed.
        let publishedStart: Int
        let publishedLength: Int
        // Alternate candidate terms for this span (3-option ask). Empty for
        // the common single-candidate case.
        let alternates: [Alternate]
        // V2-3: structural shape of the proposal. "merge" = the heard span
        // has MORE words than the term and its concatenation matches the
        // term (or an alias) — the split-word class ("sri ram" → "Sriram").
        // nil for ordinary proposals.
        let shape: String?
    }

    struct Result {
        let text: String
        let applied: Int
        let blocked: [String]        // originalWords that were protected
        let proposals: [Proposal]    // every decision, for per-transcript review (v1b)
    }

    /// Apply the gate to the rescorer output. Returns the gated transcript:
    /// each proposed replacement is re-checked and either kept or reverted to
    /// the original word. Reconstructs from `originalTranscript` (the un-boosted
    /// TDT text) so a blocked replacement cleanly leaves the original word.
    ///
    /// Replacements are resolved to their position in the transcript and applied
    /// in **positional order** — `output.replacements` is NOT left-to-right
    /// (the rescorer sorts by span length / similarity), so a forward-only pass
    /// would silently drop edits.
    static func apply(
        originalTranscript: String,
        output: VocabularyRescorer.RescoreOutput,
        tokenTimings: [TokenTiming],
        overrides: [CorrectionStore.OverrideEntry] = [],
        termAliases: [String: [String]] = [:],
        language: LanguageChoice = .english,
        allTerms: [String] = []
    ) -> Result {
        guard output.wasModified, !output.replacements.isEmpty else {
            return Result(text: output.text, applied: 0, blocked: [], proposals: [])
        }
        let wordConfidence = perWordMinConfidence(tokenTimings)

        // Resolve each replacement to a transcript range + its gate decision.
        // `occurrenceIndex` (FIFO arrival) is display-only; the STABLE identity is
        // `originalStart` (the span's char offset in the original text), computed
        // here while we still hold the authoritative range. Proposals are emitted
        // ONLY for spans that survive the positional overlap guard below, so the
        // provenance never contains a phantom record for a span that isn't in the
        // published text (plan §v2-A).
        struct Item {
            let r: VocabularyRescorer.RescoringResult
            let d: (pass: Bool, confidence: Float, margin: Float, label: String, unsure: Bool)
            let range: Range<String.Index>
            // The effective original span text — normally `r.originalWord`,
            // but WIDER when the dedup guard absorbed a following duplicate
            // word ("clawed" + following "code" for term "Claude Code" →
            // "clawed code"), so reverts/chips restore the full span.
            let originalWord: String
            let originalStart: Int
            let originalLength: Int
            let occurrenceIndex: Int
            let publishedText: String   // what occupies this span in the output (term if pass, else original)
        }
        var occurrence: [String: Int] = [:]
        var items: [Item] = []

        for r in output.replacements where r.shouldReplace {
            let key = r.originalWord.lowercased()
            let n = occurrence[key, default: 0]
            guard var range = nthWholeWordRange(of: r.originalWord, in: originalTranscript, occurrence: n) else {
                continue
            }
            occurrence[key] = n + 1

            // V2-1 · Alignment window (round-2 amendment). A multi-word term
            // must align to ONE unique edge-touching window inside its span;
            // extra span words survive; anything ambiguous blocks. Runs
            // BEFORE decide() so identity/learning use the aligned span.
            var alignmentBlocked = false
            var effectiveOriginal = r.originalWord
            if let term = r.replacementWord {
                let termWords = term.split(separator: " ").map(String.init)
                let spanWords = r.originalWord.split(separator: " ").map(String.init)
                if termWords.count >= 2, spanWords.count >= termWords.count {
                    switch Self.alignmentWindow(termWords: termWords, spanWords: spanWords) {
                    case .unique(let wordIndex):
                        if spanWords.count > termWords.count,
                           let sub = Self.wordSubrange(
                               of: range, wordIndex: wordIndex,
                               count: termWords.count, in: originalTranscript) {
                            range = sub
                            effectiveOriginal = String(originalTranscript[sub])
                            DiagnosticsLog.record(
                                source: "main-app", category: .vocabularyGate,
                                message: "align-narrowed \(r.originalWord) → \(effectiveOriginal)",
                                metadata: ["term": term])
                        }
                    case .blocked:
                        alignmentBlocked = true
                    }
                }
            }
            // Repeated-occurrence guard (round-2): the package gives no span
            // position, so the k-th-arrival→k-th-occurrence mapping can hit
            // the WRONG occurrence when the word repeats. Safe only when the
            // word occurs once, OR every occurrence has a proposal with the
            // SAME replacement (then order can't change the text). Otherwise
            // block to the pane.
            if !alignmentBlocked,
               nthWholeWordRange(of: r.originalWord, in: originalTranscript, occurrence: 1) != nil {
                // ≥2 textual occurrences. Count them + the proposals.
                var occCount = 2
                while nthWholeWordRange(of: r.originalWord, in: originalTranscript, occurrence: occCount) != nil {
                    occCount += 1
                }
                let siblings = output.replacements.filter {
                    $0.shouldReplace && $0.originalWord.lowercased() == key
                }
                let sameTerm = Set(siblings.map { ($0.replacementWord ?? "").lowercased() }).count == 1
                if siblings.count != occCount || !sameTerm {
                    alignmentBlocked = true
                    DiagnosticsLog.record(
                        source: "main-app", category: .vocabularyGate,
                        message: "occurrence-ambiguous \(r.originalWord) → \(r.replacementWord ?? "—")",
                        metadata: ["occurrences": "\(occCount)", "proposals": "\(siblings.count)"])
                }
            }

            // Dedup guard (owner bug 2026-07-13: saying "Claude code" heard
            // as "clawed code" applied the two-word term over just "clawed"
            // → "Claude Code code"). When a multi-word term covers FEWER
            // words than the term has, and the term's trailing word(s)
            // duplicate the transcript word(s) right after the span, widen
            // the span to absorb them so an apply can't double a word.
            // Runs BEFORE decide() (diff-review fix): the widened span IS the
            // proposal's identity, so learned demotions/overrides key on
            // "clawed code", and a revert actually blocks the next occurrence.
            // (Shape-gated only — widening a proposal that then blocks is
            // harmless; the record just shows the true span.)
            if let term = r.replacementWord, !alignmentBlocked,
               let widened = absorbTrailingDuplicates(
                   term: term, spanWord: effectiveOriginal,
                   range: range, in: originalTranscript) {
                range = widened
                effectiveOriginal = String(originalTranscript[widened])
                DiagnosticsLog.record(
                    source: "main-app",
                    category: .vocabularyGate,
                    message: "dedup-absorbed \(r.originalWord) → \(effectiveOriginal)",
                    metadata: ["term": term]
                )
            }

            // decide() consumes the EFFECTIVE identity (aligned-narrowed or
            // dedup-widened span text), not the raw engine span (diff-review
            // fix): plausibility/confidence/common-word/learned lookups must
            // all see the same words the replacement actually touches.
            var d = decide(
                r, originalWord: effectiveOriginal,
                wordConfidence: wordConfidence, overrides: overrides,
                aliases: termAliases[(r.replacementWord ?? "").lowercased()] ?? [],
                language: language)
            if alignmentBlocked, d.pass {
                // Force-block a proposal whose span identity is unsafe. The
                // proposal stays visible in the transcript pane for review.
                d = (false, d.confidence, d.margin, "BLOCK", d.unsure)
            }
            log.info(
                "gate \(r.originalWord, privacy: .public)→\(r.replacementWord ?? "—", privacy: .public): conf=\(d.confidence, format: .fixed(precision: 3)) margin=\(d.margin, format: .fixed(precision: 2)) \(d.label, privacy: .public)"
            )
            // Surface each decision in the in-app Help → Diagnostics card.
            // `netMargin` (R3 bootstrap, 2026-07-13): the margin with the
            // engine's context-biasing head-start (cbw≈3.0) subtracted — an
            // APPROXIMATION of "did the term win on acoustic merit alone?"
            // (long multi-token terms get an adaptive cbw slightly above 3.0,
            // so their true net is a bit lower than logged). Read these off
            // real dictations, join with the verdict logs, and calibrate the
            // R3 un-boosted-margin gate from the distribution.
            DiagnosticsLog.record(
                source: "main-app",
                category: .vocabularyGate,
                message: "\(r.originalWord) → \(r.replacementWord ?? "—")",
                metadata: [
                    "decision": d.label,
                    "conf": String(format: "%.3f", d.confidence),
                    "margin": String(format: "%.2f", d.margin),
                    "netMargin": String(format: "%.2f", d.margin - 3.0),
                ]
            )
            items.append(
                Item(
                    r: r,
                    d: d,
                    range: range,
                    originalWord: effectiveOriginal,
                    originalStart: originalTranscript.distance(from: originalTranscript.startIndex, to: range.lowerBound),
                    originalLength: originalTranscript.distance(from: range.lowerBound, to: range.upperBound),
                    occurrenceIndex: n,
                    publishedText: d.pass ? (r.replacementWord ?? r.originalWord) : String(originalTranscript[range])
                )
            )
        }

        items.sort {
            // Positional order; on an equal start (possible after V2-1
            // narrowing), the LONGER span wins the slot — it's the more
            // specific match (diff-review tie-break).
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound > $1.range.upperBound
        }

        var result = ""
        var cursor = originalTranscript.startIndex
        var applied = 0
        var blocked: [String] = []
        var proposals: [Proposal] = []
        for item in items {
            // Overlap guard — when two proposals claim overlapping spans
            // (e.g. terms "Claude" AND "Claude Code" both matching the same
            // audio), the leftmost-starting one wins and the rest are
            // dropped. Log the drop (2026-07-13): this was silent, which made
            // "I added Claude and Claude Code but only one works" untraceable.
            guard item.range.lowerBound >= cursor else {
                DiagnosticsLog.record(
                    source: "main-app",
                    category: .vocabularyGate,
                    message: "overlap-dropped \(item.originalWord) → \(item.r.replacementWord ?? "—")",
                    metadata: [
                        "decision": item.d.label,
                        "margin": String(format: "%.2f", item.d.margin),
                    ]
                )
                continue
            }
            result += originalTranscript[cursor..<item.range.lowerBound]
            let publishedStart = result.count
            result += item.publishedText
            // 3-option ask (2026-07-13): detect LONGER vocab siblings of the
            // winning term whose extension matches the words that follow in
            // the transcript ("Claude" won but "Claude Code" fits the audio +
            // next word). FluidAudio's merge prefers the shorter span and
            // drops the longer candidate inside the package, so it can never
            // reach this gate — re-derive it here so the ask can offer it.
            let alternates = extensionAlternates(
                winnerTerm: item.r.replacementWord,
                publishedText: item.publishedText,
                after: item.range.upperBound,
                in: originalTranscript,
                allTerms: allTerms)
            // V2-3 · merge-shape classification: span words > term words AND
            // the concatenated span EXACTLY equals the normalized term (or
            // one of its aliases) — the split-word class ("sri ram" →
            // "Sriram"). Shape rides the proposal so the ask publisher can
            // route it to the post-paste teach strip instead of silence.
            let shape: String? = {
                guard let term = item.r.replacementWord else { return nil }
                let spanWords = item.originalWord.split(separator: " ").map(String.init)
                let termWords = term.split(separator: " ")
                guard spanWords.count > termWords.count else { return nil }
                let concat = skeleton(spanWords.joined())
                let candidates = [term] + (termAliases[term.lowercased()] ?? [])
                for c in candidates where skeleton(c) == concat { return "merge" }
                return nil
            }()
            proposals.append(
                Proposal(
                    // Effective span text (dedup-widened when the guard
                    // absorbed a following duplicate) — reverts and ask
                    // chips must restore/show the FULL replaced span.
                    originalWord: item.originalWord,
                    term: item.r.replacementWord ?? item.r.originalWord,
                    decision: item.d.label,
                    outcome: item.d.pass ? "applied" : "kept",
                    confidence: item.d.confidence,
                    margin: item.d.margin,
                    unsure: item.d.unsure,
                    occurrenceIndex: item.occurrenceIndex,
                    originalStart: item.originalStart,
                    originalLength: item.originalLength,
                    publishedStart: publishedStart,
                    publishedLength: item.publishedText.count,
                    alternates: alternates,
                    shape: shape
                )
            )
            if item.d.pass { applied += 1 } else { blocked.append(String(originalTranscript[item.range])) }
            cursor = item.range.upperBound
        }
        result += originalTranscript[cursor...]
        return Result(text: result, applied: applied, blocked: blocked, proposals: proposals)
    }

    // MARK: - Gate decision

    /// Returns (pass, confidence, margin, label, unsure). `label` is APPLY /
    /// BLOCK / OVERRIDE so the caller can log + persist the verdict. `unsure` is
    /// true when the gate's confidence sits near the decision boundary (plan
    /// §v2-H) — used to prioritise the keyboard's quick-review asks.
    private static func decide(
        _ r: VocabularyRescorer.RescoringResult,
        originalWord: String? = nil,
        wordConfidence: [String: Float],
        overrides: [CorrectionStore.OverrideEntry],
        aliases: [String],
        language: LanguageChoice
    ) -> (pass: Bool, confidence: Float, margin: Float, label: String, unsure: Bool) {
        let margin = (r.replacementScore ?? r.originalScore) - r.originalScore
        // The EFFECTIVE span identity (aligned-narrowed / dedup-widened) when
        // the caller adjusted it; every guard below keys on this, so the
        // decision matches the words the replacement actually touches.
        let base = normalize(originalWord ?? r.originalWord)
        let term = r.replacementWord ?? ""
        let baseWords = base.split(separator: " ").map(String.init)
        let measured = baseWords.compactMap { wordConfidence[$0] }.min()
        let confidence = measured ?? lowConfidence
        let isCommon = baseWords.contains {
            CommonWords.isCommon($0, resource: language.commonWordsResource)
        }
        // Genuine acoustic uncertainty: a MEASURED confidence between "shaky" and
        // "sure". Unknown confidence (tokens missed the confidence map — common
        // for the OOV names this feature targets) is NOT unsure, so it doesn't
        // over-prioritise the keyboard asks. (NOT raw block-margin either — a
        // confident word blocked by a big margin is the gate working. plan §v2-H.)
        let unsure = measured.map { $0 >= lowConfidence && $0 < confidenceCeiling } ?? false

        // (0) USER-CONFIRMED OVERRIDE (top of the gate). A confirmed mapping
        //     fires on the spotter's proposal alone — bypassing the guards — for
        //     this exact (originalWord → term) pair only. **A common-word original
        //     is NEVER auto-applied** (plan §v2-B): silently rewriting an everyday
        //     word everywhere is the headline over-correction bug, and per-
        //     occurrence review can't undo a paste that already left the device.
        //     For common originals the gate keeps proposing-and-asking; only the
        //     UI pre-highlights the learned term. Auto-apply is reserved for
        //     rare/OOV originals (net ≥ 1) and multi-word terms (self-gating below).
        // Case-insensitive term compare (V2-2 identity fix, diff-reviewed
        // round 2): the engine re-cases replacements from sentence context
        // ("Claude" vs "claude"), while the store keys terms lowercased — a
        // case-sensitive compare here silently missed learned overrides and
        // demotions for differently-capitalized occurrences.
        if let ov = overrides.first(where: {
            $0.originalWord == base && $0.term.lowercased() == term.lowercased()
        }) {
            // DEMOTED: the owner reverted this mapping (via the marks/bubble or the
            // accordion) → stop auto-applying it. Works for common AND rare
            // originals, so a wrong auto-correction the owner undid stays undone.
            if ov.net <= -1 {
                return (false, confidence, margin, "BLOCK", unsure)
            }
            // V2-4 EXPLICIT GRANT: the owner tapped "Always replace 'X' with
            // 'Y'" — auto-apply even for a common-word original. §v2-B's
            // intent holds: the user consented explicitly, on-screen, for
            // this EXACT pair; one revert revokes the grant (store-side).
            if ov.alwaysReplace {
                return (true, confidence, margin, "OVERRIDE", unsure)
            }
            // CONFIRMED: auto-apply — rare/OOV originals only (common words never
            // auto-apply without the explicit grant, §v2-B).
            if !isCommon, ov.net >= 1 {
                return (true, confidence, margin, "OVERRIDE", unsure)
            }
        }

        // (1) PLAUSIBILITY — the heard word must be an acoustically plausible
        //     cousin of the term (or of ANY of its aliases — an alias is the user
        //     TELLING us the pair is plausible). The CTC matcher fuzzy-matches
        //     with a low similarity floor and concatenates neighbouring words, so
        //     it can propose "Vikram"→"Sriram" or "Ramanathan"→"Ramaa" — half the
        //     letters different. No acoustic margin makes those right. Spaces are
        //     ignored in the measure so a merged ASR word ("ramanathan") scores
        //     fairly against a multi-word term ("Ramaa Nathan"). Sits after (0)
        //     so an owner-confirmed mapping (net ≥ 1) is never second-guessed,
        //     and BEFORE the multi-word fast-path so it closes that bypass too.
        //     A block here still emits a reviewable "kept" record — confirming
        //     it in review teaches the exception (net ≥ 1 → step 0 override).
        if !plausible(original: base, term: term, aliases: aliases) {
            return (false, confidence, margin, "BLOCK", unsure)
        }

        // (2) A multi-word vocabulary TERM is precise and self-gating.
        if term.contains(" ") {
            return (true, confidence, margin, "APPLY", unsure)
        }
        // (3) Never overwrite a very confident word unless the term wins big.
        if confidence >= confidenceCeiling && margin <= earnedMargin {
            return (false, confidence, margin, "BLOCK", unsure)
        }
        // (4) Everyday word → NEVER silently rewrite (plan §v2-B). A common word
        //     is always proposed-and-asked per occurrence; the only paths that
        //     auto-apply are the rare/OOV override (step 0) and multi-word terms
        //     (step 2), both above. This is the headline "every name becomes Jamy"
        //     protection — a common original is surfaced for review, never swapped.
        if isCommon {
            return (false, confidence, margin, "BLOCK", unsure)
        }
        // (5) OOV-ish word (a likely name/jargon mis-hear) → allow.
        return (true, confidence, margin, "APPLY", unsure)
    }

    // MARK: - Alignment window (V2-1 — multi-word term over a WIDER span)

    /// Where a multi-word term's words sit inside a wider matched span.
    enum AlignmentResult: Equatable {
        /// Exactly one contiguous window aligns, touching a span edge —
        /// `wordIndex` is the window's first word index within the span.
        case unique(wordIndex: Int)
        /// No window aligns (e.g. span "Claude Claude" vs term "Claude
        /// Code") or more than one does (repeated words) or the only
        /// window is mid-span (extra words on BOTH sides). Precision-first:
        /// the proposal must BLOCK, never trim-and-guess.
        case blocked
    }

    /// V2-1 (round-2 amendment): a multi-word term may only apply to a span
    /// with MORE words than the term when the term's words form ONE unique,
    /// ordered, contiguous, edge-touching window inside the span (per-word
    /// skeleton alignment at the plausibility ceiling). Extra words outside
    /// the window SURVIVE the replacement ("use Claude code" → window
    /// "Claude code", "use" survives). Anything ambiguous blocks. This
    /// closes both round-2 breaks: the eaten leading word (ledger #1) and
    /// the equal-width-shifted span ("Claude Claude" never aligns to
    /// "Claude Code" because word 2 fails per-word alignment).
    static func alignmentWindow(termWords: [String], spanWords: [String]) -> AlignmentResult {
        guard termWords.count >= 2, spanWords.count > termWords.count else {
            // Equal width: require EVERY word to align (shifted spans block).
            if spanWords.count == termWords.count {
                let ok = zip(spanWords, termWords).allSatisfy { wordAligns($0, $1) }
                return ok ? .unique(wordIndex: 0) : .blocked
            }
            return .unique(wordIndex: 0)  // narrower span — dedup guard's domain
        }
        var matches: [Int] = []
        for start in 0...(spanWords.count - termWords.count) {
            let window = spanWords[start..<(start + termWords.count)]
            if zip(window, termWords).allSatisfy({ wordAligns($0, $1) }) {
                matches.append(start)
            }
        }
        guard matches.count == 1, let start = matches.first else { return .blocked }
        // Edge-touching: leading edge (start == 0) or trailing edge.
        let touchesEdge = start == 0 || start + termWords.count == spanWords.count
        return touchesEdge ? .unique(wordIndex: start) : .blocked
    }

    /// Per-word alignment at the same ceiling as the plausibility guard.
    private static func wordAligns(_ spanWord: String, _ termWord: String) -> Bool {
        let a = skeleton(spanWord)
        let b = skeleton(termWord)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return Double(levenshtein(a, b)) / Double(max(a.count, b.count)) <= plausibilityCeiling
    }

    /// Character range of `count` whole words starting at word index
    /// `wordIndex` within `range` in `text`. nil if the slice doesn't have
    /// that many words (defensive).
    private static func wordSubrange(
        of range: Range<String.Index>, wordIndex: Int, count: Int, in text: String
    ) -> Range<String.Index>? {
        var starts: [String.Index] = []
        var ends: [String.Index] = []
        var i = range.lowerBound
        var inWord = false
        while i < range.upperBound {
            if text[i] == " " {
                if inWord { ends.append(i); inWord = false }
            } else if !inWord {
                starts.append(i); inWord = true
            }
            i = text.index(after: i)
        }
        if inWord { ends.append(range.upperBound) }
        guard wordIndex + count <= starts.count, ends.count == starts.count else { return nil }
        // Trim the window's ends to alphanumerics (diff-review fix): boundary
        // punctuation must stay OUTSIDE the replaced range so "cloud code,"
        // → "Claude Code," keeps its comma. Leading trim on the first word,
        // trailing trim on the last.
        var lo = starts[wordIndex]
        let wordEnd = ends[wordIndex]
        while lo < wordEnd, !(text[lo].isLetter || text[lo].isNumber) {
            lo = text.index(after: lo)
        }
        var hi = ends[wordIndex + count - 1]
        let lastStart = starts[wordIndex + count - 1]
        while hi > lastStart {
            let prev = text.index(before: hi)
            if text[prev].isLetter || text[prev].isNumber { break }
            hi = prev
        }
        guard lo < hi else { return nil }
        return lo..<hi
    }

    // MARK: - Dedup guard (multi-word term over a narrower span)

    /// When a multi-word term is applied over a span with FEWER words than
    /// the term ("Claude Code" over just "clawed"), and the term's trailing
    /// word(s) duplicate the transcript word(s) immediately after the span,
    /// return the span widened to absorb those duplicates — so the apply
    /// yields "Claude Code" once, never "Claude Code code". Returns nil when
    /// nothing should be absorbed.
    ///
    /// Precision rules: absorb at most (term words − span words) words — a
    /// span that already covers every term word absorbs NOTHING, so a real
    /// following "code" ("Claude Code code review") is never eaten; only
    /// cross plain spaces (any punctuation or newline between blocks it);
    /// compare letter skeletons (case/punctuation-insensitive) and require
    /// EXACT equality; the widened span ends at the absorbed word's last
    /// alphanumeric so its trailing punctuation survives outside the span.
    private static func absorbTrailingDuplicates(
        term: String,
        spanWord: String,
        range: Range<String.Index>,
        in text: String
    ) -> Range<String.Index>? {
        let termSkels = term.split(separator: " ").map { skeleton(String($0)) }
        let spanWordCount = spanWord.split(separator: " ").count
        let maxAbsorb = termSkels.count - spanWordCount
        guard maxAbsorb >= 1 else { return nil }

        // Collect up to `maxAbsorb` following words (plain-space separated).
        var follow: [(skel: [Character], letterEnd: String.Index)] = []
        var i = range.upperBound
        scan: while follow.count < maxAbsorb, i < text.endIndex {
            // Cross plain spaces only — punctuation/newline ends the run.
            guard text[i] == " " else { break }
            while i < text.endIndex, text[i] == " " { i = text.index(after: i) }
            guard i < text.endIndex, text[i].isLetter || text[i].isNumber else { break }
            // Read the token up to the next space/newline; track its last
            // alphanumeric so "code," absorbs as "code" and keeps the comma.
            var wordEnd = i
            var lastAlnum = i
            while wordEnd < text.endIndex, text[wordEnd] != " ", text[wordEnd] != "\n" {
                if text[wordEnd].isLetter || text[wordEnd].isNumber { lastAlnum = wordEnd }
                wordEnd = text.index(after: wordEnd)
            }
            let letterEnd = text.index(after: lastAlnum)
            follow.append((skeleton(String(text[i..<letterEnd])), letterEnd))
            // Trailing punctuation on this token ends the absorbable run.
            if letterEnd != wordEnd { break scan }
            i = wordEnd
        }
        guard !follow.isEmpty else { return nil }

        // Longest suffix of the term's words that equals the following words.
        var n = min(maxAbsorb, follow.count)
        while n > 0 {
            let tail = Array(termSkels.suffix(n))
            let head = follow.prefix(n).map(\.skel)
            if tail == head {
                return range.lowerBound..<follow[n - 1].letterEnd
            }
            n -= 1
        }
        return nil
    }

    // MARK: - Extension alternates (3-option ask)

    /// Longer vocab siblings of the winning term whose extra words match the
    /// transcript words that FOLLOW the span. FluidAudio's greedy merge
    /// prefers the SHORTER span ("Prefer shorter spans", its Pass 2), so when
    /// the user's list has both "Claude" and "Claude Code", "Claude" always
    /// wins and the longer candidate is dropped inside the package — this
    /// re-derives it so the ask card can offer all three choices. The
    /// extension words must be an acoustic cousin of what follows (same
    /// skeleton-distance ceiling as the plausibility guard), and never cross
    /// a paragraph break. Capped at 2 (the keyboard card surfaces 1).
    private static func extensionAlternates(
        winnerTerm: String?,
        publishedText: String,
        after upperBound: String.Index,
        in transcript: String,
        allTerms: [String]
    ) -> [Alternate] {
        guard let winner = winnerTerm, !winner.isEmpty, !allTerms.isEmpty else { return [] }
        let winnerLower = winner.lowercased()
        var out: [Alternate] = []
        for term in allTerms {
            guard out.count < 2 else { break }
            let termLower = term.lowercased()
            guard termLower != winnerLower,
                  termLower.hasPrefix(winnerLower + " ") else { continue }
            let extensionText = String(term.dropFirst(winner.count))
                .trimmingCharacters(in: .whitespaces)
            let extWords = extensionText.split(separator: " ").map(String.init)
            guard !extWords.isEmpty else { continue }
            let follow = nextWords(count: extWords.count, after: upperBound, in: transcript)
            guard follow.count == extWords.count, let lastEnd = follow.last?.end else { continue }
            let a = skeleton(follow.map(\.word).joined())
            let b = skeleton(extensionText)
            guard !a.isEmpty, !b.isEmpty else { continue }
            let ratio = Double(levenshtein(a, b)) / Double(max(a.count, b.count))
            guard ratio <= plausibilityCeiling else { continue }
            // `find` is built from the EXACT transcript slice after the span
            // (diff-review fix): double spaces / odd separators are preserved
            // verbatim so the strict anchored splice can actually match.
            out.append(
                Alternate(
                    term: term,
                    find: publishedText + String(transcript[upperBound..<lastEnd])
                )
            )
        }
        return out
    }

    /// The next `count` space-separated words after `start` in `text`,
    /// each with its end index (trailing punctuation retained — consumers
    /// trim it; stops at a newline so an alternate never extends across a
    /// paragraph break).
    private static func nextWords(
        count: Int, after start: String.Index, in text: String
    ) -> [(word: String, end: String.Index)] {
        var words: [(word: String, end: String.Index)] = []
        var current = ""
        var i = start
        while i < text.endIndex, words.count < count {
            let ch = text[i]
            if ch == "\n" { break }
            if ch == " " {
                if !current.isEmpty { words.append((current, i)); current = "" }
            } else {
                current.append(ch)
            }
            i = text.index(after: i)
        }
        if !current.isEmpty, words.count < count { words.append((current, i)) }
        return words
    }

    // MARK: - Plausibility (guard 1)

    /// Max normalized edit distance (Levenshtein over letter-skeletons, divided
    /// by the longer skeleton) for the heard word to count as an acoustic cousin
    /// of the term. Measured on real pairs: shriram→sriram 0.14, cloud→claude
    /// 0.33, jamie→jamy 0.40 (all pass); vikram→sriram 0.50, ramanathan→ramaa
    /// 0.50, name→jamy 0.50 (all block).
    static let plausibilityCeiling: Double = 0.45

    private static func plausible(original: String, term: String, aliases: [String]) -> Bool {
        let heard = skeleton(original)
        guard !heard.isEmpty else { return true }
        for candidate in [term] + aliases {
            let c = skeleton(candidate)
            guard !c.isEmpty else { continue }
            let ratio = Double(levenshtein(heard, c)) / Double(max(heard.count, c.count))
            if ratio <= plausibilityCeiling { return true }
        }
        return false
    }

    /// Lowercased alphanumerics only — spaces and punctuation dropped so a
    /// merged ASR word ("ramanathan") measures fairly against a multi-word
    /// term ("Ramaa Nathan" → "ramaanathan"). NFC-precomposed first
    /// (diff-review fix) so canonically-equivalent Unicode (composed vs
    /// decomposed "é") skeletons identically instead of dropping a
    /// combining mark.
    private static func skeleton(_ s: String) -> [Character] {
        s.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init)
    }

    /// Plain two-row Levenshtein. Inputs are short (words/short phrases), so
    /// O(a·b) is trivially cheap even on the transcription hot path.
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: - Helpers

    private static func normalize(_ s: String) -> String {
        // Diff-review fix: MUST be the same normalization the store keys use
        // (`CorrectionKey`) — the override lookup compares this output to
        // store-normalized keys, and any divergence (NFC, whitespace runs)
        // silently misses learned overrides/demotions.
        CorrectionKey.normalize(s)
    }

    /// Per-word minimum *content-token* confidence, keyed by lowercased word.
    /// A new word begins at a token with a leading space / `▁` boundary; the
    /// minimum is taken over alphabetic (content) tokens only — punctuation and
    /// casing tokens would otherwise produce false low-confidence flags. When a
    /// word repeats, the lowest occurrence's confidence is kept (conservative).
    private static func perWordMinConfidence(_ timings: [TokenTiming]) -> [String: Float] {
        var out: [String: Float] = [:]
        var word = ""
        var minConf: Float = 1.0

        func flush() {
            let key = normalize(word)
            if !key.isEmpty {
                out[key] = min(out[key] ?? 1.0, minConf)
            }
            word = ""
            minConf = 1.0
        }

        for t in timings {
            let startsWord = t.token.hasPrefix(" ") || t.token.hasPrefix("\u{2581}")
            let piece = t.token
                .replacingOccurrences(of: "\u{2581}", with: "")
                .trimmingCharacters(in: .whitespaces)
            if startsWord { flush() }
            word += piece
            if piece.rangeOfCharacter(from: .letters) != nil {
                minConf = min(minConf, t.confidence)
            }
        }
        flush()
        return out
    }

    /// The `occurrence`-th (0-based) whole-word range of `word` in `text`.
    private static func nthWholeWordRange(
        of word: String,
        in text: String,
        occurrence n: Int
    ) -> Range<String.Index>? {
        var search = text.startIndex
        var count = 0
        while let r = wholeWordRange(of: word, in: text, from: search) {
            if count == n { return r }
            count += 1
            search = r.upperBound
        }
        return nil
    }

    /// Whole-word range of `word` in `text` at/after `from` (so "name" does not
    /// match inside "rename"). `word` may itself be a multi-word phrase.
    private static func wholeWordRange(
        of word: String,
        in text: String,
        from: String.Index
    ) -> Range<String.Index>? {
        var search = from
        while let r = text.range(of: word, options: [.caseInsensitive], range: search..<text.endIndex) {
            let before: Character? = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after: Character? = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            let okBefore = !(before?.isLetter ?? false)
            let okAfter = !(after?.isLetter ?? false)
            if okBefore && okAfter { return r }
            search = r.upperBound
        }
        return nil
    }
}
