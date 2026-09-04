# Adversarial review — `teach-by-voice-v2.md`

**Reviewer:** adversarial design pass, 2026-08-31. Read against the live working tree
(`jot-mobile` @ `d68453f` + uncommitted) and `~/code/jot-shared`.
**Verdict: REVISE** (2 BLOCKERs, 1 near-blocker, 8 MAJOR).

The design's *invariant* — "Jot never classifies a take; the user judges" — is right and
nothing below asks to weaken it. The problem is that the mechanism chosen to honour it
(*"run the real pipeline and see whether the term came out"*) reads only the pipeline's
**final text**, and the final text is precisely where the pipeline's own honesty is
destroyed: the gate deliberately declines to apply the plan's own flagship case, and four
post-gate transforms rewrite the span the design wants to highlight. The fix is not to grade
— it is to read the pipeline's **proposals**, which record what Jot found *and* what it chose
to do, and let the user judge that.

---

## BLOCKER

### 1. The plan's own device-gate test case can never pass validation. `VocabularyGate` refuses to apply a common-word original — by design.

`docs/plans/teach-by-voice-v2.md:125` names the acceptance test: teach **"Vineet"**,
historically heard **"we need"**. Trace it:

- `jot-shared/Sources/JotVocabCore/VocabularyGate.swift:1044` —
  `let isCommon = baseWords.contains { commonWords.contains($0.lowercased()) }`. For the
  span "we need", `baseWords == ["we","need"]` → `isCommon == true`.
- The user alias makes step (1) plausibility **pass** (`VocabularyGate.swift:1103`, aliases
  are threaded in from `VocabularyRescorerHolder.swift:523-527`).
- Term "Vineet" has no space → step (2) multi-word fast-path does not fire
  (`VocabularyGate.swift:1111`).
- Step (4), `VocabularyGate.swift:1123`: `if isCommon { return (false, …, "BLOCK", unsure, true) }`
  — *"Everyday word → NEVER silently rewrite … a common original is surfaced for review,
  never swapped."*

So phase 2 produces a sentence that **still says "we need"**. Under the plan's locator
(`teach-by-voice-v2.md:59-60`: "the corrector fired, or the canonical term appears verbatim")
both sources miss → the flow falls into **"Term NOT found — tap where `<term>` should be"**
(`:66-69`). The user taps "we need"; the code learns "we need" as an alias — **which it
already is**. The validation loops, reporting failure forever, on the one case the owner
picked to prove the feature.

Worse, it is *wrong*: in a real dictation this exact proposal is an **ask candidate**
(`askCandidate: true`, same line) and would have reached the user as a keyboard correction
card via `CorrectionAsksPublisher`/`AskPolicy`. The teach sheet does not run
`DictationPipeline`, so no ask is ever published (see finding 3) — the user sees only the
uncorrected text and is taught, by Jot, that their vocabulary does not work.

**Recommendation.** Locate from the gate **proposals**, not from the final text, and render
**three** states rather than two — all of them descriptive, none of them a verdict:

| proposal for this term | what the sheet says |
|---|---|
| `outcome == "applied"` | "Jot changed it to *`<term>`* here." (highlight) |
| `outcome == "kept"` (BLOCK/common-word) | "Jot found it here but held back — it asks first when the words it heard are everyday words." (highlight the span, offer the same accept/reject the keyboard card offers) |
| no proposal, term absent verbatim | the existing not-found flow |

Row 2 is the honest report of what the pipeline did; the user still judges. This also gives
the "No" branch something real to do — accepting is exactly the `alwaysReplace` grant that
`VocabularyGate.swift:1078` already implements for this case.

### 2. There is no seam to read this run's provenance. `pending` has no accessor, and `transcribe(samples:)` returns a bare `String`.

`teach-by-voice-v2.md:86-90` specifies phase 2 as "the normal `transcribe`", and
`:92-94` makes provenance the primary locator. Neither is reachable:

- `TranscriptionService.transcribe(samples:) -> String`
  (`Jot/App/Transcription/TranscriptionService.swift:434`). The proposals **exist** at the
  seam — `mergeWithProposals` returns them (`TranscriptionService.swift:1211`,
  `rescored.proposals`) and the model-free path has `corrected.proposals`
  (`TranscriptionService.swift:1242`) — and both are **discarded**; only
  `acousticProposals` (a count, `:1212`) survives.
