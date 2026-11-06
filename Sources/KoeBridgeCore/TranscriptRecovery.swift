import Foundation

/// Selects a saved partial from the recognizer currently responsible for the
/// take. A stale cloud prefix must not hide a newer on-device recovery result.
public enum TranscriptRecovery {
    public enum Source: Equatable, Sendable { case cloud, local }

    public static func text(preferred: Source, cloud: String?, local: String?, preview: String) -> String {
        let candidates = preferred == .local ? [local, cloud, preview] : [cloud, local, preview]
        return candidates.compactMap { $0 }.first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? ""
    }
}
