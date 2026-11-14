import Foundation
import KoeBridgeCore

struct StartupPreviewPolicyTests {
    func replacedGitHubNeverPublishes() {
        var policy = StartupPreviewPolicy()
        check(policy.interim("GitHub", at: 0) == .suppress)
        let old = policy.generation
        check(policy.interim("今日は", at: 0.1) == .suppress)
        check(policy.tick(at: 0.26, generation: old) == .suppress)
        check(policy.tick(at: 0.26, generation: policy.generation) == .suppress)
        check(policy.tick(at: 0.36, generation: policy.generation) == .publish("今日は"))
    }
    func stableFirstHypothesisPublishesAfterDwell() {
        var policy = StartupPreviewPolicy()
        check(policy.interim("hello", at: 1) == .suppress)
        check(policy.tick(at: 1.249, generation: policy.generation) == .suppress)
        check(policy.tick(at: 1.25, generation: policy.generation) == .publish("hello"))
        check(policy.interim("replacement", at: 1.26) == .publish("replacement"))
    }
    func revisionsCannotSuppressBeyondOneSecond() {
        var policy = StartupPreviewPolicy()
        for i in 0..<5 { check(policy.interim("revision \(i)", at: Double(i) * 0.2) == .suppress) }
        check(policy.tick(at: 1, generation: policy.generation) == .publish("revision 4"))
        policy.reset()
        check(policy.interim("first", at: 0) == .suppress)
        check(policy.interim("latest", at: 1) == .publish("latest"))
    }
    func spokenGitHubPublishesByDwellOrCorroboration() {
        var policy = StartupPreviewPolicy()
        check(policy.interim("GitHub", at: 0) == .suppress)
        check(policy.tick(at: 0.25, generation: policy.generation) == .publish("GitHub"))
        policy.reset()
        check(policy.interim("GitHub", at: 1) == .suppress)
        check(policy.interim("GitHub", at: 1.01) == .publish("GitHub"))
        policy.reset()
        check(policy.interim("GitHub", at: 2) == .suppress)
        check(policy.interim("GitHub Actions", at: 2.01) == .publish("GitHub Actions"))
    }
    func finalBypassesDwellAndRawAssemblerIsUntouched() {
        var policy = StartupPreviewPolicy()
        var assembler = TranscriptAssembler()
        assembler.apply(.interim("GitHub"))
        check(policy.interim(assembler.displayText, at: 0) == .suppress)
        check(assembler.recoveryText == "GitHub")
        assembler.apply(.final("実際の文章"))
        check(policy.final(assembler.displayText) == .publish(assembler.displayText))
        check(policy.interim("next", at: 0.01) == .publish("next"))
    }
    func resetAndStaleGenerationsCannotPublish() {
        var policy = StartupPreviewPolicy()
        _ = policy.interim("old take", at: 0)
        let old = policy.generation
        policy.reset()
        check(policy.tick(at: 10, generation: old) == .suppress)
        _ = policy.interim("new take", at: 10)
        check(policy.tick(at: 11, generation: old) == .suppress)
        check(policy.tick(at: 10.25, generation: policy.generation) == .publish("new take"))
    }
    func emptyRevisionCancelsPendingWithoutResettingCap() {
        var policy = StartupPreviewPolicy()
        _ = policy.interim("old", at: 0)
        _ = policy.interim("", at: 0.1)
        check(policy.tick(at: 0.5, generation: policy.generation) == .suppress)
        check(policy.interim("latest", at: 1) == .publish("latest"))
    }
}
