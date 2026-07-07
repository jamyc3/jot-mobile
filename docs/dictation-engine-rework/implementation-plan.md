# Dictation engine rework — implementation plan (remaining work)

**Status:** AUTHORED 2026-07-05 (v2) by the adversarial-review agent, commissioned by the
owner. Covers everything left after the C1 converter fix (verified against 6 real recordings:
mean WER 0.062, 15–98 progressive updates/file, first text ~1.5s; pre-fix C1 also hung
`finalizeAndFinishThroughEndOfInput` — an analyzer starved of audio never finalizes, so C1
was a teardown hang, not just a blank preview).

**Rules that bind every step:** root cause only, no band-aids. All work stays UNCOMMITTED
until the owner verifies on device. No `git commit` 9pm–10am PST even after a verify.
Compile gate after every step (`xcodegen` from `Jot/`, then build); harness gate where
marked. Every step is independently revertible (its diff touches only the files it names).

## Decided inputs (owner, 2026-07-05 — no longer open questions)

**D1 — FluidAudio upgrade offer, three surfaces:** (a) the WIZARD offers the download during
setup on capable devices; (b) a SETTINGS row, always available; (c) a KEYBOARD nudge after a
few dictations if still not downloaded, modeled on the existing keyboard vocab-correction UX.
⚠️ **Two different device lines are now in play — do not silently collapse them.** The owner
scoped the proactive surfaces to **iPhone 14 Pro and above**; the design doc's FUNCTIONAL
floor for running FluidAudio at all is **6 GB / iPhone 12 Pro**. Resolution adopted by this
plan: proactive offers (wizard step, keyboard nudge) fire on 14 Pro+ only; the Settings
download remains manually available down to the 6 GB/12 Pro functional line; below that,
never offered anywhere (can't run it). This needs a NEW capability flag (e.g.
`DeviceCapability.isProactiveUpgradeOfferEligible`) distinct from `is600MCapable` — reusing
the existing bool would conflate the support floor with the offer line. D1 is ROLLOUT-PHASE
work (it only matters once Apple is the default); it is specified in §Rollout below, not in
this cycle's steps.

**D2 — stop-pass on the Apple path: the owner delegated the call to me. Decision: PROMOTE
the streaming session's finalized text, gated on proven full coverage; the one-shot
re-transcribe remains as the always-correct fallback.** Answer to "why redo it?": we don't,
in the common case. We redo ONLY when the streaming session cannot prove it heard the whole
recording — pause/resume seams (each resume is a separate analyzer session), the
factory-fallback case (FluidAudio preview ran instead; its preview text is NOT save quality
by design), live-text OFF (no session existed), or dropped chunks (queue cap under a wedged
consumer). The saved note is the product; it must never silently become worse than today's.
The coverage gate is cheap and exact — see Step 6. The owner is also right that the CTC
vocab spot needs only audio and already runs in parallel (the `async let` at
TranscriptionService.swift:691-733); promotion changes nothing about it. Gate to enter
Step 6 at all: Harness V7 must show streaming-assembled text at WER parity with the one-shot
on the same files (≤ +0.01 absolute). If parity fails, Step 6 is skipped and the numbers go
to the owner — that outcome would itself answer "why redo it" (because the redo is
measurably better).

---

## Do-not-touch fences (read first)

Load-bearing, tuned, or cross-process; the steps route around them. If a step seems to
require touching one, stop and re-read the step — it doesn't.

- `Jot/App/Transcription/PreviewScheduler.swift` — ENTIRE FILE. SchedulerSim-tuned; stays
  byte-identical. Its protocol conformance (and any new protocol members) live in
  `StreamingSession.swift` extensions, never in this file.
- `StreamingPartial` (the presenter class, StreamingPartial.swift:28-263) — no logic changes.
  The ONLY edits in that file are to `StreamingBufferQueue` (Step 3b). The presenter's
  session-token guard, throttle, 8 KB cap, and cross-process projection are the keyboard's
  contract.
- `AudioTapRouter` + `CaptureContext` (RecordingService.swift:2773+) — the tap/route/ingest
  path. Untouched by every step.
- Warm-hold, the wizard teardown contract, `pauseRecording()`'s body
  (RecordingService.swift:998-1047) — untouched. Only `resumeRecording()`'s final Task
  changes (Step 2).
- `AppleDictationEngine.swift` — internals untouched (Step 6 COPIES its timing-synthesis
  pattern; it does not modify it).
- `previewTranscribe` + `isPreviewModelReady` (TranscriptionService.swift:962-1058) —
  untouched; FluidAudio-preview-only by design.
- Schema: no `@Model` changes anywhere in this plan (explicit statement per the standing
  schema-impact requirement).
- Log-line literals `"RECORDING START FROM:"`, `"Parakeet prepare wait end"`, `"Parakeet
  inference begin/end"`: preserve exact text even where a line moves (grep stability).

---

## Step 1 — H1: the kickoff/teardown race (generation guard) — `RecordingService.swift` only

**Problem (review H1).** `kickOffStreamingSession()` (RecordingService.swift:404) suspends
at `await TranscriptionService.shared.makeStreamingSession(...)` (line 444). Apple's factory
can take real time (asset check/install + format discovery). A stop/cancel/forceStop/
interruption during that await runs a teardown that finds `previewScheduler == nil`, cleans
nothing, and the resumed kickoff then installs a live session onto a terminated recording:
never-quiesced analyzer (leak), stale presenter updates (the no-scheduler teardown branch
never clears the token), post-terminal state mutation. Same race via the resume path
(line 1118).

