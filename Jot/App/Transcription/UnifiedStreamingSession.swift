import AVFoundation
import FluidAudio
import Foundation
import os.log

/// Live-preview session backed by **Parakeet Unified 0.6B's native streaming
/// encoder** (English, opt-in test backend).
///
/// ## Why this exists — it removes the stop-pass entirely
///
/// The batch path (`UnifiedAsrManager`) re-transcribes the WHOLE recording after
/// the user stops. This one decodes incrementally as the audio arrives, so
/// `finish()` simply flushes the tail and returns the transcript that is already
/// built. Nothing is re-run.
///
/// The app already has the mechanism for this: `stopArtifact()`. Returning a
/// non-nil artifact tells the stop-pass "this session can vouch for the full
/// recording", and the one-shot pass is skipped — the same contract
/// `AppleStreamingSession` uses.
///
/// ## What it buys back
///
/// The batch API returns text only. This one exposes `consumeTokenTimings()`,
/// so on this path Jot regains BOTH timing-dependent features that the batch
/// path silently loses:
///
/// - **paragraph segmentation** (`ParagraphSegmenter` is pause-based)
/// - **the acoustic vocabulary merge** (needs word spans)
///
/// The cost is 2.21% vs 2.15% WER on FluidAudio's LibriSpeech run — roughly one
/// extra error per 1600 words. Paragraphs and an instant stop are worth more.
///
/// ## Latency
///
/// FluidAudio 0.15.4 exposes only the `70_13_13` window: a 1.04 s chunk plus
/// 1.04 s of right context, so partials trail live speech by ~2.08 s. Lower
/// latency encoders (320/640/1120 ms) exist in the HF repo but are not wired
/// into `ParakeetModelVariant`, so selecting one needs a custom download path.
/// Recorded here because it is the one place this path feels worse than the
/// batch pseudo-streaming it replaces.
actor UnifiedStreamingSession: StreamingSession {

    private let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "unified-streaming")

    private let manager: StreamingUnifiedAsrManager
    private let queue: StreamingBufferQueue
    private let presenter: StreamingPartial
    private let sessionID: UUID

    /// Every sample this session consumed. The stop-pass compares it against the
    /// full capture's count and only promotes on an EXACT match, so a partial
    /// session can never masquerade as the whole recording.
    private var consumedSampleCount: Int = 0

    /// Timings accumulated across the whole session. `consumeTokenTimings()`
    /// DRAINS on each call (so the manager's buffer stays bounded over long
    /// streams), which means we must accumulate them here — reading only at
    /// `finish()` would return just the final chunk's worth.
    private var allTimings: [TokenTiming] = []

    /// Set once `finish()` has returned. Until then `stopArtifact()` must yield
    /// nil, because the tail has not been flushed and the transcript is short.
    private var finalText: String?

    /// A decode error means we cannot vouch for the transcript. Latched so
    /// `stopArtifact()` fails closed and the caller runs the normal stop-pass.
    private var failed = false

    init(
        manager: StreamingUnifiedAsrManager,
        queue: StreamingBufferQueue,
        presenter: StreamingPartial,
        sessionID: UUID
    ) {
        self.manager = manager
        self.queue = queue
        self.presenter = presenter
        self.sessionID = sessionID
    }

    // MARK: - StreamingSession

    func drain() async {
        while true {
            switch await queue.popOrEndOfStream() {
            case .samples(let chunk):
                await feed(chunk)
            case .endOfStream:
                return
            }
        }
    }

    func quiesce() async {
        guard !failed else { return }
        do {
            let text = try await manager.finish()
            allTimings.append(contentsOf: await manager.consumeTokenTimings())
            finalText = text
            let presenter = self.presenter
            let sessionID = self.sessionID
            await MainActor.run {
                presenter.update(text: text, isFinal: true, sessionID: sessionID)
            }
            log.info(
                "unified streaming finish — chars=\(text.count, privacy: .public) timings=\(self.allTimings.count, privacy: .public) samples=\(self.consumedSampleCount, privacy: .public)"
            )
        } catch {
            failed = true
            log.error(
                "unified streaming finish FAILED — \(String(describing: error), privacy: .public). Stop-pass will re-transcribe."
            )
        }
    }

    func assembledText() -> String {
        finalText ?? ""
    }

    /// This session drives its own CoreML encoder, not the shared FluidAudio
    /// batch model — so `RecordingService` must not warm that model or mirror its
    /// load state to the keyboard on our behalf.
    nonisolated var usesBatchModel: Bool { false }

    /// Promote to save quality only when the tail was flushed cleanly and we
    /// actually produced text. Anything else returns nil and the caller falls
    /// back to a full transcription — a test backend must never cost a dictation.
    func stopArtifact() -> StreamingStopArtifact? {
        guard !failed, let finalText, !finalText.isEmpty else { return nil }
        return StreamingStopArtifact(
            text: finalText,
            tokenTimings: allTimings,
            sourceSampleCount: consumedSampleCount
        )
    }

    // MARK: - Feeding

    private func feed(_ chunk: [Float]) async {
        guard !failed else { return }
        consumedSampleCount += chunk.count
        guard let buffer = Self.makeBuffer(chunk) else {
            // A buffer we cannot construct is audio we cannot account for, so the
            // sample-count promotion check would be wrong. Fail closed.
            failed = true
            log.error("unified streaming — PCM buffer construction failed; falling back to the stop-pass")
            return
        }
        do {
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
            // Drain timings on every tick, not just at the end: the manager
            // clears its buffer per call by design.
            allTimings.append(contentsOf: await manager.consumeTokenTimings())
            let partial = await manager.getPartialTranscript()
            if !partial.isEmpty {
                let presenter = self.presenter
                let sessionID = self.sessionID
                await MainActor.run {
                    presenter.update(text: partial, isFinal: false, sessionID: sessionID)
                }
            }
        } catch {
            failed = true
            log.error(
                "unified streaming decode FAILED — \(String(describing: error), privacy: .public). Stop-pass will re-transcribe."
            )
        }
    }

    /// Wrap a 16 kHz mono Float32 chunk (what the audio tap produces) in the
    /// `AVAudioPCMBuffer` the manager's `appendAudio` takes. The manager
    /// resamples internally, so the format only has to be declared honestly.
    private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let dst = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
