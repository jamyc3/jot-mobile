# Jot noise-robustness study (2026-07-22)

**Question:** Can we improve on-device dictation in steady background noise (running water,
exhaust fan, wind)? **Answer:** No cheap lever helps. Doing nothing is already the best of
everything tried; every audio "cleanup" is neutral-at-best and often catastrophic.

Live writeup: **https://sites.simple-host.app/vineetu/jot-noise-robustness/**
(simple-host site `jot-noise-robustness`, redeploy = PUT the tarball, see project_mockup_deploy_atlas memory.)

## Verdict on every lever
| Lever | Result |
|---|---|
| Bolt-on denoiser (RNNoise, DeepFilterNet, afftdn, anlmdn) | **Hurts.** DFN-full ~doubled WER; on a real water clip 9%→74%. |
| High-pass filter | Neutral for accuracy. |
| Newer Parakeet checkpoint (v2→v3) | No noise benefit. |
| Different model (Whisper small.en) | **Worse** than Parakeet in every noisy case; hallucinated ("waffle gun"). |
| Skip-silence / VAD gating | Neutral on synthetic (under-triggered hallucination); marginal help on real fan. **Retest on real noise.** |
| Apple Voice Processing (AGC off) | **Untested — device-only. The top remaining lever.** |
| Noise-augmented fine-tuning of Parakeet | **The only artifact-free path that actually improves. Needs offline training → ships as a better checkpoint.** |

## Key facts
- Noise severity: broadband (water > fan) is the enemy; low-freq wind ~harmless.
- Denoiser harm is monotonic with aggressiveness — no beneficial "sweet spot," only least-harmful.
- Matches peer-reviewed "When De-noising Hurts" (arXiv 2512.17562), which tested Parakeet-TDT directly.
- Real recordings (owner's fan + water) are in ~/Downloads/"1735 19th Ave 40/41.m4a".

## Reproduce
Persistent tool: `jot batch` subcommand added to `~/code/jot/tools/jot-cli` (BatchRun.swift) —
loads Parakeet once, transcribes a manifest, supports `--vad` and `--model-version v2|v3`.
Scripts here (run in order): choose_set.py → preprocess.py → add_fan.py → [transcribe via jot batch]
→ score.py; finish_denoise.py (DFN/RNNoise); whisper_run.py + compare_models.py; real_prep.py +
real_score.py. Full numbers in RESULTS.txt. site.html is the deployed page.
Needs: ffmpeg, sox, numpy, whisper-cli, DeepFilterNet `deep-filter` binary, rnnn/ models.
