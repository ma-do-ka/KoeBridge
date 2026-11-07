#if os(macOS)
import Foundation
@preconcurrency import AVFoundation
@preconcurrency import SoundAnalysis
import CoreMedia

/// Per-recording SoundAnalysis owner. No microphone, network, files or transcript access.
/// Analyzer calls are confined to workQueue; snapshots and completion ownership use lock.
/// Model initialization and inference never run on the UI or real-time audio thread.
public final class NativeSpeechDetector: NSObject, SNResultsObserving, @unchecked Sendable {
    private final class Packet: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
    private let workQueue = DispatchQueue(label: "dev.koebridge.speech-classifier", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 192)
    private let lock = NSLock()
    private var verification = SpeechVerification()
    private var closing = false
    private var completion: (@Sendable (SpeechVerification) -> Void)?
    private var analyzer: SNAudioStreamAnalyzer?
    private var labels: [String] = []
    private var position: AVAudioFramePosition = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!

    public override init() {
        super.init()
        workQueue.async { [self] in
            do {
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                labels = ["speech", "whispering"].filter { request.knownClassifications.contains($0) }
                guard labels.contains("speech") else { conclude(.failed); return }
                request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 16_000)
                request.overlapFactor = 0.5
                let prepared = SNAudioStreamAnalyzer(format: format)
                try prepared.add(request, withObserver: self)
                analyzer = prepared
                lock.lock()
                verification.started()
                let stopped = verification.state != .running
                lock.unlock()
                if stopped { prepared.removeAllRequests(); analyzer = nil }
            } catch { conclude(.failed) }
        }
    }

    public var evidence: SpeechVerification {
        lock.lock(); defer { lock.unlock() }
        return verification
    }

    /// Caller transfers an independently owned, sanitized 16kHz mono float buffer.
    /// Never mutate or recycle the buffer after this call.
    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let accepts = !closing && (verification.state == .pending || verification.state == .running)
        lock.unlock()
        guard accepts else { return }
        guard buffer.format.sampleRate == 16_000, buffer.format.channelCount == 1,
              buffer.format.commonFormat == .pcmFormatFloat32, buffer.frameLength > 0 else {
            conclude(.failed); return
        }
        guard slots.wait(timeout: .now()) == .success else { conclude(.failed); return }
        let packet = Packet(buffer)
        workQueue.async { [self, packet] in
            defer { slots.signal() }
            guard evidence.state == .running, let analyzer else { return }
            analyzer.analyze(packet.buffer, atAudioFramePosition: position)
            position += AVAudioFramePosition(packet.buffer.frameLength)
        }
    }

    /// End without delaying the microphone lifecycle lane. A missing/late classifier
    /// result is review-only, never promoted to speech by a timer or ASR text.
    public func finish(_ callback: @escaping @Sendable (SpeechVerification) -> Void) {
        lock.lock()
        if closing || (verification.state != .pending && verification.state != .running) {
            let snapshot = verification
            lock.unlock()
            callback(snapshot)
            return
        }
        closing = true
        completion = callback
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5) { [self] in
            conclude(.timedOut)
        }
        workQueue.async { [self] in
            guard evidence.state == .running, let analyzer else {
                conclude(.failed); return
            }
            // Tail padding is classifier-only: it is never sent to an ASR provider.
            // It lets a short word and the last incomplete model window be assessed.
            if position > 0, let padding = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000),
               let samples = padding.floatChannelData?[0] {
                padding.frameLength = 8_000
                samples.initialize(repeating: 0, count: 8_000)
                analyzer.analyze(padding, atAudioFramePosition: position)
                position += 8_000
            }
            analyzer.completeAnalysis()
        }
    }

    public func cancel() { conclude(.failed) }

    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { conclude(.failed); return }
        // Independent confidence scores are not ranked against noise classes.
        // The labels are verified against this OS's supported label list at setup.
        let confidence = labels.compactMap { result.classification(forIdentifier: $0)?.confidence }.max() ?? 0
        lock.lock()
        verification.observe(confidence: confidence, start: result.timeRange.start.seconds,
                             duration: result.timeRange.duration.seconds)
        lock.unlock()
    }
    public func request(_ request: SNRequest, didFailWithError error: Error) { conclude(.failed) }
    public func requestDidComplete(_ request: SNRequest) { conclude(.completed) }

    private func conclude(_ state: SpeechVerification.State) {
        lock.lock()
        switch state {
        case .completed: verification.complete()
        case .timedOut: verification.timeOut()
        default: verification.fail()
        }
        let snapshot = verification
        let done = completion
        completion = nil
        lock.unlock()
        done?(snapshot)
        workQueue.async { [self] in
            analyzer?.removeAllRequests()
            analyzer = nil
        }
    }
}
#endif
