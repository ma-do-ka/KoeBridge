#if os(macOS)
import Foundation
import KoeBridgeCore
import KoeBridgeEngines

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
    let normalizeJapaneseSpacing: Bool
    let snippets: [SnippetRule]

    func adoptFinalText(_ text: String) -> String {
        guard commandCandidate == nil, transformSelection == nil, !isFixLastInput else { return text }
        return JapaneseDictationSpacing.adopt(text, enabled: normalizeJapaneseSpacing, protectedTerms: snippets.map(\.trigger) + vocabulary)
    }

    var postProcessEnabled = false
    var postProcessMode: PostProcessingMode = .tidy
    var postProcessOriginal: String?
    var postProcessTask: Task<Void, Never>?
    var voiceCommandsEnabled = false
    var enabledVoiceCommands: Set<VoiceCommandID> = []
    var commandCandidate: VoiceCommandID?
    var isFixLastInput = false
    var transformSelection: String?
    var capturedContext: CapturedContext?
    var target: InsertionTarget?
    // Only reports received while this take is pending participate. A newly
    // started take does not inherit an earlier take's unconfirmed submission.
    private var allowsSettledDictation: Bool { commandCandidate == nil && transformSelection == nil && !isFixLastInput }
    var applicableSettledPredecessors: [TextInsertion.SettledUnconfirmedPredecessor] {
        allowsSettledDictation ? settledUnconfirmedInputTargets : []
    }

    func hasPriorBlock(for candidate: InsertionTarget) -> Bool {
        let adjudicated = TextInsertion.adjudicatePredecessors(
            for: candidate, takeStart: target,
            unverifiedPredecessors: unverifiedInputTargets,
            settledUnconfirmedPredecessors: applicableSettledPredecessors)
        if adjudicated.startBlocks || adjudicated.hasHardUnverified {
            return true
        }
        if !allowsSettledDictation,
           settledUnconfirmedInputTargets.contains(where: { candidate.sameElement(as: $0.target) }) {
            return true
        }
        return false
    }

    var unverifiedInputTargets: [InsertionTarget] = []
    var settledUnconfirmedInputTargets: [TextInsertion.SettledUnconfirmedPredecessor] = []
    var targetCaptureReason = "not_attempted"
    var mic: MicrophoneCapture?
    var continuation: AsyncStream<Data>.Continuation?
    var worker: Task<Void, Never>?
    var permissionTask: Task<Void, Never>?
    var recordingStart: ContinuousClock.Instant?
    var effectiveMode: RecognitionMode?
    var recordingDeadline: ContinuousClock.Instant? {
        let seconds = transformSelection != nil ? 30 : ((effectiveMode ?? preferred) == .gemini ? 480 : 50)
        return recordingStart?.advanced(by: .seconds(seconds))
    }
    var recordingTimeout: Task<Void, Never>?
    func scheduleRecordingTimeout(onDeadline: @escaping @MainActor () -> Void) {
        guard let deadline = recordingDeadline else { return }
        recordingTimeout?.cancel()
        recordingTimeout = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            if !Task.isCancelled { onDeadline() }
        }
    }
    var finalizationTimeout: Task<Void, Never>?
    var cloud: GeminiLiveConnection?
    var local: LocalTranscribing?
    var audioIntegrity = AudioIntegrityState()
    var retainAudioGeneration: UUID?
    var audioBackup = Data()
    var captureDrainedCleanly = false
    static let maximumRescueBytes = 50 * 32_000

    func transcribeLive(_ stream: AsyncStream<Data>, send: (Data) async throws -> Void,
                        finish: () async throws -> String, rescue: () async throws -> String) async throws -> String {
        var sendFailed = false
        for await chunk in stream {
            guard !finished, !Task.isCancelled else { throw CancellationError() }
            audioBackup.append(chunk)
            if !sendFailed {
                do { try await send(chunk) }
                catch {
                    try Task.checkCancellation()
                    if cloud?.assembler.exceededFinalBudget == true { throw GeminiLiveConnection.ConnectionError.finalBudgetExceeded }
                    sendFailed = true
                }
            }
            if sendFailed && audioBackup.count > Self.maximumRescueBytes { throw VoiceController.AppError.localRecoveryTooLong }
        }
        try Task.checkCancellation()
        guard !finished else { throw CancellationError() }
        guard audioIntegrity.droppedChunks == 0 else { throw VoiceController.AppError.audioDropped }
        if !sendFailed {
            do {
                let text = try await finish()
                successfulEngine = .gemini
                return text
            } catch { try Task.checkCancellation() }
        }
        if cloud?.assembler.exceededFinalBudget == true { throw GeminiLiveConnection.ConnectionError.finalBudgetExceeded }
        guard !finished, captureDrainedCleanly, stoppingAt != nil, audioIntegrity.droppedChunks == 0 else {
            throw VoiceController.AppError.audioDropped
        }
        DiagnosticLog.record("gemini transmit failed; attempting Apple on-device recovery")
        let text = try await rescue()
        successfulEngine = .local
        return text
    }
    var geminiAttempted = false
    var appleAttempted = false
    var fellBackToApple = false
    var geminiStartedAt: Date?
    var appleStartedAt: Date?
    var appleAudioBytes = 0
    var successfulEngine: RecognitionMode?
    var partialText = ""
    // Display state only; delivery and review continue to use whole-take results.
    var startupPreview = StartupPreviewPolicy()
    var previewPublicationTask: Task<Void, Never>?
    var previewFinalizedText = ""
    var previewVolatileText = ""
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
         vocabulary: [String], shouldPaste: Bool, options: TranscriptionOptions,
         normalizeJapaneseSpacing: Bool = true, snippets: [SnippetRule] = []) {
        self.normalizeJapaneseSpacing = normalizeJapaneseSpacing
        self.snippets = snippets
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
    func usageSamples(recognizedText: String?, cancelled: Bool) -> (engines: [EngineUsageSample], tokens: [GeminiTokenSample]) {
        let fallbackTime = startedAt ?? Date()
        func outcome(for mode: RecognitionMode) -> UsageOutcome {
            if recognizedText?.isEmpty == false && successfulEngine == mode { return .success }
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

    func resetPreviewPublication() {
        previewPublicationTask?.cancel()
        previewPublicationTask = nil
        startupPreview.reset()
    }

    func releaseResources() {
        resetPreviewPublication()
        postProcessTask?.cancel()
        permissionTask?.cancel()
        recordingTimeout?.cancel()
        finalizationTimeout?.cancel()
        worker?.cancel()
        reviewSession?.cancel()
        // A capture may still be preparing; late callbacks are gated by
        // 'finished', and the original startup task releases its own mic.
        mic?.stop(.cancelled) { _ in }
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
