# Model externalization — sub-50 MB app

**Status: SHIPPED to TestFlight & owner-validated. Build A (carry-forward-all) = 256/257, submitted to App Store review 2026-07-07. Build B (strip-all) = 258, cut with `scripts/strip-models.sh`, uploaded to TestFlight, and owner-verified on a FRESH install 2026-07-07: 44 MB app, instant Apple dictation, vocab-enable CTC download works, Ask/EmbeddingGemma on-demand download works. Committed at `a9c4b6c`. Build B must NOT reach the App Store until 256/257 ships and soaks ≥1 update cycle (memory: `v2-strip-release-sequencing`). Original plan (adversarially reviewed 2026-07-06) preserved below.**

Review verdict: mechanism sound; one BLOCKER (B1, silently-inert vocab for
skip-A/restore users — fixed via the launch auto-trigger below), the overnight
downloader re-scoped as net-new work (H1/H2/H3), and the iCloud-restore path
added as a first-class cohort. Everything else in the original plan verified
against code by the reviewer.

## Goal

Get the App Store download under **50 MB** by removing all three bundled ML models
from the IPA, without breaking a single existing user and without making any new
user feel the difference.

Measured on the build-255 archive (`tmp/releases/Jot-20260707T031028Z.xcarchive`):

| Component | Size | After this plan |
|---|---|---|
| `Models/Parakeet/parakeet-tdt-0.6b-v2` (English dictation, opt-in) | 443 MB | stripped — carry-forward + on-demand download (ALREADY SHIPPED in 253+, see below) |
| `Models/EmbeddingGemma` (Ask / semantic search / indexing) | 328 MB | stripped — carry-forward + **overnight discretionary download** |
| `Models/Parakeet/parakeet-ctc-110m-coreml` (vocabulary boost scorer) | 99 MB | stripped — carry-forward + **download when vocab is enabled** |
| Everything else (binary 31 MB, appexes 4.9 MB, Cmlx 3.6 MB, Watch 2.2 MB, assets/fonts ~2 MB) | **~43 MB** | unchanged (the 10 Supertonic TTS voice presets, ~2.9 MB, were removed outright on 2026-07-06 — TTS is paused/cut, owner decision) |

Post-strip `.app` ≈ 46 MB uncompressed. App Store download smaller still.

## Non-negotiable invariants

1. **No user ever loses a working feature across an update.** An existing user
   who has vocab boosting or Ask working today must have it working the minute
   the stripped build launches — that is what the carry-forward build exists for.
2. **Dictation is never touched.** Neither model is on the dictation path
   (Apple engine needs nothing; Parakeet-English v2 externalization already
   shipped its own carry-forward + download backstop in 253+).
3. **No band-aids.** Every fallback here is a designed product state
   ("downloading, here's progress"), not a silent degradation swap.
