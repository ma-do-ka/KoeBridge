import Foundation

/// The microphone can accept a new dictation while previous audio is still
/// being recognized. Never deliver completed text out of recording order.
/// A failed take still occupies its slot until it is explicitly resolved.
public struct OrderedResultBuffer<Value> {
    public private(set) var pending: [UUID] = []
    private var resolved: [UUID: Value] = [:]
    public let maximumPending: Int

    public init(maximumPending: Int = 8) {
        self.maximumPending = max(1, maximumPending)
    }

    public var canBegin: Bool { pending.count < maximumPending }
    public var count: Int { pending.count }

    @discardableResult public mutating func begin(_ id: UUID) -> Bool {
        guard canBegin, !pending.contains(id) else { return false }
        pending.append(id)
        return true
    }

    /// Duplicate / stale callbacks are ignored, not delivered twice.
    @discardableResult public mutating func finish(_ id: UUID, result: Value) -> Bool {
        guard pending.contains(id), resolved[id] == nil else { return false }
        resolved[id] = result
        return true
    }

    /// Drain only the contiguous prefix that has finished. No later turn
    /// can overtake an unresolved earlier one.
    public mutating func drain() -> [(UUID, Value)] {
        var items: [(UUID, Value)] = []
        while let id = pending.first, let value = resolved.removeValue(forKey: id) {
            pending.removeFirst()
            items.append((id, value))
        }
        return items
    }

    /// Cancel all queued takes on sleep / termination. The owner is
    /// responsible for saving any already-known partial text first.
    public mutating func reset() {
        pending.removeAll()
        resolved.removeAll()
    }
}
