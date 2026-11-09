import XCTest
@testable import KoeBridgeCore

final class MicrophoneBindingPolicyTests: XCTestCase {
    func testExactReadbackAuthorizesSuccessfulSetter() {
        XCTAssertEqual(MicrophoneBindingPolicy.outcome(
            requestedID: 42, readBackID: 42, setStatus: 0), .ready)
    }

    func testExactReadbackAuthorizesTransientNonzeroSetterStatus() {
        let nope = Int32(bitPattern: 0x6e6f7065)
        XCTAssertEqual(MicrophoneBindingPolicy.outcome(
            requestedID: 42, readBackID: 42, setStatus: nope), .ready)
    }

    func testNonzeroSetterWithoutExactReadbackPreservesError() {
        let nope = Int32(bitPattern: 0x6e6f7065)
        XCTAssertEqual(MicrophoneBindingPolicy.outcome(
            requestedID: 42, readBackID: 7, setStatus: nope), .selectionFailed(nope))
        XCTAssertEqual(MicrophoneBindingPolicy.outcome(
            requestedID: 42, readBackID: nil, setStatus: nope), .selectionFailed(nope))
    }

    func testZeroSetterStatusStillRequiresExactReadback() {
        XCTAssertEqual(MicrophoneBindingPolicy.outcome(
            requestedID: 42, readBackID: 7, setStatus: 0), .selectionNotApplied)
    }

    func testZeroRequestedDeviceFailsClosed() {
        XCTAssertEqual(MicrophoneBindingPolicy.outcome(
            requestedID: 0, readBackID: 0, setStatus: 0), .selectionNotApplied)
    }
}
