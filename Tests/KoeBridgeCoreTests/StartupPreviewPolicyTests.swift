import Foundation
import Testing
@testable import KoeBridgeCore

struct StartupPreviewPolicyTests {
    @Test func replacedGitHubNeverPublishes() {
        var policy = StartupPreviewPolicy()
        #expect(policy.interim("GitHub", at: 0) == .suppress)
        let old = policy.generation
        #expect(policy.interim("今日は", at: 0.1) == .suppress)
        #expect(policy.tick(at: 0.26, generation: old) == .suppress)
        #expect(policy.tick(at: 0.26, generation: policy.generation) == .suppress)
        #expect(policy.tick(at: 0.36, generation: policy.generation) == .publish("今日は"))
    }
    @Test func stableFirstHypothesisPublishesAfterDwell() {
        var policy = StartupPreviewPolicy()
        #expect(policy.interim("hello", at: 1) == .suppress)
        #expect(policy.tick(at: 1.249, generation: policy.generation) == .suppress)
        #expect(policy.tick(at: 1.25, generation: policy.generation) == .publish("hello"))
        #expect(policy.interim("replacement", at: 1.26) == .publish("replacement"))
    }
    @Test func revisionsCannotSuppressBeyondOneSecond() {
        var policy = StartupPreviewPolicy()
        for i in 0..<5 { #expect(policy.interim("revision \(i)", at: Double(i) * 0.2) == .suppress) }
        #expect(policy.tick(at: 1, generation: policy.generation) == .publish("revision 4"))
        policy.reset()
        #expect(policy.interim("first", at: 0) == .suppress)
        #expect(policy.interim("latest", at: 1) == .publish("latest"))
    }
    @Test func spokenGitHubPublishesByDwellOrCorroboration() {
        var policy = StartupPreviewPolicy()
        #expect(policy.interim("GitHub", at: 0) == .suppress)
        #expect(policy.tick(at: 0.25, generation: policy.generation) == .publish("GitHub"))
        policy.reset()
        #expect(policy.interim("GitHub", at: 1) == .suppress)
        #expect(policy.interim("GitHub", at: 1.01) == .publish("GitHub"))
        policy.reset()
        #expect(policy.interim("GitHub", at: 2) == .suppress)
        #expect(policy.interim("GitHub Actions", at: 2.01) == .publish("GitHub Actions"))
    }
    @Test func finalBypassesDwellAndRawAssemblerIsUntouched() {
        var policy = StartupPreviewPolicy()
        var assembler = TranscriptAssembler()
        assembler.apply(.interim("GitHub"))
        #expect(policy.interim(assembler.displayText, at: 0) == .suppress)
        #expect(assembler.recoveryText == "GitHub")
        assembler.apply(.final("実際の文章"))
        #expect(policy.final(assembler.displayText) == .publish(assembler.displayText))
        #expect(policy.interim("next", at: 0.01) == .publish("next"))
    }
    @Test func resetAndStaleGenerationsCannotPublish() {
        var policy = StartupPreviewPolicy()
        _ = policy.interim("old take", at: 0)
        let old = policy.generation
        policy.reset()
        #expect(policy.tick(at: 10, generation: old) == .suppress)
        _ = policy.interim("new take", at: 10)
        #expect(policy.tick(at: 11, generation: old) == .suppress)
        #expect(policy.tick(at: 10.25, generation: policy.generation) == .publish("new take"))
    }
    @Test func emptyRevisionCancelsPendingWithoutResettingCap() {
        var policy = StartupPreviewPolicy()
        _ = policy.interim("old", at: 0)
        _ = policy.interim("", at: 0.1)
        #expect(policy.tick(at: 0.5, generation: policy.generation) == .suppress)
        #expect(policy.interim("latest", at: 1) == .publish("latest"))
    }
}
