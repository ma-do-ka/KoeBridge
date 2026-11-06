#if os(macOS)
import Foundation
import AVFoundation

/// Captures audio once; converts to signed 16-bit, 16 kHz, mono, little-endian PCM.
/// Never perform WebSocket requests on the real-time microphone callback.
///
/// Concurrency contract:
/// - AVAudioEngine start/stop and engine ownership use lifecycleQueue.
/// - All queued PCM conversion, carry, converter and onAudio cleanup finishes
///   before lifecycleQueue can start the next capture (stop drains with sync).
/// - Dropped-buffer counts, delivered byte counts and peak are locked.
/// - The real-time audio tap only copies buffers and enqueues conversion.
/// Queue confinement is reviewed here; @unchecked Sendable is not a blanket
/// promise that arbitrary external mutations are safe.
final class MicrophoneCapture: @unchecked Sendable {
    // A single serial lane prevents overlapping AVAudioEngine start/stop
    // calls when F8 is pressed immediately after finishing a take.
    private static let lifecycleQueue = DispatchQueue(label: "dev.koebridge.microphone-lifecycle", qos: .userInteractive)
    private let processingQueue = DispatchQueue(label: "dev.koebridge.pcm-conversion", qos: .userInitiated)
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var engine: AVAudioEngine?
    private var carry = Data()
    private var onAudio: ((Data) -> Void)?
    private let chunkBytes = 1_600 // 50 ms at 16kHz 16-bit mono: lower first-result latency
    private var alive = false
    private let workSlots = DispatchSemaphore(value: 16)
    private let healthLock = NSLock()
    private var droppedBuffers = 0
    private var conversionErrors = 0
    private var deliveredPCMBytes = 0
    private var peakAmplitude: Float = 0

    struct StartTimings {
        let microphonePreparation: TimeInterval
        let engineStart: TimeInterval
        let total: TimeInterval
    }
    private(set) var startTimings: StartTimings?

    var sessionPeakAmplitude: Float {
        healthLock.lock()
        defer { healthLock.unlock() }
        return peakAmplitude
    }

    var totalPCMBytes: Int {
        healthLock.lock()
        defer { healthLock.unlock() }
        return deliveredPCMBytes
    }

    private func noteAudioDelivered(_ bytes: Int) {
        healthLock.lock()
        deliveredPCMBytes += bytes
        healthLock.unlock()
    }
    private var configurationObserver: NSObjectProtocol?

    var lostBufferCount: Int {
        healthLock.lock()
        defer { healthLock.unlock() }
        return droppedBuffers + conversionErrors
    }

    private func noteBufferLoss(conversionError: Bool = false) {
        healthLock.lock()
        if conversionError { conversionErrors += 1 } else { droppedBuffers += 1 }
        healthLock.unlock()
    }

