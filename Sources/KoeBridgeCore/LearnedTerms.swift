import Foundation

public struct LearnedTerm: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var term: String
    public var originalFragment: String
    public var sourceRecordID: UUID?
    public let createdAt: Date

    public init(id: UUID = UUID(), term: String, originalFragment: String,
                sourceRecordID: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.term = term
        self.originalFragment = originalFragment
        self.sourceRecordID = sourceRecordID
        self.createdAt = createdAt
    }
}

public enum LearnedTermPolicy {
    public static func normalized(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func validationHint(fragment: String, term: String, recordText: String) -> String? {
        guard !normalized(fragment).isEmpty, !normalized(term).isEmpty else { return "誤りと正しい表記を入力してください" }
        guard term.count <= 60 else { return "正しい表記は60文字以内にしてください" }
        guard recordText.range(of: fragment, options: .literal) != nil else { return "誤りは履歴の文章に含まれる部分を入力してください" }
        return nil
    }

    public static func saving(_ entry: LearnedTerm, in terms: [LearnedTerm]) -> [LearnedTerm] {
        var result = terms
        if let index = result.firstIndex(where: { normalized($0.term) == normalized(entry.term) }) {
            result[index].term = entry.term
            result[index].originalFragment = entry.originalFragment
            result[index].sourceRecordID = entry.sourceRecordID
        } else { result.append(entry) }
        return result
    }
}
