# Carry-forward migration: ease existing users off the bundled v2 model without breaking anything

**Status:** 🎨 DESIGNED 2026-07-06, then REVISED after an Opus adversarial review that verified
the core mechanism against FluidAudio internals and found 4 must-fix gaps (now folded in below).
NOT built. **Review verdict: sound in mechanism, safe to implement once the C/C2/E/B-F fixes
below are honored** — without C and C2 specifically, an existing user's dictation breaks at the
strip while every check reports green. The failure mode is catastrophic (silent broken dictation
on update), so re-review the implementation against these same points before shipping the strip.

## Problem

Today Jot bundles the Parakeet 600M **v2** English model (~443 MB) *inside the app binary*
(`Jot/Resources/Models/Parakeet/parakeet-tdt-0.6b-v2/`). Every install carries it. We want to
eventually **strip it from the bundle** (ship it as a download-on-demand asset like the European
v3 models) to shrink the app and let Apple's engine be the no-download default.

**The danger:** the moment we ship a build that stops bundling v2, an existing user who *updates*
finds the model gone from the binary. Under a naive strip, their English dictation either breaks
or silently forces a **450 MB re-download** — a terrible update experience for someone whose
dictation worked fine yesterday. "Don't break anything" = an existing v2 user must keep working
English dictation across the update with **zero re-download and no visible disruption.**

## Goal / non-goals

**Goal:** existing v2 users keep working English dictation across the bundle-strip update, no
re-download, no engine change they didn't ask for. New users get Apple by default.

**Non-goals:** this doc is NOT the bundle-strip itself, NOT the Apple-default work (shipped), NOT
the upgrade nudge. It is only the *migration that makes the future strip safe*. It ships BEFORE
the strip.

## Key insight — the loader already falls through to the right place

`TranscriptionService.modelDirectory()` (TranscriptionService.swift:1401-1411) already does this
for English:

```swift
if LanguageChoice.current.isEnglish {
    if let bundled = bundled600mDirectory() { return bundled }   // bundle present → use it
}
return MLModelConfigurationUtils.defaultModelsDirectory(for: selectedRepo)  // else → App Support
```

So when the bundle is stripped, `bundled600mDirectory()` returns `nil` and English **already
falls through** to `defaultModelsDirectory(for: .parakeetV2)` — the App-Support cache directory
FluidAudio uses for downloaded models, and the same directory `modelsExist`/`download` resolve
against. **The strip is therefore not a code problem — it's a data problem: get the v2 weights
into that App-Support directory before the bundle disappears.** That is the entire migration.

## Design

### A. The carry-forward copy (the core of it)

A transitional release (still bundling v2) copies the bundled model into the App-Support
location on launch:

- **Source:** `bundled600mDirectory()` = `<Bundle>/Models/Parakeet/parakeet-tdt-0.6b-v2/`.
  Confirmed by review: this contains exactly `{Preprocessor,Encoder,Decoder,JointDecision}.mlmodelc`
  + `parakeet_vocab.json` — the full required set `modelsExist(version:.v2)` checks.
- **Destination:** `MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetV2)` — the
  exact directory a stripped build's `modelDirectory()` fallthrough returns, and that
  `AsrModels.modelsExist(at:version:)` checks (review verified this equality byte-for-byte:
  `repoPath = dir.deletingLastPathComponent() + folderName` resolves to the same
  `.../Models/parakeet-tdt-0.6b-v2/`).
- **⚠️ COPY MECHANICS (review B — build-142 trap):** the destination is the LEAF directory
  itself. `copyItem(at: bundledLeaf, to: destLeaf)` is correct ONLY when `.../Models/` exists and
  the dest leaf does NOT pre-exist. Do NOT pre-create the leaf and copy contents into it, and do
  NOT copy the four `.mlmodelc` dirs individually — either reproduces the build-142 folder-name
  bug. The leaf's last path component MUST be exactly `parakeet-tdt-0.6b-v2` (no `-coreml`).
