import Foundation
import KoeBridgeCore

struct OrderedResultBufferTests {
    func anEarlierUnfinishedTakeDoesNotBlockStartingAnother() {
        var queue = OrderedResultBuffer<String>(maximumPending: 8)
        let first = UUID(), second = UUID()
        check(queue.begin(first))
        check(queue.begin(second))
        check(queue.finish(second, result: "後の録音"))
        check(queue.drain().isEmpty) // must not paste out of order
        check(queue.finish(first, result: "先の録音"))
        let ready = queue.drain()
        check(ready.map(\.0) == [first, second])
        check(ready.map(\.1) == ["先の録音", "後の録音"])
        check(queue.count == 0)
    }
    func repeatedCallbacksAndUnknownIdsDoNotDuplicate() {
        var queue = OrderedResultBuffer<String>()
        let id = UUID()
        check(queue.begin(id))
        check(!queue.begin(id))
        check(!queue.finish(UUID(), result: "unknown"))
        check(queue.finish(id, result: "一度だけ"))
        check(!queue.finish(id, result: "重複"))
        check(queue.drain().map(\.1) == ["一度だけ"])
        check(!queue.finish(id, result: "late"))
    }
    func boundedJobsAndFailureUnblock() {
        var queue = OrderedResultBuffer<String>(maximumPending: 3)
        let ids = (0..<4).map { _ in UUID() }
        for id in ids.prefix(3) { check(queue.begin(id)) }
        check(!queue.begin(ids[3]))
        check(queue.finish(ids[1], result: "2"))
        check(queue.finish(ids[2], result: "3"))
        check(queue.drain().isEmpty)
        check(queue.finish(ids[0], result: "failure"))
        check(queue.drain().map(\.1) == ["failure", "2", "3"])
        check(queue.begin(ids[3]))
    }
    func cancelledSessionClearsPreviousResults() {
        var queue = OrderedResultBuffer<String>()
        let old = UUID(), next = UUID()
        check(queue.begin(old))
        check(queue.finish(old, result: "previous"))
        queue.reset()
        check(!queue.finish(old, result: "late"))
        check(queue.begin(next))
        check(queue.finish(next, result: "new"))
        check(queue.drain().map(\.1) == ["new"])
    }
    func rapidSuccessionsAlwaysStayInOrder() {
        var queue = OrderedResultBuffer<Int>(maximumPending: 8)
        for _ in 0..<200 {
            let ids = (0..<8).map { _ in UUID() }
            for id in ids { check(queue.begin(id)) }
            for j in stride(from: 7, through: 0, by: -1) {
                check(queue.finish(ids[j], result: j))
                if j > 0 { check(queue.drain().isEmpty) }
            }
            check(queue.drain().map(\.1) == Array(0..<8))
        }
    }
}
