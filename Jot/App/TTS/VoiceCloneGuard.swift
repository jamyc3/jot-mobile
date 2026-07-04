import Foundation

/// Blocks creating a voice clone unless the sample's voice matches the
/// device owner's own established voiceprint — reuses the exact machinery
/// built for the Diarization Lab (`DiarizerHolder`, `OwnerVoiceprintStore`,
/// `DiarizationLabeling`), computed fresh from the owner's retained
/// recordings at the moment of cloning (not gated on the separate
/// "Diarization Lab" Settings toggle — this is a safety check, not a lab
/// feature, so it always runs).
///
/// **Hard-block policy (owner's explicit choice, no override):** if the
/// sample doesn't match, OR there isn't yet enough recording history to
/// check, voice cloning refuses outright — no bypass. This deliberately
/// means a brand-new user with no dictation history can't clone a voice
/// until they've used Jot enough to build a voiceprint (≥5 confidently-solo
/// clips within `RetainedAudioStore`'s 3-day window). Accepted tradeoff for
/// a hard safety gate with zero override.
enum VoiceCloneGuard {
    /// Distance ABOVE this is treated as "not a confident match" — looser
    /// than the Diarization Lab's owner-match bar (`DiarizationLabeling.ownerAbsoluteBar`,
    /// 0.35 — tuned for labeling inside a shared recording, where a miss
    /// just falls back to anonymous). Here a false block has real cost (no
    /// override, blocks a legitimate clone outright), so this is
    /// deliberately more permissive. First-pass heuristic from the Mac
    /// feasibility numbers (self ≤0.58 naive / ≤0.18 robust, other ≥0.69) —
    /// needs real-world calibration.
    private static let matchThreshold: Double = 0.5

    enum Verdict {
        case passed
        case blocked(reason: String)
    }

    /// Builds the owner voiceprint if it doesn't exist yet (first call may
    /// take a while — diarizes past retained recordings), then verifies the
    /// sample against it.
    static func verify(sampleURL: URL) async -> Verdict {
        if !OwnerVoiceprintStore.isBuilt {
            await OwnerVoiceprintStore.build()
        }
        guard let centroid = OwnerVoiceprintStore.centroid else {
            return .blocked(reason:
                "Jot can't confirm this is your voice yet — it needs a bit more of your own recording history first. Dictate a few solo notes over the next few days, then come back to clone your voice.")
        }

        do {
            let result = try await DiarizerHolder.shared.diarize(audioFileURL: sampleURL)
            guard let embedding = result.speakerDatabase?.values.first else {
                return .blocked(reason:
                    "Jot couldn't verify this recording. Please record the passage again in a quiet room.")
            }
            let distance = DiarizationLabeling.cosineDistance(embedding, centroid)
            guard distance <= matchThreshold else {
                return .blocked(reason:
                    "This doesn't sound like your voice. Cloning someone else's voice without their explicit permission may be unethical or illegal, and isn't something Jot can help create.")
            }
            return .passed
        } catch {
            return .blocked(reason:
                "Jot couldn't verify this recording (\(error.localizedDescription)). Please try recording again.")
        }
    }
}
