import Foundation

public enum OutputVolumeElement: Hashable, Sendable {
    case virtualMain
    /// Element zero is main. Positive elements are one-based output channels.
    case scalar(UInt32)
}

public struct OutputVolumeReading: Sendable {
    public let uid: String
    public let device: UInt32
    public let muted: Bool
    public let volumes: [OutputVolumeElement: Float]
    public let maximum: Float?

    public init(uid: String, device: UInt32, muted: Bool, volumes: [OutputVolumeElement: Float]) {
        self.uid = uid
        self.device = device
        self.muted = muted
        self.volumes = volumes.filter { (0...1).contains($0.value) }
        maximum = self.volumes.values.max()
    }
}

/// A failed HAL read (nil) can be retried on the next attempt. A completed
/// snapshot, including a device with no readable volume, lasts for the take.
public struct OutputVolumeGuardPolicy {
    public private(set) var enabled: Bool
    public private(set) var snapshot: OutputVolumeReading?
    private var owners = Set<UUID>()
    private var originalDisconnected = false
    public var isMonitoring: Bool { enabled && snapshot?.maximum != nil && snapshot?.muted == false }

    public init(enabled: Bool) { self.enabled = enabled }

    public mutating func setEnabled(_ value: Bool, read: () -> OutputVolumeReading?) {
        guard enabled != value else { return }
        enabled = value
        if enabled && !owners.isEmpty && snapshot == nil { snapshot = read() }
    }

    public mutating func begin(_ owner: UUID, read: () -> OutputVolumeReading?) {
        owners.insert(owner)
        if enabled && snapshot == nil { snapshot = read() }
    }

    public mutating func handover(from warm: UUID, to take: UUID) {
        guard owners.remove(warm) != nil else { return }
        owners.insert(take)
    }

    public mutating func end(_ owner: UUID) {
        owners.remove(owner)
        if owners.isEmpty {
            snapshot = nil
            originalDisconnected = false
        }
    }

    public mutating func disconnected() { originalDisconnected = true }

    public func corrections(for reading: OutputVolumeReading?,
                            settable: Set<OutputVolumeElement>) -> [OutputVolumeElement: Float] {
        guard isMonitoring, let snapshot, let maximum = snapshot.maximum,
              let reading, !reading.muted else { return [:] }
        let same = !originalDisconnected && reading.uid == snapshot.uid && reading.device == snapshot.device
        var result = [OutputVolumeElement: Float]()
        for (element, value) in reading.volumes where settable.contains(element) {
            let ceiling = same ? snapshot.volumes[element] ?? maximum : maximum
            if value > ceiling { result[element] = ceiling }
        }
        return result
    }
}
