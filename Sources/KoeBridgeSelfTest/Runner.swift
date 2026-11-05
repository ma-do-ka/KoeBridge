import Foundation
import KoeBridgeCore
import KoeBridgePOSIX

// Portable verification: no XCTest or Swift Testing framework required.
// Full Swift Testing suite remains in Tests/ and should run under a complete toolchain.
enum TestRecorder {
    static let lock = NSLock()
    nonisolated(unsafe) static var checked = 0
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var current = ""
    static func begin(_ test: String) {
        lock.lock(); current = test; lock.unlock()
    }
    static func assertion(_ ok: Bool, file: StaticString, line: UInt, message: String = "") {
        lock.lock(); defer { lock.unlock() }
        checked += 1
        guard !ok else { return }
        failures += 1
        fputs("FAIL: \(current) at \(file):\(line) \(message)\n", stderr)
    }
}

struct MissingRequiredValue: Error { let message: String }

func check(_ condition: @autoclosure () throws -> Bool, file: StaticString = #fileID, line: UInt = #line) rethrows {
    TestRecorder.assertion(try condition(), file: file, line: line)
}
func require<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else {
        TestRecorder.assertion(false, file: file, line: line, message: "required value missing")
        throw MissingRequiredValue(message: "required value missing")
    }
    TestRecorder.assertion(true, file: file, line: line)
    return value
}
func checkThrows(_ expected: Any.Type, file: StaticString = #fileID, line: UInt = #line,
                 _ body: () throws -> Void) {
    do {
        try body()
        TestRecorder.assertion(false, file: file, line: line, message: "expected error was not thrown")
    } catch {
        let actual = Swift.type(of: error)
        let acceptAny = String(reflecting: expected) == "Swift.Error"
            || String(reflecting: expected) == "Error"
        TestRecorder.assertion(acceptAny || actual == expected, file: file, line: line,
                               message: "wrong error type: \(actual), expected \(expected)")
    }
}
func recordFailure(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
    TestRecorder.assertion(false, file: file, line: line, message: message)
}

