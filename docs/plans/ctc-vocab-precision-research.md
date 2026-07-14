# CTC Vocabulary Rescoring — Precision Research

**Question (owner complaint):** "Sometimes it asks for words which actually don't
even match — 'did I mean that?' — so that part can be done better." I.e. the
vocabulary rescorer over-eagerly proposes a custom term when the spoken word does
not actually sound like it.

**Goal:** Understand exactly how candidate matching + substitution works today,
find the precision weakness with code evidence, and recommend low-risk,
on-device-feasible improvements that **stop suggesting non-matching words**,
accepting some loss of recall.

**Scope note / confidence:** All Jot-side logic (the `VocabularyGate`, the
`VocabularyRescorerHolder`, the asks publisher) was read in full and is quoted
below with high confidence. The FluidAudio internals are from the pinned checkout
of **FluidAudio 0.14.7** (`Jot/project.yml:36 exactVersion "0.14.7"`); I read the
actual rescorer/candidate-matching/evaluation source in that checkout. Where I
infer runtime behavior (e.g. which algorithm branch runs) I state the flag that
proves it.

---

## 1. Current implementation

### 1.1 Pipeline shape (where the rescore happens)

1. Parakeet **TDT** produces the 1-best transcript + per-token timings/confidence.
2. In parallel, the **CTC keyword-spot** pass runs over the raw audio
   (`TranscriptionService.swift:889-911` kicks `spot(...)` concurrently with the
   TDT transcribe; `VocabularyRescorerHolder.spot` →
   `CtcKeywordSpotter.spotKeywordsWithLogProbs`,
   `VocabularyRescorerHolder.swift:344-355`). This yields CTC **log-probs** per
   frame, not decisions.
3. The cheap **merge** step (`VocabularyRescorerHolder.mergeWithProposals`,
   `VocabularyRescorerHolder.swift:389-468`) calls FluidAudio's
   `rescorer.ctcTokenRescore(...)` (`:404-409`) to get proposed replacements,
   then runs Jot's own **`VocabularyGate`** (`:446-452`) as a precision brake, and
   records every gate decision to `CorrectionProvenance` (`:462-464`).
4. After the transcript is saved, `CorrectionAsksPublisher.publish`
   (`DictationPipeline.swift:383`) turns a subset of those recorded proposals into
   the keyboard "did you mean X?" **asks**.

So there are **two** stages that decide "is term Y a match for heard word X":
FluidAudio's rescorer (candidate generation + CTC vote) and Jot's `VocabularyGate`
(the brake). Both feed the asks surface.

### 1.2 FluidAudio candidate matching (FluidAudio 0.14.7)

Active branch: **term-centric**, because
`ContextBiasingConstants.useBkTree = false`
(`.../CustomVocabulary/ContextBiasingConstants.swift:272`), so
`ctcTokenRescore` dispatches to `rescoreWithConstrainedCTCTermCentric`
(`VocabularyRescorer+TokenRescoring.swift:151-171, 389-710`).

**Candidate selection is purely orthographic string similarity** — Levenshtein
distance over normalized letters, no phonetics:

- `stringSimilarity(a,b) = 1 - editDistance/maxLen`
  (`VocabularyRescorer+Utilities.swift:8-17`).
- Minimum floor to even consider a match:
  `ContextBiasingConstants.minSimilarityFloor = 0.50`
  (`ContextBiasingConstants.swift:89`). The doc-comment's own example admits how
  loose this is: `"nvidia" vs "nvida" = 0.83 ✓`, but the floor is 0.50.
- `requiredSimilarity` returns the bare `minSimilarity` (0.50) for single words,
  `max(minSimilarity, 0.55)` for multi-word spans
  (`VocabularyRescorer+Utilities.swift:77-86`).
- Guard rails that raise the bar in narrow cases only: short-word length-ratio
  guard raises to `shortWordSimilarity = 0.80` when the heard word is ≤4 chars
  and <75% of the term length (`+TokenEvaluation.swift:223-243`,
  `ContextBiasingConstants.swift:119,129,260`); stopword-span guard raises to
  `0.85` (`+TokenEvaluation.swift:185-213`, `:140`); a stopword *single* word is
  skipped entirely (`+TokenEvaluation.swift:195-198`, stopword set at
  `+TokenRescoring.swift:19-40`); terms shorter than
  `minTermLength = 3` are skipped (`+TokenRescoring.swift:265,425`).

