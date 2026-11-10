import Foundation

public enum VoiceCommandID: String, CaseIterable, Identifiable, Sendable {
    case cancelTake, newline, paragraph
    public var id: String { rawValue }
    public var phrase: String {
        switch self {
        case .cancelTake: return "入力をキャンセルして"
        case .newline: return "改行して"
        case .paragraph: return "段落を変えて"
        }
    }
    public var effect: String {
        switch self {
        case .cancelTake: return "この発話だけを破棄します。入力・コピー・履歴保存は行いません。"
        case .newline: return "改行を1つ入力します。"
        case .paragraph: return "改行を2つ入力します。"
        }
    }
    public var completionMessage: String {
        switch self {
        case .cancelTake: return "入力をキャンセルしました"
        case .newline: return "改行しました"
        case .paragraph: return "段落を変えました"
        }
    }
    /// Only these fixed typed payloads can authorize control text delivery.
    public var insertionText: String? {
        switch self {
        case .cancelTake: return nil
        case .newline: return "\n"
        case .paragraph: return "\n\n"
        }
    }
}

public enum VoiceCommandMatcher {
    public static func match(text: String, enabled: Set<VoiceCommandID>) -> VoiceCommandID? {
        var normalized = text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.last == "。" || normalized.last == "." { normalized.removeLast() }
        return VoiceCommandID.allCases.first { enabled.contains($0) && normalized == $0.phrase }
    }
}

/// Shared classification and execution gates; no recognized text is retained in reasons.
public enum VoiceCommandGate {
    public static func blockedReason(acousticReviewRequired: Bool, reviewStatus: TranscriptReview.Status?,
                                     suppressed: Bool, shouldPaste: Bool, sameCommand: Bool) -> String? {
        if suppressed { return "suppressed" }
        if acousticReviewRequired { return "acoustic_review_required" }
        if reviewStatus == .needsReview { return "review_required" }
        if reviewStatus == .incomplete { return "review_incomplete" }
        if !sameCommand { return "review_command_mismatch" }
        if !shouldPaste { return "automatic_input_disabled" }
        return nil
    }
}