- **⚠️ ATOMIC + VERIFIED, not copy-in-place (review C — HIGH, the one that silently detonates):**
  `modelsExist` only does `fileExists` on each `.mlmodelc` **directory** — it does NOT recurse or
  validate contents. So a partial/interrupted copy (dirs present, contents truncated) PASSES
  `modelsExist`, is invisible in Release T (bundle still loads), then loads corrupt and breaks
  English at Release S. Therefore: copy into a **temp sibling** dir, verify completeness, then
  **atomically rename** into the leaf (`FileManager.replaceItemAt` / atomic move). "Verify" must be
  stronger than `modelsExist` — a real check such as file-count/total-size match against the
  bundle, or an `AsrModels.load` smoke-test — because `modelsExist` alone cannot detect a truncated
  copy. A crash mid-copy then leaves only an abandoned temp dir (cleaned next launch), never a
  half-model in the leaf.
- **⚠️ FREE-SPACE PRE-FLIGHT (review F):** temp+rename needs ~900 MB transient (bundle ~443 MB +
  temp copy). Check `volumeAvailableCapacityForImportantUsage` before copying; if short, skip
  cleanly and retry next launch (harmless in Release T — bundle still serves dictation).
- **When — idempotent presence check every launch, NO flag** (honors the flag-before-work
  antipattern rule): on launch, if `bundled600mDirectory() != nil` and the destination doesn't
  already hold a VERIFIED-complete copy, do the atomic copy above. Once done, a cheap no-op
  forever; self-healing on failure, no stuck-flag trap. Off the main thread.
- **Backup-excluded:** set `URLResourceValues.isExcludedFromBackup = true` on the destination
  (the retained-audio store already sets this precedent) so a 450 MB model doesn't bloat iCloud
  backups. Application Support is not auto-purged (unlike Caches/), which is why it's the right
  container.

### A2. What the strip removes — ONLY the v2 subdir (review C2 — HIGH)

The bundled `Resources/Models` folder reference (project.yml:197-198) contains MORE than v2: the
**CTC vocab scorer** `parakeet-ctc-110m-coreml` (~99 MB, bundle-only, no download branch —
`CtcModelCache.swift:34-73`) **and EmbeddingGemma** (used by Ask). The CTC scorer runs the
vocabulary boost **even when English dictation is on Apple's engine** — so it is load-bearing
regardless of engine. **Release S must strip ONLY the `parakeet-tdt-0.6b-v2` subdirectory, and
keep the CTC scorer + EmbeddingGemma bundled.** The carry-forward copies ONLY the 600M v2; the
99 MB scorer and EmbeddingGemma stay in the bundle (they're small — not worth the migration
complexity, and the scorer has no download backstop). A blunt strip of `Models/Parakeet` or the
whole folder reference would kill vocab boost (silently, no fallback) + Ask embeddings.

### A3. Don't let a future orphan-sweep delete the carried model (review G)

After carry-forward, capable devices have a v2 model in App Support, but
`activeDownloadedModelDirectory()` (TranscriptionService.swift:1584) returns nil on 600M-capable
devices today. A planned orphan-model cleanup sweep (docs/plans/single-model-600m-rip-eou.md) is
told to exclude "the active downloaded model" — which, per that nil, would treat the carried v2 as
an orphan and DELETE it out from under Release S. **When carry-forward ships, that accessor / the
sweep's allowlist MUST be updated to include the carried v2 dir** so no cleanup can reclaim it.

### B. The two-release sequence

1. **Release T (transitional) — still bundles v2.** Adds the §A carry-forward copy on launch.
   Also the release where Apple-becomes-default lands for NEW users (§D). Existing v2 users are
   untouched behaviorally — v2 still loads (from the bundle *or* the fresh App-Support copy; both
   exist), dictation identical. The copy is invisible.
2. **Release S (strip) — removes the bundle.** `bundled600mDirectory()` → nil → English resolves
   to the App-Support copy Release T made → `modelsExist` true → dictation works, zero download.
   App binary shrinks by ~443 MB.

Release S must not ship until enough of the field has run Release T (see §C soak).

