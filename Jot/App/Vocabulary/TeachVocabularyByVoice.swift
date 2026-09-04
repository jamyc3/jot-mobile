import Foundation
import JotVocabCore
import Observation
import OSLog
import SwiftUI

struct VocabularyTeachingTake: Identifiable, Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case transcript(String)
        case failure(String)
    }

    let id: UUID
    let payload: Payload

    init(id: UUID = UUID(), payload: Payload) {
        self.id = id
        self.payload = payload
    }
}

/// One take, as the sheet reports it back.
///
/// There is deliberately no verdict here. `Note` says what Jot will DO with the
/// take (learn it, or already have it), never whether the take was good — the
/// user is the only judge of that, and is the one who deletes a take that was a
/// cough or the wrong word. Build 296 shipped a verdict taxonomy here, graded
/// takes with it, and got the grades backwards; this type is the fix.
struct VocabularyTeachingResult: Identifiable, Equatable, Sendable {
    enum Note: Equatable, Sendable {
        /// A distinct hearing — kept as a sounds-like unless the user deletes it.
        case stored
        /// Jot heard the term itself. Informational: nothing new to learn.
        case matches
        /// Already in the term's sounds-like list.
        case duplicate
        case nothingHeard
        /// Heard something, but nothing survives the vocabulary file's
        /// structural sanitizing (or normalizes to an empty key) — a fact about
        /// storage, not about the take.
        case nothingToLearn
        case failed(String)
    }

    let id: UUID
    /// The recognizer's output is never rewritten for display or replay.
    let rawTranscript: String?
    let note: Note
}

struct VocabularyTeachingState: Equatable, Sendable {
    let takeCount: Int
    let provisionalAliases: [String]
    let results: [VocabularyTeachingResult]
}

/// Immutable dependencies for one replay. Keeping them outside capture state
/// makes deleting a take equivalent to evaluating the surviving raw inputs
/// again from the beginning.
struct VocabularyTeachingContext: Sendable {
    let termText: String
    let existingAliases: [String]
}

enum VocabularyTeachingReducer {
    /// Every distinct hearing that isn't the term itself is a candidate
    /// sounds-like, KEPT BY DEFAULT. Jot doesn't decide which hearings are
    /// worth keeping — repetition is how a mishearing gets learned, and the
    /// per-take delete is how the user removes one that wasn't speech.
    static func replay(
        takes: [VocabularyTeachingTake],
        takeCount: Int,
        context: VocabularyTeachingContext
    ) -> VocabularyTeachingState {
        var provisionalAliases: [String] = []
        var results: [VocabularyTeachingResult] = []
        let termKey = CorrectionKey.normalize(context.termText)
        var knownAliasKeys = Set(context.existingAliases.map(CorrectionKey.normalize))

        for take in takes {
            switch take.payload {
            case .failure(let message):
                results.append(VocabularyTeachingResult(
                    id: take.id, rawTranscript: nil, note: .failed(message)
                ))

            case .transcript(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    results.append(VocabularyTeachingResult(
                        id: take.id, rawTranscript: raw, note: .nothingHeard
                    ))
                    continue
                }

                // The simple file format has structural characters, and the
                // correction key trims outer punctuation — a take of ":" or
                // "..." survives neither. Excluded BEFORE the term comparison so
                // an unstorable take is never reported as matching the term, and
                // so an empty key can't be inserted as an alias (it would then
                // dedupe against every other unstorable take).
                let candidate = VocabularyStore.fileSafeAlias(raw)
                let candidateKey = CorrectionKey.normalize(candidate)
                guard !candidate.isEmpty, !candidateKey.isEmpty else {
                    results.append(VocabularyTeachingResult(
                        id: take.id, rawTranscript: raw, note: .nothingToLearn
                    ))
                    continue
                }
                guard candidateKey != termKey else {
                    results.append(VocabularyTeachingResult(
                        id: take.id, rawTranscript: raw, note: .matches
                    ))
                    continue
                }

                guard knownAliasKeys.insert(candidateKey).inserted else {
                    results.append(VocabularyTeachingResult(
                        id: take.id, rawTranscript: raw, note: .duplicate
                    ))
                    continue
                }

                provisionalAliases.append(candidate)
                results.append(VocabularyTeachingResult(
                    id: take.id, rawTranscript: raw, note: .stored
                ))
            }
        }

        return VocabularyTeachingState(
            takeCount: takeCount,
            provisionalAliases: provisionalAliases,
            results: results
        )
    }
}

/// The two halves of the sheet. Phase 1 stays re-enterable — a sentence result
/// is kept while the user records more takes and is re-run, not discarded,
/// because re-entering phase 2 re-persists the (possibly changed) alias set
/// before recording again.
enum VocabularyTeachingPhase: Equatable, Sendable {
    case takes
    case sentence
}

/// What the sentence test found, plus the text it found it in. `gatedText` is
/// kept because the number pass and the filler sweep rewrite the published text
/// after the gate — an alias learned from a tapped span has to be checked
/// against the pre-cleanup text or Jot can learn a word the user never said.
struct VocabularyTeachingSentence: Equatable, Sendable {
    let text: String
    let gatedText: String
    /// Forward map of every `gatedText` character offset into `text`, so a span
    /// the user taps can be traced back to the words that produced it.
    let gatedToFinal: [Int]
    let result: TeachSentenceLocator.Result
}

