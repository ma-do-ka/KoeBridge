import Foundation
import Testing
@testable import KoeBridgeCore

struct UserFacingErrorMessageTests {
    private let rawDescription = "The update feed is improperly signed and could not be validated."

    private func error(_ domain: String, _ code: Int) -> NSError {
        NSError(domain: domain, code: code, userInfo: [
            NSLocalizedDescriptionKey: rawDescription,
            NSLocalizedFailureReasonErrorKey: "A raw failure reason must not reach the interface.",
            NSLocalizedRecoverySuggestionErrorKey: "An English recovery suggestion must not leak."
        ])
    }

    @Test func allSparkleCodesHaveJapaneseMessages() {
        let groups: [([Int], String)] = [
            ([1, 2], "署名設定"), ([3, 4], "接続先"), ([5, 6, 5000], "更新の設定"),
            ([7, 4006], "比較"), ([1000], "読み取れません"),
            ([1001], "新しい更新はありません"), ([1002, 1004], "取得できません"),
            ([1003, 1005], "移動"), ([1006, 1007], "説明"),
            ([2000], "一時ファイル"), ([2001], "ダウンロードできません"),
            ([3000], "展開"), ([3001, 3002, 4009], "署名を検証"),
            ([4000, 4002, 4003, 4005, 4010], "インストールできません"),
            ([4001, 4012], "アクセス権"), ([4004], "再起動"),
            ([4007], "取り消しました"), ([4008], "あとで")
        ]
        for (codes, expected) in groups {
            for code in codes {
                let input = error("SUSparkleErrorDomain", code)
                let message = UserFacingErrorMessage.message(for: input)
                #expect(message.contains(expected))
                #expect(!message.contains(input.localizedDescription))
                #expect(message.range(of: "[A-Za-z]", options: .regularExpression) == nil)
            }
        }
    }

    @Test func networkCodesHaveJapaneseMessages() {
        let groups: [([Int], String)] = [
            ([-999], "取り消しました"), ([-1009], "接続されていません"),
            ([-1001], "時間内"), ([-1004, -1005], "接続できません"),
            ([-1003, -1006], "接続先"),
            ([-1200, -1201, -1202, -1203, -1204, -1205, -1206, -1022], "安全な通信")
        ]
        for (codes, expected) in groups {
            for code in codes {
                let input = error(NSURLErrorDomain, code)
                let message = UserFacingErrorMessage.message(for: input, operation: "更新")
                #expect(message.contains(expected))
                #expect(!message.contains(input.localizedDescription))
                #expect(message.range(of: "[A-Za-z]", options: .regularExpression) == nil)
            }
        }
    }

    @Test func keychainCodesHaveJapaneseMessages() {
        for domain in [NSOSStatusErrorDomain, "OSStatus"] {
            for (code, expected) in [(-25308, "ロックを解除"), (-25300, "見つかりません"), (-25293, "許可")] {
                let input = error(domain, code)
                let message = UserFacingErrorMessage.message(for: input)
                #expect(message.contains(expected))
                #expect(!message.contains(input.localizedDescription))
                #expect(message.range(of: "[A-Za-z]", options: .regularExpression) == nil)
            }
        }
    }

    @Test func cancellationIsQuietAndDoesNotUseOperationFailure() {
        let expected = "操作を取り消しました。"
        #expect(UserFacingErrorMessage.message(for: CancellationError(), operation: "更新") == expected)
        #expect(UserFacingErrorMessage.message(for: error(NSCocoaErrorDomain, 3072), operation: "更新") == expected)
        #expect(UserFacingErrorMessage.message(for: error(NSURLErrorDomain, -999), operation: "更新") == expected)
        #expect(UserFacingErrorMessage.message(for: error("SUSparkleErrorDomain", 4007), operation: "更新") == expected)
    }

    @Test func genericFallbackUsesOnlyTheSuppliedOperation() {
        for domain in ["unknown.domain", NSURLErrorDomain, NSOSStatusErrorDomain] {
            let input = error(domain, 987654)
            #expect(UserFacingErrorMessage.message(for: input) == "処理に失敗しました。時間をおいてもう一度お試しください。")
            #expect(UserFacingErrorMessage.message(for: input, operation: "更新") == "更新に失敗しました。時間をおいてもう一度お試しください。")
            #expect(UserFacingErrorMessage.message(for: input, operation: "  APIキーの保存\n") == "APIキーの保存に失敗しました。時間をおいてもう一度お試しください。")
            #expect(UserFacingErrorMessage.message(for: input, operation: "  \n") == UserFacingErrorMessage.message(for: input))
            #expect(!UserFacingErrorMessage.message(for: input, operation: "更新").contains(input.localizedDescription))
        }
    }

    @Test func unknownSparkleAndExplicitSparkleFlagUseUpdateFallback() {
        let expected = "更新に失敗しました。時間をおいてもう一度お試しください。"
        #expect(UserFacingErrorMessage.message(for: error("SUSparkleErrorDomain", 99999)) == expected)
        #expect(UserFacingErrorMessage.message(for: error("wrapper.domain", 99999), isSparkleError: true) == expected)
        #expect(UserFacingErrorMessage.message(for: error("wrapper.domain", 2001), isSparkleError: true).contains("ダウンロードできません"))
        #expect(UserFacingErrorMessage.message(for: error("wrapper.domain", 2001)) == "処理に失敗しました。時間をおいてもう一度お試しください。")
    }

    @Test func descriptionsAndUnderlyingErrorsNeverReachTheInterface() {
        let input = NSError(domain: "unknown.domain", code: 12, userInfo: [
            NSLocalizedDescriptionKey: "English outer error sentence.",
            NSUnderlyingErrorKey: error(NSURLErrorDomain, -1009)
        ])
        let message = UserFacingErrorMessage.message(for: input, operation: "文字起こし")
        #expect(message == "文字起こしに失敗しました。時間をおいてもう一度お試しください。")
        #expect(!message.contains(input.localizedDescription))
        #expect(!message.contains(rawDescription))
        #expect(message.range(of: "[A-Za-z]", options: .regularExpression) == nil)
    }
}
