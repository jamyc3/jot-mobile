# Granite Speech 5.0 470M TurboCTC — evaluation for Jot (2026-08-30)

Model: `ibm-granite/granite-speech-5.0-470m-turboctc` (IBM, released 2026-08-25, Apache-2.0,
English-only, 470M params, conformer CTC, 16,384 BPE, 12.5 Hz output frames).

**Verdict: not a Parakeet replacement, even with IBM's punctuation/caps model bolted on.
One genuinely interesting result — it is measurably more robust in heavy noise, which is
Jot's one open unsolved ASR problem.**

*Updated 2026-08-30: added the full `punct_cap_seg_en` pipeline test (see "With the
punctuation + caps model" below).*

> **SUPERSEDED IN PART — see `PUNCTUATION.md`.** A blind 3-judge comparison found that the
> punctuation model actually beats Parakeet's own punctuation 31–16 on identical words, and
> that the "invents proper nouns" claim below is wrong (261 of 304 mid-sentence capitals are
> genuine proper nouns Parakeet leaves lowercase). The PCS model also quantizes to 53 MB.

## Method
- 420 real Jot recordings from `~/Desktop/jot-recordings.csv` (8–60 words, ASCII, on disk).
- Baseline = **Jot's shipped output** (Parakeet v2 + NumberNormalizer + vocabulary corrector),
  not raw Parakeet. This is the right product baseline but it is *generous to Jot* on jargon
  and formatting — a raw-Parakeet baseline would look worse.
- **Neither side is ground truth.** Word divergence is measured with the Open ASR leaderboard
  normalizer (`whisper_normalizer.english`), which lowercases, strips punctuation and
  normalizes numbers.
- Noise: replicates `../noise-robustness/` exactly (same seeds, same synthesis, same
  active-RMS SNR mixing, same "degradation vs own clean output" metric), n=36.
- Runtime: PyTorch fp32 on MPS, M2 Pro / 32 GB. Not the quantized CoreML path that would ship.

## Speed — outstanding
| clip length | latency (M2 Pro, fp32, MPS) |
|---|---|
| 5 s | 39 ms |
| 10 s | 57 ms |
| 20 s | 95 ms |

111 minutes of audio in 53 s wall = **126x realtime**. Half Parakeet 0.6B's parameter count.

## Word accuracy — parity, not a win
| metric | value |
|---|---|
| normalized divergence vs Jot's shipped output | **6.9%** |
| unnormalized | 29.4% |
| of which pure casing/punctuation/number formatting | **22.5 points** |
| clips agreeing word-for-word after normalization | 147/420 (35%) |

No long-form collapse — divergence is flat with duration (9.6% at 0–5 s, 6.4% at 10–20 s,
7.9% at 40 s+). Some of the largest "disagreements" are Jot *truncating the start of the
recording* and Granite catching it, i.e. the divergence overstates Granite's error.

## Formatting — the disqualifier for drop-in use
Raw model output, 420 clips:

| | Jot/Parakeet | Granite |
|---|---|---|
| contains any capital letter | 413/420 (98%) | **0/420 (0%)** |
| contains any punctuation | 326/420 (78%) | 15/420 (4%) |
| contractions emitted (I'm, don't) | 282 | **0** |

The tokenizer explains it: the only uppercase tokens in the 16,384-entry vocab are the 26 bare
letters — there are no cased word-pieces. It also expands every contraction ("I'm" → "i am")
and applies aggressive ITN that is often wrong for dictation: "six hundred million" →
`600000000`, "first part" → `1st part`.

IBM's own demo space ships a **separate 210 MB `punct_cap_seg_en.onnx`** to restore
punctuation/capitalization — so the real deployed size is ~660 MB (CoreML q8) + ~210 MB,
which erases the "470M" size appeal. That model was tested in full; see below.

### Two systematic ITN bugs
- **"oh" → `0`** in 4 of 5 occurrences ("Oh my god" → "0 My God").
- **Version numbers mangled** in 9 of 20 cases ("1.0.3" → "one.0.3").
Both survive the punctuation model, and both would collide with Jot's NumberNormalizer.

## Jargon — worse, and Jot's existing fix does not transfer
Of 81 ALL-CAPS acronyms in Jot's output, Granite reproduced the same letters in 81%.
Misses include `JWT`→"gwt", `ZSHRC`→"zhrc", `JSON`→"jsm", and — repeatedly — **`JOT`→"job" /
"jaw" / "j"**. Jot's vocabulary boosting fixes exactly this class, but it is a CTC rescoring
pass bound to `parakeet-ctc-110m`'s tokenizer; it would have to be rebuilt against Granite's
16,384 BPE vocab. And with zero capitalization, ALL-CAPS terms are structurally unreachable
without the extra punct/caps model.

## With the punctuation + caps model (`punct_cap_seg_en`, 210 MB)
Ported IBM's own `punctuator.js` decoder to Python verbatim (`pcs.py`) and ran it over all
420 transcripts. It costs **4 ms per transcript** on CPU — latency is a non-issue.

It fixes formatting *presence*:

| | Jot/Parakeet | Granite raw | Granite + PCS |
|---|---|---|---|
| has capitals | 98% | 0% | **100%** |
| has punctuation | 78% | 4% | **100%** |
| ALL-CAPS acronyms matched exactly | — | 0/81 (0%) | **55/81 (68%)** |
| contractions emitted | 282 | 0 | **0** |

But it does not fix formatting *fidelity*. Unnormalized divergence from Jot's output moves
only **29.4% → 27.6%**. Decomposing that remaining 27.6%:

| ignore… | divergence | attributable |
|---|---|---|
| nothing (what the user sees) | 27.6% | — |
| casing | 23.3% | **4.3 pts = casing** |
| + punctuation | 13.3% | **10.1 pts = punctuation** |
| + contractions | 9.8% | **3.5 pts = contractions** |
| — | | 9.8 pts = genuine words + ITN |

Why it stays high:
- **It punctuates ~1.9x denser than Parakeet.** 9.16 sentence-enders per 100 words vs Jot's
  4.67; 15.43 total marks vs 8.54. It sometimes chops mid-clause: *"Fantastic, can you? Also
  in the the 1st page?"* — but blind judges still preferred the denser style 2:1, so treat
  density as a style difference, not a defect.
- ~~**It invents proper nouns.**~~ **WRONG — corrected in `PUNCTUATION.md`.** Of 304
  mid-sentence capitals only 43 are function words (real errors from bad sentence breaks);
  261 are content words, mostly genuine proper nouns Parakeet leaves lowercase (Sony, Mac,
  Nemotron, Jot, Apple, Gemini, Kafka, Parakeet).
- **It cannot restore contractions.** Its label set is only `.` `,` `?` plus `<ACRONYM>` —
  there is no apostrophe. "I'm" stays "I am", "can't" stays "can not", "let's" stays "let us",
  permanently. For a dictation app this is the one that would be noticed every single time.

Net: the 210 MB buys back capitals, sentence-enders and ALL-CAPS acronyms (a real win — `JWT`,
`JSON` come back), at the cost of doubled punctuation density, invented proper nouns, and no
contractions ever.

## Noise robustness — the one real win
Degradation vs each model's own clean output (n=36, identical synthesis/metric to the July study):

| noise | SNR | Granite | Parakeet | winner |
|---|---|---|---|---|
| wind | 10 | 0.4% | 1.7% | Granite (−1.3) |
| wind | 5 | 0.8% | 2.8% | Granite (−2.0) |
| fan | 10 | 17.3% | 15.5% | Parakeet (+1.8) |
| fan | 5 | 29.8% | 34.3% | Granite (−4.5) |
| water | 10 | 23.4% | 25.8% | Granite (−2.4) |
| water | 5 | **48.4%** | **58.0%** | **Granite (−9.6)** |

The July study concluded every cheap lever (denoisers, high-pass, VAD, Whisper) was
neutral-at-best, and that the only artifact-free path was a better checkpoint. Granite is
evidence that a better checkpoint does exist — the gap widens as noise gets worse.

## Timings — available
Frame-level CTC alignment recovers per-word starts at **80 ms resolution** (12.5 Hz), with
pauses clearly visible. Both timing-dependent Jot features (pause-based paragraph
segmentation, acoustic vocabulary merge) are feasible — but need a custom decode loop, since
`generate()` returns token ids only.

## Shipping blockers
1. **FluidAudio has no Granite support** (v0.15.6, 2026-08-19, predates the model).
2. The only Swift path is `kylehowells/Granite-MLX` — 0 stars, days old, **license
   `NOASSERTION`**. Not something to take a dependency on.
3. The existing CoreML q8 conversion has a **fixed `[1, 16384, 320]` input = 327.68 s per
   invocation** — built for long-form lectures, the wrong shape for 15 s dictation. Jot would
   need its own conversion.
4. **English only.** Jot ships 19 languages, so this is at best an English-only backend —
   the same slot the Parakeet Unified English toggle already occupies.

## Reproduce
`batch2.py START END OUT` (transcribe real recordings) → `score.py` / `dur.py` / `acro.py`;
`noise_test.py` (self-contained noise matrix); `timings.py` (alignment + latency).
Punctuation: `pcs.py` (port of `punctuator.js.reference`) → `run_pcs.py` → `score2.py` /
`decomp.py` / `ex.py`. Needs `pcs/punct_cap_seg_en.onnx` + `pcs/pcs_vocab.json` from the
`ibm-granite/granite-speech-streaming-webgpu` space.
Needs: `torch transformers==5.16.1 torchaudio soundfile jiwer whisper_normalizer onnxruntime`, ffmpeg.
Raw output: `granite_all.jsonl` (420 clips), `granite_pcs.jsonl`, `noise_granite.json`.
