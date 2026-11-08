import Foundation
import XCTest
@testable import KoeBridgeCore

final class MicrophoneSelectionPolicyTests: XCTestCase {
    let a = MicrophoneDeviceOption(uid: "test-a", name: "A", deviceID: 1)
    let b = MicrophoneDeviceOption(uid: "test-b", name: "B", deviceID: 2)
    func testDefaultUsesCurrentSystemDevice() throws {
        let t = try MicrophoneSelectionPolicy.resolve(uid: "", devices: [a,b], systemDefaultID: 2)
        XCTAssertEqual(t.uid, b.uid); XCTAssertTrue(t.followsSystem)
    }
    func testDefaultFollowsChangedDeviceOnNextRecording() throws {
        XCTAssertEqual(try MicrophoneSelectionPolicy.resolve(uid: "", devices: [a,b], systemDefaultID: 1).deviceID, 1)
        XCTAssertEqual(try MicrophoneSelectionPolicy.resolve(uid: "", devices: [a,b], systemDefaultID: 2).deviceID, 2)
    }
    func testExplicitChoiceOverridesSystem() throws {
        let t = try MicrophoneSelectionPolicy.resolve(uid: a.uid, devices: [a,b], systemDefaultID: 2)
        XCTAssertEqual(t.deviceID, 1); XCTAssertFalse(t.followsSystem)
    }
    func testMissingExplicitChoiceNeverFallsBack() {
        XCTAssertThrowsError(try MicrophoneSelectionPolicy.resolve(uid: "missing", devices: [a,b], systemDefaultID: 1)) {
            XCTAssertEqual($0 as? MicrophoneSelectionError, .selectedDeviceMissing)
        }
    }
    func testDisconnectedDefaultFailsClosed() {
        XCTAssertThrowsError(try MicrophoneSelectionPolicy.resolve(uid: "", devices: [a], systemDefaultID: 2))
    }
    func testNoDefaultFailsClosed() {
        XCTAssertThrowsError(try MicrophoneSelectionPolicy.resolve(uid: "", devices: [a], systemDefaultID: nil))
    }
    func testZeroDefaultFailsClosed() {
        XCTAssertThrowsError(try MicrophoneSelectionPolicy.resolve(uid: "", devices: [a], systemDefaultID: 0))
    }
    func testReconnectResolvesNewIDByUID() throws {
        let new = MicrophoneDeviceOption(uid: a.uid, name: "Renamed", deviceID: 9)
        XCTAssertEqual(try MicrophoneSelectionPolicy.resolve(uid: a.uid, devices: [new], systemDefaultID: nil).deviceID, 9)
    }
    func testDuplicateUIDIsRejected() {
        let duplicate = MicrophoneDeviceOption(uid: a.uid, name: "A2", deviceID: 9)
        XCTAssertThrowsError(try MicrophoneSelectionPolicy.resolve(uid: a.uid, devices: [a,duplicate], systemDefaultID: nil))
    }
    func testIdenticalNamesDoNotCollapseDifferentDevices() throws {
        let duplicateName = MicrophoneDeviceOption(uid: "other", name: a.name, deviceID: 9)
        XCTAssertEqual(try MicrophoneSelectionPolicy.resolve(uid: "other", devices: [a,duplicateName], systemDefaultID: 1).deviceID, 9)
    }
    func testDefaultChangeInterruptsFollowingRecording() throws {
        let t = try MicrophoneSelectionPolicy.resolve(uid: "", devices: [a,b], systemDefaultID: 1)
        XCTAssertFalse(MicrophoneSelectionPolicy.isStillSelected(t, devices: [a,b], systemDefaultID: 2, actualUnitDeviceID: 1))
    }
    func testDefaultChangeDoesNotInvalidateExplicitSelection() throws {
        let t = try MicrophoneSelectionPolicy.resolve(uid: a.uid, devices: [a,b], systemDefaultID: 1)
        XCTAssertTrue(MicrophoneSelectionPolicy.isStillSelected(t, devices: [a,b], systemDefaultID: 2, actualUnitDeviceID: 1))
    }
    func testUnexpectedAudioUnitFallbackIsRejected() throws {
        let t = try MicrophoneSelectionPolicy.resolve(uid: a.uid, devices: [a,b], systemDefaultID: 2)
        XCTAssertFalse(MicrophoneSelectionPolicy.isStillSelected(t, devices: [a,b], systemDefaultID: 2, actualUnitDeviceID: 2))
    }
    func testReusedNumericIDCannotSelectDifferentMicrophone() throws {
        let t = try MicrophoneSelectionPolicy.resolve(uid: a.uid, devices: [a], systemDefaultID: nil)
        let reused = MicrophoneDeviceOption(uid: b.uid, name: b.name, deviceID: 1)
        XCTAssertFalse(MicrophoneSelectionPolicy.isStillSelected(t, devices: [reused], systemDefaultID: nil, actualUnitDeviceID: 1))
    }
    func testDisconnectedExplicitSelectionInterrupts() throws {
        let t = try MicrophoneSelectionPolicy.resolve(uid: a.uid, devices: [a,b], systemDefaultID: 2)
        XCTAssertFalse(MicrophoneSelectionPolicy.isStillSelected(t, devices: [b], systemDefaultID: 2, actualUnitDeviceID: 1))
    }
    func testNoUnitReadbackFailsClosed() throws {
        let t = try MicrophoneSelectionPolicy.resolve(uid: a.uid, devices: [a], systemDefaultID: nil)
        XCTAssertFalse(MicrophoneSelectionPolicy.isStillSelected(t, devices: [a], systemDefaultID: nil, actualUnitDeviceID: nil))
    }
    func testZeroIDExplicitDeviceIsNotSelectable() {
        let zero = MicrophoneDeviceOption(uid: a.uid, name: a.name, deviceID: 0)
        XCTAssertThrowsError(try MicrophoneSelectionPolicy.resolve(uid: a.uid, devices: [zero], systemDefaultID: nil))
    }
    func testEmptyUIDIsNotSelectableAsDefault() {
        let empty = MicrophoneDeviceOption(uid: "", name: "A", deviceID: 1)
        XCTAssertThrowsError(try MicrophoneSelectionPolicy.resolve(uid: "", devices: [empty], systemDefaultID: 1))
    }
}

