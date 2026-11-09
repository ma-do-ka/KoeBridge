import Foundation
import Testing
@testable import KoeBridgeCore

struct DeveloperDiagnosticsPolicyTests {
    @Test func audioIsStrictlyBounded() {
        let limit = DeveloperDiagnosticsPolicy.maximumAudioPCMBytes
        let exact = Data(repeating: 1, count: limit)
        let cappedExact = DeveloperDiagnosticsPolicy.cappedPCM(exact)
        #expect(cappedExact.data.count == limit)
        #expect(!cappedExact.truncated)

        let oversized = Data(repeating: 2, count: limit + 1234)
        let capped = DeveloperDiagnosticsPolicy.cappedPCM(oversized)
        #expect(capped.data.count == limit)
        #expect(capped.truncated)
    }

    @Test func utf8TruncationNeverSplitsACharacter() {
        let prefix = String(repeating: "a", count: DeveloperDiagnosticsPolicy.maximumTextUTF8Bytes - 2)
        let original = prefix + "😀末尾"
        let result = DeveloperDiagnosticsPolicy.cappedText(original)
        #expect(result.truncated)
        #expect(result.text == prefix)
        #expect(String(data: Data(result.text.utf8), encoding: .utf8) == result.text)
    }

    @Test func shortTextIsUnchanged() {
        let original = "音声と文字列の開発診断"
        let result = DeveloperDiagnosticsPolicy.cappedText(original)
        #expect(result.text == original)
        #expect(!result.truncated)
    }

    @Test func observedDeltaKeepsOnlyChangedCharacters() {
        let delta = DeveloperDiagnosticsPolicy.changedSegment(
            before: "prefix OLD suffix",
            after: "prefix NEW text suffix"
        )
        #expect(delta?.text == "NEW text")
        #expect(delta?.truncated == false)
        #expect(DeveloperDiagnosticsPolicy.changedSegment(before: "same", after: "same") == nil)
    }

    @Test func retentionLimitsAreFailClosed() {
        #expect(DeveloperDiagnosticsPolicy.mayRetainSession(
            fileBytes: DeveloperDiagnosticsPolicy.maximumSessionBytes,
            totalBytes: DeveloperDiagnosticsPolicy.maximumTotalBytes,
            retainedSessions: DeveloperDiagnosticsPolicy.maximumSessions
        ))
        #expect(!DeveloperDiagnosticsPolicy.mayRetainSession(
            fileBytes: DeveloperDiagnosticsPolicy.maximumSessionBytes + 1,
            totalBytes: 0,
            retainedSessions: 1
        ))
        #expect(!DeveloperDiagnosticsPolicy.mayRetainSession(
            fileBytes: 1,
            totalBytes: DeveloperDiagnosticsPolicy.maximumTotalBytes + 1,
            retainedSessions: 1
        ))
        #expect(!DeveloperDiagnosticsPolicy.mayRetainSession(
            fileBytes: 1,
            totalBytes: 1,
            retainedSessions: DeveloperDiagnosticsPolicy.maximumSessions + 1
        ))
    }
}
