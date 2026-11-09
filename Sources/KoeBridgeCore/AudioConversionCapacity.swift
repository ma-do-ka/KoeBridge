import Foundation

/// Converts an input audio buffer length to a bounded output-buffer capacity.
/// Invalid or extreme CoreAudio metadata must fail closed instead of trapping
/// during floating-point to integer conversion.
public enum AudioConversionCapacity {
    public static func frames(inputFrames: Int, inputRate: Double,
                              outputRate: Double = 16_000,
                              margin: Int = 128,
                              maximum: Int = Int(UInt32.max)) -> Int? {
        guard inputFrames > 0, margin >= 0, maximum > margin,
              inputRate.isFinite, inputRate > 0,
              outputRate.isFinite, outputRate > 0 else { return nil }
        let scaled = (Double(inputFrames) * outputRate / inputRate).rounded(.up)
        guard scaled.isFinite, scaled > 0,
              scaled <= Double(maximum - margin) else { return nil }
        return Int(scaled) + margin
    }
}
