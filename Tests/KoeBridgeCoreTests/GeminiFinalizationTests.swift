import Foundation
import Testing
@testable import KoeBridgeCore

struct GeminiFinalizationTests {
    @Test func interimBoundaryKeepsEveryScalarInPreview() {
        for (prefix, tail) in [("か", "\u{3099}く"), ("👩", "\u{200D}💻")] {
            var assembler = TranscriptAssembler(budget: .dictation)
            assembler.apply(.final(prefix))
            assembler.apply(.interim(tail))
            #expect(assembler.preview.volatileTail.utf8.elementsEqual(tail.utf8))
            #expect(assembler.preview.text.utf8.elementsEqual((prefix + tail).utf8))
            #expect(assembler.committedText.utf8.elementsEqual(prefix.utf8))
            assembler.apply(.final(tail))
            #expect(assembler.committedText.utf8.elementsEqual((prefix + tail).utf8))
        }
    }

    @Test func interimReplacementAndLongLegitimateFinalsRemainExact() {
        var limited = TranscriptAssembler(budget: .dictation)
        var control = TranscriptAssembler()
        for i in 0..<4096 {
            limited.apply(.interim(String(repeating: "仮", count: 100) + String(i)))
        }
        #expect(!limited.exceededFinalBudget && limited.finalCount == 0)
        for i in 0..<1024 {
            let event = TranscribeEvent.final("長い発話の区間" + String(i))
            limited.apply(event, segmentIdentity: String(i))
            control.apply(event, segmentIdentity: String(i))
        }
        #expect(!limited.exceededFinalBudget)
        #expect(limited.finalCount == 1024)
        #expect(limited.committedText.utf8.elementsEqual(control.committedText.utf8))
    }

    @Test func oversizedFirstFinalKeepsOnlyWholeScalarsForRecovery() {
        var limited = TranscriptAssembler(budget: .init(bytes: 8, identities: 4))
        limited.apply(.final("日月火水"))
        limited.apply(.interim("遅着"))
        #expect(limited.exceededFinalBudget && limited.committedText.isEmpty)
        #expect(limited.recoveryText == "日月")
    }

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
        #expect(endpoint.acknowledgedEndAt == nil)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(-0.05),
            turnCompleteAt: endpoint.acknowledgedEndAt, now: end.addingTimeInterval(0.8)))
        // The socket send succeeds after the receive task handled its reply.
        endpoint.endWriteSucceeded(at: end)
        #expect(endpoint.writeCompletedAt == end)
        #expect(endpoint.acknowledgedEndAt == end)
        #expect(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(-0.05),
            turnCompleteAt: endpoint.acknowledgedEndAt, now: end.addingTimeInterval(0.8)))
    }

    @Test func manualEndIgnoresCompletionBeforeItsWriteBegins() {
        var endpoint = ManualEndpointState()
        endpoint.receiveTurnComplete(at: end.addingTimeInterval(-0.2))
        endpoint.beginEnd()
        endpoint.endWriteSucceeded(at: end)
        #expect(endpoint.acknowledgedEndAt == nil)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.1),
            turnCompleteAt: endpoint.acknowledgedEndAt, now: end.addingTimeInterval(0.8)))
        // A later, activity-scoped completion follows the other valid order.
        endpoint.receiveTurnComplete(at: end.addingTimeInterval(0.2))
        #expect(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.1),
            turnCompleteAt: endpoint.acknowledgedEndAt, now: end.addingTimeInterval(0.8)))
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
            #expect(endpoint.acknowledgedEndAt == nil)
            #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.1),
                turnCompleteAt: endpoint.acknowledgedEndAt, now: end.addingTimeInterval(0.8)))
        }
    }

    @Test func cancellationRevokesAnAcknowledgedManualEnd() {
        var endpoint = ManualEndpointState()
        endpoint.beginEnd()
        endpoint.receiveTurnComplete(at: end.addingTimeInterval(-0.1))
        endpoint.endWriteSucceeded(at: end)
        #expect(endpoint.acknowledgedEndAt != nil)
        endpoint.cancel()
        endpoint.receiveTurnComplete(at: end.addingTimeInterval(0.1))
        #expect(endpoint.acknowledgedEndAt == nil)
    }

    @Test func manualActivityEndFinalizesWithoutModelTurnComplete() throws {
        var endpoint = ManualEndpointState()
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        endpoint.beginEnd()
        // Matches the dedicated Transcribe manual-VAD response: final text
        // plus root voiceActivity ACTIVITY_END, with no model turnComplete.
        let events = try GeminiWire.parse("""
        {"serverContent":{"inputTranscription":{"text":"3,000円です。"}},"voiceActivity":{"type":"ACTIVITY_END"}}
        """)
        for event in events {
            assembler.apply(event)
            if case .activityEnd = event {
                endpoint.receiveActivityEnd(at: end.addingTimeInterval(-0.05))
            }
        }
        #expect(endpoint.acknowledgedEndAt == nil)
        endpoint.endWriteSucceeded(at: end)
        #expect(assembler.committedText == "3,000円です。")
        #expect(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(-0.05),
            endAcknowledgedAt: endpoint.acknowledgedEndAt, now: end.addingTimeInterval(0.8),
            hasPendingInterim: !assembler.interim.isEmpty))
        // The new acknowledgement does not authorize an unfinished suffix.
        assembler.apply(.interim("ただし"))
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(-0.05),
            endAcknowledgedAt: endpoint.acknowledgedEndAt, now: end.addingTimeInterval(0.8),
            hasPendingInterim: !assembler.interim.isEmpty))
    }

    @Test func manualActivityEndNeverBypassesFailedOrUnstartedEnd() {
        var early = ManualEndpointState()
        early.receiveActivityEnd(at: end.addingTimeInterval(-0.2))
        early.beginEnd()
        early.endWriteSucceeded(at: end)
        #expect(early.acknowledgedEndAt == nil)
        for cancelled in [false, true] {
            var endpoint = ManualEndpointState()
            endpoint.beginEnd()
            endpoint.receiveActivityEnd(at: end.addingTimeInterval(-0.1))
            if cancelled { endpoint.cancel() } else { endpoint.endWriteFailed() }
            endpoint.endWriteSucceeded(at: end)
            endpoint.receiveActivityEnd(at: end.addingTimeInterval(0.1))
            #expect(endpoint.acknowledgedEndAt == nil)
            #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end,
                endAcknowledgedAt: endpoint.acknowledgedEndAt, now: end.addingTimeInterval(0.8)))
        }
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
