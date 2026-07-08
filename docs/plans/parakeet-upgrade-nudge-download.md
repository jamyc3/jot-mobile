# Parakeet-upgrade nudge: "Switch" does nothing + needs background download-on-charge

**Status: BACKLOG — initial design only, NOT started. NEEDS VALIDATION before build.**
Recorded 2026-07-07 from owner report.

## The bug (as observed)

After someone uses **Apple dictation** for a while, the keyboard surfaces the
Parakeet-upgrade nudge ("More accurate dictation — switch to Jot's engine").
When they tap **Switch / Use Jot's engine, nothing happens** — no visible
change, no confirmation, dictation quality is unchanged.

## Why (code reality)

- The keyboard nudge tap (`JotKeyboardViewController.handleParakeetNudgeUpgrade`,
  :827) opens `jot://upgrade-engine`, routed (`Router.swift:70`,
  `JotApp.swift:593`) to **`UpgradeEngineView`**.
- `UpgradeEngineView.useJotsEngine()` just flips
  `AppGroup.useAppleDictationForEnglish = false` and dismisses. It assumes
  **Parakeet 600M is bundled and already on device**, so the switch is instant
  with no download step. The file's own header NOTE already flags this:
  > "When the bundle is stripped later … this screen will need a
  > download-progress state before flipping the toggle."
- In the **stripped build (258+) that world is now here**: on a device where the
  Parakeet model was never carried/downloaded, flipping the flag switches to an
  engine whose model isn't present → nothing usable happens. Even in a bundled
  build, the flip is silent (no confirmation), which can also read as "nothing
  happened."
- **Also unvalidated:** whether the keyboard→`jot://upgrade-engine` deep link
  reliably foregrounds the app at all (keyboard extensions have restricted
  `openURL` behaviour). Part of the "nothing happens" symptom may be here —
  **validate this first**, before designing the download flow.

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