### C. The "skipped Release T" tail — download-if-missing backstop

A user who jumps straight from an old bundled build to Release S (never ran T) has no
App-Support copy → `modelsExist` false. Without a backstop their English dictation breaks. So
**Release S must keep a graceful download-if-missing path for English v2**: if the App-Support v2
is absent, treat English exactly like a European language today — surface the download-on-first-
dictation flow (with `.downloading` progress), not a broken/empty dictation. This turns the worst
case from "broken" into "one-time 450 MB download with a progress bar" — acceptable, not silent.

**Soak gate:** before shipping Release S, measure what fraction of active users have run Release T
(a lightweight already-carried-forward signal, or just calendar time across ≥1–2 update cycles).
The download-if-missing backstop means the tail isn't catastrophic, but we still want the vast
majority carried-forward silently. `log()` / surface the carried-vs-download split so we're not
guessing.

### D. Existing-vs-new-user default (the "existing users stay on Parakeet" rule)

Owner's direction: existing users stay on Parakeet (their working engine); new users get Apple by
default. The shipped test build defaults `AppGroup.useAppleDictationForEnglish` to **true
globally** — which is wrong for existing users (it would flip a working-v2 user to Apple on
update). Production resolution, decided at Release T's first launch **once**:

- **Existing user** = evidence of prior use before Release T. **⚠️ SIGNAL CHOICE (review E —
  HIGH):** "has saved transcripts via SwiftData" is a BAD early-launch signal — the SwiftData
  container loads async/heavy/racy and isn't reliably queryable before the recording subsystem
  can service a start. Prefer, in order: (a) **a beacon shipped in a release AHEAD of Release T**
  (a small persistent App-Group/file marker written by every pre-T build) — most reliable;
  promote this from an open question to a REQUIREMENT if the timeline allows a pre-T release; else
  (b) a cheap synchronous `FileManager` existence check on the SwiftData store FILE on disk (not a
  query — just "does the store file exist," which means an established install), or a long-standing
  App-Group key that predates the Apple-default work. If existing → set
  `useAppleDictationForEnglish = false` explicitly (keep Parakeet), mark migrated.
- **New user** = fresh install of Release T+ with no prior-use evidence → leave Apple default
  (true), mark migrated.
- **⚠️ LAUNCH ORDERING (review E — HIGH):** `useAppleDictationForEnglish` defaults TRUE globally
  and is read fresh per dictation (`useAppleEngine`, TranscriptionService.swift:997). Recordings
  can start WITHOUT the app UI — Action Button, `DictateIntent`, a cold `jot://dictate` — so a §D
  resolution that runs in a root-view `.task` can be BEATEN: an existing user's very first
  post-update English dictation would silently go to Apple before §D flips them back. **§D must
  resolve SYNCHRONOUSLY and EARLY — in App init, before the recording subsystem can service any
  start — off the cheap signal above (never a SwiftData query).** The global-true default must not
  be observable by any dictation path before §D has run once.
- Write the resolution ONCE (guarded so it never re-runs and clobbers a later explicit user
  choice — an explicit Settings toggle always wins thereafter). Touches only a UserDefaults/
  App-Group value, **not** the SwiftData schema (no `@Model` change — stated explicitly per the
  schema-impact rule).

