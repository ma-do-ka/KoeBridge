#if os(macOS)
import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import KoeBridgeCore

/// A separate source: normalization, classifier, admission, and energy evidence
/// never share state with the microphone. No screen frames are requested.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.koebridge.system-audio")
    private let lock = NSLock()
    private var cachedActivity = AudioActivityMeter().evidence
    private var admissionOffset: TimeInterval = 0
    private var firstSampleAt: TimeInterval?
    private var capture: SCStream? // lock protected
    private var closeRequested = false // lock protected; stop also fences pending startup
    private var onAudio: ((Data) -> Void)?
    private var onFailure: (() -> Void)?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                             channels: 1, interleaved: false)!
    private let detector = NativeSpeechDetector()
    private var admission = SpeechAdmissionBuffer()
    private var meter = AudioActivityMeter()
    private var stopped = false // queue only

    var activityEvidence: AudioActivityEvidence {
        lock.lock(); let value = cachedActivity; lock.unlock()
        return value.withSpeechVerification(detector.evidence)
    }
    var startedAtUptime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }; return firstSampleAt
    }
    var releasedFrom: TimeInterval {
        lock.lock(); defer { lock.unlock() }; return admissionOffset
    }
    func start(onAudio: @escaping (Data) -> Void, onFailure: @escaping () -> Void) async throws {
        try checkStartup()
        self.onAudio = onAudio; self.onFailure = onFailure
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try checkStartup()
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        // ScreenCaptureKit supports 48 kHz; normalize its actual format below.
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try install(stream)
        do {
            try await stream.startCapture()
            try checkStartup()
        } catch {
            // stop() may have returned while native startup was still pending.
            // The startup owner always closes its own late stream as well.
            try? await stream.stopCapture()
            clear(stream)
            throw error
        }
    }

    private func checkStartup() throws {
        try Task.checkCancellation()
        lock.lock(); let closed = closeRequested; lock.unlock()
        if closed { throw CancellationError() }
    }
    private func install(_ stream: SCStream) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closeRequested else { throw CancellationError() }
        capture = stream
    }
    private func clear(_ stream: SCStream) {
        lock.lock(); defer { lock.unlock() }
        if capture === stream { capture = nil }
    }
    private func closeStream() -> SCStream? {
        lock.lock(); defer { lock.unlock() }
        closeRequested = true
        let stream = capture; capture = nil
        return stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, !stopped else { return }
        do {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: asbd) else { throw CaptureError.invalidAudio }
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                throw CaptureError.invalidAudio
            }
            input.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                into: input.mutableAudioBufferList) == noErr else { throw CaptureError.invalidAudio }
            if inputFormat != format {
                inputFormat = format; converter = AVAudioConverter(from: format, to: outputFormat)
            }
            guard let converter,
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(ceil(Double(frames) * 16_000 / format.sampleRate)) + 32) else {
                throw CaptureError.invalidAudio
            }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            guard error == nil, status != .error else { throw CaptureError.invalidAudio }
            guard let samples = output.floatChannelData?[0], output.frameLength > 0 else { return }
            let count = Int(output.frameLength)
            meter.observe(UnsafeBufferPointer(start: samples, count: count))
            var pcm = Data(capacity: count * 2)
            for i in 0..<count {
                let value = samples[i].isFinite ? max(-1, min(1, samples[i])) : 0
                samples[i] = value
                let integer = Int16((value * 32767).rounded())
                pcm.append(UInt8(truncatingIfNeeded: integer))
                pcm.append(UInt8(truncatingIfNeeded: integer >> 8))
            }
            lock.lock()
            if firstSampleAt == nil { firstSampleAt = ProcessInfo.processInfo.systemUptime - Double(count) / 16_000 }
            cachedActivity = meter.evidence
            lock.unlock()
            detector.append(output)
            if let data = admission.append(pcm, proof: detector.evidence) { emit(data) }
            if admission.overflowed { throw CaptureError.invalidAudio }
        } catch { fail() }
    }
    private func emit(_ data: Data) {
        lock.lock(); admissionOffset = admission.openGeometry?.releasedFrom ?? 0; lock.unlock()
        onAudio?(data)
    }
    private func fail() {
        guard !stopped else { return }
        stopped = true
        lock.lock(); closeRequested = true; lock.unlock()
        onFailure?()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { queue.async { self.fail() } }

    func stop() async {
        if let stream = closeStream() { try? await stream.stopCapture() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                stopped = true
                detector.finish { [self] proof in
                    queue.async { [self] in
                        if let tail = admission.finish(proof: proof, isDigitalSilence: meter.evidence.classification == .nearSilence) {
                            emit(tail)
                        }
                        onAudio = nil; onFailure = nil; converter = nil
                        done.resume()
                    }
                }
            }
        }
    }
    enum CaptureError: Error { case noDisplay, invalidAudio }
}
#endif