**Mechanism: a monotonic generation counter, bumped by every teardown, checked after the
factory await.** Chosen over cancellation tokens / serializing kickoff into stop because it
is synchronous MainActor state with no new suspension points, and orphan disposal reuses the
existing `drain()→quiesce()` contract — no new teardown semantics.

**1a. New field** — next to `previewDrainTask` (RecordingService.swift:245):

```swift
/// Monotonic generation for streaming sessions. Every teardown site bumps it
/// (tearDownStreamingSession covers stop/cancel/pause; forceStop and
/// internalStop bump inline where they snapshot-and-nil the refs).
/// `kickOffStreamingSession` snapshots it before the async factory and
/// discards the built session if any teardown intervened — the discarded
/// session is drained+quiesced on its own detached task so the analyzer and
/// its startTask/resultsTask never leak (adversarial review H1).
private var streamingGeneration: UInt64 = 0
```

**1b. Bump at the three teardown sites:**
- `tearDownStreamingSession()` (line 559): first statement of the body, before
  `streamingQueue?.endOfStream()`: `streamingGeneration &+= 1`.
- `forceStop()`: `streamingGeneration &+= 1` immediately above the snapshot block at
  line 1782 (`let streamingQueueRef = self.streamingQueue`).
- `internalStop`: same one-liner above its snapshot block at line 2659.
Do NOT bump anywhere else — the engine-start-failure paths (~709 and the cold-no-input path
~750-762) run before the kickoff Task is even created; no race exists there.

**1c. Clear the presenter token on the no-scheduler paths** (the stale-update half of H1):
- `tearDownStreamingSession()`'s final fallback branch (currently just
  `self.streamingQueue = nil`, ~line 593): add `streamingPresenter?.clearSession()` above the
  nil. `clearSession()` only nils the token (StreamingPartial.swift:138-140) — no publish,
  idempotent, harmless in the headless / live-text-off cases that also reach this branch.
  **⚠️ AMENDMENT (Opus review MEDIUM-2): ALSO add `await
  TranscriptionService.shared.depositStreamingArtifact(nil)` in this same no-scheduler branch,
  so the "every teardown either arms or disarms the artifact" invariant is literally true and
  a stale artifact from a prior toggle-flipped recording can never survive into this branch.
  This method exists after Step 6; when doing Step 1 first, add a `// TODO(Step 6): deposit nil
  here` marker and wire it when Step 6 lands.**
- `forceStop()` and `internalStop`: immediately after their `endBatchLoadLabelMirror()` calls
  (~1792 / ~2669), add `streamingPresenterRef?.clearSession()` — synchronous MainActor, so it
  belongs in the sync section, NOT inside the detached Task (which keeps its existing
  clearSession for the has-scheduler case; both firing is idempotent and correct).

**1d. Rewrite the tail of `kickOffStreamingSession()`** — from `let sessionID = ...`
(line 436) through the factory call (444-448); the ⚠️ H1 comment block (437-443) is REPLACED
by this fix. The signature gains a return value and a `resumePrefix` parameter (consumed by
Step 2 — implement 1d and 2 together, they are one edit):

```swift
enum StreamingKickoffOutcome { case installed, skipped, stale }

@discardableResult
private func kickOffStreamingSession(resumePrefix: String? = nil) async -> StreamingKickoffOutcome {
    // ... existing three guards unchanged (presenter / queue / live-text) —
    //     each existing early-return becomes `return .skipped` ...

    let sessionID = presenter.beginSession()
    // Resume (§10.5): show the committed prefix IMMEDIATELY — before the
    // factory await — so the strip never blanks while the (possibly slow,
    // Apple asset-install) factory runs. beginSession just cleared
    // resumePrefix, so this ordering is the load-bearing one. (Review M1.)
    if let resumePrefix, !resumePrefix.isEmpty {
        presenter.seedResumePrefix(resumePrefix)
    }
    // H1 guard: snapshot the generation; any teardown during the await
    // bumps it, and we must NOT install a session onto a terminated
    // recording.
    let generation = streamingGeneration
    let scheduler = await TranscriptionService.shared.makeStreamingSession(
        queue: queue, presenter: presenter, sessionID: sessionID
    )
    guard generation == streamingGeneration else {
        // A teardown ran mid-factory. It already EOS'd the queue and cleared
        // the presenter token, so: dispose of the just-built session through
        // its NORMAL lifecycle (drain returns after flushing any pre-EOS
        // samples into the engine, then quiesce finalizes and joins
        // startTask/resultsTask) and walk away. Detached: disposal must not
        // block, and must not touch self.
        log.notice("kickOffStreamingSession stale — recording torn down during engine construction; disposing session")
        Task.detached {
            await scheduler.drain()
            await scheduler.quiesce()
        }
        return .stale
    }
    self.previewScheduler = scheduler
    self.previewDrainTask = Task.detached(priority: .userInitiated) {
        await scheduler.drain()
    }
    // ... existing warmUp()/beginBatchLoadLabelMirror()/DiagnosticsLog tail
    //     unchanged in THIS step (Step 5g revises the warmUp/mirror lines) ...
    return .installed
}
```

