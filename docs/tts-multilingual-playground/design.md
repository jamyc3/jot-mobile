# Multilingual TTS + Text-to-Speech Playground — design

Status: DRAFT (2026-06-29). Owner approved scope "engine + build the Playground."

## Goal
1. Make Jot's text-to-speech **multilingual** (English, French, German, Italian, Portuguese, Spanish) for both **synthesis** and **voice cloning**.
2. Move TTS out of the hidden "Lab" + transcript read-aloud into a dedicated **Text-to-Speech Playground** page under Settings → About. Mockup: `jot-mockup.ideaflow.page` (atlas `tts-playground` / `tts-voice-picker` / `tts-clone`).
3. **Remove** read-aloud from the transcript detail view + retire the TTS Lab toggle.

## Key engine findings (verified against the pinned FluidAudio)
- **PocketTTS** is the multilingual engine: `PocketTtsLanguage` = english / french / german / italian / portuguese / spanish (each with a 6-layer and a higher-quality 24-layer pack under `FluidInference/pocket-tts-coreml` `v2/<lang>/`). It does BOTH synthesis (built-in pack voices) and cloning.
- A `PocketTtsManager` is **bound to one language at init** (immutable — "to switch languages, create a new manager"). So the engine layer caches **one manager per language**.
- **The cloned voice is LANGUAGE-AGNOSTIC.** `cloneVoice(from:)` runs the sample through the **Mimi encoder** → `PocketTtsVoiceData` (speaker conditioning, independent of language). `synthesize(text:, voiceData:)` applies the *manager's* language separately. ⇒ **clone once, speak in any of the 6 languages**; language is a synthesis-time choice, not a property of the clone.
- Each language pack ships **built-in voices** (e.g. `PocketTtsConstants.defaultVoice = "alba"`), so non-English **preset** voices come free with the pack — no reference samples to bundle.
- Today Jot uses **Supertonic-3** for the 10 English presets (high quality, ~398 MB), and PocketTTS only for cloning (always `.english`). All `TTSVoice.language` are hardcoded `"en"`; `TranslationGateway` is a translate-then-speak fallback (English voice only).
- Alternatives rejected: **Kokoro** (this build = English + Mandarin only — wrong language set); **Magpie** (multilingual but experimental, RTFx < 1.0 = slower than real-time).

## Model / data changes
- `TTSVoice.language` becomes meaningful (BCP-47/ISO code). Cloned voices stay one record but are no longer pinned to `"en"` — they can be synthesized in any supported language.
- New: a **selected synthesis language** for the Playground (and per-generate). Likely a new `AppGroup` key `jot.tts.language` (default device/English) — read in the app only (TTS is app-host).
- Cloned-voice registry (`AppGroup.Keys.ttsClonedVoices`, `.bin` under `ApplicationSupport/TTSVoices/`) is unchanged — clones are already just speaker conditioning.

## Engine layer (Phase 1)
`TTSService` gains a language axis:
- Cache `pocket[language] : PocketTtsManager` (lazy per language; each `initialize()` downloads that pack once). Replace the single `.english` `pocket`.
- `synthesize(text, voice: TTSVoice, language: PocketTtsLanguage)`:
  - **cloned voice** → `pocket[language].synthesize(text:, voiceData: loadClonedVoice(.bin))`.
  - **PocketTTS preset** → `pocket[language].synthesize(text:, voice: packVoiceId)`.
  - **English Supertonic preset** → keep the existing Supertonic path (best English quality) when language == en; for non-en, use PocketTTS.
- Keep the existing `speak()` AVAudioEngine playback + `stop()` teardown; route PocketTTS WAV (24 kHz) through it (Supertonic already does).
- **Decision A (English voices):** keep Supertonic for English presets (quality) + PocketTTS for en clones & non-en. Simplest, best quality, but two engines. (Alt: unify on PocketTTS — fewer engines, but loses the Supertonic English quality + re-downloads.) → **lean keep Supertonic for English presets.**

## Playground UI (Phase 2) — SwiftUI, new page under Settings → About
Per the atlas mockups:
- Text field → **language picker** (the 6) → **voice row** (selected voice; tap → picker) → **Generate** → player (scrub + transport) → **Export audio** (share sheet, `.m4a`/AAC default).
- Voice picker: pack presets for the chosen language + cloned voices (by name) + "Clone your voice".
- Clone screen: record ~15s, name it → `cloneVoice`.
- Export: write the synthesized WAV → AAC `.m4a` → `UIActivityViewController` (Files/AirDrop/Messages).
- Model-state surfacing: first use downloads the chosen language pack (progress), mirroring the Settings download UX.

## Removal (Phase 3)
- Strip `readAloudControls` / `readAloudText` / `selectedVoice` / `ttsLabEnabled` from `TranscriptDetailView`.
- Retire the `AppGroup.Keys.ttsLabEnabled` Lab toggle in Settings; the About row becomes a chevron → Playground (matches the mockup edit already made).
- Keep `TranslationGateway`? With real multilingual TTS it's largely redundant; decide whether to keep as a fallback or delete. → **lean delete once multilingual synth lands.**

## Testing reality
- **TTS audio is device-only** (the sim can't drive synthesis/playback — see memory `project_tts_lab_playback_clone`). Owner is TestFlight-only until Mon 2026-06-29+. So each phase is compile-verified locally and **verified on device via TestFlight**.
- Per-language pack downloads + first-synth latency need on-device measurement.

## Open questions
1. English voices: keep Supertonic (Decision A, leaning yes) or unify on PocketTTS?
2. 6-layer vs 24-layer PocketTTS packs (quality vs size/speed) — measure on device; start with the default (6) unless quality is poor.
3. Does one clone sample sound good across all 6 languages, or only near the recorded language? (Model says agnostic; verify timbre/accent on device.)
4. Export format: `.m4a`/AAC (recommended) vs `.wav`.
5. Delete `TranslationGateway` or keep as fallback?

## Phasing
- **P1 — engine:** multilingual `TTSService` (per-language PocketTTS cache + language-aware synth + cloned-voice-in-any-language). Testable via the EXISTING read-aloud before it's removed.
- **P2 — Playground page** (Settings → About): the SwiftUI page + voice picker + clone + export.
- **P3 — removal:** rip read-aloud from transcripts + retire the Lab toggle + wire the About entry.
Each phase = its own compile-verified, TestFlight-shippable increment.
