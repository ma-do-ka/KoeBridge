import Foundation

/// Hard privacy and disk limits for the opt-in developer diagnostics mode.
/// These limits are deliberately independent from ordinary diagnostics/history.
public enum DeveloperDiagnosticsPolicy {
    public static let maximumAudioSeconds: TimeInterval = 20
    public static let pcmBytesPerSecond = 32_000 // 16 kHz, mono, signed 16-bit
    public static let maximumAudioPCMBytes = Int(maximumAudioSeconds) * pcmBytesPerSecond
    public static let audioBitRate = 24_000
    public static let maximumSessions = 30
    public static let maximumTotalBytes = 8 * 1024 * 1024
    public static let maximumSessionBytes = 512 * 1024
    public static let maximumGlobalLogBytes = 256 * 1024
    public static let maximumInputTraceBytes = 256 * 1024
    public static let maximumTextUTF8Bytes = 32 * 1024
    public static let developerInputTraceEvents = 512
    public static let developerInputTraceInitialEvents = 64

    public static func cappedPCM(_ data: Data) -> (data: Data, truncated: Bool) {
        guard data.count > maximumAudioPCMBytes else { return (data, false) }
        return (Data(data.prefix(maximumAudioPCMBytes)), true)
    }

    public static func cappedText(_ text: String) -> (text: String, truncated: Bool) {
        let bytes = Array(text.utf8)
        guard bytes.count > maximumTextUTF8Bytes else { return (text, false) }
        var end = maximumTextUTF8Bytes
        while end > 0 && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        return (String(decoding: bytes.prefix(end), as: UTF8.self), true)
    }

    public static func mayRetainSession(fileBytes: Int, totalBytes: Int, retainedSessions: Int) -> Bool {
        fileBytes >= 0 && totalBytes >= 0 && retainedSessions >= 0
            && fileBytes <= maximumSessionBytes
            && totalBytes <= maximumTotalBytes
            && retainedSessions <= maximumSessions
    }
}