final class SignedUpdateConfigurationTests: XCTestCase {
    let key = Data(repeating: 1, count: 32).base64EncodedString()
    func ready(key: String? = nil, feed: String? = nil, archive: Bool = true, signed: Bool = true, expiry: Double? = 0) -> Bool {
        SignedUpdateConfiguration.isReady(publicKey: key ?? self.key,
            feed: feed ?? SignedUpdateConfiguration.feedURL, verifiesArchive: archive,
            requiresSignedFeed: signed, signatureExpiry: expiry)
    }
    func testValidPinnedConfiguration() { XCTAssertTrue(ready()) }
    func testMissingKeyRejected() {
        XCTAssertFalse(SignedUpdateConfiguration.isReady(publicKey: nil, feed: SignedUpdateConfiguration.feedURL,
            verifiesArchive: true, requiresSignedFeed: true, signatureExpiry: 0))
    }
    func testEmptyKeyRejected() { XCTAssertFalse(ready(key: "")) }
    func testPlaceholderRejected() { XCTAssertFalse(ready(key: "ADD_PUBLIC_KEY_HERE")) }
    func testZeroKeyRejected() { XCTAssertFalse(ready(key: Data(repeating: 0, count: 32).base64EncodedString())) }
    func testShortKeyRejected() { XCTAssertFalse(ready(key: Data(repeating: 1, count: 31).base64EncodedString())) }
    func testLongKeyRejected() { XCTAssertFalse(ready(key: Data(repeating: 1, count: 64).base64EncodedString())) }
    func testArbitraryFeedRejected() { XCTAssertFalse(ready(feed: "https://example.org/feed.xml")) }
    func testHTTPRejected() { XCTAssertFalse(ready(feed: SignedUpdateConfiguration.feedURL.replacingOccurrences(of: "https:", with: "http:"))) }
    func testMissingArchiveVerificationRejected() { XCTAssertFalse(ready(archive: false)) }
    func testMissingFeedVerificationRejected() { XCTAssertFalse(ready(signed: false)) }
    func testTimeBasedSignatureBypassRejected() { XCTAssertFalse(ready(expiry: 1728000)) }
    func testMissingExpirationPolicyRejected() { XCTAssertFalse(ready(expiry: nil)) }
    func testKeyWhitespaceRejected() { XCTAssertFalse(ready(key: key + "\n")) }
}
