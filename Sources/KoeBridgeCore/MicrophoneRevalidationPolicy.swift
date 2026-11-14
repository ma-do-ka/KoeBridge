import Foundation

public struct MicrophoneRevalidationInput: Equatable, Sendable {
    public var hasEngineAndTarget: Bool
    public var deviceStillSelected: Bool
    public var engineRunning: Bool
    public var tapInstalled: Bool
    public var outputConnectionsEmpty: Bool
    public var hardwareFormatValid: Bool
    public var hardwareMatchesPlan: Bool
    public var appliedMatchesPlan: Bool
    public var droppedBuffers: Int
    public var conversionErrors: Int

    public init(hasEngineAndTarget: Bool, deviceStillSelected: Bool, engineRunning: Bool,
                tapInstalled: Bool, outputConnectionsEmpty: Bool, hardwareFormatValid: Bool,
                hardwareMatchesPlan: Bool, appliedMatchesPlan: Bool, droppedBuffers: Int,
                conversionErrors: Int) {
        self.hasEngineAndTarget = hasEngineAndTarget; self.deviceStillSelected = deviceStillSelected
        self.engineRunning = engineRunning; self.tapInstalled = tapInstalled
        self.outputConnectionsEmpty = outputConnectionsEmpty; self.hardwareFormatValid = hardwareFormatValid
        self.hardwareMatchesPlan = hardwareMatchesPlan; self.appliedMatchesPlan = appliedMatchesPlan
        self.droppedBuffers = droppedBuffers; self.conversionErrors = conversionErrors
    }
}

public enum MicrophoneRevalidationPolicy {
    public enum Component: String, Equatable, Sendable {
        case lease, conversion, buffers, selection, graph
        case hardwareFormat = "hardware_format", hardwarePlan = "hardware_plan"
        case appliedPlan = "applied_plan", engine, tap
    }
    public enum Verdict: Equatable, Sendable {
        case resume
        case fail(MicrophoneStartupGate.Failure, component: Component)
    }
    public static func evaluate(_ input: MicrophoneRevalidationInput) -> Verdict {
        guard input.hasEngineAndTarget else { return .fail(.engineStopped, component: .lease) }
        guard input.conversionErrors == 0 else { return .fail(.conversionFailed, component: .conversion) }
        guard input.droppedBuffers == 0 else { return .fail(.bufferDropped, component: .buffers) }
        guard input.deviceStillSelected else { return .fail(.inputRouteChanged, component: .selection) }
        guard input.outputConnectionsEmpty else { return .fail(.formatChanged, component: .graph) }
        guard input.hardwareFormatValid else { return .fail(.formatChanged, component: .hardwareFormat) }
        guard input.hardwareMatchesPlan else { return .fail(.formatChanged, component: .hardwarePlan) }
        guard input.appliedMatchesPlan else { return .fail(.formatChanged, component: .appliedPlan) }
        // These would require Outcome C, deliberately deferred to a later build.
        guard input.engineRunning else { return .fail(.engineStopped, component: .engine) }
        guard input.tapInstalled else { return .fail(.formatChanged, component: .tap) }
        return .resume
    }
}