**Coupling to the nudge:** existing users kept on Parakeet don't need the "upgrade to Parakeet"
nudge (they're already on it). New users on Apple are exactly the nudge audience. So §D's
existing/new determination is also the nudge-eligibility signal — build them together or share
the marker.

## Edge cases

- **Disk full during copy (Release T):** copy fails → v2 still loads from the still-present bundle
  → no breakage in T. Retries next launch. Only matters at Release S, where the download-if-missing
  backstop (§C) covers a user who never got a successful copy.
- **Delete + reinstall of Release T+:** fresh install → new-user path → Apple default. Expected;
  the user can switch back in Settings. (A reinstalling existing user loses "existing" status —
  acceptable, and the download-if-missing backstop still gives them v2 if they switch.)
- **App thinning / on-demand resources:** the bundled model is a folder reference in `project.yml`;
  confirm it's not sliced/ODR such that `bundled600mDirectory()` could be absent on a normal
  Release T install (it isn't today — it's a plain folder reference, always present).
- **Non-English languages:** unaffected — European v3 already downloads to App Support; this only
  adds v2 to the same scheme.
- **Keyboard extension:** reads model state the same way; no change. It never copies (main app owns
  the carry-forward); the keyboard only ever reads `modelsExist`-style state.
- **Corrupt partial copy:** §A's post-copy verify + delete-and-retry handles it; a partial copy
  never satisfies `modelsExist` (it checks the full `.mlmodelc` set), so it can't masquerade as done.

## Test plan

- **Local (before ship):** on a device/sim, run a build with the carry-forward copy, confirm the
  model lands at `defaultModelsDirectory(for: .parakeetV2)` with the correct `parakeet-tdt-0.6b-v2`
  leaf, `isExcludedFromBackup` set, and `modelsExist(at:version:.v2)` true. Then simulate the strip
  by temporarily pointing `bundled600mDirectory()` to nil (or a build with the bundle removed) and
  confirm English dictation still loads from App Support with zero download.
- **Upgrade path (the real test):** install an OLD bundled build → dictate (become an "existing
  user") → update to Release T → confirm (a) carry-forward copy happened, (b) still on Parakeet,
  no engine flip, no re-download → update to a Release-S simulation (bundle stripped) → confirm
  English dictation still works instantly, Diagnostics shows "loaded v2 from App Support", zero
  download.
- **Skip-T path:** old bundled build → straight to Release-S simulation → confirm graceful
  download-if-missing (progress shown), not broken dictation.
- **New user:** fresh install of Release T → Apple default, no carry-forward needed, no v2 unless
  they pick it.
- Honor the verify-locally-first rule: prove the copy + fallthrough on a real install before any
  TestFlight of Release S.

## Open questions

1. **Existing-user signal (§D) — review leaning: pre-shipped BEACON.** The review downgraded
   "has saved transcripts (SwiftData query)" as unreliable/racy at early launch and recommended a
   beacon written by a release shipped AHEAD of Release T (or, failing that, a synchronous
   `FileManager` check on the SwiftData store FILE's existence). Decision needed: do we have room
   for a pre-T beacon release in the timeline? If yes, ship the beacon in the very next
   maintenance build so it's soaking before T. (This is the single most important open item —
   getting §D wrong flips existing users to Apple.)
2. **Soak criterion (§C):** ship Release S on a % of Release-T adoption, or on calendar time?
   No telemetry (Jot sends nothing off-device except feedback) → likely conservative calendar time
   across update cycles. The download-if-missing backstop bounds the worst case regardless.
3. **Is the strip even worth it yet?** The whole carry-forward exists to enable the strip. Confirm
   the app-size win (~443 MB — note the ~99 MB CTC scorer + EmbeddingGemma STAY bundled per §A2, so
   the real shrink is ~443 MB not the full Models folder) is still the goal vs. keeping v2 bundled
   and just defaulting to Apple (which the shipped build already does). The carry-forward is only
   needed if/when we actually strip — and per the review it is NOT safe to strip without the
   C/C2/E fixes above.

## Sizing

**M** for the carry-forward copy + existing-vs-new resolution + download-if-missing backstop
(Release T). The strip itself (Release S) is **S** once T has soaked. Multi-release calendar
dependency makes the whole thing **L** in wall-clock even though each code change is modest.

## Cross-links

- [design.md](design.md) — the "MUST-PLAN carry-forward" stub this doc fleshes out, and the
  go-forward direction (Apple default, existing-users-stay-on-Parakeet).
- `TranscriptionService.modelDirectory()` / `bundled600mDirectory()` / `modelsExistOnDiskForSelectedVariant()`
  — the loader whose existing App-Support fallthrough makes the strip a data-only migration.
- The upgrade nudge (shares §D's existing-vs-new determination).
