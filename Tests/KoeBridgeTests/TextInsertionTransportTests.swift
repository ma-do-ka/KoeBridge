#if os(macOS)
import CoreGraphics
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct TextInsertionTransportTests {
    @Test func privateSourceAndKeyDownOnlyUnicode() throws {
        let source = try #require(TextInsertion.makePostingSource())
        let (down, up) = try #require(TextInsertion.makeUnicodeEvents("日本語A", source: source))
        #expect(down.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.privateState.rawValue))
        #expect(up.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.privateState.rawValue))
        #expect(down.flags.isEmpty && up.flags.isEmpty)
        #expect(down.getIntegerValueField(.keyboardEventKeycode) == 0)
        #expect(up.getIntegerValueField(.keyboardEventKeycode) == 0)
        #expect(down.type == .keyDown && up.type == .keyUp)
        var downLength = 0
        var upLength = 0
        var units = [UniChar](repeating: 0, count: 64)
        units.withUnsafeMutableBufferPointer { buffer in
            down.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &downLength,
                                          unicodeString: buffer.baseAddress)
        }
        #expect(String(decoding: units.prefix(downLength), as: UTF16.self) == "日本語A")
        units.withUnsafeMutableBufferPointer { buffer in
            up.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &upLength,
                                        unicodeString: buffer.baseAddress)
        }
        #expect(upLength == 0)
    }

    @Test func unconfirmedFeedbackDoesNotChangeSubmissionSemantics() {
        let verified = DictationDelivery.Outcome(delivery: .verifiedInserted, detail: "", report: nil)
        let unconfirmed = DictationDelivery.Outcome(delivery: .attemptedUnconfirmed, detail: "", report: nil)
        let blocked = DictationDelivery.Outcome(delivery: .blockedFocus, detail: "", report: nil)
        #expect(verified.submitted && unconfirmed.submitted)
        #expect(!blocked.submitted)
        #expect(verified.submissionFeedback == .sent)
        #expect(unconfirmed.submissionFeedback == .sentUnconfirmed)
        #expect(blocked.submissionFeedback == nil)
    }
}
#endif
