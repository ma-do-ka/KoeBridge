#if os(macOS)
import Foundation
import KoeBridgeCore

/// Delivery decisions and descriptions. Queue order, history, and receipt
/// reconciliation stay with the controller that owns all in-flight takes.
@MainActor enum DictationDelivery {
    struct Outcome {
        let delivery: TranscriptRecord.Delivery
        let detail: String
        let report: TextInsertion.Report?

        var submitted: Bool { delivery == .verifiedInserted || delivery == .attemptedUnconfirmed }
    }

    static func skipped(suppressed: Bool, requiresReview: Bool, shouldPaste: Bool) -> Outcome? {
        if suppressed {
            return Outcome(delivery: .blockedFocus, detail: "システム中断により自動入力しませんでした。", report: nil)
        }
        if requiresReview {
            return Outcome(delivery: .reviewRequired,
                           detail: "再認識との違いを確認するため、自動入力せず両方の文章を保存しました。", report: nil)
        }
        if !shouldPaste {
            return Outcome(delivery: .automaticPasteDisabled,
                           detail: "自動入力がOFFのため、履歴へ保存しました。", report: nil)
        }
        return nil
    }

    static func send(_ text: String, to target: InsertionTarget?, captureReason: String,
                     shouldContinue: @MainActor () -> Bool) async -> Outcome {
        let report = await TextInsertion.deliver(text, to: target, shouldContinue: shouldContinue)
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
                       detail: description(delivery, reason: target == nil ? captureReason : report.reason),
                       report: report)
    }

    private static func description(_ delivery: TranscriptRecord.Delivery, reason: String) -> String {
        switch delivery {
        case .verifiedInserted: return "入力先への反映を確認しました。履歴に保存済みです。"
        case .attemptedUnconfirmed: return "入力イベントを送信しました（受理は未確認）。再送の前に入力先を確認してください。"
        case .missingPermission: return "入力に必要な権限がありません。認識結果は履歴に保存しました。"
        case .partiallyDirect: return "入力が途中で中断しました。履歴を使う前に、入力先に入った範囲を確認してください。"
        case .insertionUnavailable: return "入力イベントを送信できませんでした。認識結果は履歴に保存しました。"
        default: break
        }
        switch reason {
        case "caret_or_selection_changed": return "カーソルまたは選択範囲が変わったため、入力せず履歴に保存しました。"
        case "prior_input_unverified": return "前の文章の反映を確認できないため、続く文章を履歴に保存しました。"
        case "koebridge_window_is_frontmost": return "設定画面を閉じて入力欄を選んでください。認識結果は履歴に保存しました。"
        case "active_app_changed", "focused_field_changed", "focused_window_changed":
            return "録音開始時と入力先が変わったため、入力せず履歴に保存しました。"
        case "accessibility_not_granted": return "アクセシビリティの許可が必要です。認識結果は履歴に保存しました。"
        default: return "入力先の安全確認を完了できなかったため、履歴に保存しました。"
        }
    }
}
#endif