/// The user's own reading of a sentence run. Deliberately NOT a boolean:
/// "I confirm this" and "nothing here matched" are different answers, and
/// collapsing them made Jot congratulate the user on a result they had just
/// rejected.
enum VocabularyTeachingVerdict: Equatable, Sendable {
    case unanswered
    case confirmed
    case nothingMatched
    /// The user pointed at the words Jot got wrong and they were learned. A
    /// state of its own because the generic not-found line reads as "nothing
    /// happened" at exactly the moment something did.
    case learned(String)
}

@MainActor
@Observable
final class VocabularyTeachingSession {
    private(set) var state: VocabularyTeachingState
    private(set) var phase: VocabularyTeachingPhase = .takes
    private(set) var sentence: VocabularyTeachingSentence?
    /// The user is picking the words Jot should have written as the term.
    private(set) var isCorrecting = false
    /// Indices into `TeachSentenceLocator.words(in:)` of the sentence.
    private(set) var selectedWords: Set<Int> = []
    /// The user's answer to the sentence run — encouragement, never a gate.
    private(set) var verdict: VocabularyTeachingVerdict = .unanswered
    private(set) var isStarting = false
    private(set) var isCapturing = false
    private(set) var isTranscribing = false
    private(set) var isPreparingVocabulary = false
    private(set) var isTearingDown = false

    /// Set the moment the sheet starts going away, BEFORE any of `stopGently`'s
    /// early-returns. Load-bearing: the Record button queues `startTake()` in an
    /// UNSTRUCTURED `Task`, so dismissal can win the scheduling race and run
    /// `stopGently` while `ownsCapture` is still false — its `guard ownsCapture`
    /// then returns without tearing anything down, and the queued task would go
    /// on to claim `ownsActiveRecording` and start the mic on a dead sheet. That
    /// leaks a zombie capture and wedges ownership APP-WIDE, not just here.
    private var hasDismissed = false
    private(set) var transientError: String?

    let termID: VocabTerm.ID
    let termText: String

