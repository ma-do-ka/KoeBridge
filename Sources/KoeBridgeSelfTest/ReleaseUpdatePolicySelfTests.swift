import Foundation
import KoeBridgeCore

struct ReleaseUpdatePolicySelfTests {
    func stableVersionsAreMonotonic() {
        let a = KoeBridgeReleaseVersion("v1.0.1c")
        let b = KoeBridgeReleaseVersion("v1.0.1d")
        let future = KoeBridgeReleaseVersion("v1.0.2")
        check(a != nil && b != nil && future != nil)
        if let a, let b, let future {
            check(a < b)
            check(b < future)
        }
        check(KoeBridgeReleaseVersion("v1.0.1d;malicious") == nil)
        check(KoeBridgeReleaseVersion("v1.0.1-rc") == nil)
    }

    func rejectsForgedOrPrereleaseMetadata() throws {
        let valid = """
        {"tag_name":"v1.0.1d","html_url":"https://github.com/ma-do-ka/KoeBridge/releases/tag/v1.0.1d","draft":false,"prerelease":false}
        """
        let release = try KoeBridgeUpdatePolicy.decodeLatest(Data(valid.utf8))
        check(release.tag == "v1.0.1d")
        check(KoeBridgeUpdatePolicy.newer(release, than: "1.0.1c"))
        check(!KoeBridgeUpdatePolicy.newer(release, than: "1.0.1d"))
        checkThrows(Error.self) {
            _ = try KoeBridgeUpdatePolicy.decodeLatest(
                Data(valid.replacingOccurrences(of: "github.com", with: "example.net").utf8))
        }
        checkThrows(Error.self) {
            _ = try KoeBridgeUpdatePolicy.decodeLatest(
                Data(valid.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true").utf8))
        }
    }

    func automaticChecksAreBounded() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        check(!KoeBridgeUpdatePolicy.shouldCheck(automatic: false, lastCheck: nil, now: now))
        check(KoeBridgeUpdatePolicy.shouldCheck(automatic: true, lastCheck: nil, now: now))
        check(!KoeBridgeUpdatePolicy.shouldCheck(
            automatic: true, lastCheck: now.addingTimeInterval(-3600), now: now))
        check(KoeBridgeUpdatePolicy.shouldCheck(
            automatic: true, lastCheck: now.addingTimeInterval(-86_400), now: now))
    }
}
