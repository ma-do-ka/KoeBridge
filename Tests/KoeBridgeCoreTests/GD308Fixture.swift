import Foundation

/// A single test case from the GD‑308 evaluation set.
public struct GD308TestCase: Sendable {
    public let sampleID: String
    public let datasetType: String // "correct_pair" or "boundary_or_monitoring"
    public let categoryOrGroup: String
    public let beforeText: String
    public let afterText: String
    public let normalizedSurface: String
    public let expectedReadingHiraganaTentative: String
    public let expectedStatusPhase1MVP: String
    public let expectedStatusPhase2AI: String
    public let guardOrRule: String
    public let relatedOQ: String

    /// Whether this case is among the 27 auto‑registration‑forbidden ones.
    public var isForbidden: Bool {
        datasetType == "boundary_or_monitoring"
    }

    /// Whether the expected Phase‑1 outcome is "自動確定".
    public var expectsAutoConfirmed: Bool {
        expectedStatusPhase1MVP.contains("自動確定")
    }

    /// Whether the expected Phase‑1 outcome is "保留" or contains "pending_review".
    public var expectsPendingReview: Bool {
        expectedStatusPhase1MVP.contains("保留") || expectedStatusPhase1MVP.contains("pending_review")
    }

    /// Whether the expected Phase‑1 outcome is "除外" or "対象外".
    public var expectsExcluded: Bool {
        expectedStatusPhase1MVP.contains("除外") || expectedStatusPhase1MVP.contains("対象外")
    }

    public static func loadAll() -> [GD308TestCase] {
        // The CSV is at /tmp/gd308-samples-dataset.csv; we'll embed a static copy for the test.
        // Since we cannot read from /tmp in the test target, we'll embed the data.
        // For now, return an empty array; the actual test will load from a bundled resource.
        return []
    }
}