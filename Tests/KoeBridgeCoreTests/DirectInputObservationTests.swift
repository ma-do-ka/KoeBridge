import Testing
@testable import KoeBridgeCore

struct DirectInputObservationTests {
    @Test func verifiesAppendingJapanese() {
        #expect(DirectInputObservation.classify(before: "こんにちは", after: "こんにちは世界", inserted: "世界") == .verifiedInsertion)
    }
    @Test func verifiesSelectionReplacement() {
        #expect(DirectInputObservation.classify(before: "abcXYZdef", after: "abc日本語def", inserted: "日本語") == .verifiedInsertion)
    }
    @Test func detectsSilentlyIgnoredEvent() {
        #expect(DirectInputObservation.classify(before: "hello", after: "hello", inserted: "world") == .unchanged)
    }
    @Test func refusesUnobservableBrowserEditor() {
        #expect(DirectInputObservation.classify(before: nil, after: nil, inserted: "文字") == .unobservable)
    }
    @Test func refusesUnrelatedEditAsVerification() {
        #expect(DirectInputObservation.classify(before: "text", after: "edit", inserted: "入力") == .changedButUnverified)
    }
    @Test func preservesEmojiAndRepeatedCharacters() {
        #expect(DirectInputObservation.classify(before: "😀", after: "😀😀", inserted: "😀") == .verifiedInsertion)
        #expect(DirectInputObservation.classify(before: "aa", after: "aaa", inserted: "a") == .verifiedInsertion)
    }
}
