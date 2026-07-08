# Speaker Notes productization + Writing Tools pre-select

**Status: DESIGNED + adversarially reviewed 2026-07-06; all must-fixes folded in (marked ⚠️REVIEW). Target: next build (256).**

Review verdict on v1 of this doc: two BLOCKERs (inbound selection binding
didn't exist; voiceprint build mistaken as cheap), two HIGHs (tab visibility
coupled to `hasRewrite`; stored rows going stale on re-transcribe), two
missing schema steps. All corrected below.

Two features, one build, per owner:

1. **Speaker Notes** — promote the hidden Diarization Lab to a real feature:
   remove the lab flag, **auto-diarize audio shared in from other apps**
   (headline case: iOS call recordings → Notes → share to Jot), persist the
   result, keep manual "Detect speakers" available on any transcript with
   retained audio.
2. **Writing Tools pre-select** — when the user's rewrite engine is Apple
   Intelligence, tapping the rewrite action **pre-selects the whole
   transcript** and updates the guide copy so the user's next gesture is
   tap-the-selection → Writing Tools → whatever *they* choose. Jot never runs
   the rewrite for them.

---

## Part 1 — Speaker Notes

### Current state (verified in code)

- **Engine**: `DiarizerHolder` (Jot/App/Diarization/DiarizerHolder.swift) —
  FluidAudio offline VBx, pyannote community-1, **~22 MB**, download-on-first-
  use with progress via `OfflineDiarizerModels.load`, generation-guarded
  actor. No hardware gate (works on all devices).
- **Labeling**: `DiarizationLabeling` (isMultiSpeaker / firstAppearanceOrder /
  assignOwnerLabel / distributeText) + `OwnerVoiceprintStore` (auto-built
  centroid from retained solo recordings, **no enrollment step**; <5 clips →
  no voiceprint → all speakers anonymous, feature still works).
- **UI**: `diarizeSpeakers()` in TranscriptDetailView (:695) runs on the
  transcript's **retained audio** (3-day `RetainedAudioStore` window) and
  shows an **ephemeral** `DiarizationResultSheet` — nothing persisted.
- **Gate**: `AppGroup.Keys.diarizationLabEnabled`, set by the 5-tap-Version
  reveal (SettingsView:1232), read in TranscriptDetailView (:199, :594, :655);
  a Settings "Diarization Lab" row (SettingsView:~977) opens
  `DiarizationLabView`. Voiceprint build is kicked on first reveal.
- **Import path**: `PendingShareDrainer.transcribeAndSave` (:59) — share-ext
  audio → transcribe → cleanup → `TranscriptStore.append(raw:cleaned:
  source:"share", retainAudioFileURL:)`. The transcript already carries
  `source == "share"` (V8 provenance field) and its audio is already
  retained — everything auto-diarize needs is in place.

### Product behavior

- **Auto**: audio that arrives via the Share Extension is transcribed as
  today, then diarized automatically. Multi-speaker → the transcript gains a
  **Speakers** view (see below). Single-speaker → nothing changes, no UI
  noise. Failure → transcript untouched (diarization is an enhancement,
  NEVER a gate on the import — same tolerant posture as the cleanup pass).
- **Manual**: "Detect speakers" appears in the detail overflow menu for ANY
  transcript with retained audio (self-dictations included — the owner
  considers this fine), no lab flag. Re-running overwrites the stored result.
- **Labels**: "You" via the owner voiceprint when available, else
  "Speaker 1/2/…" in first-appearance order — existing `DiarizationLabeling`
  logic unchanged.
- **Announcement-readiness**: the ~22 MB model is prefetched quietly so the
  feature works instantly when announced (see Model availability).

### Persistence — Schema V9 (the one schema change)

Store the diarization result ON the transcript: new optional field on a new
`JotSchemaV9` (frozen-rule discipline, `docs/schema-migrations.md`):

