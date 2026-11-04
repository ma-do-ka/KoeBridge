import Testing
@testable import KoeBridgeCore

struct DirectTypingPlanTests {
    @Test func japaneseAndEnglish() {
        let text = "日本語をGitHubで使う😀"
        #expect(UnicodeTypingPlan.chunks(text).joined() == text)
    }
    @Test func graphemeClusters() {
        let text = "👩🏽‍💻👨‍👩‍👧‍👦🙂"
        #expect(UnicodeTypingPlan.chunks(text, maximumUTF16Units: 8).joined() == text)
    }
    @Test func newlinesCannotSendChat() {
        #expect(UnicodeTypingPlan.safeText("A\r\nB\tC") == "A B C")
    }
    @Test func longText() {
        let text = String(repeating: "日本語Qwen3🙂", count: 100)
        let pieces = UnicodeTypingPlan.chunks(text)
        #expect(pieces.joined() == text)
        #expect(pieces.allSatisfy { $0.utf16.count <= 16 })
    }
}