**Crucially, which threshold is used at runtime:** `ctcTokenRescore`'s
`minSimilarity` parameter defaults to `ContextBiasingConstants.minSimilarityFloor`
(= 0.50) (`+TokenRescoring.swift:149`), and Jot calls it **without** overriding
that parameter (`VocabularyRescorerHolder.swift:404-409` passes only
`transcript/tokenTimings/logProbs/frameDuration`). So the effective candidate
floor in Jot is **0.50 orthographic similarity**. (Note: FluidAudio's
`CustomVocabularyContext.minSimilarity` field is **not** consulted by the rescore
path — the rescore uses the constant — so setting it on the context would have no
effect; the override must be passed to `ctcTokenRescore`.)

### 1.3 FluidAudio's acoustic decision (the CTC vote)

For each surviving candidate, `evaluateCTCMatch`
(`VocabularyRescorer+TokenEvaluation.swift:29-129`) scores the vocab term and the
original phrase with constrained CTC over the same frame window and decides:

```
boostedVocabScore = vocabCtcScore + adaptiveCbw(cbw)     // cbw default 3.0
shouldReplace     = boostedVocabScore > originalCtcScore  // :85-88
```

- `cbw` (context-biasing weight) default = **3.0**
  (`ContextBiasingConstants.swift:153`); its own comment: "Multiplies vocabulary
  term probability by ~20× (e^3.0)". This is a large, unconditional thumb on the
  scale in favor of replacement.
- The decision is a bare `>` — **no margin requirement and no length
  normalization.** A term wins whenever `vocabCtcScore > originalCtcScore − 3.0`,
  i.e. its *raw* acoustic evidence only has to come within 3.0 log-prob of the
  original. `adaptiveCbw` even *grows* the boost for longer terms
  (`VocabularyRescorer.swift:64-69`).

`RescoringResult.replacementScore` reported back to Jot is the **boosted** score
(`+TokenEvaluation.swift:166`), so the "+3.0" is baked into what Jot sees as the
margin.

### 1.4 Jot's `VocabularyGate` — the precision brake

`Jot/App/Vocabulary/VocabularyGate.swift`. Thresholds (`:39-46`):
`confidenceCeiling 0.95`, `lowConfidence 0.85`, `earnedMargin 4.0`,
`plausibilityCeiling 0.45`. The per-proposal decision ladder is `decide(...)`
(`:197-274`):

```
margin = (replacementScore ?? originalScore) − originalScore   // :203  (INCLUDES the +3.0 cbw)
(0) user-confirmed override pair          → OVERRIDE/BLOCK  (:226-238)
(1) plausibility: NOT plausible(...)      → BLOCK           (:252-254)
(2) multi-word term (contains " ")        → APPLY           (:257-259)
(3) confidence≥0.95 AND margin≤4.0        → BLOCK           (:261-263)
(4) common word (CommonWords.isCommon)    → BLOCK           (:269-271)
(5) otherwise (OOV-ish word)              → APPLY           (:272-273)
```

The **only** acoustic/phonetic-similarity gate is `plausible(...)`
(`:285-295`), and it is **still orthographic**: it compares letter *skeletons*
(lowercased alphanumerics, `skeleton(...)` `:300-304`) by normalized Levenshtein
ratio and passes if `ratio ≤ plausibilityCeiling (0.45)` against the term or any
alias. Calibration comments (`:278-283`) show it is tuned on spelling overlap:
`shriram→sriram 0.14`, `cloud→claude 0.33`, `jamie→jamy 0.40` pass;
`vikram→sriram 0.50`, `name→jamy 0.50` block.

### 1.5 The asks surface

`CorrectionAsksPublisher.publish` (`CorrectionAsksPublisher.swift:20-102`).
Every gate decision — **pass OR block** — is turned into a `Proposal` and recorded
to provenance (`VocabularyGate.apply` appends a `Proposal` for every surviving
item, `:168-183`; `mergeWithProposals` records `gated.proposals` `:462-464`).
`worthAsking` (`:64-67`) then surfaces a record if:

```
r.outcome == "applied"  ||  prior(r) > 0  ||  r.unsure
```