- `CorrectionProvenance.pending` is `private var` with **no getter**
  (`jot-shared/…/CorrectionProvenance.swift:129`). The only exit is
  `commit(transcriptID:)` (`:180`), which writes
  `Vocabulary/provenance/<uuid>.json` (`:431-436`) — a file nothing ever cleans up
  (`discard(transcriptID:)` at `:419` is only called on transcript delete). Committing a
  teach run would litter the container with orphan payloads keyed to transcripts that do not
  exist.

**Recommendation.** Add an app-side `transcribeWithProposals(samples:) -> (text: String,
gatedText: String, proposals: [VocabularyGate.Proposal])` alongside the existing two modes at
`TranscriptionService.swift:434-447`, returning what `runInference` already computes. No
`jot-shared` change, no disk litter, no provenance coupling. Note `runInference` **must
still** call `CorrectionProvenance.shared.clearPending()` (`:1198`) so the teach run's
proposals cannot be committed under a later dictation's id — that guard already exists and
is load-bearing here.

---

## MAJOR

### 3. Q3 answered — and the plan's fear is unfounded, but for a reason it should record.

**No transcript is saved and no asks are published**, because everything that does either
lives in `DictationPipeline`, which the teach sheet never enters:
`CorrectionProvenance.shared.commit` + `CorrectionAsksPublisher.publish` are called exactly
once, from `Jot/App/Intents/DictationPipeline.swift:391-395`, both inside `if !transient`
(`:390`). The teach session calls `TranscriptionService.shared.transcribe…` **directly**
(`Jot/App/Vocabulary/TeachVocabularyByVoice.swift:276`), so there is no
`ClipboardHandoff.publish` (`DictationPipeline.swift:406`), no SwiftData append, no keyboard
mirror. Switching `recognizerOnly` → `fullPipeline` does **not** change that.

Two residues the plan should state explicitly:
- the run **does** leave proposals in `CorrectionProvenance`'s `pending` slot
  (`VocabularyRescorerHolder.swift:572` and `TranscriptionService.swift:1258`). Safe only
  because every `fullPipeline` run clears it first (`TranscriptionService.swift:1198`).
  Don't "optimise" that call away.
- the run does **not** touch `CorrectionStore` (no `adjust`, no `noteMergeAsked` — those are
  publisher-side, `CorrectionAsksPublisher.swift:126`), so it cannot pollute learned nets.
  Verified, worth writing down.

### 4. Q1 answered — neither of the plan's two options is the seam. The two vocabulary paths read from *different sources*.

`teach-by-voice-v2.md:131-134` frames this as overlay-vs-persist. The real shape:

- **Model-free corrector** reads the store in memory:
  `let terms = VocabularyStore.shared.terms` (`TranscriptionService.swift:1227`). An overlay
  here is trivial — pass a mutated `[VocabTerm]`.
- **Acoustic path** does **not** read the store at all. `VocabularyRescorerHolder`'s
  `vocabulary` is built exclusively by
  `rebuildVocabulary(from url: URL)` →
  `CustomVocabularyContext.loadFromSimpleFormat(from: url)`
  (`Jot/App/Vocabulary/VocabularyRescorerHolder.swift:216-223`) — i.e. **from the file on
  disk** — and every rebuild pays an `await VocabularyRescorer.create(…)`
  (`:247-253`), a CoreML rescorer build, then publishes to shared actor state behind a
  `generation` reentrancy token (`:257-268`). There is no in-memory ingress and no
  per-call vocabulary parameter (`spot(audioSamples:)` at `:417` reads `self.vocabulary`).

So a "per-run overlay" would mean mutating global actor state twice (install, restore),
racing every other dictation and every keystroke in the Vocabulary pane (finding 9).

**Recommendation — persist, then roll back.** The plan's stated fear ("stranding on crash")
is the *smaller* risk here and, with the always-visible Sounds-like row this same plan ships
(`teach-by-voice-v2.md:74-81`), the stranded state is a chip the user can see and delete.
Concretely: on entering phase 2, `VocabularyStore.shared.update(id:aliases:)` with the merged
provisionals; on Cancel, write the pre-phase-2 alias array back. Both paths then see the same
truth with zero new plumbing. If the owner rejects persist-then-rollback, the fallback is a
**new** `VocabularyRescorerHolder` API that builds a second context without replacing
`self.vocabulary` — not a swap-and-restore of the shared one.

