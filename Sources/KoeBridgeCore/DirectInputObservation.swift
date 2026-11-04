import Foundation

/// Observes one contiguous text edit without trusting a successful AX write
/// or an event-posting call as evidence of actual text insertion.
/// Absence of evidence must NEVER trigger a blind resend: duplicate insertion
/// is worse than an explicit unconfirmed delivery kept in history.
public enum DirectInputObservation: Equatable {
    case verifiedInsertion
    case unchanged
    case changedButUnverified
    case unobservable

    public static func classify(before: String?, after: String?, inserted: String) -> Self {
        guard let before, let after, !inserted.isEmpty else { return .unobservable }
        guard before != after else { return .unchanged }
        let previous = Array(before)
        let current = Array(after)
        var prefix = 0
        while prefix < min(previous.count, current.count), previous[prefix] == current[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < previous.count - prefix, suffix < current.count - prefix,
              previous[previous.count - 1 - suffix] == current[current.count - 1 - suffix] {
            suffix += 1
        }
        let insertedSpan = String(current[prefix..<(current.count - suffix)])
        return insertedSpan == inserted ? .verifiedInsertion : .changedButUnverified
    }
}
