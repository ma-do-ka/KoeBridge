import Foundation
import Testing
@testable import KoeBridgeCore

struct ResilienceTests {
    @Test func hotkeyF8OnlyTogglesOncePerPress() {
        var gate = HotKeyPressGate()
        gate.activate(11)
        let first = gate.receive(id: 11, pressed: true)
        #expect(first)
        for _ in 0..<20 {
            let repeatPress = gate.receive(id: 11, pressed: true)
            #expect(!repeatPress)
        }
        let release = gate.receive(id: 11, pressed: false)
        let second = gate.receive(id: 11, pressed: true)
        #expect(!release)
        #expect(second)
    }

    @Test func hotkeySwitchRejectsStaleOldEvents() {
        var gate = HotKeyPressGate()
        gate.activate(10)
        let a = gate.receive(id: 10, pressed: true)
        gate.activate(20)
        let b = gate.receive(id: 10, pressed: false)
        let c = gate.receive(id: 10, pressed: true)
        let d = gate.receive(id: 20, pressed: true)
        let e = gate.receive(id: 20, pressed: false)
        let f = gate.receive(id: 20, pressed: true)
        gate.activate(nil)
        let g = gate.receive(id: 20, pressed: true)
        #expect(a)
        #expect(!b && !c)
        #expect(d && !e && f && !g)
    }

    @Test func finalBeforeReleaseCannotFinalizeEarly() {
        let end = Date(timeIntervalSince1970: 100)
        let final = end.addingTimeInterval(-5)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: final,
                                              turnCompleteAt: nil, now: end))
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: final,
                                              turnCompleteAt: nil, now: end.addingTimeInterval(0.8)))
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: final,
                                              turnCompleteAt: nil, now: end.addingTimeInterval(1.25)))
    }

    @Test func finalAndTurnCompleteInEitherOrder() {
        let end = Date(timeIntervalSince1970: 100)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: nil,
                                              turnCompleteAt: end.addingTimeInterval(0.1), now: end.addingTimeInterval(2)))
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.2),
                                              turnCompleteAt: end.addingTimeInterval(0.2), now: end.addingTimeInterval(0.3)))
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.2),
                                              turnCompleteAt: end.addingTimeInterval(0.2), now: end.addingTimeInterval(0.4)))
        #expect(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.2),
                                             turnCompleteAt: end.addingTimeInterval(0.2), now: end.addingTimeInterval(0.7)))
    }

    @Test func finalWithoutTurnCompleteDoesNotFinish() {
        let end = Date(timeIntervalSince1970: 100)
        let final = end.addingTimeInterval(1.0)
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: final,
                                              turnCompleteAt: nil, now: end.addingTimeInterval(1.25)))
        #expect(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: final,
                                              turnCompleteAt: nil, now: end.addingTimeInterval(1.70)))
    }

    @Test func droppedAudioIsRememberedAcrossThreads() {
        let state = AudioIntegrityState()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in state.markDropped() }
        #expect(state.droppedChunks == 100)
    }

    @Test func oversizedArchiveIsRejectedWithoutOverwrite() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KoeBridgeLarge-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let blob = Data(repeating: 0x41, count: RecentTranscriptArchive.maximumFileBytes + 1)
        try blob.write(to: url)
        #expect(throws: RecentTranscriptArchive.ArchiveError.self) {
            _ = try RecentTranscriptArchive(fileURL: url)
        }
        #expect(try Data(contentsOf: url).count == blob.count)
    }

    @Test func temporaryAudioQueueDropsButNeverOverwritesOldest() async {
        let (stream, cont) = AsyncStream<Int>.makeStream(of: Int.self,
                                                       bufferingPolicy: .bufferingOldest(2))
        _ = cont.yield(1)
        _ = cont.yield(2)
        if case .dropped(let third) = cont.yield(3) { #expect(third == 3) }
        else { Issue.record("overflow must be explicit") }
        cont.finish()
        var collected: [Int] = []
        for await n in stream { collected.append(n) }
        #expect(collected == [1, 2])
    }
}
