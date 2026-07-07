# Apple Dictation A/B Spike — status + what worked

**Status (2026-07-05):** experimental, hidden behind a Settings toggle. NOT a
decided default yet. This doc exists so a future session can pick up "make
Apple dictation the default" without re-deriving the debugging history below.

**Owner on-device confirmation (2026-07-05, post build 242/243 fixes):** the
CTC vocabulary-boost pass works well running on top of Apple's engine — real
device testing after the three bug fixes above. This is the core thing the
whole session's investigation was trying to establish (does the existing
vocab-boost mechanism still work if Apple replaces FluidAudio as the front-end
engine); owner-confirmed yes.

**Direction decided (2026-07-05, owner):** Apple's engine is NOT meant to
become the universal default. FluidAudio's own WER benchmark (below) shows
FluidAudio is actually MORE accurate on real recordings — there's no
across-the-board quality case for switching everyone. The real target: Apple's
engine as English dictation support for devices that currently have **none at
all** — sub-6GB-RAM phones (iPhone 11, 12/13 non-Pro, SE) are entirely
unsupported today for English (`DeviceCapability.is600MCapable` gates it off,
no smaller fallback tier exists). Apple's `SpeechAnalyzer` runs on any iOS
26-compatible device back to iPhone 11 regardless of RAM tier, so it can
extend dictation to those phones without shrinking accuracy for anyone who
already has FluidAudio. Capable devices should keep defaulting to FluidAudio.

**➡️ Follow-on design doc:** [docs/dictation-engine-rework/design.md](../dictation-engine-rework/design.md) —
the full architecture for making this native (device/language compatibility matrix,
engine-selection logic, streaming rework, rollout plan). Read that doc, not this
one, for anything beyond the spike's own bug history.

**Next planned work session:** rework the dictation-engine architecture to
support Apple's engine "natively" — i.e. promote it out of the experimental
A/B-toggle shape into a real, permanent part of the pipeline (specifically
scoped to the under-served device tier above), not a wholesale swap. Revisit
the "dual-write retained audio format" tradeoff (in Open Questions below) in
that context, since it stops being a throwaway-experiment concern once this is
a permanent code path.

## What this is

An English-only alternative front-end dictation engine: Apple's on-device
`SpeechAnalyzer`/`SpeechTranscriber` (iOS 26+) instead of FluidAudio's Parakeet
TDT, with Jot's existing CTC vocabulary-boost running unmodified on top of
whichever engine produced the raw transcript.

- Toggle: Settings → About → tap Version 5× → Labs → **"Apple Dictation
  (English, A/B test)"**. Off by default.
- Engine: `Jot/App/Transcription/AppleDictationEngine.swift`
- Wiring: `TranscriptionService.transcribe(samples:)`'s stop-pass only —
  **not** the live-preview loop (`previewTranscribe`), which stays FluidAudio
  (see "Why preview wasn't touched" below).
- Comparison tools:
  - `Jot/App/Transcription/EngineABTestLabView.swift` — batch re-transcribes
    the last 3 days of retained (English-only) audio through both engines,
    review one-by-one.
  - `Jot/App/Transcription/LiveEngineComparisonStore.swift` — when the toggle
    is on, every REAL dictation also shadow-runs FluidAudio in the background
    (non-blocking, best-effort) and stores the pair for marking in the same
    Lab screen ("Apple better" / "Jot better" / "Same").

## Three real bugs found and fixed (in order)

All three were found by pulling actual crash logs off the paired device via
`xcrun devicectl device copy from --domain-type systemCrashLogs`, not by
guessing from symptoms. Worth repeating that step first if anything regresses.

