# Vocab hold-deck reliability — "what I tap is always what I get"

**Status:** v2 (2026-08-30) — REVISED per adversarial review
(`vocab-hold-deck-reliability-REVIEW.md`, verdict REVISE, all findings folded in below).
Implementation batches at the bottom.
**Owner decision:** Option A confirmed ("I don't think B is possible, but already I think we
are doing A"). No retro-editing of host-app text, ever.

## Problem

When the keyboard's correction deck asks about a word and the user answers, the answer
reliably updates the saved transcript but only *sometimes* the pasted text, and long
dictations sometimes surface a false error. Three divergence mechanisms and two error bugs,
all mapped with citations (exploration 2026-08-30):

| # | Mechanism | Where |
|---|---|---|
| D1 | Keyboard dismissed/reopened mid-deck loses the splice state — per-controller dicts (`deckDefaultText` etc., `JotKeyboardViewController.swift:317-326`) die with the controller while `hub.showAskDeck` persists; the re-entered flush hits `if hub.showAskDeck { return }` (`:1820`) before repopulating, so `handleAskDeckFinished` finds no default and pastes the raw payload (`:949-953`, `:1883`). Transcript flips, paste doesn't. | keyboard |
| D2a | **Case-only corrections are a GUARANTEED silent no-op** (Batch-1 review, MAJOR 1): `applyVerdicts`'s equal-after-trim guard uses `caseInsensitiveCompare` (`JotKeyboardViewController.swift:993`), so a pick that differs only in casing — `"Claude code"→"Claude Code"`, `"iphone"→"iPhone"`, the canonical 3-option `alt0` shape — generates NO edit, 100% of the time, while the queued verdict flips the saved transcript. Not intermittent; likely the owner's most-reproducible instance. Batch-2 consumer must compare `replacement == span.text` (descriptor carries verbatim baseline casing) instead of porting `:993`. |
| D2 | The staged-text splice has seven silent no-op conditions (`applyVerdicts`/`spliceRange`, `:971-1134`): no `publishedStart`; equal-after-trim; anchor out of range; zero in-window matches; 2+ matches; lone match not context-corroborated; missing `deckDefaultText`. Every failure keeps the default silently. | keyboard |
| D3 | Learning-only (`postPasteOnly`) cards render after the paste and never edit text **by design** (`CorrectionReviewStrip.swift:13-15`), but the card copy reads like a text choice. | product |
| E1 | Deck longer than the 30 s `ClipboardHandoff` freshness window (`ClipboardHandoff.swift:14`, worst-case deck ≈ 31–33 s) → `pasteSkipNoPayload` → **nothing pastes, nothing shown** (`:2220-2226`, `:2264-2269`). | keyboard |
| E2 | False red "Couldn't paste here — saved to clipboard" (`:2985`) on long dictations: the 350 ms settled-verify uses `documentContextBeforeInput.hasSuffix(pasteText)` (`:2082`), and iOS windows that property, so for pastes longer than the window the check is structurally false; the deck's added delay widens the proxy-disconnect window that then trips the failure floor (`:2103-2104`). | keyboard |

## Owner repro (2026-08-30) — the priority ordering

The owner's failure happens **at deck completion, without leaving the page**: "I'm on the
page, I am selecting the options, and once the options are done, that's when I get the
problem." Explicitly NOT the dismissed-mid-deck case ("where I moved out and stuff — that is
a totally different thing"). Long dictations, all cards answered, then either the picks are
missing from the paste or a red error shows.

That maps to **E2 (the visible error), D2 (picks missing), and E1** — note E1 fires in this
exact sequence too: three cards x dwell on a long dictation can cross the 30 s expiry while
the user is actively tapping, producing the "answered everything, nothing pasted" flavor.

**Priority: F4, F3, F2 are the owner's bug. F1 is hardening for a case the owner does not
hit (still worth doing — it shares the same state surface F2 reworks). F5 is an open
product question.**

## Goal

Under Option A: an answered ask is **always** reflected in the pasted text; a slow answer
never loses the paste; a long dictation never shows a false error. Concretely: the
`"ask-before-paste: applied verdict splices"` diagnostic (`:1017-1020`) reports
`spliced == requested` in normal operation, and the two error paths cannot fire when text
actually landed.

## Non-goals

- Option B / retro-editing already-inserted host text (`KeyboardUndoLedger.recordReplacement`
  stays dead; the teach-only contract on the post-paste strip stands).
- Any change to `VocabularyGate` / `VocabularyCorrector` / `AskPolicy` decision logic in
  jot-shared.
- Changing which asks are selected or how many (≤3 cap stays).

## Design (v2 — post-review)

### F1 — One hub-owned `ActiveDeck` state machine (fixes D1; review findings 1, 2, 4)

NOT four dictionaries. `KeyboardStreamingHub` gains a single `ActiveDeck` value:
`sessionID`, monotonically increasing `generation`, the asks, answered record keys +
verdicts, current index/engagement/deadline, and an explicit `phase`
(`.reviewing` / `.resolved(text:)` / `.inserting`). Rules:

- Every strip/controller action carries `(sessionID, generation)` and no-ops on mismatch —
  stale-controller commands (ghost controllers are a documented reality in this codebase)
  are fenced, not just serialized.
- Deck progress (stage/index/feedback) moves out of SwiftUI-local state so a remounted strip
  RESUMES at the first unanswered card instead of restarting. Re-answering an answered
  record is impossible (kills the last-wins-paste / first-wins-inbox divergence — verdicts
  are enqueued once, as a deduplicated batch at deck resolution).
- Timers become cancellable hub-owned deadlines (or `.task(id:)`), not free-floating `Task`s.
- Strict all-terminal cleanup: the `ActiveDeck` is cleared on successful paste, clipboard
  fallback, cancellation, stale-session rejection, supersession, and failed insertion.
  (Today the clipboard-fallback path consumes the payload without deck cleanup.)
- Only the ACTIVE controller for the matching generation may drive proxy insertion.

### F1b — The deck is modal for dictation (review finding 3; OWNER-VISIBLE product change)

While an `ActiveDeck` exists in `.reviewing`/`.resolved`/`.inserting`, the Dictate button is
disabled and the controller's mic decision refuses a new start. The cross-process transport
(pending-paste slot, handoff payload, asks payload) is single-slot; a second dictation
overwrites the first and cleanup races follow. Queueing all three transports is a much
larger redesign with no user demand — the deck resolves in seconds. If simultaneous decks
ever become a requirement, that redesign is the price.

### F2 — Phase-aware flush; deck text bypasses freshness (fixes E1; review finding 5)

The flush branches on the matching `ActiveDeck` BEFORE `ClipboardHandoff.readFresh()` (today
the freshness read runs first, so an expired payload never even reaches the deck gate):

1. `.reviewing` → return; no insert, no consume, no terminal cleanup.
2. `.resolved(text)` → paste that text, no age check; re-verify the pending-session match
   immediately before insertion (as the current path already does).
3. No matching deck → the normal fresh-payload path, untouched.

Review confirmed no post-publish mutation exists that a re-read would pick up — the handoff
text is frozen before asks are mapped. Process-restart recovery is OUT of scope for v2: the
hub dies with the extension process, and persisting a full transcript checkpoint is not
justified until a real eviction-mid-deck report exists (review finding 4). Recorded as a
known limit.

### F3 — Producer-validated exact edit descriptors (fixes D2, D2a; review findings 6, 7, 8 + Batch-1 review MAJORs 1–2)

Batch-1 review carry-forwards (decisions, not discoveries):
- **No-op test is `replacement == span.text`** (case-SENSITIVE, against the descriptor's
  verbatim baseline text) — never port the `caseInsensitiveCompare` guard (D2a).
- **Dropped-ask ratio watch:** the producer's `dropped`/`descriptors` diagnostic counts get
  read during the device soak; if material, unresolvable asks become CONFIRM-ONLY cards
  (paste-gating, disagreeing chip suppressed) instead of disappearing — preserving
  suppression, transcript flip, and learning.


The v1 idea (keyboard falls back to replaying the app-side pick) is DEAD: the review proved
`CorrectionReviewModel` has app-only dependencies, no fallback resolver, and records verdicts
even when its own edit fails — so "the replay will apply it anyway" was false. Correct
mechanism, validation moved to the producer:

- `CorrectionAsksPublisher` resolves every hold-deck ask against the immutable
  `publishedText` and emits an authoritative character start + the exact expected substring
  for each choice (base and `alt0`'s wider span, validated separately).
- An ask whose edit cannot be honored in the paste baseline is not offered as a
  paste-gating choice (logged). This deliberately relaxes the v1 non-goal about never
  changing ask selection — an unhonorable ask must not gate the paste.
- All candidate edit intervals are validated for NON-OVERLAP against the same baseline
  before the deck is shown (an `alt0` widened span can cover the next ask's word);
  conflicting cards are suppressed by deterministic precedence, and the keyboard defensively
  rejects any overlapping final batch.
- The keyboard verifies each expected substring against the unchanged baseline and applies
  validated non-overlapping edits in descending order. The pure span helper lives in
  `JotVocabCore`/`Shared` (Foundation-only; keyboard already links it).
- Bridge schema change is backward-compatible: old asks without descriptors keep today's
  splice path until the producer ships.

Metrics (review finding 7): replace `spliced == requested` with `answered` /
`editsRequired` / `editsApplied` / `alreadyDesired` / `unresolvable`. Equal-after-trim and
"stop asking" are SUCCESSES. Invariant: `editsApplied == editsRequired && unresolvable == 0`
for shown asks.

### F4 — Evidence-strength model for paste verification (fixes E2; review findings 9, 10)

The v1 suffix-overlap formula is DEAD: at window 0 an empty suffix vacuously matches, and a
1-char window proves one character — it would convert swallowed pastes into false successes
and false consumption. v2: a shared evidence helper returning explicit strength:

- `none` — nil/empty context (never proof of anything);
- `full` — the entire paste text fits and matches (today's strong signal, preserved);
- `partial(overlapLength:)` — exact tail equality over the available window when the paste
  is longer than the window.

Decision table per branch: `full` behaves as today. ~~`partial` plus
`settledLen >= immediateAfterLen` counts as survival~~ — **WRONG, caught by the F4 review
(BLOCKER 1): both values derive from the same context read, which the proxy cache can satisfy
after a swallowed paste (Path D), so that pair is one signal counted twice and must never
bypass `hasText`. With `hasText` added it is subsumed by the no-shrink arm — so settled
partial evidence is DIAGNOSTICS-ONLY, never a survival arm.** `partial` alone in the
disconnect branch stays INCONCLUSIVE and is classified not-survived; the windowed case is
answered UPSTREAM instead — by the `textDidChange` corroborated-partial confirm arm
(Option B, which resolves through `finalizeSuccess` before this branch is reached) and by
Option G downgrading the banner copy. The settled verify itself has no host-confirmation
input at all. Every
decision logs evidence source, nil/empty state, overlap length, full-fit status, and branch,
so the device gate can calibrate.

F4 lands separately behind its own device gate (below), never in the F1–F3 batch.

### F5 — Choice-specific, non-promissory card copy (addresses D3; review finding 11)

Post-paste teach cards get copy that promises only what every choice actually does: e.g.
"Preference recorded for next time" — not "Saved to vocabulary — future dictations will use
it" (untrue for the `original` choice, and not guaranteed even for `term`: a merge alias can
be skipped on conflict). The current "applied/restored" confirmation wording is wrong in
teach-only mode and is replaced. VoiceOver labels/hints updated together with visible copy.
## Edge cases

- Mid-deck dismissal with the HOST app also changing fields → deck state is per-session;
  the re-entered flush only fires for the session whose paste is still pending.
- Two dictations back-to-back, second staged while first's deck is open: deck state keyed by
  session UUID; F2 must consume the handoff for the deck session only if the handoff still
  belongs to that session (compare session IDs before consuming).
- F3's whole-text fallback and repeated words: reuse the pick-replay's own
  occurrence-disambiguation; if it is ambiguous there too, the miss is logged, not guessed.
- F4 with an EMPTY context window (host returns nil/empty): unchanged from today — falls to
  the `hasTextNow`/`settledLen` arm.

## F4 addendum — Option B + G (BUILT 2026-08-31, uncommitted)

The F4 evidence model alone could not reach the owner's headline case: for a paste longer
than the host's context window, the `textDidChange` fast path is structurally unable to fire
(`hasSuffix`/`contains` both false by length), so no host confirmation existed anywhere.
Landed on top of F4:

- **Option B** — a corroborated-partial arm in `maybeConfirmPasteViaTextDidChange`, gated on
  SIX conjunctions (windowed case only; entire window == our tail with ≤4 trailing-whitespace
  slack; window ≥64 chars — deliberately above the settled table's 24, because the unsafe
  failure direction is a consumed swallowed paste; our own post-insert read already showed
  the same tail; window non-shrinking; callback ≤1.0s after the insert). The trusted signal
  remains the host's change callback, which a proxy cache cannot fire. Residual risk (host
  re-render + stale cache holding ≥64 matching chars inside 1s) is attacked by the
  arm-2-specific forced-swallow negative control in the device gate.
- **Option G** — the `disconnect-inconclusive` branch's banner is now NEUTRAL ("Also saved to
  clipboard — tap to paste if it didn't land", amber chip); red "Couldn't paste" is kept for
  every affirmative-failure branch. The undecidable case stops calling a landed paste a
  failure in the user's face.

Device-gate additions for B: per-host window-size measurement (a sub-64 window makes arm 2
dead there), per-host `textDidChange` frequency for proxy inserts, trailing-whitespace hosts
vs the 4-char slack, the arm-2 forced-swallow negative control, and no-regression on arm 1.

**What actually ships as the E2 fix.** The settled-verify's partial machinery is
DIAGNOSTICS-ONLY (see BLOCKER 1 above) — it logs `settledEvidence`/`settledOverlap` for floor
calibration and decides nothing. The shipping E2 fix is therefore exactly **Option G + the
Option B confirm arm**. The device gate's pass/fail read follows from that: **if
`arm=corroborated-partial` never appears in the keyboard's `pasteLandedViaTextDidChange`
entries, Option B contributed nothing and Option G is the entire fix.** (Only the partial arm
logs that entry; the full arm's success is already logged by `finalizeSuccess`, so there is
one entry per event, not two.)

**Device gate — run long pastes THROUGH the correction deck.** The `disconnect-inconclusive`
population is produced by deck dwell: the review cards hold the keyboard while the host
re-renders and drops the input connection. A long paste with no deck in front of it will
mostly settle cleanly and exercise neither Option B nor Option G, so a gate run without the
deck proves nothing about either.

## Batch-1 review closing notes (feed Batch 2; full text in the review thread)

1. EditSpan fail-open: carry/assert `end`; `guard end > start` in `PasteEditResolver.resolve`
   (degenerate span currently slips past overlap validation as an insert-with-no-delete).
2. No-op test = `replacement == span.text`, case-sensitive (D2a).
3. Collapse the THREE copies of the algorithm: delete the keyboard's
   `spliceRange`/`contextCorroborates` in favor of `PasteEditResolver` (already linked);
   re-point `docs/harnesses/splice_check.swift` at the shared implementation.
4. Device soak reads `dropped`/`descriptors` before finalizing the deck shape; if material,
   unresolvable asks become confirm-only cards.
5. Fix the double-logged drop (`alt-unresolvable` then `base-overlap` double-counts).
6. Fix the order-independence comment in the alt pass (deterministic, but order-DEPENDENT).
7. Commit hygiene when the owner says commit: `CorrectionReviewStrip.swift` mixes F5 + themes;
   jot-shared mixes this thread with the NumberNormalizer/VocabularyCorrector batch.

## Test plan (v2 — review finding 12)

- Unit/harness: stale-generation fencing, duplicate-answer rejection, phase-aware expiry,
  blocked second dictation, session-scoped terminal cleanup, overlapping edit descriptors
  (incl. `altFind` covering the next ask), descriptor-vs-baseline mismatch rejection.
  `docs/harnesses/splice_check.swift` gains the descriptor path + re-synced mirror.
- Simulator: mid-deck dismiss/reopen resume-at-card; 35 s deck dwell → paste still lands.
- Device gate, F1–F3 batch (owner): long dictation with 2–3 asks → picks in pasted text AND
  saved transcript; dismiss/reopen mid-card; attempted second dictation while cards open;
  repeated words; `alt0`.
- Device gate, F4 (separate): native field + WKWebView + one React-Native/web host; short and
  long pastes; nil/empty/tiny/normal context; proxy disconnect; **negative control — a
  forced swallowed/reverted paste must still be flagged, inspecting actual host text**, not
  just banner absence.

## Implementation batches (review's landing order)

1. **Safe now:** F5 copy; F3 bridge schema + producer-side validator (backward-compatible,
   consumer behavior off).
2. **One coherent batch:** F1 + F1b + F2 + F3 consumer (`ActiveDeck` machine, modal deck,
   phase-aware flush, descriptor-applying keyboard).
3. **Separate, own device gate:** F4 evidence model.

## Known limits (accepted in v2)

- Batched verdicts mean a deck killed mid-review (terminal session, supersession, launch
  deadline, unresponsive-app recovery) discards its answers entirely — under the old
  tap-by-tap enqueue the transcript at least learned them. Deliberate: nothing pasted,
  nothing learned; the proposals stay reviewable in the app. (Batch-2 review, MINOR.)

- Extension eviction mid-deck loses the deck (hub is process-lifetime, not persisted).
  Revisit only on a real report.
- `documentContextBeforeInput` freshness/alignment across hostile hosts is not provable from
  source — F4's calibration comes from its device gate instrumentation.

- **Unicode window truncation.** A host window truncated mid-grapheme (or mid-surrogate) makes
  the tail comparison fail, degrading the evidence to `.none`. Fail-safe by construction: it
  can only produce FALSE NEGATIVES (an inconclusive/neutral-banner outcome for a paste that
  landed), never a false success.

- **`pastePartialConfirmFloor` counts Characters, not bytes or code points.** 64 Latin
  characters is a modest payload; 64 CJK ideographs is a much larger one, so the arm gates
  proportionally harder for CJK dictation. Accepted — the failure direction is again a false
  negative.

- **The deferred-verify closure's latch-vs-locals split** (the shared `inFlightPasteResolved`
  latch versus the values captured in the closure) predates F4 and is unchanged by it: a
  closure from an earlier paste could in principle read a latch belonging to a newer window.
  Practically unreachable — `isAutoPasteInsertInFlight` stays armed across the whole window
  and the modal deck blocks a second dictation — so it is documented, not fixed.