Why disposal-via-`drain()` is safe in the stale branch: every teardown that bumps the
generation also EOS's the queue (tearDown does it synchronously before any await;
forceStop/internalStop do it inside their detached tasks — and if that EOS races the
disposal's `drain()`, `popOrEndOfStream` just parks until it lands; it always lands, because
both detached blocks run whenever `streamingQueueRef != nil`, which the race guarantees since
`start()` pre-allocated the queue). `quiesce()`'s precondition ("input sequence ended") holds
because `drain()` returns only after `inputContinuation.finish()`. This disposal path is
Harness case V3 — it is exactly the pre-C1 hang shape, so it MUST be harness-proven, not just
compiled.

**Call sites:** the cold-start (~773) and warm-start (~884) fire-and-forget Tasks ignore the
result.

**Verify (gate):** build green + Harness V3 + sim smoke (start/stop on the FluidAudio path —
byte-identical behavior there, because `PreviewScheduler` constructs synchronously so the
generation cannot change between snapshot and check).

---

## Step 2 — M1: resume must not blank the strip — `RecordingService.swift` (same edit session as Step 1)

Change `resumeRecording()`'s final block (RecordingService.swift:1113-1122) from:

```swift
let prefix = committedStreamingPrefix
Task { [weak self] in
    guard let self else { return }
    await self.kickOffStreamingSession()
    if !prefix.isEmpty {
        self.streamingPresenter?.seedResumePrefix(prefix)
    }
}
```

to:

```swift
let prefix = committedStreamingPrefix
Task { [weak self] in
    await self?.kickOffStreamingSession(resumePrefix: prefix)
}
```

The prefix now renders BEFORE the factory await (Step 1d) instead of after it, and the
`.stale` path can never re-seed text onto a stopped recording (the old code's second race).
Update the ordering comment above the block (currently "spin up ... THEN seed") to match.
Everything else in resume — the `pauseTeardownTask` await, fresh queue install,
`tapRouter.resumeSlice` — stays byte-identical.

**Verify (gate):** build + Harness V4 + sim pause→resume on the FluidAudio path: strip shows
the prefix continuously, resumed tail appends, stop saves the full text.

---

## Step 3 — M4 + M2(cap): converter tail flush + bounded queue — `AppleStreamingSession.swift`, `StreamingPartial.swift`

**3a. Tail flush (M4).** In `drain()` (AppleStreamingSession.swift:154-164), the
`.endOfStream` case becomes:

```swift
case .endOfStream:
    flushConverterTail()
    inputContinuation.finish()
    return
```

New private method after `feed(_:)`:

```swift
/// One terminal convert with `.endOfStream` so a resampling converter's
/// internally-buffered tail frames (filter delay) reach the analyzer.
/// No-op when no conversion is active. For the empirical same-rate Int16
/// target this yields 0–few frames; if `bestAvailableAudioFormat` ever
/// returns a different sample rate on some device, this is the last
/// ~tens of ms of the user's final word (adversarial review M4).
private func flushConverterTail() {
    guard let converter else { return }
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { return }
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
        outStatus.pointee = .endOfStream
        return nil
    }
    if conversionError != nil { return }
    switch status {
    case .haveData, .inputRanDry, .endOfStream:
        if outputBuffer.frameLength > 0 {
            inputContinuation.yield(AnalyzerInput(buffer: outputBuffer, bufferStartTime: nil))
        }
    default:
        break
    }
}
```

It accepts `.endOfStream` status too — that IS the expected terminal status here, unlike
`feed`'s per-chunk case. Do NOT touch `feed(_:)` itself — its C1-fixed switch
(AppleStreamingSession.swift:237-244) is harness-proven; leave it byte-identical.

**3b. Queue cap (M2, defensive half).** In `StreamingBufferQueue`
(StreamingPartial.swift:281-368):

```swift
/// Backlog ceiling: ~120s of 16kHz mono Float32 (~7.7MB). The consumer
/// normally drains within ms; this only bites when the consumer is absent
/// for minutes (e.g. a first-use Apple asset install mid-recording).
/// Overflow drops the OLDEST chunk: the preview should show the newest
/// speech, and the saved transcript is unaffected (the stop-pass reads
/// CaptureContext, not this queue). A session that suffered drops can
/// never be promoted at stop — its consumed-sample count won't match the
/// capture (Step 6 coverage gate), by construction.
private static let maxBufferedSamples = 120 * 16_000
private var bufferedSamples = 0
```

In `push(_:)` (line 297), inside the lock, on the append path only (a parked waiter means
backlog 0 — no cap logic needed on that path):

```swift
queue.append(samples)
bufferedSamples += samples.count
while bufferedSamples > Self.maxBufferedSamples, !queue.isEmpty {
    bufferedSamples -= queue.removeFirst().count
}
```

Mirror the accounting: `popOrEndOfStream` decrements by the popped chunk's count; `reset()`
zeroes it. Nothing else in the file changes. Cannot affect the FluidAudio path in practice
(PreviewScheduler drains continuously; backlog never approaches 2s, let alone 120s).

**Verify (gate):** build + Harness V1 regression (6-file WER unchanged) + V5 (tail unit
check) + V6 (cap behavior).

**→ DEVICE CHECKPOINT 1 (recommended).** After Steps 1-3 the Apple path is safe to hand to
the owner: C1 verified, H1 closed, tails bounded. Ship uncommitted via `scripts/testflight.sh`
(absolute path; build number must be ≥228) when the owner wants it. Checklist in
§Verification.

---

## Step 4 — retire the live shadow-run — `TranscriptionService.swift` only

**Why before Step 5:** the shadow-run (lines 849-895) is the only thing on the Apple
stop-pass path that structurally needs a LOADED FluidAudio `manager`. Deleting it first makes
Step 5's inversion clean instead of conditional. The design doc already recommends this (its
open question 1). Only the LIVE shadow dies — `EngineABTestLabView`'s batch
retranscribe-and-compare (via `rawTranscribeForComparison`, line 586) is untouched and
remains the owner's comparison tool.

