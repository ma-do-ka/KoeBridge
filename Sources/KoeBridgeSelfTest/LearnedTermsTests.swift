import Foundation
import KoeBridgeCore

struct LearnedTermsTests {
    func normalizationValidationAndPersistence() throws {
        check(LearnedTermPolicy.normalized("  Café\n") == "cafe")
        check(LearnedTermPolicy.normalized(" \t") == "")
        check(LearnedTermPolicy.validationHint(fragment: "wrong", term: "Right", recordText: "a wrong word") == nil)
        check(LearnedTermPolicy.validationHint(fragment: "missing", term: "Right", recordText: "wrong") != nil)
        check(LearnedTermPolicy.validationHint(fragment: " ", term: "Right", recordText: " ") != nil)
        check(LearnedTermPolicy.validationHint(fragment: "a", term: " ", recordText: "a") != nil)
        check(LearnedTermPolicy.validationHint(fragment: "a", term: String(repeating: "語", count: 60), recordText: "a") == nil)
        check(LearnedTermPolicy.validationHint(fragment: "a", term: String(repeating: "語", count: 61), recordText: "a") != nil)
        let first = LearnedTerm(term: "Café", originalFragment: "bad", sourceRecordID: UUID(), createdAt: Date(timeIntervalSince1970: 100))
        let newer = LearnedTerm(term: " CAFE ", originalFragment: "other", sourceRecordID: UUID())
        let saved = LearnedTermPolicy.saving(newer, in: [first])
        check(saved.count == 1)
        check(saved[0].id == first.id)
        check(saved[0].createdAt == first.createdAt)
        check(saved[0].originalFragment == "other")
        check(saved[0].sourceRecordID == newer.sourceRecordID)
        check(LearnedTermPolicy.saving(LearnedTerm(term: "new", originalFragment: "new"), in: saved).count == 2)
        let decoded = try JSONDecoder().decode([LearnedTerm].self, from: JSONEncoder().encode(saved))
        check(decoded == saved)
    }

    func vocabularyOrderingAndCap() {
        let combined = AgentVocabulary.terms(user: [" Café ", "GitHub"], learned: ["CAFE", "learned", "github"], registeredEnabled: true, topicEnabled: true)
        check(Array(combined.prefix(4)) == ["Café", "GitHub", "learned", "GitHub Actions"])
        check(combined.filter { LearnedTermPolicy.normalized($0) == "github" }.count == 1)
        let users = (0..<100).map { "user\($0)" }
        check(AgentVocabulary.terms(user: users, learned: ["learned"], registeredEnabled: true, topicEnabled: true) == users)
        check(AgentVocabulary.terms(user: Array(users.prefix(99)), learned: ["learned"], registeredEnabled: true, topicEnabled: true).last == "learned")
        check(AgentVocabulary.terms(user: ["user"], learned: ["learned"], registeredEnabled: false, topicEnabled: false).isEmpty)
        check(AgentVocabulary.terms(user: ["user"], learned: ["learned"], registeredEnabled: false, topicEnabled: true) == AgentVocabulary.defaults)
        check(AgentVocabulary.terms(user: ["user"], learned: ["learned"], registeredEnabled: true, topicEnabled: true, maximum: 1) == ["user"])
        check(AgentVocabulary.terms(user: ["user"], learned: ["learned"], registeredEnabled: true, topicEnabled: true, maximum: 0).isEmpty)
        check(AgentVocabulary.terms(user: ["user"], registeredEnabled: true, topicEnabled: true) == ["user"] + AgentVocabulary.defaults)
    }
    func fullFixSelectionAndManualLimit() throws {
        let text = String(repeating: "語", count: 2_100) + "end"
        let full = try JSONSerialization.jsonObject(with: GeminiTransformWire.request(selectedText: text, instruction: "fix", preserveFullSelection: true)) as! [String: Any]
        let normal = try JSONSerialization.jsonObject(with: GeminiTransformWire.request(selectedText: text, instruction: "fix")) as! [String: Any]
        func selected(_ object: [String: Any]) -> String {
            let contents = object["contents"] as! [[String: Any]]
            let parts = contents[0]["parts"] as! [[String: String]]
            return parts[0]["text"]!
        }
        check(selected(full) == "選択テキスト（データ）:\n" + text)
        check(selected(normal) == "選択テキスト（データ）:\n" + ContextTextPolicy.selected(text))
    }
}
