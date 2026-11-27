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
    public enum Rejection: String { case length, fencedContent = "fenced_content" }

    public static func adoption(original: String, processed: String) -> (text: String, rejection: Rejection?) {
        let source = CodeFences.segments(in: original)
        if !source.isEmpty && source != CodeFences.segments(in: processed) {
            return (original, .fencedContent)
        }
        guard !processed.isEmpty, processed.count <= max(original.count * 3, original.count + 120) else {
            return (original, .length)
        }
        if isDrasticallyShortened(original: original, processed: processed) {
            return (original, .length)
        }
        return (processed, nil)
    }

    private static func isDrasticallyShortened(original: String, processed: String) -> Bool {
        let originalCount = original.count
        let processedCount = processed.count
        guard originalCount > 0, processedCount > 0 else { return false }
        let reduction = originalCount - processedCount
        guard reduction > 0, originalCount >= 20, reduction >= 20 else { return false }
        if originalCount < 200 {
            return reduction * 100 >= originalCount * 45
        }
        return reduction >= 80 && reduction * 100 >= originalCount * 25
    }

    public static func accepts(original: String, processed: String) -> Bool {
        adoption(original: original, processed: processed).rejection == nil
    }

    public static func shouldApply(mode: PostProcessingMode, enabled: Bool,
                                   style: TranscriptionStyle, isTransform: Bool,
                                   skipped: Bool, noInput: Bool) -> Bool {
        enabled && mode != .off && style != .agent && !isTransform && !skipped && !noInput
    }
}