**Edits:**
- Delete the whole `if useAppleEngine { ... }` shadow block, lines 849-895 (from the
  `// A/B Lab support (2026-07-05, temporary)` comment through the closing brace after
  `catch { // No comparison pair ... }`).
- `publishedCorrections` (declared ~820, assigned ~841): grep
  `publishedCorrections` first; if the shadow block was its only reader (it is, per my review
  read), delete the declaration and the assignment, keeping `transcriptText = rescored.text`.
- `LiveEngineComparisonStore`: leave the file this cycle (the Lab's history viewer may read
  it); nothing records anymore. One header-comment line: "Live shadow-run retired 2026-07
  (implementation-plan Step 4); batch Lab comparisons only." Full removal is a rollout-phase
  debt.

**Verify (gate):** build + `grep LiveEngineComparisonStore.record` → zero call sites + sim
smoke (one dictation per toggle position; transcript publishes normally).

---

## Step 5 — H2 / ask-4 completion: two peer stop-pass engines — `TranscriptionService.swift`, `RecordingService.swift`, `StreamingSession.swift`

The crux-of-the-app edit: a pure extraction-and-reorder of `runInference`
(TranscriptionService.swift:615-937). Every existing statement lands in a named destination;
nothing is rewritten except the two method shells and the dispatch. After this step the Apple
stop-pass NEVER touches FluidAudio state unless Apple itself fails.

**5a. The seam** — two private engine methods + one dispatcher on `TranscriptionService`:

```swift
// MARK: - Stop-pass engines (docs/dictation-engine-rework/implementation-plan.md Step 5)
// Two PEER transcription methods (owner ask #4). Each fully owns its own
// preconditions: neither can gate, warm, or fail the other's path.

/// FluidAudio/Parakeet stop-pass. Owns: bundled-model integrity check,
/// prepare/load wait, manager guard, decoder state.
private func fluidAudioStopPass(samples: [Float], label: String) async throws -> ASRResult

/// Apple SpeechTranscriber stop-pass. Owns: the promoted-streaming-artifact
/// check (Step 6) and the one-shot engine call (asset install lives inside
/// AppleDictationEngine.transcribe). Nothing FluidAudio.
private func appleStopPass(samples: [Float]) async throws -> ASRResult

/// Engine dispatch + resilience policy: Apple first when selected; any
/// Apple failure falls back to FluidAudio (which only THEN pays its load
/// cost). Reads `useAppleEngine` exactly once per stop-pass.
private func stopPassTranscribe(samples: [Float], label: String) async throws -> ASRResult
```

**5b. `fluidAudioStopPass` body — moved verbatim from `runInference`:** the integrity-check
block 636-643 WITH its full consent/capability comment 615-635; the prepare wait + timing
logs **645-651** (log text unchanged) — **⚠️ AMENDMENT (Opus review MEDIUM-1): line 644
(`let inferenceStartedAt = Date()`) STAYS in `runInference` — it is read later by the RTF math
(774-780) and the catch (928-930); moving it breaks the build. Move only 645-651.**; the
manager guard 652-654; the decoder-state construction
669-671 with its FluidAudio-0.14.x comment 660-668; the
`manager.transcribe(samples, decoderState:&, language:)` call (shape at 768-772); return the
`ASRResult`.

**5c. `appleStopPass` body:** the lines currently at 744-747 (routing log, one-shot call,
success log). Step 6 later prepends the artifact check here.

**5d. `stopPassTranscribe` body** — the policy currently inline at 742-773, now the ONLY
stop-time read of `useAppleEngine`:

```swift
if useAppleEngine {
    do {
        return try await appleStopPass(samples: samples)
    } catch {
        // Resilience: the toggle must never cost the user a dictation.
        // FluidAudio pays its (possibly cold) load HERE, on the failure
        // path only — no longer eagerly on every Apple dictation (H2).
        log.error("A/B: Apple SpeechTranscriber FAILED, falling back to FluidAudio — \(error.localizedDescription, privacy: .public)")
        DiagnosticsLog.record(   // keep the existing record verbatim (755-760)
            source: "main-app", category: .vocabularyGate,
            message: "Apple dictation A/B engine failed, fell back to FluidAudio",
            metadata: ["error": "\(error)"]
        )
        return try await fluidAudioStopPass(samples: samples, label: label)
    }
}
return try await fluidAudioStopPass(samples: samples, label: label)
```

