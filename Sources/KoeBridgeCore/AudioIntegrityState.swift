import Foundation

/// Shared between an audio callback queue and the recording controller.
/// Any dropped PCM chunk makes the final transcript incomplete, so the
/// session must fail closed instead of silently pasting truncated text.
public final class AudioIntegrityState: @unchecked Sendable {
    private let lock = NSLock()
    private var dropped = 0

    public init() {}

    public func markDropped() {
        lock.lock()
        dropped += 1
        lock.unlock()
    }

    public var droppedChunks: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }
}
