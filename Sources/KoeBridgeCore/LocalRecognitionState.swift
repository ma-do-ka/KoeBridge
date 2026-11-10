/// Recognizer stability for display only; never authorizes document insertion.
public struct RecognitionPreview: Equatable, Sendable {
    public let finalizedPrefix: String
    public let volatileTail: String
    public init(finalizedPrefix: String = "", volatileTail: String = "") {
        self.finalizedPrefix = finalizedPrefix
        self.volatileTail = volatileTail
    }
    public var text: String { finalizedPrefix + volatileTail }
}

/// Lifecycle of one on-device recognition request. Kept separate from the
/// Speech framework so cancellation and delayed callbacks can be exercised
/// without a microphone or a permission prompt.
public struct LocalRecognitionState: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, authorizing, recognizing, finishing, completed, failed, cancelled
    }

    public private(set) var phase: Phase = .idle
    public private(set) var transcript = ""
    public private(set) var preview = RecognitionPreview()
    public private(set) var failure: String?

    public init() {}

    public var acceptsAudio: Bool { phase == .recognizing }
    public var acceptsUpdates: Bool { phase == .recognizing || phase == .finishing }
    public var isFinal: Bool { phase == .completed }

    @discardableResult public mutating func beginAuthorization() -> Bool {
        guard phase == .idle else { return false }
        phase = .authorizing
        return true
    }

    @discardableResult public mutating func beginRecognition() -> Bool {
        guard phase == .authorizing else { return false }
        phase = .recognizing
        return true
    }

    /// Returns true only for the first request to finish an active recording.
    @discardableResult public mutating func endAudio() -> Bool {
        guard phase == .recognizing else { return false }
        phase = .finishing
        return true
    }

    /// Legacy cumulative request updates; no segment stability is inferred.
    @discardableResult public mutating func receive(_ text: String, isFinal: Bool) -> Bool {
        guard acceptsUpdates else { return false }
        transcript = text
        preview = isFinal ? RecognitionPreview(finalizedPrefix: text)
            : RecognitionPreview(volatileTail: text)
        if isFinal { phase = .completed }
        return true
    }

    /// Segment finals append; hypotheses replace only the volatile tail.
    /// Request completion folds the supplied last tail into the prefix.
    /// A finalized segment replaces the previous hypothesis, including an empty
    /// final at stream end; only provider-final text then remains accepted.
    @discardableResult public mutating func receiveSegment(_ text: String, finalized: Bool,
                                                          completesRequest: Bool = false) -> Bool {
        guard acceptsUpdates else { return false }
        var prefix = preview.finalizedPrefix
        var tail = text
        if finalized { prefix += text; tail = "" }
        if completesRequest { prefix += tail; tail = "" }
        preview = RecognitionPreview(finalizedPrefix: prefix, volatileTail: tail)
        transcript = preview.text
        if completesRequest { phase = .completed }
        return true
    }

    public mutating func receiveFailure(_ message: String) {
        // Speech can deliver a final result and an error together. Preserve
        // the accepted final; no later callback may replace a terminal state.
        guard acceptsUpdates else { return }
        failure = message
        phase = .failed
    }

    public mutating func cancel() {
        phase = .cancelled
        // Keep the last accepted text available for manual recovery.
    }
}