- `diarizationJSON: String?` — JSON-encoded `[PersistedSpeakerRow]`
  (`label`, `start`, `end`, `text`), nil = never diarized / single-speaker.
  Encoded rows store the RESOLVED display label ("You"/"Speaker 2") — the
  voiceprint is consulted at diarization time, not render time, so a later
  voiceprint change never silently relabels an existing transcript.
- Additive optional ⇒ `.lightweight` migration stage; `versionIdentifier`
  bump to (9,0,0); `Transcript` typealias bump.
- ⚠️ Known gotcha (memory `project_transcript_language_translate`): **JotWatch
  enumerates schema files explicitly in project.yml** — add
  `Shared/Schema/JotSchemaV9.swift` to the watch target's source list or the
  watch build breaks.
- Why not a sidecar file: diarization data must live exactly as long as the
  transcript. A schema field deletes/cascades for free; a sidecar needs
  delete hooks + orphan sweeps (RetainedAudioStore gets away with it only
  because it self-expires in 3 days).
- Keyboard/watch never read this field (keyboard reads the history-mirror
  JSON, which we do NOT extend; watch shows plain text) — no cross-process
  changes.

### Display — a third detail tab (⚠️REVIEW: visibility rework required)

`DetailTab` (TranscriptDetailView:63) gains `case speakers` ("Speakers") —
but NOT as a bare enum case: the selector renders `ForEach(DetailTab.allCases)`
(:753) and is only mounted when `hasRewrite && !isEditing` (:261), where
`hasRewrite` requires a cleaned/rewritten text (:1690-1694). A shared call
recording with cleanup off/failed has NO rewrite → no tab bar at all → the
Speakers tab would be unreachable **for exactly the headline case**. Rework:

- A computed `visibleTabs: [DetailTab]` — `.original` always; `.rewrite` when
  `hasRewrite`; `.speakers` when `diarizationJSON != nil`. The selector
  iterates `visibleTabs` and mounts whenever `visibleTabs.count > 1 &&
  !isEditing` (decoupled from `hasRewrite`).
- Content: the row layout ported from `DiarizationResultSheet` (label +
  timestamp + text per turn), selectable text.
- Manual "Detect speakers" switches to the tab on success; multi-speaker
  shared imports open on Original as usual (the tab's presence is discovery
  enough — no forced navigation). Single-speaker manual runs show the
  existing transient "sounds like one speaker" notice and store nothing.
- The ephemeral sheet is retired; its row views are reused by the tab.

### ⚠️REVIEW — staleness: invalidate on text/language change

Stored rows hold RESOLVED text distributed across segments; they cannot be
cheaply re-derived. Whenever the underlying text or language changes, the
stored result no longer matches and MUST be invalidated
(`updateDiarization(id:, nil)` — tab disappears; the user can re-run Detect
speakers while audio is retained):

- `retranscribe(in:)` success (:663-687) — rewrites text + language.
- Original-tab `saveEdit` with actually-changed text (:1913-1926, the
  text-diff dirty check at :1922 already tells us).
- Rewrite saves do NOT invalidate (they never touch Original).

### Auto-diarize hook (PendingShareDrainer)

After a successful `TranscriptStore.append` in `transcribeAndSave`:

1. `DiarizerHolder.shared.prepareIfNeeded()` (downloads the 22 MB on first
   use if the prefetch hasn't landed — visible nowhere; this is a background
   import pipeline).
2. ⚠️REVIEW: guard `TranscriptionService.shared.isBusy` **AND**
   `RecordingService.shared.isRecording`, re-checked immediately before the
   diarize call (the drainer's entry guard is sampled once at :35 and a
   dictation can start mid-drain; FluidAudio's shared CoreML/BNNS state is
   documented unsafe under two concurrent graphs). If busy: **skip** the
   auto-diarize for this file (enhancement-not-gate — the user can run
   Detect speakers manually) rather than wait.