    private let existingAliases: [String]
    private let recording: RecordingService
    private let streamingPartial: StreamingPartial
    private var takes: [VocabularyTeachingTake] = []
    private var takeCount = 0
    private var startTask: Task<Bool, Never>?
    private var startToken: UUID?
    private var ownsCapture = false
    /// Sounds-like forms learned from the user tapping the words Jot got wrong.
    private var correctedAliases: [String] = []
    /// The term's alias list as it stood before phase 2 persisted anything —
    /// the rollback target on Cancel, and the base Save merges onto so a take
    /// deleted after phase 2 doesn't survive as a persisted alias. `nil` until
    /// the first entry into phase 2, i.e. until anything has been persisted.
    private var preTeachAliases: [String]?
    /// What the last persist actually wrote, so a re-record that changes nothing
    /// doesn't pay for another CoreML rescorer build.
    private var lastPersistedAliases: [String]?
    private var didSave = false

    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "vocabulary-voice-teaching"
    )

    init(term: VocabTerm, recording: RecordingService, streamingPartial: StreamingPartial) {
        termID = term.id
        termText = term.text
        existingAliases = term.aliases
        self.recording = recording
        self.streamingPartial = streamingPartial
        state = VocabularyTeachingState(takeCount: 0, provisionalAliases: [], results: [])
    }

    var canRecord: Bool {
        !hasDismissed && !isStarting && !isCapturing && !isTranscribing
            && !isPreparingVocabulary && !isTearingDown
    }

    var isBusy: Bool {
        isStarting || isCapturing || isTranscribing || isPreparingVocabulary || isTearingDown
    }

    /// Is there anything a dismissal would throw away? Drives the swipe-down
    /// confirmation: a session with recordings in it is minutes of the user's
    /// speech, and a sheet that vanishes on an accidental swipe takes all of it
    /// with no way back.
    var hasWorkToLose: Bool {
        !state.results.isEmpty || sentence != nil || !correctedAliases.isEmpty
    }

    /// The sentence test is offered once there is more than one usable take to
    /// learn from — one take teaches Jot a form, two make it a pattern worth
    /// testing in context.
    var maySayASentence: Bool {
        state.results.filter {
            switch $0.note {
            case .stored, .matches, .duplicate: true
            case .nothingToLearn, .nothingHeard, .failed: false
            }
        }.count >= 2
    }

    // MARK: - Capture (shared by both phases)

    func startTake() async {
        // The sheet is already leaving; never claim the mic on its way out.
        // Silent by design: there is no longer any UI to show an error in.
        guard !hasDismissed else { return }
        guard canRecord, !recording.isRecording, !recording.isPipelineInFlight else {
            transientError = "The microphone is busy. Finish the other recording and try again."
            return
        }
        transientError = nil
        isStarting = true
        // Claiming ownership also exempts this capture from the live-text
        // preview gate, which is how a teach recording could end up on a
        // DIFFERENT engine than the user's real dictations — the exact opposite
        // of what phase 2 promises. It doesn't, because
        // `UnifiedEnglishModel.isOfferedForCurrentLanguage` requires
        // `DeviceCapability.liveTextEnabled` in its own right. Drop that clause
        // and this sheet starts validating on an engine the user never dictates
        // with; see ARCHITECTURE.md's `ownsActiveRecording` bullet.
        recording.ownsActiveRecording = true
        ownsCapture = true
        log.notice("RECORDING START FROM: VocabularyTeachingSheet")
        let token = UUID()
        startToken = token
        let task = Task { @MainActor () -> Bool in
            do {
                try await recording.start()
                return true
            } catch {
                self.log.error("vocabulary teaching start failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        startTask = task
        let started = await task.value
        // Dismissal may have claimed this in-flight start for gentle teardown.
        // In that case its terminal Task owns all cleanup and this continuation
        // must not resurrect the capture after the sheet has gone away.
        guard startToken == token else { return }
        startToken = nil
        startTask = nil
        isStarting = false
        if started {
            isCapturing = true
        } else {
            recording.ownsActiveRecording = false
            ownsCapture = false
            transientError = "Jot couldn't start the microphone. Try again."
        }
    }

    func finishTake() async {
        guard isCapturing else { return }
        // Count every physical capture before either await so a successful-start
        // Stop tap is never lost to cancellation or a failing recorder tail.
        if phase == .takes { takeCount += 1 }
        isCapturing = false
        isTranscribing = true
        transientError = nil
        let pending = startTask
        startTask = nil
        startToken = nil
        _ = await pending?.value

        do {
            let samples = try await recording.stop()
            finishRecorderTail()
            switch phase {
            case .takes: await transcribeTake(samples: samples)
            case .sentence: await transcribeSentence(samples: samples)
            }
        } catch {
            finishRecorderTail()
            log.error("vocabulary teaching stop failed: \(error.localizedDescription, privacy: .public)")
            if phase == .takes {
                takes.append(VocabularyTeachingTake(payload: .failure("Jot couldn't finish that take. Try again.")))
                replay()
            } else {
                transientError = "Jot couldn't finish that recording. Try the sentence again."
            }
        }

        isTranscribing = false
    }

    /// Phase 1 wants the selected recognizer's OWN words — what Jot hears with
    /// no vocabulary applied is exactly the mishearing being taught.
    private func transcribeTake(samples: [Float]) async {
        do {
            let raw = try await TranscriptionService.shared.transcribeWithoutVocabulary(samples: samples)
            takes.append(VocabularyTeachingTake(payload: .transcript(raw)))
        } catch {
            log.error("vocabulary teaching transcription failed: \(error.localizedDescription, privacy: .public)")
            takes.append(VocabularyTeachingTake(payload: .failure(Self.takeFailureMessage(error))))
        }
        replay()
    }

    /// Phase 2 runs the REAL pipeline — same engine routing, filler strip,
    /// number pass, punctuation model and the full vocabulary apply, including
    /// the provisional aliases this sheet persisted on the way in. "As if I hit
    /// record somewhere else." Nothing is saved: transcript saving, provenance
    /// commit and keyboard ask publication all live in `DictationPipeline`,
    /// which this sheet never enters.
    private func transcribeSentence(samples: [Float]) async {
        isCorrecting = false
        selectedWords = []
        verdict = .unanswered
        do {
            let output = try await TranscriptionService.shared.transcribeWithProposals(samples: samples)
            let gatedToFinal = Self.gatedToFinalMap(from: output)
            let located = TeachSentenceLocator.locate(
                term: termText,
                in: output.text,
                proposals: Self.locatorProposals(from: output, gatedToFinal: gatedToFinal)
            )
            sentence = VocabularyTeachingSentence(
                text: output.text,
                gatedText: output.gatedText,
                gatedToFinal: gatedToFinal,
                result: located
            )
            // Nothing to confirm when the term is nowhere in the sentence — go
            // straight to "tap the words that should have been <term>".
            if case .notFound = located { isCorrecting = true }
            log.notice(
                "teaching sentence located — proposals=\(output.proposals.count, privacy: .public) outcome=\(Self.outcomeLabel(located), privacy: .public)"
            )
            // The owner's device pass is the only way this feature gets
            // verified, so the outcome has to be readable from Help →
            // Diagnostics afterwards rather than only from a live Console.
            DiagnosticsLog.record(
                source: "main-app",
                category: .vocabularyGate,
                message: "teaching sentence outcome",
                metadata: [
                    "outcome": Self.outcomeLabel(located),
                    "proposals": "\(output.proposals.count)",
                    "forThisTerm": "\(Self.locatorProposals(from: output, gatedToFinal: gatedToFinal).filter { CorrectionKey.normalize($0.term) == CorrectionKey.normalize(termText) }.count)",
                    "spans": "\(Self.spanCount(located))",
                    "textDrifted": "\(output.gatedText != output.text)",
                    "chars": "\(output.text.count)",
                ]
            )
        } catch {
            sentence = nil
            log.error("vocabulary teaching sentence failed: \(error.localizedDescription, privacy: .public)")
            transientError = Self.sentenceFailureMessage(error)
        }
    }

    func deleteTake(id: UUID) {
        guard !isBusy else { return }
        takes.removeAll { $0.id == id }
        replay()
    }

    // MARK: - Phase 2

    /// Persist the provisional aliases and WAIT for the rescorer to be rebuilt
    /// around them before offering to record.
    ///
    /// Persist-then-rollback is the seam because the two vocabulary paths read
    /// different sources — the model-free corrector reads the store in memory,
    /// the acoustic path reads the file on disk — so an in-memory overlay would
    /// test only half the pipeline. The await matters just as much: the rebuild
    /// is a CoreML build, and recording before it lands would test the
    /// vocabulary this sheet just replaced and report a failure Jot caused.
    func beginSentencePhase() async {
        guard !isBusy else { return }
        transientError = nil
        guard await persistProvisionalAliases() else { return }
        phase = .sentence
    }

    /// Writes everything the session has learned so far and WAITS for the
    /// rescorer to be rebuilt around it.
    ///
    /// Persist-then-rollback is the seam because the two vocabulary paths read
    /// different sources — the model-free corrector reads the store in memory,
    /// the acoustic path reads the file on disk — so an in-memory overlay would
    /// test only half the pipeline. The await matters just as much: the rebuild
    /// is a CoreML build, and recording before it lands would test the
    /// vocabulary this sheet just replaced and report a failure Jot caused.
    ///
    /// Called before EVERY sentence recording, not just on entering phase 2:
    /// after a tap-correction the owner's next move is "try it again", and a
    /// retry that ran against the pre-correction vocabulary would be testing
    /// the wrong thing. Re-persisting is skipped when nothing changed, so a
    /// plain re-record pays nothing.
    @discardableResult
    private func persistProvisionalAliases() async -> Bool {
        // Re-read the term: the Sounds-like row behind the sheet is editable, so
        // the snapshot taken at init may be stale.
        guard let latest = VocabularyStore.shared.terms.first(where: { $0.id == termID }) else {
            transientError = "This vocabulary term no longer exists."
            return false
        }
        if preTeachAliases == nil { preTeachAliases = latest.aliases }
        let merged = TeachSentenceLocator.mergeAliases(
            latestAliases: preTeachAliases ?? latest.aliases,
            provisionalAliases: state.provisionalAliases + correctedAliases
        )
        guard merged != lastPersistedAliases else { return true }

        isPreparingVocabulary = true
        defer { isPreparingVocabulary = false }
        let startedAt = Date()
        await VocabularyStore.shared.updateAwaitingRescorer(id: termID, aliases: merged)
        lastPersistedAliases = merged
        DiagnosticsLog.record(
            source: "main-app",
            category: .vocabularyGate,
            message: "teaching persisted provisional aliases",
            metadata: [
                "aliases": "\(merged.count)",
                "fromTakes": "\(state.provisionalAliases.count)",
                "fromTaps": "\(correctedAliases.count)",
                "rebuildMS": "\(Int(Date().timeIntervalSince(startedAt) * 1000))",
            ]
        )
        return true
    }

    /// A phase-2 recording must never start before the vocabulary it is meant
    /// to test is on disk and loaded.
    func startRecording() async {
        if phase == .sentence {
            guard !isBusy else { return }
            transientError = nil
            guard await persistProvisionalAliases() else { return }
        }
        await startTake()
    }

    func returnToTakes() {
        guard !isBusy else { return }
        phase = .takes
        // Drop the previous run entirely. Re-entering phase 2 re-persists a
        // possibly different alias set, so a kept highlight would be describing
        // what a DIFFERENT vocabulary did — stale and unfalsifiable until a new
        // recording lands.
        sentence = nil
        verdict = .unanswered
        isCorrecting = false
        selectedWords = []
    }

    /// "Yes, that's it" / "Got it" — the user's judgment, recorded for the
    /// sheet's own encouragement copy. It gates nothing: Save always works.
    func confirmSentence() {
        verdict = .confirmed
        isCorrecting = false
        selectedWords = []
    }

    /// The user looked and found nothing to point at. Distinct from a
    /// confirmation: it must not be reported back as "your vocabulary is
    /// working", which is the opposite of what they just said.
    func dismissCorrection() {
        verdict = .nothingMatched
        isCorrecting = false
        selectedWords = []
    }

    func beginCorrection() {
        verdict = .unanswered
        isCorrecting = true
        selectedWords = []
    }

    func toggleWord(_ index: Int) {
        if selectedWords.contains(index) {
            selectedWords.remove(index)
        } else {
            selectedWords.insert(index)
        }
        transientError = nil
    }

    /// The span the user tapped becomes another sounds-like. The span IS the
    /// heard text — with one exception the number pass creates: it rewrites
    /// spelled cardinals to digits AFTER the gate, so a span that gained a digit
    /// is not what was said and must not be learned (it would arm a correction
    /// that fires on every numeral in every future dictation).
    func learnSelection() {
        guard let sentence, !selectedWords.isEmpty else { return }
        let words = TeachSentenceLocator.words(in: sentence.text)
        let indices = selectedWords.sorted()
        guard let first = indices.first, let last = indices.last,
              first >= 0, last < words.count else { return }
        let span = TeachSentenceLocator.Span(
            start: words[first].start, length: words[last].end - words[first].start
        )
        let heard = TeachSentenceLocator.text(of: span, in: sentence.text)
        let alias = VocabularyStore.fileSafeAlias(heard)
        guard !alias.isEmpty, !CorrectionKey.normalize(alias).isEmpty else {
            transientError = "Jot can't save that as a sounds-like. Try picking the words again."
            return
        }
        // Span-scoped, not sentence-scoped: the number pass rewrites spelled
        // cardinals to digits after the gate, so a picked span that gained a
        // digit its own source words didn't have is text the user never said.
        // Testing the whole sentence would disarm this the moment they happened
        // to say any unrelated number.
        let source = TeachSentenceLocator.sourceSpanText(
            finalSpan: span, gatedText: sentence.gatedText, gatedToFinal: sentence.gatedToFinal
        )
        guard !(alias.contains(where: \.isNumber) && !source.contains(where: \.isNumber)) else {
            transientError = "Jot turned those words into a number after transcribing, so it can't learn them as a misheard form. Try the sentence again."
            return
        }
        guard CorrectionKey.normalize(alias) != CorrectionKey.normalize(termText) else {
            transientError = "Those words already read as your term."
            return
        }
        correctedAliases = TeachSentenceLocator.mergeAliases(
            latestAliases: correctedAliases, provisionalAliases: [alias]
        )
        verdict = .learned(alias)
        isCorrecting = false
        selectedWords = []
    }

    var learnedFromCorrection: [String] { correctedAliases }

    // MARK: - Save / discard

    func save() -> Bool {
        guard let latest = VocabularyStore.shared.terms.first(where: { $0.id == termID }) else {
            transientError = "This vocabulary term no longer exists."
            return false
        }
        // Merge onto the PRE-TEACH list when phase 2 already persisted, so a
        // take deleted afterwards doesn't survive as an alias nobody kept.
        let merged = TeachSentenceLocator.mergeAliases(
            latestAliases: preTeachAliases ?? latest.aliases,
            provisionalAliases: state.provisionalAliases + correctedAliases
        )
        VocabularyStore.shared.update(id: termID, aliases: merged)
        didSave = true
        return true
    }

    /// Cancel drops everything phase 2 persisted. The aliases were real
    /// observations, so a crash mid-teach leaving them behind is acceptable —
    /// they show up as deletable chips in the term's Sounds-like row.
    func discardProvisionalAliases() {
        guard !didSave, let original = preTeachAliases else { return }
        preTeachAliases = nil
        VocabularyStore.shared.update(id: termID, aliases: original)
    }

    /// Dismissal drops provisional data and gently tears down only a capture
    /// this session owns. Locals keep the cleanup alive after the sheet leaves.
    func stopGently() {
        // Latch BEFORE the guards below — a queued-but-unstarted `startTake()`
        // must be refused even when those guards make this call a no-op.
        hasDismissed = true
        // Cancel calls this before dismiss, then onDisappear calls it again.
        // The second invocation must not clear generic ownership before the
        // first Task reaches stop(), whose owned-stop snapshot is load-bearing.
        guard !isTearingDown else { return }
        // A Stop-tap task already owns the gentle recorder terminal. Dismissing
        // during its transcription tail drops the result but must not issue a
        // second concurrent stop while the first one is still awaiting audio.
        guard !isTranscribing else { return }
        let pending = startTask
        startTask = nil
        startToken = nil
        guard ownsCapture else { return }
        isTearingDown = true
        isStarting = false
        isCapturing = false
        let recording = recording
        let presenter = streamingPartial
        let log = log
        Task {
            _ = await pending?.value
            do {
                _ = try await recording.stop()
            } catch {
                log.error("vocabulary teaching gentle stop failed: \(error.localizedDescription, privacy: .public)")
            }
            recording.markPipelineFinished()
            recording.ownsActiveRecording = false
            recording.publishPipelinePhase(.idle)
            presenter.reset()
            self.ownsCapture = false
            self.isTearingDown = false
        }
    }

    // MARK: - Internals

    private func replay() {
        state = VocabularyTeachingReducer.replay(
            takes: takes,
            takeCount: takeCount,
            context: VocabularyTeachingContext(
                termText: termText,
                existingAliases: preTeachAliases ?? existingAliases
            )
        )
    }

    private func finishRecorderTail() {
        recording.markPipelineFinished()
        recording.ownsActiveRecording = false
        recording.publishPipelinePhase(.idle)
        streamingPartial.reset()
        ownsCapture = false
    }

    /// Move each proposal's span out of the gate's output text and into the
    /// published text, which four transforms have rewritten since. `mapOffsets`
    /// is the same diff-based mapping the provenance reconcile uses for exactly
    /// this drift; `TeachSentenceLocator` then re-checks every mapped span and
    /// drops the ones that no longer read as the proposal claims.
    private static func locatorProposals(
        from output: TranscriptionService.InferenceOutput,
        gatedToFinal: [Int]
    ) -> [TeachSentenceLocator.Proposal] {
        guard !output.proposals.isEmpty else { return [] }
        let gatedCount = output.gatedText.count
        func mapped(_ offset: Int) -> Int {
            guard !gatedToFinal.isEmpty else { return offset }
            guard offset >= 0 else { return 0 }
            // An end offset may sit one past the last character.
            guard offset < gatedToFinal.count else { return output.text.count }
            return gatedToFinal[offset]
        }
        return output.proposals.map { proposal in
            let start = mapped(min(proposal.publishedStart, gatedCount))
            let end = mapped(min(proposal.publishedStart + proposal.publishedLength, gatedCount))
            return TeachSentenceLocator.Proposal(
                term: proposal.term,
                originalWord: proposal.originalWord,
                outcome: proposal.outcome,
                start: start,
                length: max(0, end - start)
            )
        }
    }

    /// One diff of the gate's output against the published text, reused for
    /// every proposal span AND for tracing a tapped span back to the words that
    /// produced it. Empty when the two strings are identical (the common case —
    /// no post-gate transform changed anything), which callers read as identity.
    private static func gatedToFinalMap(from output: TranscriptionService.InferenceOutput) -> [Int] {
        guard output.gatedText != output.text else { return [] }
        return CorrectionProvenance.mapOffsets(
            Array(0...output.gatedText.count), old: output.gatedText, new: output.text
        )
    }

    private static func spanCount(_ result: TeachSentenceLocator.Result) -> Int {
        switch result {
        case .applied(let spans): spans.count
        case .heldBack(let spans, _): spans.count
        case .notFound: 0
        }
    }

    private static func outcomeLabel(_ result: TeachSentenceLocator.Result) -> String {
        switch result {
        case .applied: "applied"
        case .heldBack: "held-back"
        case .notFound: "not-found"
        }
    }

    private static func isBusyError(_ error: Error) -> Bool {
        if let error = error as? TranscriptionService.TranscriptionError, case .busy = error {
            return true
        }
        return false
    }

    private static func takeFailureMessage(_ error: Error) -> String {
        isBusyError(error)
            ? "Jot was still finishing another recording. Try that take again."
            : "Jot couldn't transcribe that take. Try again."
    }

    /// The sentence is a long, deliberate action — a generic take-level error
    /// reads as "that recording was bad" when the real cause was a transcription
    /// still in flight.
    private static func sentenceFailureMessage(_ error: Error) -> String {
        isBusyError(error)
            ? "Jot was still finishing another recording. Wait a moment and say the sentence again."
            : "Jot couldn't transcribe that sentence. Try saying it again."
    }
}

struct VocabularyTeachingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: VocabularyTeachingSession
    @State private var isConfirmingDiscard = false

    init(term: VocabTerm, recording: RecordingService, streamingPartial: StreamingPartial) {
        _session = State(initialValue: VocabularyTeachingSession(
            term: term,
            recording: recording,
            streamingPartial: streamingPartial
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                switch session.phase {
                case .takes: takesPhase
                case .sentence: sentencePhase
                }
            }
            .padding(.top, 20)
            .navigationTitle("Teach it by voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        session.discardProvisionalAliases()
                        session.stopGently()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Save always works — the sentence test is encouragement,
                    // not a gate on keeping what the takes taught.
                    Button("Save") {
                        if session.save() {
                            session.stopGently()
                            dismiss()
                        }
                    }
                    .disabled(session.isBusy)
                }
            }
        }
        // A swipe-down is the same discard the Cancel button performs, but with
        // none of its intent — so when there is something to lose it is refused
        // and explained instead. Cancel itself stays an explicit, immediate
        // discard; this only covers the gesture that isn't one.
        .background(
            SheetDismissGuard(shouldBlock: session.isBusy || session.hasWorkToLose) {
                guard !session.isBusy else { return }
                isConfirmingDiscard = true
            }
        )
        .confirmationDialog(
            "Discard this teaching session?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                session.discardProvisionalAliases()
                session.stopGently()
                dismiss()
            }
            Button("Save what I taught") {
                if session.save() {
                    session.stopGently()
                    dismiss()
                }
            }
            // NO `.cancel` role on purpose. iOS 26 renders this dialog as a
            // centered card and replaces the cancel-role button with an
            // invisible tap-outside region — which left the safe way out
            // unrendered while the destructive one sat there in red. A plain
            // role puts it in the button stack; tapping outside still cancels.
            Button("Keep teaching") {}
        } message: {
            Text("Your takes and anything Jot learned from them will be thrown away.")
        }
        .onDisappear {
            session.discardProvisionalAliases()
            session.stopGently()
        }
    }

    // MARK: - Phase 1

    @ViewBuilder
    private var takesPhase: some View {
        VStack(spacing: 6) {
            Text("Say “\(session.termText)”")
                .font(.title2.weight(.semibold))
            Text("Say it a few times, the way you normally would.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }

        Text("Takes: \(session.state.takeCount)")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

        captureControl(stopLabel: "Stop", recordLabel: "Record")

        errorLabel

        if session.state.results.isEmpty {
            Text("Each take shows exactly what Jot heard. Delete a cough or a wrong word — everything else Jot keeps as a way you might be misheard.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        } else {
            List(session.state.results) { result in
                takeRow(result)
            }
            .listStyle(.plain)
        }

        if session.maySayASentence {
            Button {
                Task { await session.beginSentencePhase() }
            } label: {
                Label("Now use it in a sentence", systemImage: "text.bubble")
                    .frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(session.isBusy)
            .padding(.bottom, 16)
        }
    }

    private func takeRow(_ result: VocabularyTeachingResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(heardLine(result))
                    .font(.subheadline.weight(.medium))
                if let note = noteText(result.note) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button(role: .destructive) {
                session.deleteTake(id: result.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(session.isBusy)
            .accessibilityLabel("Delete take")
        }
    }

    private func heardLine(_ result: VocabularyTeachingResult) -> String {
        guard let raw = result.rawTranscript else { return "Take didn't finish" }
        if case .nothingHeard = result.note { return "Heard: nothing" }
        return "Heard: “\(raw)”"
    }

    private func noteText(_ note: VocabularyTeachingResult.Note) -> String? {
        switch note {
        case .stored: nil
        case .matches: "matches"
        case .duplicate: "already in Sounds like"
        case .nothingToLearn: "Nothing here Jot can store as a sounds-like."
        case .nothingHeard: "Try again a little closer to the mic."
        case .failed(let message): message
        }
    }

    // MARK: - Phase 2

    @ViewBuilder
    private var sentencePhase: some View {
        VStack(spacing: 6) {
            Text("Say a sentence that uses “\(session.termText)” naturally.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Jot will transcribe it exactly the way it would if you had hit record anywhere else.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)

        captureControl(stopLabel: "Stop", recordLabel: session.sentence == nil ? "Record sentence" : "Try another sentence")

        errorLabel

        if let sentence = session.sentence {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SentenceWordsView(
                        sentence: sentence.text,
                        highlighted: highlightedSpans(sentence.result),
                        selected: session.selectedWords,
                        isSelecting: session.isCorrecting,
                        onTapWord: { session.toggleWord($0) }
                    )
                    outcomeCopy(sentence.result)
                    outcomeActions(sentence.result)
                    if !session.learnedFromCorrection.isEmpty {
                        // The one line here that grows without bound — each tap
                        // adds a phrase. Capped for the same reason the pane's
                        // chips are.
                        Text("Jot will also learn: \(session.learnedFromCorrection.map { "“\($0)”" }.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }
        }

        Button("Record more takes") { session.returnToTakes() }
            .font(.footnote)
            .disabled(session.isBusy)
            .padding(.bottom, 16)
    }

    private func highlightedSpans(
        _ result: TeachSentenceLocator.Result
    ) -> [TeachSentenceLocator.Span] {
        switch result {
        case .applied(let spans): spans
        case .heldBack(let spans, _): spans
        case .notFound: []
        }
    }

    /// Every line below DESCRIBES what the pipeline did with the sentence. None
    /// of them grades the user or the take — "found but held back" is the gate's
    /// documented behaviour on an everyday-word original, not a failure.
    @ViewBuilder
    private func outcomeCopy(_ result: TeachSentenceLocator.Result) -> some View {
        if session.isCorrecting {
            Text("Tap the word or words that should have been “\(session.termText)”. Tap a second word to extend the pick.")
                .font(.subheadline)
        } else if session.verdict == .confirmed {
            Label(validatedCopy(result), systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        } else if session.verdict == .nothingMatched {
            // The user just said none of these words were the term. Reporting
            // that back as a success is the one thing this screen must not do.
            Text("Nothing in this sentence to learn from, then. Say another one, or save what the takes taught.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if case .learned(let alias) = session.verdict {
            Label(
                "“\(alias)” added to Sounds like. Try another sentence, or Save.",
                systemImage: "plus.circle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(Color.accentColor)
        } else {
            switch result {
            case .applied:
                Text("Did I get it right?")
                    .font(.headline)
            case .heldBack:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Jot heard “\(session.termText)” here — in real dictations it will ask before changing this.")
                        .font(.subheadline)
                    Text("Everyday words are never rewritten silently, so you get the last word on them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .notFound:
                Text("“\(session.termText)” isn't in this sentence. Say another one, or save what the takes taught.")
                    .font(.subheadline)
            }
        }
    }

    /// Only reachable from an explicit confirmation, so each line reports back
    /// something the user actually said was right.
    private func validatedCopy(_ result: TeachSentenceLocator.Result) -> String {
        switch result {
        case .applied: "Your vocabulary is working in a real sentence."
        case .heldBack: "Jot will ask you about this one while you dictate."
        case .notFound: "Noted."
        }
    }

    @ViewBuilder
    private func outcomeActions(_ result: TeachSentenceLocator.Result) -> some View {
        if session.isCorrecting {
            HStack {
                Button("Learn that") { session.learnSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.selectedWords.isEmpty || session.isBusy)
                Button("Nothing here matched") { session.dismissCorrection() }
                    .buttonStyle(.bordered)
                    .disabled(session.isBusy)
            }
        } else if case .learned = session.verdict {
            // A sentence can hold more than one wrong span; offer the picker
            // again rather than making a second correction need a new recording.
            Button("Pick more words") { session.beginCorrection() }
                .buttonStyle(.bordered)
                .disabled(session.isBusy)
        } else if session.verdict == .unanswered {
            HStack {
                switch result {
                case .applied:
                    Button("Yes, that's it") { session.confirmSentence() }
                        .buttonStyle(.borderedProminent)
                    Button("No — let me show you") { session.beginCorrection() }
                        .buttonStyle(.bordered)
                case .heldBack:
                    Button("Got it") { session.confirmSentence() }
                        .buttonStyle(.borderedProminent)
                    Button("No — let me show you") { session.beginCorrection() }
                        .buttonStyle(.bordered)
                case .notFound:
                    Button("Show Jot the words") { session.beginCorrection() }
                        .buttonStyle(.bordered)
                }
            }
            .disabled(session.isBusy)
        }
    }

    // MARK: - Shared chrome

    @ViewBuilder
    private func captureControl(stopLabel: String, recordLabel: String) -> some View {
        if session.isPreparingVocabulary {
            ProgressView("Getting your vocabulary ready…")
                .controlSize(.large)
        } else if session.isStarting || session.isTranscribing {
            ProgressView(session.isStarting ? "Starting…" : "Listening back…")
                .controlSize(.large)
        } else if session.isCapturing {
            Button {
                Task { await session.finishTake() }
            } label: {
                Label(stopLabel, systemImage: "stop.fill")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .accessibilityLabel("Stop recording")
        } else {
            Button {
                Task { await session.startRecording() }
            } label: {
                Label(recordLabel, systemImage: "mic.fill")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!session.canRecord)
            .accessibilityLabel(recordLabel)
        }
    }

    @ViewBuilder
    private var errorLabel: some View {
        if let error = session.transientError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.leading)
                .padding(.horizontal)
        }
    }
}

/// Refuses a sheet's swipe-down dismissal and REPORTS the attempt.
///
/// SwiftUI's `interactiveDismissDisabled` does the refusing but has no callback,
/// so the gesture just dies and the user is told nothing. UIKit does report it
/// (`presentationControllerDidAttemptToDismiss`), which is the whole reason this
/// bridge exists.
///
/// It takes over the sheet's presentation-controller delegate, so it CHAINS to
/// whatever delegate was there — SwiftUI's own, which is what resets the
/// `sheet(item:)` binding when a sheet really is dismissed. Dropping those
/// forwards would leave the binding set after a legitimate dismissal and the
/// sheet unable to reopen. When nothing is blocked, `shouldDismiss` returns true
/// and every other call passes straight through, so the presentation behaves
/// exactly as it did before.
private struct SheetDismissGuard: UIViewControllerRepresentable {
    let shouldBlock: Bool
    let onAttempt: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> Proxy {
        let proxy = Proxy()
        proxy.coordinator = context.coordinator
        return proxy
    }

    func updateUIViewController(_ proxy: Proxy, context: Context) {
        context.coordinator.shouldBlock = shouldBlock
        context.coordinator.onAttempt = onAttempt
        proxy.coordinator = context.coordinator
        proxy.installIfNeeded()
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var shouldBlock = false
        var onAttempt: () -> Void = {}
        weak var chained: (any UIAdaptivePresentationControllerDelegate)?

        func presentationControllerShouldDismiss(_ controller: UIPresentationController) -> Bool {
            guard !shouldBlock else { return false }
            // Not ours to allow: the delegate we displaced may have its own
            // reason to refuse (another `interactiveDismissDisabled` upstream),
            // and answering `true` for it would silently override that.
            return chained?.presentationControllerShouldDismiss?(controller) ?? true
        }

        func presentationControllerDidAttemptToDismiss(_ controller: UIPresentationController) {
            onAttempt()
            chained?.presentationControllerDidAttemptToDismiss?(controller)
        }

        func presentationControllerWillDismiss(_ controller: UIPresentationController) {
            chained?.presentationControllerWillDismiss?(controller)
        }

        func presentationControllerDidDismiss(_ controller: UIPresentationController) {
            chained?.presentationControllerDidDismiss?(controller)
        }

        // Adaptivity: invisible on iPhone portrait, load-bearing on iPad and on
        // a size-class change, where SwiftUI answers these to keep a sheet a
        // sheet. Defaults here would silently change the presentation style.
        func adaptivePresentationStyle(
            for controller: UIPresentationController
        ) -> UIModalPresentationStyle {
            chained?.adaptivePresentationStyle?(for: controller) ?? .none
        }

        func adaptivePresentationStyle(
            for controller: UIPresentationController, traitCollection: UITraitCollection
        ) -> UIModalPresentationStyle {
            chained?.adaptivePresentationStyle?(for: controller, traitCollection: traitCollection)
                ?? adaptivePresentationStyle(for: controller)
        }

        func presentationController(
            _ presentationController: UIPresentationController,
            willPresentWithAdaptiveStyle style: UIModalPresentationStyle,
            transitionCoordinator: (any UIViewControllerTransitionCoordinator)?
        ) {
            chained?.presentationController?(
                presentationController,
                willPresentWithAdaptiveStyle: style,
                transitionCoordinator: transitionCoordinator
            )
        }
    }

    final class Proxy: UIViewController {
        var coordinator: Coordinator?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installIfNeeded()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installIfNeeded()
        }

        /// Resolve the presentation controller from the TOPMOST ancestor, not
        /// from `self`.
        ///
        /// This proxy is a CHILD view controller (it rides in a `.background`),
        /// and `UIViewController.presentationController` resolves through the
        /// presented/presenting chain rather than through containment — so on
        /// `self` it is nil and this guard would early-return forever. That was
        /// a real, reproduced failure: the guard never installed, swipe-down
        /// discarded a session with no dialog, and the reopen tests "passed"
        /// only because nothing had ever been displaced to chain to.
        ///
        /// Idempotent, and attempted on every update as well as on appearance
        /// and on containment changes, because the hosting controller is not
        /// reachable at `makeUIViewController` time.
        func installIfNeeded() {
            var host: UIViewController = self
            while let next = host.parent { host = next }
            guard let coordinator,
                  let presentation = host.presentationController,
                  presentation.delegate !== coordinator
            else { return }
            coordinator.chained = presentation.delegate
            presentation.delegate = coordinator
        }
    }
}

/// The sentence, rendered one word at a time so a word can be highlighted or
/// tapped. The transcript renderers elsewhere in the app tap PRE-COMPUTED marks
/// (`MarkedTranscriptText`) and give no per-word geometry, and a plain `Text`
/// gives none either — so the sheet lays the words out itself. Taps snap to a
/// whole word by construction; a second tap extends the pick across the words
/// in between.
private struct SentenceWordsView: View {
    let sentence: String
    let highlighted: [TeachSentenceLocator.Span]
    let selected: Set<Int>
    let isSelecting: Bool
    let onTapWord: (Int) -> Void

    var body: some View {
        let words = TeachSentenceLocator.words(in: sentence)
        let range = selectionRange
        FlowLayout(spacing: 4, lineSpacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, span in
                let text = TeachSentenceLocator.text(of: span, in: sentence)
                let isSelected = range.map { index >= $0.lowerBound && index <= $0.upperBound } ?? false
                let isMarked = highlighted.contains { $0.start < span.end && span.start < $0.end }
                Text(text)
                    .font(.body)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(background(isMarked: isMarked, isSelected: isSelected))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 5))
                    .onTapGesture { if isSelecting { onTapWord(index) } }
                    .accessibilityAddTraits(isSelecting ? .isButton : [])
            }
        }
    }

    /// Two taps mean "these words and everything between them" — the heard span
    /// is contiguous, so the pick is too.
    private var selectionRange: ClosedRange<Int>? {
        guard let low = selected.min(), let high = selected.max() else { return nil }
        return low...high
    }

    private func background(isMarked: Bool, isSelected: Bool) -> Color {
        if isSelected { return .accentColor.opacity(0.35) }
        if isMarked && !isSelecting { return .yellow.opacity(0.35) }
        return .clear
    }
}