1. **Missing `NSSpeechRecognitionUsageDescription`.** Jot never used Apple's
   Speech framework before (always FluidAudio) — iOS hard-terminates any app
   that touches Speech APIs without this Info.plist key. Legitimate fix, but
   turned out NOT to be the cause of the crash the owner was actually hitting
   (see #2) — both fixes were needed, independently.
2. **Wrong audio format fed to the analyzer.** Code assumed Jot's own 16kHz
   mono Float32 pipeline format would work for Apple's engine too. It didn't —
   `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` returned 16kHz
   mono **Int16**, and feeding the wrong format trapped inside Apple's own
   framework (`SpeechRecognizerWorker.preRunRecognition()`, `EXC_BREAKPOINT`).
   Fix: query `bestAvailableAudioFormat` and convert with `AVAudioConverter`
   when it differs from the source format.
3. **`AVAudioConverter` input-block hang, then `finalize` gap.** Two
   sub-bugs, found in that order:
   - The converter's "no more data" signal used `.noDataNow` (streaming
     semantics — "more might come later") instead of `.endOfStream` ("this is
     everything") for a one-shot conversion. Caused an infinite hang instead
     of crashing.
   - After fixing the hang, transcripts came back empty. Root cause:
     `analyzer.analyzeSequence(inputSequence)` alone doesn't auto-finalize the
     last pending segment the way the file-based
     `start(inputAudioFile:finishAfterFile: true)` does. Fixed by switching to
     `analyzer.start(inputSequence:)` **plus** an explicit
     `analyzer.finalizeAndFinishThroughEndOfInput()` call, both run
     concurrently with draining `transcriber.results`.

**Verification method that actually worked:** a standalone SPM tool
(`apple-engine-verify` in scratchpad) that copies the REAL
`AppleDictationEngine.swift` unmodified (stubbing only `DiagnosticsLog` and
`CorrectionStore.OverrideEntry`) and runs it against real retained `.wav`
files pulled from the Mac Jot app / device, with the whole run visible in
terminal output. This caught the empty-transcript bug locally, across 7 real
recordings, before it ever went back to TestFlight. Recommended as the first
step for any future change to this file, rather than a build→TestFlight→wait
cycle.

## Why the live-preview loop wasn't touched

`previewTranscribe(samples:)` ticks several times per second while the user
is still speaking and is deliberately "lean" (no vocab boost, no side
effects, must stay cheap). Apple's `SpeechAnalyzer`/`SpeechTranscriber` API is
built around a "feed once, finalize once, get one final result" shape (per
the bug #3 finding above) — not naturally suited to "feed a slightly-longer
buffer every 200ms, get an updated partial guess back cheaply." Wiring Apple's
engine into preview would need a genuine streaming integration (one
persistent analyzer session kept alive for the whole recording, fed live
buffers, listening for volatile/partial results) — a materially different and
more invasive piece of work than the one-shot batch swap done here. Treat as
its own task if pursued.

## Known open findings from independent review (not yet re-verified since)

From a code-review pass on the Lab UI specifically (not the engine bugs
above), before the crash/hang/empty-transcript chain was found:

- Lab batch doesn't check `TranscriptionService.isBusy` before starting — now
  fixed (busy-guard added).
- Non-English retained recordings were being silently mis-transcribed by both
  engines — now fixed (Lab filters to English-only via `transcript.language`).
- Vocab-boost-not-ready vs. vocab-boost-ran-no-op were indistinguishable in
  the UI — now fixed (Lab shows "(vocab not ready)" distinctly).

## WER benchmark (2026-07-05, real recordings, raw transcription only)

25 real recordings sampled from a ~2900-row Mac Jot recordings export
(`~/Desktop/jot-recordings.csv`, audio path + real ground-truth transcript —
see [[reference_full_recordings_csv_export]]), no vocab boost:

| Engine | Mean WER | Median WER |
|---|---|---|
| FluidAudio Parakeet v2 (current default) | 0.088 | 0.067 |
| Gemini 3.1 Flash-Lite | 0.112 | 0.087 |
| Apple SpeechAnalyzer | 0.132 | 0.103 |

FluidAudio wins outright. This is WHY the direction above is "Apple as a
fallback for under-served devices," not "Apple as the new default" — swapping
everyone to Apple would be a real accuracy regression, not a wash. n=25 is a
spot-check, not definitive; worth a larger run before finalizing anything.
Standalone tool at scratchpad `engine-compare/` (SPM package) if this needs
re-running with a bigger sample.

## Open question for "make it default"

If Apple's engine becomes a real default (not a togglable experiment), worth
reconsidering:
- **Dual-write retained audio at capture time** (once as Float32 for
  FluidAudio, once as Int16 for Apple) instead of converting at read time —
  discussed with the owner 2026-07-05. Tradeoff: removes a runtime conversion
  step (where today's bugs lived), but bakes in an assumption about Apple's
  "best" format that could silently go stale on a future OS update, and
  touches `RecordingService`'s core capture path (used by every dictation,
  not just this toggle). Deferred as not worth it for an experiment; worth
  revisiting if this becomes permanent.
- Whether to keep FluidAudio's CTC vocab-spot mechanism (`spotDetections`/
  `gateDetections`) as-is, given it was found this session (via the Mac app's
  own memory notes) to reliably recover only SINGLE-token vocabulary terms —
  multi-token terms ("Vineet Sriram", "Claude Code") are a documented,
  pre-existing weak spot independent of which transcription engine is used.
- Whether `previewTranscribe` should eventually get a real streaming Apple
  integration, or stay FluidAudio permanently even if the stop-pass defaults
  to Apple.
