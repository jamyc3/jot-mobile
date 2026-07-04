import Foundation
import OSLog

/// Builds and persists the device owner's voice "centroid" — a mean embedding
/// derived from the user's own past SOLO recordings, with no enrollment step —
/// used to auto-label the owner as "You" in a diarized recording.
///
/// Ported from the validated Mac Jot research (`docs/speaker-diarization/design.md`,
/// D3 + the owner-auto-ID feasibility study: 0.18 self-distance vs 0.82 to a
/// different voice, a 0.64 separation gap). **Scope narrowing vs the Mac
/// design:** that design assumed an unbounded recording library; mobile Jot
/// only retains source audio for `RetainedAudioStore.retentionDays` (3 days),
/// so the candidate pool here is whatever solo recordings still have retained
/// audio — not the full history. If fewer than `minClips` solo clips are
/// available, the voiceprint simply isn't built and every speaker renders
/// anonymous (the feature still works, just without the "You" nicety).
enum OwnerVoiceprintStore {
    private static let defaultsKey = "jot.diarization.ownerVoiceprint"
    private static let minClips = 5
    private static let maxCandidates = 40

    private struct Payload: Codable {
        let centroid: [Float]
        let builtFromCount: Int
        let builtAt: Date
    }

    private static var cached: Payload? {
        get {
            guard let data = AppGroup.defaults.data(forKey: defaultsKey) else { return nil }
            return try? JSONDecoder().decode(Payload.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                AppGroup.defaults.removeObject(forKey: defaultsKey)
                return
            }
            AppGroup.defaults.set(data, forKey: defaultsKey)
        }
    }

    static var centroid: [Float]? { cached?.centroid }
    static var builtFromCount: Int { cached?.builtFromCount ?? 0 }
    static var builtAt: Date? { cached?.builtAt }
    static var isBuilt: Bool { cached != nil }

    private static let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "OwnerVoiceprint")

    /// Scans recently-retained recordings for solo clips, diarizes each, and
    /// builds a robust (medoid-trimmed) centroid. Low-priority and
    /// cooperative — backs off for a beat whenever a live transcription is in
    /// flight rather than contending with it (see `DiarizerHolder`'s BNNS
    /// concurrency caveat). Safe to call repeatedly (e.g. a manual "Rebuild"
    /// tap); simply overwrites the prior centroid on success.
    static func build(progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil) async {
        let ids = Array(RetainedAudioStore.allRetainedIDs().prefix(maxCandidates))
        var embeddings: [[Float]] = []
        for (i, id) in ids.enumerated() {
            await progress?(i + 1, ids.count)
            while await TranscriptionService.shared.isBusy {
                try? await Task.sleep(for: .seconds(1))
            }
            guard let url = RetainedAudioStore.url(for: id) else { continue }
            do {
                let result = try await DiarizerHolder.shared.diarize(audioFileURL: url)
                guard !DiarizationLabeling.isMultiSpeaker(result),
                      let db = result.speakerDatabase,
                      let embedding = db.values.first
                else { continue }
                embeddings.append(embedding)
            } catch {
                log.debug("voiceprint candidate skipped: \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
        guard embeddings.count >= minClips else {
            log.info("owner voiceprint: only \(embeddings.count) solo clip(s) (need \(minClips)) — staying anonymous-only")
            return
        }
        let kept = DiarizationLabeling.medoidTrim(embeddings)
        guard let centroid = averageNormalized(kept) else { return }
        cached = Payload(centroid: centroid, builtFromCount: kept.count, builtAt: Date())
        log.info("owner voiceprint built from \(kept.count) clip(s)")
    }

    private static func averageNormalized(_ embeddings: [[Float]]) -> [Float]? {
        guard let dim = embeddings.first?.count, dim > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dim)
        for e in embeddings {
            for i in 0..<dim { sum[i] += e[i] }
        }
        let mean = sum.map { $0 / Float(embeddings.count) }
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return mean }
        return mean.map { $0 / norm }
    }
}
