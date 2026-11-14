import Testing
@testable import KoeBridgeCore

struct DeliveryPacingPolicyTests {
    @Test func profileIsSelectedBySelectionCapability() {
        #expect(DeliveryPacingPolicy.profile(selectionKind: .numericRange) == .numericSelection)
        for kind in [InputDiagnosticEvent.Token.textMarker, .none, .unknown] {
            #expect(DeliveryPacingPolicy.profile(selectionKind: kind) == .unobservableSelection)
        }
        let numeric = DeliveryPacingPolicy.Profile.numericSelection
        let unobservable = DeliveryPacingPolicy.Profile.unobservableSelection
        #expect(numeric.name == .numericSelectionV1 && numeric.version == 1)
        #expect(numeric.gapNanoseconds == 3_000_000 && numeric.budgetNanoseconds == 300_000_000)
        #expect(unobservable.name == .unobservableSelectionV1 && unobservable.version == 1)
        #expect(unobservable.gapNanoseconds == 20_000_000 && unobservable.budgetNanoseconds == 2_000_000_000)
    }

    @Test func unobservableGapsContinueBeyondBothBudgets() {
        let profile = DeliveryPacingPolicy.Profile.unobservableSelection
        #expect(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: -1, profile: profile) == 0)
        #expect(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: 0, profile: profile) == 0)
        var total: UInt64 = 0
        for index in 1...10_000 {
            let gap = DeliveryPacingPolicy.delayNanoseconds(beforeChunk: index, profile: profile)
            #expect(gap == 20_000_000)
            total += gap
            #expect(DeliveryPacingPolicy.budgetExceeded(beforeChunk: index, profile: profile) == (total > 2_000_000_000))
        }
        #expect(!DeliveryPacingPolicy.budgetExceeded(beforeChunk: 100, profile: profile))
        #expect(DeliveryPacingPolicy.budgetExceeded(beforeChunk: 101, profile: profile))
        #expect(DeliveryPacingPolicy.budgetExceeded(beforeChunk: Int.max, profile: profile))
        #expect(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: Int.max, profile: profile) == 20_000_000)
        #expect(!DeliveryPacingPolicy.budgetExceeded(beforeChunk: Int.max, profile: .numericSelection))
    }

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
