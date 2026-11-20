import Foundation

/// Safety limits shared by the macOS logger and portable regression tests.
/// Normal users do not need local diagnostics; recording is explicitly opt-in.
public enum DiagnosticLogPolicy {
    public static let maximumEventBytes = 320
    public static let maximumFileBytes = 192 * 1024
    public static let maximumFiles = 2

    public struct StoreLimits: Sendable {
        public let maximumFileBytes: Int
        public let maximumGenerations: Int
    }

    public static let main = StoreLimits(maximumFileBytes: 256 * 1024, maximumGenerations: 8)
    public static let microphone = StoreLimits(maximumFileBytes: 256 * 1024, maximumGenerations: 8)

    public static var retentionDescription: String {
        let series = [("主ログ", main), ("マイク用ログ", microphone)]
        func capacity(_ bytes: Int) -> String {
            if bytes.isMultiple(of: 1_048_576) { return "\(bytes / 1_048_576) MiB" }
            if bytes.isMultiple(of: 1024) { return "\(bytes / 1024) KiB" }
            return "\(bytes) bytes"
        }
        let detail = series.map { name, limits in
            "\(name)は \(capacity(limits.maximumFileBytes)) × \(limits.maximumGenerations) 世代"
        }
        let total = series.reduce(0) { $0 + $1.1.maximumFileBytes * $1.1.maximumGenerations }
        return detail.joined(separator: "、") + "（合計最大 \(capacity(total))）。"
    }

    public static func isEnabled(storedValue: Bool?) -> Bool { storedValue == true }

    /// Log one short *diagnostic code*, not recognized text, URL or credentials.
    public static func sanitizedEvent(_ event: String) -> String? {
        let safe = event.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard !safe.isEmpty, safe.utf8.count <= maximumEventBytes,
              !safe.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return safe
    }

    public static func needsRotation(existingBytes: Int, incomingBytes: Int,
                                     maximumFileBytes: Int = DiagnosticLogPolicy.maximumFileBytes) -> Bool {
        existingBytes > 0 && incomingBytes > 0 &&
        (existingBytes >= maximumFileBytes || incomingBytes > maximumFileBytes - existingBytes)
    }
}