3. ⚠️REVIEW (blocker fix): **voiceprint build is OFF the critical path.**
   `OwnerVoiceprintStore.build()` runs up to 40 full diarization passes
   (OwnerVoiceprintStore maxCandidates=40, each a VBx inference) — minutes,
   not "cheap". The import diarize uses the centroid ONLY if it already
   exists; otherwise labels come out anonymous. A detached low-priority
   build() is kicked AFTER the import diarize completes (idempotent,
   presence-checked) so future runs get "You". A user can always re-run
   Detect speakers once the voiceprint exists. (`build()` also keeps its
   surviving caller in VoiceCloneGuard.swift:39 — do not delete it.)
4. Diarize; if `isMultiSpeaker` → persist `diarizationJSON` via a new
   `TranscriptStore.updateDiarization(id:json:)` (the transcript id is
   available — `append` returns the row, currently discarded with `_ =` at
   PendingShareDrainer.swift:86). Else store nothing.
5. Any error: log + DiagnosticsLog breadcrumb, transcript stays as-is. Never
   retried automatically (the user can run Detect speakers manually).

### Flag removal & lab retirement

- Delete the `diarizationLabEnabled` reads in TranscriptDetailView (:199,
  :594, :655) — the overflow menu (Detect speakers + Re-transcribe) becomes
  the standard trailing control whenever retained audio exists.
- Delete the Settings "Diarization Lab" row + `DiarizationLabView` (its job —
  proving the pipeline — is done; the 5-tap reveal keeps only Voice Clone
  Consent while TTS stays paused). Delete the `diarizationLabEnabled` key
  writes (SettingsView:122, :1232) and the key constant.
- Voiceprint build trigger moves from "lab first revealed" to
  "first diarization run" (step 3 above) — plus keep the existing refresh
  hook if one runs elsewhere (verify at implementation).
- Atlas lifecycle: the lab never had mockups (hidden feature); the NEW
  Speakers tab + updated detail overflow get fragments (see Docs).

### Model availability (owner: "downloaded at night, so it's ready")

- **Primary (this build)**: opportunistic launch prefetch — at the very end
  of the existing serial ANE warm chain (JotApp.swift:206–240, after
  `warmNonSelectedDictationModelsWhenIdle`), if diarizer models are absent
  AND the network path is neither expensive nor constrained
  (`NWPathMonitor` — i.e. effectively Wi-Fi), kick
  `DiarizerHolder.prepareIfNeeded()`. 22 MB — lands in seconds on Wi-Fi; the
  chain position guarantees it never contends with dictation model loads.
  ⚠️REVIEW caveats: (a) `prepareIfNeeded()` downloads AND loads the CoreML
  graph — so, like `warmNonSelectedDictationModelsWhenIdle`, bail if a
  recording/transcription is in flight before starting; the model staying
  resident afterward is fine (small). (b) NWPathMonitor must be RETAINED
  (not a local) and the prefetch decision made inside its
  `pathUpdateHandler` — a synchronous `currentPath` read right after
  `start()` reports unsatisfied.
- **Secondary (rides Build A of the externalization plan)**: add the
  diarizer file manifest to the overnight discretionary fetcher when that
  ships — free once the fetcher exists. Soft dependency only; the feature is
  fully functional without it via prefetch + on-demand download.
- On-demand fallback stays: manual Detect speakers with no model shows the
  existing download progress states in the menu button.
- Backup exclusion: NO new wiring needed (verified, review-2) — the diarizer
  downloads to `…/Application Support/FluidAudio/Models/` via
  `MLModelConfigurationUtils.defaultModelsDirectory()`, inside the tree the
  per-launch `BackupExclusion.excludeFluidAudioModels()` sweep already covers.

### Schema impact (required section)

