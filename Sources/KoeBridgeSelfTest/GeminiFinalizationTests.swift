import Foundation

import KoeBridgeCore

struct GeminiFinalizationTests {
    private let end = Date(timeIntervalSince1970: 1_000)

    func aFinalBeforeTheStopIsNotProofThatTheEndWasReceived() {
        let oldFinal = end.addingTimeInterval(-2)
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: oldFinal,
                                               turnCompleteAt: nil, now: end.addingTimeInterval(6)))
    }

    func anOldTurnCompleteMustNotAuthorizeTheNewStop() {
        let final = end.addingTimeInterval(-3)
        let oldComplete = end.addingTimeInterval(-0.5)
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: final,
                                               turnCompleteAt: oldComplete, now: end.addingTimeInterval(6)))
    }

    func aNewTurnCompleteCanAuthorizeAnEarlierFinal() {
        let prior = end.addingTimeInterval(-0.05)
        let completed = end.addingTimeInterval(0.2)
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: prior,
                                               turnCompleteAt: completed, now: end.addingTimeInterval(0.3)))
        check(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: prior,
                                              turnCompleteAt: completed, now: end.addingTimeInterval(0.9)))
    }

    func aNewFinalCanFinishAfterQuietPeriodWithoutTurnComplete() {
        let fresh = end.addingTimeInterval(0.2)
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: fresh,
                                               turnCompleteAt: nil, now: end.addingTimeInterval(0.4)))
        check(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: fresh,
                                              turnCompleteAt: nil, now: end.addingTimeInterval(0.8)))
    }

    func pendingInterimBlocksAutoPaste() {
        let fresh = end.addingTimeInterval(0.1)
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: fresh,
            turnCompleteAt: end.addingTimeInterval(0.2), now: end.addingTimeInterval(3),
            hasPendingInterim: true, lastTranscriptionAt: end.addingTimeInterval(1)))
    }

    func recentPreStopFinalAndOldFinalAreDifferent() {
        check(FinalizationPolicy.canFinish(endedAt: end,
            lastFinalAt: end.addingTimeInterval(-0.25), turnCompleteAt: nil,
            now: end.addingTimeInterval(0.8)))
        check(!FinalizationPolicy.canFinish(endedAt: end,
            lastFinalAt: end.addingTimeInterval(-2.00), turnCompleteAt: nil,
            now: end.addingTimeInterval(6)))
    }

    func anEarlierFinalForTheLastSpeechSegmentCanCompleteWithoutTurnComplete() {
        let previous = end.addingTimeInterval(-1.0)
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: previous,
            turnCompleteAt: nil, now: end.addingTimeInterval(0.25)))
        check(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: previous,
            turnCompleteAt: nil, now: end.addingTimeInterval(0.90)))
    }

    func outOfOrderIdenticalInterimCannotBlockAFinal() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("こんにちは"))
        assembler.apply(.interim("こんにちは"))
        check(assembler.interim.isEmpty)
        check(assembler.committedText == "こんにちは")
    }

    func retransmittedFinalIsNotNewAcceptedFinalization() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("これが確定済み"))
        let committedCount = assembler.finalCount
        assembler.apply(.final("これが確定済み"))
        check(assembler.finalCount == committedCount)
        check(assembler.committedText == "これが確定済み")
        // GeminiLiveConnection.handle advances lastFinalAt only when
        // finalCount increases; the replay must not authorize an early paste.
    }

    func consecutiveTurnsMayLegitimatelyUseTheSameWords() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("はい"))
        assembler.apply(.turnComplete)
        // A late retransmission after turnComplete does not mean a new turn.
        assembler.apply(.final("はい"))
        check(assembler.committedText == "はい")
        assembler.beginActivity()
        assembler.apply(.final("はい"))
        check(assembler.committedText == "はいはい")
    }
}
