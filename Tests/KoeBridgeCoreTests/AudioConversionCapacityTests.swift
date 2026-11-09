import XCTest
@testable import KoeBridgeCore

final class AudioConversionCapacityTests: XCTestCase {
    func testNormalResamplingCapacity() {
        XCTAssertEqual(AudioConversionCapacity.frames(inputFrames: 1024, inputRate: 48_000), 470)
        XCTAssertEqual(AudioConversionCapacity.frames(inputFrames: 1024, inputRate: 16_000), 1152)
    }

    func testInvalidRatesFailClosed() {
        for rate in [0, -1, Double.nan, Double.infinity] {
            XCTAssertNil(AudioConversionCapacity.frames(inputFrames: 1024, inputRate: rate))
        }
    }

    func testExtremeRatioCannotOverflowFrameCount() {
        XCTAssertNil(AudioConversionCapacity.frames(inputFrames: Int(UInt32.max),
                                                     inputRate: Double.leastNonzeroMagnitude))
    }

    func testInvalidFrameAndMarginValuesFailClosed() {
        XCTAssertNil(AudioConversionCapacity.frames(inputFrames: 0, inputRate: 16_000))
        XCTAssertNil(AudioConversionCapacity.frames(inputFrames: -1, inputRate: 16_000))
        XCTAssertNil(AudioConversionCapacity.frames(inputFrames: 1, inputRate: 16_000,
                                                     margin: -1))
    }
}