where `unsure` = the TDT confidence sat in `[0.85, 0.95)`
(`VocabularyGate.swift:215`). So a proposal the gate **BLOCKED** (outcome
`"kept"`) is still surfaced as an ask whenever the original word's TDT confidence
was middling. That is a direct path for "it asks about a word that doesn't match."

---

## 2. The precision weakness (concrete failure mode)

**Root cause: every "does X sound like Y?" judgement in the whole stack is made on
letters, not sound, and the one acoustic check (CTC) is deliberately biased toward
replacement and has no margin/length normalization.** Concretely:

1. **Orthographic candidate floor is very loose (0.50).** Half the letters can
   differ and a term is still a candidate (`ContextBiasingConstants.swift:89`,
   used at `VocabularyRescorer+Utilities.swift:77-86`). Letter overlap ≠ acoustic
   similarity — "Sriram" vs "Vikram" share letters but sound nothing alike.

2. **The CTC vote is a weak discriminator here.** `shouldReplace` is
   `vocabCtc + 3.0 > origCtc` with **no margin and no per-token normalization**
   (`+TokenEvaluation.swift:85-88`). The +3.0 (≈20×) boost means a term wins on
   thin, or even slightly negative, raw acoustic evidence — exactly the
   "over-eager substitution" the owner is describing. For short terms this is
   worst (few frames, small score differences, boost dominates).

3. **Jot's plausibility gate is also orthographic.** `plausible(...)` uses a
   letter-skeleton Levenshtein ratio ≤ 0.45 (`VocabularyGate.swift:285-304`). It
   catches gross spelling mismatches but, like the FluidAudio floor, cannot tell
   "sounds alike" from "spelled alike." Two words that share letters but not
   phonemes slip through.

4. **The OOV path (step 5) applies with NO acoustic bar at all.** For a
   non-common, single-word, plausible-by-spelling term,
   `decide(...)` returns `APPLY` (`VocabularyGate.swift:272-273`) with **no**
   margin check and **no** minimum acoustic-confidence check. The entire precision
   budget for the common "mis-heard rare name" case is: FluidAudio's
   +3.0-boosted CTC `>` vote **and** a 0.45 orthographic ratio. Neither is a
   phonetic test. (Steps 3/4 *do* impose a margin/common-word brake, but they only
   fire for confident or common originals — not the OOV names this feature
   targets.)

