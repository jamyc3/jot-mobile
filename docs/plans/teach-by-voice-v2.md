# Teach by Voice v2 — the sentence test

**Status:** ✅ BUILT 2026-08-31, uncommitted, awaiting owner device-test. Design v2.1 —
adversarially REVISEd (2 BLOCKER / 8 MAJOR folded in below; evidence in `-REVIEW.md`).
Implementation notes, including the two review findings NOT folded into this design and
therefore NOT built, are in `Jot/known-bugs-and-plans.md` under "Teach a vocabulary term by
voice — v2". Locator coverage: `docs/harnesses/teach_locator_check.sh` (19 cases).
**Supersedes** the paused v1 redesign brief AND the build-296 implementation (whose inverted
classification is still in the tree, dormant). Owner on v1: "Teach by Voice was pretty cool,
but I feel that should be improved upon."

## Owner's spec (near-verbatim)

"Say it multiple times, and then use it in a sentence. When you use it in a sentence you
should be able to figure out where it is — we apply the vocabulary, whatever we have, as if I
hit record somewhere else — and if you're able to figure out where, you confirm it with the
user. If it doesn't work out, the user updates it: 'oh no, THIS is what it is.'"

Plus, same conversation: the term row's "Sounds like" line "doesn't look like it's editable"
— an affordance fix that ships with this work.

## Problem

Build 296 failed because **Jot graded itself**: the teach flow re-implemented a common-word
rule the gate already owns, with inverted logic ("Cloud code" ✅, "Claude code." ❌), and
attempts were burned on wrong verdicts. The deeper truth: *learning* a mishearing was never
the hard part — knowing whether the learned vocabulary actually FIRES in real dictation was.
Isolated repetition can't answer that: words sound different mid-sentence (coarticulation),
and the correction machinery behaves differently with context around the word.

## Goal

A teach flow where (a) Jot never classifies a take as right/wrong — the user is the only
judge; (b) learning is validated against a REAL dictation of a natural sentence, through the
exact production pipeline; (c) a failed validation itself teaches (the misheard span becomes
an alias).

## Non-Goals

- No changes to `VocabularyGate` / `VocabularyCorrector` / `AskPolicy` decision logic
  (jot-shared) beyond consuming existing APIs.
- No hardcoded terms, names, or phrases anywhere (standing owner rule).
- The liked v1 interface skeleton stays: sheet title, "Say <term>", big Record button,
  per-take list with delete, Cancel/Save.
- Phase 2 does not replace phase 1 — repetitions still seed aliases; the sentence validates.

## UX (two phases, one sheet)

### Phase 1 — "Say it a few times"
Unchanged skeleton. Each take shows a **neutral** result chip: `Heard: "we need"` — no
verdict icon, no "Got it right", no "everyday word" rejection. Every distinct hearing that
differs from the canonical term is a **candidate alias, kept by default**; the user deletes
any take that was noise (mumble, interruption). Hearing the canonical term exactly shows
`Heard: "Vineet" — matches`, informational only. After ≥2 takes the primary button becomes
**"Now use it in a sentence"** (phase 1 remains re-enterable).

### Phase 2 — the sentence test
Prompt: **"Say a sentence that uses <term> naturally."** One recording. It is transcribed by
the REAL pipeline — same engine routing, filler strip, number pass, punctuation model, and
the FULL vocabulary apply *including the phase-1 provisional aliases* — "as if I hit record
somewhere else." Then:

Outcomes (REVISED per review — locate from the run's PROPOSALS, not just applied text;
proposals win, including `outcome == "kept"`; verbatim whole-word search is only the
no-proposal fallback):

- **Applied** (the corrector fired, or the term appears verbatim): sentence with the term
  **highlighted** → **"Did I get it right?"** → Yes = validated; No = tap the wrong span,
  its heard text becomes another alias.
