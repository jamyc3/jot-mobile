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

    /// Build the persisted speaker turns for a MULTI-speaker result: labels
    /// resolved against the owner centroid, transcript text distributed across
    /// segments by time. The shared builder behind both the manual "Detect
    /// speakers" action (TranscriptDetailView) and the share-import auto-diarize
    /// (PendingShareDrainer), so the two paths can never drift. The labels are
    /// frozen here (at diarization time) into the stored rows — see
    /// `PersistedSpeakerRow`.
    static func persistedRows(
        for result: DiarizationResult,
        transcriptText: String,
        ownerCentroid: [Float]?
    ) -> [PersistedSpeakerRow] {
        let order = firstAppearanceOrder(result.segments)
        let labels = assignOwnerLabel(
            orderedIDs: order,
            speakerDatabase: result.speakerDatabase ?? [:],
            ownerCentroid: ownerCentroid
        )
        // MERGE consecutive same-speaker segments into one TURN before
        // distributing text. VBx emits many short segments (its native
        // resolution, often near word-length) — mapping rows 1:1 onto raw
        // segments produced a "You: Like, / You: you know," word-salad on the
        // first real call-recording test (owner, build 256). A turn is
        // "everything this speaker said until the other one spoke", which is
        // what a human expects to read. Merging FIRST also makes the
        // proportional word split more accurate: fewer boundaries, less
        // rounding drift.
        let turns = mergedTurns(from: result.segments)
        let distributed = distributeText(transcriptText, turns: turns)
        return distributed.compactMap { turn, text in
            // Drop empty turns (a span whose proportional share rounded to
            // zero words) — they rendered as bare "Speaker 2:" lines.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return PersistedSpeakerRow(
                label: displayLabel(for: labels[turn.speakerId]),
                start: turn.start,
                end: turn.end,
                text: trimmed
            )
        }
    }

    /// One conversational turn: consecutive same-speaker segments folded
    /// together. `speechSeconds` sums the SEGMENT durations (actual speech),
    /// not `end - start` — a same-speaker pause shouldn't inflate the turn's
    /// share of the transcript's words.
    struct SpeakerTurn {
        let speakerId: String
        var start: Float
        var end: Float
        var speechSeconds: Double
    }

    /// Fold time-sorted segments into turns: adjacent segments with the same
    /// speaker merge; a speaker change starts a new turn. No smoothing of
    /// genuinely short interjections ("Yeah.") — those are real turns.
    static func mergedTurns(from segments: [TimedSpeakerSegment]) -> [SpeakerTurn] {
        let sorted = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var turns: [SpeakerTurn] = []
        for seg in sorted {
            if var last = turns.last, last.speakerId == seg.speakerId {
                last.end = max(last.end, seg.endTimeSeconds)
                last.speechSeconds += max(0, Double(seg.durationSeconds))
                turns[turns.count - 1] = last
            } else {
                turns.append(SpeakerTurn(
                    speakerId: seg.speakerId,
                    start: seg.startTimeSeconds,
                    end: seg.endTimeSeconds,
                    speechSeconds: max(0, Double(seg.durationSeconds))
                ))
            }
        }
        return turns
    }

    /// Resolved display name for a `SpeakerLabel` — owner → "You", anonymous →
    /// "Speaker N", unknown → "Speaker".
    private static func displayLabel(for label: SpeakerLabel?) -> String {
        switch label {
        case .owner: return "You"
        case .anonymous(let n): return "Speaker \(n)"
        case nil: return "Speaker"
        }
    }

    /// Proportional-by-time text split across merged TURNS — the same fallback
    /// the Mac design uses for engines without token timings ("accurate to
    /// within one word at each boundary. Correct enough to ship."). Shares are
    /// computed from `speechSeconds` (summed segment durations), so silence
    /// inside or between a speaker's segments doesn't steal words. Assumes the
    /// underlying segments are non-overlapping (FluidAudio's default
    /// `exclusiveSegments: true`); turns arrive already time-sorted from
    /// `mergedTurns`.
    static func distributeText(
        _ text: String, turns: [SpeakerTurn]
    ) -> [(turn: SpeakerTurn, text: String)] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty, !turns.isEmpty else { return [] }
        let totalDuration = turns.reduce(0.0) { $0 + $1.speechSeconds }
        guard totalDuration > 0 else { return [] }

        var result: [(SpeakerTurn, String)] = []
        var wordIndex = 0
        for (i, turn) in turns.enumerated() {
            let isLast = i == turns.count - 1
            let share = turn.speechSeconds / totalDuration
            let count = isLast ? words.count - wordIndex : Int((share * Double(words.count)).rounded())
            let end = min(words.count, wordIndex + max(0, count))
            let slice = wordIndex < end ? words[wordIndex..<end].joined(separator: " ") : ""
            result.append((turn, slice))
            wordIndex = end
        }
        return result
    }
}