**5e. `runInference` after — every remaining line accounted for:**
1. Signature + `inferenceStartedAt` (644): stay.
2. Lines 636-654: GONE (moved, 5b).
3. `signposter.beginInterval("transcribe-inference")` (656) + "Parakeet inference begin" log
   (657-659): stay, engine-neutral, at the top of the `do {}`; literal text unchanged
   (historical label, grep stability — one-line comment says so).
4. The vocab CTC spot `async let` block (~691-733: `vocabEnabledForThisRun`, `audioForSpot`,
   the `withTimeout` spot task): stays EXACTLY where it is — audio-only, engine-agnostic,
   must keep launching BEFORE inference for the measured 15-23% overlap win. Zero changes.
5. Engine-selection comment 735-741 → one line pointing at `stopPassTranscribe`; branch
   742-773 → `let result = try await stopPassTranscribe(samples: samples, label: label)`.
6. Inference-end logs + RTF math + `signposter.endInterval` (774-781): unchanged.
7. `CorrectionProvenance.shared.clearPending()` (795), "batch transcribe finished"
   DiagnosticsLog (799-808), `let resolvedSpot = await spotResult` (816), merge block
   (821-847): unchanged (with Step 4 done, `publishedCorrections` is already gone).
8. Paragraph/filler/number pipeline (897-925) + `return transcriptText` (926): unchanged.
9. `catch` (927-936): unchanged — note it now also wraps a FluidAudio prepare failure thrown
   from inside `fluidAudioStopPass`: the error's TIMING changes (mid-do rather than pre-do),
   so it gets the "Parakeet inference failed" log + `TranscriptionError.inferenceFailed`
   wrapping instead of propagating raw. Caller-visible surface is the same (a thrown
   `TranscriptionError` into the same pipeline dispatch) — verified acceptable; flag in the
   step's review notes regardless.
10. `rawTranscribeForComparison` (586-600): leave as-is this cycle (Lab-only, own inline
    branch). Optional tidy only if trivial.

**5f. Why methods-not-protocol, for the reviewer:** an external-conformer
`TranscriptionEngine` protocol would need `TranscriptionService`'s private
`manager`/`prepareTask`/`modelState`, forcing visibility loosening for ceremony. The owner's
bar is symmetry in EFFECT: after 5a-5e each engine's preconditions are fully contained, the
dispatch is one policy function, and neither engine can gate the other. When the rollout
phase adds per-language engine policy (English + the 10 Apple-covered languages), lift these
two methods behind a real protocol THEN — the second axis (language → engine table) earns
the abstraction. Documented deferral, not an omission.

**5g. Preview-side warm-up inversion — `RecordingService.swift` + `StreamingSession.swift`:**
- Protocol addition (StreamingSession.swift:14-28):
  ```swift
  /// Whether this session's preview inference rides the FluidAudio batch
  /// model (and therefore wants warmUp() + the keyboard's model-loading
  /// affordance). Capability flag, not an identity check — RecordingService
  /// stays engine-blind.
  nonisolated var usesBatchModel: Bool { get }
  ```
  `extension PreviewScheduler: StreamingSession` (StreamingSession.swift:30) gains
  `nonisolated var usesBatchModel: Bool { true }` — in the extension, PreviewScheduler.swift
  untouched. `AppleStreamingSession` adds `nonisolated var usesBatchModel: Bool { false }`.
- In `kickOffStreamingSession()`'s tail, replace the unconditional
  `TranscriptionService.shared.warmUp()` + `beginBatchLoadLabelMirror()` (~459-460) with:
  ```swift
  if scheduler.usesBatchModel {
      TranscriptionService.shared.warmUp()
      beginBatchLoadLabelMirror()
  } else {
      // Apple session active: no 600M load to warm or mirror.
      endBatchLoadLabelMirror()
  }
  ```
  Closes H2's RAM half (no 600M in memory on Apple-path recordings) AND review L4 (no false
  "Loading Parakeet…" on the keyboard strip). The factory's fallback-to-PreviewScheduler case
  automatically reports `usesBatchModel == true` → warmUp still fires exactly when the
  preview actually needs it. The "preview session start" DiagnosticsLog (~465) stays.

**Behavioral deltas to state to the owner (all intended):** (1) Apple-path stop no longer
waits for a cold 600M load — up to ~16s off a cold stop; (2) Apple-path recordings no longer
hold the 600M in RAM; (3) if Apple fails at stop, the fallback pays the load wait AT THAT
MOMENT (rare, logged, still succeeds); (4) a thinned/integrity-broken FluidAudio bundle with
the Apple toggle ON now dictates fine via Apple instead of throwing "reinstall Jot".

**Verify (gate):** build + sim both toggle positions + Harness V1 regression.

---

## Step 6 — D2: promote the streaming session's text at stop, coverage-gated — `AppleStreamingSession.swift`, `StreamingSession.swift`, `RecordingService.swift`, `TranscriptionService.swift`

**PRE-GATE (do this before writing any app code): Harness V7 + V8 must pass.** V7: same
files (expand to ~15 from `~/Desktop/jot-recordings.csv`) through (a) the streaming session's
assembled final text and (b) the one-shot `AppleDictationEngine.transcribe` — streaming WER
must be ≤ one-shot WER + 0.01 absolute, and V2's tail-words check must hold. V8: seed a
vocabulary term that appears in a recording, run the CTC spot on the audio + the merge
against timings SYNTHESIZED from streaming results (see 6a) — the merge must fire on the
correct word span, matching the one-shot path's behavior on identical audio. If V7 fails:
skip this step entirely, keep the one-shot, report the numbers to the owner as the
justification he asked for.

