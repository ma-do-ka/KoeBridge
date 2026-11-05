import Foundation
import Testing
@testable import KoeBridgeCore

struct ReleaseUpdatePolicyTests {
    private let published = """
    {"tag_name":"v1.0.1d","html_url":"https://github.com/ma-do-ka/KoeBridge/releases/tag/v1.0.1d","draft":false,"prerelease":false}
    """

    @Test func versionComparisonPreservesLetterSequence() {
        let ordered = ["1.0.1", "v1.0.1a", "1.0.1b", "v1.0.1c", "1.0.1d", "1.0.1z", "v1.0.2", "2.0.0"]
        let versions = ordered.compactMap(KoeBridgeReleaseVersion.init)
        #expect(versions.count == ordered.count)
        for pair in zip(versions, versions.dropFirst()) {
            #expect(pair.0 < pair.1)
        }
        #expect(KoeBridgeReleaseVersion("1.0.1b") == KoeBridgeReleaseVersion("v1.0.1b"))
    }

    @Test func rejectInvalidOrUnsafeTags() {
        for bad in ["", "v1.0", "v1.0.1-rc1", "v1.0.1a;rm -rf", "v1.0.1ab",
                    "1.0.1A", "a.b.c", "v1.0.1/evil", "v1.0.-2", "v1.0.1a\n"] {
            #expect(KoeBridgeReleaseVersion(bad) == nil)
        }
    }

    @Test func acceptsOnlyOfficialStableReleaseURL() throws {
        let release = try KoeBridgeUpdatePolicy.decodeLatest(Data(published.utf8))
        #expect(release.tag == "v1.0.1d")
        #expect(KoeBridgeUpdatePolicy.newer(release, than: "1.0.1c"))
        #expect(!KoeBridgeUpdatePolicy.newer(release, than: "1.0.1d"))
        #expect(!KoeBridgeUpdatePolicy.newer(release, than: "1.0.2"))
        #expect(!KoeBridgeUpdatePolicy.newer(release, than: "not-a-version"))
        #expect(KoeBridgeStableRelease(tag: "v1.0.1d", pageURL: "https://evil.example/tag",
                                        isDraft: false, isPrerelease: false) == nil)
        #expect(KoeBridgeStableRelease(tag: "v1.0.1d",
                                        pageURL: "http://github.com/ma-do-ka/KoeBridge/releases/tag/v1.0.1d",
                                        isDraft: false, isPrerelease: false) == nil)
        #expect(KoeBridgeStableRelease(tag: "v1.0.1d",
                                        pageURL: "https://github.com/ma-do-ka/KoeBridge/releases/tag/v1.0.1d",
                                        isDraft: true, isPrerelease: false) == nil)
        #expect(KoeBridgeStableRelease(tag: "v1.0.1d",
                                        pageURL: "https://github.com/ma-do-ka/KoeBridge/releases/tag/v1.0.1d",
                                        isDraft: false, isPrerelease: true) == nil)
    }

    @Test func malformedOrRedirectedPayloadIsNotTreatedAsUpToDate() {
        let spoof = published.replacingOccurrences(of: "github.com", with: "evil.example")
        #expect(throws: Error.self) {
            _ = try KoeBridgeUpdatePolicy.decodeLatest(Data(spoof.utf8))
        }
        #expect(throws: Error.self) {
            _ = try KoeBridgeUpdatePolicy.decodeLatest(Data("{}".utf8))
        }
    }

    @Test func automaticCheckIsRateLimitedWithoutDisablingManualActions() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(!KoeBridgeUpdatePolicy.shouldCheck(automatic: false, lastCheck: nil, now: now))
        #expect(KoeBridgeUpdatePolicy.shouldCheck(automatic: true, lastCheck: nil, now: now))
        #expect(!KoeBridgeUpdatePolicy.shouldCheck(automatic: true,
                                                    lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(KoeBridgeUpdatePolicy.shouldCheck(automatic: true,
                                                   lastCheck: now.addingTimeInterval(-86_400), now: now))
        #expect(KoeBridgeUpdatePolicy.shouldCheck(automatic: true,
                                                   lastCheck: now.addingTimeInterval(50), now: now))
    }
}
