import Testing
@testable import KoeBridgeCore

struct DeliveryPacingPolicyTests {
    @Test func firstChunkIsImmediateAndFollowingChunksArePaced() {
        #expect(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: 0) == 0)
        #expect(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: 1) == 3_000_000)
        #expect(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: 100) == 3_000_000)
        #expect(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: 101) == 0)
        #expect(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: Int.max) == 0)
    }
    @Test func cumulativePacingNeverExceedsThreeHundredMilliseconds() {
        var sum: UInt64 = 0
        for index in 0..<10_000 {
            sum += DeliveryPacingPolicy.delayNanoseconds(beforeChunk: index)
            #expect(sum <= 300_000_000)
        }
        #expect(sum == 300_000_000)
    }
}
