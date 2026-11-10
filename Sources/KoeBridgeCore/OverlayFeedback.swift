import Foundation

/// UI feedback is deliberately separate from the session state machine.
/// "sent" means key events were submitted, not that another app accepted them.
public enum OverlayFeedback: String, Equatable, Sendable {
    case transforming, transformCopied, transformFailed
    case hidden
    case preparing
    case recording
    case ending
    case processing
    case checking
    case noInput
    case sent
    case saved
    case heldForReview
    case failed

    public var message: String {
        switch self {
        case .transforming: return "選択テキストを変換中…"
        case .transformCopied: return "変換結果をコピーしました。入力先を確認してください"
        case .transformFailed: return "選択テキストの変換を完了できませんでした"
        case .hidden: return ""
        case .preparing: return "マイクを準備しています…"
        case .recording: return "話してください…"
        case .ending: return "録音を終了しています…"
        case .processing: return "文字起こしを確定しています…"
        case .checking: return "追加チェック中…"
        case .noInput: return "音声入力なし"
        case .sent: return "入力イベントを送信しました"
        case .saved: return "文字起こしを履歴に保存しました"
        case .heldForReview: return "発話を確認できず保留しました。文章をコピーしました"
        case .failed: return "文字起こしを確認できませんでした"
        }
    }

    /// A previous take must never hide or overwrite the overlay for a new one.
    public static func mayUpdate(owner: UUID?, resolved: UUID, newRecordingActive: Bool) -> Bool {
        owner == resolved && !newRecordingActive
    }
}
