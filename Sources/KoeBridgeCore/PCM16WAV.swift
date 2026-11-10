import Foundation

/// Canonical recognition-input audio: mono, 16 kHz, signed PCM16 little endian.
public enum PCM16WAV {
    public static func encode(_ pcm16LE: Data) throws -> Data {
        guard !pcm16LE.isEmpty, pcm16LE.count.isMultiple(of: 2) else {
            throw GeminiRecheckWire.RecheckError.invalidAudio
        }
        guard pcm16LE.count <= GeminiRecheckWire.maximumPCMBytes else {
            throw GeminiRecheckWire.RecheckError.tooLarge
        }
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func u32(_ value: UInt32) {
            for offset in [0, 8, 16, 24] { data.append(UInt8(truncatingIfNeeded: value >> offset)) }
        }
        ascii("RIFF"); u32(UInt32(pcm16LE.count) + 36); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcm16LE.count)); data.append(pcm16LE)
        return data
    }

    /// Accept only our canonical header, including exact RIFF/data lengths.
    public static func extractPCM(_ wav: Data) throws -> Data {
        guard wav.count > 44, wav.count <= GeminiRecheckWire.maximumPCMBytes + 44 else {
            throw GeminiRecheckWire.RecheckError.invalidAudio
        }
        let pcm = Data(wav.dropFirst(44))
        guard try encode(pcm) == wav else { throw GeminiRecheckWire.RecheckError.invalidAudio }
        return pcm
    }
}
