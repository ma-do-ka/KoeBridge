import Foundation

/// Safety limits shared by the macOS logger and portable regression tests.
/// Normal users do not need local diagnostics; recording is explicitly opt-in.
public enum DiagnosticLogPolicy {
    public static let maximumEventBytes = 320
    public static let maximumFileBytes = 192 * 1024
    public static let maximumFiles = 2

    public static func isEnabled(storedValue: Bool?) -> Bool { storedValue == true }

    /// Log one short *diagnostic code*, not recognized text, URL or credentials.
    public static func sanitizedEvent(_ event: String) -> String? {
        let safe = event.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard !safe.isEmpty, safe.utf8.count <= maximumEventBytes,
              !safe.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        return safe
    }

    public static func needsRotation(existingBytes: Int, incomingBytes: Int) -> Bool {
        existingBytes > 0 && incomingBytes > 0 &&
        (existingBytes >= maximumFileBytes || incomingBytes > maximumFileBytes - existingBytes)
    }
}
