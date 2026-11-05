/// A very short activation has too little audio for a reliable cloud final.
/// PCM is signed Int16 mono at 16 kHz (32,000 bytes/second).
public enum AudioDurationPolicy {
    public static let minimumPCMBytes = 3_200 // 100 ms
    public static func hasEnoughAudio(pcmBytes: Int) -> Bool {
        pcmBytes >= minimumPCMBytes
    }
}


/// Only dismiss accidental rapid toggles as "no input". A real recording,
/// an observed transcript, or dropped audio must follow the normal failure
/// and recovery paths. No network/API response is reclassified here.
public enum QuickNoInputPolicy {
    /// Too little time for useful speech even if a tap transient is loud.
    public static let minimumIntentionalSeconds: Double = 0.18
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
        if seconds < minimumIntentionalSeconds { return true }
        if !AudioDurationPolicy.hasEnoughAudio(pcmBytes: pcmBytes) { return true }
        return peak < quietPeakLimit
    }
}
