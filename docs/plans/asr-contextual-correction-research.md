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

## Detailed multi-agent deep-dive (2026-07-11) — 6 parallel research agents + Codex design pass

**Headline convergent finding: do NOT silently auto-correct with a whole-transcript LLM.** Every angle independently confirms it. The evidence-backed direction is **interactive assist + learn-from-corrections biasing**, and — *if* automatic correction is still wanted — a heavily-gated, structured, span-level pipeline, never a free-text "fix this" prompt.

### 1. Guided/structured output fixes the *derailment* (not the accuracy)
Apple FoundationModels **`@Generable` with an edit-list root** (`[{originalWord, replacement, charOffset}]`) uses constrained decoding to *mask out every non-schema token* — so the model physically cannot emit a free-text answer to the dictated question (the failure we saw). Make the root an ARRAY of edits (not a `String`, which reopens the loophole); cap edit count (`@Guide(.count(0...N))`); put a reasoning field before the edits; emit an empty list when clean. Caveat: a "constraint tax" hits small (<3B) models 10–30% on reasoning, though word-correction is extraction-like (milder). Structured output solves format/derailment (~100%), NOT correction accuracy. Cross-platform alt if ever off Apple's model: **llama.cpp GBNF** or **XGrammar** (both run on iOS); Outlines/guidance/lm-format-enforcer are Python-only.

### 2. Confidence is a WEAK detector → intersect two weak signals
Rigorous 2025 benchmark: ASR confidence gives **precision 0.41–0.55, recall 0.36–0.64**; no threshold transfers; models are overconfident (correct/wrong distributions overlap). So confidence can *select a span to examine*, never *decide the fix*. Safe pipeline = **confidence-gate (precision-tuned, low recall) → phonetic candidate generation (sound-alikes only) → small-LM pick, biased to no-change.** A word changes only if it's low-confidence AND has a phonetically-near, contextually-better alternative. Entropy-over-posteriors beats top-1 confidence 2–4× (needs full distribution — CTC exposes it, TDT doesn't). Native Swift: **DoubleMetaphoneSwift**, **MisakiSwift** (G2P), **CMUdict**; `panphon` feature-distance would need a small hand-port. Homophones (confident-but-wrong) can't be caught by confidence gating — need an independent phonetic/context check.

