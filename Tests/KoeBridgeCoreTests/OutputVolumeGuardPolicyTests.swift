import Foundation
import Testing
import KoeBridgeCore

struct OutputVolumeGuardPolicyTests {
    let left = OutputVolumeElement.scalar(1)
    let right = OutputVolumeElement.scalar(2)
    let main = OutputVolumeElement.scalar(0)

    func sample(_ volumes: [OutputVolumeElement: Float], uid: String = "A", device: UInt32 = 1,
                muted: Bool = false) -> OutputVolumeReading {
        OutputVolumeReading(uid: uid, device: device, muted: muted, volumes: volumes)
    }

    func active(_ reading: OutputVolumeReading) -> OutputVolumeGuardPolicy {
        var guardPolicy = OutputVolumeGuardPolicy(enabled: true)
        guardPolicy.begin(UUID()) { reading }
        return guardPolicy
    }

    @Test func matchesTheOriginalChannelAndVirtualMain() {
        let policy = active(sample([left: 0.2, right: 0.5, .virtualMain: 0.4]))
        #expect(policy.corrections(for: sample([left: 0.4, right: 0.3, .virtualMain: 0.45]),
            settable: [left, right, .virtualMain]) == [left: 0.2, .virtualMain: 0.4])
    }

    @Test func unseenHFPMainUsesStereoMaximum() {
        let policy = active(sample([left: 0.4, right: 0.5]))
        #expect(policy.corrections(for: sample([main: 0.6]), settable: [main]) == [main: 0.5])
    }

    @Test func differentUIDUsesMaximumEvenIfHALObjectIDIsReused() {
        let policy = active(sample([left: 0.2, right: 0.5]))
        #expect(policy.corrections(for: sample([left: 0.6], uid: "B"), settable: [left]) == [left: 0.5])
    }

    @Test func equalAndLowerReadingsStayUntouched() {
        let policy = active(sample([left: 0.4, right: 0.5]))
        #expect(policy.corrections(for: sample([left: 0.4, right: 0.01]), settable: [left, right]).isEmpty)
    }

    @Test func fixedVolumeHasNoWrite() {
        let policy = active(sample([main: 0.5]))
        #expect(policy.corrections(for: sample([main: 1]), settable: []).isEmpty)
    }

    @Test func muteAtEitherEndSuppressesWrites() {
        let initialMute = active(sample([main: 0.4], muted: true))
        #expect(initialMute.corrections(for: sample([main: 0.6]), settable: [main]).isEmpty)
        let policy = active(sample([main: 0.4]))
        #expect(policy.corrections(for: sample([main: 0.6], muted: true), settable: [main]).isEmpty)
        #expect(policy.corrections(for: sample([main: 0.6]), settable: [main]) == [main: 0.4])
    }

    @Test func offSkipsSnapshotAndListenerMonitoring() {
        var policy = OutputVolumeGuardPolicy(enabled: false)
        var reads = 0
        policy.begin(UUID()) { reads += 1; return sample([main: 0.1]) }
        #expect(reads == 0)
        #expect(!policy.isMonitoring)
        #expect(policy.corrections(for: sample([main: 0.9]), settable: [main]).isEmpty)
    }

    @Test func partialSnapshotUsesOnlyReadableScalars() {
        let policy = active(sample([left: 0.3, right: .nan]))
        #expect(policy.corrections(for: sample([right: 0.8, main: 0.7]), settable: [right, main])
            == [right: 0.3, main: 0.3])
    }

    @Test func missingOrEmptySnapshotIsInertUntilSessionEnds() {
        for reading in [nil, sample([:])] {
            var policy = OutputVolumeGuardPolicy(enabled: true)
            let warm = UUID(), take = UUID()
            var reads = 0
            policy.begin(warm) { reads += 1; return reading }
            policy.handover(from: warm, to: take)
            policy.begin(take) { reads += 1; return sample([main: 0.9]) }
            #expect(reads == 1)
            #expect(!policy.isMonitoring)
            #expect(policy.corrections(for: sample([main: 1]), settable: [main]).isEmpty)
        }
    }

    @Test func disconnectionSkipsAndReconnectUsesMaximum() {
        var policy = active(sample([left: 0.2, right: 0.5]))
        #expect(policy.corrections(for: nil, settable: [left]).isEmpty)
        #expect(policy.corrections(for: sample([left: 0.7], device: 2), settable: [left]) == [left: 0.5])
        policy.disconnected()
        #expect(policy.corrections(for: sample([left: 0.7]), settable: [left]) == [left: 0.5])
    }

    @Test func warmHandoverKeepsSnapshotAndStaleTeardownIsHarmless() {
        var policy = OutputVolumeGuardPolicy(enabled: true)
        let warm = UUID(), take = UUID()
        let loud = sample([main: 0.6])
        policy.begin(warm) { sample([left: 0.5]) }
        policy.handover(from: warm, to: take)
        policy.end(warm)
        policy.begin(take) { loud }
        #expect(policy.corrections(for: loud, settable: [main]) == [main: 0.5])
        policy.end(take)
        #expect(!policy.isMonitoring)
        #expect(policy.snapshot == nil)
        #expect(policy.corrections(for: loud, settable: [main]).isEmpty)
        policy.begin(UUID()) { loud }
        #expect(policy.corrections(for: loud, settable: [main]).isEmpty)
    }

    @Test func preferenceChangesRespectActiveOwnership() {
        var policy = OutputVolumeGuardPolicy(enabled: false)
        let take = UUID()
        var reads = 0
        let read = { reads += 1; return sample([main: 0.3]) }
        policy.setEnabled(true, read: read)
        #expect(!policy.isMonitoring && reads == 0)
        policy.begin(take, read: read)
        policy.setEnabled(false, read: read)
        #expect(!policy.isMonitoring && reads == 1)
        policy.setEnabled(true, read: read)
        #expect(policy.isMonitoring && reads == 2)
        policy.end(take)
        #expect(!policy.isMonitoring)
    }
}
