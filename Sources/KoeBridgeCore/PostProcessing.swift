public enum PostProcessingMode: String, CaseIterable, Sendable {
    case off, tidy, formal

    public var label: String {
        switch self {
        case .off: return "オフ"
        case .tidy: return "整える"
        case .formal: return "丁寧に整える"
        }
    }
}

public enum PostProcessingPolicy {
    public static func accepts(original: String, processed: String) -> Bool {
        !processed.isEmpty && processed.count <= max(original.count * 3, original.count + 120)
    }

    public static func shouldApply(mode: PostProcessingMode, enabled: Bool,
                                   style: TranscriptionStyle, isTransform: Bool,
                                   skipped: Bool, noInput: Bool) -> Bool {
        enabled && mode != .off && style != .agent && !isTransform && !skipped && !noInput
    }
}
