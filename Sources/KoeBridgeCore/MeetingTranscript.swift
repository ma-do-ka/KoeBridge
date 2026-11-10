import Foundation

/// Source labels only. A system source can contain several people or media.
public struct MeetingTranscript: Sendable {
    public enum Source: String, Sendable {
        case microphone, system
        public var label: String { self == .microphone ? "自分［マイク］" : "相手［システム音声］" }
    }
    public struct Segment: Equatable, Sendable {
        public let source: Source
        public let offset: TimeInterval
        public let text: String
        public init(source: Source, offset: TimeInterval, text: String) {
            self.source = source; self.offset = offset; self.text = text
        }
    }
    public private(set) var segments: [Segment] = []
    public init() {}
    public mutating func append(source: Source, offset: TimeInterval, text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        segments.append(.init(source: source, offset: max(0, offset), text: value))
    }
    public var text: String {
        segments.sorted {
            if $0.offset == $1.offset { return $0.source.rawValue < $1.source.rawValue }
            return $0.offset < $1.offset
        }.map {
            let seconds = Int($0.offset)
            return String(format: "[%02d:%02d] %@\n%@", seconds / 60, seconds % 60, $0.source.label, $0.text)
        }.joined(separator: "\n\n")
    }
}