### 5. Persist-then-rollback (or any store write) races the rescorer rebuild. `save()` fires and forgets.

`VocabularyStore.save()` ends with
`Task { try? await VocabularyRescorerHolder.shared.rebuildVocabulary(from: url) }`
(`Jot/App/Vocabulary/VocabularyStore.swift:120-124`) — **unstructured, no completion
signal**. If phase 2 starts recording immediately after the write, the CTC spot runs against
the *old* vocabulary and the provisional aliases are silently absent — the sentence test then
reports a failure caused by Jot's own scheduling.

`awaitReady(timeoutSeconds:)` (`VocabularyRescorerHolder.swift:90`) does **not** help: it
polls `isReady`, which is already `true` for the stale vocabulary (`:80-82`).

**Recommendation.** Have phase 2 `await` the rebuild directly (call
`rebuildVocabulary(from:)` itself and await it, rather than relying on `save()`'s fire-and-
forget Task), and show the existing "Starting…" progress state while it runs. Note the
`generation` guard at `:257-262` means a concurrent `save()` — e.g. a keystroke in the
Sounds-like field of another row — can supersede *your* rebuild; the sheet should block
store writes for the duration of phase 2.

### 6. Highlighting the span in the FINAL text is not robust — four transforms run after the gate, and the plan's own §"punctuation may re-case" note understates it.

`runInference` applies, in order, after the gate produces `gated.text`:

1. `ParagraphSegmenter.segment` — inserts newlines (`TranscriptionService.swift:1278`)
2. `applyLanguageCleanup` → `FillerWordCleaner.clean` then `NumberNormalizer.normalize`
   (`:1292`, definition at `:1330-1341`)
3. `applyPunctuationModel` → `PunctuationRestorer.shared.restore` — which, per its own
   doc comment at `:1360-1362`, **"strips existing case/punctuation before re-adding its
   own"** (`:1377`)

Every proposal's `publishedStart` is documented as valid **only** for `gated.text`
(`CorrectionProvenance.swift:130-135`: *"the ONLY text those offsets are valid for"*). By the
time the sheet sees the string, the anchors are stale by an unbounded amount.

**Recommendation.** The machinery already exists and is `public static` — use it:
`CorrectionProvenance.mapOffsets(anchors, old: gatedText, new: finalText)`
(`CorrectionProvenance.swift:313`) handles multi-region diffs and is the exact function
`reconciledPayload` uses for this same drift. Then resolve strictly with
`PasteEditResolver.resolve(needle:anchoredAt:in:contextBefore:contextAfter:)`
(`jot-shared/…/PasteEditResolver.swift:107`) and **fail safe** (no highlight, fall to the
not-found flow) rather than highlighting a guessed span. This is why finding 2's return type
must carry `gatedText` as well as the final text.

### 7. Aliases learned from a tapped span can be garbage the user never said — the number and filler passes rewrite the span first.

The plan learns the alias from the **final transcript** (`teach-by-voice-v2.md:96-97`:
"the span IS the heard text"). It is not:

- `NumberNormalizer.normalize` (`TranscriptionService.swift:1338`) converts spelled cardinals
  to digits. A term misheard as "four" becomes the span "4"; learning "4" as a sounds-like
  arms a correction that will fire on every numeral in every future dictation.
- `FillerWordCleaner.clean` (same line) **deletes** hesitation words. A term misheard as a
  filler is *gone* from the final text — so the branch that most deserves an alias
  (`teach-by-voice-v2.md:65`, "absent or eaten") is the one that records nothing.

**Recommendation.** Learn the alias from the **pre-cleanup** text (the `gatedText` you are
already returning), mapping the user's tap back through the same `mapOffsets` used for the
highlight. Never learn a span containing a digit that was not in the pre-normalization text.

### 8. Engine-parity inversion: with "Live text while dictating" OFF, the teach sentence runs on a *better* engine than the user's real dictations.

Parakeet Unified is the default English engine since build 297, and it has **no batch path** —
`unifiedEnglishPromote` promotes a streaming artifact and explicitly does no re-transcription
(`TranscriptionService.swift:660-663, 676`). No artifact ⇒ `stopPassTranscribe` falls through
to bundled Parakeet v2 (`:936` → `:964`).

