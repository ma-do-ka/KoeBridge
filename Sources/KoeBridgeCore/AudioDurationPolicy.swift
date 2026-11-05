/// A very short activation has too little audio for a reliable cloud final.
/// PCM is signed Int16 mono at 16 kHz (32,000 bytes/second).
public enum AudioDurationPolicy {
    public static let minimumPCMBytes = 3_200 // 100 ms
    public static func hasEnoughAudio(pcmBytes: Int) -> Bool {
        pcmBytes >= minimumPCMBytes
    }
}
