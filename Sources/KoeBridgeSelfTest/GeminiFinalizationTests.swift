import Foundation
import KoeBridgeCore

struct GeminiFinalizationTests {
    private let end = ContinuousClock.now

    func aFinalBeforeTheStopIsNotProofThatTheEndWasReceived() {
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(-2)),
            endAcknowledgedAt: nil, now: end.advanced(by: .seconds(6))))
    }

    func anOldTurnCompleteMustNotAuthorizeTheNewStop() {
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(-3)),
            endAcknowledgedAt: end.advanced(by: .seconds(-0.5)), now: end.advanced(by: .seconds(6))))
    }

    func aNewTurnCompleteCanAuthorizeAnEarlierFinal() {
        let prior = end.advanced(by: .seconds(-0.05))
        let completed = end.advanced(by: .seconds(0.2))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: prior,
            endAcknowledgedAt: completed, now: end.advanced(by: .seconds(0.3))))
        check(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: prior,
            endAcknowledgedAt: completed, now: end.advanced(by: .seconds(0.9))))
    }

    func aFinalNeedsExplicitCompletion() {
        // Even a final received AFTER end may be a delayed earlier segment.
        let fresh = end.advanced(by: .seconds(0.2))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: fresh,
            endAcknowledgedAt: nil, now: end.advanced(by: .seconds(0.8))))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: fresh,
            endAcknowledgedAt: nil, now: end.advanced(by: .seconds(8))))
    }

    func segmentFinishedDoesNotAuthorizeWholeActivity() {
        let raw = """
        {"serverContent":{"inputTranscription":{"text":"確定した前半","finished":true}}}
        """
        check(GeminiWire.transcriptionFinished(raw))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(0.2)),
            endAcknowledgedAt: nil, now: end.advanced(by: .seconds(7))))
    }

    func pendingInterimBlocksAutoPaste() {
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(0.1)),
            endAcknowledgedAt: end.advanced(by: .seconds(0.2)), now: end.advanced(by: .seconds(3)),
            hasPendingInterim: true, lastTranscriptionAt: end.advanced(by: .seconds(1))))
    }

    func anyPreStopFinalNeedsAnAcknowledgement() {
        for age in [0.001, 0.25, 1.0, 2.0, 45.0] {
            check(!FinalizationPolicy.canFinish(endedAt: end,
                lastFinalAt: end.advanced(by: .seconds(-age)), endAcknowledgedAt: nil,
                now: end.advanced(by: .seconds(7))))
        }
    }

    func unscopedCompletionCannotBypassTheEndWrite() {
        // endedAt is the WRITE COMPLETION barrier, not the user's stop or the
        // start of a suspended socket send. These frames arrived during it.
        let delayedFinal = end.advanced(by: .seconds(-0.02))
        let earlyCompletion = end.advanced(by: .seconds(-0.01))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: delayedFinal,
            endAcknowledgedAt: earlyCompletion, now: end.advanced(by: .seconds(3))))
        check(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: delayedFinal,
            endAcknowledgedAt: end.advanced(by: .seconds(0.1)), now: end.advanced(by: .seconds(0.8))))
    }

    func manualEndAcceptsFastCompletionOnlyAfterSuccessfulWrite() {
        var endpoint = TimedManualEndpointState<ContinuousClock.Instant>()
        endpoint.beginEnd() // All queued PCM has already been written.
        endpoint.receiveTurnComplete(at: end.advanced(by: .seconds(-0.1)))
        check(endpoint.phase == .writingEnd)
        check(endpoint.acknowledgedEndAt == nil)
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(-0.05)),
            endAcknowledgedAt: endpoint.acknowledgedEndAt, now: end.advanced(by: .seconds(0.8))))
        // The socket send succeeds after the receive task handled its reply.
        endpoint.endWriteSucceeded(at: end)
        check(endpoint.writeCompletedAt == end)
        check(endpoint.acknowledgedEndAt == end)
        check(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(-0.05)),
            endAcknowledgedAt: endpoint.acknowledgedEndAt, now: end.advanced(by: .seconds(0.8))))
    }

    func manualEndIgnoresCompletionBeforeItsWriteBegins() {
        var endpoint = TimedManualEndpointState<ContinuousClock.Instant>()
        endpoint.receiveTurnComplete(at: end.advanced(by: .seconds(-0.2)))
        endpoint.beginEnd()
        endpoint.endWriteSucceeded(at: end)
        check(endpoint.acknowledgedEndAt == nil)
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(0.1)),
            endAcknowledgedAt: endpoint.acknowledgedEndAt, now: end.advanced(by: .seconds(0.8))))
        // A later, activity-scoped completion follows the other valid order.
        endpoint.receiveTurnComplete(at: end.advanced(by: .seconds(0.2)))
        check(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(0.1)),
            endAcknowledgedAt: endpoint.acknowledgedEndAt, now: end.advanced(by: .seconds(0.8))))
    }

    func failedOrCancelledEndWritesCannotAcknowledgeCompletion() {
        for cancelled in [false, true] {
            var endpoint = TimedManualEndpointState<ContinuousClock.Instant>()
            endpoint.beginEnd()
            endpoint.receiveTurnComplete(at: end.advanced(by: .seconds(-0.1)))
            if cancelled { endpoint.cancel() } else { endpoint.endWriteFailed() }
            // Late continuations and frames must not resurrect the operation.
            endpoint.endWriteSucceeded(at: end)
            endpoint.receiveTurnComplete(at: end.advanced(by: .seconds(0.1)))
            endpoint.beginEnd()
            check(endpoint.phase == (cancelled ? .cancelled : .failed))
            check(endpoint.writeCompletedAt == nil)
            check(endpoint.acknowledgedEndAt == nil)
            check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(0.1)),
                endAcknowledgedAt: endpoint.acknowledgedEndAt, now: end.advanced(by: .seconds(0.8))))
        }
    }

    func cancellationRevokesAnAcknowledgedManualEnd() {
        var endpoint = TimedManualEndpointState<ContinuousClock.Instant>()
        endpoint.beginEnd()
        endpoint.receiveTurnComplete(at: end.advanced(by: .seconds(-0.1)))
        endpoint.endWriteSucceeded(at: end)
        check(endpoint.acknowledgedEndAt != nil)
        endpoint.cancel()
        endpoint.receiveTurnComplete(at: end.advanced(by: .seconds(0.1)))
        check(endpoint.acknowledgedEndAt == nil)
    }

    func manualActivityEndFinalizesWithoutModelTurnComplete() throws {
        var endpoint = TimedManualEndpointState<ContinuousClock.Instant>()
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
                endpoint.receiveActivityEnd(at: end.advanced(by: .seconds(-0.05)))
            }
        }
        check(endpoint.acknowledgedEndAt == nil)
        endpoint.endWriteSucceeded(at: end)
        check(assembler.committedText == "3,000円です。")
        check(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(-0.05)),
            endAcknowledgedAt: endpoint.acknowledgedEndAt, now: end.advanced(by: .seconds(0.8)),
            hasPendingInterim: !assembler.interim.isEmpty))
        // The new acknowledgement does not authorize an unfinished suffix.
        assembler.apply(.interim("ただし"))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(-0.05)),
            endAcknowledgedAt: endpoint.acknowledgedEndAt, now: end.advanced(by: .seconds(0.8)),
            hasPendingInterim: !assembler.interim.isEmpty))
    }

    func manualActivityEndNeverBypassesFailedOrUnstartedEnd() {
        var early = TimedManualEndpointState<ContinuousClock.Instant>()
        early.receiveActivityEnd(at: end.advanced(by: .seconds(-0.2)))
        early.beginEnd()
        early.endWriteSucceeded(at: end)
        check(early.acknowledgedEndAt == nil)
        for cancelled in [false, true] {
            var endpoint = TimedManualEndpointState<ContinuousClock.Instant>()
            endpoint.beginEnd()
            endpoint.receiveActivityEnd(at: end.advanced(by: .seconds(-0.1)))
            if cancelled { endpoint.cancel() } else { endpoint.endWriteFailed() }
            endpoint.endWriteSucceeded(at: end)
            endpoint.receiveActivityEnd(at: end.advanced(by: .seconds(0.1)))
            check(endpoint.acknowledgedEndAt == nil)
            check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end,
                endAcknowledgedAt: endpoint.acknowledgedEndAt, now: end.advanced(by: .seconds(0.8))))
        }
    }

    func identicalInterimRemainsPendingUntilItsOwnFinal() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("こんにちは"))
        assembler.apply(.interim("こんにちは"))
        check(assembler.interim == "こんにちは")
        check(assembler.committedText == "こんにちは")
        check(assembler.recoveryText == "こんにちはこんにちは")
        assembler.apply(.final("こんにちは"))
        check(assembler.interim.isEmpty)
        check(assembler.committedText == "こんにちはこんにちは")
    }

    func retransmittedFinalIsNotNewAcceptedFinalization() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("これが確定済み"), segmentIdentity: "0s|1s|")
        let committedCount = assembler.finalCount
        assembler.apply(.interim("後続の指示"))
        assembler.apply(.final("これが確定済み"), segmentIdentity: "0s|1s|")
        check(assembler.finalCount == committedCount)
        check(assembler.committedText == "これが確定済み")
        check(assembler.interim == "後続の指示")
    }

    func conflictingTextForTheSameRangeRemainsRecoverable() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("30,000円です。"), segmentIdentity: "0s|1s|")
        assembler.apply(.final("3,000円です。"), segmentIdentity: "0s|1s|")
        check(assembler.hasConflictingFinals)
        check(assembler.recoveryText.contains("30,000円です。"))
        check(assembler.recoveryText.contains("3,000円です。"))
        check(assembler.finalCount == 2)
    }

    func consecutiveTurnsMayLegitimatelyUseTheSameWords() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("はい"), segmentIdentity: "0s|1s|")
        assembler.apply(.turnComplete)
        assembler.apply(.final("はい"), segmentIdentity: "0s|1s|")
        check(assembler.committedText == "はい")
        assembler.beginActivity()
        assembler.apply(.final("はい"), segmentIdentity: "0s|1s|")
        check(assembler.committedText == "はいはい")
    }

    func repeatedWordsWithinOneActivityArePreserved() {
        var assembler = TranscriptAssembler()
        assembler.beginActivity()
        assembler.apply(.final("はい"), segmentIdentity: "0s|1s|")
        assembler.apply(.final("はい"), segmentIdentity: "1s|2s|")
        assembler.apply(.final("はい"))
        check(assembler.committedText == "はいはいはい")
        check(assembler.finalCount == 3)
    }

    func laterTranscriptionResetsTheQuietPeriod() {
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(0.7)),
            endAcknowledgedAt: end.advanced(by: .seconds(0.1)), now: end.advanced(by: .seconds(0.8)),
            lastTranscriptionAt: end.advanced(by: .seconds(0.7))))
        check(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(0.7)),
            endAcknowledgedAt: end.advanced(by: .seconds(0.1)), now: end.advanced(by: .seconds(1.1)),
            lastTranscriptionAt: end.advanced(by: .seconds(0.7))))
    }

    func completionAloneAndFutureEventsCannotAuthorizeInsertion() {
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: nil,
            endAcknowledgedAt: end.advanced(by: .seconds(0.1)), now: end.advanced(by: .seconds(5))))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.advanced(by: .seconds(2)),
            endAcknowledgedAt: end.advanced(by: .seconds(0.1)), now: end.advanced(by: .seconds(1))))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end,
            endAcknowledgedAt: end.advanced(by: .seconds(2)), now: end.advanced(by: .seconds(1))))
    }
}