### 3. Signal reality from Jot's ASR (decisive)
**TDT (Jot's transcription path): NO n-best** — argmax is baked into the CoreML joint export (`token_id`/`token_prob`/`duration` scalars only); TDT beam is costly at batch=1 and has a ~20% hallucination bug upstream. **Do not pursue TDT beam.** **CTC (bundled `parakeet-ctc-110m`): n-best cheaply, already wired** — FluidAudio's `VocabularyRescorer` runs CTC log-probs in-process; PR #527 exposes `CTCReplacement` scores and ships a **0.85 TDT-confidence gate** to prevent over-correction (a shipped confidence-guarded-correction example). **Available to Jot today: per-token `confidence` + `startTime/endTime` + `tokenId`** via `tokenTimings`. Build confidence-gating on those first; add CTC-constrained n-best rescore only on flagged spans.

### 4. Purpose-trained tiny corrector = best quality, heavy R&D
Apple's ECLM (arXiv 2405.15216): 69–484M char-vocab encoder-decoder, **ZERO hallucinations** vs LLMs' 3–12%, beats every LLM baseline in the low-error regime, correction-first decoding + **acoustic-score rescoring** (needs ASR log-probs). But: ~12,800 GPU-hrs data synthesis, no open weights. **Non-autoregressive edit models** (FastCorrect) are harder-to-hallucinate AND most ANE-friendly (static shapes). Pragmatic middle path: **fine-tune BART-base (140M) on real+synthetic Parakeet error pairs** (TTS→ASR cascade + Jot's own ~2,900-recording CSV as authentic seed) — a ~1–2 week spike that de-risks the full build. Safety metric to train against: **hallucination rate on already-correct inputs** (target ~0).

### 5. Evaluation — gate on False-Correction, not WER
WER is symmetric and will *hide* the exact failure (fix 2, break 2 = net-zero WER, worse trust). Use **Correction Precision**, **No-Regression / Preservation Rate**, and **False-Correction Rate (FCR)** as the SHIP GATE (precision before recall). Build the test set from Jot's own recordings CSV: sample near-clean long-form, get ground truth via a stronger reference model (server Whisper/Parakeet) + human-verify only the diffs, and keep a **"correct-text stress slice"** (already-correct transcripts) where the only acceptable behavior is near-zero edits. Ship gate: corrected judged *worse* in <1% of documents.

### 6. Who ships what + the strong reframe (agent 6)
No one ships silent on-device misrecognition-fixing over near-correct long-form text. Precedents: Google **Gboard Proofread** = one-tap *user-confirmed* suggestion (metric = "bad ratio", prioritized over recall); Apple = fix it in the *model*; **Wispr Flow** (cloud) auto-rewrites and is *known to over-edit* — the exact failure to avoid. Latency/thermal: a 3–4B LLM on iPhone runs on GPU (not ANE), throttles ~41% after ~90s, ~146 mJ/token → favors a small/targeted corrector, not a whole-transcript LLM. **Recommended framing: interactive "tap a wrong word → pick the right alternative" (never silently wrong) + capture those fixes into an on-device bias/vocabulary list** (Gboard-style personalization) so the recognizer stops repeating the mistake — reuses Jot's existing vocabulary/CTC infra and matches its privacy + user-in-control + no-band-aid ethos. **Do NOT auto-underline low-confidence words** (2025 study: unhelpful); surface alternatives on demand.

### Synthesized recommendation
- **Primary (safe, on-brand, reuses infra): interactive tap-to-fix + learn-from-corrections biasing.** Never silently wrong; leverages `VocabularyRescorer`/`CtcModelCache`/`TranscriptDetailView`/`InlineEditTextView` and the adaptive-vocab loop already in the app. **Hard dependency to verify: what per-word alternatives/confidence FluidAudio actually surfaces to Jot today** (per-token confidence + timestamps confirmed; word-level *alternatives* need the CTC n-best rescore).
- **If automatic correction is still wanted:** the ONLY safe version is confidence-gate → phonetic candidates → CTC-rescore/small-LM pick → **structured `@Generable` edit-list**, biased to no-change, span-level (never the whole transcript), gated on FCR before ship. Prototype + measure on Jot's recordings first.
- **Phase-2 R&D bet:** a purpose-trained tiny corrector (BART-base spike → possibly an Apple-ECLM-style char model) for the highest-quality, zero-hallucination ceiling.

### Codex (ultra) design pass — grounded in Jot's code
**Final position: ship a QUIET, USER-INVOKED correction tool, not an autonomous corrector.** Over-correction becomes **structurally impossible** — automatic False-Correction Rate = **zero by architecture** because no edit ever happens without an explicit user selection. Jot already has the key ingredients: Apple's alternative hypotheses waiting to be captured, FluidAudio token evidence, exact-anchored replacement, vocabulary aliases, and a correction-learning loop. The real engineering is **preserving occurrence-level per-word "evidence" safely through the pipeline** and exposing it without disturbing an already-correct transcript.

**Sharp Jot-specific findings (beyond the web agents):**
- **Apple is the DEFAULT engine** — a Parakeet/CTC-only solution has *low practical coverage*. The design must capture **Apple's** alternatives/segments too (granularity is word-vs-segment **unknown — validate on device**).
- **Streaming artifact loses metadata** — the promoted streaming transcript currently carries only text + timing + sample count; extending only the one-shot path is insufficient. Need a `TranscriptionArtifact` carrying occurrence-level evidence through both capture paths.
- **CTC is not ready-made n-best** — logits are reachable but generic top-K word candidates need new localized decoding/constrained enumeration.
- **Repeated-word confidence corruption** — Jot's existing vocab confidence collapses occurrences by normalized spelling; per-occurrence evidence is required.
- **Offset drift** — multiple post-processing transforms mutate text *after* timings are generated. **UTF-16 exact anchoring + fail-closed mapping are mandatory** (never apply an edit to a stale/ambiguous range).
- **Audio expires (3-day retention)** — CTC rescoring can't depend on retained audio; a versioned sidecar of evidence is needed, with lifecycle tied to every edit/re-transcribe/delete path.
- **Learning poisoning** — common-homophone fixes must NOT auto-become global bias; "Replace & remember" limited to explicit intent (names/jargon), reusing vocabulary aliases.
- **Corpus caveat:** `~/Desktop/jot-recordings.csv` = **2,844 rows (133 empty transcripts); transcript provenance UNKNOWN** — do NOT treat as ground truth until human-verified.

**Phased plan:**
- **Phase 0 (spikes):** (a) token-timing coverage on short/long Parakeet recordings incl. repeated words/punctuation; (b) localized CTC candidate spike on 50–100 human-confirmed error windows (Recall@3, false-candidate rate, latency/memory/battery) — abandon generic beam if unstable; (c) corpus audit (establish which CSV labels are human-corrected). Exit targets: ≥99.5% range reconciliation, Recall@3 ≥70% on selected errors, **zero stop/publish latency when unused**, warm tap→candidate p95 <~300 ms.
- **Phase 1 (MVP, behind an Experimental flag):** `TranscriptionArtifact` + occurrence evidence across Apple one-shot + streaming + Parakeet paths; final-text reconciliation; versioned sidecar; Original-tab tap handling; Apple/learned candidate display; typed fallback; **Replace once / Replace & remember**; exact-anchor fail-closed; sidecar deletion + re-transcription invalidation. (CTC candidates enter only if the spike passes; Foundation Models do **not** enter MVP.)
- **Phase 2 (ship gate):** frozen human-verified dataset split by engine/device/clean-long-form/known-errors/names/homophones/noise/repeated-words/post-processed. Metrics: **automatic FCR = 0 (by architecture)**, false-suggestion rate on correct-word taps, Precision@1 at true error slots, Recall@3, **byte-identical no-regression when disabled**, 100% anchor safety (fail closed), learning safety (jargon improves, common-word controls don't regress), performance/thermal. Local harness + explicit diagnostic export (no silent analytics — Jot has no telemetry by design).

**Net:** the hard part is *plumbing per-word evidence safely through Jot's transform pipeline and surfacing it on tap*, not the ML. This is a real multi-week feature, but with over-correction ruled out by construction.

## Key sources
- Apple, *Revisiting ASR Error Correction with Specialized Models* — https://machinelearning.apple.com/research/asr-error-correction
- *ASR Error Correction using LLMs (n-best + constrained decoding)* — https://arxiv.org/html/2409.09554v2
- *Whispering-LLaMA* (open cross-modal GER) — https://github.com/Srijith-rkr/Whispering-LLaMA
- *RLLM-CF: fewer hallucinations, verification* — https://arxiv.org/abs/2505.24347
- *GER for rare words with phonetic context* — https://arxiv.org/pdf/2505.17410
- *Confidence-guided error correction* — https://arxiv.org/pdf/2509.25048
- *Non-Intrusive ASR Refinement: A Survey* — https://arxiv.org/pdf/2508.07285
- FluidAudio (confidence/timestamps) — https://github.com/FluidInference/FluidAudio
