import FluidAudio
import Foundation

/// Pure-function labeling logic for a `DiarizationResult`, ported from the
/// validated Mac Jot research (`docs/speaker-diarization/design.md`, D3/D7).
/// No enrollment: the device owner is auto-identified from `OwnerVoiceprintStore`'s
/// centroid; everyone else stays anonymous ("Speaker 2", "Speaker 3", …).
enum SpeakerLabel: Equatable {
    case owner
    /// 1-based index in first-appearance order.
    case anonymous(Int)
}

enum DiarizationLabeling {
    // Seed values from the Mac research; not yet calibrated against real
    // (non-synthetic) second speakers on mobile — see design doc Risk R1.
    static let minSecondarySeconds: Double = 5
    static let minSecondaryFraction: Double = 0.05
    static let ownerAbsoluteBar: Double = 0.35
    static let ownerRelativeMargin: Double = 0.15

    /// Dominance-based multi-speaker check (D7): guards against a phantom
    /// sub-threshold cluster (e.g. a ~3s misfire in a long solo recording)
    /// being treated as a real second speaker. Gates on the LARGEST SINGLE
    /// non-dominant speaker, not the sum of all secondaries.
    static func isMultiSpeaker(_ result: DiarizationResult) -> Bool {
        var perSpeakerSeconds: [String: Double] = [:]
        for seg in result.segments {
            perSpeakerSeconds[seg.speakerId, default: 0] += Double(seg.durationSeconds)
        }
        let total = perSpeakerSeconds.values.reduce(0, +)
        guard total > 0, perSpeakerSeconds.count > 1 else { return false }
        let sorted = perSpeakerSeconds.values.sorted(by: >)
        let largestSecondary = sorted.count > 1 ? sorted[1] : 0
        return largestSecondary >= max(minSecondarySeconds, minSecondaryFraction * total)
    }

    /// Speaker IDs in first-appearance (time) order — the natural order for
    /// "Speaker 2", "Speaker 3", … numbering.
    static func firstAppearanceOrder(_ segments: [TimedSpeakerSegment]) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for seg in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            if seen.insert(seg.speakerId).inserted { order.append(seg.speakerId) }
        }
        return order
    }

    /// Scores every speaker's mean embedding against the owner centroid. The
    /// owner is at most ONE speaker and may be absent entirely — an absolute
    /// threshold alone would false-label a similar-voiced second speaker, so
    /// this also requires the best match to be clearly closer than the
    /// second-best. Falls back to all-anonymous when unsure (a wrong "You" is
    /// worse than an anonymous one).
    static func assignOwnerLabel(
        orderedIDs: [String],
        speakerDatabase: [String: [Float]],
        ownerCentroid: [Float]?
    ) -> [String: SpeakerLabel] {
        var result: [String: SpeakerLabel] = [:]
        for (i, id) in orderedIDs.enumerated() { result[id] = .anonymous(i + 1) }
        guard let centroid = ownerCentroid else { return result }

        let scored = orderedIDs.compactMap { id -> (id: String, distance: Double)? in
            guard let embedding = speakerDatabase[id] else { return nil }
            return (id, cosineDistance(embedding, centroid))
        }.sorted { $0.distance < $1.distance }

        guard let best = scored.first else { return result }
        let second = scored.count > 1 ? scored[1].distance : .infinity
        let isOwner = best.distance <= ownerAbsoluteBar && (second - best.distance) >= ownerRelativeMargin
        if isOwner { result[best.id] = .owner }
        return result
    }

    /// Cosine distance (0 = identical, up to 2 = opposite) between raw
    /// embeddings. Simpler than the pipeline's own PLDA-rho scoring (which the
    /// Mac design flags as the more robust choice); raw cosine is what the
    /// Mac feasibility test validated (0.18 self vs 0.82 other) and keeps this
    /// lab prototype's dependency surface small.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return .infinity }
        let cosine = Double(dot) / (Double(normA).squareRoot() * Double(normB).squareRoot())
        return 1 - cosine
    }

    /// Drops embeddings whose mean distance-to-the-rest is an outlier
    /// (> mean + 1σ) before averaging into a centroid — protects the owner
    /// centroid from a "solo" clip that's actually someone else's voice (a
    /// played video, a different speaker on speaker).
    static func medoidTrim(_ embeddings: [[Float]]) -> [[Float]] {
        guard embeddings.count > 2 else { return embeddings }
        var meanDistances: [Double] = []
        for i in embeddings.indices {
            var sum = 0.0
            for j in embeddings.indices where j != i {
                sum += cosineDistance(embeddings[i], embeddings[j])
            }
            meanDistances.append(sum / Double(embeddings.count - 1))
        }
        let mean = meanDistances.reduce(0, +) / Double(meanDistances.count)
        let variance = meanDistances.reduce(0) { $0 + pow($1 - mean, 2) } / Double(meanDistances.count)
        let cutoff = mean + variance.squareRoot()
        return embeddings.indices.filter { meanDistances[$0] <= cutoff }.map { embeddings[$0] }
    }

    /// Proportional-by-time text split across segments — the same fallback
    /// the Mac design uses for engines without token timings ("accurate to
    /// within one word at each boundary. Correct enough to ship."). Assumes
    /// segments are already non-overlapping (FluidAudio's default
    /// `exclusiveSegments: true`).
    static func distributeText(
        _ text: String, segments: [TimedSpeakerSegment]
    ) -> [(segment: TimedSpeakerSegment, text: String)] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty, !segments.isEmpty else { return [] }
        let sorted = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        let totalDuration = sorted.reduce(0.0) { $0 + max(0, Double($1.durationSeconds)) }
        guard totalDuration > 0 else { return [] }

        var result: [(TimedSpeakerSegment, String)] = []
        var wordIndex = 0
        for (i, seg) in sorted.enumerated() {
            let isLast = i == sorted.count - 1
            let share = Double(seg.durationSeconds) / totalDuration
            let count = isLast ? words.count - wordIndex : Int((share * Double(words.count)).rounded())
            let end = min(words.count, wordIndex + max(0, count))
            let slice = wordIndex < end ? words[wordIndex..<end].joined(separator: " ") : ""
            result.append((seg, slice))
            wordIndex = end
        }
        return result
    }
}
