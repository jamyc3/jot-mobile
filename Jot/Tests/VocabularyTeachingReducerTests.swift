import JotVocabCore
import XCTest
@testable import Jot

/// Phase-1 take reducer for teach-by-voice v2.
///
/// Rewritten from the v1 suite: the outcome taxonomy those 11 tests asserted on
/// (`.term`, `.added`, `.known`, `.unusable`, `.formattingNoOp`, plus `maySave`)
/// was the mechanism build 296 used to grade takes, and it is gone. What is left
/// describes what Jot will DO with a take — keep it as a sounds-like, or note
/// that it has it already — never whether the take was good.
///
/// NOTE: the `JotTests` target still cannot build (pre-existing FluidAudio
/// reason). The executable coverage for the sentence locator and the alias merge
/// is `docs/harnesses/teach_locator_check.sh`, which compiles the shipping
/// source standalone.
final class VocabularyTeachingReducerTests: XCTestCase {
    func testDistinctHearingIsKeptAsASoundsLike() {
        let state = replay([heard("Simple Phrase")])

        XCTAssertEqual(state.provisionalAliases, ["Simple Phrase"])
        XCTAssertEqual(state.results.first?.note, .stored)
    }

    func testHearingTheTermItselfIsInformationalOnly() {
        let raw = "  (SAMPLE PHRASE).  "
        let state = replay([heard(raw)])

        XCTAssertEqual(state.results.first?.rawTranscript, raw)
        XCTAssertEqual(state.results.first?.note, .matches)
        XCTAssertTrue(state.provisionalAliases.isEmpty)
    }

    func testAlreadySavedHearingIsReportedNotDuplicated() {
        let state = replay([heard("(SIMPLE PHRASE).")], existingAliases: ["Simple Phrase"])

        XCTAssertTrue(state.provisionalAliases.isEmpty)
        XCTAssertEqual(state.results.first?.note, .duplicate)
    }

    func testEverydayWordHearingIsKeptLikeAnyOther() {
        // The gate owns the question of what to do with a common-word original
        // (it asks rather than rewrites). Teaching does not re-litigate it —
        // re-implementing that rule here, inverted, is what broke build 296.
        let state = replay([heard("the sample")])

        XCTAssertEqual(state.provisionalAliases, ["the sample"])
        XCTAssertEqual(state.results.first?.note, .stored)
    }

    func testSilenceAndFailureAreRetryableAndTeachNothing() {
        let failure = VocabularyTeachingTake(payload: .failure("Please try that take again."))
        let state = replay([heard(" \n "), failure])

        XCTAssertEqual(state.results.map(\.note), [.nothingHeard, .failed("Please try that take again.")])
        XCTAssertTrue(state.provisionalAliases.isEmpty)
    }

    func testDeletingATakeReplaysTheSurvivorsFromScratch() {
        let first = heard("Simple Phrase")
        let second = heard("SIMPLE PHRASE.")
        XCTAssertEqual(replay([first, second], takeCount: 2).results.map(\.note), [.stored, .duplicate])

        let replayed = replay([second], takeCount: 2)
        XCTAssertEqual(replayed.results.map(\.note), [.stored])
        XCTAssertEqual(replayed.provisionalAliases, ["SIMPLE PHRASE."])
        XCTAssertEqual(replayed.takeCount, 2)
    }

    func testRawTranscriptIsPreservedWhenTheAliasIsFileSanitized() {
        let raw = "#sim: ple,\n"
        let state = replay([heard(raw)])

        XCTAssertEqual(state.results.first?.rawTranscript, raw)
        XCTAssertEqual(state.provisionalAliases, ["sim ple"])
    }

    func testATakeThatSanitizesToNothingIsNeitherStoredNorCalledAMatch() {
        // ":" is a structural character in the vocabulary file and "..." is
        // trimmed away by the correction key. Neither can become an alias — and
        // reporting either as "matches" would tell the user Jot heard the term.
        let state = replay([heard(" : "), heard("...")])

        XCTAssertEqual(state.results.map(\.note), [.nothingToLearn, .nothingToLearn])
        XCTAssertTrue(state.provisionalAliases.isEmpty)
    }

    func testTakesAreUncapped() {
        // v1 stopped after five tries because attempts were spent on verdicts.
        // With no grading there is nothing to exhaust.
        let state = replay((0..<7).map { _ in heard("Simple Phrase") }, takeCount: 7)

        XCTAssertEqual(state.takeCount, 7)
        XCTAssertEqual(state.results.count, 7)
        XCTAssertEqual(state.provisionalAliases, ["Simple Phrase"])
    }

    private func heard(_ raw: String) -> VocabularyTeachingTake {
        VocabularyTeachingTake(payload: .transcript(raw))
    }

    private func replay(
        _ takes: [VocabularyTeachingTake],
        takeCount: Int? = nil,
        term: String = "Sample Phrase",
        existingAliases: [String] = []
    ) -> VocabularyTeachingState {
        VocabularyTeachingReducer.replay(
            takes: takes,
            takeCount: takeCount ?? takes.count,
            context: VocabularyTeachingContext(
                termText: term,
                existingAliases: existingAliases
            )
        )
    }
}
