import Foundation
import Observation

@MainActor
@Observable
final class KeyboardRewriteRouter {
    var pendingTarget: KeyboardRewriteTarget?

    /// Set by `JotApp.onOpenURL` when the keyboard taps the row-trailing
    /// affordance on a recents row. ContentView observes this and pushes the
    /// target onto its NavigationPath via
    /// `.navigationDestination(for: OpenTranscriptTarget.self)`. Distinct from
    /// `pendingTarget` (the rewrite-HANDOFF path, where the keyboard already
    /// picked a prompt and is waiting on a pasteback): here the user is simply
    /// being taken to the transcript, optionally with the rewrite flow started.
    var pendingOpenTranscript: OpenTranscriptTarget?

    /// A transcript the keyboard asked the app to open.
    ///
    /// `writingTools` carries the recents row's Apple Intelligence tap
    /// (`jot://transcript?id=…&ai=1`): the detail view opens and immediately
    /// runs its own Rewrite action, so on Apple Intelligence the transcript
    /// arrives already selected for system Writing Tools (features.md §5.2 /
    /// §7.10). False = plain open (kept for any non-AI caller).
    struct OpenTranscriptTarget: Identifiable, Hashable {
        let id: UUID
        let writingTools: Bool
    }

    struct KeyboardRewriteTarget: Identifiable, Hashable, Equatable {
        let id: UUID
        let sessionID: UUID
        let jobID: UUID
        let promptID: UUID
        let selectionLength: Int
    }

    func setPending(_ target: KeyboardRewriteTarget) {
        pendingTarget = target
    }

    func consumePending() -> KeyboardRewriteTarget? {
        let target = pendingTarget
        pendingTarget = nil
        return target
    }

    func setPendingOpenTranscript(id: UUID, writingTools: Bool) {
        pendingOpenTranscript = OpenTranscriptTarget(id: id, writingTools: writingTools)
    }

    func consumePendingOpenTranscript() -> OpenTranscriptTarget? {
        let target = pendingOpenTranscript
        pendingOpenTranscript = nil
        return target
    }
}
