import Foundation
import JotVocabCore

/// **Publishes the keyboard's correction asks after a saved dictation.**
/// Reads the just-committed provenance, runs the shared decision core
/// (`JotVocabCore.AskPolicy` — ≤3 proposals, only those worth asking:
/// applied corrections, mappings part-way to automatic, or the one-shot
/// merge-teach lane; closest-to-automatic first), attaches a short spoken-
/// context snippet per ask, and hands them to `CorrectionBridge` for the
/// keyboard to read. Asks decay to zero as the system learns.
///
/// This type is now the app-side PLUMBING shell (design §1: decide in core,
/// spend in plumbing). The decision logic lives in `AskPolicy`; what stays
/// here is everything that touches a process boundary — slicing context
/// snippets out of `publishedText`, serializing into `CorrectionBridge.Ask`,
/// and *spending* the merge-teach one-shot (`CorrectionStore.noteMergeAsked`)
/// after publish.
enum CorrectionAsksPublisher {
    static let contextWindow = 24

    /// Stages the keyboard asks into the App Group and (when `signalReady`) posts
    /// `correctionAsksReady`. Returns whether any asks were published. For
    /// ask-before-paste the pipeline calls this with `signalReady: false` BEFORE the
    /// clipboard handoff (so the keyboard can read asks synchronously at flush), then
    /// posts the ready signal itself AFTER the handoff (never before the paste).
    @discardableResult
    static func publish(transcriptID: UUID, sessionID: UUID, publishedText: String,
                        signalReady: Bool = true) async -> Bool {
        // MAPPED read (ephemeral): record anchors are gate-output offsets, but
        // the context snippets below slice `publishedText`, which post-gate
        // transforms (segmenter/filler/number/cleanup) may have shifted — map
        // every anchor into publishedText exactly. Deliberately NOT the
        // persisting `reconciledPayload`: publishedText can be the AI-cleaned
        // text, and persisting that hop would strand anchors whose words the
        // cleanup rewrote away (the saved transcript still has them).
        let payload = await CorrectionProvenance.shared.mappedPayload(
            transcriptID: transcriptID, into: publishedText)
        let unresolved = payload.records.filter { payload.verdicts[$0.key] == nil }
        guard !unresolved.isEmpty else {
            CorrectionBridge.clearAsks()
            return false
        }

        // Shared decision core. `AskPolicy.select` derives `prior` and the
        // always-replace `granted` exclusion from `overrides` itself, applies
        // the keyboard-suppression / merge-teach one-shot / mixed-payload rules,
        // ranks closest-to-automatic first, and caps at `AskPolicy.maxAsks`.
        // Pairs the owner has rejected (kept ≥ threshold) or "Stop asking"-ed
        // are keyboard-only suppression — the transcript review reads neither.
        let overrides = await CorrectionStore.shared.snapshot()
        let keyboardSuppressed = await CorrectionStore.shared.keyboardSuppressedPairs()
        let mergeAsked = await CorrectionStore.shared.mergeAskedPairs()
        let selections = AskPolicy.select(
            unresolved: unresolved,
            overrides: overrides,
            keyboardSuppressed: keyboardSuppressed,
            mergeAsked: mergeAsked)

        var asks: [CorrectionBridge.Ask] = []
        for selection in selections {
            let r = selection.record
            let (before, after) = context(of: r, in: publishedText)
            // 3-option ask: the selected alternate rides on the Selection
            // (`altTerm`/`altFind`) so we don't re-derive it — the keyboard card
            // caps at 3 buttons (original, term, one alternate).
            asks.append(CorrectionBridge.Ask(
                recordKey: r.key, original: r.originalWord, term: r.term,
                outcome: r.outcome, contextBefore: before, contextAfter: after,
                publishedStart: r.publishedStart, publishedLength: r.publishedLength,
                altTerm: selection.altTerm, altFind: selection.altFind,
                postPasteOnly: selection.isMergeTeach ? true : nil))
            if selection.isMergeTeach {
                // Decide-in-core / spend-in-plumbing: AskPolicy MARKED this as
                // the one-shot merge-teach card; the app spends its single shot
                // here at PUBLISH time (adjudicated or not — bounded fatigue).
                await CorrectionStore.shared.noteMergeAsked(
                    originalWord: r.originalWord, term: r.term)
            }
        }
        guard !asks.isEmpty else {
            CorrectionBridge.clearAsks()
            return false
        }
        CorrectionBridge.publishAsks(
            CorrectionBridge.Asks(
                sessionID: sessionID, transcriptID: transcriptID, asks: Array(asks),
                // ALL unresolved proposals on the transcript (not just the ≤3
                // surfaced asks) — drives the keyboard "Done" stage's "N more
                // guesses are on the transcript in Jot." line.
                totalUnresolved: unresolved.count))
        // Signal the keyboard that the asks exist. For ask-before-paste the caller
        // stages with `signalReady: false` and posts this itself AFTER the handoff,
        // so the ready signal can never precede the paste it gates.
        if signalReady {
            CrossProcessNotification.post(name: CrossProcessNotification.correctionAsksReady)
        }
        DiagnosticsLog.record(
            source: "main-app", category: .vocabularyGate, message: "keyboard asks published",
            metadata: ["asks": "\(asks.count)", "unresolved": "\(unresolved.count)",
                       "session": sessionID.uuidString, "signalReady": "\(signalReady)"])
        return true
    }

    /// ~`contextWindow` chars on each side of the published span (ellipsized).
    private static func context(of r: CorrectionProvenance.Record, in text: String) -> (String, String) {
        let chars = Array(text)
        let n = chars.count
        let start = max(0, min(r.publishedStart, n))
        let end = max(start, min(r.publishedStart + r.publishedLength, n))
        let beforeStart = max(0, start - contextWindow)
        let afterEnd = min(n, end + contextWindow)
        var before = String(chars[beforeStart..<start])
        var after = String(chars[end..<afterEnd])
        if beforeStart > 0 { before = "…" + before }
        if afterEnd < n { after += "…" }
        return (before, after)
    }
}
