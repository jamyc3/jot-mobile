# Nemotron 3.5 on iPhone — the iOS model-load cache failure (BACK-BURNER)

**Status: parked 2026-07-14 (owner: back burner; likely requires contributing a fix to
FluidAudio / filing with Apple).** This doc preserves a full day of measurement so the
investigation never has to be redone. Probe apps exist and still work (see Artifacts).

## TL;DR

Nemotron 3.5 ASR (FluidInference CoreML port, latin/2240ms, 611MB) is **fast enough** on
iPhone 17 Pro — the blocker is that **iOS re-does the full ~15–20s model load on EVERY
load**, while macOS caches it to **0.17s** after the first load, and while iOS happily
caches Parakeet v2 (0.4s reload) on the same phone. It is a model-specific iOS caching
failure, not an inherent cost. Until it's fixed, Nemotron on iPhone means ~15–20s before
dictation can start whenever the model isn't already resident.

## Measured numbers (all 2026-07-14)

iPhone 17 Pro, NemotronProbe app, 58.5s real dictation clip, model cached on disk:

| Mode | Load | Wall | RTFx |
|---|---|---|---|
| Nemotron ANE (FluidAudio default) | 20.2s / 16.0s (repeat) | 5.26s | 11.1× |
| Nemotron CPU+GPU | 14.8s | 1.13s | **51.8×** |
| Nemotron All | 19.0s | 1.59s | 36.9× |
| Parakeet TDT v2 (ANE, Jot production config) | 18.0s cold, **0.4s reload** | 0.25s | **234×** |

Probe v4 added Load1/Load2 (fresh manager both times): owner confirmed **Load1 ≈ Load2
for Nemotron on iPhone** — iOS never caches it, not even within one process.

Mac (M2, fresh process per run, same latin/2240ms bundle, FluidAudio 0.15.5):

| Engine/config | Run 1 | Run 2 (fresh process) |
|---|---|---|
| Nemotron `.cpuAndNeuralEngine` | 17.4s | **0.17s** (e5rt specialization cache) |
| Parakeet v2 default | 18.3s | 0.18s |
| Nemotron `.cpuAndGPU` | 11.6s | 4.7s (Metal shader cache only; ~4.4s CPU weight-prep remains per load) |

This is why the Mac app feels instant: the ~17s specialization happened once at download
time; every later load (any process) hits the OS cache. Jot Mac additionally prewarms at
launch (`AppDelegate.prewarmTranscriber`) and uses the same `.cpuAndNeuralEngine` config
(`NemotronMultilingualStreamingTranscriber.swift:37`).

## What was ruled out

- **Per-load recompilation**: FluidAudio loads the shipped precompiled `.mlmodelc`
  directly; `MLModel.compileModel` fires only for uncompiled `.mlpackage` (not shipped).
- **ANE being unused**: ANE mode really runs on ANE (11.1× RTFx); compile cache works
  (repeat loads identical, no 100s+ first-compile).
- **Hardware**: GPU mode gives 51.8× real-time — compute is not the problem (the old
  "RTF 3–5× slower than real-time" verdict from 1.0.2 builds 22–27 is dead).
- **int4 quantization as a fix**: FluidInference's Parakeet-v3 int4 playbook (mobius
  `encoder_int4_quantization_notes.md`, FluidAudio PR #560) shows int4's speed win is
  ANE-only (GPU 4.4× slower) and load cost is dominated by specialization, not weight
  size. MLX 4-bit port (aufklarer) costs ~6pp WER + wrong runtime. Both rejected.

## Remaining suspects (untested — start here when resumed)

1. **Stateful MLState encoder** (iOS 18 path; log line "Loaded stateful encoder (MLState
   cache)") — Parakeet v2 is stateless and caches fine. Prime suspect.
2. **Cache-entry size cap on iOS** — 612MB Nemotron vs 464MB Parakeet.
3. Config-flag cache-key differences (FluidAudio default config sets
   `allowLowPrecisionAccumulationOnGPU`; per-model env overrides exist:
   `FLUIDAUDIO_ENCODER_CU` etc.).

Probe v4's per-component timing line (encoder vs decoder/joint, "(3rd+ load)") will show
whether the whole cost is the encoder — read it off the phone when resuming.

## Resume plan

1. Run probe v4 per-component breakdown → confirm encoder-only.
2. Minimal repro outside FluidAudio: load just `encoder.mlmodelc` twice with plain
   `MLModel.load` on iOS; try (a) stateless variant if FluidInference has one, (b) a
   config with/without `MLOptimizationHints`, (c) a sub-500MB chunk tier (e.g. 1120ms or
   the smallest) to test the size-cap hypothesis cheaply.
3. File with FluidAudio (they have NO published iPhone numbers; the Mac-caches/iOS-doesn't
   table is the report) and/or Apple Feedback ("same .mlmodelc specializes once on macOS
   15, re-specializes every load on iOS 26, iPhone 17 Pro").
4. If it becomes fixable: Jot integration = FluidAudio 0.14.7→0.15.5 bump (batch API
   surface unchanged, verified) + `.cpuAndGPU` or fixed-ANE config. Position: streaming
   partials + one ~664MB download for 100+ languages incl. CJK — complements, does NOT
   replace, Parakeet v2 for English (WER 3.6% vs 2.1%; Parakeet also 4.5× faster).
   Related plan: [apple-only-languages-plan.md](../dictation-engine-rework/apple-only-languages-plan.md).

## Artifacts

- iPhone probe: `~/code/nemotron-probe` (xcodegen; FluidAudio 0.15.5 exact; installs via
  `devicectl` to iPhone "Vin" `B934B07D-A9A7-52EE-8486-6A8CFD8E7DE4`). v4 = 4-mode
  segmented control, Load1/Load2, per-component timings, per-engine transcripts.
- Mac CLI probe: session scratchpad `mac-load-probe/` (top-level-await `main.swift`;
  NOTE: blocking main with a semaphore deadlocks FluidAudio's main-actor calls — that bug
  produced fake "10-minute loads" before it was fixed).
- Older Mac-side probes: `/Users/vsriram/code/jot/tools/nemotron-probe`,
  `tools/nemotron-memprobe`.
- Upstream conversion pipeline (if we ever contribute the fix or variants):
  `FluidInference/mobius` → `models/stt/nemotron-asr-streaming-multilingual-0.6b/coreml/`;
  source `.nemo` is public (`nvidia/nemotron-3.5-asr-streaming-0.6b`, OpenMDW-1.1).
