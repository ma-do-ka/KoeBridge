import XCTest
@testable import KoeBridgeCore

final class MicrophoneTapFormatPlanTests: XCTestCase {
    func testBuild36RegressionUses16kMonoNotRetained44100Stereo() throws {
        let plan = try XCTUnwrap(MicrophoneTapFormatPlan(hardwareSampleRate: 16_000, hardwareChannels: 1))
        XCTAssertEqual(plan.sampleRate, 16_000)
        XCTAssertEqual(plan.channelCount, 1)
        XCTAssertFalse(plan.matches(sampleRate: 44_100, channels: 2))
        XCTAssertTrue(plan.matches(sampleRate: 16_000, channels: 1))
    }
    func testEarlierInverseMismatchUsesHardware44100Mono() throws {
        let plan = try XCTUnwrap(MicrophoneTapFormatPlan(hardwareSampleRate: 44_100, hardwareChannels: 1))
        XCTAssertEqual(plan.sampleRate, 44_100)
        XCTAssertFalse(plan.matches(sampleRate: 16_000, channels: 1))
    }
    func testUSB48kStereoIsNotForcedToASR16kMono() throws {
        let plan = try XCTUnwrap(MicrophoneTapFormatPlan(hardwareSampleRate: 48_000, hardwareChannels: 2))
        XCTAssertTrue(plan.matches(sampleRate: 48_000, channels: 2))
        XCTAssertFalse(plan.matches(sampleRate: 16_000, channels: 1))
    }
    func testInvalidZeroRateIsRejected() {
        XCTAssertNil(MicrophoneTapFormatPlan(hardwareSampleRate: 0, hardwareChannels: 1))
    }
    func testNegativeRateIsRejected() {
        XCTAssertNil(MicrophoneTapFormatPlan(hardwareSampleRate: -16_000, hardwareChannels: 1))
    }
    func testNonfiniteRatesAreRejected() {
        for rate in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(MicrophoneTapFormatPlan(hardwareSampleRate: rate, hardwareChannels: 1))
        }
    }
    func testZeroChannelsAreRejected() {
        XCTAssertNil(MicrophoneTapFormatPlan(hardwareSampleRate: 16_000, hardwareChannels: 0))
    }
    func testHardwareRateChangeAfterTapIsRejected() throws {
        let plan = try XCTUnwrap(MicrophoneTapFormatPlan(hardwareSampleRate: 16_000, hardwareChannels: 1))
        XCTAssertFalse(plan.matches(sampleRate: 48_000, channels: 1))
    }
    func testHardwareChannelChangeAfterTapIsRejected() throws {
        let plan = try XCTUnwrap(MicrophoneTapFormatPlan(hardwareSampleRate: 16_000, hardwareChannels: 1))
        XCTAssertFalse(plan.matches(sampleRate: 16_000, channels: 2))
    }
    func testReadBackNonfiniteRateFailsClosed() throws {
        let plan = try XCTUnwrap(MicrophoneTapFormatPlan(hardwareSampleRate: 16_000, hardwareChannels: 1))
        for rate in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertFalse(plan.matches(sampleRate: rate, channels: 1))
        }
    }
    func testNewDeviceGetsANewPlan() throws {
        let bluetooth = try XCTUnwrap(MicrophoneTapFormatPlan(hardwareSampleRate: 16_000, hardwareChannels: 1))
        let usb = try XCTUnwrap(MicrophoneTapFormatPlan(hardwareSampleRate: 48_000, hardwareChannels: 2))
        XCTAssertNotEqual(bluetooth, usb)
        XCTAssertFalse(bluetooth.matches(sampleRate: usb.sampleRate, channels: usb.channelCount))
    }
    func testMatchingHardwarePreservesNativeRates() throws {
        for rate: Double in [8_000, 16_000, 24_000, 32_000, 44_100, 48_000, 96_000] {
            let plan = try XCTUnwrap(MicrophoneTapFormatPlan(hardwareSampleRate: rate, hardwareChannels: 1))
            XCTAssertTrue(plan.matches(sampleRate: rate, channels: 1))
        }
    }
    func testMultichannelInputIsNotSilentlyDownmixedAtHardwareBoundary() throws {
        let plan = try XCTUnwrap(MicrophoneTapFormatPlan(hardwareSampleRate: 48_000, hardwareChannels: 8))
        XCTAssertEqual(plan.channelCount, 8)
        XCTAssertFalse(plan.matches(sampleRate: 48_000, channels: 1))
    }
    func testInputAndClientMustBothPassReadback() throws {
        let plan = try XCTUnwrap(MicrophoneTapFormatPlan(hardwareSampleRate: 16_000, hardwareChannels: 1))
        let hardwareOK = plan.matches(sampleRate: 16_000, channels: 1)
        let staleClientOK = plan.matches(sampleRate: 44_100, channels: 2)
        XCTAssertFalse(hardwareOK && staleClientOK)
        XCTAssertTrue(hardwareOK && plan.matches(sampleRate: 16_000, channels: 1))
    }
}
