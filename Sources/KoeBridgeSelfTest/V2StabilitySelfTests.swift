import Foundation
import KoeBridgeCore

struct V2StabilitySelfTests {
    func microphoneBindingRequiresExactReadback() {
        let nope = Int32(bitPattern: 0x6e6f7065)
        check(MicrophoneBindingPolicy.outcome(
            requestedID: 42, readBackID: 42, setStatus: nope) == .ready)
        check(MicrophoneBindingPolicy.outcome(
            requestedID: 42, readBackID: 7, setStatus: nope) == .selectionFailed(nope))
        check(MicrophoneBindingPolicy.outcome(
            requestedID: 42, readBackID: nil, setStatus: 0) == .selectionNotApplied)
    }

    func routeStabilityRejectsTransientMismatchesWithoutAuthorizing() {
        var gate = MicrophoneRouteStabilityGate()
        check(!gate.observe(matches: false))
        check(!gate.observe(matches: false))
        check(gate.hasPendingMismatch)
        check(!gate.observe(matches: true))
        check(!gate.hasPendingMismatch)
        check(!gate.observe(matches: false))
        check(!gate.observe(matches: false))
        check(gate.observe(matches: false))
    }

    func routeRetryBackoffIsShortAndBounded() {
        let policy = MicrophoneStartupRetryPolicy()
        check(abs((policy.retryDelay(after: 1, elapsed: 1, routeTransition: true) ?? -1) - 0.05) < 0.0001)
        check(abs((policy.retryDelay(after: 2, elapsed: 1, routeTransition: true) ?? -1) - 0.10) < 0.0001)
        check(abs((policy.retryDelay(after: 3, elapsed: 1, routeTransition: true) ?? -1) - 0.15) < 0.0001)
        check(policy.retryDelay(after: 4, elapsed: 1, routeTransition: true) == nil)
    }

    func audioConversionCapacityFailsClosed() {
        check(AudioConversionCapacity.frames(inputFrames: 1024, inputRate: 48_000) == 470)
        check(AudioConversionCapacity.frames(inputFrames: 1024, inputRate: 16_000) == 1152)
        check(AudioConversionCapacity.frames(inputFrames: 1024, inputRate: 0) == nil)
        check(AudioConversionCapacity.frames(inputFrames: 1024, inputRate: .nan) == nil)
        check(AudioConversionCapacity.frames(inputFrames: Int(UInt32.max),
                                             inputRate: Double.leastNonzeroMagnitude) == nil)
    }

    func developerDiagnosticsBoundsAndUnicodeAreStable() {
        let limit = DeveloperDiagnosticsPolicy.maximumAudioPCMBytes
        let oversized = Data(repeating: 1, count: limit + 100)
        let capped = DeveloperDiagnosticsPolicy.cappedPCM(oversized)
        check(capped.data.count == limit)
        check(capped.truncated)

        let prefix = String(repeating: "a", count: DeveloperDiagnosticsPolicy.maximumTextUTF8Bytes - 2)
        let text = DeveloperDiagnosticsPolicy.cappedText(prefix + "😀末尾")
        check(text.text == prefix)
        check(text.truncated)

        let delta = DeveloperDiagnosticsPolicy.changedSegment(
            before: "prefix OLD suffix", after: "prefix NEW text suffix")
        check(delta?.text == "NEW text")
        check(DeveloperDiagnosticsPolicy.changedSegment(before: "same", after: "same") == nil)
    }

    func developerDiagnosticsDeclaredFilesFitHardCap() {
        let declared = DeveloperDiagnosticsPolicy.maximumTimelineBytes
            + DeveloperDiagnosticsPolicy.maximumInputTraceBytes
            + DeveloperDiagnosticsPolicy.maximumRecognitionBytes
            + DeveloperDiagnosticsPolicy.maximumDeliveryBytes
            + DeveloperDiagnosticsPolicy.maximumEncodedAudioBytes
        check(declared <= DeveloperDiagnosticsPolicy.maximumSessionBytes)
        let estimatedAACBytes = Int(DeveloperDiagnosticsPolicy.maximumAudioSeconds
            * Double(DeveloperDiagnosticsPolicy.audioBitRate) / 8.0)
        check(estimatedAACBytes <= DeveloperDiagnosticsPolicy.maximumEncodedAudioBytes)
    }

    func tokenAggregationCannotOverflow() {
        check(UsageAggregation.addingTokens(Int.max, 1) == Int.max)
        check(UsageAggregation.addingTokens(-100, 50) == 50)
    }

    func receiptVerificationPlanPreservesExactSemantics() throws {
        let before = InsertionReceiptPolicy.Snapshot(
            text: "📎案：", selection: .init(location: 4, length: 0))
        let after = InsertionReceiptPolicy.Snapshot(
            text: "📎案：明日", selection: .init(location: 6, length: 0))
        let plan = try require(InsertionReceiptPolicy.verificationPlan(before: before, inserted: "明日"))
        let planned = try require(InsertionReceiptPolicy.verify(plan, after: after, sameTarget: true))
        let legacy = try require(InsertionReceiptPolicy.verify(
            before: before, inserted: "明日", after: after, sameTarget: true))
        check(planned == legacy)
    }
}
