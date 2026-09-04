# Punctuation bake-off — Parakeet vs Nemotron vs the PCS model (2026-08-30)

Follow-up to `RESULTS.md`. Question from the owner: *"I don't think Parakeet does punctuation
really well… which one is doing better punctuation, just Nemotron or just Parakeet or Parakeet
plus the punctuation model?"*

**Headline: the owner was right. On identical words, the 210 MB punctuation model beats
Parakeet's own punctuation 31–16 in blind judging, and it quantizes to 53 MB.**

## Systems compared (420 real Jot recordings)
| variant | what it is |
|---|---|
| `parakeet` | Jot's shipped output (Parakeet v2 + NumberNormalizer + vocab corrector) |
| `parakeet_pcs` | Parakeet's words, stripped of case/punctuation, re-punctuated by PCS |
| `nemotron_en` | `nvidia/nemotron-speech-streaming-en-0.6b` via transformers |
| `nemotron_multi` | `nvidia/nemotron-3.5-asr-streaming-0.6b` (multilingual) |
| `granite_pcs` | Granite TurboCTC + PCS |
| `*_pcs_ontop` | PCS applied to text that is ALREADY punctuated |

## Formatting density
| variant | caps | punct | contractions | sent/100w | marks/100w |
|---|---|---|---|---|---|
| parakeet | 98% | 78% | 282 | 4.67 | 8.54 |
| parakeet_pcs | 100% | 100% | 282 | 8.96 | 15.87 |
| nemotron_en | 100% | 83% | 274 | 4.59 | 6.76 |
| granite_pcs | 100% | 100% | 0 | 9.16 | 15.43 |
| nemotron_en_pcs_ontop | 100% | 100% | 274 | **14.45** | **27.10** |

## Blind LLM judging (3 independent judges: Haiku, Sonnet, Fable)
50 clips, variants shuffled per clip, judges told to score **formatting only** and ignore word
accuracy. Files: `judge_A.txt`, `judge_B.txt` (+ `.key`), verdicts in `judge_*_*.json`.

**Task A — identical words, only punctuation differs (Parakeet vs Parakeet+PCS):**

| judge | parakeet | parakeet+PCS | tie |
|---|---|---|---|
| Fable | 16 | **32** | 2 |
| Haiku | 12 | **37** | 1 |
| Sonnet | 16 | **32** | 2 |
| **majority** | 16 | **31** | 3 |

All three judges independently preferred PCS by roughly 2:1. This overturns the `RESULTS.md`
claim that PCS "over-punctuates" — it *is* about 1.9x denser than Parakeet, but denser is
apparently closer to what a reader wants.

Pooled: **parakeet_pcs 101, parakeet 44** (n=145 non-tie), z = +4.7, **p = 1.2e-06**.
All three judges picked the *same* variant on **35/47 clips (74%**, chance = 25%).

**Task B — whole-output formatting (Parakeet vs Nemotron-EN vs Granite+PCS):**

| judge | parakeet | nemotron_en | granite+PCS |
|---|---|---|---|
| Fable | 14 | 10 | **26** |
| Haiku | 15 | 15 | **20** |
| Sonnet | 14 | 13 | **23** |
| **majority** | 13 | 11 | **24** |

Pooled: **granite_pcs 69, parakeet 43, nemotron_en 38** (n=150), z = +3.3, **p = 0.00086**.
Unanimous on **31/50 clips (62%**, chance = 11%).

Nemotron-EN is **not** better than Parakeet at punctuation — it is slightly worse, and it is
the sparsest punctuator of the three (6.76 marks/100w).

## Correction to RESULTS.md: the "invented proper nouns" claim was wrong
`RESULTS.md` counted 229 mid-sentence capitals from PCS vs Jot's 128 and called them invented.
Breaking them down: of 304 mid-sentence capitals, only **43 are function words** (the real
error — a wrong sentence break producing "Can", "If", "What"). The other **261 are content
words**, and the frequent ones are genuinely proper: Sony, Mac, Nemotron, Jot, Apple, Gemini,
Kafka, Parakeet, Delta, Playground. Parakeet leaves most of these lowercase. PCS capitalising
them is a *fix*, not an invention. (It still gets "Github"→GitHub and "Json"→JSON wrong.)

## Do NOT run PCS on already-punctuated text
It doubles the marks — the existing punctuation is tokenized as text and PCS adds its own:

```
BEFORE : What is the last line you read there? I'm just asking so that we are sure…
AFTER  : What is the last line you read there?? I'm just asking … at the same log. File..
BEFORE : Now when I go inside the app, the copy button is not working there.
AFTER  : Now, when I go inside the app,, the copy button is not working there. .
```
Density goes 6.76 → 27.10 marks/100w. **Always strip case+punctuation first, then re-punctuate.**

## Nemotron 3.5 multilingual transliterates English into Devanagari
On **45 of 420 clips (10.7%)** the multilingual checkpoint rendered English speech in Hindi
script (one clip in Cyrillic) — a language-ID failure on the owner's accent:

```
PARAKEET: It has been more than thirty minutes and nothing has happened…
NEMOTRON: दैट्स वेन मोर थान थर्टी मिनट्स एंड नोथिंग हाज़ हैप्पेन्ड…
```
The English-only checkpoint (`nemotron-speech-streaming-en-0.6b`) does not do this. If Nemotron
is ever revisited for Jot, **use the English checkpoint for English**, and treat auto-language-ID
on accented English as a live risk. Ids in `nemo_script_fail.json`.

