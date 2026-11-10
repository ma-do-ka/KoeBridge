#if os(macOS)
import Foundation
import KoeBridgeCore

enum RecognitionMode: String, CaseIterable, Identifiable {
    case gemini, local
    var id: String { rawValue }
    var label: String { self == .gemini ? "Gemini 3.5 Transcribe Live" : "Apple オンデバイス（無料）" }
    /// Human-readable picker label only: keep persisted engine identifiers and history names unchanged.
    var settingsLabel: String { self == .gemini ? "Gemini API（オンライン認識）" : "Apple（Mac内で認識・無料）" }
}

/// All mutable resources belong to one utterance, not to the UI singleton.
/// A completed recording can therefore finalize while another is capturing.
@MainActor final class DictationTake {
    let id = UUID()
    let requestedAt = Date()
    let preferred: RecognitionMode
    let style: TranscriptionStyle
    let japaneseHint: Bool
    let vocabulary: [String]
    let shouldPaste: Bool
    let options: TranscriptionOptions
    var appBundleIdentifier: String?
    var appProfileName: String?
    var usedMode: String
    var postProcessEnabled = false
    var postProcessMode: PostProcessingMode = .tidy
    var postProcessOriginal: String?
    var postProcessTask: Task<Void, Never>?
    var isFixLastInput = false
    var transformSelection: String?
    var capturedContext: CapturedContext?
    var target: InsertionTarget?
    var targetCaptureReason = "not_attempted"
    var mic: MicrophoneCapture?
    var continuation: AsyncStream<Data>.Continuation?
    var worker: Task<Void, Never>?
    var permissionTask: Task<Void, Never>?
    var recordingTimeout: Task<Void, Never>?
    var finalizationTimeout: Task<Void, Never>?
    var cloud: GeminiLiveConnection?
    var local: LocalTranscribing?
    var audioIntegrity = AudioIntegrityState()
    var audioBackup = Data()
    var geminiAttempted = false
    var appleAttempted = false
    var fellBackToApple = false
    var geminiStartedAt: Date?
    var appleStartedAt: Date?
    var appleAudioBytes = 0
    var successfulEngine: RecognitionMode?
    var partialText = ""
    var startedAt: Date?
    var stoppingAt: Date?
    var firstPreviewAt: Date?
    var finished = false
    var automaticDeliverySuppressed = false
    var reviewSession: DictationReviewSession?
    var historyRecordID: UUID?
    var inputDiagnostics: InputDiagnosticTrace?
    var acousticEvidence = AudioActivityMeter().evidence
    var acousticReviewRequired = false
    var resolvedAtUptime: TimeInterval?

    init(preferred: RecognitionMode, style: TranscriptionStyle, japaneseHint: Bool,
         vocabulary: [String], shouldPaste: Bool, options: TranscriptionOptions) {
        self.preferred = preferred
        self.style = style
        self.japaneseHint = japaneseHint
        self.vocabulary = vocabulary
        self.shouldPaste = shouldPaste
        self.options = options
        self.usedMode = preferred.label
    }

    var recoverableText: String {
        TranscriptRecovery.text(preferred: appleAttempted ? .local : .cloud,
                                cloud: cloud?.assembler.recoveryText,
                                local: local?.transcript, preview: partialText)
    }

    var review: TranscriptReview? {
        guard acousticReviewRequired else { return reviewSession?.record }
        if let record = reviewSession?.record, record.status == .needsReview { return record }
        return TranscriptReview(
            status: .needsReview,
            note: "録音音声から発話に十分な根拠が得られませんでした。誤認識の可能性があるため、自動入力せず履歴で確認できます。",
            originalText: reviewSession?.record?.originalText,
            alternativeText: reviewSession?.record?.alternativeText)
    }

    /// Snapshot before resources are released. No transcript, PCM, platform
    /// error details, or credentials are included in the persisted counters.
    func usageSamples(succeeded: Bool, cancelled: Bool) -> (engines: [EngineUsageSample], tokens: [GeminiTokenSample]) {
        let fallbackTime = startedAt ?? Date()
        func outcome(for mode: RecognitionMode) -> UsageOutcome {
            if succeeded && successfulEngine == mode { return .success }
            return cancelled ? .cancelled : .failure
        }
        var rows: [EngineUsageSample] = []
        if geminiAttempted {
            rows.append(EngineUsageSample(at: geminiStartedAt ?? fallbackTime, engine: .gemini,
                                          audioSeconds: Double(cloud?.sentAudioBytes ?? 0) / 32_000,
                                          outcome: outcome(for: .gemini)))
        }
        if appleAttempted {
            rows.append(EngineUsageSample(at: appleStartedAt ?? fallbackTime, engine: .apple,
                                          audioSeconds: Double(appleAudioBytes) / 32_000,
                                          outcome: outcome(for: .local), fallback: fellBackToApple))
        }
        if let usage = reviewSession?.usage, let startedAt = usage.startedAt {
            rows.append(EngineUsageSample(at: startedAt, engine: .gemini,
                                          audioSeconds: Double(usage.audioBytes) / 32_000,
                                          outcome: usage.succeeded ? .success : (cancelled ? .cancelled : .failure),
                                          purpose: .audioRecheck))
        }
        return (rows, (cloud?.tokenSamples ?? []) + (reviewSession?.usage.tokens ?? []))
    }

    func releaseResources() {
        postProcessTask?.cancel()
        permissionTask?.cancel()
        recordingTimeout?.cancel()
        finalizationTimeout?.cancel()
        worker?.cancel()
        reviewSession?.cancel()
        // A capture may still be preparing; late callbacks are gated by
        // 'finished', and the original startup task releases its own mic.
        mic?.stop { _ in }
        mic = nil
        continuation?.finish()
        continuation = nil
        cloud?.cancel()
        cloud = nil
        local?.cancel()
        local = nil
        audioBackup.removeAll(keepingCapacity: false)
    }
}
#endif
