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
    var usedMode: String
    var target: InsertionTarget?
    var targetCaptureReason = "not_attempted"
    var mic: MicrophoneCapture?
    var continuation: AsyncStream<Data>.Continuation?
    var worker: Task<Void, Never>?
    var permissionTask: Task<Void, Never>?
    var recordingTimeout: Task<Void, Never>?
    var finalizationTimeout: Task<Void, Never>?
    var cloud: GeminiLiveConnection?
    var local: AppleLocalTranscriber?
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
    var confirmedText: String?
    var review: TranscriptReview?
    var historyRecordID: UUID?
    var recheckStartedAt: Date?
    var recheckAudioBytes = 0
    var recheckSucceeded = false
    var recheckTokens: [GeminiTokenSample] = []

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
        let remote = cloud?.assembler.recoveryText ?? ""
        if !remote.isEmpty { return remote }
        let offline = local?.transcript ?? ""
        return offline.isEmpty ? partialText : offline
    }

    func releaseResources() {
        permissionTask?.cancel()
        recordingTimeout?.cancel()
        finalizationTimeout?.cancel()
        worker?.cancel()
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
