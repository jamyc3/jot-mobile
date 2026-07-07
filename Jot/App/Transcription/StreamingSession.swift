import FluidAudio
import Foundation

/// Save-quality artifact a streaming session hands to the stop-pass at
/// teardown (D2 promote, docs/dictation-engine-rework/implementation-plan.md
/// Step 6). `sourceSampleCount` is the number of source samples this session
/// consumed — the stop-pass compares it against the full capture's sample
/// count and only promotes `text`/`tokenTimings` on an EXACT match, so a
/// partial (pause-slice, dropped-chunk, or otherwise incomplete) session can
/// never be mistaken for the full recording's transcript.
struct StreamingStopArtifact: Sendable {
    let text: String
    let tokenTimings: [TokenTiming]
    let sourceSampleCount: Int
}

/// A live-preview transcription session for one recording slice. `RecordingService`
/// talks to whichever concrete engine is active ONLY through this contract — it
/// never knows whether FluidAudio or Apple's `SpeechAnalyzer` is actually running.
/// `TranscriptionService.makeStreamingSession` decides which concrete type to
/// construct; see `docs/dictation-engine-rework/design.md`.
///
/// Two conformers:
/// - `PreviewScheduler` — FluidAudio's batch pseudo-streaming
///   (`docs/plans/batch-only-streaming.md`), unchanged.
/// - `AppleStreamingSession` — a persistent `SpeechAnalyzer`/`SpeechTranscriber`
///   session consuming Apple's own native volatile/finalized results.
protocol StreamingSession: Actor {
    /// Runs until the queue signals end-of-stream (recording stop). Implementations
    /// must call `presenter.update(text:isFinal:sessionID:)` as better text becomes
    /// available and end the underlying engine's input sequence before returning.
    func drain() async

    /// Blocks until any in-flight work settles (a pending inference tick, or the
    /// engine's own finalize pass). Callers MUST call this after `drain()` returns
    /// and before `assembledText()` — otherwise a still-settling result can race
    /// the read and silently drop the last few words.
    func quiesce() async

    /// The best-known transcript for this session, read after `quiesce()`.
    func assembledText() -> String

    /// Whether this session's preview inference rides the FluidAudio batch
    /// model (and therefore wants warmUp() + the keyboard's model-loading
    /// affordance). Capability flag, not an identity check — RecordingService
    /// stays engine-blind.
    nonisolated var usesBatchModel: Bool { get }

    /// Save-quality artifact for the stop-pass (D2, Step 6), valid only after
    /// `quiesce()` has returned. `nil` means this session cannot vouch for a
    /// complete, fully-finalized transcript — the caller must run the
    /// one-shot pass instead.
    func stopArtifact() -> StreamingStopArtifact?
}

extension PreviewScheduler: StreamingSession {
    nonisolated var usesBatchModel: Bool { true }

    /// FluidAudio's preview text is deliberately NOT save quality — it is a
    /// re-transcribed trailing overlap window with no vocabulary boost, not
    /// the full-recording transcript. Never promotable.
    func stopArtifact() -> StreamingStopArtifact? { nil }
}

/// Null preview session — no live text, and NO cross-engine fallback. Used when
/// the Apple streaming session fails to start on an Apple-selected recording: we
/// do NOT silently drop to FluidAudio's preview (owner directive — Apple-selected
/// means Apple, never a Parakeet swap). The recording still captures audio and the
/// stop-pass produces the transcript (or fails honestly); the user just gets no
/// live preview for that recording rather than a wrong-engine one.
actor NoPreviewSession: StreamingSession {
    func drain() async {}
    func quiesce() async {}
    func assembledText() -> String { "" }
    nonisolated var usesBatchModel: Bool { false }
    func stopArtifact() -> StreamingStopArtifact? { nil }
}
