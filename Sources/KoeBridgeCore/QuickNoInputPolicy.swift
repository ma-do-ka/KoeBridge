/// Only dismiss accidental rapid toggles as "no input". A real recording,
/// an observed transcript, or dropped audio must follow the normal failure
/// and recovery paths. No network/API response is reclassified here.
public enum QuickNoInputPolicy {
    /// Give a short quiet tap a graceful exit. Longer recordings still use ASR.
    public static let quietTapMaximumSeconds: Double = 0.70
    /// Conservatively treat near-silence as quiet; never use this test alone.
    public static let quietPeakLimit: Float = 0.012

    public static func mayBeQuickExit(seconds: Double) -> Bool {
        seconds.isFinite && seconds >= 0 && seconds <= quietTapMaximumSeconds
    }

    public static func shouldSkipRecognition(seconds: Double, pcmBytes: Int,
                                             peak: Float, hasText: Bool,
                                             audioDropped: Bool) -> Bool {
        guard mayBeQuickExit(seconds: seconds),
              peak.isFinite, peak >= 0, pcmBytes >= 0,
              !hasText, !audioDropped else { return false }
        // Duration by itself must NEVER erase a short but audible command.
        // Insufficient PCM with audible activity still follows the existing
        // explicit too-short/failure path, not a misleading no-input toast.
        return peak < quietPeakLimit
    }
}
