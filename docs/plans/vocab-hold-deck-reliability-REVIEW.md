# Adversarial review — vocab hold-deck reliability

**Plan reviewed:** `docs/plans/vocab-hold-deck-reliability.md`  
**Review confidence:** 98%  
**Verdict:** REVISE

The plan identifies real failure modes, but F1–F4 are not safe to implement as written. The largest gaps are stale-controller commands against a process singleton, a transport that supports only one pending dictation despite the plan claiming per-session safety, a nonexistent app-side splice fallback in F3, and an F4 overlap rule that can convert weak or empty proxy evidence into false success.

## Findings

### 1. BLOCKER — F1 moves dictionaries, not the deck state machine

**Confidence: Confirmed.** `KeyboardStreamingHub` is a process-lifetime `@MainActor` singleton, but the hub currently owns only deck visibility and the current asks (`Jot/Keyboard/KeyboardStreamingHub.swift:178-184,242-249,562-581`). The actual deck progress remains SwiftUI-local state: `stage`, `index`, feedback, verdict count, and engagement (`Jot/Keyboard/CorrectionReviewStrip.swift:52-71`). Its nudge, verdict-dwell, done-dwell, and per-card timers are unstructured `Task`s with no cancellation handle or session/generation token (`Jot/Keyboard/CorrectionReviewStrip.swift:186-192,345-348,408-414,428-443`). The hold strip is mounted without a session identity, and its callbacks carry no session identity (`Jot/Keyboard/KeyboardView.swift:358-370`; `Jot/Keyboard/CorrectionReviewStrip.swift:31-46`).

The controller callback is also parameterless: `handleAskDeckFinished()` rereads whichever asks happen to be in the singleton, dismisses that shared deck, and invokes a parameterless flush through that controller's `textDocumentProxy` (`Jot/Keyboard/JotKeyboardViewController.swift:942-958`). This matters because the repository explicitly documents retained ghost controllers and unreliable disappearance callbacks (`Jot/Keyboard/JotKeyboardViewController.swift:54-64`; `Jot/Keyboard/KeyboardStreamingHub.swift:156-171`). `@MainActor` prevents simultaneous memory access; it does not prevent a serialized stale command from controller A acting on deck B.

**Recommendation:** replace the four dictionaries plus independent visibility fields with one hub-owned `ActiveDeck` value containing at least `sessionID`, a monotonically changing `generation`, asks, answered record keys/verdicts, current index/engagement/deadline, and an explicit phase such as `.reviewing`, `.resolved`, and `.inserting`. Every view/controller action must carry `(sessionID, generation)` and no-op unless it still matches. Use cancellable `.task(id:)` work or hub-owned deadlines. Only the active controller/generation may initiate proxy insertion; the process singleton must not infer the target session from its current global asks.

### 2. BLOCKER — Controller respawn can make the paste use the last choice while the app uses the first

**Confidence: Confirmed.** Each tap immediately overwrites the keyboard's verdict map and appends a verdict event (`Jot/Keyboard/JotKeyboardViewController.swift:920-925`). A remounted strip starts again from its local initial state (`Jot/Keyboard/CorrectionReviewStrip.swift:52-71`; `Jot/Keyboard/KeyboardView.swift:358-370`), so the same `recordKey` can be answered twice. The keyboard resolves the paste from the last dictionary value (`Jot/Keyboard/JotKeyboardViewController.swift:947-950`), while `CorrectionInbox` processes queued events in order and skips every later event once the first event has set a verdict (`Jot/App/Vocabulary/CorrectionInbox.swift:13-36`, especially `:16-23`).

A concrete failure is: choose `term`, dismiss/reopen, then choose `original`; the paste uses `original`, but app replay accepts the earlier `term` and skips the later event. F1 can therefore recreate the exact paste/transcript divergence it is meant to remove.

**Recommendation:** persist deck progress and answered record keys in `ActiveDeck`, resume at the first unanswered card, and make re-answering an answered record impossible. Prefer enqueueing one deduplicated final verdict batch after deck resolution. If verdicts remain tap-by-tap, the bridge protocol must define idempotency and conflict semantics by session plus record key; the current first-event-wins inbox is incompatible with a last-value-wins paste map.

### 3. BLOCKER — Per-session hub keys do not make two back-to-back dictations safe

