import Foundation
import Testing
@testable import KoeBridgeCore

struct GeminiFinalizationTests {
    private let end = Date(timeIntervalSince1970: 1_000)

    @Test func aFinalBeforeTheStopIsNotProofThatTheEndWasReceived() {
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(-2),
            turnCompleteAt: nil, now: end.addingTimeInterval(6)))
    }

    @Test func anOldTurnCompleteMustNotAuthorizeTheNewStop() {
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(-3),
            turnCompleteAt: end.addingTimeInterval(-0.5), now: end.addingTimeInterval(6)))
    }

    @Test func aNewTurnCompleteCanAuthorizeAnEarlierFinal() {
        let prior = end.addingTimeInterval(-0.05)
        let completed = end.addingTimeInterval(0.2)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: prior,
            turnCompleteAt: completed, now: end.addingTimeInterval(0.3)))
        #expect(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: prior,
            turnCompleteAt: completed, now: end.addingTimeInterval(0.9)))
    }

    @Test func aFinalNeedsExplicitCompletion() {
        // Even a final received AFTER end may be a delayed earlier segment.
        let fresh = end.addingTimeInterval(0.2)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: fresh,
            turnCompleteAt: nil, now: end.addingTimeInterval(0.8)))
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: fresh,
            turnCompleteAt: nil, now: end.addingTimeInterval(8)))
    }

    @Test func segmentFinishedDoesNotAuthorizeWholeActivity() {
        let raw = """
        {"serverContent":{"inputTranscription":{"text":"確定した前半","finished":true}}}
        """
        #expect(GeminiWire.transcriptionFinished(raw))
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.2),
            turnCompleteAt: nil, now: end.addingTimeInterval(7)))
    }

    @Test func pendingInterimBlocksAutoPaste() {
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.1),
            turnCompleteAt: end.addingTimeInterval(0.2), now: end.addingTimeInterval(3),
            hasPendingInterim: true, lastTranscriptionAt: end.addingTimeInterval(1)))
    }

    @Test func anyPreStopFinalNeedsAnAcknowledgement() {
        for age in [0.001, 0.25, 1.0, 2.0, 45.0] {
            #expect(!FinalizationPolicy.canFinish(endedAt: end,
                lastFinalAt: end.addingTimeInterval(-age), turnCompleteAt: nil,
                now: end.addingTimeInterval(7)))
        }
    }

    @Test func unscopedCompletionCannotBypassTheEndWrite() {
        // endedAt is the WRITE COMPLETION barrier, not the user's stop or the
        // start of a suspended socket send. These frames arrived during it.
        let delayedFinal = end.addingTimeInterval(-0.02)
        let earlyCompletion = end.addingTimeInterval(-0.01)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: delayedFinal,
            turnCompleteAt: earlyCompletion, now: end.addingTimeInterval(3)))
        #expect(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: delayedFinal,
            turnCompleteAt: end.addingTimeInterval(0.1), now: end.addingTimeInterval(0.8)))
    }

    @Test func manualEndAcceptsFastCompletionOnlyAfterSuccessfulWrite() {
        var endpoint = ManualEndpointState()
        endpoint.beginEnd() // All queued PCM has already been written.
        endpoint.receiveTurnComplete(at: end.addingTimeInterval(-0.1))
        #expect(endpoint.phase == .writingEnd)
        #expect(endpoint.acknowledgedTurnCompleteAt == nil)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(-0.05),
            turnCompleteAt: endpoint.acknowledgedTurnCompleteAt, now: end.addingTimeInterval(0.8)))
        // The socket send succeeds after the receive task handled its reply.
        endpoint.endWriteSucceeded(at: end)
        #expect(endpoint.writeCompletedAt == end)
        #expect(endpoint.acknowledgedTurnCompleteAt == end)
        #expect(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(-0.05),
            turnCompleteAt: endpoint.acknowledgedTurnCompleteAt, now: end.addingTimeInterval(0.8)))
    }

    @Test func manualEndIgnoresCompletionBeforeItsWriteBegins() {
        var endpoint = ManualEndpointState()
        endpoint.receiveTurnComplete(at: end.addingTimeInterval(-0.2))
        endpoint.beginEnd()
        endpoint.endWriteSucceeded(at: end)
        #expect(endpoint.acknowledgedTurnCompleteAt == nil)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.1),
            turnCompleteAt: endpoint.acknowledgedTurnCompleteAt, now: end.addingTimeInterval(0.8)))
        // A later, activity-scoped completion follows the other valid order.
        endpoint.receiveTurnComplete(at: end.addingTimeInterval(0.2))
        #expect(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.1),
            turnCompleteAt: endpoint.acknowledgedTurnCompleteAt, now: end.addingTimeInterval(0.8)))
    }

    @Test func failedOrCancelledEndWritesCannotAcknowledgeCompletion() {
        for cancelled in [false, true] {
            var endpoint = ManualEndpointState()
            endpoint.beginEnd()
            endpoint.receiveTurnComplete(at: end.addingTimeInterval(-0.1))
            if cancelled { endpoint.cancel() } else { endpoint.endWriteFailed() }
            // Late continuations and frames must not resurrect the operation.
            endpoint.endWriteSucceeded(at: end)
            endpoint.receiveTurnComplete(at: end.addingTimeInterval(0.1))
            endpoint.beginEnd()
            #expect(endpoint.phase == (cancelled ? .cancelled : .failed))
            #expect(endpoint.writeCompletedAt == nil)
            #expect(endpoint.acknowledgedTurnCompleteAt == nil)
            #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.1),
                turnCompleteAt: endpoint.acknowledgedTurnCompleteAt, now: end.addingTimeInterval(0.8)))
        }
    }

    @Test func cancellationRevokesAnAcknowledgedManualEnd() {
        var endpoint = ManualEndpointState()
        endpoint.beginEnd()
        endpoint.receiveTurnComplete(at: end.addingTimeInterval(-0.1))
        endpoint.endWriteSucceeded(at: end)
        #expect(endpoint.acknowledgedTurnCompleteAt != nil)
        endpoint.cancel()
        endpoint.receiveTurnComplete(at: end.addingTimeInterval(0.1))
        #expect(endpoint.acknowledgedTurnCompleteAt == nil)
    }

    @Test func identicalInterimRemainsPendingUntilItsOwnFinal() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("こんにちは"))
        assembler.apply(.interim("こんにちは"))
        #expect(assembler.interim == "こんにちは")
        #expect(assembler.committedText == "こんにちは")
        #expect(assembler.recoveryText == "こんにちはこんにちは")
        assembler.apply(.final("こんにちは"))
        #expect(assembler.interim.isEmpty)
        #expect(assembler.committedText == "こんにちはこんにちは")
    }

    @Test func retransmittedFinalIsNotNewAcceptedFinalization() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("これが確定済み"), segmentIdentity: "0s|1s|")
        let committedCount = assembler.finalCount
        assembler.apply(.interim("後続の指示"))
        assembler.apply(.final("これが確定済み"), segmentIdentity: "0s|1s|")
        #expect(assembler.finalCount == committedCount)
        #expect(assembler.committedText == "これが確定済み")
        #expect(assembler.interim == "後続の指示")
    }

    @Test func conflictingTextForTheSameRangeRemainsRecoverable() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("30,000円です。"), segmentIdentity: "0s|1s|")
        assembler.apply(.final("3,000円です。"), segmentIdentity: "0s|1s|")
        #expect(assembler.hasConflictingFinals)
        #expect(assembler.recoveryText.contains("30,000円です。"))
        #expect(assembler.recoveryText.contains("3,000円です。"))
        #expect(assembler.finalCount == 2)
    }

    @Test func consecutiveTurnsMayLegitimatelyUseTheSameWords() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("はい"), segmentIdentity: "0s|1s|")
        assembler.apply(.turnComplete)
        assembler.apply(.final("はい"), segmentIdentity: "0s|1s|")
        #expect(assembler.committedText == "はい")
        assembler.beginActivity()
        assembler.apply(.final("はい"), segmentIdentity: "0s|1s|")
        #expect(assembler.committedText == "はいはい")
    }

    @Test func repeatedWordsWithinOneActivityArePreserved() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("はい"), segmentIdentity: "0s|1s|")
        assembler.apply(.final("はい"), segmentIdentity: "1s|2s|")
        assembler.apply(.final("はい"))
        #expect(assembler.committedText == "はいはいはい")
        #expect(assembler.finalCount == 3)
    }

    @Test func laterTranscriptionResetsTheQuietPeriod() {
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.7),
            turnCompleteAt: end.addingTimeInterval(0.1), now: end.addingTimeInterval(0.8),
            lastTranscriptionAt: end.addingTimeInterval(0.7)))
        #expect(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.7),
            turnCompleteAt: end.addingTimeInterval(0.1), now: end.addingTimeInterval(1.1),
            lastTranscriptionAt: end.addingTimeInterval(0.7)))
    }

    @Test func completionAloneAndFutureEventsCannotAuthorizeInsertion() {
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: nil,
            turnCompleteAt: end.addingTimeInterval(0.1), now: end.addingTimeInterval(5)))
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(2),
            turnCompleteAt: end.addingTimeInterval(0.1), now: end.addingTimeInterval(1)))
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end,
            turnCompleteAt: end.addingTimeInterval(2), now: end.addingTimeInterval(1)))
    }
}