- **Found but held back** (REVIEW BLOCKER-1: the common-word gate BLOCKs applying over a
  common-word original BY DESIGN and asks per-occurrence instead — "we need"→Vineet is
  exactly this, so the plan's own acceptance case could never "pass" without this state):
  highlight where Jot found it and say **"Jot heard <term> here — in real dictations it
  will ask before changing this."** Confirm = validated-with-ask; correct = tap as above.
  Descriptive, not a grade — the invariant holds.
- **Not found**: **"Tap the word(s) that should have been <term>."** The tapped span's
  heard text becomes an alias. The between-words INSERT affordance is CUT (review Q2: no
  interaction substrate exists and an absence teaches nothing); a vanished term is
  retry-or-Save-anyway.

Save always works — validation is encouragement, not a gate. Cancel discards provisional
aliases, exactly as v1.

### The "Sounds like" affordance fix (term row)
Today the aliases line renders as caption-grey static-looking text, only when aliases exist.
Change: (a) style the field as an obvious input (bordered/filled field chrome, placeholder
"add a misheard form…"); (b) show the row ALWAYS once the term is non-empty (empty state =
placeholder), removing the aliases-exist gate; (c) aliases render as deletable chips with a
trailing add-field (chips match how the teach sheet shows them), falling back to the
comma-string editor only if chips are infeasible in this row. Keystroke-persist behavior and
the draft/round-trip guards stay.

## Mechanism

- **Phase-2 transcription** = the production inference path. Review Q3 verified the safe
  boundary: transcript saving, provenance commit, and keyboard ask-publishing all live in
  `DictationPipeline` (:390-395), which the teach sheet never enters — a teaching sentence
  saves nothing and publishes no asks, for free.
- **Reading the run's results** (REVIEW BLOCKER-2): `CorrectionProvenance.pending` is
  private and its only exit writes orphan per-transcript files; but `runInference` already
  holds the proposals and discards them (`TranscriptionService.swift:1211,1242`). Build a
  `transcribeWithProposals` variant returning `(text, proposals)`; the sheet locates from
  proposals (applied AND kept), verbatim search only when no proposal exists.
- **Provisional aliases** (review Q1): the two vocab paths read DIFFERENT sources — the
  model-free corrector reads `VocabularyStore.shared.terms` in memory; the acoustic path
  reads the FILE via `CustomVocabularyContext.loadFromSimpleFormat` plus a per-change
  CoreML rescorer rebuild. An overlay misses one or the other. Seam: PERSIST-THEN-ROLLBACK
  — write provisional aliases before the sentence run, roll back on Cancel — and AWAIT the
  rescorer rebuild explicitly (`save()` fires it in an unstructured Task with no completion
  signal; recording the sentence before the rebuild finishes tests stale vocabulary).
  Crash mid-teach leaves the aliases persisted: acceptable — real observations, deletable
  in the now-editable Sounds-like row.
- **User-tap correction:** the tapped span maps back to the heard text via the final
  transcript string (the span IS the heard text); `mergeAliases` (existing, kept) folds it
  in with the same dedupe/case rules.
- **What 296 code survives:** the session/recorder lifecycle, take list UI, `mergeAliases`,
  Cancel/Save semantics. **What dies:** the reducer's verdict taxonomy (`.term/.known/
  .empty/.unusable/.formattingNoOp` as user-facing judgments), `matchesSoleUtterance`'s
  case-sensitive comparison, `containsCommonWord` (the gate owns that question), and the
  attempts-exhausted mechanic (no grading ⇒ nothing to exhaust).

## Edge cases

- Term appears TWICE in the sentence → highlight all occurrences; confirm covers all.
- Sentence contains a DIFFERENT saved term that also corrected → its highlight is not shown
  (only the term being taught); its correction still applies (real pipeline).
- Phase-1 takes that hear the term exactly every time → phase 2 still offered (the point is
  context validation), but Save never blocked.
- Teach-entry gating (review MAJOR-3: TODAY THERE IS NO GATE — the button shows whenever
  term text is non-empty): v2 adds one — show "Teach it by voice" only when
  `VocabularyStore.isEnabled && LanguageChoice.current.isVocabEligible` (the exact pair
  phase 2's vocab apply is gated on); otherwise the sentence test reports not-found 100%
  of the time on CJK/LatAm-Spanish or with vocabulary off.
- Engine parity (review finding 8): with live text OFF, teach captures would have gotten
  Unified (ownsActiveRecording passes the session guard) while real dictations fell back
  to v2. ALREADY RESOLVED by the Unified-default MAJOR-3 fix (`liveTextEnabled` now gates
  `isOfferedForCurrentLanguage`, verified at UnifiedEnglishModel.swift:143) — add a
  regression assertion, not new code.
- Punctuation model may re-case the term ("JWT" etc.) — locating must compare through the
  same normalization the corrector uses, not raw string equality.

## Test plan

- Reducer/locator unit tests in the existing `VocabularyTeachingReducerTests` home (note:
  JotTests target still can't build — mirror the v1 approach: a standalone harness in
  `docs/harnesses/` if needed).
- Fixture cases: located-via-provenance, located-verbatim, not-found-absent, tap-correction
  alias merge, double-occurrence, punctuation-recased term.
- Device gate (owner): teach "Vineet" (historically heard "we need") end-to-end — phase 1
  collects, phase 2 sentence corrects and highlights, confirm; then a term Jot gets RIGHT
  natively; then a deliberately-wrong confirm ("No") with a tap-correction.

## Resolved questions (evidence in `teach-by-voice-v2-REVIEW.md`)

1. **Alias seam** → persist-then-rollback with an awaited rescorer rebuild (overlay is
   infeasible: the two vocab paths read different sources).
2. **Span tap** → new tappable word-token UI in the teach sheet (no existing substrate);
   whole-word snapping, multi-word via second tap; insert-between-words CUT.
3. **Saving** → phase 2 saves no transcript and publishes no keyboard asks (the
   `DictationPipeline` boundary is never entered).
4. **Locator precedence** → proposals always win, including `kept`; verbatim search only
   when no proposal exists.