**Confidence: Confirmed.** The Dictate button remains enabled while a hold deck is visible because its disabled predicate does not include `showAskDeck` (`Jot/Keyboard/KeyboardView.swift:734-760`), and the controller's mic decision has no deck guard (`Jot/Keyboard/JotKeyboardViewController.swift:2673-2684`). The underlying cross-process protocol has only one pending-paste key, one handoff payload, and one asks payload:

- a new pending session overwrites `AppGroup.Keys.pendingPasteSession` (`Jot/Shared/AppGroup.swift:45-59`; `Jot/Keyboard/JotKeyboardViewController.swift:1625-1643`);
- `ClipboardHandoff.publish` overwrites the one payload slot (`Jot/Shared/ClipboardHandoff.swift:48-63`);
- `CorrectionBridge.publishAsks` overwrites the one asks slot (`Jot/Shared/CorrectionBridge.swift:100-115`).

Cleanup is not session-scoped: `ClipboardHandoff.markConsumed()` and `CorrectionBridge.clearAsks()` unconditionally remove the current global values (`Jot/Shared/ClipboardHandoff.swift:132-136`; `Jot/Shared/CorrectionBridge.swift:139-141`). Therefore session B can overwrite session A, and a late cleanup for A can remove B. Merely comparing session IDs before an unconditional remove still leaves a read-then-remove race if another process publishes between those operations.

**Recommendation:** make the hold deck modal as the minimal design: disable the button and add a controller-side guard so no new dictation can start while an `ActiveDeck` is reviewing, resolved, or inserting. If simultaneous pending sessions are a product requirement, redesign pending sessions, handoffs, asks, consumption, and cleanup as a real per-session queue/store; hub dictionaries alone cannot provide it. The plan must choose one model explicitly.

### 4. MAJOR — F1's process-lifetime storage is neither durable nor fully cleaned up

**Confidence: Confirmed for lifecycle; Likely for material memory impact.** The hub explicitly dies with the extension process (`Jot/Keyboard/KeyboardStreamingHub.swift:178-180`). Thus moving the default and resolved transcript strings there survives controller replacement but not extension eviction/relaunch. Apple also documents custom keyboards as separate processes with memory limits and app extensions as terminable under memory pressure ([Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard); [App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)). The project itself treats the keyboard as a constrained roughly-60-MB target (`Jot/project.yml:473-479`).

Current code bounds the dictionaries to the new session before presenting a deck (`Jot/Keyboard/JotKeyboardViewController.swift:1821-1827`), so there is no evidence of an unbounded leak today. Successful insertion clears the per-session deck values (`Jot/Keyboard/JotKeyboardViewController.swift:2041-2052`), but clipboard-fallback failure consumes the payload without equivalent deck cleanup (`Jot/Keyboard/JotKeyboardViewController.swift:2128-2168`). Hoisting full text into a never-torn-down owner must preserve strict all-terminal cleanup. `applyVerdicts` also materializes both `Array(defaultText)` and an output array (`Jot/Keyboard/JotKeyboardViewController.swift:974-975,1021-1028`), so retaining duplicate base/resolved strings longer than necessary is wasteful in an extension even if ordinary transcript sizes are small.

**Recommendation:** keep one `ActiveDeck`, not four process-lifetime collections. Clear it on successful paste, clipboard fallback, explicit cancellation, stale-session rejection, supersession, and failed insertion. For the promise that a slow deck survives process eviction, persist only a compact checkpoint—session/generation, phase, progress, and verdicts—and recover the already-persisted matching handoff text without applying the 30-second age gate. Do not persist another full transcript copy unless measurements show it is necessary.

### 5. MAJOR — F2 needs a phase-aware branch before freshness and terminal cleanup

**Confidence: Confirmed.** The current flush reads `ClipboardHandoff.readFresh()` before it considers deck state (`Jot/Keyboard/JotKeyboardViewController.swift:1768-1774`). An expired payload therefore never reaches the deck gate and falls through the no-payload/terminal cleanup path (`Jot/Keyboard/JotKeyboardViewController.swift:2220-2226,2264-2268`). F2's wording says to paste `resolved ?? default` whenever deck state exists (`docs/plans/vocab-hold-deck-reliability.md:64-73`), but a reentrant flush while the user is still reviewing would then paste the default prematurely.

**Recommendation:** after reading the pending session, branch on a matching `ActiveDeck` before calling `readFresh()`:

