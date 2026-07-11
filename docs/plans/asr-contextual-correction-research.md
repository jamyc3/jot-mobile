# Research: contextual, vocabulary-free ASR post-correction ("does each word fit here?")

**Status: RESEARCH ONLY (2026-07-11), not scoped/built.** Owner asked whether we can catch the few words that come out wrong on long dictations — acoustically-plausible substitutions (accent/homophone-driven) that don't fit the sentence — WITHOUT relying on user vocabulary lists. This surveys open-source, on-device-feasible options.

## The field: Generative Error Correction (GER / GenSEC)
The owner's mental model ("go phrase-by-phrase, does each word fit, fix the misfits") **is** Generative Error Correction — a non-intrusive post-ASR refinement where a language model regenerates the wrong words from context. Adjacent terms: LLM-based ASR correction, n-best/lattice rescoring, phonetic/confusion-based correction. NOT the same as **contextual biasing** (= vocabulary lists, rejected) or **grammatical error correction / GECToR** (targets grammar, misses acoustic misrecognitions — a trap: looks relevant, isn't).

## Recommendation for on-device Jot
**Reuse the LLM already on the phone — do NOT add a model, do NOT use vocabulary.** Wrap it in a **confidence-gated, phonetically-constrained, verification-checked** GER pass over 1-best text + FluidAudio's per-word confidences:

1. **Gate first.** Use FluidAudio per-word confidence to flag low-confidence spans. If none are shaky → **skip the LLM entirely** (most long transcripts need no correction; skipping saves latency AND avoids over-correction).
2. **Correct with an existing model.** Default: **Apple Foundation Models (~3B, on-device)** — free, guaranteed present, already used for cleanup. Alt: **Qwen 3.5 (MLX)** — more capable but 4B is thermally risky on sustained iPhone load; prefer the 2–3B tier.
3. **Constrain to prevent hallucination** (the central risk): pre-detect suspect words → correct ONLY those (chain-of-thought) → verify meaning preserved (RLLM-CF recipe). Add a **phonetic-faithfulness** rule (a replacement must plausibly *sound like* what was said). Prefer minimal-edit/diff output, not a full rewrite.
4. **Don't reuse** EmbeddingGemma (retrieval-only, no generation) or the CTC vocab rescorer (vocabulary-driven — the rejected approach). Reuse the **rewrite LLM / Apple FM**.

## Key technical realities
- **n-best beats 1-best**, but Parakeet-TDT runs **greedy → 1-best only** in FluidAudio. FluidAudio *does* expose per-word **confidence + timestamps + token IDs**, so design around **1-best + confidence**. True n-best would need beam search (cheaper on the bundled CTC model than on TDT) — a future upgrade.
- **Confidence is a weak gate** — correct/incorrect distributions overlap; use it to prioritize, not as a hard filter.

## The dominant risk: over-correction
An LLM can make a **99%-correct transcript worse** by "fixing" correct words — and Apple's research shows this is *worst exactly in the low-error regime Jot lives in*. Confidence gating + phonetic constraint + minimal-edit + verification are **mandatory**, not optional. Evaluation is hard: WER is too blunt; need error-slot accuracy + a **no-regression check** that correct words survive, on Jot's own recordings.

## Phase-2 higher ceiling (R&D, no open weights)
Apple's **specialized compact corrector**: a tiny (tens-of-M-param) seq2seq trained on synthetic ASR-error pairs (TTS→ASR cascade), rescored with acoustic scores. Beats LLMs precisely in the "almost right" regime, ANE-tiny, never touches correct words — but it's a build+train, not a download. Consider only if prompt-based GER proves insufficient.

## Empirical test 2026-07-11 — naive GER prompt on Apple Foundation Models (on Mac, macOS 26)
Built a Swift CLI (`FoundationModels`, `LanguageModelSession`) and ran a phonetically-constrained, minimal-edit GER **free-text prompt** over 12 real Jot transcripts (from `~/Desktop/jot-recordings.csv`) + 3 synthetic clear-error cases.

**Result: the naive whole-transcript prompt FAILS on real data — it must NOT ship as-is.**
- ✅ Synthetic clear errors: 2/3 fixed ("by"→"buy", "excepted"→"accepted"; **missed** "root"→"route").
- ❌ Real Jot transcripts: the base model gets seduced by conversational content and **responds to / refuses / rewrites** it instead of correcting, despite explicit "treat as data, output only corrected text" instructions. Examples: answered "what does turning off streaming mean" with a paragraph; wrote a 300-word Kafka essay; **refused** an HP-cartridge line as "piracy"; leaked the prompt and printed the correction *steps*; wrapped text in a code block.
- Hard constraints found: **~4096-token context limit** (a long transcript errored out — long dictation is the target use case!); latency up to ~10s when it derails.

**Conclusion:** this is exactly the research's #1 over-correction risk, in the extreme. Apple FM *can* fix isolated acoustic mix-ups but cannot be pointed at a whole transcript with a free-text "fix it" prompt. To be usable it needs: (1) **guided/structured output** (`@Generable` → force a list of {wrong→replacement} edits so the model literally can't answer the question), (2) **confidence-gated span-level** correction (send only flagged low-confidence words + minimal context, never the whole question), or (3) a **purpose-trained tiny corrector** (Apple's specialized-model approach). Harness kept in the session scratchpad (`ger-test` SPM package). Next experiment to run: the `@Generable` edit-list variant.

## Key sources
- Apple, *Revisiting ASR Error Correction with Specialized Models* — https://machinelearning.apple.com/research/asr-error-correction
- *ASR Error Correction using LLMs (n-best + constrained decoding)* — https://arxiv.org/html/2409.09554v2
- *Whispering-LLaMA* (open cross-modal GER) — https://github.com/Srijith-rkr/Whispering-LLaMA
- *RLLM-CF: fewer hallucinations, verification* — https://arxiv.org/abs/2505.24347
- *GER for rare words with phonetic context* — https://arxiv.org/pdf/2505.17410
- *Confidence-guided error correction* — https://arxiv.org/pdf/2509.25048
- *Non-Intrusive ASR Refinement: A Survey* — https://arxiv.org/pdf/2508.07285
- FluidAudio (confidence/timestamps) — https://github.com/FluidInference/FluidAudio
