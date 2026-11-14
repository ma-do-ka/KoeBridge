import Foundation
import Testing
@testable import KoeBridgeCore

struct OverlayFeedbackTests {
    @Test func unconfirmedSubmissionHasDistinctVisibleFeedback() {
        #expect(OverlayFeedback.sentUnconfirmed != .sent)
        #expect(OverlayFeedback.sentUnconfirmed.message != OverlayFeedback.sent.message)
        #expect(OverlayFeedback.sentUnconfirmed.message.contains("未確認"))
    }

    @Test func feedbackDoesNotClaimDestinationAcceptedText() {
        #expect(OverlayFeedback.processing.message.contains("確定"))
        #expect(OverlayFeedback.sent.message.contains("送信"))
        #expect(!OverlayFeedback.sent.message.contains("入力完了"))
        #expect(OverlayFeedback.saved.message.contains("履歴"))
        #expect(OverlayFeedback.failed.message.contains("できません"))
    }

    @Test func accidentalTapIsNeutralAndNotAnError() {
        #expect(OverlayFeedback.ending.message.contains("終了"))
        #expect(OverlayFeedback.noInput.message == "音声入力なし")
        #expect(!OverlayFeedback.noInput.message.contains("失敗"))
        #expect(!OverlayFeedback.noInput.message.contains("エラー"))
    }

    @Test func olderFinalizationCannotOverwriteNewRecording() {
        let old = UUID()
        let current = UUID()
        #expect(!OverlayFeedback.mayUpdate(owner: current, resolved: old,
                                            newRecordingActive: false))
        #expect(!OverlayFeedback.mayUpdate(owner: current, resolved: current,
                                            newRecordingActive: true))
        #expect(OverlayFeedback.mayUpdate(owner: current, resolved: current,
                                           newRecordingActive: false))
        #expect(!OverlayFeedback.mayUpdate(owner: nil, resolved: current,
                                            newRecordingActive: false))
    }
}