1. `.reviewing` → return without inserting, consuming, or terminal cleanup;
2. `.resolved(text)` → use that text without the age check;
3. no matching deck → retain the normal fresh-payload path.

Repeat the pending-session match immediately before insertion, as the current path already does (`Jot/Keyboard/JotKeyboardViewController.swift:1895-1903`). If process restart is in scope, restoration must also verify the persisted session; a hub-only dictionary is insufficient.

### 6. BLOCKER — F3 is based on an app-side fallback that does not exist

**Confidence: Confirmed.** `CorrectionReviewModel` cannot be reused as-is in the keyboard without pulling in app-only persistence types and behavior: it imports SwiftData and SwiftUI, owns a `Transcript`/`ModelContext`, and writes through `TranscriptStore` (`Jot/App/Vocabulary/CorrectionReviewModel.swift:1-27,248-285`). More importantly, its behavior is not what F3 describes. `pick` calls `editText`, whose resolver accepts only an exact whole-word match at the reconciled anchor; there is no occurrence-context or whole-text fallback (`Jot/App/Vocabulary/CorrectionReviewModel.swift:109-131,248-255,289-313`). Even when `editText` returns nil, `pick` still records the verdict and applies learning (`Jot/App/Vocabulary/CorrectionReviewModel.swift:129-132`). The assertion that app replay "will apply" the replacement anyway is therefore false.

The two consumers can also operate on different baselines. The publisher maps asks into the exact `publishedText`, which may be cleaned (`Jot/App/Vocabulary/CorrectionAsksPublisher.swift:27-37`), while app replay edits `transcript.text` (`Jot/App/Vocabulary/CorrectionReviewModel.swift:248-255`). The ledger stores raw and cleaned strings separately (`Jot/App/Intents/DictationPipeline.swift:448-452`), and the preferred saved surface chooses `cleanedText` over raw `text` (`Jot/Shared/Transcript.swift:60-71`). The baselines do not necessarily differ, but the plan cannot assume one edit algorithm over one string establishes paste/display parity.

**Recommendation:** remove the proposed broad whole-text fallback. The minimal extension-safe mechanism is producer-validated exact paste-edit data, not replay of `CorrectionReviewModel`:

- in `CorrectionAsksPublisher`, resolve every hold-deck ask against the immutable `publishedText` and emit an authoritative character start plus exact expected substring for the base choice; validate a separate wider expected span for `alt0` when present;
- omit/log an ask, or omit its alternate, when that exact edit cannot be honored in the paste baseline;
- in the keyboard, verify the expected substring against the unchanged baseline and apply validated, non-overlapping edits in descending order;
- place the small exact-span helper in `Shared` or the Foundation-only `JotVocabCore`, which the keyboard already links (`Jot/project.yml:473-482`). It must not depend on `Transcript`, SwiftData, SwiftUI, provenance actors, or app stores.

The existing `publishedStart` bridge field is a useful starting point (`Jot/Shared/CorrectionBridge.swift:20-43`), but the publisher currently serializes selected asks without proving that their current needle is editable in `publishedText` (`Jot/App/Vocabulary/CorrectionAsksPublisher.swift:59-71`). This revision necessarily relaxes the plan's non-goal of never changing which asks are shown: an ask that cannot be honored must not gate the paste.

If paste/saved-display equality is also an invariant, the revised plan must separately define which stored surface (`text`, `cleanedText`, or `rewriteUserEdit`) is authoritative and make app replay verify/apply the same exact edit there. A queued verdict is evidence of the choice, not evidence that `CorrectionReviewModel` changed the visible transcript (`Jot/App/Vocabulary/CorrectionReviewModel.swift:129-132,248-285`; `Jot/Shared/Transcript.swift:60-71`).

### 7. MAJOR — F3's stated success invariant counts valid no-ops as failures

**Confidence: Confirmed.** The diagnostic's `requested` value is the number of verdicts, while `spliced` is the number of generated edits (`Jot/Keyboard/JotKeyboardViewController.swift:1017-1020`). Choosing the value already present in staged text intentionally exits through the equal-after-trim guard without an edit (`Jot/Keyboard/JotKeyboardViewController.swift:982-993`). "Stop asking" likewise preserves the original for the paste while enqueueing suppression (`Jot/Keyboard/JotKeyboardViewController.swift:927-935`). Both are successful resolutions, not splice failures. A missing optional `publishedStart` is compatibility handling in the bridge (`Jot/Shared/CorrectionBridge.swift:27-34`); new asks always serialize the mapped record's value (`Jot/App/Vocabulary/CorrectionAsksPublisher.swift:66-71`).

