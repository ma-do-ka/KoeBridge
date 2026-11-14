import XCTest
@testable import KoeBridgeCore

final class MicrophoneRevalidationPolicyTests: XCTestCase {
    func testFullChecklistMatrixAndFailurePrecedence() {
        let good = MicrophoneRevalidationInput(hasEngineAndTarget: true, deviceStillSelected: true,
            engineRunning: true, tapInstalled: true, outputConnectionsEmpty: true, hardwareFormatValid: true,
            hardwareMatchesPlan: true, appliedMatchesPlan: true, droppedBuffers: 0, conversionErrors: 0)
        XCTAssertTrue(MicrophoneRevalidationPolicy.evaluate(good) == .resume)
        let cases: [(WritableKeyPath<MicrophoneRevalidationInput, Bool>, MicrophoneStartupGate.Failure, MicrophoneRevalidationPolicy.Component)] = [
            (\.hasEngineAndTarget, .engineStopped, .lease), (\.deviceStillSelected, .inputRouteChanged, .selection),
            (\.engineRunning, .engineStopped, .engine), (\.tapInstalled, .formatChanged, .tap),
            (\.outputConnectionsEmpty, .formatChanged, .graph), (\.hardwareFormatValid, .formatChanged, .hardwareFormat),
            (\.hardwareMatchesPlan, .formatChanged, .hardwarePlan), (\.appliedMatchesPlan, .formatChanged, .appliedPlan)
        ]
        for (key, failure, component) in cases {
            var input = good; input[keyPath: key] = false
            XCTAssertTrue(MicrophoneRevalidationPolicy.evaluate(input) == .fail(failure, component: component))
        }
        var input = good
        input.droppedBuffers = 1
        XCTAssertTrue(MicrophoneRevalidationPolicy.evaluate(input) == .fail(.bufferDropped, component: .buffers))
        input.conversionErrors = 1
        XCTAssertTrue(MicrophoneRevalidationPolicy.evaluate(input) == .fail(.conversionFailed, component: .conversion))
        input = good; input.deviceStillSelected = false; input.engineRunning = false; input.hardwareMatchesPlan = false
        XCTAssertTrue(MicrophoneRevalidationPolicy.evaluate(input) == .fail(.inputRouteChanged, component: .selection))
    }
}
