import KoeBridgeCore

struct DirectTypingPlanTests {
    func preservesJapaneseAndLatin() {
        let text = "こんにちは。GitHubとn8nを使います"
        check(UnicodeTypingPlan.chunks(text).joined() == text)
    }
    func preservesEmojiGraphemeClusters() {
        let text = "👩🏽‍💻👨‍👩‍👧‍👦日本語🙂"
        let parts = UnicodeTypingPlan.chunks(text, maximumUTF16Units: 8)
        check(parts.joined() == text)
        check(parts.count >= 2)
    }
    func preventsReturnAndTabActions() {
        let input = "こんにちは\r\n世界\tです\u{0000}。"
        let output = UnicodeTypingPlan.safeText(input)
        check(output == "こんにちは 世界 です。")
        check(!output.contains("\n"))
        check(!output.contains("\t"))
        check(!output.contains("\r"))
    }
    func doesNotSplitEmojiSurrogates() {
        let parts = UnicodeTypingPlan.chunks("😀😀😀😀", maximumUTF16Units: 3)
        check(parts.count == 4)
        check(parts.allSatisfy { $0.utf16.count == 2 })
    }
    func longMixedTextRoundTrips() {
        let text = String(repeating: "ひらがな漢字English😀", count: 100)
        let parts = UnicodeTypingPlan.chunks(text)
        check(parts.joined() == text)
        check(parts.allSatisfy { $0.utf16.count <= 16 })
    }
    func emptyIsNotTyped() {
        check(UnicodeTypingPlan.chunks("").isEmpty)
        check(UnicodeTypingPlan.safeText("\r\n\t") == " ")
    }
}
