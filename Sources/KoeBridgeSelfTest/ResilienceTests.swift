import Foundation

import KoeBridgeCore

struct ResilienceTests {
    func hotkeyF8OnlyTogglesOncePerPress() {
        var gate = HotKeyPressGate()
        gate.activate(11)
        let first = gate.receive(id: 11, pressed: true)
        check(first)
        for _ in 0..<20 {
            let repeatPress = gate.receive(id: 11, pressed: true)
            check(!repeatPress)
        }
        let release = gate.receive(id: 11, pressed: false)
        let second = gate.receive(id: 11, pressed: true)
        check(!release)
        check(second)
    }

    func hotkeySwitchRejectsStaleOldEvents() {
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
        check(a)
        check(!b && !c)
        check(d && !e && f && !g)
    }

    func finalBeforeReleaseCannotFinalizeEarly() {
        let end = Date(timeIntervalSince1970: 100)
        let final = end.addingTimeInterval(-5)
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: final,
                                              turnCompleteAt: nil, now: end))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: final,
                                              turnCompleteAt: nil, now: end.addingTimeInterval(0.8)))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: final,
                                              turnCompleteAt: nil, now: end.addingTimeInterval(1.25)))
    }

    func finalAndTurnCompleteInEitherOrder() {
        let end = Date(timeIntervalSince1970: 100)
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: nil,
                                              turnCompleteAt: end.addingTimeInterval(0.1), now: end.addingTimeInterval(2)))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.2),
                                              turnCompleteAt: end.addingTimeInterval(0.2), now: end.addingTimeInterval(0.3)))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.2),
                                              turnCompleteAt: end.addingTimeInterval(0.2), now: end.addingTimeInterval(0.4)))
        check(FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: end.addingTimeInterval(0.2),
                                             turnCompleteAt: end.addingTimeInterval(0.2), now: end.addingTimeInterval(0.7)))
    }

    func finalWithoutTurnCompleteDoesNotFinish() {
        let end = Date(timeIntervalSince1970: 100)
        let final = end.addingTimeInterval(1.0)
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: final,
                                              turnCompleteAt: nil, now: end.addingTimeInterval(1.25)))
        check(!FinalizationPolicy.canFinish(endedAt: end, lastFinalAt: final,
                                              turnCompleteAt: nil, now: end.addingTimeInterval(1.70)))
    }

    func droppedAudioIsRememberedAcrossThreads() {
        let state = AudioIntegrityState()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in state.markDropped() }
        check(state.droppedChunks == 100)
    }

    func oversizedArchiveIsRejectedWithoutOverwrite() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KoeBridgeLarge-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let blob = Data(repeating: 0x41, count: RecentTranscriptArchive.maximumFileBytes + 1)
        try blob.write(to: url)
        checkThrows(RecentTranscriptArchive.ArchiveError.self) {
            _ = try RecentTranscriptArchive(fileURL: url)
        }
        try check(try Data(contentsOf: url).count == blob.count)
    }

    func temporaryAudioQueueDropsButNeverOverwritesOldest() async {
        let (stream, cont) = AsyncStream<Int>.makeStream(of: Int.self,
                                                       bufferingPolicy: .bufferingOldest(2))
        _ = cont.yield(1)
        _ = cont.yield(2)
        if case .dropped(let third) = cont.yield(3) { check(third == 3) }
        else { recordFailure("overflow must be explicit") }
        cont.finish()
        var collected: [Int] = []
        for await n in stream { collected.append(n) }
        check(collected == [1, 2])
    }
}
