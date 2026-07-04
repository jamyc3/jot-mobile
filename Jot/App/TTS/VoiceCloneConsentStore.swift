import Foundation

/// On-device-only record of each voice-clone consent acknowledgment — never
/// transmitted anywhere (same "nothing leaves except feedback" posture as
/// the rest of Jot; see `project_only_outbound_is_feedback` for the standing
/// invariant). Exists purely so there's a durable, user-inspectable record
/// that the disclaimer was shown and explicitly accepted at the moment each
/// clone was created — a legal/liability safeguard, not a technical one
/// (pairs with `VoiceCloneGuard`'s voiceprint check, which is the technical
/// safeguard and is not 100% — this is the paper trail for when it isn't).
enum VoiceCloneConsentStore {
    struct Record: Codable, Identifiable {
        let id: UUID
        let voiceName: String
        let acceptedAt: Date
        /// The EXACT disclaimer text shown at acceptance time — if the copy
        /// ever changes later, historical records still show what was
        /// actually agreed to, not the current wording.
        let disclaimerText: String
    }

    private static let key = "jot.tts.voiceCloneConsentRecords"

    static var records: [Record] {
        guard let data = AppGroup.defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        return decoded.sorted { $0.acceptedAt > $1.acceptedAt }
    }

    static func record(voiceName: String, disclaimerText: String) {
        var current = records
        current.append(Record(id: UUID(), voiceName: voiceName, acceptedAt: Date(), disclaimerText: disclaimerText))
        guard let data = try? JSONEncoder().encode(current) else { return }
        AppGroup.defaults.set(data, forKey: key)
    }
}
