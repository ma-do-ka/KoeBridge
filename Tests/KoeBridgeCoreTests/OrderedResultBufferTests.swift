import Foundation
import Testing
@testable import KoeBridgeCore

struct OrderedResultBufferTests {
    @Test func immediateNextRecordingPreservesDeliveryOrder() {
        var queue = OrderedResultBuffer<String>(maximumPending: 8)
        let a = UUID(), b = UUID()
        let check1 = queue.begin(a)
        #expect(check1)
        let check2 = queue.begin(b)
        #expect(check2)
        let check3 = queue.finish(b, result: "後")
        #expect(check3)
        let check4 = queue.drain().isEmpty
        #expect(check4)
        let check5 = queue.finish(a, result: "先")
        #expect(check5)
        let check6 = queue.drain().map(\.1) == ["先", "後"]
        #expect(check6)
    }

    @Test func staleAndDuplicateCompletionsCannotPasteTwice() {
        var queue = OrderedResultBuffer<String>()
        let a = UUID()
        let check7 = queue.begin(a)
        #expect(check7)
        let check8 = !queue.begin(a)
        #expect(check8)
        let check9 = !queue.finish(UUID(), result: "unknown")
        #expect(check9)
        let check10 = queue.finish(a, result: "valid")
        #expect(check10)
        let check11 = !queue.finish(a, result: "duplicate")
        #expect(check11)
        let check12 = queue.drain().map(\.1) == ["valid"]
        #expect(check12)
    }

    @Test func failureOfOldTurnUnblocksNewerCompletedTurn() {
        var queue = OrderedResultBuffer<Int>(maximumPending: 2)
        let a = UUID(), b = UUID(), c = UUID()
        let check13 = queue.begin(a)
        #expect(check13)
        let check14 = queue.begin(b)
        #expect(check14)
        let check15 = !queue.begin(c)
        #expect(check15)
        let check16 = queue.finish(b, result: 2)
        #expect(check16)
        let check17 = queue.drain().isEmpty
        #expect(check17)
        let check18 = queue.finish(a, result: -1)
        #expect(check18)
        let check19 = queue.drain().map(\.1) == [-1, 2]
        #expect(check19)
        let check20 = queue.begin(c)
        #expect(check20)
    }
}
