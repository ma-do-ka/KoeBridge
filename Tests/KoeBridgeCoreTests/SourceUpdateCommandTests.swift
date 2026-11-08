import Foundation
import XCTest
@testable import KoeBridgeCore

final class SourceUpdateCommandTests: XCTestCase {
    private let sha = String(repeating: "a", count: 40)
    private func target(_ label: String = "1.1.5", build: Int = 34) -> SourceUpdateTarget {
        SourceUpdateTarget(commit: sha, label: label, build: build)!
    }
    private func info(_ changes: [String: Any] = [:]) throws -> Data {
        var plist: [String: Any] = ["CFBundleIdentifier": "dev.koebridge.app",
            "KoeBridgeReleaseLabel": "1.1.5", "CFBundleShortVersionString": "1.1.5", "CFBundleVersion": "34"]
        plist.merge(changes) { _, new in new }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
    func testValidPinnedMainMetadata() throws {
        let data = Data("{\"name\":\"main\",\"commit\":{\"sha\":\"\(sha)\"}}".utf8)
        XCTAssertEqual(try SourceUpdateTarget.decodeHead(data), sha)
    }
    func testDifferentBranchIsRejected() {
        let data = Data("{\"name\":\"other\",\"commit\":{\"sha\":\"\(sha)\"}}".utf8)
        XCTAssertThrowsError(try SourceUpdateTarget.decodeHead(data))
    }
    func testInvalidHeadShapesAreRejected() {
        for raw in ["{}", "null", "[]", "{\"name\":\"main\",\"commit\":{\"sha\":\"main\"}}"] {
            XCTAssertThrowsError(try SourceUpdateTarget.decodeHead(Data(raw.utf8)))
        }
    }
    func testCommitMustBeFullLowercaseHex() {
        for value in ["main", "", String(repeating: "a", count: 39), String(repeating: "a", count: 41),
                      String(repeating: "A", count: 40), String(repeating: "g", count: 40), sha + "\n", "$(id)"] {
            XCTAssertFalse(SourceUpdateTarget.validCommit(value), value)
        }
    }
    func testLabelRejectsShellAndNoncanonicalForms() {
        for label in ["v1.1.5", "01.1.5", "+1.1.5", "1.1.5\n", "1.1.5;id", "$(id)", "1.1.5'",
                      "1.1.5-beta", "1.1.5B", "1.1.5bb", "１.１.５", "1.1", "-1.1.5", "1.1.9999999999999999999999999999"] {
            XCTAssertNil(SourceUpdateTarget(commit: sha, label: label, build: 34), label)
        }
    }
    func testSuffixConventionRemainsSupported() {
        XCTAssertNotNil(SourceUpdateTarget(commit: sha, label: "1.1.4b", build: 33))
    }
    func testBuildMustBePositive() {
        XCTAssertNil(SourceUpdateTarget(commit: sha, label: "1.1.5", build: 0))
        XCTAssertNil(SourceUpdateTarget(commit: sha, label: "1.1.5", build: -1))
    }
    func testPlistMetadataMatchesCandidate() throws {
        XCTAssertEqual(try SourceUpdateTarget.decodeInfoPlist(info(), commit: sha), target())
    }
    func testWrongBundleIdentityRejected() throws {
        XCTAssertThrowsError(try SourceUpdateTarget.decodeInfoPlist(info(["CFBundleIdentifier": "another.app"]), commit: sha))
    }
    func testNumericBundleVersionMustMatchLabel() throws {
        XCTAssertThrowsError(try SourceUpdateTarget.decodeInfoPlist(info(["CFBundleShortVersionString": "1.1.4"]), commit: sha))
    }
    func testSuffixLabelMatchesNumericVersion() throws {
        XCTAssertNoThrow(try SourceUpdateTarget.decodeInfoPlist(info([
            "KoeBridgeReleaseLabel": "1.1.4b", "CFBundleShortVersionString": "1.1.4"]), commit: sha))
    }
    func testNoncanonicalBuildRejected() throws {
        for build in ["034", "34\n", "+34", "0", "-1", "999999999999999999999999999999"] {
            XCTAssertThrowsError(try SourceUpdateTarget.decodeInfoPlist(info(["CFBundleVersion": build]), commit: sha))
        }
    }
    func testMissingOrMalformedPlistRejected() {
        for bytes in [Data(), Data("<plist/>".utf8), Data("not a plist".utf8)] {
            XCTAssertThrowsError(try SourceUpdateTarget.decodeInfoPlist(bytes, commit: sha))
        }
    }
    func testBinaryPlistSupported() throws {
        let source = try PropertyListSerialization.propertyList(from: info(), format: nil)
        let data = try PropertyListSerialization.data(fromPropertyList: source, format: .binary, options: 0)
        XCTAssertEqual(try SourceUpdateTarget.decodeInfoPlist(data, commit: sha), target())
    }
    func testNewVersionAndBuildAreAvailableWithoutReleaseTag() {
        XCTAssertTrue(target().isNewer(than: "1.1.4b", build: 33))
        XCTAssertTrue(target().canBuild(over: "1.1.4b", build: 33))
    }
    func testSameLabelHigherBuildIsAnUpdate() {
        XCTAssertTrue(target().isNewer(than: "1.1.5", build: 33))
    }
    func testSameVersionCanRebuildWithoutClaimingNewRelease() {
        XCTAssertTrue(target().canBuild(over: "1.1.5", build: 34))
        XCTAssertFalse(target().isNewer(than: "1.1.5", build: 34))
    }
    func testNoVersionDowngrade() {
        XCTAssertFalse(target().canBuild(over: "1.1.6", build: 33))
    }
    func testNoBuildDowngradeEvenForNewerLabel() {
        XCTAssertFalse(target().canBuild(over: "1.1.4b", build: 35))
    }
    func testUnknownInstalledVersionFailsClosed() {
        XCTAssertFalse(target().canBuild(over: "unknown", build: 33))
        XCTAssertFalse(target().canBuild(over: "1.1.4b", build: 0))
    }
    func testCommandPinsExactCommitNotMainOrAbsentTag() {
        let command = target().command
        XCTAssertTrue(command.contains("SHA='\(sha)'"))
        XCTAssertFalse(command.contains("refs/tags/"))
        XCTAssertFalse(command.contains("git pull"))
        XCTAssertTrue(command.contains("FETCH_HEAD^{commit}"))
        XCTAssertTrue(command.contains("git rev-parse HEAD"))
    }
    func testCommandPreservesLocalWorkAndAvoidsForceReset() {
        let command = target().command
        XCTAssertTrue(command.contains("--porcelain --untracked-files=normal"))
        XCTAssertTrue(command.contains("merge-base --is-ancestor HEAD"))
        XCTAssertTrue(command.contains("merge --ff-only"))
        XCTAssertFalse(command.contains("reset --hard"))
        XCTAssertFalse(command.contains("git clean"))
        XCTAssertFalse(command.contains("sudo"))
    }
    func testCommandChecksIdentityVersionBeforeBuildAndAfter() {
        let command = target().command
        XCTAssertTrue(command.contains("Print :CFBundleIdentifier"))
        XCTAssertEqual(command.components(separatedBy: "Print :KoeBridgeReleaseLabel").count - 1, 2)
        XCTAssertEqual(command.components(separatedBy: "Print :CFBundleVersion").count - 1, 2)
        XCTAssertTrue(command.range(of: "bash scripts/verify_and_build.sh")!.lowerBound < command.range(of: "open \"$APP\"")!.lowerBound)
    }
    func testCommandNeverDisablesSigningOrSystemSecurity() {
        let command = target().command
        for forbidden in ["KOEBRIDGE_ALLOW_ADHOC=1", "xattr", "spctl", "codesign --remove", "curl", "eval "] {
            XCTAssertFalse(command.contains(forbidden), forbidden)
        }
        XCTAssertTrue(command.contains("pgrep -x KoeBridge"))
        XCTAssertTrue(command.contains("core.hooksPath=/dev/null"))
    }
}