4. **No silent cellular spend.** The overnight download is Wi-Fi-only +
   system-discretionary. User-initiated downloads (vocab enable, Ask "download
   now") show progress and run on whatever network the user is on, consistent
   with the existing European-v3 consent flow.

## The two-build sequence

Mirrors the proven v2 sequence (Release T = carry-forward 253/255, Release S =
strip 254), extended to the remaining two models. Names below continue that
scheme:

- **Build A ("carry-forward-all", next build, e.g. 256)** — still bundles
  everything. Adds carry-forward copies for EmbeddingGemma + CTC into private
  storage (Application Support), plus the loader resolution-order changes and
  all download/degradation code paths (dormant while the bundle exists). This
  is the build existing users must pass through.
- **Build B ("strip-all")** — identical code, models removed from the IPA at
  build time. Ships only after Build A has soaked on the App Store.

### Why this ordering is skip-tolerant

A user who jumps straight from an old build to Build B (never installed Build A)
is simply treated as a fresh install for the affected asset: the same
download-on-demand paths cover them. Carry-forward is a **bandwidth courtesy**
for the common case, not a correctness requirement — same posture as v2's
adversarially-reviewed design (`docs/dictation-engine-rework/v2-carry-forward-migration-design.md`).

### ⚠️REVIEW — iCloud restore is a third cohort, not a variant of skip

A device restored from iCloud backup gets the SwiftData store back (it is NOT
backup-excluded) but none of the three models (they ARE backup-excluded — by
design, and correctly). Consequences the design must own explicitly:

- §D's `swiftDataStoreFileExists()` marks the restored device an **existing
  user** → a prior Parakeet user stays `useApple=false` with no v2 on disk →
  covered by the shipped §C download backstop (verified at
  TranscriptionService.swift:639–666). OK as-is.
- A restored user with vocab enabled would hit **B1** (below) — fixed by the
  launch auto-trigger.
- EmbeddingGemma absent → same as fresh install: re-enqueue the overnight
  fetch at launch (presence-checked, idempotent).

Rule: **restored device = fresh install for all three assets**; every
download trigger must be presence-checked at launch, never gated on a
"first-launch" or "already-downloaded" flag (flag-before-work antipattern).

## Build A — carry-forward-all (detailed)

### A1. Generalize the carry-forward machinery

`V2CarryForwardMigration` (Jot/App/Transcription/V2CarryForwardMigration.swift)
already implements everything hard: recursive file-count+size **signature**
verify, copy-to-temp-sibling + **atomic rename** install, abandoned-temp sweep,
**free-space preflight**, per-launch idempotent no-op re-check, **iCloud
backup exclusion** (`BackupExclusion.setExcludedFromBackupRecursively`), and
DiagnosticsLog breadcrumbs.

Refactor its §A engine into a generic `ModelCarryForward.carry(bundleLeaf:to:requiredFreeBytes:)`
helper and drive **three** assets through it (serially, `.utility`, off-main —
one launch task):

| Asset | Bundle source | Destination (MUST equal the loader/downloader dir) |
|---|---|---|
| v2 (existing, unchanged) | `TranscriptionService.bundled600mDirectory()` | `…/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2` (**no** `-coreml` — the build-142 trap) |
| CTC 110m | `<Bundle>/Models/Parakeet/parakeet-ctc-110m-coreml` | `…/FluidAudio/Models/parakeet-ctc-110m-coreml` (**with** `-coreml` — `CtcModelVariant.ctc110m.repo.folderName`, verified in FluidAudio `ModelNames.swift:65`) |
| EmbeddingGemma | `<Bundle>/Models/EmbeddingGemma` | `…/Application Support/CoreMLLLM/embeddinggemma-300m` — whatever `Gemma3BundleDownloader.localBundle(.embeddingGemma300m, under:)` resolves, so downloader and carry-forward converge on ONE directory (**V2 verification item below**). ⚠️REVIEW M2: unlike v2, this carry-forward **renames the leaf** (`EmbeddingGemma` → `embeddinggemma-300m`); the v2 "leaf name must equal the bundle dir name" invariant does NOT transfer — here the authoritative name is the DOWNLOADER's, and the copy verify must compare source-bundle signature to renamed-dest signature. |

Gating differences from v2:
- v2 copies only when `parakeetUsable` (sub-tier devices never load it). CTC and
  EmbeddingGemma copy on **every** device — vocab and Ask work on all hardware.
- Free-space preflight per asset (99 MB and 328 MB + temp ⇒ require ~250 MB and
  ~700 MB headroom respectively; v2 keeps its 900 MB). Skip-and-retry-next-launch
  semantics unchanged.

⚠️REVIEW-2 (HIGH — the one defect both prior passes missed): **the
`CoreMLLLM/` tree has ZERO backup-exclusion coverage.** The per-launch sweeps
are FluidAudio-only + RetainedAudio-only (JotApp.swift:250/:259); the
CoreML-LLM package sets `isExcludedFromBackup` nowhere. v2 + CTC land under
`FluidAudio/` (covered); EmbeddingGemma's `CoreMLLLM/embeddinggemma-300m` is a
brand-new writable 330 MB directory that would enter iCloud device backups by
default — starting at Build A (carry-forward + A2's read-from-App-Support),
not just at the strip. This exactly repeats the 1.0.2 ~2 GB-backup bug whose
fix (BackupExclusion.swift:30-35) established that install-time exclusion
alone is NOT sufficient — the per-launch recursive re-assert is load-bearing.
Must-fix, three parts:
1. New `BackupExclusion.excludeCoreMLLLM()` sweeping
   `…/Application Support/CoreMLLLM/`, called per-launch in JotApp.init
   beside the other two sweeps.
2. `setExcludedFromBackupRecursively(at:)` at install completion in BOTH the
   net-new EmbeddingModelFetcher AND the foreground-promote path (which calls
   `Gemma3BundleDownloader.download` directly — the library excludes nothing).
3. Test-plan item 6 names `CoreMLLLM/embeddinggemma-300m` explicitly.

### A2. Loader resolution order: private copy first, bundle fallback

- `EmbeddingGemmaService.bundledModelDirectory()`
  (Jot/App/Embeddings/EmbeddingGemmaService.swift:112) becomes
  `resolvedModelDirectory()`: App Support copy (signature-complete) → bundled
  dir → `nil` (= not-yet-downloaded state, NOT an error dialog). ⚠️REVIEW L2:
  callers reach it via `ensureModel()` which currently throws
  `.modelNotBundled`; the refactor must throw a benign `.notDownloaded` that
  every existing `try?` call site (AskEngine.swift:131, AskController.swift:302/687,
  SemanticSearchController.swift:89 — all already fail-soft, verified) degrades
  on, never a new fatal shape.
- `CtcModelCache.shared` (Jot/App/Vocabulary/CtcModelCache.swift:48) gets the
  same two-step root resolution. ⚠️REVIEW M1: it is a `static let` with a
  stored `root` — when the bundle is absent the snapshot MUST resolve to the
  stable App-Support download target (so a download landing later is found on
  next access), never to a dead bundle path captured at process start.
  `isCached` already delegates to `CtcModels.modelsExist(at:)` and JotApp's
  warm chain already guards on it (JotApp.swift:218) — missing-on-disk is
  ALREADY a graceful no-op there.
- Keep reading from the App-Support copy even while the bundle still exists
  (Build A) — that's the only way Build A actually proves the post-strip read
  path in the field, exactly like v2 did.

### A3. Download paths (shipped in Build A, mostly dormant until Build B)

**CTC — on vocab enable, PLUS a launch auto-trigger (⚠️REVIEW B1 — the
blocker fix).** `CtcModels.downloadAndLoad(to:variant:)` exists in FluidAudio
today (WordSpotting/CtcModels.swift:196–245; repo
`FluidInference/parakeet-ctc-110m-coreml`). Two triggers, one coalesced
download (⚠️REVIEW M4 — wrap in a single in-flight gate mirroring
`CtcLoadCoordinator` so the two can't race the same directory):

1. **Settings trigger:** if `!CtcModelCache.shared.isCached` when the user
   flips vocab ON (or opens the vocab screen with terms present), show an
   inline "Download vocabulary model (~99 MB)" progress row — same visual
   grammar as the European-language v3 download.
2. **Launch auto-trigger (the B1 fix):** at launch, if
   `VocabularyStore.shared.isEnabled && !CtcModelCache.shared.isCached`,
   start the same download unprompted. Without this, an existing vocab user
   who skips Build A (or restores from iCloud) lands on Build B with
   `isEnabled` persisted true (UserDefaults survives both), the launch
   prepare skipped (JotApp.swift:217–219), and `rescore()` silently no-oping
   forever — a working feature silently broken, which invariants #1/#3
   forbid. This user already consented to vocab boosting; re-fetching its
   model is completing their existing choice, not a new download decision.
   Wi-Fi-preferred, surfaced as the same progress row if they visit settings.

Until downloaded: vocab toggle works but boosting is inert and the row says
so honestly. Correction-review suggestions (which ride the CTC spotter) are
likewise unavailable until the download lands — acceptable for genuinely new
vocab users; the B1 auto-trigger makes the gap transient (one download) for
existing ones.

**EmbeddingGemma — system-scheduled overnight, with a foreground promote.**

⚠️REVIEW (H1/H2): the overnight component is **net-new engineering, not
reuse**. `Gemma3BundleDownloader.download` uses a foreground
`URLSessionConfiguration.default` session (Gemma3BundleDownloader.swift:393)
— only its *manifest* (`Model.embeddingGemma300m.bundleFiles`, 10 entries) and
repo constant are reusable. And no `UIApplicationDelegateAdaptor` /
`handleEventsForBackgroundURLSession` hook exists in Jot today — it must be
built. Scope honestly:

- **New `EmbeddingModelFetcher`** owning a background `URLSession`
  (`URLSessionConfiguration.background`, `isDiscretionary = true`,
  `allowsCellularAccess = false`, `sessionSendsLaunchEvents = true`) that
  downloads the 10-file manifest from HF repo
  `mlboydaisuke/embeddinggemma-300m-coreml` as individual file tasks,
  handling per-file completion across app relaunches (files land in a temp
  staging dir; a manifest checklist tracks which are done), then verifies and
  **atomically installs** (temp-sibling + rename, reusing carry-forward's
  helpers).
- **Verification in Build B cannot use the bundle signature** (there is no
  bundle to compare against — ⚠️REVIEW H2). Verify instead against a
  **byte-size manifest pinned at build time** (we know the exact bundle:
  e.g. `weight.bin` = 308,616,576 bytes) plus
  `Gemma3BundleDownloader.localBundle(…) != nil` required-file presence.
- **New app-delegate hook** (⚠️REVIEW H1):
  `UIApplicationDelegateAdaptor` in JotApp providing
  `handleEventsForBackgroundURLSession` so the system's background relaunch
  can hand us the session events and completion handler.
- **Force-quit caveat (⚠️REVIEW H3):** a user force-quitting Jot CANCELS
  discretionary background sessions, and `handleEventsForBackgroundURLSession`
  will not fire afterward. Recovery is the standing posture: every launch
  presence-checks and re-enqueues (idempotent, "no stuck flag"). Worst case
  the overnight fetch restarts across several nights; the foreground promote
  remains the guaranteed path the moment the user actually wants the feature.
- **Foreground promote:** if the user opens Ask or semantic search before the
  overnight fetch lands, cancel the discretionary session and run
  `Gemma3BundleDownloader.download(.embeddingGemma300m, into:)` (the plain
  async progress-reporting path) behind a visible "Finishing setup —
  downloading the search model (~330 MB)" state with progress. User-initiated ⇒
  any network, consistent with the v3 consent stance.
- **Considered alternative (⚠️REVIEW L3):** a `BGProcessingTask`
  (`requiresNetworkConnectivity` + `requiresExternalPower`; Info.plist already
  declares the `processing` background mode) could run the fetch in-process
  and skip the delegate-hook wiring. Rejected as primary: its runtime window
  (minutes) is not guaranteed to cover a 330 MB transfer, while a background
  URLSession transfer runs out-of-process in the system daemon and survives
  suspension by design. Keep as fallback if H1 wiring fights SwiftUI.

### A4. Degradation states while EmbeddingGemma is absent (fresh Build B installs only)

- **Dictation, keyboard, transcripts, TTS, diarization: unaffected.**
- **Semantic search** (SemanticSearchController): hybrid retrieval runs
  lexical-only; add a quiet one-line banner "Semantic search finishing setup…"
  with a Download-now affordance.
- **Ask** (AskEngine/AskController/HelpCorpus): needs a guarded entry state —
  "Ask needs a one-time model download" panel with progress once tapped
  (foreground promote above). NOT an error dialog. (Work item: audit
  AskEngine's current failure shape on missing model; today it assumes
  bundled-always-present.)
- **Indexing**: `TranscriptIndexer` skips embedding when the service isn't
  ready; `EmbeddingBackfillTask` (already exists, Jot/App/Embeddings/) catches
  up every transcript dictated during the gap once the model lands.
  ⚠️REVIEW M3 (verified): it has NO model-arrival trigger today (only
  `register`/`submitIfBacklog` + a 30 s `BGAppRefreshTask`) — **build** an
  immediate `submitIfBacklog()` kick on model-install completion, both the
  overnight and foreground-promote paths.
- **JotApp serial ANE warm chain** (JotApp.swift:206–240): each stage already
  gates on presence (`CtcModelCache.shared.isCached`; Gemma prewarm is `try?`).
  Confirm `prewarm()` cleanly no-ops (not throw-loops) when the model dir is
  absent, and that model-arrival kicks a one-shot prewarm + backfill.

### A5. What Build A does NOT change

- No SwiftData `@Model` change. **Schema impact: NONE** (UserDefaults/App-Group
  keys + file moves only).
- No keyboard-extension change (keyboard compiles only `Keyboard/` sources and
  bounces all inference to the main app — verified in project.yml:325).
- No change to Apple-engine dictation, warm-hold, recording, or the v2
  carry-forward/backstop already shipped.

## Build B — strip-all

Extend the proven 254 recipe (move-aside at build time; the repo keeps the
gitignored model dirs) from one directory to three:

```
Jot/Resources/Models/Parakeet/parakeet-tdt-0.6b-v2      → aside
Jot/Resources/Models/Parakeet/parakeet-ctc-110m-coreml  → aside
Jot/Resources/Models/EmbeddingGemma                     → aside
xcodegen && testflight.sh all && restore
```

Preferably scripted as `scripts/strip-models.sh stash|restore` so the strip is
one flag, not a hand recipe. Ship only after Build A has soaked on the App
Store ≥1 update cycle (same rule as the v2 memory:
`project_v2_strip_release_sequencing`).

Fresh Build B installs get: Apple dictation instantly (nothing to download),
~46 MB app, EmbeddingGemma overnight (or on first Ask/search use),
CTC only if/when they enable vocab, v2 only if they opt into the Jot engine
(existing shipped backstop).

## Hosting & supply-chain posture

- CTC + v2: HuggingFace `FluidInference/*` (already the shipped download path
  for v3 European + v2 backstop — no new dependency).
- EmbeddingGemma: HuggingFace `mlboydaisuke/embeddinggemma-300m-coreml`.
  **New runtime dependency on that repo staying up and unchanged.** Mitigations:
  byte-size manifest pinned at build time (see V1), and
  `Gemma3BundleDownloader.download(customRepo:…)` exists as a re-host escape
  hatch if the upstream repo ever moves — we can re-host under our own HF org
  without a code change beyond the repo string.
- Verify-before-install everywhere: a downloaded bundle is installed only
  after the same signature check carry-forward uses; a bad download is
  discarded and retried, never half-installed.

## App Review considerations

- The app is **fully functional at first launch** without any download
  (dictation, transcripts, keyboard all work) — the 4.2.3 posture is stronger
  than today's European-v3 flow, which already passed review.
- The only non-user-initiated download is discretionary + Wi-Fi-only +
  power-gated; user-initiated ones show progress and size. This matches the
  in-code consent stance documented at TranscriptionService.swift:269.

## Sequencing vs the 255 App Store submission (OWNER DECISION)

255 (v2-bundled, all UI fixes) is uploaded and was going to be the App Store
submission. Two options:

1. **RECOMMENDED — make Build A the store build.** Don't submit 255; cut 256 =
   255 + this plan's Build A and submit that instead. One soak cycle covers
   the v2 carry-forward AND the new ones; the strip release then removes all
   three at once. Saves an entire store round-trip.
2. Submit 255 now; 256 (Build A) becomes the *next* store update; strip after.
   Slower but decouples this plan from the imminent release.

## Verification items (do BEFORE implementation)

- ~~V1~~ ✅ **VERIFIED 2026-07-06 (live check).** The HF repo
  `mlboydaisuke/embeddinggemma-300m-coreml` serves `encoder.mlmodelc/weights/weight.bin`
  at exactly **308,616,576 bytes** — byte-count-identical to our bundle —
  plus `coremldata.bin` (408 B), `model_config.json` (2,351 B) and
  `hf_model/tokenizer.json` (33,385,008 B), all HTTP 200. The README's
  "588 MB fp16" note is a stale doc. Re-check sizes once more immediately
  before shipping Build B (repos can be force-pushed), but the parity gate
  is closed.
- ~~V2~~ ✅ **VERIFIED (source).** `Gemma3BundleDownloader.localBundle(_:under:)`
  resolves `<directory>/embeddinggemma-300m/` and checks required-file
  presence (Gemma3BundleDownloader.swift:410-424) — carry-forward, the
  background fetch, and `resolvedModelDirectory()` all converge on that path
  as the plan assumes.
- ~~V3~~ ✅ **VERIFIED 2026-07-07 (owner device, Build B / 258).** CTC
  downloadAndLoad end-to-end on a fresh stripped install: enabling vocabulary
  triggers the download and boosting works. The last unverified gate is closed.
- ~~V4~~ ⚠️REVIEW: re-scoped — the app-delegate adaptor does NOT exist and is
  a build item (work item 4), not a verification.
- ~~V5~~ ⚠️REVIEW: re-scoped — verified absent; the model-arrival backfill
  kick is a build item (work item 6), not a verification.

## Test plan (Build A, before it ships)

1. Fresh install → all three carry-forwards land (Diagnostics breadcrumbs),
   loaders read from App Support (log the resolved path once per launch).
2. Upgrade-from-255 sim test → same, plus vocab/Ask keep working with zero
   download.
3. Move App-Support copies aside → relaunch → carry-forward self-heals from
   bundle (the §A self-healing property, now ×3).
4. Simulated Build B (models moved aside at build time) on device:
   - vocab OFF user: no CTC download ever happens; nothing asks for it.
   - vocab ON: progress row appears, download lands, boosting works.
   - **B1 cohort**: vocab already-enabled + CTC absent + user never opens
     vocab settings → launch auto-trigger downloads it; next dictation with a
     vocab term actually boosts (assert via the correction pipeline, not just
     "file exists").
   - **iCloud-restore simulation**: store file present, all three model dirs
     absent, engine default already resolved → v2 backstop fires for a
     Parakeet user, CTC auto-trigger fires if vocab enabled, Gemma re-enqueues.
   - Ask before overnight window: foreground promote with progress; after
     install, Ask answers and backfill indexes gap transcripts.
   - Overnight path: enqueue, background-relaunch install (can be forced in
     Xcode with `_simulateLaunchForBackgroundURLSession` / dev trigger).
5. Low-disk preflight: fill disk, verify skip-and-retry logs, no partial
   installs.
6. iCloud-backup exclusion verified on all three destinations — explicitly
   including `CoreMLLLM/embeddinggemma-300m` (⚠️REVIEW-2: v2 + CTC are under
   the existing FluidAudio sweep; the CoreMLLLM tree needs the NEW sweep and
   must be spot-checked with `URLResourceValues.isExcludedFromBackup` reads
   after both a carry-forward install and a downloaded install).

## Work breakdown

| # | Work item | Size |
|---|---|---|
| 1 | Generalize `ModelCarryForward` + drive 3 assets, per-asset preflight, M2 leaf-rename verify | M |
| 2 | `EmbeddingGemmaService.resolvedModelDirectory()` + benign `.notDownloaded` throw shape (L2) | S |
| 3 | `CtcModelCache` stable two-step root (M1) + vocab-settings download row + **B1 launch auto-trigger** + M4 in-flight coalescing gate | M |
| 4 | **Net-new** `EmbeddingModelFetcher`: background discretionary session, per-file staging across relaunches, pinned byte-size manifest verify, atomic install **+ install-time backup exclusion (⚠️REVIEW-2)**, **new app-delegate adaptor + `handleEventsForBackgroundURLSession`** (H1/H2), force-quit re-enqueue (H3) | L |
| 4b | `BackupExclusion.excludeCoreMLLLM()` per-launch sweep + exclusion in the foreground-promote path (⚠️REVIEW-2) | XS |
| 5 | Foreground promote in Ask + semantic-search banner + AskEngine guarded state | M |
| 6 | Backfill (`submitIfBacklog` kick, M3) + prewarm on model-arrival, routed through the serial ANE warm chain | S |
| 7 | `scripts/strip-models.sh` + testflight dry run | S |
| 8 | features.md / ARCHITECTURE.md / Atlas updates (Ask setup state, vocab download row, "small app" story) | S |

## Build A code-review outcome (2026-07-07)

Adversarially reviewed post-implementation: **no blockers; ship-ready for the
256 device-test.** Two findings:
- **HIGH (FIXED same-day)**: the B1 launch auto-download ran on FluidAudio's
  default URLSession — cellular allowed — violating invariant #4 for an
  unprompted fetch. Now gated on a one-shot unmetered-path check
  (`JotApp.currentPathIsUnmetered()`); metered ⇒ park + retry next launch;
  the vocab-Settings row stays the user-initiated any-network path.
- **MEDIUM (OPEN — theoretical, deprioritized)**: the Ask foreground-promote
  and the overnight fetcher can race the same install dir in a narrow window
  (fresh Build B installs only; self-healing — one failed foreground attempt,
  retry succeeds). **Shipped behavior (owner-confirmed 2026-07-07):** when Ask
  has un-indexed notes and EmbeddingGemma is absent, Ask surfaces a choice —
  download the model now *with the user's permission*, or defer to the
  overnight/later fetch. That permission gate is the foreground-promote path;
  the race is between it and the discretionary fetcher, only in the sliver
  where both fire at once, and it self-heals on retry. Owner is fine leaving it
  as-is for now; preferred hardening if ever needed: a fetcher "suspend-install"
  flag set by the promote, or await the cancel before the foreground download.

## Risks

- **HF availability** (mitigated: pinned manifest, re-host escape hatch, and
  carry-forward means existing users never need the network at all).
- **Discretionary timing is not guaranteed** — a user never on Wi-Fi+charger
  could wait days (mitigated: foreground promote the moment they actually
  want Ask/search; everything else never needed it).
- **First post-download load pays ANE specialization** (~seconds, once) —
  schedule the arrival-prewarm through the existing serial warm chain so it
  never contends with dictation.
- ⚠️REVIEW-2 (coordination, both plans ship in 256): this plan AND
  speaker-notes both append stages to the serial warm-chain tail
  (JotApp.swift:206-240). Additive and idle/presence-gated — no correctness
  conflict — but whichever lands second must slot AFTER the other's stage and
  preserve the strict one-at-a-time serialization the block's comment says
  the ~60s→~16s cold-start win depends on. Final 256 tail order: Parakeet →
  vocab CTC → Gemma prewarm → warmNonSelected → diarizer Wi-Fi prefetch
  (loads a graph — ANE-relevant, stays serialized) → Gemma overnight ENQUEUE
  (out-of-process URLSession, no ANE contention, order-free).
- **255-vs-256 decision** changes nothing technical, only which build soaks.
