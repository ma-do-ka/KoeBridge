import Foundation

/// KoeBridge's UI intent. Gemini Live exposes only VERBATIM and SMART;
/// the agent style maps to VERBATIM with minimal paragraph formatting.
public enum TranscriptionStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case verbatim
    case readable
    case agent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .verbatim: return "逐語"
        case .readable: return "読みやすく"
        case .agent: return "AIエージェント指示"
        }
    }

    public var explanation: String {
        switch self {
        case .verbatim:
            return "発言や言い直しをできるだけそのまま残します（VERBATIM）。"
        case .readable:
            return "言いよどみや言い直しを整理して読みやすくします（SMART）。"
        case .agent:
            return "技術用語、コマンド、数値、禁止事項、手順をできるだけ残し、最小限の段落区切りを加えます。専門用語の補助は、個別の設定に従います。"
        }
    }

    public var liveMode: String {
        self == .readable ? "SMART" : "VERBATIM"
    }

    /// Preserve the user's old switch on first launch after upgrading.
    /// Unknown/malformed new values also fall back to the older preference.
    public static func restoring(storedStyle: String?, legacySmart: Bool) -> Self {
        if let storedStyle, let value = Self(rawValue: storedStyle) {
            return value
        }
        return legacySmart ? .readable : .verbatim
    }
}

/// No secondary LLM processing, deletions or substitutions. Explicit
/// sentence boundaries can improve readability for long agent instructions
/// without changing the literal words, URLs, paths, punctuation or numbers.
public enum AgentInstructionFormatting {
    private static let instructionStarters = [
        "次に", "その後", "最後に", "必ず", "禁止", "変更しないで",
        "変更せず", "条件は", "制約は", "ただし", "注意点は"
    ]

    public static func format(_ transcript: String) -> String {
        var text = transcript
        for marker in instructionStarters {
            let protected = TextContextChecking.protectedRanges(in: text)
            let source = text as NSString
            var insertionOffsets: [Int] = []
            var search = NSRange(location: 0, length: source.length)
            while search.length > 0 {
                let found = source.range(of: "。" + marker, options: [], range: search)
                guard found.location != NSNotFound else { break }
                let offset = found.location + 1
                // Inserting immediately before/after a literal preserves it;
                // inserting anywhere inside one changes its exact contents.
                if !protected.contains(where: { $0.location < offset && offset < NSMaxRange($0) }) {
                    insertionOffsets.append(offset)
                }
                let end = NSMaxRange(found)
                search = NSRange(location: end, length: source.length - end)
            }
            let edited = NSMutableString(string: text)
            for offset in insertionOffsets.reversed() { edited.insert("\n", at: offset) }
            text = edited as String
        }
        return text
    }
}

/// Domain-specific vocabulary is recognition bias, not forced spelling.
/// User-provided terms take priority over built-in agent-oriented hints.
public enum AgentVocabulary {
    public static let defaults: [String] = [
        "GitHub", "GitHub Actions", "n8n", "Python", "SwiftUI",
        "TypeScript", "Node.js", "JavaScript", "Docker", "Kubernetes",
        "JSON", "YAML", "API", "HTTP", "SQL", "MCP", "LLM",
        "OpenAI", "Gemini", "Codex", "Git", "CI", "PR", "WebSocket",
        "pytest", "npm", "GitHub Issue", "GitHub Pull Request"
    ]

    public static func terms(
        user: [String], registeredEnabled: Bool, topicEnabled: Bool, maximum: Int = 100
    ) -> [String] {
        guard maximum > 0 else { return [] }
        let candidates = (registeredEnabled ? user : []) + (topicEnabled ? defaults : [])
        var seen = Set<String>()
        var accepted: [String] = []
        for candidate in candidates {
            let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if seen.insert(key).inserted {
                accepted.append(term)
            }
            if accepted.count >= min(100, maximum) { break }
        }
        return accepted
    }
}
