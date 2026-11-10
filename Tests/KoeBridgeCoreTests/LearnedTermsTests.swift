import Foundation
import Testing
@testable import KoeBridgeCore

struct LearnedTermsTests {
    @Test func fragmentWhitespaceHintPreservesLiteralMatching() {
        #expect(LearnedTermPolicy.validationHint(fragment: " \twrong\n", term: "Right", recordText: "wrong") == "前後の空白を取り除いてください")
        #expect(LearnedTermPolicy.validationHint(fragment: " missing ", term: "Right", recordText: "wrong") == "誤りは履歴の文章に含まれる部分を入力してください")
        #expect(LearnedTermPolicy.validationHint(fragment: " wrong ", term: "Right", recordText: "a wrong word") == nil)
        #expect(LearnedTermPolicy.validationHint(fragment: " Wrong ", term: "Right", recordText: "wrong") == "誤りは履歴の文章に含まれる部分を入力してください")
    }

    @Test func normalizationValidationAndPersistence() throws {
        #expect(LearnedTermPolicy.normalized("  Café\n") == "cafe")
        #expect(LearnedTermPolicy.normalized(" \t") == "")
        #expect(LearnedTermPolicy.validationHint(fragment: "wrong", term: "Right", recordText: "a wrong word") == nil)
        #expect(LearnedTermPolicy.validationHint(fragment: "missing", term: "Right", recordText: "wrong") != nil)
        #expect(LearnedTermPolicy.validationHint(fragment: " ", term: "Right", recordText: " ") != nil)
        #expect(LearnedTermPolicy.validationHint(fragment: "a", term: " ", recordText: "a") != nil)
        #expect(LearnedTermPolicy.validationHint(fragment: "a", term: String(repeating: "語", count: 60), recordText: "a") == nil)
        #expect(LearnedTermPolicy.validationHint(fragment: "a", term: String(repeating: "語", count: 61), recordText: "a") != nil)
        let first = LearnedTerm(term: "Café", originalFragment: "bad", sourceRecordID: UUID(), createdAt: Date(timeIntervalSince1970: 100))
        let newer = LearnedTerm(term: " CAFE ", originalFragment: "other", sourceRecordID: UUID())
        let saved = LearnedTermPolicy.saving(newer, in: [first])
        #expect(saved.count == 1)
        #expect(saved[0].id == first.id)
        #expect(saved[0].createdAt == first.createdAt)
        #expect(saved[0].originalFragment == "other")
        #expect(saved[0].sourceRecordID == newer.sourceRecordID)
        #expect(LearnedTermPolicy.saving(LearnedTerm(term: "new", originalFragment: "new"), in: saved).count == 2)
        let decoded = try JSONDecoder().decode([LearnedTerm].self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
    }

    @Test func vocabularyOrderingAndCap() {
        let combined = AgentVocabulary.terms(user: [" Café ", "GitHub"], learned: ["CAFE", "learned", "github"], registeredEnabled: true, topicEnabled: true)
        #expect(Array(combined.prefix(4)) == ["Café", "GitHub", "learned", "GitHub Actions"])
        #expect(combined.filter { LearnedTermPolicy.normalized($0) == "github" }.count == 1)
        let users = (0..<100).map { "user\($0)" }
        #expect(AgentVocabulary.terms(user: users, learned: ["learned"], registeredEnabled: true, topicEnabled: true) == users)
        #expect(AgentVocabulary.terms(user: Array(users.prefix(99)), learned: ["learned"], registeredEnabled: true, topicEnabled: true).last == "learned")
        #expect(AgentVocabulary.terms(user: ["user"], learned: ["learned"], registeredEnabled: false, topicEnabled: false).isEmpty)
        #expect(AgentVocabulary.terms(user: ["user"], learned: ["learned"], registeredEnabled: false, topicEnabled: true) == AgentVocabulary.defaults)
        #expect(AgentVocabulary.terms(user: ["user"], learned: ["learned"], registeredEnabled: true, topicEnabled: true, maximum: 1) == ["user"])
        #expect(AgentVocabulary.terms(user: ["user"], learned: ["learned"], registeredEnabled: true, topicEnabled: true, maximum: 0).isEmpty)
        #expect(AgentVocabulary.terms(user: ["user"], registeredEnabled: true, topicEnabled: true) == ["user"] + AgentVocabulary.defaults)
    }
    @Test func fullFixSelectionAndManualLimit() throws {
        let text = String(repeating: "語", count: 2_100) + "end"
        let full = try JSONSerialization.jsonObject(with: GeminiTransformWire.request(selectedText: text, instruction: "fix", preserveFullSelection: true)) as! [String: Any]
        let normal = try JSONSerialization.jsonObject(with: GeminiTransformWire.request(selectedText: text, instruction: "fix")) as! [String: Any]
        func selected(_ object: [String: Any]) -> String {
            let contents = object["contents"] as! [[String: Any]]
            let parts = contents[0]["parts"] as! [[String: String]]
            return parts[0]["text"]!
        }
        #expect(selected(full) == "選択テキスト（データ）:\n" + text)
        #expect(selected(normal) == "選択テキスト（データ）:\n" + ContextTextPolicy.selected(text))
    }
}
