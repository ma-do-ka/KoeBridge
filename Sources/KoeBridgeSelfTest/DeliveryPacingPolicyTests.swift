import KoeBridgeCore

struct DeliveryPacingPolicyTests {
    func profileIsSelectedBySelectionCapability() {
        check(DeliveryPacingPolicy.profile(selectionKind: .numericRange) == .numericSelection)
        for kind in [InputDiagnosticEvent.Token.textMarker, .none, .unknown] {
            check(DeliveryPacingPolicy.profile(selectionKind: kind) == .unobservableSelection)
        }
        let numeric = DeliveryPacingPolicy.Profile.numericSelection
        let unobservable = DeliveryPacingPolicy.Profile.unobservableSelection
        check(numeric.name == .numericSelectionV1 && numeric.version == 1)
        check(numeric.gapNanoseconds == 3_000_000 && numeric.budgetNanoseconds == 300_000_000)
        check(unobservable.name == .unobservableSelectionV1 && unobservable.version == 1)
        check(unobservable.gapNanoseconds == 20_000_000 && unobservable.budgetNanoseconds == 2_000_000_000)
    }

    func unobservableGapsContinueBeyondBothBudgets() {
        let profile = DeliveryPacingPolicy.Profile.unobservableSelection
        check(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: -1, profile: profile) == 0)
        check(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: 0, profile: profile) == 0)
        var total: UInt64 = 0
        for index in 1...10_000 {
            let gap = DeliveryPacingPolicy.delayNanoseconds(beforeChunk: index, profile: profile)
            check(gap == 20_000_000)
            total += gap
            check(DeliveryPacingPolicy.budgetExceeded(beforeChunk: index, profile: profile) == (total > 2_000_000_000))
        }
        check(!DeliveryPacingPolicy.budgetExceeded(beforeChunk: 100, profile: profile))
        check(DeliveryPacingPolicy.budgetExceeded(beforeChunk: 101, profile: profile))
        check(DeliveryPacingPolicy.budgetExceeded(beforeChunk: Int.max, profile: profile))
        check(DeliveryPacingPolicy.delayNanoseconds(beforeChunk: Int.max, profile: profile) == 20_000_000)
        check(!DeliveryPacingPolicy.budgetExceeded(beforeChunk: Int.max, profile: .numericSelection))
    }

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
