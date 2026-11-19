import Foundation
import KoeBridgeCore

struct OverlayFeedbackTests {
    func unconfirmedSubmissionHasDistinctVisibleFeedback() {
        check(OverlayFeedback.sentUnconfirmed != .sent)
        check(OverlayFeedback.sentUnconfirmed.message != OverlayFeedback.sent.message)
        check(OverlayFeedback.sentUnconfirmed.message == "入力完了")
    }

    func feedbackDoesNotClaimDestinationAcceptedText() {
        check(OverlayFeedback.processing.message.contains("確定"))
        check(OverlayFeedback.sent.message.contains("送信"))
        check(!OverlayFeedback.sent.message.contains("入力完了"))
        check(OverlayFeedback.saved.message.contains("履歴"))
        check(OverlayFeedback.failed.message.contains("できません"))
    }

    func blockedHeldAndFailedKeepTheirMessages() {
        check(OverlayFeedback.commandBlocked.message == "コマンドとして実行できませんでした（安全確認）")
        check(OverlayFeedback.deferredUnsent.message == "前の入力は未送信です。履歴を確認してください")
        check(OverlayFeedback.deferredPartial.message == "前の入力は部分送信です。履歴と入力先を確認してください")
        check(OverlayFeedback.deferredUnconfirmed.message == "前の入力は受理未確認です。再送前に入力先を確認してください")
        check(OverlayFeedback.saved.message == "文字起こしを履歴に保存しました")
        check(OverlayFeedback.heldForReview.message == "発話を確認できず保留しました。文章をコピーしました")
        check(OverlayFeedback.failed.message == "文字起こしを確認できませんでした")
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
