#if os(macOS)
import Foundation
import KoeBridgeCore

/// Delivery decisions and descriptions. Queue order, history, and receipt
/// reconciliation stay with the controller that owns all in-flight takes.
@MainActor enum DictationDelivery {
    static let postingBusyDetail = "入力処理中のため未送信です。"

    struct Outcome {
        let delivery: TranscriptRecord.Delivery
        let detail: String
        let report: TextInsertion.Report?

        var submitted: Bool { delivery == .verifiedInserted || delivery == .attemptedUnconfirmed }

        func updateSavedRecord(_ id: UUID, in history: inout TranscriptHistoryStore) {
            history.updateDelivery(id, to: delivery, detail: historyInsertionDetail)
        }

        var deferredFeedback: OverlayFeedback? {
            switch delivery {
            case .verifiedInserted, .automaticPasteDisabled, .pending: return nil
            case .attemptedUnconfirmed: return .deferredUnconfirmed
            case .partiallyDirect: return .deferredPartial
            default: return .deferredUnsent
            }
        }

        var historyInsertionTitle: String {
            switch delivery {
            case .verifiedInserted: return "入力先への反映を確認しました"
            case .attemptedUnconfirmed: return "受理未確認"
            case .partiallyDirect: return "部分送信"
            default: return "未送信"
            }
        }

        var historyInsertionDetail: String {
            guard let report, report.outcome != .verifiedInserted else { return detail }
            switch report.reason {
            case "recovery_deadline_expired" where report.outcome != .partiallySubmitted:
                return "制限時間内に入力先を確認できませんでした。"
            case "recovery_host_changed" where report.outcome != .partiallySubmitted:
                return "入力欄・選択範囲の安全確認に失敗しました。"
            case "posting_busy": return detail
            case "delivery_cancelled_before_post":
                return "処理が中断されたため、入力前に停止しました。"
            default:
                guard let reason = InputDiagnosticEvent.Token(rawValue: report.reason) else { return detail }
                return detail + "（" + reason.rawValue + "）"
            }
        }

        var submissionFeedback: OverlayFeedback? {
            switch delivery {
            case .verifiedInserted: return .sent
            case .attemptedUnconfirmed: return .sentUnconfirmed
            default: return nil
            }
        }
    }

    struct DeferredFeedback {
        private var waiting: [(UUID, OverlayFeedback)] = []

        mutating func enqueueIfSuppressed(_ outcome: Outcome, id: UUID, owner: UUID?, recording: Bool) -> Bool {
            guard !OverlayFeedback.mayUpdate(owner: owner, resolved: id, newRecordingActive: recording),
                  let feedback = outcome.deferredFeedback else { return false }
            waiting.append((id, feedback))
            return true
        }

        mutating func next(owner: UUID?, recording: Bool, pendingTakes: Bool) -> (UUID, OverlayFeedback)? {
            guard owner == nil, !recording, !pendingTakes, !waiting.isEmpty else { return nil }
            return waiting.removeFirst()
        }
    }

    enum HistoryStartFailure: String, Error {
        case missing = "履歴の項目が見つかりません"
        case busy = "録音または入力処理中です"
    }

    static func historyStart(record: TranscriptRecord?, busy: Bool) -> Result<TranscriptRecord, HistoryStartFailure> {
        guard let record else { return .failure(.missing) }
        return busy ? .failure(.busy) : .success(record)
    }

    struct HeldCopy {
        let copied: Bool
        var feedback: OverlayFeedback { copied ? .heldForReview : .saved }
        var diagnostic: String { copied ? "copied=1" : "copied=0" }
    }

    static func skipped(suppressed: Bool, requiresReview: Bool,
                        acousticReviewRequired: Bool = false, shouldPaste: Bool) -> Outcome? {
        if suppressed {
            return Outcome(delivery: .blockedFocus, detail: "システム中断により自動入力しませんでした。", report: nil)
        }
        if requiresReview {
            return Outcome(delivery: .reviewRequired,
                           detail: acousticReviewRequired
                               ? "音声の活動を十分に確認できず、誤認識の可能性があるため自動入力せず履歴へ保存しました。"
                               : "再認識との違いを確認するため、自動入力せず両方の文章を保存しました。", report: nil)
        }
        if !shouldPaste {
            return Outcome(delivery: .automaticPasteDisabled,
                           detail: "自動入力がOFFのため、履歴へ保存しました。", report: nil)
        }
        return nil
    }

    static func classify(_ report: TextInsertion.Report) -> Outcome {
        let delivery: TranscriptRecord.Delivery
        switch report.outcome {
        case .verifiedInserted: delivery = .verifiedInserted
        case .inserted: delivery = .attemptedUnconfirmed
        case .focusChanged, .cancelled: delivery = .blockedFocus
        case .notPermitted, .eventPermissionMissing: delivery = .missingPermission
        case .partiallySubmitted: delivery = .partiallyDirect
        case .eventUnavailable: delivery = .insertionUnavailable
        }
        return Outcome(delivery: delivery,
                       detail: description(delivery, reason: report.reason),
                       report: report)
    }

    static func description(_ delivery: TranscriptRecord.Delivery, reason: String) -> String {
        switch delivery {
        case .verifiedInserted: return "入力先への反映を確認しました。履歴に保存済みです。"
        case .attemptedUnconfirmed: return "入力イベントを送信しました（受理は未確認）。再送の前に入力先を確認してください。"
        case .missingPermission where reason != "accessibility_not_granted":
            return "入力に必要な権限がありません。認識結果は履歴に保存しました。"
        case .partiallyDirect: return "入力が途中で中断しました。履歴を使う前に、入力先に入った範囲を確認してください。"
        case .insertionUnavailable: return "入力イベントを送信できませんでした。認識結果は履歴に保存しました。"
        default: break
        }
        switch reason {
        case "posting_busy": return postingBusyDetail
        case "marker_selection_changed", "caret_or_selection_changed": return "入力準備中にカーソルまたは選択範囲が変わったため、入力せず履歴に保存しました。"
        case "target_unavailable_at_delivery": return "現在の入力欄を取得できないため、入力せず履歴に保存しました。"
        case "secure_text_field": return "現在の入力先がパスワード欄のため、入力せず履歴に保存しました。"
        case "current_target_not_text_input": return "現在の入力先がテキスト入力欄ではないため、入力せず履歴に保存しました。"
        case "prior_input_unverified": return "前の文章の反映を確認できないため、続く文章を履歴に保存しました。"
        case "koebridge_window_is_frontmost": return "設定画面を閉じて入力欄を選んでください。認識結果は履歴に保存しました。"
        case "active_app_changed", "focused_field_changed", "focused_window_changed":
            return "入力準備中に入力先が変わったため、入力せず履歴に保存しました。"
        case "accessibility_not_granted": return "アクセシビリティの許可が必要です。認識結果は履歴に保存しました。"
        default: return "入力先の安全確認を完了できなかったため、履歴に保存しました。"
        }
    }
}
#endif