**Y** — new `JotSchemaV9` adding optional `diarizationJSON: String?` to
`Transcript`. Migration V8→V9: `.lightweight` (pure additive optional —
verified same shape as V7→V8's `language`, JotMigrationPlan.swift:112-115).
Full checklist (⚠️REVIEW added the two starred steps my v1 missed):
new frozen V9 file; `versionIdentifier` (9,0,0); stage appended to
`JotMigrationPlan`; **★ append `JotSchemaV9.self` to the `schemas` array
(JotMigrationPlan.swift:47-50)**; typealias bump; **★ bump
`JotModelContainer.shared` to `Schema(versionedSchema: JotSchemaV9.self)`
(TranscriptStore.swift:92)** — typealias-without-container-bump ⇒ container
schema and model type disagree ⇒ fallback/crash; `xcodegen`; **JotWatch
project.yml schema enumeration (verified real: project.yml:537-546, watch
does not glob Shared/)**; on-device upgrade watch for `[SCHEMA-FALLBACK]`.

---

## Part 2 — Writing Tools pre-select

### Current state (verified)

- Rewrite action → `presentRewritePicker()` (TranscriptDetailView:1755) →
  `RewriteMode.current == .appleIntelligence` → `showAIGuide = true` →
  `AppleIntelligenceRewriteGuide` sheet with 4 steps, step 1 = "**Select**
  the transcript text." — the step the owner calls genuinely painful.
- Read mode renders SwiftUI `Text` (`.textSelection(.enabled)`) — **not
  programmatically selectable**. Edit mode uses `InlineEditTextView`
  (UITextView wrapper) with a two-way `TextSelection?` binding
  (`editorSelection`, TranscriptDetailView:130-132; range sync verified in
  InlineEditTextView.swift:254-291). `RewriteMode.appleIntelligence` is only
  offered when `SystemLanguageModel.default.availability == .available`
  (RewriteMode.swift:24), which is the same device class that has Writing
  Tools in the UITextView edit menu — no extra gating needed.

### Behavior — ⚠️REVIEW: redesigned as a read-only "selection mode"

The review killed v1 of this flow twice over: (a) the `TextSelection` binding
is **outbound-only** (`InlineEditTextView.syncSelection` mirrors UIKit →
SwiftUI at :283-291; `updateUIView` never applies an inbound selection) — the
"existing machinery" I cited does not exist; and (b) entering real Edit mode
invites the user to run a Writing-Tools *Rewrite* (which replaces text
in-place) and then Save — **overwriting the pristine Original** (`saveEdit`
writes `transcript.text`, :1913-1926) — while also trapping them in edit
mode's disabled-back-navigation state (:337, :522-523).

v2 — a **selection mode**, not edit mode:

1. Tap the rewrite action with engine = Apple Intelligence → the detail view
   swaps the read-mode text for the same `InlineEditTextView` in a new
   **`isEditable = false`** variant (selectable, no keyboard, no dirty state,
   no Save/Cancel semantics — a "Done" chip exits back to read mode).
2. `InlineEditTextView` gains the missing **inbound selection apply**: in
   `updateUIView`, read the `selection` binding, convert to a UTF-16
   `NSRange`, set `tv.selectedRange` under the existing `isApplying` latch.
   (Net-new code, correctly scoped this time.)
3. The guide sheet presents; **the full-range selection is applied on sheet
   DISMISS**, not before present (while the sheet is up the selection
   highlight wouldn't be visible anyway, and presenting races the
   first-responder hop at InlineEditTextView.swift:62-63).
4. User taps the selection → menu → Writing Tools → Key Points / Summary /
   Rewrite. On a **non-editable** text view, Writing Tools shows results in
   its overlay panel with **Copy** — it cannot replace the text in place, so
   the pristine Original is structurally protected (verify this WT-on-
   read-only behavior on-device early; if iOS ever offers in-place replace
   here, fall back to guarding the save path instead).
5. Updated guide copy (directions stay, per owner):
   - Step 1: "We've **selected the whole transcript** for you."
   - Step 2: "**Tap the selection** to bring up the menu."
   - Step 3: "Tap **Writing Tools** and choose **Key Points**, **Summary**,
     **Rewrite**, and more."
   - Step 4: "**Copy** the result to use it anywhere."
6. Dirty-tracking concern is moot in selection mode (nothing editable);
   the existing edit path is untouched.

### Implementation-time investigation (bounded)

Check whether iOS 26 exposes a public "present Writing Tools directly" API
for UITextView (e.g. via `UIWritingToolsCoordinator` or a text-item action).
If a supported one-call presentation exists, step 2 collapses to "the panel
is already open" and the copy tightens further. If not (likely), the
pre-select + menu flow above ships as designed. Time-boxed; the fallback IS
the design.

### Schema impact

**N** — pure view-layer behavior + copy.

---

## Docs & Atlas (part of DONE)

- features.md: new §3.x "Speaker notes" (detail tab + auto-on-shared-audio +
  You-labeling, user-facing language), cross-linked to the share-import and
  audio-retention sections; update §7.10 guide description (pre-selection
  copy); update the share-import section (arriving audio may gain speakers).
- ARCHITECTURE.md: Diarization subsystem row updated (lab → product; new
  invariant: diarization is an enhancement, never an import gate; V9 field).
- Atlas: update detail-view fragments (new Speakers tab, overflow menu),
  update the AI-guide fragment copy, add a speakers-tab fragment; deploy.

## Test plan

1. Sim: share a two-voice audio file → transcript appears → Speakers tab
   appears with labeled turns; single-voice file → no tab, no noise.
2. Manual Detect speakers on a fresh dictation (solo) → "one speaker" notice,
   nothing stored; on a multi-voice retained recording → tab + persisted
   across relaunch (V9 round-trip).
3. Upgrade path: existing store opens on V9 with no `[SCHEMA-FALLBACK]` log;
   old transcripts show no Speakers tab.
4. Model-absent path: models dir cleared → share import downloads (22 MB) and
   still diarizes; airplane mode → import completes WITHOUT diarization,
   error only in Diagnostics.
5. Writing Tools: AI-engine device → rewrite tap → edit mode + full selection
   under the sheet → dismiss → tap selection → Writing Tools present; run Key
   Points; Edit-cancel leaves transcript unchanged. Non-AI device → flow
   unchanged (guide only shows for `.appleIntelligence` mode).
6. Watch build compiles (V9 enumeration).

## Work breakdown

| # | Item | Size |
|---|---|---|
| 1 | JotSchemaV9 + migration (incl. schemas array + container bump) + typealias + project.yml watch enumeration | S |
| 2 | `TranscriptStore.updateDiarization` + persisted-row Codable | S |
| 3 | Speakers tab + `visibleTabs` selector rework (decouple from `hasRewrite`), retire sheet, menu always-on, flag removal, lab deletion | M |
| 4 | Auto-diarize hook in PendingShareDrainer (busy re-check, skip-not-wait) + detached post-import voiceprint build | S |
| 5 | Launch Wi-Fi prefetch of diarizer models (warm-chain tail, busy bail, retained NWPathMonitor) | S |
| 6 | Selection mode: `InlineEditTextView` inbound selection apply + non-editable variant + apply-on-sheet-dismiss + guide copy update | M |
| 7 | Staleness invalidation (retranscribe + Original save) | XS |
| 8 | features.md / ARCHITECTURE.md / Atlas + deploy | S |

## Risks

- **Schema migration** — additive lightweight, but it's still a shipped-store
  migration; the discipline (frozen files, fallback log watch) exists and V8
  shipped cleanly two weeks ago.
- **Diarization quality on call recordings** — VBx was validated on Mac
  research audio (12% DER); phone-call audio is compressed/narrowband. The
  lab's own 4-bugs-found-by-sim-testing history says: test with a real iOS
  call recording before announcing. NOT a blocker for shipping the plumbing.
- **Voiceprint cold start** — a user whose first Jot contact is a shared call
  recording has no solo clips → anonymous labels (designed degradation, not
  a bug).
- **distributeText fidelity** — text is distributed across speaker segments
  by timing heuristics; imperfect turn boundaries are expected and acceptable
  for v1 (the Original tab always has the untouched text).
