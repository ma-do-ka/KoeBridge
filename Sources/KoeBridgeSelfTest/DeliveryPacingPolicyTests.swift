import KoeBridgeCore

struct DeliveryPacingPolicyTests {
    func firstChunkIsImmediateAndFollowingChunksArePaced() {
        check(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: 0) == 0)
        check(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: 1) == 3_000_000)
        check(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: 100) == 3_000_000)
        check(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: 101) == 0)
        check(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: Int.max) == 0)
    }
    func cumulativePacingNeverExceedsThreeHundredMilliseconds() {
        var sum: UInt64 = 0
        for index in 0..<10_000 {
            sum += DeliveryPacingPolicy.delayNanoseconds(beforeChunk: index)
            check(sum <= 300_000_000)
        }
        check(sum == 300_000_000)
    }
}
