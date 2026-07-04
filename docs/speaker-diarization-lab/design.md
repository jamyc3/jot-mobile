# Speaker Diarization Lab (mobile, experimental)

Ported from the validated Mac Jot research at
`/Users/vsriram/code/jot/docs/speaker-diarization/design.md`. This is a
hidden, opt-in **lab prototype** — not a shipped feature — to test whether
offline VBx diarization is worth building out properly on mobile.

## What shipped in this pass

- **Reveal:** Settings → About, tap the "Version" row 5× (same gesture as the
  TTS Lab). Reveals a "Diarization Lab" row alongside "Text to Speech".
  Persisted via `AppGroup.Keys.diarizationLabEnabled`.
- **Model:** FluidAudio's offline VBx pipeline (`OfflineDiarizerManager`,
  pyannote community-1 — segmentation + embedding + PLDA, ~22 MB). Already
  present in FluidAudio 0.14.7, the version mobile Jot has pinned — no package
  bump needed. `DiarizerHolder` (actor) owns download/load/process, mirroring
  `VocabularyRescorerHolder`'s generation-guarded shape.
- **Owner voice profile:** `OwnerVoiceprintStore` builds a centroid from the
  user's own past SOLO recordings (no enrollment), same medoid-trim approach
  as the Mac research. Triggered automatically the first time the lab is
  revealed, and manually re-buildable from the lab screen.
- **Action:** "Detect speakers" button in `TranscriptDetailView`, next to
  Re-transcribe — only shown when the lab is on AND retained source audio
  still exists for that recording. Shows an ephemeral result sheet (label +
  time range + a proportional-by-time text split per speaker turn). **Nothing
  is persisted** — no schema change in this pass.

## Deliberate scope narrowing vs the Mac design

- **3-day retention ceiling.** Mac Jot assumed an effectively unlimited
  recording library for both the on-demand diarize action and the owner
  voiceprint build. Mobile only keeps source audio for
  `RetainedAudioStore.retentionDays` (3 days) — "Detect speakers" only works
  within that window, and the voiceprint's candidate pool is whatever solo
  clips are still retained, not the full history. If fewer than 5 solo clips
  are available, the voiceprint isn't built and every speaker renders
  anonymous — the feature still works, just without "You".
- **No schema change.** The Mac design reuses a persisted
  `Recording.speakerTimeline` field. This pass shows the result in an
  ephemeral sheet only — it doesn't survive leaving the screen. If this
  graduates past the lab, persisting it needs a new `JotSchemaV9` (V8 is
  frozen per `Jot/CLAUDE.md`'s schema discipline) sibling field.
- **Raw cosine, not PLDA-rho.** The Mac design flags PLDA-rho scoring (the
  pipeline's own discriminatively-trained similarity space) as the more robust
  choice for owner-matching, with raw-256 cosine as a fallback. This pass uses
  raw cosine only — it's what the Mac feasibility test actually validated
  (0.18 self vs 0.82 other) and keeps the prototype's surface small. Revisit
  if owner-matching accuracy is disappointing on real (non-synthetic) second
  speakers.
- **No token-timing alignment.** Mobile doesn't currently surface Parakeet's
  `tokenTimings` through `TranscriptionService`. Per-speaker text uses the
  same proportional-by-time fallback the Mac design uses for Nemotron
  ("accurate to within one word at each boundary — correct enough to ship").
- **Background auto-diarize was explicitly considered and rejected for
  now** — see the "background refresh" discussion in this session: iOS's
  `BGAppRefreshTask`/`BGProcessingTask` schedule opportunistically (iOS
  decides if/when, not the app), so it isn't a good fit for "labeled by the
  time you open the note." The lab keeps the Mac design's D4 (manual,
  on-demand only).

## Cross-pipeline concurrency

A known FluidAudio issue (#661, cited in the Mac design) corrupts shared BNNS
state if two CoreML graphs run concurrently. Mobile's `TranscriptionService`
gates its own ASR calls with a private `isTranscribing` flag; this pass adds
a one-line public read accessor (`TranscriptionService.isBusy`) so
`DiarizerHolder`/`OwnerVoiceprintStore` can back off rather than race it.
`DiarizerHolder` itself is single-in-flight (an `isProcessing` guard).

## Known rough edges (lab-quality, not production-quality)

- Owner-match thresholds (`ownerAbsoluteBar`, `ownerRelativeMargin` in
  `DiarizationLabeling`) are seeded from the Mac numbers, not calibrated on a
  mobile device or against real family/similar voices — the Mac design's own
  Risk R1.
- The voiceprint build has no progress UI beyond the lab screen's "Rebuild"
  button; it isn't wired to run automatically after every new recording.
- No accessibility pass, no localization (Diarization Lab strings are
  hardcoded English) — appropriate for a hidden dev toggle, not for shipping.

## Files

- `Jot/App/Diarization/DiarizerHolder.swift` — actor wrapping
  `OfflineDiarizerManager` (download/load/process).
- `Jot/App/Diarization/DiarizationLabeling.swift` — pure functions:
  dominance-based multi-speaker check (D7), owner-label assignment,
  medoid-trim, cosine distance, proportional text split.
- `Jot/App/Diarization/OwnerVoiceprintStore.swift` — builds/persists the
  owner centroid from retained solo recordings.
- `Jot/App/Diarization/DiarizationLabView.swift` — Settings sub-screen
  (model status, voice-profile status + rebuild).
- `Jot/App/Diarization/DiarizationResultSheet.swift` — the ephemeral
  "Detect speakers" result sheet + its `DiarizationSheetData`/`DiarizationRow`
  types.
- `Jot/Shared/RetainedAudioStore.swift` — added `allRetainedIDs()`.
- `Jot/App/Transcription/TranscriptionService.swift` — added `isBusy`.
- `Jot/Shared/AppGroup.swift` — added `Keys.diarizationLabEnabled`.
- `Jot/App/Settings/SettingsView.swift` — new lab row + auto-build trigger
  in `handleVersionTap`.
- `Jot/App/TranscriptDetailView.swift` — "Detect speakers" action + sheet.