**Why the gate can be exact:** the tap pushes the SAME converted sample arrays to both the
capture storage and the streaming queue (`AudioTapRouter.route`,
RecordingService.swift:~2891-2917: `capture.ingest(pcm)` returns `convertedSamples`, then
`streamingQueue.push(convertedSamples)`), and pause gates BOTH identically. So a streaming
session that consumed every queued chunk has consumed EXACTLY `capture.drain().count`
samples. Any divergence — pause/resume (per-slice sessions), queue-cap drops, factory
fallback, live-text off, mid-session failure — shows up as a count mismatch or a missing
artifact, and the stop-pass silently uses the one-shot. Promotion is provably-safe-or-absent
by construction.

**6a. `AppleStreamingSession` collects what the stop-pass needs:**
- New actor state: `private var consumedSampleCount = 0` — incremented by `chunk.count` at
  the top of `feed(_:)` (before any conversion; source-sample units, matching capture), and
  `private var words: [AppleDictationEngine.Word] = []`.
- In `consumeResults()` (AppleStreamingSession.swift:247-268), for `isFinal` results ONLY,
  synthesize per-word timings from the result's runs — the SAME char-share pattern as
  `AppleDictationEngine.transcribe` (AppleDictationEngine.swift:182-199): iterate
  `result.text.runs`, take `run.audioTimeRange`, split the run text on spaces, apportion the
  range by character share, append to `words`. Factor that loop into a shared static helper
  on `AppleDictationEngine` (e.g. `static func words(from text: AttributedString) -> [Word]`)
  and call it from BOTH places rather than duplicating — the one-shot's call sites change
  from inline loop to helper call, byte-equivalent output (this is the one permitted edit in
  that file: extract, don't modify).
- New method (after `assembledText()`):
  ```swift
  /// Save-quality artifact for the stop-pass, valid only after quiesce().
  /// nil when the session cannot vouch for a complete, fully-finalized
  /// transcript — the caller then runs the one-shot pass instead.
  func stopArtifact() -> StreamingStopArtifact? {
      guard volatileText.isEmpty, !finalizedText.isEmpty else { return nil }
      return StreamingStopArtifact(
          text: finalizedText,
          tokenTimings: words.map {
              TokenTiming(token: " " + $0.text, tokenId: 0, startTime: $0.start, endTime: $0.end, confidence: 1.0)
          },
          sourceSampleCount: consumedSampleCount
      )
  }
  ```
  (`volatileText` empty is guaranteed post-quiesce when finalize succeeded; if finalize
  FAILED — the existing catch in `quiesce()` — a trailing volatile remains and this correctly
  returns nil → one-shot fallback.)
- `StreamingStopArtifact` (in StreamingSession.swift): `struct StreamingStopArtifact:
  Sendable { let text: String; let tokenTimings: [TokenTiming]; let sourceSampleCount: Int }`.
- Protocol addition (StreamingSession.swift): `func stopArtifact() -> StreamingStopArtifact?`;
  the PreviewScheduler extension returns `nil` (its preview text is deliberately NOT save
  quality — no vocab, volatile-window derived).

**6b. RecordingService deposits it — engine-blind, one site only.** In
`tearDownStreamingSession()`, immediately after `await scheduler.quiesce()` (~line 579):

```swift
// D2 promote: hand the session's save-quality artifact (if it can vouch
// for full coverage) to the stop-pass. PreviewScheduler always returns
// nil; a partial (pause-slice) artifact is harmless — its sample count
// can never match the full capture, so the stop-pass ignores it and the
// FINAL slice's deposit (or nil) overwrites it anyway.
await TranscriptionService.shared.depositStreamingArtifact(scheduler.stopArtifact())
```

Deliberately NOT in forceStop/internalStop's detached blocks: those are the messy
interruption paths — their dispatch races the detached quiesce, and the one-shot is the
correct choice there. No other call site.

**6c. TranscriptionService consumes it inside `appleStopPass`:**
- Storage + API (near `useAppleEngine`, ~987):
  ```swift
  private var pendingStreamingArtifact: (artifact: StreamingStopArtifact, depositedAt: Date)?
  func depositStreamingArtifact(_ artifact: StreamingStopArtifact?) {
      pendingStreamingArtifact = artifact.map { ($0, Date()) }
  }
  ```
  (`depositStreamingArtifact(nil)` CLEARS — so every teardown either arms or disarms;
  staleness cannot cross recordings. Belt-and-suspenders: also clear in `makeStreamingSession`
  before constructing a new session.)
- At the top of `appleStopPass(samples:)`:
  ```swift
  if let pending = pendingStreamingArtifact {
      pendingStreamingArtifact = nil
      if pending.artifact.sourceSampleCount == samples.count,
         Date().timeIntervalSince(pending.depositedAt) < 60 {
          log.info("A/B: promoting streaming transcript — coverage exact (\(samples.count) samples), skipping one-shot re-transcribe")
          DiagnosticsLog.record(
              source: "main-app", category: .appleDictationAB,
              message: "Streaming transcript promoted at stop (no re-transcribe)",
              metadata: ["samples": "\(samples.count)", "chars": "\(pending.artifact.text.count)"]
          )
          return ASRResult(
              text: pending.artifact.text, confidence: 1.0,
              duration: Double(samples.count) / 16_000.0,
              processingTime: 0,
              tokenTimings: pending.artifact.tokenTimings
          )
      }
      DiagnosticsLog.record(
          source: "main-app", category: .appleDictationAB,
          message: "Streaming artifact NOT promoted — coverage mismatch, running one-shot",
          metadata: ["artifactSamples": "\(pending.artifact.sourceSampleCount)", "stopSamples": "\(samples.count)"]
      )
  }
  // ... existing one-shot call (5c) ...
  ```
- Everything downstream of `stopPassTranscribe` — vocab merge (timings present ✓),
  provenance, paragraph/filler/number — runs unmodified on the promoted `ASRResult`, exactly
  as it does on the one-shot's synthetic-timing result today.

**What the owner gets:** on the common path (no pause, healthy session), stop is
near-instant regardless of recording length; the two Diagnostics lines make
promoted-vs-fallback visible per dictation. Pause/resume, interruptions, live-text-off, and
any session anomaly transparently keep today's one-shot quality.

**Verify (gate):** V7/V8 pre-gate already passed; then build + V1 + sim; on-device checklist
in CHECKPOINT 2.

---

## Step 7 — M2 (root-cause half): pre-install Apple assets at toggle-flip — `SettingsView.swift`, `TranscriptionService.swift`, `AppleStreamingSession.swift`

The Step-3b cap bounds the damage; the root cause is a network asset install INSIDE a live
recording. Move it to consent time:

- `SettingsView.swift:962-964` (`.onChange(of: useAppleDictationForEnglish)`): on
  `newValue == true`, after writing the AppGroup key, fire a task calling a new
  `TranscriptionService.preinstallAppleAssets()`.
- Extract AppleStreamingSession.swift:68-87 (locale + preset union + transcriber) into
  `static func makeConfiguredTranscriber() -> SpeechTranscriber` on `AppleStreamingSession`;
  `make()` calls it; `preinstallAppleAssets()` calls it then runs the
  `AssetInventory.assetInstallationRequest`/`downloadAndInstall` pair. Errors: log +
  DiagnosticsLog only — the in-session install remains as fallback, now expected to be a
  no-op.
- Settings row subtitle shows "Preparing Apple dictation…" while running (match existing
  Settings download presentation; no new progress UI this cycle).
- Do NOT also fire it from `warmUp()` call sites — keep it consent-shaped; the wizard/
  default-on story is rollout-phase (§Rollout).

**Verify (gate):** build + sim (toggle flips cleanly; airplane-mode flip logs the failure;
recording still works via in-session fallback).

**→ DEVICE CHECKPOINT 2 (main owner verify).** Checklist in §Verification.

---

## Step 8 — docs + registry sync (part of DONE)

- `docs/dictation-engine-rework/design.md`: Status section updated (C1 verified w/ harness
  numbers; H1/H2/M1-M4 fixed; shadow-run retired; D1/D2 recorded as DECIDED with the owner's
  wording; delete open questions 1 and 3). §A gains: "bundle removal REQUIRES the Step-5
  engine containment (done) — the pre-Step-5 stop-pass gated on FluidAudio load and would
  have broken Apple-default dictation." §B gains the D1 two-lines note (14 Pro+ proactive vs
  6GB/12 Pro functional).
