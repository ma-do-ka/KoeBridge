#if os(macOS)
import Foundation
import KoeBridgeCore

/// One confirmed transcript's optional checks. It cannot alter another take,
/// read live preferences, deliver text, or promote an interim result to final.
@MainActor final class DictationReviewSession {
    struct Usage {
        var startedAt: Date?
        var audioBytes = 0
        var succeeded = false
        var tokens: [GeminiTokenSample] = []
    }

    let originalText: String
    private(set) var record: TranscriptReview?
    private(set) var usage = Usage()
    private let engine: RecognitionMode?
    private let options: TranscriptionOptions
    private let stoppedAt: Date?
    private let vocabulary: [String]
    private let style: TranscriptionStyle
    private let japaneseHint: Bool
    private let context: CapturedContext?
    private var audio: Data
    private var ended = false

    init(originalText: String, engine: RecognitionMode?, options: TranscriptionOptions,
         stoppedAt: Date?, audio: Data, vocabulary: [String], style: TranscriptionStyle,
         japaneseHint: Bool, context: CapturedContext? = nil) {
        self.context = context
        self.originalText = originalText
        self.engine = engine
        self.options = options
        self.stoppedAt = stoppedAt
        self.audio = audio
        self.vocabulary = vocabulary
        self.style = style
        self.japaneseHint = japaneseHint
    }

    func run(onAudioRecheck: () -> Void) async -> String {
        defer { audio = Data() }
        guard !ended, !Task.isCancelled,
              options.textContextCheckEnabled || options.audioRecheckEnabled else { return originalText }
        guard engine == .gemini else {
            record = TranscriptReview(status: .incomplete,
                                      note: "Appleの認識結果にはGemini用の追加チェックを実行していません。")
            return originalText
        }
        let local = options.textContextCheckEnabled ? TextContextChecking.check(originalText) : nil
        let locallyChecked = local?.text ?? originalText
        let textNote = local.map { "文章チェック：句読点を\($0.changes)箇所調整。" } ?? ""
        let shouldRecheck = options.audioRecheckEnabled &&
            (options.audioRecheckPolicy == .always || TextContextChecking.isSuspicious(originalText))
        guard shouldRecheck else {
            let audioNote = options.audioRecheckEnabled ? "音声照合：疑わしい区切りの検出条件に該当せず、再認識は実行していません。" : ""
            record = TranscriptReview(status: .checked, note: textNote + audioNote,
                                      originalText: locallyChecked == originalText ? nil : originalText)
            return locallyChecked
        }
        let budget = TranscriptReviewDeadline.available(stoppedAt: stoppedAt, now: Date())
        guard budget > 0, !audio.isEmpty, audio.count <= GeminiRecheckWire.maximumPCMBytes,
              let key = KeychainStore.load() else {
            record = TranscriptReview(status: .incomplete,
                                      note: "追加チェックの時間・音声サイズ・APIキーの条件を満たさないため、元の確定文を使用しました。")
            return originalText
        }
        if let context, context.prompt != nil {
            DiagnosticLog.record("context injected fields=\(context.fields)")
        }
        onAudioRecheck()
        usage.startedAt = Date()
        usage.audioBytes = audio.count
        do {
            let checked = try await GeminiAudioRechecker.recognize(
                pcm16LE: audio, vocabulary: vocabulary, style: style,
                japaneseHint: japaneseHint, apiKey: key, timeout: budget, context: context?.prompt)
            guard !ended, !Task.isCancelled else { return originalText }
            usage.succeeded = true
            if let counters = checked.usage {
                usage.tokens.append(GeminiTokenSample(at: Date(), usage: counters))
            }
            let comparison = TextContextChecking.compare(original: originalText, candidate: checked.text,
                                                         textCheckEnabled: options.textContextCheckEnabled)
            guard !comparison.requiresReview else {
                record = TranscriptReview(status: .needsReview,
                                          note: "元の確定文と再認識結果に文字の違いがあります。自動入力せず、両方を保存しました。",
                                          alternativeText: checked.text)
                return originalText
            }
            // Audio comparison does not enable the independent punctuation check.
            record = TranscriptReview(status: .checked,
                                      note: textNote + "音声を1回再認識し、語句の一致を確認しました。認識の正しさを保証するものではありません。",
                                      originalText: comparison.text == originalText ? nil : originalText)
            return comparison.text
        } catch {
            guard !ended, !Task.isCancelled else { return originalText }
            record = TranscriptReview(status: .incomplete,
                                      note: "追加チェックを完了できなかったため、元の確定文を使用しました。")
            DiagnosticLog.record("audio recheck incomplete; original confirmed result retained")
            return originalText
        }
    }

    /// The controller's overall deadline can retain only an already-confirmed
    /// original. Late network callbacks cannot replace this outcome.
    func expire() -> String {
        record = TranscriptReview(status: .incomplete,
                                  note: "追加チェックが時間内に終わらなかったため、元の確定文を使用しました。")
        cancel()
        return originalText
    }

    func cancel() {
        ended = true
        audio = Data()
    }
}
#endif
