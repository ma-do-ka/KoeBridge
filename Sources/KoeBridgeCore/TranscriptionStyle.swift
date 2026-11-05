import Foundation

/// KoeBridge's UI intent. Gemini Live exposes only VERBATIM and SMART;
/// the agent style maps to VERBATIM with additional vocabulary biasing.
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
            return "技術用語、コマンド、数値、禁止事項、手順を残すことを優先します。省略の少ない逐語認識に技術用語の補助辞書と最小限の段落区切りを加えます。"
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
            text = text.replacingOccurrences(of: "。" + marker, with: "。\n" + marker)
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

    public static func terms(user: [String], style: TranscriptionStyle, maximum: Int = 100) -> [String] {
        guard maximum > 0 else { return [] }
        let candidates = style == .agent ? user + defaults : user
        var seen = Set<String>()
        var accepted: [String] = []
        for candidate in candidates {
            let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if seen.insert(key).inserted {
                accepted.append(term)
            }
            if accepted.count >= max(0, maximum) { break }
        }
        return accepted
    }
}