    /// A first AVAudioEngine.start() can block for seconds when an external
    /// audio device wakes. Never run it on AppKit's main thread.
    func start(onAudio: @escaping (Data) -> Void,
               onDeviceChanged: @escaping () -> Void = {}) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.lifecycleQueue.async { [self] in
                do {
                    try startBlocking(onAudio: onAudio, onDeviceChanged: onDeviceChanged)
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startBlocking(onAudio: @escaping (Data) -> Void,
                               onDeviceChanged: @escaping () -> Void) throws {
        guard engine == nil else { return }
        let beganAt = Date()
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let input = node.outputFormat(forBus: 0)
        guard input.sampleRate > 0,
              let converter = AVAudioConverter(from: input, to: output) else {
            throw CaptureError.noInput
        }
        processingQueue.sync {
            self.onAudio = onAudio
            self.converter = converter
            self.alive = true
        }
        self.engine = engine
        node.installTap(onBus: 0, bufferSize: 1024, format: input) { [weak self] buffer, _ in
            guard let self else { return }
            // Never let a blocked conversion queue accumulate unbounded microphone
            // buffers. The real-time callback must never wait for a free slot.
            guard self.workSlots.wait(timeout: .now()) == .success else {
                self.noteBufferLoss()
                return
            }
            // AVAudioEngine recycles tap buffers. Copy before returning from callback.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                self.noteBufferLoss()
                self.workSlots.signal()
                return
            }
            copy.frameLength = buffer.frameLength
            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for i in 0..<min(src.count, dst.count) {
                guard let from = src[i].mData, let to = dst[i].mData else { continue }
                memcpy(to, from, Int(src[i].mDataByteSize))
                dst[i].mDataByteSize = src[i].mDataByteSize
            }
            self.processingQueue.async { [weak self, slots = self.workSlots] in
                defer { slots.signal() }
                self?.convert(copy)
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { _ in onDeviceChanged() }
        do {
            engine.prepare()
            let startAt = Date()
            try engine.start()
            let completedAt = Date()
            startTimings = StartTimings(
                microphonePreparation: startAt.timeIntervalSince(beganAt),
                engineStart: completedAt.timeIntervalSince(startAt),
                total: completedAt.timeIntervalSince(beganAt))
        } catch {
            // start() may fail after the tap has queued buffers. Use the same
            // drain barrier as normal stop before clearing converter/callback
            // ownership. Failed startup must not emit an extra partial chunk.
            stopBlocking(flushPendingAudio: false)
            throw error
        }
    }

    private func convert(_ incoming: AVAudioPCMBuffer) {
        guard alive, let converter else { return }
        let capacity = AVAudioFrameCount(ceil(Double(incoming.frameLength) * 16_000.0 / incoming.format.sampleRate)) + 128
        guard let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            noteBufferLoss(conversionError: true)
            return
        }
        var didProvide = false
        var conversionError: NSError?
        _ = converter.convert(to: target, error: &conversionError) { _, status in
            if didProvide { status.pointee = .noDataNow; return nil }
            didProvide = true
            status.pointee = .haveData
            return incoming
        }
        guard conversionError == nil else {
            noteBufferLoss(conversionError: true)
            return
        }
        guard target.frameLength > 0 else { return }
        guard let floats = target.floatChannelData?.pointee else {
            noteBufferLoss(conversionError: true)
            return
        }
        let n = Int(target.frameLength)
        var pcm = Data(count: n * 2)
        var peak: Float = 0
        pcm.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<n {
                peak = max(peak, abs(floats[i]))
                let clipped = max(-1.0, min(1.0, floats[i]))
                let value = Int16((clipped * 32767).rounded()).littleEndian
                base[i * 2] = UInt8(truncatingIfNeeded: value)
                base[i * 2 + 1] = UInt8(truncatingIfNeeded: Int(value) >> 8)
            }
        }
        healthLock.lock()
        peakAmplitude = max(peakAmplitude, peak)
        healthLock.unlock()
        carry.append(pcm)
        while carry.count >= chunkBytes {
            let data = carry.subdata(in: 0..<chunkBytes)
            carry.removeSubrange(0..<chunkBytes)
            noteAudioDelivered(data.count)
            onAudio?(data)
        }
    }

    /// Stop the input tap, but do not wait for queued conversion work on the
    /// UI thread. The callback runs only after all trailing PCM was forwarded.
    func stop(completion: @escaping (Int) -> Void) {
        // Never block the main thread / F8 handling on an external microphone
        // or an AVAudioEngine teardown. Start and stop use the same queue.
        Self.lifecycleQueue.async { [self] in
            stopBlocking(completion: completion)
        }
    }

    private func stopBlocking(flushPendingAudio: Bool = true, completion: ((Int) -> Void)? = nil) {
        guard let engine else { completion?(lostBufferCount); return }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        // Drain *all* queued conversion work before releasing lifecycleQueue.
        // The old async cleanup could run after a new startBlocking(), erase
        // the new converter/callback, and silently stop audio on rapid toggles.
        // This is a background serial lane; it does not block AppKit/UI.
        processingQueue.sync { [self] in
            alive = false
            if flushPendingAudio && !carry.isEmpty {
                noteAudioDelivered(carry.count)
                onAudio?(carry)
            }
            carry.removeAll(keepingCapacity: true)
            onAudio = nil
            converter = nil
            completion?(lostBufferCount)
        }
    }

    enum CaptureError: Error, LocalizedError {
        case noInput
        var errorDescription: String? { "有効なマイク入力がありません。Mac miniには外付けマイクが必要です" }
    }
}
#endif
