#if os(macOS)
import Foundation
import AVFoundation
import KoeBridgeCore

/// Engine lifecycle, conversion and inference have separate serial lanes.
/// The real-time tap only copies; health counters use healthLock.
final class MicrophoneCapture: @unchecked Sendable {
    private static let lifecycleQueue = DispatchQueue(label: "dev.koebridge.microphone-lifecycle", qos: .userInteractive)
    private let processingQueue = DispatchQueue(label: "dev.koebridge.pcm-conversion", qos: .userInitiated)
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var engine: AVAudioEngine?
    private var carry = Data()
    private var onAudio: ((Data) -> Void)?
    private let chunkBytes = 1_600
    private var alive = false
    private let workSlots = DispatchSemaphore(value: 16)
    private let healthLock = NSLock()
    private var droppedBuffers = 0
    private var conversionErrors = 0
    private var capturedPCMBytes = 0
    private var peakAmplitude: Float = 0
    private var activityMeter = AudioActivityMeter()
    private var cachedActivity = AudioActivityMeter().evidence
    private var admission = SpeechAdmissionBuffer() // processingQueue only
    private let speechDetector = NativeSpeechDetector()
    private let diagnosticID = UUID()
    @MainActor private var speechTrace: InputDiagnosticTrace?

    struct StartTimings {
        let microphonePreparation: TimeInterval
        let engineStart: TimeInterval
        let total: TimeInterval
    }
    private(set) var startTimings: StartTimings?
    var sessionPeakAmplitude: Float {
        healthLock.lock(); defer { healthLock.unlock() }
        return peakAmplitude
    }
    var activityEvidence: AudioActivityEvidence {
        healthLock.lock()
        let energy = cachedActivity
        healthLock.unlock()
        return energy.withSpeechVerification(speechDetector.evidence)
    }
    /// Captured duration is independent of the leading-silence admission buffer.
    /// Provider usage continues to count only bytes actually sent by that provider.
    var totalPCMBytes: Int {
        healthLock.lock(); defer { healthLock.unlock() }
        return capturedPCMBytes
    }
    private var configurationObserver: NSObjectProtocol?
    var lostBufferCount: Int {
        healthLock.lock(); defer { healthLock.unlock() }
        return droppedBuffers + conversionErrors
    }
    private func noteBufferLoss(conversionError: Bool = false) {
        healthLock.lock()
        if conversionError { conversionErrors += 1 } else { droppedBuffers += 1 }
        healthLock.unlock()
    }