The artifact is only deposited when a streaming session ran, and that is gated:
`guard DeviceCapability.liveTextEnabled || ownsActiveRecording`
(`Jot/App/Recording/RecordingService.swift:448`; contract in `Jot/ARCHITECTURE.md:98`).

- Real dictation, live text OFF → no session → **Parakeet v2**.
- Teach sheet → claims `ownsActiveRecording` before `start()`
  (`TeachVocabularyByVoice.swift:227-228`, before `:234`) → exemption applies → **Unified**.

So for that user the sentence test validates on an engine they never dictate with, which is
the exact opposite of "as if I hit record somewhere else"
(`teach-by-voice-v2.md:11-12`). Note also `ARCHITECTURE.md:98` names only Ask and the voice
prompt as the owned-capture exemption — the teach sheet's reliance on it is undocumented and
one refactor away from silently flipping teach onto v2 for *everyone*.

**Recommendation.** Read the engine that actually produced the phase-2 result and either
(a) refuse to run the sentence test when it differs from the engine the user's dictations use,
or (b) say so on screen. Also worth raising separately with whoever owns the Unified default:
"live text off ⇒ English silently downgrades to v2" looks like a real product bug independent
of this feature.

### 9. The teach entry point has **no** gating today. The plan's "keep today's gating" instruction has nothing to keep.

`teach-by-voice-v2.md:112-114` says the entry is hidden for Apple-routed/CJK languages
"exactly as today's gating (verify v1's gate; keep it)". Verified — **there is no gate**:

```
Jot/App/Settings/VocabularySettingsView.swift:400   if !term.text.trimmingCharacters(…).isEmpty {
Jot/App/Settings/VocabularySettingsView.swift:401       Button(action: onTeach) {
Jot/App/Settings/VocabularySettingsView.swift:402           Label("Teach it by voice", …)
```

The only condition is non-empty term text. No check of `VocabularyStore.shared.isEnabled`, of
`LanguageChoice.current.isVocabEligible` (`Jot/App/Transcription/LanguageChoice.swift:253`),
or of `CtcModelCache.shared.isCached`.

This is survivable for v1 (a take is just recognizer output). It is **not** survivable for
v2: the vocabulary apply in phase 2 is gated on
`VocabularyStore.shared.isEnabled && LanguageChoice.current.isVocabEligible`
(`TranscriptionService.swift:1071-1072` and again at `:1223-1224`). On Japanese, Korean,
Mandarin, Cantonese, LatAm Spanish, or with the master toggle off, **no proposal can ever be
produced**, so the sentence test reports not-found 100% of the time.

**Recommendation.** Add the gate this plan assumed existed: hide (or disable with a reason)
"Teach it by voice" unless `store.isEnabled && LanguageChoice.current.isVocabEligible`.
Phase 1 alone could stay available with the toggle off, but phase 2 must not be offered.

### 10. Keeping every distinct hearing "by default" has no collision guard — and the one that exists elsewhere is not on this path.

`teach-by-voice-v2.md:48-50` keeps every non-canonical hearing as an alias by default. v2 will
therefore write far more aliases than v1, plus tap-derived ones. But the **cross-term conflict
guard lives only in the review model**:

```
Jot/App/Vocabulary/CorrectionReviewModel.swift:157-168
  // never write a sounds-like that collides with ANOTHER term's text or aliases
```

Neither `VocabularyTeachingReducer.mergeAliases`
(`TeachVocabularyByVoice.swift:153-160`) nor `VocabularyStore.update(id:aliases:)`
(`VocabularyStore.swift:216-221`) applies it. Teaching term B an alias equal to term A's text
makes two terms compete for the same heard phrase, with no diagnostic.

Separately: a take heard as a common word ("the", "and") becomes an alias silently, and the
gate will then **propose-and-ask** on every occurrence of that word forever
(`VocabularyGate.swift:1123`) — chronic ask fatigue.

**Recommendation.** Reuse the `CorrectionReviewModel:158-163` conflict predicate at the teach
save path (skip + tell the user which term already owns the phrase). For common-word aliases,
do **not** reject — that is the 296 mistake — but reuse the warning affordance the term row
already has (`VocabularySettingsView.swift:427-436`, the orange triangle + explanation) so the
user chooses with the consequence visible.

### 11. Q2 answered: there is no word-span tap affordance, and no between-words affordance at all.

