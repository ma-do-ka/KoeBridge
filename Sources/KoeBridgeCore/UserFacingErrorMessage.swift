import Foundation

/// User-interface copy is selected only from error identity, never error text.
/// Keep the original error in diagnostics at the call site when appropriate.
public enum UserFacingErrorMessage {
    public static func message(for error: Error, operation: String? = nil,
                               isSparkleError: Bool = false) -> String {
        if error is CancellationError { return cancelled }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == 3072 { return cancelled }

        if isSparkleError || error.domain == "SUSparkleErrorDomain" {
            return updateMessage(code: error.code)
        }
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case -999: return cancelled
            case -1009: return "インターネットに接続されていません。接続を確認してください。"
            case -1001: return "通信が時間内に完了しませんでした。時間をおいてもう一度お試しください。"
            case -1004, -1005: return "サーバーに接続できませんでした。接続を確認してもう一度お試しください。"
            case -1003, -1006: return "サーバーの接続先を確認できませんでした。接続を確認してください。"
            case -1206 ... -1200, -1022:
                return "安全な通信を確立できませんでした。日時やネットワークの設定を確認してください。"
            default: break
            }
        }
        if error.domain == NSOSStatusErrorDomain || error.domain == "OSStatus" {
            // Security.framework errSec constants, without a platform dependency.
            switch error.code {
            case -25308: return "キーチェーンにアクセスできません。ロックを解除してもう一度お試しください。"
            case -25300: return "保存された認証情報が見つかりません。もう一度設定してください。"
            case -25293: return "認証情報を確認できませんでした。キーチェーンの許可を確認してください。"
            default: break
            }
        }
        let operation = operation?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(operation.flatMap { $0.isEmpty ? nil : $0 } ?? "処理")に失敗しました。時間をおいてもう一度お試しください。"
    }

    private static let cancelled = "操作を取り消しました。"

    private static func updateMessage(code: Int) -> String {
        // SUError values from Sparkle 2.10.1 SUErrors.h. Numeric identities keep
        // this pure mapper portable; Sparkle remains an application dependency.
        switch code {
        case 1, 2:
            return "更新の署名設定を確認できませんでした。リリースページから手動で更新してください。"
        case 3, 4:
            return "更新情報の接続先を確認できませんでした。リリースページから手動で更新してください。"
        case 5, 6, 5000:
            return "更新の設定を確認できませんでした。リリースページから手動で更新してください。"
        case 7, 4006:
            return "現在の版と更新の版を安全に比較できないため、更新を中止しました。リリースページを確認してください。"
        case 1000:
            return "更新情報を読み取れませんでした。時間をおいてもう一度お試しください。"
        case 1001:
            return "このアプリに適用できる新しい更新はありません。"
        case 1002, 1004:
            return "更新情報を取得できませんでした。接続を確認してもう一度お試しください。"
        case 1003, 1005:
            return "アプリをアプリケーションフォルダに移動してから、もう一度更新してください。"
        case 1006, 1007:
            return "更新内容の説明を表示できませんでした。リリースページを確認してください。"
        case 2000:
            return "更新用の一時ファイルを作成できませんでした。空き容量とアクセス権を確認してください。"
        case 2001:
            return "更新をダウンロードできませんでした。接続を確認してもう一度お試しください。"
        case 3000:
            return "更新ファイルを展開できませんでした。もう一度ダウンロードしてください。"
        case 3001, 3002, 4009:
            return "更新情報または更新ファイルの署名を検証できないため、更新を中止しました。時間をおいてもう一度お試しください。"
        case 4000, 4002, 4003, 4005, 4010:
            return "更新をインストールできませんでした。空き容量を確認し、もう一度お試しください。"
        case 4001, 4012:
            return "更新に必要なアクセス権を確認できませんでした。管理者の許可を確認してください。"
        case 4004:
            return "更新後の再起動を完了できませんでした。アプリを手動で起動してください。"
        case 4007:
            return cancelled
        case 4008:
            return "更新のインストールをあとで行います。"
        default:
            return "更新に失敗しました。時間をおいてもう一度お試しください。"
        }
    }
}