5. **The gate's `margin` is inflated by the cbw.** `margin = replacementScore −
   originalScore` and `replacementScore` already includes the +3.0
   (`VocabularyGate.swift:203`, `+TokenEvaluation.swift:166`). So `earnedMargin =
   4.0` really means "raw vocab CTC beat the original by >1.0" — and, again, step 5
   doesn't consult margin at all.

6. **Blocked/implausible proposals still reach the asks.** `worthAsking` surfaces
   any `unsure` record even when the gate said BLOCK
   (`CorrectionAsksPublisher.swift:64-67`), so the noisiest, least-matching
   proposals are precisely the ones that nag the owner.

**Net:** the failure the owner sees is not a bug in one line; it is the absence of
any *phonetic* gate plus a CTC decision rule that is tuned for recall (big boost,
bare `>`), and an asks filter that forwards even blocked guesses.

---

## 3. Options to improve (ranked by value / effort)

Precision-over-recall throughout: prefer to miss a real term over suggesting a
wrong one. All options are on-device, pure-Swift, and live in Jot code (no
FluidAudio fork required).

### R1 — Add a real phonetic plausibility gate (HIGHEST value, LOW effort)

**Where:** `VocabularyGate.plausible(...)` /
`Jot/App/Vocabulary/VocabularyGate.swift:285-304`.

**What:** Require phonetic agreement **in addition to** (logical AND, not OR) the
existing orthographic ceiling. Compute a phonetic code for the heard word and for
the term/aliases and require either equal codes or a small phonetic edit distance.
Options, cheapest first:

- **Double Metaphone** (two codes per word; designed for names, handles
  non-English) — a compact, well-understood ~150-line pure-Swift algorithm, no
  model, no data files. Require primary/secondary code overlap (or metaphone
  edit-distance ≤ 1). This is the standard cheap phonetic-match primitive and
  directly kills the "vikram→sriram / doesn't sound like it" class while keeping
  "cloud→claude", "jamie→jamy", "shriram→sriram" (they share metaphone codes).
- If Double Metaphone proves too coarse for some names, a **phoneme-edit-distance**
  gate using a G2P mapping is the literature-standard next step (see Sources), but
  there is no Apple public G2P and shipping a G2P model is far more effort — start
  with Metaphone.

**Why it's the top pick:** it fixes the actual missing dimension (sound), sits on
the cheap CPU merge path, is trivially unit-testable against the calibration pairs
already in the code comments (`VocabularyGate.swift:278-283`), and is
precision-first by construction (a term that doesn't sound alike is blocked
regardless of CTC boost). Keep the orthographic ceiling as a cheap pre-filter and
add phonetics as the gate.

**Risk:** low. It can only *block* more; worst case is a real term stops applying,
which is the acceptable direction. Metaphone is English-centric — gate it to the
Latin-script path and fall back to the current orthographic-only check for scripts
Metaphone can't encode (so non-English dictation isn't silently degraded).

### R2 — Raise the candidate floor Jot passes to FluidAudio (HIGH value, TINY effort)

**Where:** the `ctcTokenRescore` call at
`VocabularyRescorerHolder.swift:404-409`.

**What:** Pass an explicit higher `minSimilarity` (e.g. `0.62–0.68`) instead of
letting it default to the 0.50 floor (`+TokenRescoring.swift:149`). This culls
weak orthographic candidates *before* the +3.0-boosted CTC vote ever runs, so
fewer borderline pairs can be proposed at all.

**Why:** one-line, reversible, immediately reduces proposal volume (and therefore
asks). It is blunt (still orthographic) so it complements — does not replace — R1.

**Risk:** low; purely a numeric tightening. Calibrate against the same pairs; 0.65
keeps the intended `jamie→jamy (0.60?)`-class if desired, so tune with the owner's
real vocab. (Confidence that this parameter is the effective one: **high** — traced
the default and the call site.)

### R3 — Require real acoustic margin on the OOV apply path (HIGH value, MEDIUM effort)

**Where:** `VocabularyGate.decide(...)` step (5),
`Jot/App/Vocabulary/VocabularyGate.swift:272-273`.

**What:** Before the OOV `APPLY`, require the term to win on *un-boosted* acoustic
evidence, not merely survive the +3.0 thumb. Compute
`rawMargin = margin − cbwBaseline` (the cbw is a known constant 3.0, grown by
`adaptiveCbw` for >3 tokens) and require `rawMargin ≥ smallFloor` (e.g. `rawMargin
> 0`, meaning the term's raw CTC actually beat the original). Equivalently, gate on
a minimum *positive* margin above the boost. This turns "the boost decided" into
"the audio decided."

**Why:** directly attacks weakness #2/#4 — the acoustic check currently rubber-
stamps thin evidence. Precision-first.

**Risk / uncertainty:** medium. The gate only receives the **boosted**
`replacementScore` (`+TokenEvaluation.swift:166`); to subtract the boost precisely
the gate needs the token count (for `adaptiveCbw`). Either (a) thread `cbw` +
`vocabTokenCount` through `RescoringResult` (small FluidAudio-surface change, or
recompute in Jot from the term's `ctcTokenIds`), or (b) approximate with the
constant 3.0 and accept slight error for >3-token terms. Also CTC sums are
length-dependent, so consider per-token normalization when comparing — I have
**not** verified the exact score scale FluidAudio returns, so this needs an
on-device calibration pass before choosing the floor. Flag as "needs measurement."

### R4 — Stop surfacing blocked / implausible proposals as asks (MEDIUM value, TINY effort)

**Where:** `CorrectionAsksPublisher.worthAsking(...)`,
`CorrectionAsksPublisher.swift:64-67`.

**What:** Drop the bare `|| r.unsure` path for records the gate **BLOCKED**
(outcome `"kept"`), i.e. only ask on `outcome == "applied" || prior > 0`. Blocked
guesses remain visible on the transcript-review surface (which reads provenance
directly) but stop nagging on the keyboard.

**Why:** this is the most literal fix for "it *asks* for words that don't match" —
those are exactly the blocked/implausible-but-unsure records. Tiny, reversible.

**Design tension:** `unsure` was added to prioritize genuinely borderline calls for
review (comment at `CorrectionAsksPublisher.swift:56-60`,
`VocabularyGate.swift:211-215`). Removing it for *blocked* pairs is safe; keep it
for `applied` pairs so real borderline corrections still get a confirm. Discuss the
exact predicate with the owner.

### R5 — Tighten the orthographic `plausibilityCeiling` (LOW value, TINY effort)

**Where:** `VocabularyGate.plausibilityCeiling = 0.45`
(`VocabularyGate.swift:283`). Lowering it (e.g. 0.40) blocks more, but it is the
same orthographic axis R1 replaces properly, and the calibration comments show
real pairs sitting right at the boundary (`jamie→jamy 0.40`). Use only as a stop-
gap knob; R1 dominates it.

---

## 4. Recommendation

Ship **R1 + R2 + R4** together as the first, low-risk pass:

- **R1 (phonetic gate via Double Metaphone in `VocabularyGate.plausible`)** is the
  real fix — it adds the missing *sound* dimension exactly where the owner's
  "doesn't even match" pairs slip through, on the cheap CPU path, unit-testable
  against the pairs already documented in code.
- **R2 (raise `minSimilarity` at `VocabularyRescorerHolder.swift:404`)** is a
  one-line upstream cull that immediately lowers proposal/ask volume.
- **R4 (don't ask on blocked-unsure)** is the one-line fix for the *asks* symptom
  specifically.

Hold **R3 (raw-CTC-margin floor)** for a second pass — it is the most principled
acoustic fix but needs an on-device calibration of the CTC score scale and a small
plumbing change to recover the un-boosted margin; do it after R1/R2/R4 land and are
measured. Keep the master vocabulary toggle's "experimental / calibrate before
enable" posture (`VocabularyGate.swift:29-31`).

All four are precision-over-recall: each can only *reduce* substitutions/asks, so
the downside is a missed real term, never a new wrong one.

---

## 5. Sources

Code (this repo / pinned FluidAudio 0.14.7 checkout):
- `Jot/App/Vocabulary/VocabularyGate.swift` (gate, plausibility, thresholds)
- `Jot/App/Vocabulary/VocabularyRescorerHolder.swift` (spot/merge, rescore call)
- `Jot/App/Vocabulary/CorrectionAsksPublisher.swift` (asks policy)
- `Jot/App/Transcription/TranscriptionService.swift:889-960` (pipeline wiring)
- `Jot/App/Vocabulary/CtcModelCache.swift`, `VocabularySettingsView.swift` (model + UI)
- FluidAudio `.../CustomVocabulary/` : `ContextBiasingConstants.swift`,
  `Rescorer/VocabularyRescorer*.swift`, `BKTree/VocabularyRescorer+CandidateMatching.swift`

Web (contextual-biasing / phonetic-matching literature):
- [Fast Context-Biasing for CTC and Transducer ASR models with CTC-based Word Spotter (NeMo, arXiv:2406.07096)](https://arxiv.org/html/2406.07096) — the CTC-WS method FluidAudio implements; compares CTC-WS candidates against greedy CTC to cut false positives.
- [PARCO: Phoneme-Augmented Robust Contextual ASR via Contrastive Entity Disambiguation (arXiv:2509.04357)](https://arxiv.org/html/2509.04357) — phoneme-aware encoding + phoneme-edit-distance hard-negative selection to raise precision.
- [Phoneme-Aware Encoding for Prefix-Tree-Based Contextual ASR (arXiv:2312.09582)](https://arxiv.org/html/2312.09582v1) — feeding pronunciation (phonemes) to align bias words and generalize to unusual pronunciations.
- [Contextual biasing for ASR in speech LLM with common word cues and bias word position prediction (arXiv:2604.12398)](https://arxiv.org/html/2604.12398) — G2P pronunciation hints and common-word cueing.
- [GraphemeAug: Synthesized Hard Negative Keyword Spotting Examples (arXiv:2505.14814)](https://arxiv.org/html/2505.14814v2) — edit-distance-controlled hard negatives; too-small distance → false rejects, large enough → phonetically distinct.
- [Metaphone / Double Metaphone (Wikipedia)](https://en.wikipedia.org/wiki/Metaphone) and [Phonetic Matching Algorithms overview](https://medium.com/@ievgenii.shulitskyi/phonetic-matching-algorithms-50165e684526) — the cheap on-device phonetic primitive proposed in R1; a Fast Double Metaphone Swift implementation exists.

## Implementation outcome 2026-07-12 — R1 measured unnecessary; shipped R2 + R4 (build 270)
Ran a phonetic harness (`scratchpad/vocab-phon/`, jellyfish + doublemetaphone) over a curated 19-good / 14-bad pair set to test whether R1 (phonetic AND-gate) improves precision over the current orthographic gate:
- **ortho-only (ceil 0.45): recall 18/19, BAD leaks 0/14, precision 1.00.** The orthographic gate ALREADY blocks every bad pair (vikram→sriram, stream→sriram, name→jamy, …). The "bad pairs that leak through ortho" list was **empty** — R1 has nothing to add.
- Adding a phonetic AND-gate blocks nothing new and only **breaks good pairs** (double-metaphone drops shriram→sriram and raul→rahul; metaphone-exact drops 3). No phonetic threshold cleanly separates good/bad for short names (metaphone-edit≤1 is needed to keep shriram/sriram but that also admits stream/sriram).
- **Verdict: SKIP R1.** The complaint ("it asks about words that don't match") isn't a gate-plausibility miss — the gate correctly BLOCKS those; the bug is that they were still surfaced as keyboard asks.

**Shipped (build 270, v2.0.2):**
- **R4** — `CorrectionAsksPublisher.worthAsking`: dropped the `|| r.unsure` clause. A gate-BLOCKED (kept) proposal is no longer surfaced as a keyboard ask just because TDT confidence was middling; only APPLIED corrections + in-progress mappings (prior > 0) prompt. Blocked guesses remain on the transcript for review. This is the direct fix for the owner's complaint.
- **R2** — `VocabularyRescorerHolder` merge: passed `minSimilarity: 0.60` to `ctcTokenRescore` (was the FluidAudio default 0.50 floor). Culls the weakest upstream candidates. TUNABLE — flagged for on-device recall validation.
- **R3** (un-boosted CTC margin on the OOV path): still deferred — needs on-device CTC-score calibration.
- Harness kept at `scratchpad/vocab-phon/` if R1 is ever revisited with a richer pair set or a G2P phoneme-distance gate.

## Per-language common-word lists 2026-07-12 (build 271) — closes the non-English guard gap
Owner spotted it: the CTC vocab correction runs for every non-Apple-only language (English + the Parakeet-v3 European union — `vocabEnabledForThisRun = isEnabled && !LanguageChoice.current.isAppleOnly`; `isAppleOnly` is only the 4 CJK), but the common-word guard (`CommonWords`) checked a single **English** 24k list regardless of dictation language. So for Spanish/French/German/… the "never overwrite an everyday word" guard was inert (an everyday foreign word isn't in the English list → not protected; the plausibility + confidence guards still applied).

**Fix:** shipped **16 per-language lists** (`Resources/common-words-<code>.txt`, top ~24k from wordfreq/MIT — a bare word list is factual data) for the European set: es fr de it pt ro ru uk bg sr da nl fi el hu sv. Belarusian skipped (wordfreq has no real `be` data — falls back to no guard, unchanged). Names kept IN the lists (conservative — protects common foreign names; a real name-term just needs one confirm via the override path).

**Wiring:**
- `LanguageChoice.commonWordsResource` maps each language → resource base name (nil for Belarusian + CJK).
- `CommonWords.isCommon(_:resource:)` now takes the resource NAME (String), lazily loads + caches per list (one set in memory at a time). **Deliberately NOT a `LanguageChoice` param** — `CommonWords` compiles into the keyboard extension, which must not link FluidAudio (`LanguageChoice` imports it).
- `VocabularyGate.apply/decide` thread `language: LanguageChoice` (from `LanguageChoice.current` at the rescore merge) → pass `language.commonWordsResource`.
- `VocabularyAddInbox` uses `LanguageChoice.current.commonWordsResource`. The transcript-view add-filter and the keyboard add-filter stay English-default for v1 (lower-stakes user-initiated offers; the keyboard can't use `LanguageChoice` and only bundles `common-words.txt`).
- project.yml: the 16 lists ship in the MAIN APP target only (~1.5 MB compressed IPA growth), not the keyboard.
