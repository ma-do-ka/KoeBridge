#if os(macOS)
import CoreGraphics
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct TextInsertionTransportTests {
    @Test func privateSourceAndKeyDownOnlyUnicode() throws {
        let source = try #require(TextInsertion.makePostingSource())
        // makePostingSource constructs the source with .privateState; event state IDs
        // are not a reliable probe, and the source accessor returns a unique private table ID.
        let (down, up) = try #require(TextInsertion.makeUnicodeEvents("日本語A", source: source))
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
        // With no attached Unicode string, keyUp readback can synthesize the layout
        // character for virtualKey 0. Its length need not be zero; it must never carry the payload.
        #expect(String(decoding: units.prefix(upLength), as: UTF16.self) != "日本語A")
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