## Task C — the add-on applied to ALL THREE engines (the real product question)
Same 50 clips, labels reshuffled per clip, three judges. Every engine's output was stripped of
case/punctuation and re-punctuated by the SAME add-on model:

| add-on applied to | pooled judge picks (n=150) |
|---|---|
| **Parakeet (what Jot ships)** | **79** |
| Granite | 44 |
| Nemotron | 27 |

z = +5.0 vs chance; all three judges independently ranked Parakeet first. **The add-on is worth
having; Granite is not.** Granite was only ever how the add-on was found.

Number rendering after each engine passes through Jot's `NumberNormalizer`:

| engine | % numbers as digits | unrecoverable giant numbers |
|---|---|---|
| Parakeet | 71% | 0 |
| Nemotron | 67% | 0 |
| Granite | 72% | **6 clips** |

Parakeet and Nemotron hand Jot spelled-out words and let `NumberNormalizer` decide. Granite does
its own ITN first, so when it is wrong the damage is already digits and Jot cannot repair it
("300 million" → `300000000`). Granite is the only engine that can produce a number Jot's
normalizer cannot rescue.

## TWO BUGS FOUND IN THE HARNESS — both fixed, both matter for the Swift port

**1. `<unk>` leaked into user-visible text (19/420 clips, 4.5%).** IBM's `punctuator.js` decodes
each token by looking its id back up in the vocab. An out-of-vocabulary character resolves to
UNK, so the literal string `"<unk>"` is emitted into the output — and the per-character
capitaliser may upper-case it: `"the front<Unk>end design skill"` for "front-end". The fix
(`pcs.py`) is to remember the SOURCE text each token consumed and emit that instead of the vocab
string. **Any Swift port must do this too — the reference implementation is wrong.**

**2. The strip step destroyed digit-internal separators (17/420).** `5,000` → `5 000`,
`3.1` → `3 1`, `10.30` → `10 30`. The add-on then re-punctuated the fragments as prose. Fixed in
`strip.py` by protecting `(?<=[0-9])[.,](?=[0-9])` across the strip. After both fixes: 0/420
`<unk>`, 1/420 separator loss.

Note that **Parakeet+add-on won Task C while carrying both bugs**, so its margin is understated.

Still open: letter-internal periods (`10 a.m.` → `10 a M.`) need the same protection.

## The shippable finding: PCS quantizes to 53 MB
`onnxruntime.quantization.quantize_dynamic(QInt8)`: **210 MB → 53 MB**, latency **4 ms → 1.9 ms**
per transcript on CPU. Output is byte-identical to fp32 on 302/420 (72%); the differences seen
are cosmetic (one comma, one capital, one sentence split), not degradation — *this still needs a
blind judge pass to confirm int8 is not worse.*

A ready-made CoreML build also exists — `soloish90/punct-cap-seg-en-coreml-int8` (Apache-2.0):
an already-compiled `.mlmodelc` (the same form Jot loads Parakeet from), INT8, ~60 MB, ~6 ms per
256-token window on Apple Silicon, built for a dictation app doing exactly this. Fixed input
`[1, 256]`, so long dictations need windowing. That removes the ONNX-runtime dependency and the
conversion work entirely.

**Integration note.** Jot's post-processing chokepoint is one line —
`TranscriptionService.swift:1306`, `NumberNormalizer.normalize(FillerWordCleaner.clean(text))`.
But `JotKeyboard` links only `JotVocabCore`, NOT `JotTextPipeline`, so the keyboard does not run
that chain at all today. Main-app-only is a one-line change; covering the keyboard means wiring
the pipeline into a memory-constrained app extension AND loading a 60 MB model there.

That makes "Parakeet + PCS" a ~53-60 MB, ~2-6 ms add-on that blind judges prefer 2:1 over Parakeet's
own punctuation — **and it is completely independent of Granite.** It would also work on the
Mac app, which shares the same pipeline.

### Validity checks
- **Labels were shuffled per clip**, so a judge could not "vote for system A" across the set.
  Pooled letter picks were skewed to the first slot (A=89 vs B=56 in Task A) while the pooled
  *variant* picks ran the other way — position preference and variant preference are decoupled,
  so the effect is content-driven. Any residual letter bias adds noise, which *understates* the
  effect rather than manufacturing it.
- **The judges' prose descriptions are INVALID and must not be quoted.** Each judge wrote up
  "System A does X, System B does Y" assuming stable labels; because labels were reshuffled
  every clip, those narratives describe a different mixture on each line. Only the per-clip
  verdicts, mapped back through `judge_*.txt.key`, are meaningful. Run `stats.py`, not the
  prose.
- One judge independently flagged clip 28 as "byte-identical text" — Parakeet and Parakeet+PCS
  genuinely agree there, a good sanity signal that the harness is wired correctly.

### Caveats
- Judges are LLMs, not the owner. They agreed strongly (74% unanimous), but they share a house
  style, and 3 judges from one vendor is not an independent panel.
- PCS restores `.` `,` `?` only — no apostrophes. It never *removes* Parakeet's contractions
  (they survive the strip), but it cannot create them, so it can only be bolted onto a source
  that already emits them.
- 50 clips per task.

## Reproduce
`nemo_batch.py` / `nemoen_batch.py` → `variants2.py` → `vstats2.py`; `mkjudge.py` builds the
blind files, `agg.py` aggregates verdicts.