`MarkedTranscriptText` (`Jot/App/Vocabulary/MarkedTranscriptText.swift:17`) is the only
transcript renderer with tap handling, and it taps **pre-computed marks only**:

```
MarkedTranscriptText.swift:255   for m in parent.marks where NSLocationInRange(idx, m.range) {
```

With `marks` empty, `handleTap` returns immediately (`:247`, `guard … !parent.marks.isEmpty`).
Arbitrary word selection exists only through the iOS selection edit menu
(`:195-220`, `trimmedSelection(in:range:)` → `(String, NSRange)`), which needs a long-press and
drag handles. There is **nothing** for "tap between two words".

The teach sheet renders takes with plain SwiftUI `Text` (`TeachVocabularyByVoice.swift:492`),
which gives no per-word geometry at all — the reason `MarkedTranscriptText` is a
`UITextView` in the first place (`:12-16`).

**Recommendation.** (a) Reuse `MarkedTranscriptText`, extended so `handleTap` falls back to
word-boundary expansion of the hit character index when no mark contains it — the
`characterIndex(for:in:fractionOfDistanceBetweenInsertionPoints:)` call at `:251` already
gives you the index and the fraction. (b) **Cut the between-words insert case from v1.** It
needs a caret-placement UI that does not exist, and by the plan's own text (`:67-69`) it
records nothing and learns nothing — it is pure cost. "Nothing here matched" as a button is
the same information for a fraction of the work.

---

## MINOR

12. **The plan describes code that is not in the tree.** `teach-by-voice-v2.md:4-5` says the
    296 implementation "is still in the tree, dormant", and `:100-103` lists
    `matchesSoleUtterance`, `containsCommonWord` and the attempts-exhausted mechanic as
    things to delete. A case-insensitive grep across `Jot/App`, `Jot/Keyboard`, `Jot/Shared`,
    `Jot/Tests` and `jot-shared/Sources` returns **zero** matches for all three, and
    `git status` shows `Jot/App/Vocabulary/TeachVocabularyByVoice.swift` as untracked (`??`)
    — the reverted base, not the 296 build. An implementer will hunt for code that does not
    exist. Rewrite `:99-103` against the file as it stands.

13. **Load-bearing deletion (Q on the outcome taxonomy).** The only consumers are
    `TeachVocabularyByVoice.swift` itself (`:485-543`, the row/symbol/colour switches) and
    `Jot/Tests/VocabularyTeachingReducerTests.swift`, whose **11 tests are written entirely
    against `Outcome`** (`.term`, `.added`, `.known`, `.empty`, `.unusable`,
    `.formattingNoOp`). That target is real in `Jot/project.yml:546-555` and listed in the
    scheme at `:709`; it cannot currently build for the pre-existing FluidAudio reason, but
    deleting the enum makes it a *compile* failure rather than a link failure. The plan
    should say the tests are rewritten, not just "reducer/locator unit tests in the existing
    home" (`:120-121`).

14. **Docs pairing is missing from the plan entirely.** `Jot/features.md:542` and `:560` still
    describe the 296 behaviour — *"stops once Jot gets two takes in a row right (or after
    five tries)"*, *"Everyday-word mishearings are explained but never saved"* — which
    contradicts both the current tree **and** v2. `Jot/known-bugs-and-plans.md:205-215` still
    carries the 296 "BUILT, awaiting device test" entry. Per `Jot/CLAUDE.md`, updating
    `features.md` + the bug registry (+ Atlas if a screen shows this flow) is part of DONE.
    Add it to the plan.

15. **`Save` is currently gated on `maySave`** (`TeachVocabularyByVoice.swift:298-301`,
    `:443-447`), which is computed from the outcome taxonomy (`:144-149`). The plan says
    "Save always works" (`:71`). Deleting the taxonomy without replacing `maySave` leaves
    Save permanently disabled for a phase-2-only flow.

16. **`isTranscribing` busy-throw.** `transcribe(samples:)` throws `TranscriptionError.busy`
    if another transcription is in flight (`TranscriptionService.swift:465`). Phase 2 is a
    long, user-visible action; it needs a distinct message, not the generic "couldn't
    transcribe that take" at `TeachVocabularyByVoice.swift:280`.