    @MainActor
    func start(onAudio: @escaping (Data) -> Void,
               onDeviceChanged: @escaping () -> Void = {}) async throws {
        speechTrace = DiagnosticLog.inputTrace(takeID: diagnosticID)
        if speechTrace?.isCollecting == true {
            DiagnosticLog.record("speech_classifier_started capture=\(diagnosticID.uuidString) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.lifecycleQueue.async { [self] in
                do {
                    try startBlocking(onAudio: onAudio, onDeviceChanged: onDeviceChanged)
                    continuation.resume(returning: ())
                } catch { continuation.resume(throwing: error) }
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
        guard input.sampleRate > 0, let converter = AVAudioConverter(from: input, to: output) else {
            speechDetector.cancel(); throw CaptureError.noInput
        }
        processingQueue.sync {
            self.onAudio = onAudio; self.converter = converter; self.alive = true
        }
        self.engine = engine
        node.installTap(onBus: 0, bufferSize: 1024, format: input) { [weak self] buffer, _ in
            guard let self else { return }
            guard self.workSlots.wait(timeout: .now()) == .success else { self.noteBufferLoss(); return }
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                self.noteBufferLoss(); self.workSlots.signal(); return
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
            startTimings = StartTimings(microphonePreparation: startAt.timeIntervalSince(beganAt),
                                       engineStart: completedAt.timeIntervalSince(startAt),
                                       total: completedAt.timeIntervalSince(beganAt))
        } catch {
            stopBlocking(flushPendingAudio: false)
            throw error
        }
    }

    private func convert(_ incoming: AVAudioPCMBuffer) {
        guard alive, let converter else { return }
        let capacity = AVAudioFrameCount(ceil(Double(incoming.frameLength) * 16_000.0 / incoming.format.sampleRate)) + 128
        guard let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            noteBufferLoss(conversionError: true); return
        }
        var didProvide = false
        var conversionError: NSError?
        _ = converter.convert(to: target, error: &conversionError) { _, status in
            if didProvide { status.pointee = .noDataNow; return nil }
            didProvide = true; status.pointee = .haveData
            return incoming
        }
        guard conversionError == nil else { noteBufferLoss(conversionError: true); return }
        guard target.frameLength > 0 else { return }
        guard let floats = target.floatChannelData?.pointee else { noteBufferLoss(conversionError: true); return }
        let n = Int(target.frameLength)
        activityMeter.observe(UnsafeBufferPointer(start: floats, count: n))
        let energy = activityMeter.evidence
        var pcm = Data(count: n * 2)
        var peak: Float = 0
        pcm.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<n {
                let finite = floats[i].isFinite ? floats[i] : 0
                peak = max(peak, abs(finite))
                let clipped = max(-1.0, min(1.0, finite))
                floats[i] = clipped
                let value = Int16((clipped * 32767).rounded()).littleEndian
                base[i * 2] = UInt8(truncatingIfNeeded: value)
                base[i * 2 + 1] = UInt8(truncatingIfNeeded: Int(value) >> 8)
            }
        }
        healthLock.lock()
        peakAmplitude = max(peakAmplitude, peak)
        cachedActivity = energy
        capturedPCMBytes += pcm.count
        healthLock.unlock()
        speechDetector.append(target) // target is independently owned, never recycled
        carry.append(pcm)
        while carry.count >= chunkBytes {
            let data = carry.subdata(in: 0..<chunkBytes)
            carry.removeSubrange(0..<chunkBytes)
            admit(data)
        }
    }

    private func admit(_ pcm: Data) {
        let wasOverflowed = admission.overflowed
        if let admitted = admission.append(pcm, proof: speechDetector.evidence) { emit(admitted) }
        if admission.overflowed && !wasOverflowed { noteBufferLoss(conversionError: true) }
    }
    private func emit(_ pcm: Data) {
        // A long review-only take is replayed in bounded packets, not thousands
        // of 50ms synchronous yields that could overflow the 480-item ASR queue.
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 64_000, pcm.count)
            onAudio?(pcm.subdata(in: offset..<end))
            offset = end
        }
    }

    func stop(completion: @escaping (Int) -> Void) {
        Self.lifecycleQueue.async { [self] in stopBlocking(completion: completion) }
    }
    private func stopBlocking(flushPendingAudio: Bool = true, completion: ((Int) -> Void)? = nil) {
        guard let engine else { completion?(lostBufferCount); return }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.stop(); engine.inputNode.removeTap(onBus: 0); self.engine = nil
        processingQueue.sync { [self] in
            alive = false
            if flushPendingAudio && !carry.isEmpty { admit(carry) }
            carry.removeAll(keepingCapacity: true)
            converter = nil
            if !flushPendingAudio { admission = SpeechAdmissionBuffer(); onAudio = nil }
        }
        guard flushPendingAudio else {
            speechDetector.cancel(); completion?(lostBufferCount); return
        }
        // Do not hold lifecycleQueue while a stopped take completes inference.
        speechDetector.finish { [self] speech in
            processingQueue.async { [self] in
                let digitalSilence = activityEvidence.classification == .nearSilence
                if let remainder = admission.finish(proof: speech, isDigitalSilence: digitalSilence) { emit(remainder) }
                onAudio = nil
                Task { @MainActor [self] in
                    if let trace = speechTrace, trace.isCollecting {
                        let score = Int((speech.maximumConfidence * 1_000).rounded())
                        DiagnosticLog.record("speech_classifier capture=\(diagnosticID.uuidString) state=\(speech.state.rawValue) windows=\(speech.windows) positives=\(speech.positiveWindows) max_permille=\(score) allowed=\(speech.allowsTranscript)")
                        trace.finish()
                    }
                }
                completion?(lostBufferCount)
            }
        }
    }

    enum CaptureError: Error, LocalizedError {
        case noInput
        var errorDescription: String? { "有効なマイク入力がありません。Mac miniには外付けマイクが必要です" }
    }
}
#endif