**Recommendation:** replace `spliced == requested` with explicit results such as `answered`, `editsRequired`, `editsApplied`, `alreadyDesired`, and `unresolvable`. The invariant is `editsApplied == editsRequired` and `unresolvable == 0` for asks that were actually shown. Do not list equal-after-trim as one of F3's failure cases.

### 8. MAJOR — Multiple individually valid F3 edits can overlap

**Confidence: Possible.** The keyboard collects edits and merely applies them in descending start order; it never checks interval intersection (`Jot/Keyboard/JotKeyboardViewController.swift:974-1027`). `AskPolicy` ranks and caps selected records without checking choice-specific edit ranges (`../jot-shared/Sources/JotVocabCore/AskPolicy.swift:98-121`), while an alternate's `find` deliberately widens through following words (`../jot-shared/Sources/JotVocabCore/VocabularyGate.swift:1298-1343`). An `alt0` choice can therefore plausibly overlap a separate ask on a following word and overwrite or invalidate that answer. The repository does not contain a concrete failing fixture, so this remains Possible rather than Confirmed.

**Recommendation:** validate all possible edit intervals against the same immutable paste baseline before presenting the deck. Suppress/merge conflicting cards or define deterministic precedence, then reject any overlapping final edit batch defensively. Add a harness case where `altFind` covers the next selected ask.

### 9. BLOCKER — F4 turns zero or tiny context into proof that a paste survived

**Confidence: Confirmed.** The proposed formula takes `pasteText.suffix(min(W, pasteText.count))` (`docs/plans/vocab-hold-deck-reliability.md:88-96`). At `W == 0`, the expected suffix is empty, and every string has an empty suffix. With a one-character context, equality proves only the final character. Both conflict with the plan's claim that nil/empty context behaves unchanged (`docs/plans/vocab-hold-deck-reliability.md:116-117`).

This is not merely theoretical defensiveness. The current code explicitly warns that immediate proxy context may reflect a local-cache insertion even when the host swallowed or reverted the paste (`Jot/Keyboard/JotKeyboardViewController.swift:1964-1983`). In the settled-disconnect branch, current success therefore requires the strong immediate full-text suffix signal (`Jot/Keyboard/JotKeyboardViewController.swift:2084-2104`). Replacing it with "all the host happened to expose," even one character, weakens a guard that exists to prevent false consumption.

The plan also overstates the scope of the structural failure: when settled context is non-nil, the current code can already succeed via `settledLen >= immediateAfterLen`; the full-suffix check becomes decisive chiefly when the proxy disconnects and settled context is nil (`Jot/Keyboard/JotKeyboardViewController.swift:2077-2104`).

**Recommendation:** define a shared evidence helper and a branch-by-branch decision table. It must return no suffix evidence for nil/empty context, preserve a full-string match when the full paste fits, label shorter exact tail equality as partial evidence with its overlap length, and never treat an arbitrary tiny overlap as sufficient by itself. Partial immediate-cache evidence plus later disconnect must remain inconclusive unless corroborated by a host callback or device-validated signal. Acceptance must test both sides: no false banner after a real paste and no false success/consumption after a swallowed or reverted paste.

### 10. MAJOR — F4 does not specify how the host callback participates, and suffix alignment is not a universal runtime guarantee

**Confidence: Confirmed for the omitted code path; Likely for conforming suffix alignment; Unknown for all third-party hosts.** `textDidChange` is the strongest host-originated callback in this flow, but its presence check still searches for the entire pending text (`Jot/Keyboard/JotKeyboardViewController.swift:1260-1281`). F4 mentions only `endsWithInserted` and `stillEndsWith`; it neither deliberately leaves this early-confirm path conservative nor updates it with the same evidence rules. Blindly changing this comparator to a partial suffix would also weaken its existing unrelated-change guard (`Jot/Keyboard/JotKeyboardViewController.swift:1260-1267`).