17. **`unifiedEnglishPromote` is consume-on-read** (`TranscriptionService.swift:685`,
    unconditional `pendingStreamingArtifact = nil`, including on reject). Its doc comment
    already lists file-import and re-transcribe as interleaving hazards (`:679-684`); teach
    phase 2 is a third. Low probability (the sheet holds `ownsActiveRecording`) but add it to
    that comment when you touch this path.

18. **Per-keystroke rescorer rebuild, widened by the always-visible chips row.** The row
    binding writes through on every keystroke
    (`VocabularySettingsView.swift:329-336` → `VocabularyStore.update` → `save()`), and
    `save()` fires a full file write plus `rebuildVocabulary` — a CoreML
    `VocabularyRescorer.create` (`VocabularyRescorerHolder.swift:247`). Making the Sounds-like
    field visible on *every* row (`teach-by-voice-v2.md:76-78`) multiplies the exposure.
    Debounce the alias write (the local `soundsLikeDraft` at
    `VocabularySettingsView.swift:355` already isolates typing; commit on blur/return).

19. **Sheet state vs the row's live draft.** `VocabularyTeachingSession` snapshots `termText`
    and `existingAliases` at init (`TeachVocabularyByVoice.swift:183-186`) while `save()`
    re-reads the store (`:303`). With the Sounds-like field now always editable, a chip
    deleted behind the sheet is silently re-added by `mergeAliases`. Re-read the term when
    phase 2 begins, or block store writes while the sheet is up (see finding 5).

20. **Phase state machine is unspecified.** `hasDismissed` latches irreversibly
    (`TeachVocabularyByVoice.swift:179-220`) and `interactiveDismissDisabled` covers only
    start/capture/transcribe (`:451`). v2 adds phase-2 transcription, a confirm step and a
    tap-correction step; the plan says phase 1 "remains re-enterable" (`:51`) without saying
    what happens to a phase-2 result when the user goes back, or to a mid-phase-2 cancel.
    Specify the states and which of them block interactive dismiss.

---

## Answers to the plan's four open questions

**Q1 — provisional-alias injection seam.** Neither option as framed. The two vocabulary paths
read from *different sources*: the model-free corrector takes `VocabularyStore.shared.terms`
in memory (`TranscriptionService.swift:1227`), the acoustic path takes the **file on disk** via
`CustomVocabularyContext.loadFromSimpleFormat(from:)` behind an actor with no in-memory ingress
and a CoreML rebuild per change (`VocabularyRescorerHolder.swift:216-268`). Cheapest correct
seam is **persist-then-rollback-on-cancel**, awaiting the rebuild explicitly (findings 4, 5).

**Q2 — span-tap granularity.** Word-tap does not exist today; only mark-tap
(`MarkedTranscriptText.swift:255`) and edit-menu selection (`:195-220`). Extend
`MarkedTranscriptText.handleTap` to expand the hit index to word boundaries; **drop the
between-words insert affordance from v1** — it has no existing analogue and, per the plan's
own text, learns nothing (finding 11).

**Q3 — does phase 2 save a transcript?** No, and no asks are published either: saving,
provenance commit and ask publication all live in `DictationPipeline.swift:390-395`, which the
teach sheet never enters. The only residue is the `CorrectionProvenance` `pending` slot, which
the next dictation clears (`TranscriptionService.swift:1198`). Default "don't save" is correct
and needs no new gating — just record why (finding 3).

**Q4 — provenance-vs-verbatim precedence.** They answer different questions and cannot
genuinely disagree. **Proposals win**, always — including `outcome == "kept"` (BLOCK), which is
the case that matters most (finding 1). Verbatim search is the fallback for "no proposal was
generated at all", i.e. the engine already got it right. If both hit and point at different
spans, prefer the proposal and drop the verbatim hit; if the proposal's span will not resolve
after `mapOffsets` + `PasteEditResolver.resolve`, fail safe to not-found rather than
highlighting a guess (finding 6).

---

## Verdict: **REVISE**

Findings 1 and 2 are load-bearing — without them the feature ships a validation step that
reports failure on correct behaviour and has no way to read what the pipeline actually did.
Finding 9 (no entry gate) makes it report failure for whole languages. Everything else is
tractable within the current shape. The interface skeleton, the "user is the only judge"
invariant, and the two-phase structure all survive intact; what changes is *where the sheet
reads its truth from* — proposals and `gatedText`, not the final string.