@main
struct KoeBridgeSelfTest {
    static func main() async {
        var testCount = 0
        func run(_ name: String, _ action: () async throws -> Void) async {
            testCount += 1
            TestRecorder.begin(name)
            do { try await action() }
            catch { TestRecorder.assertion(false, file: #fileID, line: #line, message: "test threw: \(error)") }
        }
        await run("DiagnosticLogPolicyTests.disabledByDefaultEvenWhenUnset", { DiagnosticLogPolicyTests().disabledByDefaultEvenWhenUnset() })
        await run("DiagnosticLogPolicyTests.normalEventCannotBreakIntoTwoLogLines", { DiagnosticLogPolicyTests().normalEventCannotBreakIntoTwoLogLines() })
        await run("DiagnosticLogPolicyTests.boundedRotationMath", { DiagnosticLogPolicyTests().boundedRotationMath() })
        await run("DiagnosticLogPolicyTests.systemInterruptionArchiveValueRoundTrips", { try DiagnosticLogPolicyTests().systemInterruptionArchiveValueRoundTrips() })
        await run("DiagnosticLogPolicyTests.onDiskRotationAndDeletionAreBounded", { try DiagnosticLogPolicyTests().onDiskRotationAndDeletionAreBounded() })
        await run("DiagnosticLogPolicyTests.aSymlinkMustNotBeOverwritten", { try DiagnosticLogPolicyTests().aSymlinkMustNotBeOverwritten() })
        await run("DirectInputObservationTests.verifiesAppendingJapanese", { DirectInputObservationTests().verifiesAppendingJapanese() })
        await run("DirectInputObservationTests.verifiesSelectionReplacement", { DirectInputObservationTests().verifiesSelectionReplacement() })
        await run("DirectInputObservationTests.detectsSilentlyIgnoredEvent", { DirectInputObservationTests().detectsSilentlyIgnoredEvent() })
        await run("DirectInputObservationTests.refusesUnobservableBrowserEditor", { DirectInputObservationTests().refusesUnobservableBrowserEditor() })
        await run("DirectInputObservationTests.refusesUnrelatedEditAsVerification", { DirectInputObservationTests().refusesUnrelatedEditAsVerification() })
        await run("DirectInputObservationTests.preservesEmojiAndRepeatedCharacters", { DirectInputObservationTests().preservesEmojiAndRepeatedCharacters() })
        await run("DirectTypingPlanTests.preservesJapaneseAndLatin", { DirectTypingPlanTests().preservesJapaneseAndLatin() })
        await run("DirectTypingPlanTests.preservesEmojiGraphemeClusters", { DirectTypingPlanTests().preservesEmojiGraphemeClusters() })
        await run("DirectTypingPlanTests.preventsReturnAndTabActions", { DirectTypingPlanTests().preventsReturnAndTabActions() })
        await run("DirectTypingPlanTests.doesNotSplitEmojiSurrogates", { DirectTypingPlanTests().doesNotSplitEmojiSurrogates() })
        await run("DirectTypingPlanTests.longMixedTextRoundTrips", { DirectTypingPlanTests().longMixedTextRoundTrips() })
        await run("DirectTypingPlanTests.emptyIsNotTyped", { DirectTypingPlanTests().emptyIsNotTyped() })
        await run("LoginItemRegistrationPolicyTests.registrationFromNotFoundDoesNotPretendApproval", {
            LoginItemRegistrationPolicyTests().registrationFromNotFoundDoesNotPretendApproval()
        })
        await run("LoginItemRegistrationPolicyTests.unregisterOnlyWhenActuallyRegistered", {
            LoginItemRegistrationPolicyTests().unregisterOnlyWhenActuallyRegistered()
        })
        await run("PermissionSetupPolicyTests.neverClaimsSetupDoneWithoutBothGrants", {
            PermissionSetupPolicyTests().neverClaimsSetupDoneWithoutBothGrants()
        })
        await run("PermissionSetupPolicyTests.directInputRequiresActualProcessPermissionAndTarget", {
            PermissionSetupPolicyTests().directInputRequiresActualProcessPermissionAndTarget()
        })
        await run("AudioDurationTests.immediateSecondPressDoesNotWaitForCloudFinal", { AudioDurationTests().immediateSecondPressDoesNotWaitForCloudFinal() })
        await run("AudioDurationTests.rapidEmptyInputIsNeutralButSpeechAndLossRemainReal", { AudioDurationTests().rapidEmptyInputIsNeutralButSpeechAndLossRemainReal() })
        await run("FileLockTests.secondHandleCannotAcquireUntilFirstCloses", { try FileLockTests().secondHandleCannotAcquireUntilFirstCloses() })
        await run("GeminiFailureTests.liveAPIErrorReported", { try GeminiFailureTests().liveAPIErrorReported() })
        await run("GeminiFailureTests.liveAPIUnknownMessageIsIgnored", { try GeminiFailureTests().liveAPIUnknownMessageIsIgnored() })
        await run("GeminiFailureTests.missingServerTextDoesNotCrash", { try GeminiFailureTests().missingServerTextDoesNotCrash() })
        await run("GeminiFailureTests.emptyInputIsError", { GeminiFailureTests().emptyInputIsError() })
        await run("GeminiFailureTests.manualVADStartAndEndAreRealJSON", { try GeminiFailureTests().manualVADStartAndEndAreRealJSON() })
        await run("GeminiFailureTests.hybridVADUsesAutomaticDetectionAndAudioStreamEnd", { try GeminiFailureTests().hybridVADUsesAutomaticDetectionAndAudioStreamEnd() })
        await run("GeminiFailureTests.largeVocabularyIsCappedAtOneHundred", { try GeminiFailureTests().largeVocabularyIsCappedAtOneHundred() })
        await run("GeminiFinalizationTests.aFinalBeforeTheStopIsNotProofThatTheEndWasReceived", { GeminiFinalizationTests().aFinalBeforeTheStopIsNotProofThatTheEndWasReceived() })
        await run("GeminiFinalizationTests.anOldTurnCompleteMustNotAuthorizeTheNewStop", { GeminiFinalizationTests().anOldTurnCompleteMustNotAuthorizeTheNewStop() })
        await run("GeminiFinalizationTests.aNewTurnCompleteCanAuthorizeAnEarlierFinal", { GeminiFinalizationTests().aNewTurnCompleteCanAuthorizeAnEarlierFinal() })
        await run("GeminiFinalizationTests.aNewFinalCanFinishAfterQuietPeriodWithoutTurnComplete", { GeminiFinalizationTests().aNewFinalCanFinishAfterQuietPeriodWithoutTurnComplete() })
        await run("GeminiFinalizationTests.pendingInterimBlocksAutoPaste", { GeminiFinalizationTests().pendingInterimBlocksAutoPaste() })
        await run("GeminiFinalizationTests.recentPreStopFinalAndOldFinalAreDifferent", { GeminiFinalizationTests().recentPreStopFinalAndOldFinalAreDifferent() })
        await run("GeminiFinalizationTests.anEarlierFinalForTheLastSpeechSegmentCanCompleteWithoutTurnComplete", { GeminiFinalizationTests().anEarlierFinalForTheLastSpeechSegmentCanCompleteWithoutTurnComplete() })
        await run("GeminiFinalizationTests.outOfOrderIdenticalInterimCannotBlockAFinal", { GeminiFinalizationTests().outOfOrderIdenticalInterimCannotBlockAFinal() })
        await run("GeminiFinalizationTests.retransmittedFinalIsNotNewAcceptedFinalization", { GeminiFinalizationTests().retransmittedFinalIsNotNewAcceptedFinalization() })
        await run("GeminiFinalizationTests.consecutiveTurnsMayLegitimatelyUseTheSameWords", { GeminiFinalizationTests().consecutiveTurnsMayLegitimatelyUseTheSameWords() })
        await run("TranscriptionStyleSelfTests.preservesLegacyChoiceAndNewMode", { TranscriptionStyleSelfTests().preservesLegacyChoiceAndNewMode() })
        await run("TranscriptionStyleSelfTests.agentModeUsesSupportedGeminiWire", { try TranscriptionStyleSelfTests().agentModeUsesSupportedGeminiWire() })
        await run("TranscriptionStyleSelfTests.noTechnicalDetailIsDeletedByFormatting", { TranscriptionStyleSelfTests().noTechnicalDetailIsDeletedByFormatting() })
        await run("GeminiWireTests.setupAndAudioMatchGoogleWireFormat", { try GeminiWireTests().setupAndAudioMatchGoogleWireFormat() })
        await run("GeminiWireTests.parseInterimFinalTurnComplete", { try GeminiWireTests().parseInterimFinalTurnComplete() })
        await run("GeminiWireTests.setupComplete", { try GeminiWireTests().setupComplete() })
        await run("GeminiWireTests.assemblerJapaneseSegmentsAndEnglish", { GeminiWireTests().assemblerJapaneseSegmentsAndEnglish() })
        await run("GeminiWireTests.assemblerCumulativeFinal", { GeminiWireTests().assemblerCumulativeFinal() })
        await run("GeminiWireTests.recoveryRetainsUncommittedInstructions", { GeminiWireTests().recoveryRetainsUncommittedInstructions() })
        await run("HotKeyRecoveryTests.explicitPhysicalReleaseReconcilesMissingCarbonUp", { HotKeyRecoveryTests().explicitPhysicalReleaseReconcilesMissingCarbonUp() })
        await run("HotKeyRecoveryTests.oldRegistrationsCannotAffectNewHotkeys", { HotKeyRecoveryTests().oldRegistrationsCannotAffectNewHotkeys() })
        await run("HotKeyRecoveryTests.missedRightCommandUpCanBeReconciledWithoutDoubleToggle", { HotKeyRecoveryTests().missedRightCommandUpCanBeReconciledWithoutDoubleToggle() })
        await run("HotKeyRecoveryTests.noAccidentalToggleAfterCancelledModifierTap", { HotKeyRecoveryTests().noAccidentalToggleAfterCancelledModifierTap() })
        await run("InsertionSafetyTests.neverPasteToWindowOnlyTarget(false)", { InsertionSafetyTests().neverPasteToWindowOnlyTarget(false) })
        await run("InsertionSafetyTests.neverPasteToWindowOnlyTarget(true)", { InsertionSafetyTests().neverPasteToWindowOnlyTarget(true) })
        await run("InsertionSafetyTests.movingTheCaretInTheSameEditorBlocksPasteWhenObservable", { InsertionSafetyTests().movingTheCaretInTheSameEditorBlocksPasteWhenObservable() })
        await run("InsertionSafetyTests.validCaptureAndCurrentFocusPermitPaste", { InsertionSafetyTests().validCaptureAndCurrentFocusPermitPaste() })
        await run("InsertionSafetyTests.unknownCaretMayPasteOnlyWhenTheSameTextFieldIsVerified", { InsertionSafetyTests().unknownCaretMayPasteOnlyWhenTheSameTextFieldIsVerified() })
        await run("InsertionSafetyTests.focusedElementOwnedByDifferentProcessMustBlockPaste", { InsertionSafetyTests().focusedElementOwnedByDifferentProcessMustBlockPaste() })
        await run("InsertionSafetyTests.anotherWindowOrAppMustBlockPaste", { InsertionSafetyTests().anotherWindowOrAppMustBlockPaste() })
        await run("ModifierToggleDetectorTests.rightCommandSolitaryTapTogglesOnlyOnRelease", { ModifierToggleDetectorTests().rightCommandSolitaryTapTogglesOnlyOnRelease() })
        await run("ModifierToggleDetectorTests.modifierUsedInShortcutDoesNotToggle", { ModifierToggleDetectorTests().modifierUsedInShortcutDoesNotToggle() })
        await run("ModifierToggleDetectorTests.secondModifierDuringHoldCancels", { ModifierToggleDetectorTests().secondModifierDuringHoldCancels() })
        await run("ModifierToggleDetectorTests.modifierAlreadyCombinedAtPressDoesNotToggle", { ModifierToggleDetectorTests().modifierAlreadyCombinedAtPressDoesNotToggle() })
        await run("ModifierToggleDetectorTests.twoSeparateCleanTapsEachToggle", { ModifierToggleDetectorTests().twoSeparateCleanTapsEachToggle() })
        await run("ModifierToggleDetectorTests.spuriousReleaseAndReset", { ModifierToggleDetectorTests().spuriousReleaseAndReset() })
        await run("ModifierToggleDetectorTests.familyFlagStillSetByOtherSideOnRelease", { ModifierToggleDetectorTests().familyFlagStillSetByOtherSideOnRelease() })
        await run("RecentTranscriptArchiveTests.persistsNewestTenAcrossRestarts", { try RecentTranscriptArchiveTests().persistsNewestTenAcrossRestarts() })
        await run("RecentTranscriptArchiveTests.deliveryStatusPersistsAndPartialIsRecoverable", { try RecentTranscriptArchiveTests().deliveryStatusPersistsAndPartialIsRecoverable() })
        await run("RecentTranscriptArchiveTests.deletionOnlyAffectsSelectedRecord", { try RecentTranscriptArchiveTests().deletionOnlyAffectsSelectedRecord() })
        await run("RecentTranscriptArchiveTests.emptyRecordIsNotStored", { try RecentTranscriptArchiveTests().emptyRecordIsNotStored() })
        await run("RecentTranscriptArchiveTests.corruptDataIsNotSilentlyOverwritten", { try RecentTranscriptArchiveTests().corruptDataIsNotSilentlyOverwritten() })
        await run("RecentTranscriptArchiveTests.historyIsPrivateAtFilesystemLevel", { try RecentTranscriptArchiveTests().historyIsPrivateAtFilesystemLevel() })
        await run("ResilienceTests.hotkeyF8OnlyTogglesOncePerPress", { ResilienceTests().hotkeyF8OnlyTogglesOncePerPress() })
        await run("ResilienceTests.hotkeySwitchRejectsStaleOldEvents", { ResilienceTests().hotkeySwitchRejectsStaleOldEvents() })
        await run("ResilienceTests.finalBeforeReleaseCannotFinalizeEarly", { ResilienceTests().finalBeforeReleaseCannotFinalizeEarly() })
        await run("ResilienceTests.finalAndTurnCompleteInEitherOrder", { ResilienceTests().finalAndTurnCompleteInEitherOrder() })
        await run("ResilienceTests.finalQuietTimeMustPassWithoutTurnComplete", { ResilienceTests().finalQuietTimeMustPassWithoutTurnComplete() })
        await run("ResilienceTests.droppedAudioIsRememberedAcrossThreads", { ResilienceTests().droppedAudioIsRememberedAcrossThreads() })
        await run("ResilienceTests.oversizedArchiveIsRejectedWithoutOverwrite", { try ResilienceTests().oversizedArchiveIsRejectedWithoutOverwrite() })
        await run("ResilienceTests.temporaryAudioQueueDropsButNeverOverwritesOldest", { await ResilienceTests().temporaryAudioQueueDropsButNeverOverwritesOldest() })
        await run("StressTests.tenThousandCarbonCyclesNeverDuplicateARecording", { StressTests().tenThousandCarbonCyclesNeverDuplicateARecording() })
        await run("StressTests.tenThousandRightCommandTapsToggleOncePerTap", { StressTests().tenThousandRightCommandTapsToggleOncePerTap() })
        await run("StressTests.finalizationNeverAuthorizesUnacknowledgedPreStopResult", { StressTests().finalizationNeverAuthorizesUnacknowledgedPreStopResult() })
        await run("StressTests.aThousandTranscriptWritesRetainTheNewestTen", { try StressTests().aThousandTranscriptWritesRetainTheNewestTen() })
        await run("SessionTransitionsTests.normalStartStopStartAgain", { SessionTransitionsTests().normalStartStopStartAgain() })
        await run("SessionTransitionsTests.finalizationCannotReserveOrBlockANewRecording", { SessionTransitionsTests().finalizationCannotReserveOrBlockANewRecording() })
        await run("SessionTransitionsTests.repeatedProcessingPressNeverEnqueuesGhostRestart", { SessionTransitionsTests().repeatedProcessingPressNeverEnqueuesGhostRestart() })
        await run("SessionTransitionsTests.preparingPressCancelsWithoutDelayedAutoRestart", { SessionTransitionsTests().preparingPressCancelsWithoutDelayedAutoRestart() })
        await run("SessionTransitionsTests.stopAfterACompletedTurnCanStartImmediately", { SessionTransitionsTests().stopAfterACompletedTurnCanStartImmediately() })
        await run("OrderedResultBufferTests.anEarlierUnfinishedTakeDoesNotBlockStartingAnother", { OrderedResultBufferTests().anEarlierUnfinishedTakeDoesNotBlockStartingAnother() })
        await run("OrderedResultBufferTests.repeatedCallbacksAndUnknownIdsDoNotDuplicate", { OrderedResultBufferTests().repeatedCallbacksAndUnknownIdsDoNotDuplicate() })
        await run("OrderedResultBufferTests.boundedJobsAndFailureUnblock", { OrderedResultBufferTests().boundedJobsAndFailureUnblock() })
        await run("OrderedResultBufferTests.cancelledSessionClearsPreviousResults", { OrderedResultBufferTests().cancelledSessionClearsPreviousResults() })
        await run("OrderedResultBufferTests.rapidSuccessionsAlwaysStayInOrder", { OrderedResultBufferTests().rapidSuccessionsAlwaysStayInOrder() })
        await run("GeminiWireTests.unknownFramesCanBeDiagnosedWithoutLeakingTheirText", { GeminiWireTests().unknownFramesCanBeDiagnosedWithoutLeakingTheirText() })
        print("KoeBridge portable self-test: \(testCount) cases, \(TestRecorder.checked) assertions, \(TestRecorder.failures) failures")
        if TestRecorder.failures > 0 { exit(1) }
    }
}