- `Jot/known-bugs-and-plans.md`: dual entry for this plan doc.
- `ARCHITECTURE.md`: engine seam is intra-subsystem — expected NO row change; verify the
  Transcription row's entry-point symbols still hold.
- Atlas: verify `ai-engine-apple.html` still matches the Settings row after Step 7's subtitle;
  update + redeploy if visible in the mockup.
- `features.md`: the Labs toggle's description (if present) gains "also drives the live
  preview"; no other user-facing change this cycle.

---

## Verification plan

**Harness (extends the SPM harness that verified C1; runs production
`AppleStreamingSession.swift` verbatim; recordings from `~/Desktop/jot-recordings.csv`):**
- V1 (regression, every step): 6-file streaming pass. Accept: mean WER ≤ 0.07, ≥10
  progressive updates/file, first text ≤ 3s, clean exit ≤ audio length + 10s.
- V2 (tail): last 3 ground-truth words present in `assembledText()` for all files.
- V3 (H1 orphan disposal, gates Step 1): session via `make()`, EOS the queue BEFORE any
  drain (variants: 0s and ~2s pre-pushed audio), then `drain(); quiesce()` → completes < 5s,
  no hang. This is the exact pre-C1 hang shape.
- V4 (pause/resume seam, gates Step 2): front-half → full teardown → new session + prefix →
  back-half → assembled ≈ ground truth, no duplicated seam words.
- V5 (M4): persistent AVAudioConverter at a genuinely different rate (16k→24k), N chunks +
  `.endOfStream` flush → total output ≈ input × ratio (±64). Pure AVFoundation.
- V6 (cap): push >120s with no consumer → backlog ≤ cap, newest retained; attach consumer →
  normal drain.
- V7 (D2 parity, PRE-GATES Step 6): ~15 files, streaming-assembled vs one-shot WER;
  streaming ≤ one-shot + 0.01 absolute AND V2 holds on streaming text.
