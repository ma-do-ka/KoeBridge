import Foundation
import Testing
@testable import KoeBridgeCore

struct GeminiFinalizationTests {
    private let end = Date(timeIntervalSince1970: 1_000)

    @Test func aFinalBeforeTheStopIsNotProofThatTheEndWasReceived() {
        let oldFinal = end.addingTimeInterval(-2)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: oldFinal,
                                               turnCompleteAt: nil, now: end.addingTimeInterval(6)))
    }

    @Test func anOldTurnCompleteMustNotAuthorizeTheNewStop() {
        let final = end.addingTimeInterval(-3)
        let oldComplete = end.addingTimeInterval(-0.5)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: final,
                                               turnCompleteAt: oldComplete, now: end.addingTimeInterval(6)))
    }

    @Test func aNewTurnCompleteCanAuthorizeAnEarlierFinal() {
        let prior = end.addingTimeInterval(-0.05)
        let completed = end.addingTimeInterval(0.2)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: prior,
                                               turnCompleteAt: completed, now: end.addingTimeInterval(0.3)))
        #expect(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: prior,
                                              turnCompleteAt: completed, now: end.addingTimeInterval(0.9)))
    }

    @Test func aNewFinalCanFinishAfterQuietPeriodWithoutTurnComplete() {
        let fresh = end.addingTimeInterval(0.2)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: fresh,
                                               turnCompleteAt: nil, now: end.addingTimeInterval(0.4)))
        #expect(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: fresh,
                                              turnCompleteAt: nil, now: end.addingTimeInterval(0.8)))
    }

    @Test func pendingInterimBlocksAutoPaste() {
        let fresh = end.addingTimeInterval(0.1)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: fresh,
            turnCompleteAt: end.addingTimeInterval(0.2), now: end.addingTimeInterval(3),
            hasPendingInterim: true, lastTranscriptionAt: end.addingTimeInterval(1)))
    }

    @Test func recentPreStopFinalAndOldFinalAreDifferent() {
        #expect(FinalizationPolicy.canFinish(endedAt: end,
            lastFinalAt: end.addingTimeInterval(-0.25), turnCompleteAt: nil,
            now: end.addingTimeInterval(0.8)))
        #expect(!FinalizationPolicy.canFinish(endedAt: end,
            lastFinalAt: end.addingTimeInterval(-2.00), turnCompleteAt: nil,
            now: end.addingTimeInterval(6)))
    }

    @Test func anEarlierFinalForTheLastSpeechSegmentCanCompleteWithoutTurnComplete() {
        let previous = end.addingTimeInterval(-1.0)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: previous,
            turnCompleteAt: nil, now: end.addingTimeInterval(0.25)))
        #expect(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: previous,
            turnCompleteAt: nil, now: end.addingTimeInterval(0.90)))
    }

    @Test func outOfOrderIdenticalInterimCannotBlockAFinal() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("こんにちは"))
        assembler.apply(.interim("こんにちは"))
        #expect(assembler.interim.isEmpty)
        #expect(assembler.committedText == "こんにちは")
    }

    @Test func retransmittedFinalIsNotNewAcceptedFinalization() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("これが確定済み"))
        let committedCount = assembler.finalCount
        assembler.apply(.final("これが確定済み"))
        #expect(assembler.finalCount == committedCount)
        #expect(assembler.committedText == "これが確定済み")
        // GeminiLiveConnection.handle advances lastFinalAt only when
        // finalCount increases; the replay must not authorize an early paste.
    }

    @Test func consecutiveTurnsMayLegitimatelyUseTheSameWords() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("はい"))
        assembler.apply(.turnComplete)
        // A late retransmission after turnComplete does not mean a new turn.
        assembler.apply(.final("はい"))
        #expect(assembler.committedText == "はい")
        assembler.beginActivity()
        assembler.apply(.final("はい"))
        #expect(assembler.committedText == "はいはい")
    }
}
