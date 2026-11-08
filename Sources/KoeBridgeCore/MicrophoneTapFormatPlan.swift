/// A hardware-backed AVAudioInputNode cannot resample its input. Select the
/// current hardware rate/channels, never a retained client's old output format
/// or the downstream ASR format. AVAudioConverter does ASR conversion later.
public struct MicrophoneTapFormatPlan: Equatable, Sendable {
    public let sampleRate: Double
    public let channelCount: UInt32

    public init?(hardwareSampleRate: Double, hardwareChannels: UInt32) {
        guard hardwareSampleRate.isFinite, hardwareSampleRate > 0,
              hardwareChannels > 0 else { return nil }
        sampleRate = hardwareSampleRate
        channelCount = hardwareChannels
    }

    /// Used after tap installation AND after engine.prepare(). A changing
    /// route must retry with a new plan rather than start with a stale format.
    public func matches(sampleRate: Double, channels: UInt32) -> Bool {
        sampleRate.isFinite && sampleRate == self.sampleRate && channels == channelCount
    }
}
