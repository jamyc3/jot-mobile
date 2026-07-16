# Parakeet-upgrade nudge: "Switch" dead-tap FIXED; background download-on-charge is the remaining enhancement

**Status: primary "nothing happens" bug FIXED 2026-07-07 (awaiting owner device-test). Background download-on-charge + auto-enable enhancement IMPLEMENTED 2026-07-14 (compiles Jot + JotKeyboard; awaiting owner copy-review + on-device test — the discretionary Wi-Fi+charging transfer and background-relaunch handoff can't be exercised in the sim). Design as-built matches the sketch below.**
Recorded 2026-07-07 from owner report.

## As-built (2026-07-14)

- **`ParakeetModelFetcher`** (`Jot/App/Transcription/`) — a second background,
  discretionary, Wi-Fi-only `URLSession` mirroring `EmbeddingModelFetcher`
  exactly: 22-file v2 manifest (subset the loader needs, sizes parity-checked
  live vs `FluidInference/parakeet-tdt-0.6b-v2-coreml`), per-file staging across
  relaunches, pinned `weight.bin` sizes + `AsrModels.modelsExist` verify, atomic
  install into the SAME `…/Models/parakeet-tdt-0.6b-v2` dir carry-forward uses,
  install-time backup-exclusion. Runs only while `AppGroup.parakeetDownloadPending`;
  `resumeIfPending()` at launch recovers force-quit cancellation.
- **`ParakeetModelArrival`** — flips `useAppleDictationForEnglish=false` ONLY at a
  safe boundary (armed on arrival, applied when not recording — drained at
  recording-end in `HomeScreen` and at launch in `JotApp`), posts
  `parakeetEngineActivated`, sets the one-shot `parakeetSwitchedNotice`, prewarms.
- **`UpgradeEngineView`** — state machine: offerInstant / offerDownload /
  downloading / switched / ineligibleDevice / lowDisk. **`EngineSwitchedCard`** —
  home confirmation popup (the download almost always finishes backgrounded).
- **`JotAppDelegate`** now routes `handleEventsForBackgroundURLSession` by
  session identifier to the owning fetcher (two background sessions now).
- Eligibility: `TranscriptionService.parakeetUsable` + ~1.1 GB free-disk preflight
  + `parakeetV2ReadyOnDevice()`.
- **Validation item #1 (deep link foregrounds the app):** confirmed by code-read —
  `handleParakeetNudgeUpgrade` routes through the responder-chain `openContainingApp`,
  the same proven opener `jot://dictate` uses; HIGH confidence. Flag for a quick
  on-device confirm only.
- Keyboard UNCHANGED (reads no new state).

### Hardening (2026-07-15, post-review findings 1–7)

1. **No stuck "Downloading…" wedge.** `ParakeetModelFetcher.stopDownload()` +
   `cancelDiscretionaryFetch()` back a "Stop download" (keep Apple) action in the
   `.downloading` sheet state (cancels tasks, clears `parakeetDownloadPending`,
   drops staged files). Terminal errors — a 404 on a REQUIRED file (repo/path
   gone) or `maxInstallFailures` (3) repeated verify/rollback failures — now call
   `markTerminalFailure`: cancel, clear pending, raise `AppGroup.parakeetDownloadFailed`,
   which drives a retriable `.failed` sheet state (Try again / Keep Apple).
2. **Install-time disk re-check.** Before the staging→temp copy (~464 MB),
   `attemptInstallIfComplete` re-checks free disk against `installHeadroomBytes`
   (~550 MB); on shortfall it clears pending + drops staging so the sheet surfaces
   the retriable `lowDisk`/offer state instead of wedging.
3. **Last explicit choice wins.** The Settings "Use Apple speech engine" toggle
   (`SettingsView`) now clears `parakeetSwitchArmed` on ANY explicit change (either
   direction), disarming a pending auto-switch; the download itself keeps running.
4. **Copy honesty.** iOS has no strict-charging API (`isDiscretionary` only
   PREFERS power; Wi-Fi is the hard guarantee), so all copy now promises Wi-Fi
   firmly and charging softly: "in the background over Wi-Fi — usually while your
   phone charges." (offerDownload + downloading bodies, features.md §5.2b.)
5. **No double-pending.** `requestBackgroundDownload` sets `parakeetDownloadPending`
   only when files were actually enqueued (`enqueued > 0`) — the `enqueued == 0`
   inline-install path already cleared it.
6. **No latent switch.** The safe-boundary drain now also fires on
   `isPipelineInFlight` clearing (post-stop pipeline outlives `isRecording`), and
   `scenePhase == .active` calls `applyPendingSwitchIfSafe()` (not just refresh).
7. **No fake "downloading".** `requestBackgroundDownload()` returns `Bool`; the
   sheet only enters `.downloading` when it returns true (staging create OK),
   else `.failed`.

New App-Group keys: `parakeetDownloadFailed`, `parakeetDownloadInstallFailures`.
Both targets rebuilt clean (Jot + JotKeyboard, sim Debug).

### Final polish (2026-07-15, re-review NITs)

Re-review verdict: CLEAN / ship-ready. Fixed three NITs:
1. `.lowDisk` now offers a "Try again" button (re-runs `resolveScreen()`), so a
   user who freed space advances to the download offer instead of dead-ending on
   "Done" (mirrors `.failed`).
2. The Settings "Use Apple speech engine" toggle @State is re-seeded from the App
   Group on `.onAppear` AND on a `parakeetEngineActivated` observer, so a
   background auto-switch while Settings is open no longer leaves a stale Apple-ON
   toggle. (Kept @State, not @AppStorage; the re-seed is guarded so it doesn't
   re-fire the toggle's onChange when already in sync.)
3. `ParakeetModelArrival.applyPendingSwitchIfSafe` sets `parakeetSwitchedNotice`
   only when the flip actually CHANGES the engine — a user who manually switched
   to Jot's engine before the download landed no longer gets a redundant home
   popup (it still disarms + prewarms).

### Accepted residuals (reviewed, left as-is)

- **`stopDownload` one-file re-stage race** — `cancelDiscretionaryFetch()` is
  async (getAllTasks → cancel) while `cleanUpStaging()` runs synchronously, so an
  in-flight `didFinishDownloadingTo` could re-stage one file just after cleanup.
  Self-limiting: at most one stray file, `parakeetDownloadPending` is already
  false so nothing resumes it, and the next `requestBackgroundDownload` recreates
  staging fresh. Not worth an await handshake.
- **Transient 5xx on a REQUIRED file loops without a hard cap** — a required file
  returning repeated 5xx is left unstaged for retry (only a 404 is treated as
  terminal, and only install/verify failures hit the `maxInstallFailures` ceiling).
  A repo serving persistent 5xx on one file could re-attempt across launches.
  Mitigated by the user-facing **Stop download** exit and the discretionary
  (idle-only) scheduling; a download-attempt cap is possible future hardening.

## The bug (as observed)

After someone uses **Apple dictation** for a while, the keyboard surfaces the
Parakeet-upgrade nudge ("More accurate dictation — switch to Jot's engine").
Tapping **Switch / Use Jot's engine** did **nothing** — the app didn't even open.

## Root cause (FIXED) — nothing to do with 258/stripping

`JotKeyboardViewController.handleParakeetNudgeUpgrade` opened
`jot://upgrade-engine` via **`extensionContext?.open(url)`**. This file's own
`openContainingApp` documentation (JotKeyboardViewController.swift ~2740) spells
out that on **iOS 18+ UIKit silently force-fails the deprecated open path for
keyboard extensions** ("BUG IN CLIENT OF UIKIT … Force returning false"). The
working `jot://dictate` launch uses the **responder-chain opener**
`openContainingApp(url)`; the nudge was never switched over to it. So on every
iOS 18+ device, on **every** build (not just 258), the app never opened → the
tap was a pure no-op.

**Fix:** route `handleParakeetNudgeUpgrade` through `openContainingApp(url)`, the
same proven opener the dictate path uses. One-line change; no behavior redesign.

## What happens AFTER the app opens (already handled — was over-stated before)

Once `UpgradeEngineView` appears and the user taps "Use Jot's engine", it flips
`AppGroup.useAppleDictationForEnglish = false`. On a **stripped build** where the
Parakeet model isn't on disk, this is **not** a dead-end: the next Parakeet
dictation hits the **download-on-first-need backstop** in
`TranscriptionService.loadOrFail` (`!modelsOnDisk → .downloading(0)` → fetch v2
weights with progress → load; the §C "jumped straight to the stripped build"
path, guarded so the "reinstall" error does NOT fire when
`bundled600mDirectory() == nil`). So the model self-heals on first use with
progress shown in the dictation UI.

Two gaps remain — the *enhancement* the owner asked for, not a correctness bug:

## Desired behavior (owner's initial ask)

On **Switch**, decide based mainly on **device tier** (and free disk):

- **Parakeet-capable device** (iPhone 14 Pro+ / M1+ — the existing
  `TranscriptionService.parakeetUsable` gate) **and** enough free disk (~443 MB
  model + headroom): don't fail silently. Tell the user something like
  *"We'll download the better engine in the background while your phone is on
  charge, and switch you over automatically when it's ready."* Then:
  - Enqueue a **background, charging-gated (discretionary)** download.
  - On completion, **auto-enable** Jot's engine (flip
    `useAppleDictationForEnglish = false`) and notify the user it's now active.
- **Ineligible device or low disk:** say so plainly and keep Apple (no dead tap).
- **Model already present** (carried/bundled): instant switch as today, but with
  a confirmation so it doesn't read as a no-op.

## Initial design sketch (reuse externalization plumbing — do NOT build new)

The model-externalization work (`docs/plans/model-externalization-sub-50mb.md`,
shipped `a9c4b6c`) already built every piece this needs:

- **Download + install:** Parakeet already has a §C download-with-progress
  backstop (`V2CarryForwardMigration` download path) + `ModelCarryForward`'s
  verify-then-atomic-rename install. Route the nudge download through the SAME
  install path so there's one Parakeet install dir, not two.
- **Charging/Wi-Fi discretionary gating:** mirror `EmbeddingModelFetcher`'s
  background discretionary URLSession (Wi-Fi + charging, per-file staging across
  relaunches, pinned byte-size verify, atomic install). This is the closest
  existing analog — the nudge download is the same shape as the overnight
  EmbeddingGemma fetch, just triggered by a user tap.
- **Auto-enable on arrival:** mirror `EmbeddingModelArrival` — a model-arrival
  hook that, on Parakeet install completion, flips the engine flag and posts a
  cross-process "now active" signal. **Switch at a safe boundary, never
  mid-recording.**
- **Pending state:** persist a "Parakeet download in flight" App-Group flag so
  re-opening the nudge/`UpgradeEngineView` shows *"Downloading… we'll switch you
  automatically"* instead of re-offering. Clears on arrival or on failure.
- **Eligibility gate:** `parakeetUsable` for device tier; a free-disk preflight
  like `ModelCarryForward`'s per-asset check.

New surface needed: a downloading/queued **state in `UpgradeEngineView`** (its
NOTE anticipates exactly this), plus the fetcher wiring. Estimated **M**.

## Needs validation (before any build)

1. **Deep link actually foregrounds the app** from the keyboard nudge tap — is
   part of "nothing happens" the `openURL` restriction, not the missing model?
   Instrument/repro first.
2. **Device-tier + free-disk thresholds** — confirm `parakeetUsable` is the
   right gate and pick the disk headroom number.
3. **Charging-only vs. Wi-Fi+charging** — owner said "while on charge"; confirm
   whether cellular-while-charging is acceptable or Wi-Fi is also required
   (externalization invariant #4 says unprompted fetches stay unmetered; but
   this is user-initiated, so any-network may be fine — decide).
4. **Auto-enable UX** — where's the safe boundary to flip the engine, and how to
   notify (banner? next-launch note?) without surprising the user mid-use.
5. **Copy** for the queued / downloading / switched states.

## Do NOT

- Do not build a parallel download/install stack — reuse the externalization
  fetchers and the single Parakeet install dir.
- Do not flip the engine before the model is verified-installed.
- Do not switch engines mid-recording.
