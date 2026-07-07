# Overnight work log + questions for the owner

The owner went to sleep 2026-07-05 (~late PST) and asked me to keep executing
autonomously, note any questions here, and NOT wait. Standing rule honored: **no
`git commit` 9pm–10am PST**; all work stays uncommitted. TestFlight upload is
allowed during sleep hours but I will not push a build unless a step reaches a
clean, harness-verified checkpoint worth testing.

## Goal (locked)

Two peer transcribers (Apple + FluidAudio), streaming both, toggle-selectable, all
current features preserved, no bugs. Full statement at the top of `design.md`.

## Process (owner-directed)

1. Opus 4.8 reviews the implementation plan BEFORE any code. (running)
2. If must-fixes: back to Fable to amend, re-review.
3. Once plan is clean: implement (Sonnet), parallelize only where Opus confirms no
   file-edit conflicts; sequential otherwise.
4. Each implemented step: compile gate + harness gate (real recordings CSV) + an
   Opus diff review before moving on.
5. Two on-device checkpoints are the owner's to run when awake.

## Questions for the owner (answer when awake — none are blocking; I've picked a
## safe default for each and noted it so work continues)

_(none blocking. Owner raised 2 product points 2026-07-06, both about the LATER
rollout phase, not the current toggle cycle — captured for planning, not blocking
the implementation in flight:)_

1. **Where capable phones (14 Pro+, incl. 17 Pro) are asked to download FluidAudio:**
   already decided (D1) — wizard + Settings + keyboard nudge. RIGHT NOW nothing is
   asked (Parakeet still bundled this cycle; the download flow is rollout-phase).
2. **Carry-forward migration of the already-bundled model** — owner flagged this as
   "very important, needs to be thought through and planned." Captured in detail in
   design.md → "Rollout / migration → ⭐ MUST-PLAN carry-forward". His idea: a
   transitional release that copies the bundled model into the App Group / App
   Support BEFORE a later release strips the bundle, so upgraders keep FluidAudio
   with zero re-download. Open sub-questions (where to copy, one-time vs idempotent,
   how long the transitional build must soak before stripping, keep a download-if-
   missing fallback for the skip-the-transitional tail) written up there. DEFERRED,
   hard prerequisite for the app-size win.
3. **Simulator test** requested "once everything is done" — will run after Step 7.
   Caveat noted to owner: sim validates the FluidAudio path + all UI/flows but
   CANNOT faithfully test Apple's engine (SpeechAnalyzer asset behavior on sim isn't
   representative) — the harness + on-device checkpoints are the real Apple proof.

## ▶▶ WHEN YOU WAKE — TestFlight build 245: what to test on your 17 Pro

All 7 steps done, reviewed (two Opus adversarial passes on the crux steps, one real
HIGH bug found + fixed), harness-verified against your real recordings, sim-smoke-tested
(clean launch/render/no-crash), and shipped to TestFlight as **build 245** (2.0). Nothing
committed — awaiting your device verdict, then I commit.

The Apple engine is behind the existing hidden toggle: **Settings → tap Version 5× →
Labs → "Apple Dictation (English, A/B test)".** Flip it ON to test the Apple path; OFF
must be exactly like today.

