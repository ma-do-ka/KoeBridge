import Foundation

/// One delivery's zero-based chunk indices. The experimental budget is a
/// diagnostic threshold, never permission to compress gaps or stop mid-text.
public enum DeliveryPacingPolicy {
    public enum Profile: Equatable, Sendable {
        case numericSelection, unobservableSelection

        public var name: InputDiagnosticEvent.Token {
            self == .numericSelection ? .numericSelectionV1 : .unobservableSelectionV1
        }
        public var version: Int { 1 }
        public var gapNanoseconds: UInt64 { self == .numericSelection ? 3_000_000 : 20_000_000 }
        public var budgetNanoseconds: UInt64 { self == .numericSelection ? 300_000_000 : 2_000_000_000 }
    }

    public static func profile(selectionKind: InputDiagnosticEvent.Token) -> Profile {
        selectionKind == .numericRange ? .numericSelection : .unobservableSelection
    }

    public static func delayNanoseconds(beforeChunk index: Int,
                                        profile: Profile = .numericSelection) -> UInt64 {
        guard index > 0 else { return 0 }
        if profile == .numericSelection && index > 100 { return 0 }
        return profile.gapNanoseconds
    }

    public static func budgetExceeded(beforeChunk index: Int, profile: Profile) -> Bool {
        // Division avoids overflow for even Int.max chunk indices.
        profile == .unobservableSelection && index > Int(profile.budgetNanoseconds / profile.gapNanoseconds)
    }
}
