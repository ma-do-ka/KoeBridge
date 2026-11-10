import Foundation
import KoeBridgeCore

struct GeminiPrewarmPolicyTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private func snapshot() -> GeminiPrewarmSnapshot {
        GeminiPrewarmSnapshot(vocabulary: ["Swift"], style: .verbatim, japaneseHint: true,
                              apiKeyFingerprint: "test-fingerprint")
    }

    func maximumWarmAgeIsFiveMinutes() {
        check(GeminiPrewarmPolicy.maximumWarmAge == 300)
    }

    func matchingSnapshotWithinAgeLimit() {
        let current = snapshot()
        for age: TimeInterval in [0, 1, GeminiPrewarmPolicy.maximumWarmAge - 0.001] {
            let usable = GeminiPrewarmPolicy.isUsable(snapshot: current, current: current,
                                                     warmedAt: now.addingTimeInterval(-age), now: now)
            check(usable)
        }
    }

    func everySnapshotFieldMustMatch() {
        let current = snapshot()
        var variants = [current, current, current, current]
        variants[0].vocabulary = ["Swift", "Gemini"]
        variants[1].style = .readable
        variants[2].japaneseHint = false
        variants[3].apiKeyFingerprint = "different"
        for variant in variants {
            let usable = GeminiPrewarmPolicy.isUsable(snapshot: variant, current: current,
                                                     warmedAt: now, now: now)
            check(!usable)
        }
    }

    func expiredAndFutureConnectionsAreUnusable() {
        let current = snapshot()
        for age: TimeInterval in [GeminiPrewarmPolicy.maximumWarmAge, GeminiPrewarmPolicy.maximumWarmAge + 1,
                                 1000, -0.001, -GeminiPrewarmPolicy.maximumWarmAge] {
            let usable = GeminiPrewarmPolicy.isUsable(snapshot: current, current: current,
                                                     warmedAt: now.addingTimeInterval(-age), now: now)
            check(!usable)
        }
    }

    func fingerprintIsStableFNV1a() {
        let empty = GeminiPrewarmSnapshot.fingerprint(apiKey: "")
        let a = GeminiPrewarmSnapshot.fingerprint(apiKey: "a")
        let repeated = GeminiPrewarmSnapshot.fingerprint(apiKey: "a")
        check(empty == "0:cbf29ce484222325")
        check(a == "1:af63dc4c8601ec8c")
        check(a == repeated)
    }
}
