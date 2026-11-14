import Foundation
import KoeBridgeCore

struct OverlayFeedbackTests {
    func unconfirmedSubmissionHasDistinctVisibleFeedback() {
        check(OverlayFeedback.sentUnconfirmed != .sent)
        check(OverlayFeedback.sentUnconfirmed.message != OverlayFeedback.sent.message)
        check(OverlayFeedback.sentUnconfirmed.message.contains("未確認"))
    }

    func feedbackDoesNotClaimDestinationAcceptedText() {
        check(OverlayFeedback.processing.message.contains("確定"))
        check(OverlayFeedback.sent.message.contains("送信"))
        check(!OverlayFeedback.sent.message.contains("入力完了"))
        check(OverlayFeedback.saved.message.contains("履歴"))
        check(OverlayFeedback.failed.message.contains("できません"))
    }

    func accidentalTapIsNeutralAndNotAnError() {
        check(OverlayFeedback.ending.message.contains("終了"))
        check(OverlayFeedback.noInput.message == "音声入力なし")
        check(!OverlayFeedback.noInput.message.contains("失敗"))
        check(!OverlayFeedback.noInput.message.contains("エラー"))
    }

    func olderFinalizationCannotOverwriteNewRecording() {
        let old = UUID()
        let current = UUID()
        check(!OverlayFeedback.mayUpdate(owner: current, resolved: old,
                                            newRecordingActive: false))
        check(!OverlayFeedback.mayUpdate(owner: current, resolved: current,
                                            newRecordingActive: true))
        check(OverlayFeedback.mayUpdate(owner: current, resolved: current,
                                           newRecordingActive: false))
        check(!OverlayFeedback.mayUpdate(owner: nil, resolved: current,
                                            newRecordingActive: false))
    }
}
