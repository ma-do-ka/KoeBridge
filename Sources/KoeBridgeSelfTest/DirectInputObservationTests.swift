import Foundation
import KoeBridgeCore

struct DirectInputObservationTests {
    func verifiesAppendingJapanese() {
        check(DirectInputObservation.classify(before: "こんにちは", after: "こんにちは世界", inserted: "世界") == .verifiedInsertion)
    }
    func verifiesSelectionReplacement() {
        check(DirectInputObservation.classify(before: "abcXYZdef", after: "abc日本語def", inserted: "日本語") == .verifiedInsertion)
    }
    func detectsSilentlyIgnoredEvent() {
        check(DirectInputObservation.classify(before: "hello", after: "hello", inserted: "world") == .unchanged)
    }
    func refusesUnobservableBrowserEditor() {
        check(DirectInputObservation.classify(before: nil, after: nil, inserted: "文字") == .unobservable)
    }
    func refusesUnrelatedEditAsVerification() {
        check(DirectInputObservation.classify(before: "text", after: "edit", inserted: "入力") == .changedButUnverified)
    }
    func preservesEmojiAndRepeatedCharacters() {
        check(DirectInputObservation.classify(before: "😀", after: "😀😀", inserted: "😀") == .verifiedInsertion)
        check(DirectInputObservation.classify(before: "aa", after: "aaa", inserted: "a") == .verifiedInsertion)
    }
}
