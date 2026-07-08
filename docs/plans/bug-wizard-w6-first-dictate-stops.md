# Bug: Wizard W6 "Try the keyboard" — first Jot-down tap starts, flips to "Starting", then stops

**Status: ROOT-CAUSE FIX SHIPPED in 257 (2026-07-07) — awaiting owner re-test.**

## Trace outcome (static analysis, agent-verified)

PROVEN: the strip's "Starting" renders ONLY `.arming` (KeyboardView.swift:793-808),
published ONLY by `RecordingService.start()` (:802) — so a second, un-tapped
`start()` really ran, which requires the first recording to have already died
silently (`start()`'s `!isRecording` guard at :658 publishes nothing).

Most-probable chain (deterministic, fits every observed beat):
1. **LINK A (fixed)**: the cold `start()` path's `configureSession()` swaps
   the audio-session category (`.playAndRecord` mixable warm-idle → `.record`)
   **without stamping `lastDeliberateSessionSwapAt`** — the one swap site
   missing the stamp both warm-path swaps carry. The swap's async
   config-change echo then hit `handleEngineConfigChange` outside any grace →
   `internalStop("engine config change")` killed the recording mid-speech.
2. **LINK B**: with the recording observed dead, the keyboard's
   didn't-start fallback re-entered via the `jot://dictate` URL bounce →
   `triggerAutoStart` (forceStop + fresh `start()`) → `.arming` ("Starting")
   → first-buffer `cold-no-input` against the still-tearing-down mic →
   `.failed`, dead strip. A later manual tap works because the session is
   already `.record` (no swap ⇒ no echo).

## Fixes shipped (257)

- **Root cause**: `configureSession()` now stamps `lastDeliberateSessionSwapAt`
  before its category swap (RecordingService.swift, cold path) — the echo of
  the recording's OWN activation is ignored, recording #1 survives. Also fixes
  the same latent fragility for every cold start app-wide, not just W6.
- **Hardening**: `SetupWizardView.handleKeyboardDictateTapped` gained the
  `!isRecording && !isPipelineInFlight` guard its HomeScreen twin already had.
- **Instrumentation** (if the bug survives, in-app Diagnostics now names the
  killer): breadcrumbs on the config-change self-stop (main-app) and on the
  keyboard's URL-bounce path (keyboard) — one tap should log inline-Darwin OR
  bounce, never both.

## If it reproduces on 257

Grab Settings → Diagnostics immediately: count
`RECORDING START FROM: SetupWizardView.handleKeyboardDictateTapped` lines and
look for "external audio config change" / "URL-bounce (cold) path" breadcrumbs
in the failure window — they disambiguate the residual mechanism.

---

Original diagnosis-first record below, kept for history.

**RECORDED 2026-07-07, diagnosis-first.**

## Owner's exact repro (build 256, wizard RE-RUN — not a fresh install)

> "there is a bug in wizard, when i rerun it (i can't test a new wizard) in try
> the keyboard, when i move from how it works to next page. i tap try it,
> then, globe, then tap jot down, it starts and i speak, then it changes to
> starting and stops suddenly, i have to tap jot down again and then it works."

Sequence: W6 (Try the keyboard) → "Try it" → globe-switch to Jot keyboard →
tap Jot down → recording STARTS (user speaks) → UI regresses to "Starting" →
recording stops on its own → second Jot-down tap works normally.

## Context / caveats

- Observed on a wizard **re-run** (Settings → re-run wizard), which the owner
  notes isn't a clean first-run state. A fresh-install repro is still wanted
  before concluding anything — re-run leaves prior wizard/observer/recording
  state behind by construction.
- Smells adjacent to the standing backlog bug "first 'Jot down' tap after cold
  launch doesn't record" (`docs/plans/bug-cold-start-dictation-race.md`,
  memory `project_first_tap_no_record_bug`) — same shape (first tap fails,
  second works), different surface (wizard W6 keyboard test vs cold launch).
  Do NOT assume same root cause; the memory's standing instruction is trace
  before fixing (a retry band-aid was already rejected there).

## Candidate mechanisms (UNRANKED hypotheses — to be disambiguated by logs, not fixed on spec)

1. **Wizard re-entry leaves a duplicate W6 `keyboardDictateTapped` observer**
   (one per wizard run) — the second observer's start/cancel fighting the
   first could start-then-kill the session. Check observer add/remove
   lifetime in `SetupWizardView` / `TryKeyboardStep` across re-runs.
2. **Stale teardown from the PREVIOUS wizard run firing late** — the wizard
   contract cancels any wizard-started recording on dismiss
   (`closeAndComplete()`, gentle `cancel()`); a delayed teardown from run N-1
   landing after run N's start would produce exactly start→stop.
3. **Pipeline-phase regression**: "changes to Starting" = the keyboard strip
   re-rendered `publishPipelinePhase(.starting)` after audio was already
   flowing — a phase publisher racing a second start request, or a
   cross-process notification replay.
4. **Warm-hold / session arbitration**: W6 starts a pipeline recording while
   the keyboard-host context also manages audio-session state; an arbiter
   release on first activation could cut capture (would show in the
   AudioSessionArbiter diagnostics).

## Diagnosis plan (first steps, no code changes)

1. Repro on-device with in-app **Diagnostics** open (Settings → Diagnostics),
   then capture: `RECORDING START FROM:` lines (how many starts fired?),
   pipeline-phase transitions, any gentle-stop/cancel breadcrumbs, and
   AudioSessionArbiter entries in the failure window.
2. Compare a wizard re-run repro against a fresh-install run (owner notes
   fresh isn't currently testable — a sim fresh-install run may substitute).
3. Only then rank the hypotheses and design the fix. NO retry band-aids.