**Checkpoint 1 — Apple path basics (toggle ON):**
- Dictate and watch the live preview: text should stream in naturally and firm up as you
  talk (Apple's native streaming), not appear in one lump at the end.
- Rapid-fire: tap Jot down and immediately stop, ~10×. No stuck "Listening…", no stale
  text landing after you stop, next recording clean. (This is the H1 race fix.)
- Pause then resume mid-dictation: your already-dictated text must NOT blank out while it
  resumes. (M1 fix.)
- Stop mid-sentence: the last words must be in the saved note. (tail flush.)

**Checkpoint 2 — the payoff + no-regression (toggle ON):**
- Cold-launch the app, toggle ON, dictate, stop: NO ~16-second stall on stop. (H2 — Apple
  no longer waits on Jot's model.)
- A LONG (2–3 min) dictation should stop **near-instantly** — check Settings → Help →
  Diagnostics for a "Streaming transcript promoted" line. (D2 — the "why redo it" win.)
- A PAUSED-then-resumed dictation: Diagnostics should show the coverage-mismatch FALLBACK
  line instead (proves the guard that protects your saved note is working).
- Dictate one of your custom vocabulary terms on the Apple path — it should still get
  corrected in the saved note. (Confirms vocab/CTC still applies at stop.)
- Keyboard strip during an Apple-path recording should show text, never "Loading
  Parakeet…".

**Checkpoint 3 — toggle OFF = byte-identical to today.** Everything (FluidAudio dictation,
warm-hold, keyboard, wizard) exactly as before.

If anything's off, tell me the symptom + grab Diagnostics; I'll diagnose before any commit.
If it all feels right, say so and I'll commit the whole rework.

**Two things NOT in this build (later, separate cycle):** stripping the bundled Parakeet
model to shrink the app, and the carry-forward migration you raised — both written up in
design.md, deferred by design.

---

## Build 246 (2026-07-06) — Apple as DEFAULT engine, for the 2020 iPad Pro test

Owner has a 2020 11" iPad Pro (no M1) where Parakeet v2 doesn't work but Apple dictation
does — the exact "FluidAudio-incapable device" the rework targets. Wants Apple as default
there. Change: added `AppGroup.useAppleDictationForEnglish` accessor **defaulting to TRUE**
(`object(forKey:) as? Bool ?? true`), single source of truth; pointed both readers
(`TranscriptionService.useAppleEngine`, `SettingsView` @State) at it. So a FRESH install
uses Apple for English out of the box, no Labs toggle. Explicit toggle choice still wins.
Build 246 → ✅ UPLOAD SUCCEEDED. Uncommitted.

⚠️ Caveats flagged to owner: (1) app min = iPadOS 26, so if the iPad can install 246 it's on
26 and Apple works; if TestFlight blocks install, that iPad isn't on 26 and NEITHER engine
runs. (2) With default-on from fresh install, Apple's asset download happens on the FIRST
dictation (no toggle-flip to trigger Step 7's pre-install) — first one may be slow, needs
Wi-Fi. (3) Kept the Apple→Parakeet fallback (didn't fold in the earlier "pure Apple no
fallback" ask — moot on the iPad since v2 is broken there anyway). (4) OPEN for production:
default Apple-on GLOBALLY vs only on FluidAudio-incapable devices — this test build is global;
revisit before committing. Noted in the AppGroup accessor doc-comment.

## Continued 2026-07-06 (post-246) — direction + follow-on features

- Apple set as DEFAULT engine (build 246, shipped). Settings toggle reworded off "A/B test"
  → "Apple Dictation (English)" (build 247, shipped). Both uploaded ✅.
- DECIDED go-forward direction (design.md): Apple = permanent default; Parakeet/FluidAudio
  ("nvidia") = higher-accuracy upgrade via nudge; existing users stay on Parakeet, new users
  get Apple; wizard simplified (Apple-first language picker, download only for the 13
  FluidAudio-only languages).
- Apple-only-languages plan written + registered (~11 net-new languages Jot can't do today).
- Carry-forward migration DESIGNED (v2-carry-forward-migration-design.md): how existing users
  keep bundled v2 across the future bundle-strip with zero re-download. Key insight: the loader
  already falls through to App Support, so the strip is a DATA migration (copy v2 out before
  stripping). → Under Opus adversarial review now.
- Upgrade nudge: infra mapped (reuse warm-hold-nudge machinery), Sonnet implementing now
  (keyboard strip after 5 Apple dictations → deep-link → switch to Parakeet). Decisions:
  usage-based (5), keyboard surface, is600MCapable eligibility, one-time. Parakeet is bundled
  so the switch is instant (no download yet). → Combined build + Opus review to follow.

## Upgrade nudge + migration design (2026-07-06, diligent pass)

- **Carry-forward migration** DESIGNED + Opus-reviewed. Core mechanism CONFIRMED correct
  (loader fallthrough = data-only migration). 4 must-fix gaps found + folded into the design:
  (C) `modelsExist` only checks dir-existence not completeness → atomic copy + real verify;
  (C2) CTC vocab scorer + EmbeddingGemma share the bundled folder → strip ONLY the v2 subdir,
  keep the scorer bundled; (E) existing-vs-new resolution must run synchronously at app init off
  a cheap signal (prefer a pre-shipped beacon), not a SwiftData query, or a dictation beats it;
  (B/F) atomic copy mechanics + free-space preflight + orphan-sweep allowlist. Design-only,
  ships when we actually strip (not now).
- **Parakeet upgrade nudge** IMPLEMENTED (mirrors warm-hold-nudge machinery) + Opus-reviewed:
  VERDICT correct + safe, no critical/high, cleared to ship. Applied the 3 recommended fixes:
  (E) manual Settings toggle-off now clears the armed strip + posts the change; (E2) switching
  to Parakeet resets the Apple-dictation count so re-enabling Apple doesn't instantly re-nudge;
  (B) honest "counts attempted-on-Apple" comment. Keyboard strip after 5 English-on-Apple
  dictations on a 6GB-capable device → deep-link → sheet → switch (instant, Parakeet bundled;
  download step attaches when the bundle is later stripped). One-time (decline = permanent).
  Build 248 → TestFlight.

## Build 249 (2026-07-06) — CRITICAL on-device fix + 4 languages

**On-device testing (owner's iPad) exposed that Apple's engine had NEVER actually run on
iOS** — `AssetInventory.assetInstallationRequest` threw `"not subscribed to
transcription.<locale>"` every time → silent FluidAudio fallback (masked on capable devices;
fatal on the iPad where FluidAudio also can't build its CoreML model, error -4). The Mac
harness didn't reproduce it. Fixes in 249:
- **RESERVE FIX (critical):** shared `AppleStreamingSession.makeReservedTranscriber(requestedLocale:preset:)`
  — normalize via `SpeechTranscriber.supportedLocale(equivalentTo:)` → `AssetInventory.reserve`
  (pool-managed) → build transcriber → install. All 3 asset-install sites route through it.
  Verified against the real iOS 26.4 SDK interface (not guessed). Only real validation is
  on-device (harness can't hit the bug) — 249 IS that test.
- **iPad Parakeet-OFF (temporary, owner-requested):** `DeviceCapability.isIPad` (sysctl-based,
  nonisolated) + `TranscriptionService.parakeetUsable` (= is600MCapable && !isIPad). Gates: the
  Parakeet-v2 warm (at the `warmUp()` front door — covers all 4 warm callers incl. the frequent
  recording-start warm) + `allDeviceModelTargets()` v2 target + the stop-pass FluidAudio
  fallback (rethrows on iPad). English engine selection unchanged; European v3 untouched.
- **4 net-new languages** (Japanese, Korean, Mandarin zh-CN, Cantonese yue-CN) via
  SpeechTranscriber — `LanguageChoice` cases + `isAppleOnly`/`appleLocaleIdentifier`, engine
  routing generalized (`isAppleOnly || (isEnglish && toggle)`), locale threaded into both Apple
  engines, vocab skipped for them, NO FluidAudio fallback for them (rethrow). No schema change.

**Device-verified language reality (probe on macOS 26):** SpeechTranscriber does only 10
languages (de,en,es,fr,it,ja,ko,pt,yue,zh) — the web research's "11 incl. Arabic/Turkish/Thai"
was WRONG. Net-new via the GOOD engine = 4. The other ~10 (Arabic/Hebrew/Hindi/Indonesian/
Malay/Norwegian/Thai/Turkish/Vietnamese/Catalan) are DictationTranscriber-only (older, no
streaming). Decision (research-backed): ship the 4 now; HOLD the older-engine batch (Arabic
risky; all behind server quality). Recorded in apple-only-languages-plan.md.

**FOLLOW-UPS still owed (flagged, not blocking the iPad test):**
1. Picker status UI shows a bogus "download Parakeet v3" affordance for the 4 languages
   (SettingsView `languageStatusRow` + LanguageStep `statusContent`/`downloadControl` branch
   only isEnglish-vs-else-v3) — needs an `isAppleOnly` branch. Cosmetic, dictation still works.
2. `makeStreamingSession` live-preview fallback for isAppleOnly (cosmetic wrong-language flash
   if Apple make() fails) — gate on !isAppleOnly for polish.
3. `WatchLanguage.swift` mirror needs the 4 cases (silent divergence).
4. Searchable Settings picker + diacritic-insensitive match + empty state (UX design done,
   not yet implemented — native `.searchable` already in the wizard; Settings still a Menu).
5. Nudge Atlas mockups deployed (v57) — awaiting owner approval.

## Build 251 (2026-07-06) — ROOT CAUSE found: SpeechTranscriber is HW-gated; DictationTranscriber fallback

The iPad "not subscribed to transcription.en" was NEVER a reserve/auth code bug — it's
**hardware**: Apple's new `SpeechTranscriber` on-device models are gated to ~M1/A17-class
hardware; the 2020 iPad Pro (A12Z, pre-M1) has NO model, so it can't subscribe/install. Proven:
- Build 250 device log: `Speech authorization status {status=3}` (auth GRANTED) yet STILL
  "not subscribed" on both streaming + stop-pass → unsupported hardware, not permissions.
- iPad-sim self-test: `SpeechTranscriber.supportedLocales == 0`, auth granted + locale reserved,
  install fails identically → the sim is a faithful UNSUPPORTED-DEVICE repro (also means the sim
  can NEVER validate a working Apple-dictation fix — 0 models).
- Apple docs (SpeechTranscriber): "Use `isAvailable`/`supportedLocales` to see if the device
  supports [it]. If it does not, consider … using `DictationTranscriber` instead."

Builds 249 (reserve) + 250 (Speech auth request) were both REAL prerequisites for SUPPORTED
devices (and stay in), but neither could conjure a model onto A12Z.

**251 fix — DictationTranscriber as a peer Apple engine, gated on `SpeechTranscriber.isAvailable`:**
- `TranscriptionService.appleEngineIsSpeechTranscriber = SpeechTranscriber.isAvailable` — single
  branch point. Available → SpeechTranscriber (unchanged). Unavailable → DictationTranscriber.
- New `DictationStreamingSession.swift` (actor, StreamingSession peer, `.progressiveLongDictation`
  + `.volatileResults`) + `DictationOneShotEngine.swift` (stop-pass). Reuse the shared
  auth (`ensureSpeechAuthorization`) + reserve/install flow (`resolveReservedLocale`). NOTE:
  `DictationTranscriber` has NO `isAvailable` (it's the un-gated broad-compat engine) — the
  Preset init requires `contentHints` explicitly (unlike SpeechTranscriber's 3-arg init).
- Capability diagnostics (ONE DiagnosticsLog entry, `.appleDictationAB`): speechIsAvailable,
  speech supported/installed counts, dictationLocaleSupported, dictation supported/installed
  counts, resolvedEngine — so the iPad run is conclusive either way.
- Both DictationTranscriber paths still skip Parakeet warm / no Parakeet fallback (it's useAppleEngine).

Sim self-test (`AppleStreamingSession.simSelfTest`, `#if targetEnvironment(simulator)`) + its
JotApp init call are TEMP — remove before commit. Build 251 green (device archive excludes them).

**Pending device verdict:** does A12Z support DictationTranscriber? If yes → iPad works. If no →
diagnostics show it and Apple dictation isn't possible on that specific iPad at all.

**Still owed (unchanged from 250):** picker Apple-provenance for the 10 langs, WatchLanguage sync,
searchable Settings picker, doc/Atlas sync, then commit.

## Repo-wide band-aid hunt + triage (2026-07-06, Opus)

Read-only sweep of all 230 source files. Codebase judged largely SOUND (FirstBufferLatch,
liveness heartbeats, deadline timers, capability thresholds, keyboard-paste stack all evaluated
as LEGITIMATE — not band-aids). ~5 genuine band-aids found. Owner triage:
- **#1 `JotApp.swift:~1099` — cold-launch 700ms sleep + 1 blind retry on `.micUnavailable`** → the
  root cause of the known "first Jot-down after cold launch doesn't record" bug. **FIXING** (owner
  said "fix it now"): replace the blind fixed-sleep with a bounded poll on the REAL mic-input-ready
  signal. Agent `fix-first-tap`.
- **#3 `HomeScreen.swift:436` + `SetupWizardView.swift:218` — defensive `ownsActiveRecording=false`
  scrub** masking Ask not resetting its own ownership flag → keyboard-Stop-won't-stop regression.
  **FIXING**: Ask resets the flag in its own teardown; delete the 2 scrubs. Agent `fix-owns-flag`.
- **#5 `VocabularyStore.swift:~94` — silently-swallowed vocab-save disk failure.** **FIXING**:
  surface it (Settings status row + DiagnosticsLog). Agent `fix-vocab-save`.
- **#2 `RecordingService.swift:2448` — `deliberateSwapGrace` 1s echo-suppression heuristic.**
  **ACCEPTED** — AVAudioSession gives no token to distinguish our own config-change echo from a
  real one; no clean root-cause fix exists (also = audio-review's A3).
- **#4 `AppGroup.swift:485` — "Apple default" flag flagged as spike-leak.** RESOLVED by the product
  decision (Apple-default-everywhere + Parakeet opt-in upgrade IS the shipped design). No fix.
- **Tier 2/3 (keyboard paste magic numbers, watch WCSession reactivate, minor UI `asyncAfter`)** —
  LEFT: platform-gap workarounds judged best-available; ripping the keyboard paste stack risks the
  double-paste class that burned builds 103–106.

## Spick-and-span cleanup COMPLETE (2026-07-06) — 0 of our compiler warnings

Clean build: `** BUILD SUCCEEDED **`, **0 Jot warnings** remain (only ~4 vendored `mlx-swift`
C++17-extension warnings in SourcePackages/checkouts — third-party, not ours). Done via 4 parallel
agents + verification:
- **Deprecations:** iOS-26 `Text +` concat → `Text` interpolation / `AttributedString` (TranscribingText,
  ActionsPopover, CorrectionReviewSection/Strip, TryKeyboardStep, SeeForYourselfPage); TTS
  `export()/status/error` → `export(to:as:)`; `UIScreen.main` → window-scene screen; dead `default:`.
- **Concurrency (Swift 6):** the `AVAudioConverterInputBlock` non-Sendable `AVAudioPCMBuffer` capture +
  `suppliedSource` var → `@preconcurrency import AVFoundation` + `Mutex<Bool>` across AppleStreamingSession,
  DictationStreamingSession, AppleDictationEngine, DictationOneShotEngine (matching CaptureContext idiom);
  spurious `await`s removed; FeedbackView/EngineABTestLab actor-isolation fixed properly.
- **REAL bugs found in cleanup:** (1) `allDeviceModelTargets()` warmed Parakeet **v3 unconditionally**
  even on `!parakeetUsable` devices (= the "v3 skipped" log spam) → now gated. (2) upgrade nudge gated on
  `is600MCapable` (TRUE on A12Z) not `parakeetUsable` → fixed. (3) TranscriptionService:1319 "dead code"
  was actually device-branch after a `#if simulator return` — restructured to `#if/#else` (deleting it
  would've removed production Parakeet load).
- **Naming:** `appleDictationAB` → `appleDictation` (30 refs / 5 files); "A/B spike/experimental" wording
  retired. KEPT the genuine hidden "Engine A/B Test Lab" dev tool.
- **S2 scaffolding removed:** `TapOnceGate` + log, 6× `[WARM-HOLD-DEBUG]`, the kickOffStreamingSession
  `[PREVIEW-DIAG]`. **LEFT deliberately:** `[PREVIEW-DIAG]` in StreamingPartial.swift + PreviewScheduler.swift
  — the streaming-preview path is still unverified on HW; those are owner-read diagnostics we'd need.
  Sweep once streaming is device-verified.

**Still owed:** the 3 owner-decision items below (A2, S1, Settings-toggle gate), doc/Atlas sync, commit
(after device-verify). New TestFlight build must be ≥252.

## Audio-architecture adversarial review (2026-07-06, Opus) — findings

Reviewed RecordingService + the 3 Apple engine files re: warm-hold ↔ Apple-engine ↔ session
soundness (owner concern: "warm hold trips over itself"). Warnings 14→0, build green.

**KEY CONCLUSION — warm-hold and the Apple engine do NOT trip over each other.** grep-confirmed
ZERO `AVAudioSession` refs in `App/Transcription/` — the Apple SpeechAnalyzer/SpeechTranscriber/
DictationTranscriber engines are pure `[Float]`-in compute (own converter + AsyncStream); they
NEVER touch the session/mic/route while RecordingService owns capture. No second session owner.
The residual fragility is entirely within RecordingService's OWN warm↔capture category swapping on
old HW — intrinsic to the mixable-idle feature, not a cross-engine bug.

**Warnings FIXED (properly):** spurious `await` on sync `depositStreamingArtifact` (RecordingService
637,659); the `AVAudioPCMBuffer` non-Sendable capture + `suppliedSource` var-mutation in the
`AVAudioConverterInputBlock` across AppleStreamingSession/DictationStreamingSession/
AppleDictationEngine → `@preconcurrency import AVFoundation` + `Mutex<Bool>` (Synchronization),
matching the existing `CaptureContext.ingest` sibling pattern.

**Verified GOOD (keep):** first-buffer confirmation gate (real fix, not band-aid); `restoreSession()`
only in `fullyTeardownEngine` (no churn between rapid warm dictations); `.measurement` mode justified
(raw audio for ASR + forces exclusive `.record`).

**Structural findings — decisions:**
- **A1 (warm-hold category thrash = the A12Z fragility):** every stop swaps `.record`→`.playAndRecord`
  +reactivate; every resume swaps back. Load-bearing (mixable-idle needs `.playAndRecord`; clean
  capture needs exclusive `.record` or other-app audio acoustically bleeds in — `.measurement` has no
  echo cancel). KEEP; add no further hot-path session ops. This churn is the known A12Z HW-wedge cost.
- **A2 (resume activation asymmetry — POSSIBLE REAL BUG, owner decision):** `makeWarmIdleSessionMixable`
  does setCategory + `setActive(true)`; `startFromWarmHold:876` does setCategory(.record) WITHOUT the
  matching `setActive(true)`. If the "reactivation required for policy to apply" comment holds, a
  RESUMED capture may stay effectively mixable → other-app audio bleeds into the START of the resumed
  transcript. Fix = add `setActive(true)` on resume (but +1 HAL op on wedge-prone HW). NEEDS on-device
  check: does a resumed capture actually interrupt other-app audio? NOT changed.
- **A3 (`deliberateSwapGrace` 1s heuristic):** suppresses our own `AVAudioEngineConfigurationChange`
  echo so it's not misread as external + cool the warm hold. Load-bearing band-aid; a slow echo >1s on
  A12Z could spuriously cool. No structural signal exists (notification carries no cause). KEEP.
- **S1 (unbounded AsyncStream buffering, owner follow-up):** the Apple sessions use default unbounded
  `AsyncStream<AnalyzerInput>`; if `feed()` outpaces SpeechAnalyzer on the slow A12Z (the device
  DictationStreamingSession targets), buffers grow unbounded → memory risk. Recommend bounded policy +
  on-device sizing. NOT fixed (needs device data). Both files are "NOT YET VERIFIED against real HW".
- **S2 (diagnostic scaffolding to remove):** `TapOnceGate` + its `[recording] first tap callback` log
  (self-labeled "remove once verified"), `[WARM-HOLD-DEBUG]` notices, `[PREVIEW-DIAG]` DiagnosticsLog
  in `kickOffStreamingSession` ("remove once diagnosed"). Harmless dead weight → clean up.

## Work log (newest last)

- **[start]** Goal written to design.md. Implementation plan v2 saved. Opus 4.8
  plan review launched. Harness prep (V3–V8 test cases) starting in parallel since
  it touches no production code and every step gates on it.
- **[+1]** Harness re-synced to clean production `AppleStreamingSession` (debug
  instrumentation stripped), rebuilt, V1 baseline re-run: mean WER 0.062, all 6
  files stream progressively — identical to the instrumented run, so the harness
  is a trustworthy regression gate. Opus plan review still running (idle-pinged
  without delivering text; re-requested the findings).
- **[+2] PLAN CLEARED by Opus 4.8 review.** Verdict: safe to execute, no CRITICAL
  issues, 3 amendments (all applied to the plan doc): (MED-1) Step 5b moves lines
  645-651 not 644 — `inferenceStartedAt` must stay in runInference; (MED-2) add
  `depositStreamingArtifact(nil)` to tearDown's no-scheduler branch to close the
  last staleness gap; (LOW-3) doc-note the nested-error-string on the rare
  FluidAudio failure path (happy path is byte-identical). Opus independently
  confirmed in CODE: FluidAudio-OFF byte-identical, the Step-6 coverage gate is
  exact + fails safe (a partial transcript can never be promoted), all 9 current
  features preserved, and Step 4 shadow deletion is clean.
- **[+3] WAVE A LAUNCHED (parallel, per Opus's disjoint-file grouping):** 3 Sonnet
  implementers editing disjoint files simultaneously — Steps 1+2 (RecordingService),
  Step 3 (AppleStreamingSession + StreamingBufferQueue), Step 4 (retire shadow-run
  in TranscriptionService). Edit-only; the lead does ONE combined build + harness
  gate + Opus diff-review after all three land. Steps 5→6→7 are strictly sequential
  after (Opus: highest blast radius, shared files) — NOT parallelized.
- **[+4] WAVE A LANDED + COMBINED BUILD SUCCEEDED.** All three implementers reported
  clean self-reviews (Steps 1+2: generation field bumped at exactly 3 sites/read at 1,
  kickoff rewritten w/ .stale disposal + resume-prefix-before-await, Step 6 TODO marker
  left; Step 3: tail flush + queue-cap accounting mirrored on all 3 paths, feed()
  byte-identical; Step 4 report re-requested but its edits compile). Full app
  `xcodebuild` → BUILD SUCCEEDED, which independently proves Step 4's shadow-run
  deletion left no dangling `publishedCorrections` reference. Harness re-synced to the
  new AppleStreamingSession (tail flush) + rebuilt clean; V1 regression running.
  Pending before Steps 5-7: V1 result + Step 4's grep-confirmation report + an Opus
  diff-review of the Wave A regions.
- **[+5] WAVE A FULLY VERIFIED.** V1 regression post-Wave-A = 0.062 (unchanged);
  Step 4 confirmed clean by direct grep (zero `publishedCorrections`, zero
  `.record` call sites, Lab `loadAll`/`setMark` still used). Wave A closed.
- **[+6] STEP 5 (CRUX) IMPLEMENTED + BUILDS GREEN.** Fresh Sonnet agent extracted
  `runInference` into `fluidAudioStopPass`/`appleStopPass`/`stopPassTranscribe` +
  wired `usesBatchModel` across all 4 files. Self-trace: every old statement lands
  in exactly one place, vocab async-let still launches before the engine call,
  `inferenceStartedAt` stays in runInference, Apple path never touches FluidAudio
  except via the explicit fallback. Full-app `xcodebuild` → BUILD SUCCEEDED.
  Focused Opus 4.8 adversarial review of the Step 5 diff LAUNCHED (heaviest review
  point — decoder-state per-call, prepare-gating on Apple path, vocab spot without
  ensurePreparing, error surface, warmUp-skip side effects). Holding Step 6 until
  that verdict.
- **[+7] STEP 5 CLEARED by Opus 4.8 diff-review.** Faithful, behavior-preserving
  extraction; NO critical/high; FluidAudio-off proven byte-identical vs HEAD. 3 LOW:
  LOW-2 (blanket catch masked CancellationError) FIXED — added
  `catch is CancellationError { throw }` before the fallback; LOW-1 (vocab spot now
  launches before the prepare-wait — bounded, output-neutral) noted; LOW-3 (cosmetic
  nested error string) plan-acknowledged. Rebuilt → BUILD SUCCEEDED. Owner caveats:
  (1) H2 RAM claim is PARTIAL — Parakeet still loads at LAUNCH regardless of toggle
  (keeps vocab scorer prepared); real win = "no cold 16s stall + no per-recording
  re-warm," not "never loads." (2) tree carries an adjacent merge→mergeWithProposals
  change from earlier vocab work — engine-neutral, not from Step 5.
- **[+8] STEP 6 PRE-GATE starting:** extend harness with V7 (streaming-assembled vs
  one-shot AppleDictationEngine WER parity, ~15 files; gate = streaming ≤ one-shot +
  0.01 abs) + V8 (vocab merge on streaming-synthesized timings). Step 6 code is
  written ONLY if V7 passes; else keep one-shot re-transcribe + report numbers.
- **[+9] V7 GATE PASSED DECISIVELY.** 15 real files through BOTH the streaming
  session AND the production one-shot AppleDictationEngine: mean STREAMING WER 0.101,
  mean ONE-SHOT WER 0.101, **mean delta +0.000.** Promoting the streamed text costs
  ZERO accuracy vs re-transcribing → owner's "why redo it?" empirically vindicated.
  Step 6 (promote-streaming-text) is SAFE to build. (Note: the WER is higher than the
  earlier 6-file 0.062 because this is a larger, harder 15-file sample — irrelevant to
  the gate; the DELTA is what matters and it's zero.)
  V8 CALL (vocab-merge-on-streaming-timings): building it fully standalone is
  impractical (needs the bundled CTC model + VocabularyStore + merge infra). Decision:
  Step 6 factors the timing-synthesis into a SHARED helper reused by BOTH the one-shot
  and the streaming path, so the streaming timings have byte-identical shape to the
  one-shot's — which already drives the vocab merge today AND was owner-verified
  on-device during the spike ("CTC vocab boost works on Apple's engine"). So V8's risk
  reduces to "do Apple's isFinal-run audioTimeRanges work as well as the one-shot's" —
  an on-device empirical question, covered by the CHECKPOINT 2 vocab test (dictate a
  vocab term on the Apple path, confirm it corrects). Documented, not skipped.
- **[+10] STEP 6 implementation starting** (Sonnet agent, plan 6a-6c + the MEDIUM-2
  depositStreamingArtifact(nil) amendment + wiring the TODO marker Steps 1+2 left).
- **[+11] STEP 6 IMPLEMENTED + BUILDS GREEN.** Shared `words(from:)` helper extracted
  from AppleDictationEngine (one-shot output byte-equivalent), streaming session now
  collects consumedSampleCount + per-word timings on isFinal, `stopArtifact()` gated on
  `volatileText.isEmpty && !finalizedText.isEmpty`, `StreamingStopArtifact` in the
  protocol (PreviewScheduler returns nil), promote-check in appleStopPass gated on exact
  `sourceSampleCount == samples.count && <60s`, both tearDown branches deposit
  (arms-or-disarms), makeStreamingSession clears defensively. Agent needed one extra
  `import FluidAudio` in 2 files (TokenTiming type) — mechanical, not a design change.
  Full-app `xcodebuild` → BUILD SUCCEEDED. Focused Opus 4.8 review of the coverage-gate
  correctness LAUNCHED (the "never promote a partial" invariant — sample-count identity,
  stale-artifact windows, finalize-error partial, pause/resume fallback). Holding Step 7
  until that verdict.
- **[+12] STEP 6 REVIEW: 1 HIGH found + FIXED, else invariant holds.** Opus verified
  in code that count-identity, pause/resume fallback, stale-artifact impossibility, and
  finalize-throw safety all hold — EXCEPT one reachable hole (FINDING 1): `feed()` bumps
  `consumedSampleCount` at the top, but 3 paths (buffer alloc fail, mid-stream converter
  error, empty conversion) can drop a counted chunk WITHOUT yielding it → interior gap
  passing BOTH guards → silent partial saved note (rare: converter/alloc failure
  mid-recording). FIXED per Opus's prescription: `coverageComplete` poison flag, set
  false in all 3 drop paths + empty-output case, gated into `stopArtifact()`. Any in-feed
  drop now forces the one-shot. Rebuilt → BUILD SUCCEEDED. Opus verdict: "with that one
  change applied, invariant provably held, Step 6 safe behind the toggle." FINDING 2 (LOW
  exotic same-count-within-60s overlap) left as noted non-blocker.
- **[+13] STEP 7 (final code step) starting:** move Apple's one-time asset install out of
  the live recording to toggle-flip time. Sequential (shares TranscriptionService +
  AppleStreamingSession with Step 6).
- **[+14] STEP 7 DONE + ALL 7 STEPS BUILD GREEN.** Shared `makeConfiguredTranscriber()`
  helper extracted, `preinstallAppleAssets()` (never throws) fires only on toggle→true.
  Full-app xcodebuild → BUILD SUCCEEDED.
- **[+15] SIMULATOR SMOKE TEST PASSED (for what sim can validate).** Installed + launched
  build on the 17 Pro sim: clean launch, home renders normally, hero prompt rotates, NO
  crash reports. (Sim can't exercise Apple's engine or the mic recording flow — that's the
  harness + your on-device checkpoints.)
- **[+16] ✅ TESTFLIGHT BUILD 245 (2.0) UPLOADED SUCCESSFULLY.** altool: "No errors
  uploading archive … Jot.ipa", 847MB in 22s. Bumped 244→245, marketing 2.0 (matches
  committed HEAD). Uncommitted per the standing rule — awaiting owner device verdict, then
  commit. **What-to-test checklist is at the TOP of this file.** THE OVERNIGHT RUN IS
  COMPLETE: goal met (two peer transcribers, all features preserved, no known bugs), plan
  authored by Fable + Opus-reviewed, 7 steps implemented (mostly parallel where safe) with
  a build+harness+Opus gate on each crux step, 1 real HIGH bug found+fixed, real-audio
  harness-verified, sim-smoke-tested, shipped to TestFlight.
