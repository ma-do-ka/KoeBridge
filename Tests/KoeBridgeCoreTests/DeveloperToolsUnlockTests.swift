import Foundation
import Testing
@testable import KoeBridgeCore

struct DeveloperToolsUnlockTests {
    private let konami = DeveloperToolsUnlockSequence.keyCodes

    @Test func fullSequenceCompletesOnlyOnTheLastKey() {
        var sequence = DeveloperToolsUnlockSequence()
        for (offset, keyCode) in konami.enumerated() {
            let completed = sequence.advance(keyCode: keyCode)
            #expect(completed == (offset == konami.count - 1))
        }
        #expect(sequence.progress == 0)
    }

    @Test func wrongKeyResetsThePartialSequence() {
        var sequence = DeveloperToolsUnlockSequence()
        for keyCode in konami.prefix(4) {
            let completed = sequence.advance(keyCode: keyCode)
            #expect(!completed)
        }
        let interrupted = sequence.advance(keyCode: 49) // space
        #expect(!interrupted)
        #expect(sequence.progress == 0)
        // The full command still works after the reset.
        for (offset, keyCode) in konami.enumerated() {
            let completed = sequence.advance(keyCode: keyCode)
            #expect(completed == (offset == konami.count - 1))
        }
    }

    @Test func nonMatchingKeyThatStartsTheCommandBeginsAFreshAttempt() {
        var sequence = DeveloperToolsUnlockSequence()
        for keyCode in konami.prefix(3) {
            let completed = sequence.advance(keyCode: keyCode)
            #expect(!completed)
        }
        // A third up-arrow breaks ↑↑↓↓ but is itself the command's first key.
        let restarted = sequence.advance(keyCode: konami[0])
        #expect(!restarted)
        #expect(sequence.progress == 1)
        for (offset, keyCode) in konami.dropFirst().enumerated() {
            let completed = sequence.advance(keyCode: keyCode)
            #expect(completed == (offset == konami.count - 2))
        }
    }

    @Test func partialSequenceNeverUnlocks() {
        var sequence = DeveloperToolsUnlockSequence()
        for keyCode in konami.dropLast() {
            let completed = sequence.advance(keyCode: keyCode)
            #expect(!completed)
        }
        #expect(sequence.progress == konami.count - 1)
    }

    @Test func repeatedCommandReTogglesWithoutStaleProgress() {
        var sequence = DeveloperToolsUnlockSequence()
        for _ in 0..<2 {
            for (offset, keyCode) in konami.enumerated() {
                let completed = sequence.advance(keyCode: keyCode)
                #expect(completed == (offset == konami.count - 1))
            }
            #expect(sequence.progress == 0)
        }
    }

    @Test func unlockStateIsLockedByDefaultAndPersistsToggles() throws {
        let suite = "KoeBridge.DeveloperTools." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!DeveloperToolsUnlockStore.isUnlocked(defaults: defaults))
        let unlocked = DeveloperToolsUnlockStore.toggle(defaults: defaults)
        #expect(unlocked)
        #expect(DeveloperToolsUnlockStore.isUnlocked(defaults: defaults))
        let relocked = DeveloperToolsUnlockStore.toggle(defaults: defaults)
        #expect(!relocked)
        #expect(!DeveloperToolsUnlockStore.isUnlocked(defaults: defaults))
        DeveloperToolsUnlockStore.setUnlocked(true, defaults: defaults)
        #expect(defaults.bool(forKey: DeveloperToolsUnlockStore.defaultsKey))
    }

    @Test func searchIndexHidesBenchUntilUnlocked() {
        for query in ["ベンチ録音", "ベンチマーク", "録音"] {
            #expect(SettingsSearchCatalog.find(query).allSatisfy { $0.section != .bench })
            #expect(SettingsSearchCatalog.find(query, developerToolsUnlocked: true)
                .contains { $0.section == .bench && $0.id == "bench-recording" })
        }
    }

    @Test func benchPageIsUnavailableWhileLocked() {
        #expect(!SettingsSection.bench.isAvailable(developerToolsUnlocked: false))
        #expect(SettingsSection.bench.isAvailable(developerToolsUnlocked: true))
        #expect(SettingsSection.general.isAvailable(developerToolsUnlocked: false))
        #expect(SettingsSection.about.isAvailable(developerToolsUnlocked: false))
    }
}
