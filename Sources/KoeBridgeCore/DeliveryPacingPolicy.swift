import Foundation

/// One delivery's zero-based chunk indices. No delay before the first chunk;
/// at most 100 gaps of 3 ms, even for arbitrarily large payloads.
public enum DeliveryPacingPolicy {
    public static func delayNanoseconds(beforeChunk index: Int) -> UInt64 {
        index > 0 && index <= 100 ? 3_000_000 : 0
    }
}