- V8 (D2 vocab, PRE-GATES Step 6): seeded vocab term + CTC spot + merge against
  streaming-synthesized timings → correction fires on the right span, matching the one-shot
  path on identical audio.

**Simulator:** FluidAudio-path regression end-to-end (start/stop/pause/resume, strip, saved
transcript — stand-in), Settings toggle UX, wizard W6 record+cancel contract, keyboard strip
projections (batch path). Sim does NOT prove the Apple engine — treat any sim Apple result as
anecdote.

**On-device (owner checklists):**
- CHECKPOINT 1 (post Step 3): toggle ON → preview streams while speaking; rapid tap-stop ×10
  right after start (H1 — no stuck "Listening…", no stale text after stop, next recording
  clean); pause → resume (prefix never disappears — M1); stop mid-sentence (last words in the
  saved note).
- ⚠️ CHECKPOINT 2 CAVEAT (Opus review LOW-3): the HAPPY-PATH transcript is byte-identical to
  today on the FluidAudio path, but a FluidAudio prepare/bundle FAILURE now surfaces a nested
  error string ("Transcription failed: Model load failed: …") because the prepare-wait moved
  inside the `do{}` (Step 5b) and gets wrapped by the existing catch. No caller pattern-matches
  these cases (verified — only FeedbackImageEncoder catches `.loadFailed`, a different enum),
  so this is a cosmetic error-message change on a rare failure path only. Note it; do not treat
  it as a regression.
- CHECKPOINT 2 (post Step 7): cold-launch → Apple dictation → stop with NO ~16s stall (H2)
  and Diagnostics shows no FluidAudio prepare on the Apple path; a LONG (2-3 min) dictation
  stops near-instantly with Diagnostics showing "Streaming transcript promoted" (D2);
  a PAUSED-then-resumed dictation stops correctly with Diagnostics showing the coverage-
  mismatch fallback line (D2 gate working); a vocab term dictated on the Apple path still
  corrects (V8 in vivo); toggle OFF → byte-identical to today; airplane-mode first toggle
  flip (graceful — Step 7); keyboard strip never shows "Loading Parakeet…" on the Apple path
  (L4); warm-hold: dictate → stop → warm idle → dictate again, both engines, mixable-idle
  unchanged.

---

## §Rollout (decided-D1 design notes + scheduled debts — NOT this cycle's steps)

**D1 surfaces (owner-decided):**
1. Wizard: on `isProactiveUpgradeOfferEligible` devices (iPhone 14 Pro+ — NEW flag in
   `DeviceCapability`, distinct from `is600MCapable`), the language step offers the
   FluidAudio download ("more accurate, larger download") with Apple as the no-wait default.
2. Settings: the download affordance replaces the Labs toggle, available on ALL ≥6GB/12 Pro
   devices (the functional floor) — broader than the proactive line, per the owner's phrasing.
3. Keyboard nudge: after N dictations on the Apple engine without the upgrade (N≈5, owner
   tune), a one-time keyboard prompt modeled on the vocab-correction UX. Keyboard constraint:
   main app computes eligibility and publishes an App Group flag; the keyboard only renders
   (60MB ceiling, no inference in-process — same split as vocab).
   ⚠️ The two device lines (14 Pro+ proactive vs 6GB functional) must be named in design.md §B
   so nobody later "simplifies" them into one.

**Scheduled debts:** loud Apple-engine failure once Apple is DEFAULT (silent fallback is
A/B-phase-only); `Locale("en-US")` → LanguageChoice threading in both Apple paths + pt-BR
mapping (lands with the 10-language rollout + the Step-5f protocol lift);
`LiveEngineComparisonStore` full removal + `EngineABTestLabView` rename out of Labs;
preview-parity acceptance criteria formalized in design.md (seed from V1/V2/V7 thresholds);
remove the `[PREVIEW-DIAG]` temporary logging once the owner confirms the Apple preview on
device.

## Sequencing summary

| # | Step | Files | Gate |
|---|------|-------|------|
| 1 | H1 generation guard | RecordingService | build + V3 |
| 2 | M1 resume prefix-before-await | RecordingService | build + V4 + sim pause/resume |
| 3 | M4 flush + M2 cap | AppleStreamingSession, StreamingPartial (queue only) | build + V1/V2/V5/V6 |
| — | DEVICE CHECKPOINT 1 | — | owner checklist |
| 4 | Retire live shadow-run | TranscriptionService | build + grep + sim |
| 5 | Stop-pass engine containment + warm inversion | TranscriptionService, RecordingService, StreamingSession | build + sim both toggles + V1 |
| 6 | D2 promote-with-coverage-gate | AppleStreamingSession, StreamingSession, RecordingService, TranscriptionService | V7+V8 PRE-GATE, then build + V1 + sim |
| 7 | Asset pre-install at toggle-flip | SettingsView, TranscriptionService, AppleStreamingSession (helper extract) | build + sim |
| — | DEVICE CHECKPOINT 2 (main verify) | — | owner checklist |
| 8 | Docs/registry/Atlas sync | docs, known-bugs-and-plans, features/ARCHITECTURE check | review |

Steps 1+2 are one edit session (same function), two logical diffs. Step 6 must not start
before Step 5 lands (it extends `appleStopPass`) nor before V7/V8 pass. Every step's revert =
`git checkout -- <its files>` since nothing is committed.

---
END OF PLAN