Apple defines `documentContextBeforeInput` as textual context before the current insertion point, which supports a caret-adjacent suffix interpretation, but does not promise completeness, a fixed window size, a stable caret, or freshness across a host re-render ([`UITextDocumentProxy.documentContextBeforeInput`](https://developer.apple.com/documentation/uikit/uitextdocumentproxy/documentcontextbeforeinput)). The production code already assumes suffix alignment in the host callback, immediate check, and settled check (`Jot/Keyboard/JotKeyboardViewController.swift:1273-1279,1937-1942,2077-2084`). The repository cannot establish that every problematic WKWebView or React-Native host returns a fresh, suffix-aligned window during disconnect.

**Recommendation:** state explicitly whether `textDidChange` remains a full-match fast path or becomes corroborating evidence for guarded partial matches. Do not use partial suffix alone to confirm an unrelated `textDidChange`. Instrument evidence source, context nil/empty state, overlap length, full-fit/windowed status, callback observation, and final branch. Treat arbitrary middle/stale context as a device-test question rather than a solved property of the API.

### 11. MINOR — F5 replaces one misleading promise with another

**Confidence: Confirmed.** Post-paste asks are teach-only and cannot edit host text (`Jot/Keyboard/CorrectionReviewStrip.swift:3-15`; `Jot/Keyboard/KeyboardStreamingHub.swift:499-519`). A keyboard tap only queues a verdict for later app replay (`Jot/Shared/CorrectionBridge.swift:143-160`; `Jot/App/Vocabulary/CorrectionInbox.swift:5-36`). A merge alias is written only for a qualifying `term` choice and can be skipped because of a conflict (`Jot/App/Vocabulary/CorrectionReviewModel.swift:145-170`); an `original` choice instead contributes keep/suppression behavior (`Jot/App/Vocabulary/CorrectionReviewModel.swift:172-180`). Therefore "Saved to vocabulary — future dictations will use it" is not true for every choice and is not guaranteed even for the term choice. The current shared copy's "applied/restored" wording is also wrong in teach-only mode (`Jot/Keyboard/CorrectionReviewStrip.swift:446-465`).

**Recommendation:** specify `holdMode`- and choice-specific copy in the plan. For post-paste mode, use non-promissory queued-learning language such as "Preference recorded for next time," not a claim that current text changed or that a future correction is guaranteed. Update VoiceOver labels/hints together with visible copy.

### 12. MAJOR — The test plan cannot detect the plan's highest-risk regressions

**Confidence: Confirmed.** The existing splice harness exercises isolated resolver cases only (`docs/harnesses/splice_check.swift:93-178`). It passes as currently written, but it has no controller respawn, stale timer, duplicate-verdict replay, two-session overwrite, unconditional cleanup, multi-edit intersection, process-death recovery, or host insertion oracle. The plan's device test checks only that a real paste succeeds and no banner appears (`docs/plans/vocab-hold-deck-reliability.md:119-126`); it would not catch F4 falsely declaring a swallowed paste successful.

**Recommendation:** add state-machine and bridge tests for stale generations, duplicate answers, phase-aware expiry, a blocked second dictation, session-specific cleanup, and overlapping edit descriptors. The device matrix must include both success and negative controls: a real long paste and a forced swallowed/reverted insertion, with nil, empty, tiny, and normal context windows where harnessable.

## Answers to the four open questions

1. **F2 — Is `readFresh()` preserving a later cleanup mutation? Confirmed: no such mutation was found.** Cleanup completes before `publishedText` is frozen (`Jot/App/Intents/DictationPipeline.swift:319-361`); asks are mapped from that exact value (`Jot/App/Intents/DictationPipeline.swift:377-397`); the same value is published into the handoff (`Jot/App/Intents/DictationPipeline.swift:399-407`). The later ledger append does not mutate the handoff (`Jot/App/Intents/DictationPipeline.swift:436-465`). `readFresh()` instead protects against payloads older than 30 seconds and empty payloads (`Jot/Shared/ClipboardHandoff.swift:12-14,91-105`), while the caller checks the pending session ID (`Jot/Keyboard/JotKeyboardViewController.swift:1768-1774`). Preserve those protections for non-deck traffic and replace them with explicit phase/session validation for a held deck.

2. **F3 — What is the minimal keyboard mechanism? Confirmed: producer-validated exact edit descriptors, not app model replay.** `CorrectionReviewModel` has app-only dependencies and no fallback resolver (`Jot/App/Vocabulary/CorrectionReviewModel.swift:1-27,248-313`). Extend the Foundation-only `CorrectionBridge.Ask` contract with an exact expected substring/range for the `publishedText` baseline, validate it in `CorrectionAsksPublisher`, and apply verified non-overlapping edits descending in the keyboard. A tiny pure helper can live in `Shared` or already-linked `JotVocabCore` (`Jot/project.yml:473-482`). Unresolvable asks must not be offered as paste-changing choices.

3. **F4 — Can the API return a middle window? Likely no for a conforming, current proxy value; Unknown across stale/nonconforming host behavior.** Apple's semantic contract is context before the current insertion point, so a truncated value should remain caret-adjacent, not an arbitrary middle slice. Apple does not document completeness/window length/freshness, and the repository itself records stale-cache and disconnect behavior (`Jot/Keyboard/JotKeyboardViewController.swift:1964-1983,2077-2104`). This cannot be resolved from source inspection; it requires real-host device evidence.

4. **F1 — What else still dies with the controller/view? Confirmed: deck progress and all review timers do.** The strip owns stage/index/engagement/feedback and unstructured timers (`Jot/Keyboard/CorrectionReviewStrip.swift:52-71,186-192,345-348,408-443`). Paste verification state and `textDocumentProxy` are also controller-owned (`Jot/Keyboard/JotKeyboardViewController.swift:132-156`), consistent with the hub's stated boundary that proxy machinery remains per-presentation (`Jot/Keyboard/KeyboardStreamingHub.swift:173-176`). The former must move into session/generation state; the latter should remain per-controller but be fenced so only the active controller for the matching generation can act.

## Landing and verification gates

- **Safe independently:** corrected F5 visible/accessibility copy. It needs snapshot/UI and VoiceOver review, not the paste device gate.
- **Safe preparatory change:** a backward-compatible F3 bridge schema plus the pure producer-side exact-edit validator and unit/harness coverage. Do not enable the new consumer behavior until invalid/overlapping asks are filtered.
- **Must land as one coherent behavior batch:** corrected F1 + F2 + the consumer half of corrected F3: one generation-keyed `ActiveDeck`, persisted progress where required, explicit phases, second-dictation serialization, exact edit descriptors, session-safe terminal cleanup, and active-controller insertion fencing. Splitting these leaves periods where shared state and callbacks have incompatible lifetimes.
- **Device gate for the F1/F2/F3 batch:** dismiss/reopen mid-card; keyboard switch/controller replacement; a stale 0.9-second/10-second callback; more than 35 seconds of deck dwell; attempted second dictation; field switch; extension eviction/relaunch if the reliability promise includes process death; repeated words, cleanup on/off, Unicode/punctuation, `alt0`, and overlapping candidate ranges. Verify both pasted text and the saved/displayed transcript.
- **F4 must land separately behind a device gate:** native `UITextView`/`UITextField`, a populated WKWebView, and at least one React-Native/web compose host; short and long successful pastes; caret movement; nil/empty/tiny context; proxy disconnect; and a forced swallowed/reverted paste. Inspect actual host text, not only whether the red banner disappeared.

## Review limits

- **Unknown:** no repository inspection can prove `documentContextBeforeInput` freshness/window behavior in every host. The required next evidence is device logging for the F4 evidence fields above.
- **Unknown:** extension eviction recovery and peak memory were not measured on a device. The required next checks are a jetsam/relaunch exercise and Instruments memory profiling with a long held transcript.
- **Not run:** no Xcode build or UI test was run because this review made no implementation changes. The standalone resolver harness was run and reported `ALL PASS`; it does not cover the lifecycle, bridge, or host-verification paths listed in finding 12.

## Verdict

**REVISE.** Before implementation, the plan must: (1) replace F1's dictionaries with a session/generation/phase state machine and stale-callback fencing; (2) choose modal single-session operation or redesign all three single-slot transports as queues; (3) branch F2 on deck phase before freshness cleanup and define process-restart recovery; (4) replace F3's nonexistent replay fallback with producer-validated exact, non-overlapping edit data and correct metrics; (5) redesign F4 around explicit evidence strength so nil/empty/tiny overlap cannot prove success, then require a swallowed-paste negative-control device gate; and (6) make F5 copy choice-specific and non-promissory.
