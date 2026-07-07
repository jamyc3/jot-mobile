# Dictation engine rework — Apple SpeechTranscriber as default, FluidAudio as a downloadable upgrade

## THE GOAL (owner, 2026-07-05, verbatim intent — this is the north star)

> "The goal is that we have 2 transcribers, Apple and Fluid Audio. I want all the
> current features to be there. No bugs."

Concretely, DONE means all of the following are simultaneously true:

1. **Two first-class transcription engines exist as peers** — Apple's on-device
   iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` AND FluidAudio's Parakeet — for BOTH
   the live-preview (streaming) path and the stop-pass (saved-transcript) path.
   Neither engine may gate, warm, block, or depend on the other's machinery.
2. **Both engines stream properly.** FluidAudio keeps its tuned batch-overlap
   pseudo-streaming; Apple uses its NATIVE volatile/finalized streaming (not a
   re-feed-and-discard hack). This is the "don't throw away Apple's streaming" ask.
3. **Selectable by the existing Settings toggle**, exactly like today — the owner
   tests by flipping the switch. (Wider default/rollout policy is a LATER phase;
   see the deferred sections below.)
4. **Every current feature still works, with zero regressions.** With the toggle
   OFF, behavior is byte-identical to today. With it ON, everything downstream —
   vocab CTC boost + merge + provenance, paragraph/filler/number pipeline,
   warm-hold, pause/resume, the keyboard's cross-process streaming strip, the
   wizard W6 contract, Ask/voice-prompt owned-input capture, cold-model-load
   capture-first — behaves correctly.
5. **No bugs.** Every finding from the adversarial reviews (C1 fixed+verified;
   H1/H2/M1-M4 in the implementation plan) is closed and harness/device-verified
   before it reaches the owner's device.

The step-by-step path to this is **`implementation-plan.md`** (authored by the Fable
review agent, under independent Opus 4.8 review before execution). Everything below
in THIS doc (bundle removal, Apple-as-default, device floors, 10-language rollout) is
LATER-PHASE design, explicitly NOT part of the current goal — do not conflate.

---

**Status:** 🔧 CORE ENGINE ABSTRACTION BUILT 2026-07-06 (compiles clean), NOT YET
VERIFIED ON REAL AUDIO. Scope narrowed at owner's direction to just this section
(§B/§C below) — the bundle-decoupling/rollout/language-narrowing sections further
down are still just design, deliberately deferred, not the current focus.

**What's built:** a shared `StreamingSession` protocol
(`Jot/App/Transcription/StreamingSession.swift`) that both engines conform to
symmetrically — `PreviewScheduler` (FluidAudio's existing pseudo-streaming,
untouched, just given the conformance) and the new `AppleStreamingSession`
(`Jot/App/Transcription/AppleStreamingSession.swift`, a persistent
`SpeechAnalyzer`/`SpeechTranscriber` session consuming Apple's own native
`isFinal` volatile/finalized results). `TranscriptionService.makeStreamingSession`
picks between them using the exact same `useAppleEngine` toggle the stop-pass
already used (extracted into one shared property so the two paths can't
disagree), falling back to FluidAudio if Apple's session fails to construct.
`RecordingService` now talks to whichever concrete engine is active only through
the protocol — it has no idea which one is running.

**Testable today via the existing Settings → Labs → "Apple Dictation (English,
A/B test)" toggle** — flipping it now drives BOTH the stop-pass transcript AND
the live preview through Apple's engine, no new UI needed.

**UPDATE 2026-07-06 — full implementation plan EXECUTED + reviewed + harness-verified;
awaiting owner on-device verify.** The continuous `AVAudioConverter` path is no longer
unverified: the standalone harness ran the production `AppleStreamingSession` verbatim
against real recordings from `~/Desktop/jot-recordings.csv` (streaming mean WER 0.062–0.101
depending on sample, progressive updates confirmed). All 7 steps of
[implementation-plan.md](implementation-plan.md) are done and the full app builds green:
H1 teardown race (generation guard), M1 resume-no-blank, M4 tail flush + M2 queue cap,
retired the live shadow-run, the two-peer stop-pass extraction (H2 — Apple no longer gates on
FluidAudio's model load), promote-streaming-text-at-stop behind an exact coverage gate (D2 —
V7 proved streaming == one-shot WER, delta +0.000, so promoting costs zero accuracy), and
Apple asset pre-install at toggle-flip. Each of the two crux steps (5, 6) got a dedicated
Opus 4.8 adversarial review; the Step-6 review found + fixed one real HIGH bug (an interior
`feed` drop could have saved a partial note — closed with a `coverageComplete` poison flag).
Remaining before commit: simulator smoke test (FluidAudio path + flows; sim can't test Apple's
engine) then the owner's two on-device checkpoints. All work UNCOMMITTED per the standing rule.

## ⭐ DECIDED GO-FORWARD DIRECTION (owner, 2026-07-06) — this is now product, not an experiment

The A/B-test framing is retired. The decided model:

1. **Apple is the permanent DEFAULT dictation engine.** Not a toggle you find in a hidden
   Lab — the standing default. (Shipped as default-on in build 246 via
   `AppGroup.useAppleDictationForEnglish` defaulting `true`; the Settings toggle was reworded
   away from "A/B test" to a real "Apple Dictation (English)" setting.)
2. **FluidAudio/Parakeet is the higher-accuracy UPGRADE** — the owner calls it "nvidia"
   (Parakeet is NVIDIA NeMo's model). Users are **nudged** toward it (it's more accurate:
   WER 0.088 vs Apple 0.132) and can switch in Settings. The nudge surfaces come from the
   D1 decision (wizard + Settings + keyboard nudge).
3. **Existing users stay on Parakeet ("nvidia").** They already have it working — don't
   downgrade them. This is exactly what the [carry-forward migration](#-must-plan-owner-flagged-2026-07-06-carry-forward-the-already-bundled-parakeet-v2-so-stripping-the-bundle-doesnt-force-a-re-download)
   preserves. **New users get Apple by default** + the nudge to upgrade.
4. **The setup wizard gets SIMPLIFIED — Apple-first language picker (owner, 2026-07-06).**
   For new users the wizard offers **Apple for every language Apple supports** (English + the
   ~10 European overlap + the ~11 Apple-only like Chinese/Japanese/Korean/Arabic). Those pick
   → dictate immediately: Apple downloads its per-language model on demand (small), so the
   whole "downloading Parakeet…" onboarding step is DROPPED for the common case. **Edge to
   preserve:** the 13 FluidAudio-only languages (Romanian, Polish, Czech, Slovak, Slovenian,
   Croatian, Bosnian, Ukrainian, Belarusian, Bulgarian, Greek, Hungarian) have NO Apple
   coverage — picking one still requires the Parakeet download (as today). So the wizard is
   "Apple for everything Apple can do; Parakeet download only when the chosen language needs
   it (or when a user later upgrades English for accuracy)." Net: simple/instant for the vast
   majority, download shown only when genuinely required. (New feature work — not yet built;
   depends on the apple-only-languages plan for the non-English Apple locales.)

**What's built toward this so far:** Apple-default (246) + the reworded non-A/B Settings
toggle. **Still to build (next phases):** surface the engine setting discoverably (out of the
5-tap Lab), the three-surface nudge-to-Parakeet (wizard/Settings/keyboard), the wizard
simplification, and the existing-user carry-forward so upgraders keep Parakeet. The
[apple-only-languages-plan.md](apple-only-languages-plan.md) rides on top of this too.
Follows [docs/plans/apple-dictation-ab-spike.md](../plans/apple-dictation-ab-spike.md) (the
experimental A/B toggle, builds 237-244) — this doc is the "make it native" rework that spike
was scoped to lead into.

## Motivation

Today Jot bundles FluidAudio's 600M-parameter Parakeet v2 model (443 MB) inside the app binary
for English dictation. This has two costs: it inflates every install by ~450 MB regardless of
whether the user ever dictates in English, and it hard-couples English dictation to a RAM floor
(`DeviceCapability.is600MCapable`, physical memory ≥ 4.6 GB) with **no fallback tier** —
devices below that line get nothing for English dictation today. Worse: that RAM gate is not
actually enforced anywhere in the dictation path (see "Pre-existing bug" below), so those
under-served devices don't get a clean "unsupported" message — they silently attempt to load
the bundled model and likely crash.

Separately, iOS 26 introduced `SpeechAnalyzer`/`SpeechTranscriber` — Apple's own on-device,
offline transcription engine, downloaded via `AssetInventory` rather than bundled, and it runs
on any iOS 26-capable device (iPhone 11 and up) regardless of RAM tier.

**This is NOT an accuracy-driven swap.** A same-week WER benchmark on 25 real recordings showed
FluidAudio is meaningfully *more* accurate than Apple (mean WER 0.088 vs Apple 0.132, Gemini
3.1 Flash-Lite 0.112 in between) — see the spike doc's WER section. The goal here is app size
+ device coverage, not quality. Capable devices should still be able to get FluidAudio's better
accuracy; they just shouldn't have to carry its weight in every install by default.

## Decisions made (owner, 2026-07-06)

1. **Apple's engine is the soft default for every fresh install.** No download wait —
   dictation works immediately. FluidAudio becomes an opt-in, better-accuracy download, using
   the exact same on-demand download UX already built for non-English (v3) languages.
2. **Minimum iOS version becomes 26, app-wide.** One architecture, no legacy branch for
   pre-26 devices.
3. **Real Apple-engine streaming is in scope now**, not deferred. The live-preview-while-speaking
   experience should use Apple's native volatile/finalized partial results on the Apple path,
   not the FluidAudio pseudo-streaming hack.
4. **Non-English scope is narrow, not general.** Apple's `SpeechTranscriber` covers only 10 of
   Jot's 23 supported non-English languages (see table below) — those 10 get the same
   Apple-default/FluidAudio-upgrade treatment as English; the other 13 keep today's
   FluidAudio-only, download-required behavior unconditionally, forever (Apple has no coverage
   to offer there).
5. **Officially-supported device floor for dictation = iPhone 12 Pro / 6 GB RAM and up.**
   Below that (iPhone 11, 12, 12 mini, 13, 13 mini, SE 2nd/3rd gen — the 4 GB tier): dictation
   is **best-effort, not promised, but never hard-blocked**. This deliberately sidesteps the one
   real unknown below rather than gambling on it.

## The one real unknown, and why decision 5 sidesteps it

Apple does not publicly document a hardware floor for `SpeechTranscriber` specifically. But
Apple ships a *second* API, `DictationTranscriber`, explicitly as a fallback "for unsupported
languages or devices" — described as behaving like iOS 10-era on-device dictation. That's
Apple's own admission that `SpeechTranscriber` (the good, benchmarked engine) isn't guaranteed
on every iOS 26 device — and the 4 GB tier (iPhone 11/12/13-non-Pro/SE) is exactly where it's
most likely to silently degrade to the older fallback. Nobody has published where the real
cutoff sits; the only way to know for certain is an on-device asset-availability check, which
this design does not gate on. Instead: below the 6 GB / 12 Pro line, we simply don't promise
anything — whichever Apple API the OS actually uses there is accepted as best-effort, exactly
like the existing "12 Pro→14 Plus best-effort" line already documented in
`DeviceCapability.swift`. This is the same two-line support pattern Jot already uses; we're
extending it, not inventing a new shape.

## Pre-existing bug this rework happens to close

`DeviceCapability.is600MCapable` exists but **no call site actually gates dictation on it**
(confirmed by exhaustive grep — only 4 call sites: `liveTextEnabled` default, a bundled-model
integrity-check error path, secondary-warm target selection, and an idle-download-directory
helper). A real 4 GB-RAM user attempting English dictation today loads the bundled 600M model
unconditionally and is likely jetsammed. This rework fixes it as a side effect (4 GB devices
stop touching FluidAudio's model entirely), but it's worth knowing this is a live crash risk on
under-served hardware *today*, independent of anything below.

## Compatibility matrix

| Device class | RAM | iOS 26? | Dictation tier | Engine |
|---|---|---|---|---|
| iPhone XR/XS/XS Max and older | — | ❌ not supported by iOS 26 | N/A | N/A (app requires iOS 26) |
| iPhone 11, 11 Pro/Max, SE 2nd gen | 3-4 GB | ✅ | Best-effort, unsupported | Apple only (SpeechTranscriber or OS-chosen DictationTranscriber fallback) |
| iPhone 12, 12 mini, 13, 13 mini, SE 3rd gen | 4 GB | ✅ | Best-effort, unsupported | Apple only |
| **iPhone 12 Pro, 13 Pro, 14, 14 Plus** | **6 GB** | ✅ | **Officially supported (floor)** | Apple default; FluidAudio downloadable upgrade |
| iPhone 14 Pro/Max, 15, 15 Plus | 6-8 GB | ✅ | Officially supported | Apple default; FluidAudio downloadable upgrade |
| iPhone 15 Pro/Max, 16 line, 17 line | 8 GB+ | ✅ | Officially supported | Apple default; FluidAudio downloadable upgrade |

## Language coverage — Apple `SpeechTranscriber`'s 42 locales vs Jot's 23 non-English languages

**Covered (10 of 23) — eligible for the same Apple-default/FluidAudio-upgrade treatment:**
Spanish, French, German, Italian, Portuguese (Brazil variant only — Apple has no `pt_PT`),
Russian, Danish, Dutch, Finnish, Swedish.

**Not covered (13 of 23) — FluidAudio-only, download required, unconditionally, no change:**
Romanian, Polish, Czech, Slovak, Slovenian, Croatian, Bosnian, Ukrainian, Belarusian,
Bulgarian, Serbian, Greek, Hungarian.

## Architecture

### A. Model lifecycle — decouple the bundled English model

- Remove `Jot/Resources/Models/Parakeet/parakeet-tdt-0.6b-v2/` (443 MB) from the app bundle.
- English becomes just another `LanguageChoice` from a download-management perspective — reuse
  `AsrModels.download(to:force:version:progressHandler:)` / `AsrModels.modelsExist(at:version:)`
  and the wizard/Settings download-progress UI already built for the 23 non-English languages.
  This is the single biggest implementation-simplifying fact from the research: the
  download infrastructure already exists and is already engine-agnostic — this is removing a
  special case (the English bundle branch in `TranscriptionService.modelDirectory()` /
  `bundled600mDirectory()`), not building new plumbing.
- The English-specific integrity-check error path (`TranscriptionService.swift:636-643`, "model
  missing from bundle, reinstall Jot") goes away entirely — a missing English model just means
  "not downloaded yet," same as any other language today.

### B. Engine selection

For a given `LanguageChoice`:

- **FluidAudio not downloaded + language has Apple coverage** (English + the 10 above) → Apple
  engine (`SpeechTranscriber`, with `DictationTranscriber` as the OS's own fallback on
  unsupported devices — Jot doesn't choose between them, it just calls `SpeechTranscriber` and
  accepts whatever the framework does).
- **FluidAudio not downloaded + no Apple coverage** (the 13 languages) → same as today: prompt
  for/require the FluidAudio download, no alternative exists.
- **FluidAudio downloaded** → use it (best accuracy), regardless of Apple coverage.
- **Below the 6 GB / 12 Pro floor** → Apple only, always, best-effort. Never attempt to
  download or load FluidAudio (can't run it anyway — this is just finally enforcing the intent
  `is600MCapable` was always supposed to have).

Settings gains an explicit **"Download [language]'s more accurate model"** affordance per
Apple-covered language — the upgrade path — replacing today's hidden Labs A/B toggle. The
A/B-test toggle's job (routing to Apple vs FluidAudio) becomes the real default behavior, not
an experiment.

**Open question:** retire or repurpose `LiveEngineComparisonStore`'s always-on shadow-run
(double-transcribing every real dictation to gather comparison data)? That was built for
gathering A/B evidence during the spike; running it forever in production doubles compute for
every default-Apple user with no ongoing purpose once the direction is decided. Recommend
retiring the shadow-run, keeping `EngineABTestLabView`'s batch-retranscribe-and-compare as an
internal diagnostic tool (renamed out of "Labs"), for future spot-checks.

### C. Streaming / live preview

- Build a real Apple streaming integration for devices on the Apple path: one persistent
  `SpeechAnalyzer`/`SpeechTranscriber` session held for the life of the recording, fed the same
  live audio buffers RecordingService already produces, consuming Apple's own
  volatile/finalized partial results directly. This retires the need for the
  re-feed-and-discard pseudo-streaming hack **for Apple-engine devices specifically**.
- Devices that have downloaded FluidAudio keep today's batch-overlap-window pseudo-streaming
  (`docs/plans/batch-only-streaming.md`) unchanged — that mechanism is orthogonal to this
  rework and still the only way to get a cheap partial out of FluidAudio's 600M model.
- `TranscriptionService.previewTranscribe` needs an engine branch:
  `useAppleEngine ? previewViaAppleStreaming(...) : previewViaFluidAudioPseudoStreaming(...)`.
  This is genuinely new work — Apple's API shape (feed-once/finalize-once for the stop-pass) is
  different from a long-lived streaming session, so the persistent-session variant is a new
  code path, not a reuse of `AppleDictationEngine.swift`'s existing one-shot transcribe.

### D. Retained audio / format — no change for now

The A/B spike's open question (dual-write retained audio at capture — Float32 for FluidAudio +
Int16 for Apple — vs today's convert-at-read) is revisited here since Apple is now a permanent
path, not a togglable experiment. Recommendation: **keep convert-at-read.** `RecordingService`'s
capture path is high-blast-radius (every dictation, every user), and the conversion step is
cheap relative to transcription itself. Revisit only if the on-the-fly `AVAudioConverter` step
becomes a measured cost once most users are actually on the Apple path day-to-day.

### E. Vocabulary boost / CTC — no change

Confirmed already (owner-verified on-device during the spike): the CTC vocabulary-boost and
gate mechanism consumes raw audio + transcript only and is engine-agnostic. Nothing here needs
to change; this rework doesn't touch `Jot/App/Vocabulary/`.

## Rollout / migration

### ⭐ MUST-PLAN (owner-flagged 2026-07-06): carry-forward the already-bundled Parakeet v2 so stripping the bundle doesn't force a re-download

**The problem the owner raised:** today every install ships the 443 MB Parakeet v2 model
INSIDE the app binary. The moment we release a version that STOPS bundling it, an existing
user who updates would find the model gone from the app bundle — and under the naive plan
they'd have to re-download ~450 MB just to keep the English dictation they already had
working. That's a bad update experience and must not happen.

**The owner's proposed approach (record it — this is the plan to flesh out):** ship a
**transitional "carry-forward" release FIRST**, BEFORE the strip. That release still bundles
the model, but on launch it COPIES the bundled model out of the read-only app bundle into a
writable, update-surviving location (the App Group container, or Application Support — wherever
the download-on-demand path already looks for models). Then the SUBSEQUENT release strips the
bundle: on that update, the model is already sitting on disk in the writable location, the
normal "is the model already downloaded?" check (disk-presence, per
`modelsExistOnDiskForSelectedVariant()`) passes, and dictation keeps working seamlessly with
zero re-download. New installs of the stripped version get Apple by default (+ optional
FluidAudio download); upgraders who had the bundle carried-forward keep FluidAudio for free.

**Open sub-questions to resolve when this is planned (NOT this cycle):**
- WHERE exactly to copy it — must be the same directory the download-on-demand loader treats as
  "already downloaded," and must be backup-excluded (the retained-audio store already sets that
  precedent) so it doesn't bloat iCloud backups.
- Is the copy a one-time migration (flag-after-success, per the standing flag-before-work
  antipattern rule) or an idempotent every-launch presence check (cheaper reasoning, no stuck
  flag)? Lean idempotent-presence-check.
- Sequencing/timing: how many release cycles does the carry-forward version need to be in the
  field before the strip is safe (i.e. what fraction of users must have launched the transitional
  build)? A user who skips the transitional version and jumps straight from an old bundled build
  to the stripped build would still face the re-download — quantify that tail and decide whether
  to (a) accept it, or (b) also keep a "download if missing" fallback in the stripped build so
  the worst case is graceful, not broken.
- Interaction with the min-iOS-26 bump: both land in the same rollout; make sure the carry-forward
  copy runs on the transitional build which may still support pre-26, before the floor rises.

This whole item is DEFERRED (rollout phase, not the current toggle cycle) but is a hard
prerequisite for the app-size win — the strip cannot ship safely without it.

### Other rollout notes

- Bump the min-iOS-version build setting to 26 — the App Store enforces the floor; no in-app
  migration needed for users stuck below it (they simply stop receiving updates).
- Users currently on the bundled 600M model: with the carry-forward migration above, existing
  users KEEP FluidAudio (no re-download, no accuracy change). WITHOUT it, everyone would drop to
  Apple-by-default and need an explicit re-download to regain today's accuracy — **a real,
  user-visible regression that the carry-forward plan exists specifically to prevent.** Either
  way, a one-time in-app note / release-note callout about the new Apple-default + upgrade path
  is warranted — not something to ship silently.
- First-run wizard: no English-specific download step needed by default (Apple engine is ready
  instantly, matching decision 1). The language step's existing download UI is reused
  unchanged for (a) the opt-in FluidAudio upgrade on Apple-covered languages and (b) the
  mandatory download on the 13 Apple-uncovered languages, exactly as today.

## Open questions for review

1. Retire or repurpose the always-on live shadow-run comparison (`LiveEngineComparisonStore`) —
   see §B above.
2. Does the existing-user accuracy-change deserve a one-time in-app message, and if so what
   does it say (framed as "faster, on-device by default; download for even higher accuracy," not
   "we made your dictation worse")?
3. Should the FluidAudio upgrade affordance be a proactive one-time offer (e.g., after N
   dictations) or purely Settings-discoverable? Leaning discoverable-only to avoid nagging, but
   worth a product call.
4. Once a build exists: confirm whether it's possible to detect at runtime which Apple API
   actually ran (`SpeechTranscriber` vs `DictationTranscriber`) so Diagnostics can log it — useful
   for understanding real-world quality on the best-effort (sub-12-Pro) tier without guessing.
5. Not addressed here, deliberately deferred: whether/how to also close the pre-existing
   unenforced-`is600MCapable` bug as an *independent*, smaller, shippable-sooner fix ahead of
   this larger rework, since it's a live crash risk today. Worth a quick owner call on
   sequencing.

## Sizing

**XL.** Touches model lifecycle/download plumbing, engine-selection logic, a new Apple
streaming subsystem, wizard/Settings UI, and a real user-facing migration for existing English
dictation users. Needs full brainstorm→design-review→implement-with-subagents treatment before
any code — this doc is the design-review input, not yet reviewed.

## Cross-links

- [docs/plans/apple-dictation-ab-spike.md](../plans/apple-dictation-ab-spike.md) — the
  experimental precursor (bug history, WER benchmark, direction-decided section).
- [docs/plans/batch-only-streaming.md](../plans/batch-only-streaming.md) — FluidAudio's
  pseudo-streaming mechanism, which stays as-is for FluidAudio-upgraded devices.
- `Jot/Shared/DeviceCapability.swift` — today's single-bool RAM gate this rework extends into a
  real enforced two-tier (officially-supported vs best-effort) policy.
