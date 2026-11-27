#if os(macOS)
import AppKit
import AVFoundation
import Speech
import Combine
import SwiftUI
import KoeBridgeCore
import KoeBridgeEngines

/// Memoizes derived display values without publishing from a SwiftUI body.
@MainActor final class DisplayCache<Key: Equatable, Value> {
    private var entry: (Key, Value)?

    func value(for key: Key, compute: () -> Value) -> Value {
        if let entry, entry.0 == key { return entry.1 }
        let result = compute()
        entry = (key, result)
        return result
    }
}

@MainActor final class VoiceController: ObservableObject {
    static let shared = VoiceController()
    typealias Phase = VoiceSessionPhase
    @Published private(set) var phase: Phase = .idle
    @Published var status = "待機中"
    private(set) var previewRevision: UInt64 = 0
    @Published var previewFinalizedText = "" { didSet { previewRevision &+= 1 } }
    @Published var previewVolatileText = "" { didSet { previewRevision &+= 1 } }
    @Published var previewText = "" {
        didSet {
            previewRevision &+= 1
            if previewText.isEmpty { previewFinalizedText = ""; previewVolatileText = "" }
        }
    }
    @Published var progressivePreviewEnabled = UserDefaults.standard.object(forKey: "progressivePreviewEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(progressivePreviewEnabled, forKey: "progressivePreviewEnabled") }
    }
    @Published var isRecording = false
    @Published private(set) var benchRecordingActive = false
    private var cancelBenchRecording: (@MainActor () -> Void)?
    @Published private(set) var microphoneNotice: MicrophoneNotice?
    @Published private(set) var overlayFeedback: OverlayFeedback = .hidden
    @Published private(set) var lastStartupSeconds: TimeInterval?
    @Published private(set) var lastStopToInputSeconds: TimeInterval?
    @Published var requestedMode: RecognitionMode {
        didSet {
            UserDefaults.standard.set(requestedMode.rawValue, forKey: "engine")
            switch requestedMode {
            case .gemini:
                scheduleWarmGemini()
            case .amivoice, .local:
                warmScheduleTask?.cancel()
                prewarmer.shutdown()
            }
        }
    }
    @Published var amiVoiceEngine: AmiVoiceEngine {
        didSet {
            UserDefaults.standard.set(amiVoiceEngine.rawValue, forKey: "amiVoiceEngine")
        }
    }
    @Published var outputVolumeGuardEnabled: Bool {
        didSet {
            volumeGuard.changePreference(outputVolumeGuardEnabled,
                evidence: outputVolumeGuardEnabled ? DiagnosticLog.microphoneEvidenceWriter() : nil)
            UserDefaults.standard.set(outputVolumeGuardEnabled, forKey: OutputVolumeGuard.preferenceKey)
        }
    }
    @Published var bluetoothMicWarmEnabled: Bool {
        didSet {
            UserDefaults.standard.set(bluetoothMicWarmEnabled, forKey: "bluetoothMicWarm")
            if bluetoothMicWarmEnabled { resumeMicrophoneWarm(reason: "enabled") }
            else { microphoneWarmKeeper.suspend(reason: "disabled") }
        }
    }
    @Published var geminiPrewarmEnabled: Bool {
        didSet {
            UserDefaults.standard.set(geminiPrewarmEnabled, forKey: "geminiPrewarm")
            if geminiPrewarmEnabled { scheduleWarmGemini() }
            else {
                warmScheduleTask?.cancel()
                prewarmer.shutdown()
            }
        }
    }
    @Published var transcriptionStyle: TranscriptionStyle {
        didSet {
            UserDefaults.standard.set(transcriptionStyle.rawValue, forKey: "transcriptionStyle")
            // Continue maintaining the legacy setting for a safe downgrade.
            UserDefaults.standard.set(transcriptionStyle == .readable, forKey: "smart")
            scheduleWarmGemini()
        }
    }
    @Published var normalizeJapaneseSpacing: Bool {
        didSet { UserDefaults.standard.set(normalizeJapaneseSpacing, forKey: "normalizeJapaneseSpacing") }
    }

    @Published var japaneseHint: Bool {
        didSet {
            UserDefaults.standard.set(japaneseHint, forKey: "japanese")
            scheduleWarmGemini()
        }
    }
    @Published var automaticPaste: Bool {
        didSet { UserDefaults.standard.set(automaticPaste, forKey: "autoPaste") }
    }
    @Published var voiceCommandsEnabled = UserDefaults.standard.bool(forKey: "voiceCommandsEnabled") {
        didSet { UserDefaults.standard.set(voiceCommandsEnabled, forKey: "voiceCommandsEnabled") }
    }
    @Published var enabledVoiceCommands: Set<VoiceCommandID> = Set(VoiceCommandID.allCases.filter {
        UserDefaults.standard.object(forKey: "voiceCommand." + $0.rawValue) as? Bool ?? ($0 == .cancelTake)
    }) {
        didSet {
            for command in VoiceCommandID.allCases {
                UserDefaults.standard.set(enabledVoiceCommands.contains(command), forKey: "voiceCommand." + command.rawValue)
            }
        }
    }

    @Published var postProcessEnabled = UserDefaults.standard.bool(forKey: "postProcessEnabled") {
        didSet { UserDefaults.standard.set(postProcessEnabled, forKey: "postProcessEnabled") }
    }
    @Published var postProcessMode = PostProcessingMode(rawValue: UserDefaults.standard.string(forKey: "postProcessMode") ?? "") ?? .tidy {
        didSet { UserDefaults.standard.set(postProcessMode.rawValue, forKey: "postProcessMode") }
    }
    @Published var recheckContextEnabled = UserDefaults.standard.object(forKey: "recheckContextEnabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(recheckContextEnabled, forKey: "recheckContextEnabled") }
    }
    @Published var contextAppEnabled = UserDefaults.standard.object(forKey: "contextAppEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(contextAppEnabled, forKey: "contextAppEnabled") }
    }
    @Published var contextSelectionEnabled = UserDefaults.standard.object(forKey: "contextSelectionEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(contextSelectionEnabled, forKey: "contextSelectionEnabled") }
    }
    @Published var contextSurroundingEnabled = UserDefaults.standard.object(forKey: "contextSurroundingEnabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(contextSurroundingEnabled, forKey: "contextSurroundingEnabled") }
    }
    @Published private(set) var transformShortcutProblem = ""
    @Published private(set) var transformShortcut = RecordingShortcut(rawValue: UserDefaults.standard.string(forKey: "transformShortcut") ?? "")
    var onTransformShortcutChange: ((RecordingShortcut?) -> Bool)?
    func selectTransformShortcut(_ choice: RecordingShortcut?) {
        guard onTransformShortcutChange?(choice) == true else {
            transformShortcutProblem = "変換ショートカットを登録できません（キーの競合を確認してください）"
            status = transformShortcutProblem
            return
        }
        transformShortcutProblem = ""
        transformShortcut = choice
        UserDefaults.standard.set(choice?.rawValue, forKey: "transformShortcut")
    }

    @Published private(set) var translateShortcutProblem = ""
    @Published private(set) var translateShortcut = RecordingShortcut(rawValue: UserDefaults.standard.string(forKey: "translateShortcut") ?? "")
    var onTranslateShortcutChange: ((RecordingShortcut?) -> Bool)?
    func selectTranslateShortcut(_ choice: RecordingShortcut?) {
        guard onTranslateShortcutChange?(choice) == true else {
            translateShortcutProblem = "翻訳ショートカットを登録できません（キーの競合を確認してください）"
            status = translateShortcutProblem
            return
        }
        translateShortcutProblem = ""
        translateShortcut = choice
        UserDefaults.standard.set(choice?.rawValue, forKey: "translateShortcut")
    }
    @Published var translationDirection = TranslationDirection(rawValue: UserDefaults.standard.string(forKey: "translationDirection") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(translationDirection.rawValue, forKey: "translationDirection") }
    }
    @Published var transformMode = TransformMode(rawValue: UserDefaults.standard.string(forKey: "transformMode") ?? "") ?? .spoken {
        didSet {
            UserDefaults.standard.set(transformMode.rawValue, forKey: "transformMode")
            onInputConfigurationChange?()
        }
    }
    @Published var selectedTransformPresetID = UserDefaults.standard.string(forKey: "selectedTransformPresetID").flatMap(UUID.init(uuidString:)) {
        didSet { UserDefaults.standard.set(selectedTransformPresetID?.uuidString, forKey: "selectedTransformPresetID") }
    }
    @Published private(set) var transformPresetsStore = SettingsArray<TransformPreset>("transformPresets")
    var transformPresets: [TransformPreset] {
        get { transformPresetsStore.rows }
        set { transformPresetsStore.save(newValue) }
    }
    func resetTransformPresets() { transformPresetsStore.resetCorruptValue() }
    @Published private(set) var lastTextOperationOutput: String?
    @Published private(set) var textOperationRunning = false
    private var textOperationID: UUID?
    private var textOperationTask: Task<Void, Never>?
    private var textOperationDeadlineTask: Task<Void, Never>?
    private var textOperationStep = 1
    private var textOperationUnverifiedTargets: [InsertionTarget] = []

    func copyTextOperationOutput() {
        guard let output = lastTextOperationOutput else { return }
        status = TextInsertion.copy(output) ? "途中までの変換結果をコピーしました" : "変換結果をコピーできませんでした"
    }

    private func cancelTextOperation() {
        textOperationDeadlineTask?.cancel()
        textOperationDeadlineTask = nil
        textOperationTask?.cancel()
        textOperationTask = nil
        if let id = textOperationID, overlayOwner == id { hideOverlay() }
        textOperationID = nil
        textOperationRunning = false
        textOperationUnverifiedTargets.removeAll()
        lastTextOperationOutput = nil
    }

    func translateSelection() {
        startSelectionOperation(translating: true)
    }

    private func startSelectionOperation(translating: Bool) {
        cancelTextOperation()
        guard active == nil else { return }
        guard !KoeBridgeUpdateManager.shared.blocksRecording else {
            status = "更新画面を閉じるか、更新の完了後に実行してください"
            return
        }
        let steps: [String]
        if !translating {
            guard let preset = transformPresets.first(where: { $0.id == selectedTransformPresetID }), preset.isValid else {
                status = "設定で変換プリセットを作成・選択してください（名前と各ステップの指示が必要です）"
                return
            }
            steps = preset.steps
        } else { steps = [] }
        guard let (target, selected) = InsertionTarget.captureExternalSelection() else {
            status = translating ? "翻訳するテキストを選択してください" : "変換するテキストを選択してください"
            return
        }
        guard selected.count <= ContextTextPolicy.maximumCharacters else {
            status = translating ? "翻訳する選択テキストは2,000文字以内にしてください" : "変換する選択テキストは2,000文字以内にしてください"
            return
        }
        guard let key = KeychainStore.loadForUse() else { status = AppError.noKey.localizedDescription; return }
        let direction = translationDirection == .auto ? TranslationPolicy.direction(for: selected) : translationDirection
        runTextOperation(target: target, original: selected,
                         kind: translating ? .selectionTranslation : .presetChain,
                         steps: translating ? [TranslationPolicy.instruction(for: direction)] : steps, apiKey: key)
    }

    /// No DictationTake: intermediate results remain in memory until every step succeeds.
    private func runTextOperation(target: InsertionTarget, original: String, kind: GeneratedOperation, steps: [String], apiKey: String) {
        let id = UUID()
        textOperationID = id
        textOperationRunning = true
        textOperationUnverifiedTargets.removeAll()
        textOperationStep = 1
        textOperationDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.textOperationID == id else { return }
            self.textOperationDeadlineTask = nil
            self.textOperationTask?.cancel()
            self.textOperationTask = nil
            self.textOperationID = nil
            self.textOperationRunning = false
            self.status = "ステップ\(self.textOperationStep)で失敗しました（30秒の制限時間）。" +
                (self.lastTextOperationOutput == nil ? "" : "途中までの結果はステータスからコピーできます。")
            self.showCompletionFeedback(.transformFailed, for: id)
        }
        overlayDismissal?.cancel()
        overlayOwner = id
        overlayFeedback = .transforming
        status = "変換中 1/\(steps.count)"
        onShowPreview?()
        textOperationTask = Task { [weak self] in
            guard let self else { return }
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            var working = original
            var step = 1
            defer {
                if self.textOperationID == id {
                    self.textOperationDeadlineTask?.cancel()
                    self.textOperationDeadlineTask = nil
                    self.textOperationID = nil
                    self.textOperationRunning = false
                    self.textOperationTask = nil
                }
            }
            do {
                for (index, instruction) in steps.enumerated() {
                    step = index + 1
                    self.textOperationStep = step
                    guard self.textOperationID == id, !Task.isCancelled else { return }
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0, working.count <= ContextTextPolicy.maximumCharacters,
                          TransformPreset.validStep(instruction) else { throw GeminiRecheckWire.RecheckError.invalidResponse }
                    self.status = "変換中 \(step)/\(steps.count)"
                    let output = try await GeminiTextTransformer.transform(selectedText: working, instruction: instruction,
                                                                            apiKey: apiKey, timeout: remaining)
                    if let usage = output.usage {
                        DiagnosticLog.record("gemini transform step=\(step) usage; promptTokens=\(usage.promptTokens.map(String.init) ?? "unknown") responseTokens=\(usage.responseTokens.map(String.init) ?? "unknown") totalTokens=\(usage.totalTokens)")
                    }
                    let final = index == steps.count - 1
                    guard self.textOperationID == id, !Task.isCancelled else {
                        self.saveGeneratedResult(output.text, kind: kind, final: final, report: nil)
                        return
                    }
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        self.saveGeneratedResult(output.text, kind: kind, final: final, report: nil)
                        throw GeminiRecheckWire.RecheckError.invalidResponse
                    }
                    guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw GeminiRecheckWire.RecheckError.invalidResponse
                    }
                    working = output.text
                    self.lastTextOperationOutput = working
                }
                guard self.textOperationID == id, !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                    self.saveGeneratedResult(working, kind: kind, report: nil)
                    throw GeminiRecheckWire.RecheckError.invalidResponse
                }
                self.textOperationDeadlineTask?.cancel()
                self.textOperationDeadlineTask = nil
                // The selected source is fixed; the destination is the current
                // caret/selection when the completed transform is delivered.
                let report = await self.postingGate.post(.dictation(working), from: .selection(target),
                    selectionPredecessors: self.textOperationUnverifiedTargets) {
                    self.textOperationID == id && !Task.isCancelled
                }
                self.saveGeneratedResult(working, kind: kind, report: report)
                guard self.textOperationID == id, !Task.isCancelled else { return }
                let verified = report.outcome == .verifiedInserted
                self.finishTextOperation(verified: verified, copied: !verified && TextInsertion.copy(working), id: id)
            } catch {
                guard self.textOperationID == id, !Task.isCancelled else { return }
                self.status = "ステップ\(step)で失敗しました。選択範囲は変更していません。" +
                    (self.lastTextOperationOutput == nil ? "" : "途中までの結果はステータスからコピーできます。")
                self.showCompletionFeedback(.transformFailed, for: id)
            }
        }
    }

    private func finishTextOperation(verified: Bool, copied: Bool, id: UUID) {
        lastTextOperationOutput = nil
        showCompletionFeedback(verified ? .sent : (copied ? .transformCopied : .transformFailed), for: id)
        status = verified ? "選択テキストの変換を反映しました" : (copied ? "変換結果をクリップボードにコピーしました。入力先を確認してください。" : "変換結果をコピーできませんでした。入力先と権限を確認してください。")
    }

    func transformInstructionEnded() {
        guard active?.transformSelection != nil else { return }
        shortcutPressEnded()
    }

    func transformSelection() {
        if active?.transformSelection == nil && transformMode == .preset {
            startSelectionOperation(translating: false)
            return
        }
        cancelTextOperation()
        if active?.transformSelection != nil { toggle(); return }
        guard active == nil else { return }
        guard let (target, selected) = InsertionTarget.captureExternalSelection() else {
            status = "変換するテキストを選択してください"
            return
        }
        guard selected.count <= ContextTextPolicy.maximumCharacters else {
            status = "変換する選択テキストは2,000文字以内にしてください"
            return
        }
        guard KeychainStore.loadForUse() != nil else { status = AppError.noKey.localizedDescription; return }
        beginRecording(transformTarget: target, selection: selected)
    }
    @Published private(set) var appProfilesStore = SettingsArray<AppProfile>("appProfiles")
    var appProfiles: [AppProfile] {
        get { appProfilesStore.rows }
        set { appProfilesStore.save(newValue) }
    }
    func resetAppProfiles() { appProfilesStore.resetCorruptValue() }
    @Published private(set) var learnedTermsStore = SettingsArray<LearnedTerm>("learnedTerms")
    var learnedTerms: [LearnedTerm] {
        get { learnedTermsStore.rows }
        set { if learnedTermsStore.save(newValue) { scheduleWarmGemini() } }
    }
    func resetLearnedTerms() { learnedTermsStore.resetCorruptValue() }

    func learn(fragment: String, term: String, from record: TranscriptRecord) -> Bool {
        guard LearnedTermPolicy.validationHint(fragment: fragment, term: term, recordText: record.text) == nil else { return false }
        let updated = LearnedTermPolicy.saving(
            LearnedTerm(term: term, originalFragment: fragment, sourceRecordID: record.id), in: learnedTerms)
        guard learnedTermsStore.save(updated) else { return false }
        scheduleWarmGemini()
        return true
    }

    @Published private(set) var fixLastShortcutProblem = ""
    @Published private(set) var fixLastShortcut = RecordingShortcut(rawValue: UserDefaults.standard.string(forKey: "fixLastShortcut") ?? "")
    var onFixLastShortcutChange: ((RecordingShortcut?) -> Bool)?
    func selectFixLastShortcut(_ choice: RecordingShortcut?) {
        guard onFixLastShortcutChange?(choice) == true else {
            fixLastShortcutProblem = "修正ショートカットを登録できません（キーの競合を確認してください）"
            status = fixLastShortcutProblem
            return
        }
        fixLastShortcutProblem = ""
        fixLastShortcut = choice
        UserDefaults.standard.set(choice?.rawValue, forKey: "fixLastShortcut")
    }

    func fixLastInput() {
        guard !postingGate.isHeld else { status = DictationDelivery.postingBusyDetail; return }
        guard !hasPendingWork else { return }
        guard let anchor = postingGate.lastDeliveryAnchor, anchor.isFresh() else {
            postingGate.lastDeliveryAnchor = nil
            status = "修正できる直前の入力がありません"
            return
        }
        guard KeychainStore.loadForUse() != nil else { status = AppError.noKey.localizedDescription; return }
        var selectedTarget: InsertionTarget?
        let admitted = postingGate.withSelectionWrite {
            guard let current = InsertionTarget.capture().target,
                  current.sameField(as: anchor.target), current.textSnapshot == anchor.after else { return }
            selectedTarget = current.selectDeliveredSpan(before: anchor.before, after: anchor.after, submitted: anchor.submittedText)
        }
        guard admitted else { status = DictationDelivery.postingBusyDetail; return }
        guard let target = selectedTarget else {
            status = "入力後に変更されているため修正できません"
            return
        }
        beginRecording(transformTarget: target, selection: anchor.submittedText, fixingLastInput: true)
    }

    @Published private(set) var snippetsStore = SettingsArray<SnippetRule>("snippets")
    var snippets: [SnippetRule] {
        get { snippetsStore.rows }
        set { snippetsStore.save(newValue) }
    }
    func resetSnippets() { snippetsStore.resetCorruptValue() }
    @Published var shortcutActivationMode: ShortcutActivationMode {
        didSet {
            UserDefaults.standard.set(shortcutActivationMode.rawValue, forKey: "shortcutActivationMode")
            onInputConfigurationChange?()
        }
    }
    @Published private(set) var mouseTriggerButton: MouseTriggerButton
    @Published private(set) var mouseRegistrationProblem = ""
    var registerMouse: ((MouseTriggerButton) -> Bool)?

    func selectMouseButton(_ button: MouseTriggerButton) {
        guard registerMouse?(button) == true else {
            mouseRegistrationProblem = "マウスボタンを登録できません。入力監視の許可を確認して再試行してください。"
            return
        }
        mouseRegistrationProblem = ""
        guard button != mouseTriggerButton else { return }
        mouseTriggerButton = button
        UserDefaults.standard.set(button.rawValue, forKey: "mouseTriggerButton")
    }
    var onInputConfigurationChange: (() -> Void)?
    @Published var vocabulary: String {
        didSet {
            UserDefaults.standard.set(vocabulary, forKey: "vocabulary")
            scheduleWarmGemini()
        }
    }
    @Published var registeredVocabularyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(registeredVocabularyEnabled, forKey: "registeredVocabularyEnabled")
            scheduleWarmGemini()
        }
    }
    @Published var topicVocabularyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(topicVocabularyEnabled, forKey: "topicVocabularyEnabled")
            scheduleWarmGemini()
        }
    }
    @Published var textContextCheckEnabled: Bool {
        didSet { UserDefaults.standard.set(textContextCheckEnabled, forKey: "textContextCheckEnabled") }
    }
    @Published var audioRecheckEnabled: Bool {
        didSet { UserDefaults.standard.set(audioRecheckEnabled, forKey: "audioRecheckEnabled") }
    }
    @Published var audioRecheckPolicy: AudioRecheckPolicy {
        didSet { UserDefaults.standard.set(audioRecheckPolicy.rawValue, forKey: "audioRecheckPolicy") }
    }
    @Published private(set) var lastMetrics = ""
    @Published private(set) var usedMode = ""
    private(set) var historyRevision: UInt64 = 0
    @Published private(set) var history: [TranscriptRecord] = [] { didSet { historyRevision &+= 1 } }
    @Published private(set) var historyProblem = ""
    private(set) var usageRevision: UInt64 = 0
    @Published private(set) var monitorEvents: [EngineUsageSample] = [] { didSet { usageRevision &+= 1 } }
    @Published private(set) var monitorTokens: [GeminiTokenSample] = [] { didSet { usageRevision &+= 1 } }
    @Published private(set) var monitorProblem = ""
    @Published private(set) var shortcutChoice: RecordingShortcut = .controlOptionSpace
    @Published private(set) var shortcutProblem = ""
    var onShortcutChange: ((RecordingShortcut) -> Bool)?
    var onShortcutRearm: ((RecordingShortcut) -> Bool)?
    var onShowPreview: (() -> Void)?
    var onHidePreview: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var onShowPermissions: (() -> Void)?

    @Published var meetingModeEnabled = UserDefaults.standard.bool(forKey: "meetingModeEnabled") {
        didSet {
            UserDefaults.standard.set(meetingModeEnabled, forKey: "meetingModeEnabled")
            if meetingModeEnabled { PermissionGuide.shared.requestScreenRecording(enabled: true) }
            else { meetingSession?.stop() }
        }
    }
    @Published private(set) var meetingRunning = false
    @Published private(set) var meetingStatus = ""
    private var meetingSession: MeetingSession?
    private var meetingStatusTask: Task<Void, Never>?
    var canStartMeeting: Bool { meetingModeEnabled && CGPreflightScreenCaptureAccess() }
    func toggleMeeting() {
        if let meetingSession { meetingSession.stop(); return }
        guard !KoeBridgeUpdateManager.shared.blocksRecording else {
            status = "更新画面を閉じるか、更新の完了後に会議モードを開始してください"; return
        }
        guard canStartMeeting else { status = "会議モードと画面収録の許可を設定してください"; return }
        guard phase == .idle, active == nil, inFlight.isEmpty, !textOperationRunning, !benchRecordingActive else {
            status = "音声入力・ベンチ録音・処理の完了後に会議モードを開始してください"; return
        }
        let geminiKey: String?
        let amiVoiceKey: String?
        switch requestedMode {
        case .gemini:
            guard let key = loadKeyForUse(provider: .gemini) else {
                status = AppError.noKey.localizedDescription
                return
            }
            geminiKey = key
            amiVoiceKey = nil
        case .amivoice:
            guard let key = loadKeyForUse(provider: .amivoice) else {
                status = AppError.noAmiVoiceKey.localizedDescription
                return
            }
            geminiKey = nil
            amiVoiceKey = key
        case .local:
            geminiKey = nil
            amiVoiceKey = nil
        }
        meetingRunning = true
        microphoneWarmKeeper.suspend(reason: "meeting")
        warmScheduleTask?.cancel(); prewarmer.shutdown()
        let session = MeetingSession(engine: requestedMode, vocabulary: currentAudioVocabulary,
            style: transcriptionStyle, japaneseHint: japaneseHint, apiKey: geminiKey,
            microphoneUID: MicrophoneDeviceStore.shared.selectedUID,
            amiVoiceKey: amiVoiceKey, amiVoiceEngine: amiVoiceEngine,
            amiVoiceProfileId: amiVoiceRecognitionProfileID(for: amiVoiceEngine))
        meetingSession = session
        meetingStatus = session.liveStatus
        session.onStatus = { [weak self] in self?.meetingStatus = $0 }
        session.onUsage = { [weak self] event, tokens in
            self?.usageStore.append(engineEvents: [event], tokenEvents: tokens)
        }
        session.onMicrophoneStarted = { [weak self] in
            self?.clearMicrophoneNoticeForSuccessfulStart()
        }
        session.onMicrophoneInterruption = { [weak self] interruption in
            self?.recordMicrophoneNotice(.recordingDeviceDisconnected, timing: .finalFailure, context: .meeting,
                deviceRemovalProven: interruption == .deviceRemoval)
        }
        session.onMicrophoneFailure = { [weak self] error, disposition in
            self?.recordMicrophoneNotice(MicrophoneNoticeBinding.state(for: error, disposition: disposition),
                timing: .finalFailure, context: .meeting)
        }
        session.onFinished = { [weak self, weak session] text, partial in
            guard let self, let session, meetingSession === session else { return }
            let recordID = session.save(text, partial: partial, to: &historyStore)
            refreshRetainedAudio()
            meetingSession = nil; meetingRunning = false
            meetingStatusTask?.cancel(); meetingStatusTask = nil
            if let message = session.microphoneRecoveryMessage { status = message }
            else if text.isEmpty { status = "会議モードを終了しました（文字起こしなし）" }
            else if !historyStore.isSaved(recordID) { status = "会議の文字起こしは未保存です" }
            else { status = partial ? "会議の途中結果を履歴に保存しました" : "会議の文字起こしを履歴に保存しました" }
            meetingStatus = status
            resumeMicrophoneWarm(); scheduleWarmGemini()
        }
        meetingStatusTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            let allowed = await microphoneAllowed()
            guard meetingSession === session else { return }
            guard allowed else {
                // Stop and save through the meeting's mic-failure completion without starting chunks.
                recordMicrophoneNotice(.permissionDenied, timing: .finalFailure, context: .meeting)
                session.microphonePermissionDenied()
                return
            }
            session.start()
            while meetingSession === session {
                meetingStatus = session.liveStatus
                if !CGPreflightScreenCaptureAccess() { session.systemPermissionRevoked() }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    @Published var retainAudioEnabled = UserDefaults.standard.bool(forKey: "retainAudioEnabled") {
        didSet {
            UserDefaults.standard.set(retainAudioEnabled, forKey: "retainAudioEnabled")
            if !retainAudioEnabled { clearRetainedAudio() }
        }
    }
    @Published var replayRecordID: UUID?
    @Published var replayStatus = ""
    @Published var retentionStatus = ""
    private let retainedAudio: RetainedAudioStore
    private var retentionGeneration = UUID()
    private var replayTask: Task<Void, Never>?
    private var replayLocal: LocalTranscribing?
    private var replayAmiVoice: AmiVoiceWebSocketConnection?
    static let amiVoiceReplayChunkBytes = 16 * 1_024

    static func streamReplayPCM(_ pcm: Data, through connection: AmiVoiceWebSocketConnection) async throws -> String {
        for offset in stride(from: pcm.startIndex, to: pcm.endIndex, by: amiVoiceReplayChunkBytes) {
            try Task.checkCancellation()
            let end = min(offset + amiVoiceReplayChunkBytes, pcm.endIndex)
            try await connection.sendAudio(Data(pcm[offset..<end]))
            await Task.yield()
        }
        try Task.checkCancellation()
        return try await connection.endAudioAndAwaitFinal()
    }

    func clearRetainedAudio() {
        retentionGeneration = UUID()
        cancelReplay()
        retainedAudio.clear(history: &historyStore)
        updateRetentionStatus()
    }
    private func refreshRetainedAudio() {
        retainedAudio.sweep(history: &historyStore)
        updateRetentionStatus()
    }
    private func updateRetentionStatus() {
        if let id = replayRecordID, !historyStore.entries.contains(where: { $0.id == id && $0.audioAsset != nil }) {
            cancelReplay()
        }
        if historyStore.loadOutcome == .failed {
            retentionStatus = "履歴の参照を読み込めないため、保存音声の自動整理を保留しています。"
            return
        }
        retentionStatus = "\(retainedAudio.bytesUsed) / 250,000,000 bytes・\(retainedAudio.fileCount)ファイル・7日間"
    }
    func cancelReplay() {
        let wasRunning = replayRecordID != nil
        replayJob = UUID()
        replayTask?.cancel(); replayTask = nil
        replayLocal?.cancel(); replayLocal = nil
        replayAmiVoice?.cancel(); replayAmiVoice = nil
        replayRecordID = nil
        if wasRunning { replayStatus = "再文字起こしをキャンセルしました" }
    }
    func replay(_ record: TranscriptRecord, engine: RecognitionMode) {
        cancelReplay()
        let job = UUID()
        replayJob = job
        replayRecordID = record.id
        replayStatus = "音声から再文字起こし中…"
        replayTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if replayJob == job {
                    replayRecordID = nil
                    replayLocal?.cancel(); replayLocal = nil
                    replayAmiVoice?.cancel(); replayAmiVoice = nil
                    replayTask = nil
                }
            }
            do {
                let source = try retainedAudio.prepareRead(record.id, history: &historyStore)
                let revision = historyRevision
                let pcm: Data
                do { pcm = try await source.loadOnWorker() }
                catch {
                    guard replayJob == job, !Task.isCancelled else { return }
                    retainedAudio.handleReadFailure(error, source: source, history: &historyStore)
                    throw error
                }
                guard replayJob == job, !Task.isCancelled,
                      historyStore.entries.first(where: { $0.id == record.id })?.audioAsset == source.asset else { return }
                if historyRevision == revision && retainedAudio.sweepIsReusable { updateRetentionStatus() } else { refreshRetainedAudio() }
                guard replayJob == job, !Task.isCancelled else { return }
                let text: String
                switch engine {
                case .local:
                    guard pcm.count <= 50 * 32_000 else { throw RetainedAudioStore.ReplayError.localLimit }
                    let local = makeLocalTranscriber()
                    replayLocal = local
                    try await local.start()
                    for offset in stride(from: 0, to: pcm.count, by: 3_200) {
                        try Task.checkCancellation()
                        try await local.appendRecoveryPCM(pcm, range: offset..<min(offset + 3_200, pcm.count))
                        await Task.yield()
                    }
                    text = try await local.endAudioAndAwaitFinal()
                case .gemini:
                    guard let key = loadKeyForUse(provider: .gemini) else { throw AppError.noKey }
                    text = try await GeminiAudioRechecker.recognize(pcm16LE: pcm,
                        vocabulary: currentAudioVocabulary, style: transcriptionStyle,
                        japaneseHint: japaneseHint, apiKey: key, timeout: 60).text
                case .amivoice:
                    guard let key = loadKeyForUse(provider: .amivoice) else { throw AppError.noAmiVoiceKey }
                    let connection = makeAmiVoiceConnectionInstance(apiKey: key, engine: amiVoiceEngine, vocabulary: currentAudioVocabulary)
                    replayAmiVoice = connection
                    defer {
                        connection.cancel()
                        if replayAmiVoice === connection { replayAmiVoice = nil }
                    }
                    text = try await Self.streamReplayPCM(pcm, through: connection)
                }
                try Task.checkCancellation()
                guard replayJob == job, historyStore.entries.contains(where: { $0.id == record.id }) else { return }
                let saved = historyStore.appendRetranscription(record.id, result: .init(engine: engine.label, text: text))
                replayStatus = saved ? "再文字起こし結果を履歴に追加しました" : "再文字起こし結果は未保存です"
            } catch {
                DiagnosticLog.record("audio replay recognition failed; category=\(Self.failureCategory(error))")
                if replayJob == job, !Task.isCancelled {
                    replayStatus = Self.userFacingFailure(error, operation: "再文字起こし")
                }
            }
        }
    }
    private var replayJob = UUID()
    private var currentAudioVocabulary: [String] {
        AgentVocabulary.terms(user: vocabulary.components(separatedBy: .newlines), learned: learnedTerms.map(\.term),
            registeredEnabled: registeredVocabularyEnabled, topicEnabled: topicVocabularyEnabled)
    }

    var rejectedHistoryText: String? { historyStore.rejectedResult?.text }
    func isHistorySaved(_ id: UUID) -> Bool { historyStore.isSaved(id) }
    var savedHistoryCount: Int { history.count - historyStore.unsavedIDs.count }

    private var historyStore: TranscriptHistoryStore {
        didSet {
            history = historyStore.entries
            historyProblem = historyStore.problem
        }
    }
    private var usageStore: UsageMonitorStore {
        didSet {
            monitorEvents = usageStore.engineEvents
            monitorTokens = usageStore.tokenEvents
            monitorProblem = usageStore.problem
        }
    }
    private let volumeGuard: OutputVolumeGuard
    private let microphoneWarmKeeper: MicrophoneWarmKeeper
    private var microphoneStoreObservation: AnyCancellable?
    private func resumeMicrophoneWarm(reason: String = "teardown") {
        guard !meetingRunning, !benchRecordingActive else { return }
        microphoneWarmKeeper.resume(enabled: bluetoothMicWarmEnabled,
            selectedUID: MicrophoneDeviceStore.shared.selectedUID, takeActive: busy || benchRecordingActive, reason: reason)
    }

    private let prewarmer = GeminiLivePrewarmer()
    private var warmScheduleTask: Task<Void, Never>?
    private var active: DictationTake?
    private var microphoneNoticeStore = MicrophoneNoticeStore()
    private lazy var postingGate = TextInsertion.PostingGate { [unowned self] report, sourceID in
        reconcileDelivery(report, sourceTakeID: sourceID)
    }
    private var inFlight: [UUID: DictationTake] = [:]
    private var finished = OrderedResultBuffer<Completion>(maximumPending: 8)
    /// Presentation only: report a live fallback accurately; idle text names the OS default.
    var localBackendStatus: String {
        if let local = active?.local {
            return local.requiresSpeechAuthorization
                ? "使用中のローカル認識: SFSpeechRecognizer"
                : "使用中のローカル認識: SpeechAnalyzer"
        }
        if #available(macOS 26, *) {
            return "ローカル認識: SpeechAnalyzer（開始に失敗した場合はSFSpeechRecognizerへ切替）"
        }
        return "ローカル認識: SFSpeechRecognizer"
    }

    private var localRecoveryBusy = false
    private(set) var deferredSummary: String?
    private var deferredFeedback = DictationDelivery.DeferredFeedback()
    private var overlayOwner: UUID?
    private var overlayDismissal: Task<Void, Never>?
    private var deliveryWorker: Task<Void, Never>?
    private var deliveringTakeID: UUID?

    private var transcriptionOptions: TranscriptionOptions {
        TranscriptionOptions(registeredVocabularyEnabled: registeredVocabularyEnabled,
                             topicVocabularyEnabled: topicVocabularyEnabled,
                             textContextCheckEnabled: textContextCheckEnabled,
                             audioRecheckEnabled: audioRecheckEnabled,
                             audioRecheckPolicy: audioRecheckPolicy)
    }

    private enum Disposition {
        case text
        case command(VoiceCommandID)
        case blockedCommand(VoiceCommandID, String)
    }

    private struct Completion {
        var disposition: Disposition = .text
        let text: String?
        let reason: String?
        let partial: String
        let noInput: Bool
    }

    @MainActor struct PreparationEnvironment {
        var permission: (() async -> Bool)?
        var selectedInputUID: (() -> String)?
        var makeCapture: ((String, OutputVolumeGuard, UUID, Bool) -> MicrophoneCapture)?
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var waitBeforeRetry: (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
        var makeInputTrace: (UUID) -> InputDiagnosticTrace? = { DiagnosticLog.inputTrace(takeID: $0) }
        var recordSession: (() -> String) -> Void = { DiagnosticLog.record($0()) }
        var recordMicrophone: (() -> String) -> Void = { DiagnosticLog.recordMicrophoneEvidence($0()) }
        var captureTarget: ((InputDiagnosticTrace?) -> (target: InsertionTarget?, reason: String))?
        var consumeAudio: ((AsyncStream<Data>) async -> String?)?
        var shouldPaste: Bool?
        var preparationLaunched: ((Task<Void, Never>) -> Void)?
        var loadKeyForUse: (@MainActor (CredentialProvider) -> String?)?
        var keyRegistered: (@MainActor (CredentialProvider) -> Bool)?
        var makeLocalTranscriber: (@MainActor () -> LocalTranscribing)?
        var makeAmiVoiceConnection: (@MainActor (String, AmiVoiceEngine, [String]) -> AmiVoiceWebSocketConnection)?
        var makeAmiVoiceConnectionWithProfile: (@MainActor (String, AmiVoiceEngine, [String], String?) -> AmiVoiceWebSocketConnection)?
    }

    private let preparation: PreparationEnvironment
    private let amiVoiceDictionaryStore: AmiVoiceDictionarySyncStore
    let amiVoiceDictionarySyncEngine: AmiVoiceDictionarySyncEngine

    private var currentAmiVoiceDictionaryProfileKey: AmiVoiceDictionaryProfileKey {
        AmiVoiceDictionaryProfileKey(engine: amiVoiceEngine, samplingRate: .rate16k)
    }

    /// B-4-facing opt-in setting. It is deliberately false on a fresh install;
    /// while false every sync entry point returns before touching transport.
    var amiVoiceDictionarySyncEnabled: Bool {
        get { amiVoiceDictionaryStore.automaticSyncEnabled }
        set {
            amiVoiceDictionaryStore.automaticSyncEnabled = newValue
            objectWillChange.send()
            guard newValue else { return }
            let key = currentAmiVoiceDictionaryProfileKey
            Task { [weak self] in
                guard let self else { return }
                _ = await self.amiVoiceDictionarySyncEngine.performLaunchConsistencyPass(for: key)
            }
        }
    }

    /// Synchronous snapshot for settings UI rendering; the actor exposes the
    /// same surface to asynchronous callers through `status(for:)`.
    var currentAmiVoiceDictionarySyncStatus: AmiVoiceDictionarySyncStatus {
        let key = currentAmiVoiceDictionaryProfileKey
        return AmiVoiceDictionarySyncStatus.make(
            automaticSyncEnabled: amiVoiceDictionaryStore.automaticSyncEnabled,
            entries: amiVoiceDictionaryStore.loadEntries(),
            profile: amiVoiceDictionaryStore.profile(for: key),
            key: key
        )
    }

    func refreshAmiVoiceDictionarySyncStatus() async -> AmiVoiceDictionarySyncStatus {
        await amiVoiceDictionarySyncEngine.status(for: currentAmiVoiceDictionaryProfileKey)
    }

    func amiVoiceRecognitionProfileID(for engine: AmiVoiceEngine) -> String? {
        let key = AmiVoiceDictionaryProfileKey(engine: engine, samplingRate: .rate16k)
        return AmiVoiceDictionarySyncPolicy.recognitionProfileID(
            automaticSyncEnabled: amiVoiceDictionaryStore.automaticSyncEnabled,
            entries: amiVoiceDictionaryStore.loadEntries(),
            profile: amiVoiceDictionaryStore.profile(for: key),
            key: key
        )
    }

    private func loadKeyForUse(provider: CredentialProvider) -> String? {
        if let load = preparation.loadKeyForUse { return load(provider) }
        return KeychainStore.loadForUse(provider: provider)
    }

    private func makeLocalTranscriber() -> LocalTranscribing {
        preparation.makeLocalTranscriber?() ?? LocalTranscriberFactory.make()
    }

    private func makeAmiVoiceConnectionInstance(apiKey: String, engine: AmiVoiceEngine, vocabulary: [String]) -> AmiVoiceWebSocketConnection {
        let profileID = amiVoiceRecognitionProfileID(for: engine)
        if let make = preparation.makeAmiVoiceConnectionWithProfile {
            return make(apiKey, engine, vocabulary, profileID)
        }
        if let make = preparation.makeAmiVoiceConnection {
            return make(apiKey, engine, vocabulary)
        }
        return AmiVoiceWebSocketConnection(apiKey: apiKey, engine: engine, vocabulary: vocabulary, profileId: profileID)
    }

    init(preparation: PreparationEnvironment? = nil, storageDirectory: URL? = nil) {
        self.preparation = preparation ?? PreparationEnvironment()
        let dictionaryStore = AmiVoiceDictionarySyncStore()
        amiVoiceDictionaryStore = dictionaryStore
        amiVoiceDictionarySyncEngine = AmiVoiceDictionarySyncEngine(
            store: dictionaryStore,
            transport: AmiVoiceDictionaryAPIClient(),
            apiKeyProvider: { KeychainStore.load(provider: .amivoice) }
        )

        let d = UserDefaults.standard
        let guardEnabled = storageDirectory == nil && d.bool(forKey: OutputVolumeGuard.preferenceKey)
        outputVolumeGuardEnabled = guardEnabled
        let guardController = OutputVolumeGuard(enabled: guardEnabled)
        volumeGuard = guardController
        microphoneWarmKeeper = MicrophoneWarmKeeper(volumeGuard: guardController)
        bluetoothMicWarmEnabled = storageDirectory == nil && d.bool(forKey: "bluetoothMicWarm")
        shortcutActivationMode = ShortcutActivationMode(rawValue: d.string(forKey: "shortcutActivationMode") ?? "") ?? .toggle
        mouseTriggerButton = MouseTriggerButton(rawValue: d.string(forKey: "mouseTriggerButton") ?? "") ?? .none
        requestedMode = RecognitionMode(rawValue: d.string(forKey: "engine") ?? "gemini") ?? .gemini
        amiVoiceEngine = AmiVoiceEngine(rawValue: d.string(forKey: "amiVoiceEngine") ?? "") ?? .e2eJapaneseGeneral
        transcriptionStyle = TranscriptionStyle.restoring(
            storedStyle: d.string(forKey: "transcriptionStyle"),
            legacySmart: d.bool(forKey: "smart")
        )
        geminiPrewarmEnabled = storageDirectory == nil && (d.object(forKey: "geminiPrewarm") == nil || d.bool(forKey: "geminiPrewarm"))
        normalizeJapaneseSpacing = d.object(forKey: "normalizeJapaneseSpacing") as? Bool ?? true
        japaneseHint = d.object(forKey: "japanese") == nil ? true : d.bool(forKey: "japanese")
        automaticPaste = d.object(forKey: "autoPaste") == nil ? true : d.bool(forKey: "autoPaste")
        vocabulary = d.string(forKey: "vocabulary") ?? "GitHub\nn8n\nPython\nDeepSeek\nGemini\nCodex"
        let options = TranscriptionOptions.load(
            from: d,
            hasLegacyUsage: FileManager.default.fileExists(atPath: RecentTranscriptArchive.defaultFileURL.path))
        registeredVocabularyEnabled = options.registeredVocabularyEnabled
        topicVocabularyEnabled = options.topicVocabularyEnabled
        textContextCheckEnabled = options.textContextCheckEnabled
        audioRecheckEnabled = options.audioRecheckEnabled
        audioRecheckPolicy = options.audioRecheckPolicy
        shortcutChoice = RecordingShortcut(rawValue: d.string(forKey: "recordingShortcut") ?? "") ?? .controlOptionSpace
        if let storageDirectory {
            retainedAudio = RetainedAudioStore(directory: storageDirectory.appendingPathComponent("RetainedAudio"))
            historyStore = TranscriptHistoryStore(fileURL: storageDirectory.appendingPathComponent("history.json"))
            usageStore = UsageMonitorStore(fileURL: storageDirectory.appendingPathComponent("usage.json"))
        } else {
            retainedAudio = RetainedAudioStore()
            historyStore = TranscriptHistoryStore()
            usageStore = UsageMonitorStore()
        }
        history = historyStore.entries
        historyProblem = historyStore.problem
        monitorEvents = usageStore.engineEvents
        monitorTokens = usageStore.tokenEvents
        monitorProblem = usageStore.problem
        retainedAudio.reconcileAtLaunch(history: &historyStore, retentionEnabled: retainAudioEnabled)
        updateRetentionStatus()
        guard storageDirectory == nil else { return }
        let launchProfileKey = currentAmiVoiceDictionaryProfileKey
        Task { [weak self] in
            guard let self else { return }
            _ = await self.amiVoiceDictionarySyncEngine.performLaunchConsistencyPass(for: launchProfileKey)
        }
        scheduleWarmGemini()
        microphoneWarmKeeper.onConfigurationChange = { [weak self] in
            self?.resumeMicrophoneWarm(reason: "configuration")
        }
        microphoneStoreObservation = MicrophoneDeviceStore.shared.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.resumeMicrophoneWarm(reason: "devices") }
        }
        Task { @MainActor [weak self] in
            await MicrophoneDeviceStore.shared.refresh()
            self?.resumeMicrophoneWarm(reason: "launch")
        }
    }

    private func scheduleWarmGemini() {
        warmScheduleTask?.cancel()
        warmScheduleTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) }
            catch { return }
            self?.warmGeminiIfNeeded()
        }
    }

    private func warmGeminiIfNeeded() {
        prewarmer.warmIfNeeded { [self] in
            guard !meetingRunning, !benchRecordingActive, geminiPrewarmEnabled, requestedMode == .gemini, active == nil,
                  !inFlight.values.contains(where: { !$0.finished }),
                  let key = KeychainStore.loadForUse() else { return nil }
            let terms = AgentVocabulary.terms(user: vocabulary.components(separatedBy: .newlines), learned: learnedTerms.map(\.term),
                                             registeredEnabled: registeredVocabularyEnabled,
                                             topicEnabled: topicVocabularyEnabled)
            return (GeminiPrewarmSnapshot(vocabulary: terms, style: transcriptionStyle,
                                         japaneseHint: japaneseHint,
                                         apiKeyFingerprint: GeminiPrewarmSnapshot.fingerprint(apiKey: key)), key)
        }
    }

    private var cachedKeyRegistration: Bool?
    private var cachedAmiVoiceKeyRegistration: Bool?
    var hasKey: Bool {
        if let keyRegistered = preparation.keyRegistered {
            if let cachedKeyRegistration { return cachedKeyRegistration }
            let registered = keyRegistered(.gemini)
            cachedKeyRegistration = registered
            return registered
        }
        guard KeychainStore.observingChanges else { return KeychainStore.load(provider: .gemini) != nil }
        if let cachedKeyRegistration { return cachedKeyRegistration }
        let registered = KeychainStore.load(provider: .gemini) != nil
        cachedKeyRegistration = registered
        return registered
    }

    var hasAmiVoiceKey: Bool {
        if let keyRegistered = preparation.keyRegistered {
            if let cachedAmiVoiceKeyRegistration { return cachedAmiVoiceKeyRegistration }
            let registered = keyRegistered(.amivoice)
            cachedAmiVoiceKeyRegistration = registered
            return registered
        }
        guard KeychainStore.observingChanges else { return KeychainStore.load(provider: .amivoice) != nil }
        if let cachedAmiVoiceKeyRegistration { return cachedAmiVoiceKeyRegistration }
        let registered = KeychainStore.load(provider: .amivoice) != nil
        cachedAmiVoiceKeyRegistration = registered
        return registered
    }

    func invalidateKeyRegistration() {
        guard cachedKeyRegistration != nil || cachedAmiVoiceKeyRegistration != nil else { return }
        cachedKeyRegistration = nil
        cachedAmiVoiceKeyRegistration = nil
        objectWillChange.send()
    }
    private func recordMicrophoneNotice(
        _ state: MicrophoneNoticeState?,
        timing: MicrophoneNoticeFailureTiming,
        context: MicrophoneNoticeContext = .standard,
        deviceRemovalProven: Bool = false
    ) {
        guard let state else { return }
        if microphoneNoticeStore.recordFailure(state, timing: timing, context: context,
                                               deviceRemovalProven: deviceRemovalProven) {
            microphoneNotice = microphoneNoticeStore.current
        }
    }

    private func clearMicrophoneNoticeForSuccessfulStart() {
        if microphoneNoticeStore.recordSuccessfulStart() { microphoneNotice = nil }
    }

    func dismissMicrophoneNotice() {
        if microphoneNoticeStore.dismissCurrent() { microphoneNotice = nil }
    }

    var busy: Bool { active != nil }
    static func benchRecordingAdmission(busy: Bool, phase: Phase, meetingRunning: Bool,
                                        updateBlocksRecording: Bool) -> Bool {
        !busy && phase == .idle && !meetingRunning && !updateBlocksRecording
    }
    var canStartBenchRecording: Bool {
        Self.benchRecordingAdmission(busy: busy, phase: phase, meetingRunning: meetingRunning,
                                     updateBlocksRecording: KoeBridgeUpdateManager.shared.blocksRecording)
    }
    func beginBenchRecordingSession(onInterrupt: @escaping @MainActor () -> Void) -> Bool {
        guard canStartBenchRecording, !benchRecordingActive else { return false }
        benchRecordingActive = true
        cancelBenchRecording = onInterrupt
        microphoneWarmKeeper.suspend(reason: "bench")
        return true
    }
    func endBenchRecordingSession() {
        guard benchRecordingActive else { return }
        benchRecordingActive = false
        cancelBenchRecording = nil
        resumeMicrophoneWarm(reason: "bench_teardown")
    }
    /// Read-only observation of the active take's stored target (post-capture).
    var activeTakeTarget: InsertionTarget? { active?.target }
    func reserveHistoryInsertion() -> UUID? { postingGate.reserveHistory() }
    func performHistoryIntent(_ ticket: UUID, deadline: ContinuousClock.Instant, perform: () async -> Void) async {
        await postingGate.performHistoryIntent(ticket, deadline: deadline, perform: perform)
    }

    func insertHistory(_ text: String, to target: InsertionTarget?, ticket: UUID) async -> DictationDelivery.Outcome {
        let report = await postingGate.post(.dictation(text), from: .history(target, requestedAt: ticket)) {
            !self.meetingRunning && self.replayRecordID == nil
        }
        return DictationDelivery.classify(report)
    }

    // Updating must not terminate background recognition or pending delivery.
    var hasPendingWork: Bool { postingGate.hasPendingWork || otherDeliveryWorkPending }
    var historyAdmissionBusy: Bool { postingGate.isHeld || otherDeliveryWorkPending }
    private var otherDeliveryWorkPending: Bool { active != nil || !inFlight.isEmpty || deliveryWorker != nil || textOperationRunning || meetingRunning || replayRecordID != nil }

    func shortcutPressBegan() {
        if phase == .idle { beginRecording() }
    }

    func shortcutPressEnded() {
        if phase == .recording { stop() }
        else if phase == .preparing { discard() }
    }

    /// Recording STOP frees the shortcut synchronously. Recognition and
    /// paste continue on the take that just ended; the next F8 can start NOW.
    func toggle() {
        switch VoiceSessionTransitions().shortcut(phase: phase) {
        case .start:
            if phase == .finalizing { phase = .idle }
            beginRecording()
        case .discard:
            DiagnosticLog.record("shortcut cancel preparing; no deferred restart")
            discard()
        case .stop: stop()
        }
    }

    private func beginRecording(transformTarget: InsertionTarget? = nil, selection: String? = nil, fixingLastInput: Bool = false) {
        guard !meetingRunning else { status = "会議モード中は通常の音声入力を開始できません"; return }
        guard !benchRecordingActive else { status = "ベンチ録音中は通常の音声入力を開始できません"; return }
        guard active == nil, phase == .idle else { return }
        cancelTextOperation()
        guard !KoeBridgeUpdateManager.shared.blocksRecording else {
            status = "更新画面を閉じるか、更新の完了後に録音を開始してください"
            return
        }
        guard finished.canBegin, inFlight.count < 8 else {
            status = "確定待ちが8件あります。前の認識が終わるまで追加できません（録音内容は履歴へ保存）"
            DiagnosticLog.record("shortcut capacity reached; pending=\(finished.count)")
            return
        }
        // Read identity without AX so save-only takes also resolve a profile.
        // Transformations retain the identity captured with their selected text.
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier: String? = transformTarget != nil
            ? transformTarget?.bundleIdentifier
            : (frontApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontApp?.bundleIdentifier)
        if let anchor = postingGate.lastDeliveryAnchor, frontApp?.processIdentifier != anchor.target.pid {
            postingGate.lastDeliveryAnchor = nil
        }
        let profile = AppProfileResolver.match(profiles: appProfiles, bundleIdentifier: bundleIdentifier)
        let globalOptions = transcriptionOptions
        let options = TranscriptionOptions(
            registeredVocabularyEnabled: profile?.registeredVocabularyEnabled ?? globalOptions.registeredVocabularyEnabled,
            topicVocabularyEnabled: profile?.topicVocabularyEnabled ?? globalOptions.topicVocabularyEnabled,
            textContextCheckEnabled: profile?.textContextCheckEnabled ?? globalOptions.textContextCheckEnabled,
            audioRecheckEnabled: profile?.audioRecheckEnabled ?? globalOptions.audioRecheckEnabled,
            audioRecheckPolicy: profile?.audioRecheckAlways.map { $0 ? .always : .whenSuspicious } ?? globalOptions.audioRecheckPolicy)
        let globalTerms = AgentVocabulary.terms(user: vocabulary.components(separatedBy: .newlines), learned: learnedTerms.map(\.term),
                                               registeredEnabled: options.registeredVocabularyEnabled,
                                               topicEnabled: options.topicVocabularyEnabled)
        let selectedVocabulary = AppProfileResolver.mergedVocabulary(
            profileTerms: (profile?.additionalVocabulary ?? "").components(separatedBy: .newlines),
            globalTerms: globalTerms)
        let take = DictationTake(preferred: profile?.engine.flatMap(RecognitionMode.init(rawValue:)) ?? requestedMode,
                                style: profile?.style.flatMap(TranscriptionStyle.init(rawValue:)) ?? transcriptionStyle,
                                japaneseHint: japaneseHint,
                                vocabulary: selectedVocabulary,
                                shouldPaste: preparation.shouldPaste ?? automaticPaste, options: options,
                                normalizeJapaneseSpacing: normalizeJapaneseSpacing, snippets: snippets)
        take.retainAudioGeneration = retainAudioEnabled ? retentionGeneration : nil
        take.appBundleIdentifier = bundleIdentifier
        take.appProfileName = profile?.displayName
        take.voiceCommandsEnabled = voiceCommandsEnabled
        take.enabledVoiceCommands = enabledVoiceCommands
        take.postProcessEnabled = profile?.postProcessEnabled ?? postProcessEnabled
        take.postProcessMode = profile?.postProcessMode.flatMap(PostProcessingMode.init(rawValue:)) ?? postProcessMode
        if let profile {
            DiagnosticLog.record("app profile applied bundle=\(profile.bundleIdentifier)")
        }
        take.transformSelection = selection
        take.isFixLastInput = fixingLastInput
        guard finished.begin(take.id) else { return }
        take.inputDiagnostics = preparation.makeInputTrace(take.id)
        take.inputDiagnostics?.record(.session, stage: .requested, [
            .pending: .integer(finished.count),
            .shouldPaste: .flag(take.shouldPaste),
            .textCheck: .flag(take.options.textContextCheckEnabled),
            .audioRecheck: .flag(take.options.audioRecheckEnabled),
            .vocabularyCount: .integer(take.vocabulary.count),
            .registeredTerms: .flag(take.options.registeredVocabularyEnabled),
            .topicTerms: .flag(take.options.topicVocabularyEnabled),
            .engine: .token(take.preferred.diagnosticToken),
            .style: .token(take.style == .agent ? .agent : (take.style == .readable ? .readable : .verbatim)),
            .build: .integer(Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0),
            .osMajor: .integer(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            .osMinor: .integer(ProcessInfo.processInfo.operatingSystemVersion.minorVersion),
            .osPatch: .integer(ProcessInfo.processInfo.operatingSystemVersion.patchVersion)
        ])
        inFlight[take.id] = take
        active = take
        overlayDismissal?.cancel()
        overlayDismissal = nil
        overlayOwner = take.id
        overlayFeedback = .preparing
        phase = .preparing
        previewText = ""
        lastMetrics = ""
        usedMode = take.usedMode
        status = take.appProfileName.map { "\($0)用プロファイル適用中 — マイクを準備しています…" } ?? "マイクを準備しています…"
        let focusStartedAt = ProcessInfo.processInfo.systemUptime
        let targetResult = transformTarget.map { (target: Optional($0), reason: "ok") }
            ?? preparation.captureTarget?(take.inputDiagnostics)
            ?? InsertionTarget.capture(diagnostics: take.inputDiagnostics) // BEFORE the overlay is shown
        take.target = targetResult.target?.removingTextSnapshotUnlessNormal()
        take.targetCaptureReason = targetResult.reason
        if recheckContextEnabled && selection == nil {
            take.capturedContext = ContextCapture.capture(target: take.target, app: contextAppEnabled,
                selection: contextSelectionEnabled, surrounding: contextSurroundingEnabled)
        }
        take.inputDiagnostics?.record(.target, stage: .capture, [
            .element: .token(take.target != nil ? .ok : .unavailable),
            .reason: .reason(targetResult.reason),
            .elapsedMS: .integer(InputDiagnosticTrace.milliseconds(since: focusStartedAt))
        ])
        onShowPreview?()
        take.permissionTask = Task { [weak self, weak take] in
            do { try await Task.sleep(for: .seconds(40)) } catch { return }
            guard let self, let take, self.active === take, self.phase == .preparing else { return }
            self.resolve(take, text: nil, reason: "マイクの準備が40秒以内に終わりませんでした")
        }
        let startupTask = Task { [weak self, weak take] in
            guard let self, let take else { return }
            await self.startPrepared(take)
        }
        preparation.preparationLaunched?(startupTask)
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func startPrepared(_ take: DictationTake) async {
        guard active === take, !take.finished else { return }
        let beforePermission = Date()
        let selectedInputUID = preparation.selectedInputUID?() ?? MicrophoneDeviceStore.shared.selectedUID
        let allowed: Bool
        if let permission = preparation.permission { allowed = await permission() }
        else { allowed = await microphoneAllowed() }
        guard allowed else {
            if active === take {
                recordMicrophoneNotice(.permissionDenied, timing: .finalFailure)
                resolve(take, text: nil, reason: "マイクへのアクセスが許可されていません")
            }
            return
        }
        DiagnosticLog.record("mic permission ready; elapsed=\(String(format: "%.3f", Date().timeIntervalSince(beforePermission)))s")
        guard active === take, phase == .preparing, !take.finished else { return }

        let (stream, continuation) = AsyncStream<Data>.makeStream(
            of: Data.self, bufferingPolicy: .bufferingOldest(480))
        take.continuation = continuation
        let integrity = take.audioIntegrity // thread-safe; do not cross actor isolation in audio callback
        let retryPolicy = MicrophoneStartupRetryPolicy()
        let preparationBegan = preparation.now()
        var attempts = 0
        var recoveryDisposition: MicrophoneCapture.EngineLifetime.Disposition = .normal
        do {
            var readyCapture: MicrophoneCapture?
            while readyCapture == nil {
                try Task.checkCancellation()
                guard active === take, phase == .preparing, !take.finished else { throw CancellationError() }
                let attemptBegan = preparation.now()
                let elapsed = attemptBegan - preparationBegan
                let timeout = retryPolicy.timeoutForNextAttempt(elapsed: elapsed)
                guard timeout > 0 else { throw MicrophoneCapture.CaptureError.notReady(.noBuffers) }
                attempts += 1
                let candidate = preparation.makeCapture?(selectedInputUID, volumeGuard, take.id, attempts == 1)
                    ?? MicrophoneCapture(selectedInputUID: selectedInputUID, volumeGuard: volumeGuard,
                                         takeID: take.id, explicitStart: attempts == 1)
                // Own preparation, not just a successfully started microphone.
                // discard()/releaseResources() can now stop it immediately.
                take.mic = candidate
                preparation.recordMicrophone { "mic_prepare_attempt take=\(take.id.uuidString) attempt=\(attempts)" }
                do {
                    microphoneWarmKeeper.suspend(reason: "take", handingTo: candidate)
                    let deadline = min(attemptBegan + timeout, preparationBegan + retryPolicy.totalTimeout)
                    try await candidate.start(deadline: deadline, onAudio: { [weak self, weak take] data in
                        let delivery = continuation.yield(data)
                        if case .dropped = delivery {
                            integrity.markDropped()
                            Task { @MainActor [weak self, weak take] in
                                guard let self, let take, !take.finished else { return }
                                self.resolve(take, text: nil, reason: "音声送信キューから音声が欠落しました")
                            }
                        }
                    }, onDeviceChanged: { [weak self, weak take, weak candidate] interruption in
                        Task { @MainActor [weak self, weak take, weak candidate] in
                            guard let self, let take, let candidate, !take.finished,
                                  self.active === take, take.mic === candidate else { return }
                            // Covers the narrow ready-to-UI handoff as well as
                            // recording; preparing-only events stay inside start().
                            self.recordMicrophoneNotice(.recordingDeviceDisconnected, timing: .finalFailure,
                                deviceRemovalProven: interruption == .deviceRemoval)
                            self.resolve(take, text: nil, reason: "マイク入力が変更または中断されたため録音を終了しました")
                        }
                    })
                    readyCapture = candidate
                } catch {
                    await candidate.cancelAndWait()
                    if take.mic === candidate { take.mic = nil }
                    guard active === take, phase == .preparing, !take.finished else { throw CancellationError() }
                    if error is CancellationError { throw error }
                    recoveryDisposition = candidate.recoveryDisposition
                    // A missing explicit choice must never become another mic.
                    if error is MicrophoneSelectionError { throw error }
                    let category = (error as? MicrophoneCapture.CaptureError)?.diagnosticCategory ?? (error as? MicrophoneGraphError)?.rawValue ?? ((error as? MicrophoneDevices.DeviceError) == .enumerationFailed ? "enumeration_failed" : "engine_start_failed")
                    let elapsed = preparation.now() - preparationBegan
                    if let route = candidate.routeSnapshot {
                        preparation.recordMicrophone { "mic_prepare_route take=\(take.id.uuidString) attempt=\(attempts) \(route.diagnosticFields)" }
                    }
                    if let format = candidate.formatSnapshot {
                        preparation.recordMicrophone { "mic_prepare_format take=\(take.id.uuidString) attempt=\(attempts) \(format.diagnosticFields)" }
                    }
                    preparation.recordMicrophone { "mic_prepare_failed take=\(take.id.uuidString) attempt=\(attempts) category=\(category) code=\((error as NSError).code) elapsed_ms=\(Int(elapsed * 1_000))" }
                    guard let delay = MicrophoneCapture.retryDelay(for: error, policy: retryPolicy,
                        attempts: attempts, elapsed: elapsed, disposition: recoveryDisposition) else { throw error }
                    status = "マイクの接続準備を待っています…（\(attempts + 1)/\(retryPolicy.maximumAttempts)）"
                    recordMicrophoneNotice(MicrophoneNoticeBinding.state(for: error, disposition: recoveryDisposition),
                        timing: .retryInProgress)
                    try await preparation.waitBeforeRetry(delay)
                }
            }
            guard let capture = readyCapture else { throw MicrophoneCapture.CaptureError.noInput }
            guard active === take, phase == .preparing, !take.finished else {
                await capture.cancelAndWait()
                continuation.finish()
                return
            }
            // No repeated cloud/local recognizer setup while Bluetooth warms up.
            // The stream retains the verified pre-roll until this worker starts.
            take.worker = Task { [weak self, weak take] in
                guard let self, let take, !take.finished, !Task.isCancelled else { return }
                if let consumeAudio = self.preparation.consumeAudio {
                    if let text = await consumeAudio(stream), take.captureDrainedCleanly, !Task.isCancelled {
                        self.resolve(take, text: text, reason: nil, postProcessed: true)
                    }
                } else {
                    await self.transmit(stream, take: take)
                }
            }
            if let route = capture.routeSnapshot {
                preparation.recordMicrophone { "mic_prepare_route take=\(take.id.uuidString) attempt=\(attempts) \(route.diagnosticFields)" }
            }
            if let format = capture.formatSnapshot {
                preparation.recordMicrophone { "mic_prepare_format take=\(take.id.uuidString) attempt=\(attempts) \(format.diagnosticFields)" }
            }
            if let timing = capture.startTimings {
                preparation.recordMicrophone { "mic_prepare_ready take=\(take.id.uuidString) attempts=\(attempts) first_pcm_ms=\(Int(timing.firstBufferDelay * 1_000)) sample_rate=\(String(format: "%.0f", timing.sampleRate)) channels=\(timing.channels)" }
            }
            take.startedAt = Date()
            take.recordingStart = .now
            lastStartupSeconds = take.startedAt?.timeIntervalSince(take.requestedAt)
            phase = .recording
            isRecording = true
            clearMicrophoneNoticeForSuccessfulStart()
            if overlayOwner == take.id { overlayFeedback = .recording }
            take.permissionTask?.cancel()
            take.permissionTask = nil
            if let t = capture.startTimings {
                preparation.recordMicrophone { "mic startup; total=\(String(format: "%.3f", t.total))s prepare=\(String(format: "%.3f", t.microphonePreparation))s engineStart=\(String(format: "%.3f", t.engineStart))s" }
            }
            DiagnosticLog.record("session recording; recognizer=pending; pending=\(finished.count)")
            status = (take.appProfileName.map { "\($0)用プロファイル適用中 — " } ?? "") + "録音中。\(take.transformSelection == nil || take.isFixLastInput ? shortcutChoice.label : (transformShortcut?.label ?? shortcutChoice.label)) でもう一度押すと確定"
            scheduleRecordingTimeout(take)
        } catch {
            if active === take, !take.finished {
                let recoveryMessage = recoveryDisposition.message
                DiagnosticLog.record("microphone start failed: \(recoveryMessage ?? error.localizedDescription)")
                recordMicrophoneNotice(MicrophoneNoticeBinding.state(for: error, disposition: recoveryDisposition),
                    timing: .finalFailure)
                resolve(take, text: nil, reason: Self.microphoneStartFailureMessage(error, disposition: recoveryDisposition))
            }
        }
    }

    private func scheduleRecordingTimeout(_ take: DictationTake) {
        guard active === take, phase == .recording else { return }
        take.scheduleRecordingTimeout { [weak self, weak take] in
            guard let self, let take, self.active === take, self.phase == .recording else { return }
            self.stop()
        }
    }

    func prepareRecognizer(_ take: DictationTake) async throws -> RecognitionMode {
        var actual = take.preferred
        switch take.preferred {
        case .gemini:
            if let key = loadKeyForUse(provider: .gemini) {
                let snapshot = GeminiPrewarmSnapshot(
                    vocabulary: take.vocabulary, style: take.style, japaneseHint: take.japaneseHint,
                    apiKeyFingerprint: GeminiPrewarmSnapshot.fingerprint(apiKey: key))
                take.geminiAttempted = true
                take.geminiStartedAt = Date()
                do {
                    let candidate = try await prewarmer.connectForTake(current: snapshot,
                        enabled: geminiPrewarmEnabled, apiKey: key) { take.cloud = $0 }
                    guard !take.finished, !Task.isCancelled else {
                        candidate.cancel()
                        throw CancellationError()
                    }
                    candidate.onEvent = { [weak self, weak take, weak candidate] event in
                        guard let self, let take, let candidate, take.cloud === candidate, !take.finished else { return }
                        switch event {
                        case .interim, .final:
                            let preview = candidate.assembler.preview
                            take.partialText = preview.text
                            take.previewFinalizedText = preview.finalizedPrefix
                            take.previewVolatileText = preview.volatileTail
                            if take.firstPreviewAt == nil, !take.partialText.isEmpty {
                                take.firstPreviewAt = Date()
                            }
                            if self.active === take {
                                let isFinal: Bool
                                if case .final = event { isFinal = true } else { isFinal = false }
                                self.updatePreview(for: take, isFinal: isFinal)
                            }
                        case .error(let message):
                            if candidate.assembler.exceededFinalBudget {
                                self.resolve(take, text: nil, reason: message)
                                return
                            }
                            take.resetPreviewPublication()
                            DiagnosticLog.record("gemini receiver failure during take")
                        default: break
                        }
                    }
                } catch is CancellationError {
                    take.cloud?.cancel()
                    throw CancellationError()
                } catch {
                    take.cloud?.cancel()
                    DiagnosticLog.record("gemini setup failed; using local for THIS take")
                    take.fellBackToApple = true
                    actual = .local
                }
            } else {
                DiagnosticLog.record("gemini key unavailable; using local for THIS take")
                take.fellBackToApple = true
                actual = .local
            }
        case .amivoice:
            if let key = loadKeyForUse(provider: .amivoice) {
                let connection = makeAmiVoiceConnectionInstance(apiKey: key, engine: amiVoiceEngine, vocabulary: take.vocabulary)
                take.amiVoiceAttempted = true
                take.amiVoiceStartedAt = Date()
                take.amiVoiceEngine = amiVoiceEngine
                take.amiVoice = connection
                connection.onUpdate = { [weak self, weak take, weak connection] preview in
                    guard let self, let take, let connection, take.amiVoice === connection, !take.finished else { return }
                    take.partialText = preview.text
                    take.previewFinalizedText = preview.finalizedPrefix
                    take.previewVolatileText = preview.volatileTail
                    if take.firstPreviewAt == nil, !preview.text.isEmpty {
                        take.firstPreviewAt = Date()
                    }
                    if self.active === take {
                        let isFinal = !preview.finalizedPrefix.isEmpty && preview.volatileTail.isEmpty
                        self.updatePreview(for: take, isFinal: isFinal)
                    }
                }
                connection.onError = { [weak self, weak take, weak connection] error in
                    guard let self, let take, let connection, take.amiVoice === connection, !take.finished else { return }
                    if connection.assembler.exceededFinalBudget || error == .finalBudgetExceeded {
                        self.resolve(take, text: nil, reason: Self.userFacingFailure(error, operation: "音声認識"))
                        return
                    }
                    take.resetPreviewPublication()
                    DiagnosticLog.record("amivoice receiver failure during take; \(AmiVoiceWebSocketConnection.diagnosticFailure(error))")
                }
            } else {
                DiagnosticLog.record("amivoice key unavailable; using local for THIS take")
                take.fellBackToApple = true
                actual = .local
            }
        case .local:
            break
        }
        guard !take.finished, !Task.isCancelled else { throw CancellationError() }
        take.effectiveMode = actual
        scheduleRecordingTimeout(take)
        switch actual {
        case .gemini, .amivoice:
            break
        case .local:
            var recognizer: LocalTranscribing = makeLocalTranscriber()
            take.appleAttempted = true
            take.appleStartedAt = Date()
            take.local = recognizer
            do {
                try await recognizer.start()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !recognizer.requiresSpeechAuthorization else { throw error }
                DiagnosticLog.record("speechAnalyzer start failed; falling back to sfSpeech for THIS take")
                recognizer.cancel()
                try Task.checkCancellation()
                guard !take.finished else { throw CancellationError() }
                recognizer = AppleLocalTranscriber()
                take.local = recognizer
                try await recognizer.start()
            }
            guard !take.finished, !Task.isCancelled else {
                recognizer.cancel()
                throw CancellationError()
            }
            take.local = recognizer
            recognizer.onUpdate = { [weak self, weak take, weak recognizer] update in
                guard let self, let take, let recognizer, take.local === recognizer, !take.finished else { return }
                take.partialText = update.text
                take.previewFinalizedText = update.finalizedPrefix
                take.previewVolatileText = update.volatileTail
                if take.firstPreviewAt == nil, !update.text.isEmpty { take.firstPreviewAt = Date() }
                if self.active === take {
                    self.updatePreview(for: take, isFinal: !update.finalizedPrefix.isEmpty)
                }
            }
        }
        guard !take.finished, !Task.isCancelled else { throw CancellationError() }
        take.usedMode = actual.label
        if active === take {
            usedMode = take.usedMode
            if phase == .recording { status = (take.appProfileName.map { "\($0)用プロファイル適用中 — " } ?? "") + "録音中。\(take.transformSelection == nil || take.isFixLastInput ? shortcutChoice.label : (transformShortcut?.label ?? shortcutChoice.label)) でもう一度押すと確定" }
        }
        if let start = take.startedAt {
            DiagnosticLog.record("recognizer ready; mode=\(actual.rawValue); sinceMic=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        } else {
            DiagnosticLog.record("recognizer ready during microphone initialization; mode=\(actual.rawValue)")
        }
        return actual
    }

    /// STOP transitions the UI to idle before any network await or slow
    /// microphone teardown. Each recording's worker owns its own ASR state.
    func stop() {
        guard phase == .recording, let take = active else { return }
        take.mic?.invalidateVolumeGuard()
        volumeGuard.end(take.id)
        take.resetPreviewPublication()
        active = nil
        phase = .idle
        isRecording = false
        let stoppedAt = Date()
        take.stoppingAt = stoppedAt
        take.recordingTimeout?.cancel()
        // Rapid stop does not imply a transcription failure. Wait for the
        // microphone's final PCM/peak measurement before classifying a quiet tap.
        // Real speech still enters the normal finalization path.
        let recordedSeconds = take.startedAt.map {
            stoppedAt.timeIntervalSince($0)
        } ?? .infinity
        let quickExitCandidate = QuickNoInputPolicy.mayBeQuickExit(seconds: recordedSeconds)
        if overlayOwner == take.id {
            overlayFeedback = quickExitCandidate ? .ending : .processing
            previewText = ""
        }
        status = quickExitCandidate ? "録音を終了しています…" :
            "文字起こしを確定中。録音キーでもう一度押すと次の録音を開始できます"
        DiagnosticLog.record("session stopped; UI idle immediately; background finalization; pending=\(finished.count)")
        take.finalizationTimeout = Task { [weak self, weak take] in
            do { try await Task.sleep(for: .seconds(TranscriptReviewDeadline.totalSeconds)) } catch { return }
            guard let self, let take, !take.finished else { return }
            DiagnosticLog.record("background finalization watchdog; id=\(take.id.uuidString.prefix(8))")
            if let original = take.postProcessOriginal {
                DiagnosticLog.record("postprocess failed; delivering original")
                self.resolve(take, text: original, reason: nil, postProcessed: true)
            } else if let review = take.reviewSession {
                self.resolve(take, text: review.expire(), reason: nil)
            } else {
                self.resolve(take, text: nil, reason: "認識処理が15秒以内に完了しませんでした")
            }
        }
        let capture = take.mic
        take.mic = nil
        if let capture {
            capture.stop(.normal) { [weak self, weak take] losses in
                Task { @MainActor [weak self, weak take] in
                    self?.resumeMicrophoneWarm()
                    guard let self, let take, !take.finished else { return }
                    let pcmBytes = capture.totalPCMBytes
                    let seconds = Double(pcmBytes) / 32_000
                    let peak = capture.sessionPeakAmplitude
                    let evidence = capture.activityEvidence
                    take.acousticEvidence = evidence
                    take.acousticReviewRequired = AudioActivityPolicy.requiresReview(evidence)
                    let hasObservedText = !take.recoverableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let acousticToken: InputDiagnosticEvent.Token
                    switch evidence.classification {
                    case .nearSilence: acousticToken = .nearSilence
                    case .uncertain: acousticToken = .uncertain
                    case .activity: acousticToken = .activity
                    case .unavailable: acousticToken = .unavailable
                    }
                    take.inputDiagnostics?.record(.session, stage: .capture, [
                        .acoustic: .token(acousticToken),
                        .audioFrames: .integer(evidence.frames),
                        .activeFrames: .integer(evidence.activeFrames),
                        .maxRMSPPM: .integer(Int((Double(evidence.maximumFrameRMS) * 1_000_000).rounded())),
                        .modulationPct: .integer(Int((Double(evidence.modulation) * 100).rounded())),
                        .invalidSamples: .integer(evidence.invalidSamples)
                    ])
                    DiagnosticLog.recordMicrophoneEvidence("audio activity; classification=\(evidence.classification.rawValue) frames=\(evidence.frames) active=\(evidence.activeFrames) rms_ppm=\(Int(Double(evidence.maximumFrameRMS) * 1_000_000))")
                    DiagnosticLog.recordMicrophoneEvidence("mic stopped; pcmBytes=\(pcmBytes) audioSeconds=\(String(format: "%.2f", seconds)) peak=\(String(format: "%.4f", peak)) losses=\(losses)")
                    let lostAudio = losses > 0 || take.audioIntegrity.droppedChunks > 0
                    // Audio-loss errors and real transcribed text are never
                    // hidden by the accidental-tap UX.
                    if lostAudio {
                        self.resolve(take, text: nil, reason: "マイクの音声チャンクが欠落しました")
                    } else if QuickNoInputPolicy.shouldSkipRecognition(
                        seconds: recordedSeconds, pcmBytes: pcmBytes, peak: peak,
                        hasText: hasObservedText,
                        audioDropped: lostAudio
                    ) && (evidence.classification == .nearSilence || !AudioDurationPolicy.hasEnoughAudio(pcmBytes: pcmBytes)) {
                        self.resolve(take, text: nil, reason: "音声入力なし", noInput: true)
                    } else if !AudioDurationPolicy.hasEnoughAudio(pcmBytes: pcmBytes) {
                        self.resolve(take, text: nil, reason: "録音が短すぎます（0.1秒未満）")
                    } else if AudioActivityPolicy.shouldDiscardQuietTake(evidence, pcmBytes: pcmBytes,
                                                                         hasTranscript: hasObservedText) {
                        self.resolve(take, text: nil, reason: "音声入力なし", noInput: true)
                    } else {
                        if self.overlayOwner == take.id && self.overlayFeedback == .ending {
                            self.overlayFeedback = .processing
                        }
                        take.captureDrainedCleanly = true
                        take.continuation?.finish()
                    }
                }
            }
        } else {
            take.acousticReviewRequired = true
            take.continuation?.finish()
        }
    }

    /// A failed cloud transcription may be retried with
    /// Apple's on-device recognizer using the SAME audio data. This does not
    /// block the next recording; the result still waits for its delivery slot.
    private func retryLocally(_ take: DictationTake) async throws -> String {
        try Task.checkCancellation()
        guard !take.finished else { throw CancellationError() }
        guard !take.audioBackup.isEmpty else { throw AppError.connectionLost }
        guard take.audioBackup.count <= DictationTake.maximumRescueBytes else { throw AppError.localRecoveryTooLong }
        // Only one fallback recognizer at a time. A wave of failed Gemini
        // sessions must not launch eight heavyweight local ASR tasks at once.
        let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(7))
        while localRecoveryBusy {
            try Task.checkCancellation()
            guard !take.finished, ContinuousClock.now < recoveryDeadline else {
                throw AppError.localRecoveryBusy
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        try Task.checkCancellation()
        guard !take.finished else { throw CancellationError() }
        localRecoveryBusy = true
        defer { localRecoveryBusy = false }
        // Never bring up a permission prompt during a following dictation.
        // The legacy backend requires a prior grant; SpeechAnalyzer does not.
        let local = makeLocalTranscriber()
        guard !local.requiresSpeechAuthorization ||
                SFSpeechRecognizer.authorizationStatus() == .authorized else {
            DiagnosticLog.record("local recovery unavailable; speech permission not granted")
            throw AppleLocalTranscriber.LocalError.permission
        }
        // If a deadline cancels this worker while start() awaits macOS, the
        // take may already have released its resources. Always close this
        // local owner as well, including recognizers that finish starting late.
        defer { local.cancel() }
        take.local = local
        take.fellBackToApple = true
        take.appleAttempted = true
        take.appleStartedAt = Date()
        take.usedMode = Self.localRescueModeLabel(for: take.effectiveMode ?? take.preferred)
        try await local.start()
        try Task.checkCancellation()
        guard !take.finished else { throw CancellationError() }
        let length = take.audioBackup.count
        var offset = 0
        while offset < length {
            try Task.checkCancellation()
            let end = min(offset + 3_200, length)
            try await local.appendRecoveryPCM(take.audioBackup, range: offset..<end)
            take.appleAudioBytes += end - offset
            offset = end
        }
        let result = try await local.endAudioAndAwaitFinal()
        DiagnosticLog.record("local recovery succeeded; chars=\(result.count)")
        return result
    }

    static func localRescueModeLabel(for failedEngine: RecognitionMode) -> String {
        switch failedEngine {
        case .gemini: return "Appleオンデバイス（Gemini失敗時の救済）"
        case .amivoice: return "Appleオンデバイス（AmiVoice失敗時の救済）"
        case .local: return "Appleオンデバイス（救済）"
        }
    }

    private func transmit(_ stream: AsyncStream<Data>, take: DictationTake) async {
        do {
            let mode = try await prepareRecognizer(take)
            let result: String
            switch mode {
            case .gemini:
                guard let remote = take.cloud else { throw AppError.connectionLost }
                result = try await take.transcribeLive(
                    stream,
                    cloudEngine: .gemini,
                    budgetExceeded: { remote.assembler.exceededFinalBudget },
                    send: remote.sendAudio,
                    finish: {
                        try await remote.endAudio()
                        return try await remote.awaitFinal()
                    },
                    rescue: { try await self.retryLocally(take) }
                )
            case .amivoice:
                guard let amiVoice = take.amiVoice else { throw AppError.connectionLost }
                result = try await take.transcribeLive(
                    stream,
                    cloudEngine: .amivoice,
                    budgetExceeded: { amiVoice.assembler.exceededFinalBudget },
                    send: amiVoice.sendAudio,
                    finish: { try await amiVoice.endAudioAndAwaitFinal() },
                    rescue: { try await self.retryLocally(take) }
                )
            case .local:
                guard let recognizer = take.local else { throw AppError.connectionLost }
                for await chunk in stream {
                    guard !take.finished, !Task.isCancelled else { return }
                    take.audioBackup.append(chunk)
                    try recognizer.appendPCM16(chunk)
                    take.appleAudioBytes += chunk.count
                }
                guard !take.finished, !Task.isCancelled else { return }
                guard take.audioIntegrity.droppedChunks == 0 else { throw AppError.audioDropped }
                result = try await recognizer.endAudioAndAwaitFinal()
                take.successfulEngine = .local
            }
            guard !take.finished, !Task.isCancelled else { return }
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppleLocalTranscriber.LocalError.empty(nil)
            }
            if take.voiceCommandsEnabled, take.transformSelection == nil, !take.isFixLastInput {
                take.commandCandidate = VoiceCommandMatcher.match(text: result, enabled: take.enabledVoiceCommands)
            }
            let adopted = take.adoptFinalText(result)
            let original = take.commandCandidate == nil && take.transformSelection == nil && take.preferred == .gemini && take.style == .agent
                ? AgentInstructionFormatting.format(adopted) : adopted
            // Only an actually confirmed primary result can survive a review
            // timeout. Pending/interim text never takes this route.
            let review = DictationReviewSession(
                originalText: original, engine: take.successfulEngine, options: take.options,
                stoppedAt: take.stoppingAt, audio: take.audioBackup,
                vocabulary: take.vocabulary, style: take.style, japaneseHint: take.japaneseHint,
                context: take.capturedContext)
            take.reviewSession = review
            let output = await review.run { [weak self, weak take] in
                guard let self, let take, !take.finished else { return }
                if self.overlayOwner == take.id, self.active == nil { self.overlayFeedback = .checking }
                if self.active == nil { self.status = "追加チェック中。次の録音は開始できます" }
            }
            guard !take.finished, !Task.isCancelled else { return }
            resolve(take, text: output, reason: nil)
        } catch {
            guard !take.finished, !Task.isCancelled else { return }
            DiagnosticLog.record("recognition failure; category=\(Self.failureCategory(error))")
            resolve(take, text: nil, reason: Self.userFacingFailure(error, operation: "音声認識"))
        }
    }

    /// Finish only this take. This MUST NOT reset a newer active recording.
    private func resolve(_ take: DictationTake, text: String?, reason: String?,
                         noInput: Bool = false, postProcessed: Bool = false) {
        guard !take.finished else { return }
        take.mic?.invalidateVolumeGuard()
        volumeGuard.end(take.id)
        // Review, post-processing and their deadline fallbacks converge here.
        var text = text.map(take.adoptFinalText)
        var disposition: Disposition = .text
        if let command = take.commandCandidate {
            let same = text.flatMap { VoiceCommandMatcher.match(text: $0, enabled: take.enabledVoiceCommands) } == command
            let blocked = VoiceCommandGate.blockedReason(acousticReviewRequired: take.acousticReviewRequired,
                reviewStatus: take.review?.status, suppressed: take.automaticDeliverySuppressed,
                shouldPaste: take.shouldPaste, sameCommand: same)
            if let blocked { disposition = .blockedCommand(command, blocked) }
            else { disposition = .command(command) }
            DiagnosticLog.record("voice_command take=\(take.id) command=\(command.rawValue) gate=\(blocked ?? "clear") phase=classification")
        }
        let isCommand = take.commandCandidate != nil
        let skipped = !finished.pending.contains(take.id) || DictationDelivery.skipped(
            suppressed: take.automaticDeliverySuppressed,
            requiresReview: take.review?.status == .needsReview,
            acousticReviewRequired: take.acousticReviewRequired, shouldPaste: take.shouldPaste) != nil
        if !isCommand, !postProcessed, let original = text, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           PostProcessingPolicy.shouldApply(mode: take.postProcessMode, enabled: take.postProcessEnabled,
               style: take.style, isTransform: take.transformSelection != nil, skipped: skipped, noInput: noInput) {
            guard take.postProcessOriginal == nil else { return }
            take.postProcessOriginal = original
            take.postProcessTask = Task { [weak self, weak take] in
                guard let self, let take, !take.finished else { return }
                var output = original
                do {
                    let budget = TranscriptReviewDeadline.available(stoppedAt: take.stoppingAt, now: Date())
                    guard budget > 0, let key = KeychainStore.loadForUse() else { throw AppError.noKey }
                    let result = try await GeminiTextTransformer.postProcess(
                        text: original, mode: take.postProcessMode, apiKey: key, timeout: budget)
                    guard !take.finished, !Task.isCancelled else { return }
                    let adoption = PostProcessingPolicy.adoption(original: original, processed: result.text)
                    output = adoption.text
                    if let reason = adoption.rejection {
                        DiagnosticLog.record("postprocess rejected \(reason.rawValue)")
                    } else {
                        DiagnosticLog.record("postprocess applied mode=\(take.postProcessMode.rawValue)")
                    }
                    if let usage = result.usage {
                        DiagnosticLog.record("gemini postprocess usage; promptTokens=\(usage.promptTokens.map(String.init) ?? "unknown") responseTokens=\(usage.responseTokens.map(String.init) ?? "unknown") totalTokens=\(usage.totalTokens)")
                    }
                } catch {
                    guard !take.finished, !Task.isCancelled else { return }
                    DiagnosticLog.record("postprocess failed; delivering original")
                }
                self.resolve(take, text: output, reason: reason, noInput: noInput, postProcessed: true)
            }
            return
        }
        // Freeze the exact deliverable before both ordered completion and history.
        // Save-only, suppressed, review-held, stale and no-input takes never expand.
        let usage = take.usageSamples(recognizedText: text, cancelled: noInput || take.automaticDeliverySuppressed || reason == "録音をキャンセルしました")
        if isCommand { text = nil }
        if take.transformSelection == nil, !noInput, finished.pending.contains(take.id), let original = text, !original.isEmpty,
           DictationDelivery.skipped(suppressed: take.automaticDeliverySuppressed,
               requiresReview: take.review?.status == .needsReview,
               acousticReviewRequired: take.acousticReviewRequired, shouldPaste: take.shouldPaste) == nil {
            let expansion = SnippetExpander.expansion(original, rules: take.snippets, date: Date()) {
                NSPasteboard.general.string(forType: .string)
            }
            text = expansion.text
            if expansion.budgetExhausted { DiagnosticLog.record("snippet expansion stopped reason=byte_budget") }
        }
        let partial = take.recoverableText
        let actualEngine: InputDiagnosticEvent.Token
        switch take.successfulEngine {
        case .gemini: actualEngine = .gemini
        case .amivoice: actualEngine = .amivoice
        case .local: actualEngine = .apple
        case nil: actualEngine = .unknown
        }
        take.inputDiagnostics?.record(.session, stage: .result, [
            .engine: .token(actualEngine),
            .recognizedUTF16: .integer(text?.utf16.count ?? 0),
            .outcome: .token(noInput ? .skipped : (text?.isEmpty == false ? .ok : .unavailable))
        ])
        if take.inputDiagnostics != nil {
            take.resolvedAtUptime = ProcessInfo.processInfo.systemUptime
        }
        take.finished = true
        if let start = take.startedAt, let stop = take.stoppingAt, text != nil {
            let first = take.firstPreviewAt.map { String(format: "%.2f", $0.timeIntervalSince(start)) } ?? "未取得"
            lastMetrics = "初回表示 \(first)秒 / 停止→確定 \(String(format: "%.2f", Date().timeIntervalSince(stop)))秒"
        }
        if active === take {
            active = nil
            phase = .idle
            isRecording = false
            // Preparing was cancelled or capture failed; no pending processing.
            if overlayOwner == take.id && !noInput { hideOverlay() }
            previewText = ""
        }
        let accepted = finished.finish(take.id, result: Completion(
            disposition: disposition, text: text, reason: reason, partial: isCommand ? "" : partial, noInput: noInput))
        // Persist now, even if an older delivery is awaiting its receipt. An
        // app exit must not discard a completed result waiting in the sender.
        var sweptAfterRemember = false
        if accepted, !isCommand, !noInput, take.transformSelection == nil {
            if let text, !text.isEmpty {
                take.historyRecordID = remember(text, isPartial: false, delivery: .pending,
                                                engine: take.usedMode, review: take.review,
                                                recordedAt: take.requestedAt)
                sweptAfterRemember = retainedAudio.sweepIsReusable
            } else if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                take.historyRecordID = remember(partial, isPartial: true, delivery: .recognitionInterrupted,
                                                engine: take.usedMode, review: take.review,
                                                recordedAt: take.requestedAt)
                sweptAfterRemember = retainedAudio.sweepIsReusable
            }
        }
        preparation.recordSession { "session resolved; success=\(text?.isEmpty == false) accepted=\(accepted) noInput=\(noInput) pending=\(finished.count)" }
        // Show a brief, neutral acknowledgement immediately, even if an
        // older take is still finalizing in the ordered delivery buffer.
        if noInput { showCompletionFeedback(.noInput, for: take.id) }
        // Safety first: persist recoverable text before posting input events.
        // Usage telemetry is secondary and must not delay those key events.
        deliverOrderedResults()
        if noInput && active == nil && overlayOwner == take.id { status = "音声入力なし" }
        usageStore.append(engineEvents: usage.engines, tokenEvents: usage.tokens)
        if retainAudioEnabled, take.retainAudioGeneration == retentionGeneration,
           let id = take.historyRecordID, let record = historyStore.entries.first(where: { $0.id == id }) {
            sweptAfterRemember = retainedAudio.write(pcm: take.audioBackup, record: record, history: &historyStore,
                                                      followingSweep: sweptAfterRemember)
        }
        if sweptAfterRemember && retainedAudio.sweepIsReusable { updateRetentionStatus() }
        else { refreshRetainedAudio() }
        let stoppingCapture = take.mic
        take.releaseResources()
        if let stoppingCapture {
            stoppingCapture.stop(.cancelled) { [weak self] _ in
                Task { @MainActor [weak self] in self?.resumeMicrophoneWarm() }
            }
        } else { resumeMicrophoneWarm() }
        scheduleWarmGemini()
    }

    private func deliverOrderedResults() {
        guard deliveryWorker == nil else { return }
        deliveryWorker = Task { [weak self] in
            guard let self else { return }
            defer { self.deliveryWorker = nil }
            while true {
                let ready = self.finished.drain()
                guard !ready.isEmpty else { return }
                for (id, result) in ready {
                    guard let take = self.inFlight[id] else { continue }
                    // Retain the whole ready prefix in inFlight while awaiting
                    // receipts, so rebasing reaches finished and recording takes.
                    await self.deliver(result, take: take)
                    self.inFlight.removeValue(forKey: id)
                    self.presentDeferredFeedbackIfIdle()
                }
            }
        }
    }

    private func deliver(_ result: Completion, take: DictationTake) async {
        let id = take.id
        // AX reads and receipt polling only collect bounded in-memory evidence.
        // Write it once, after input and all dependent-target decisions finish.
        defer { take.inputDiagnostics?.finish() }
        take.inputDiagnostics?.record(.session, stage: .preflight, [
            .queueWaitMS: .integer(take.resolvedAtUptime.map { InputDiagnosticTrace.milliseconds(since: $0) } ?? 0),
            .shouldPaste: .flag(take.shouldPaste),
            .suppressed: .flag(take.automaticDeliverySuppressed),
            .requiresReview: .flag(take.review?.status == .needsReview)
        ])
        if take.transformSelection != nil {
            await deliverTransform(result, take: take)
            return
        }
        switch result.disposition {
        case .command(let command):
            await deliverCommand(command, blockedReason: nil, take: take)
            return
        case .blockedCommand(let command, let reason):
            await deliverCommand(command, blockedReason: reason, take: take)
            return
        case .text: break
        }
        if result.noInput {
            let cancelled = result.reason == "録音をキャンセルしました"
            take.inputDiagnostics?.record(.result, stage: .result, [
                .outcome: .token(cancelled ? .cancelled : .skipped),
                .reason: .reason(cancelled ? "delivery_cancelled_before_post" : "no_input"), .eventsPosted: .flag(false)
            ])
            DiagnosticLog.record("empty rapid recording discarded; id=\(id.uuidString.prefix(8))")
            return
        }
        guard let text = result.text, !text.isEmpty else {
            take.inputDiagnostics?.record(.result, stage: .result, [
                .outcome: .token(take.automaticDeliverySuppressed ? .cancelled : .skipped),
                .reason: .reason(take.automaticDeliverySuppressed ? "system_suppressed" : "recognition_failed"), .eventsPosted: .flag(false)
            ])
            let recovered = result.partial.trimmingCharacters(in: .whitespacesAndNewlines)
            if !recovered.isEmpty, take.historyRecordID == nil {
                _ = remember(recovered, isPartial: true, delivery: .recognitionInterrupted,
                             engine: take.usedMode, review: take.review)
            }
            DiagnosticLog.record("session failure; id=\(id.uuidString.prefix(8)); reason=\(Self.safeFailureCode(result.reason))")
            showCompletionFeedback(.failed, for: id)
            if active == nil { status = result.reason ?? "文字起こしに失敗しました（履歴を確認）" }
            return
        }
        let recordID = take.historyRecordID ?? remember(text, isPartial: false, delivery: .pending,
                                                        engine: take.usedMode, review: take.review,
                                                        recordedAt: take.requestedAt)
        let outcome: DictationDelivery.Outcome
        var completionFeedback: OverlayFeedback = .saved
        if let skipped = DictationDelivery.skipped(suppressed: take.automaticDeliverySuppressed,
                                                  requiresReview: take.review?.status == .needsReview,
                                                  acousticReviewRequired: take.acousticReviewRequired,
                                                  shouldPaste: take.shouldPaste) {
            outcome = skipped
            if take.acousticReviewRequired, !take.automaticDeliverySuppressed,
               take.shouldPaste, skipped.delivery == .reviewRequired, !text.isEmpty {
                let rescue = DictationDelivery.HeldCopy(copied: TextInsertion.copy(text))
                completionFeedback = rescue.feedback
                DiagnosticLog.recordMicrophoneEvidence("held_text_rescued take=\(id.uuidString.prefix(8)) chars=\(text.count) \(rescue.diagnostic)")
            }
            take.inputDiagnostics?.record(.result, stage: .result, [
                .outcome: .token(take.automaticDeliverySuppressed ? .cancelled : .skipped),
                .reason: .reason(take.automaticDeliverySuppressed ? "system_suppressed"
                    : (take.acousticReviewRequired ? "acoustic_review_required"
                        : (take.review?.status == .needsReview ? "review_required" : "automatic_input_disabled"))),
                .eventsPosted: .flag(false)
            ])
        } else {
            deliveringTakeID = id
            let report = await postingGate.post(.dictation(text), from: .take(take), finalize: { report in
                if let receipt = report.receipt, receipt.proof.retainsContentEvidence {
                    self.postingGate.lastDeliveryAnchor = LastDeliveryAnchor(receipt: receipt, sourceRecordID: recordID)
                }
            }) {
                !take.automaticDeliverySuppressed && self.inFlight[id] === take
            }
            deliveringTakeID = nil
            outcome = DictationDelivery.classify(report)
            DiagnosticLog.record("delivery resolved; id=\(id.uuidString.prefix(8)); outcome=\(outcome.delivery.rawValue); reason=\(report.reason)")
        }
        if let recordID { outcome.updateSavedRecord(recordID, in: &historyStore) }
        let saved = historyStore.isSaved(recordID)
        if !saved && completionFeedback == .saved { completionFeedback = .notSaved }
        if outcome.submitted, let stoppedAt = take.stoppingAt {
            lastStopToInputSeconds = Date().timeIntervalSince(stoppedAt)
        }
        if !deferredFeedback.enqueueIfSuppressed(outcome, id: id, owner: overlayOwner, recording: active != nil) {
            showCompletionFeedback(outcome.submissionFeedback ?? completionFeedback, for: id)
        }
        if active == nil {
            let message = outcome.delivery == .attemptedUnconfirmed ? OverlayFeedback.sentUnconfirmed.message : outcome.detail
            status = (saved ? message : outcome.historyInsertionTitle + "。文字起こしは未保存です。") + (take.review?.status == .incomplete ? " 追加チェックは未完了です。" : "")
        }
    }

    /// Reconcile against the target actually used by this delivery. Also keep
    /// unverified identities for pending takes with a different/nil start target:
    /// their own current-target capture must not bypass a predecessor's latch.
    private func reconcileDelivery(_ report: TextInsertion.Report, sourceTakeID: UUID? = nil) {
        if textOperationRunning, let target = report.unverifiedTarget {
            textOperationUnverifiedTargets.append(target)
        }
        for other in inFlight.values where other.id != sourceTakeID {
            Self.reconcileDelivery(report, sourceTakeID: sourceTakeID, into: other)
        }
    }

    /// Apply one source report to a pending take before advancing the sender.
    static func reconcileDelivery(_ report: TextInsertion.Report, sourceTakeID: UUID?, into other: DictationTake) {
        let unverifiedTarget = report.unverifiedTarget
        if let unverifiedTarget { other.unverifiedInputTargets.append(unverifiedTarget) }
        if let settled = report.settledUnconfirmedPredecessor {
            other.settledUnconfirmedInputTargets.append(settled)
        }
        let candidate = other.target
        if other.transformSelection == nil, let target = candidate {
            other.target = report.reconciled(target, sourceTakeID: sourceTakeID, candidateTakeID: other.id,
                                            diagnostics: other.inputDiagnostics, recaptureBeforeDelivery: true)
        }
        let newlyBlocked = candidate?.isBlocked == false && other.target?.isBlocked == true
        if unverifiedTarget != nil || newlyBlocked {
            let diagnostics = other.inputDiagnostics ?? report.diagnostics
            diagnostics?.record(.reconcileAttachment, stage: .reconcile, [
                .sourceTake: sourceTakeID.map { .shortIdentifier($0) } ?? .token(.unknown),
                .candidateTake: .shortIdentifier(other.id),
                .sourceEventsPosted: .flag(report.eventsPosted),
                .sourceReceiptPresent: .flag(report.receipt != nil),
                .candidateState: .token(other.finished ? .finished : .recording),
                .sourceResultUptimeMS: .integer(report.resultUptimeMS),
                .candidateCaptureUptimeMS: candidate.map {
                    .integer(InputDiagnosticTrace.uptimeMilliseconds($0.capturedAt))
                } ?? .token(.unknown)
            ])
        }
    }

    enum GeneratedOperation: String, CaseIterable {
        case voiceTransform, fixLastInput, selectionTranslation, presetChain

        @MainActor func save(_ text: String, final: Bool, report: TextInsertion.Report?,
                             in history: inout TranscriptHistoryStore) {
            guard final, report?.outcome != .verifiedInserted else { return }
            let outcome = report.map(DictationDelivery.classify)
            history.remember(text, isPartial: false, delivery: outcome?.delivery ?? .blockedFocus,
                engine: GeminiTransformWire.model, kind: rawValue, deliveryDetail: outcome?.detail ?? "操作の中断により未送信です。",
                preserveWhitespace: true)
        }
    }

    private func saveGeneratedResult(_ text: String, kind: GeneratedOperation, final: Bool = true,
                                     report: TextInsertion.Report?) {
        kind.save(text, final: final, report: report, in: &historyStore)
        refreshRetainedAudio()
    }

    private func deliverCommand(_ command: VoiceCommandID, blockedReason: String?, take: DictationTake) async {
        let reason = blockedReason ?? VoiceCommandGate.blockedReason(
            acousticReviewRequired: take.acousticReviewRequired, reviewStatus: take.review?.status,
            suppressed: take.automaticDeliverySuppressed, shouldPaste: take.shouldPaste, sameCommand: true)
        func feedback(_ value: OverlayFeedback, _ message: String) {
            showCompletionFeedback(value, for: take.id)
            if OverlayFeedback.mayUpdate(owner: overlayOwner, resolved: take.id, newRecordingActive: active != nil) {
                status = message
            }
        }
        if let reason {
            DiagnosticLog.record("voice_command take=\(take.id) command=\(command.rawValue) gate=\(reason) phase=execution events_posted=false")
            feedback(.commandBlocked, "コマンドとして実行できませんでした" + Self.commandReasonSuffix(reason))
            return
        }
        if command == .cancelTake {
            DiagnosticLog.record("voice_command take=\(take.id) command=\(command.rawValue) gate=clear outcome=cancelled events_posted=false")
            feedback(.commandCancelled, command.completionMessage)
            return
        }
        deliveringTakeID = take.id
        let report = await postingGate.post(.command(command), from: .take(take)) {
            !take.automaticDeliverySuppressed && self.inFlight[take.id] === take
        }
        deliveringTakeID = nil
        DiagnosticLog.record("voice_command take=\(take.id) command=\(command.rawValue) gate=\(report.reason) outcome=\(report.outcome.diagnosticOutcome.rawValue) events_posted=\(report.eventsPosted)")
        if report.outcome == .verifiedInserted {
            feedback(command == .newline ? .commandNewline : .commandParagraph, command.completionMessage)
        } else if report.reason == "posting_busy" {
            feedback(.commandBlocked, DictationDelivery.postingBusyDetail)
        } else {
            feedback(.commandFailed, "コマンドの入力を確認できませんでした" + Self.commandReasonSuffix(report.reason)
                     + "。入力先を確認してください。")
        }
    }

    /// Diagnostic tokens are translated only when presenting command feedback.
    /// Unknown reasons leave the message useful without exposing internal text.
    static func commandReasonSuffix(_ token: String) -> String {
        let reason: String
        switch token {
        case "suppressed": reason = "自動入力を停止しました"
        case "acoustic_review_required": reason = "音声の確認が必要です"
        case "review_required": reason = "認識結果の確認が必要です"
        case "review_incomplete": reason = "認識結果の確認が完了していません"
        case "review_command_mismatch": reason = "確認後のコマンドが一致しません"
        case "automatic_input_disabled": reason = "自動入力が無効です"
        case "delivery_cancelled_before_post": reason = "入力前に取り消しました"
        case "delivery_cancelled_after_partial_post": reason = "一部の入力後に取り消しました"
        case "delivery_cancelled_after_post": reason = "入力後の確認を取り消しました"
        case "accessibility_not_granted": reason = "アクセシビリティの許可がありません"
        case "post_event_permission_missing": reason = "キー入力の許可がありません"
        case "empty_typing_payload": reason = "入力する内容がありません"
        case "target_not_captured", "target_unavailable_at_delivery": reason = "現在の入力先を取得できませんでした"
        case "secure_text_field": reason = "現在の入力先がパスワード欄です"
        case "current_target_not_text_input": reason = "現在の入力先がテキスト入力欄ではありません"
        case "command_baseline_unavailable", "field_value_unavailable_on_recheck":
            reason = "入力先の内容を確認できませんでした"
        case "field_value_or_selection_changed": reason = "入力先の内容または選択範囲が変わりました"
        case "event_source_unavailable", "keyboard_event_unavailable":
            reason = "キー入力を準備できませんでした"
        case "posted_without_observable_edit", "posted_receipt_timeout":
            reason = "送信した入力を確認できませんでした"
        case "active_app_changed", "posted_then_active_app_changed":
            reason = "入力先のアプリが変わりました"
        case "focused_field_changed", "posted_then_focused_field_changed":
            reason = "入力欄が変わりました"
        case "focused_window_changed", "posted_then_focused_window_changed":
            reason = "入力先のウインドウが変わりました"
        case "marker_selection_changed", "caret_or_selection_changed", "posted_then_caret_or_selection_changed":
            reason = "カーソル位置または選択範囲が変わりました"
        case "prior_input_unverified", "posted_then_prior_input_unverified":
            reason = "直前の入力を確認できませんでした"
        case "frontmost_application_unavailable", "posted_then_frontmost_application_unavailable",
             "focused_element_unavailable_on_recheck", "posted_then_focused_element_unavailable_on_recheck",
             "focused_window_invalid_on_recheck", "posted_then_focused_window_invalid_on_recheck",
             "focused_window_unavailable_on_recheck", "posted_then_focused_window_unavailable_on_recheck",
             "focused_element_owner_changed", "posted_then_focused_element_owner_changed",
             "focused_element_owner_unavailable", "posted_then_focused_element_owner_unavailable",
             "captured_selection_invalid", "posted_then_captured_selection_invalid",
             "selection_value_invalid_on_recheck", "posted_then_selection_value_invalid_on_recheck",
             "selection_unavailable_on_recheck", "posted_then_selection_unavailable_on_recheck",
             "focus_verification_failed", "posted_then_focus_verification_failed":
            reason = "入力先の状態を確認できませんでした"
        default: return ""
        }
        return "（\(reason)）"
    }

    private func deliverTransform(_ result: Completion, take: DictationTake) async {
        guard !result.noInput else { return }
        guard !take.automaticDeliverySuppressed,
              take.review?.status != .needsReview, !take.acousticReviewRequired,
              let instruction = result.text, !instruction.isEmpty,
              let selected = take.transformSelection else {
            showCompletionFeedback(.transformFailed, for: take.id)
            if active == nil { status = result.reason ?? "変換の指示を確認できませんでした。選択範囲は変更していません。" }
            return
        }
        do {
            guard let key = KeychainStore.loadForUse() else { throw AppError.noKey }
            if active == nil && overlayOwner == take.id {
                overlayDismissal?.cancel()
                overlayDismissal = nil
                overlayFeedback = .transforming
                status = "選択テキストを変換中…"
            }
            let output = try await GeminiTextTransformer.transform(selectedText: selected, instruction: instruction, apiKey: key, preserveFullSelection: take.isFixLastInput)
            if let usage = output.usage {
                DiagnosticLog.record("gemini transform usage; promptTokens=\(usage.promptTokens.map(String.init) ?? "unknown") responseTokens=\(usage.responseTokens.map(String.init) ?? "unknown") totalTokens=\(usage.totalTokens)")
            }
            let kind: GeneratedOperation = take.isFixLastInput ? .fixLastInput : .voiceTransform
            guard !take.automaticDeliverySuppressed, !Task.isCancelled else {
                saveGeneratedResult(output.text, kind: kind, report: nil)
                return
            }
            // The source selection stays fixed for recognition/transformation.
            // Delivery follows the current target, including fix-last-input;
            // its initial anchor eligibility was checked before recording.
            let sourceRecordID = postingGate.lastDeliveryAnchor?.sourceRecordID
            deliveringTakeID = take.id
            let report = await postingGate.post(.dictation(output.text), from: .take(take), finalize: { report in
                if take.isFixLastInput, let receipt = report.receipt, receipt.proof.retainsContentEvidence {
                    self.postingGate.lastDeliveryAnchor = LastDeliveryAnchor(receipt: receipt, sourceRecordID: sourceRecordID)
                }
            }) {
                !take.automaticDeliverySuppressed && self.inFlight[take.id] === take
            }
            deliveringTakeID = nil
            saveGeneratedResult(output.text, kind: kind, report: report)
            let verified = report.outcome == .verifiedInserted
            let copied = !verified && TextInsertion.copy(output.text)
            showCompletionFeedback(verified ? .sent : (copied ? .transformCopied : .transformFailed), for: take.id)
            if active == nil {
                status = verified ? "選択テキストの変換を反映しました" : (copied ? "変換結果をクリップボードにコピーしました。入力先を確認してください。" : "変換結果をコピーできませんでした。入力先と権限を確認してください。")
            }
        } catch {
            showCompletionFeedback(.transformFailed, for: take.id)
            if active == nil { status = "選択テキストの変換に失敗しました。選択範囲は変更していません。" }
        }
    }

    /// Both preview styles publish the same policy-approved snapshot. Raw take
    /// and assembler state remain available to finalization and recovery throughout.
    private func updatePreview(for take: DictationTake, isFinal: Bool) {
        guard active === take, phase == .recording, !take.finished, take.stoppingAt == nil else { return }
        guard AudioActivityPolicy.mayShowInterim(take.mic?.activityEvidence ?? take.acousticEvidence) else {
            take.resetPreviewPublication()
            previewText = ""
            return
        }
        take.previewPublicationTask?.cancel()
        take.previewPublicationTask = nil
        let now = ProcessInfo.processInfo.systemUptime
        let decision = isFinal ? take.startupPreview.final(take.partialText)
            : take.startupPreview.interim(take.partialText, at: now)
        if case .publish = decision {
            publishPreview(for: take)
        } else if let deadline = take.startupPreview.nextPublicationAt {
            let generation = take.startupPreview.generation
            take.previewPublicationTask = Task { @MainActor [weak self, weak take] in
                do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) }
                catch { return }
                guard let self, let take, !Task.isCancelled, self.active === take,
                      self.phase == .recording, !take.finished, take.stoppingAt == nil,
                      AudioActivityPolicy.mayShowInterim(take.mic?.activityEvidence ?? take.acousticEvidence) else { return }
                if case .publish = take.startupPreview.tick(at: ProcessInfo.processInfo.systemUptime, generation: generation) {
                    self.publishPreview(for: take)
                }
            }
        }
    }

    private func publishPreview(for take: DictationTake) {
        previewFinalizedText = take.previewFinalizedText
        previewVolatileText = take.previewVolatileText
        previewText = take.partialText
    }

    /// Feedback never claims that the receiving app accepted synthetic key events.
    /// Completion from an older take cannot replace a newer recording overlay.
    private func showCompletionFeedback(_ feedback: OverlayFeedback, for id: UUID) {
        guard OverlayFeedback.mayUpdate(owner: overlayOwner, resolved: id,
                                        newRecordingActive: active != nil) else { return }
        overlayFeedback = feedback
        overlayDismissal?.cancel()
        overlayDismissal = Task { [weak self] in
            let hold: Int
            switch feedback {
            case .notSaved, .heldForReview, .transformCopied, .sentUnconfirmed, .deferredUnsent, .deferredPartial, .deferredUnconfirmed: hold = 3_000
            case .noInput: hold = 330
            case .failed, .transformFailed, .commandBlocked, .commandFailed: hold = 1_000
            default: hold = 520
            }
            do { try await Task.sleep(for: .milliseconds(hold)) } catch { return }
            guard let self, self.overlayOwner == id, self.active == nil else { return }
            self.hideOverlay()
        }
    }

    private func presentDeferredFeedbackIfIdle() {
        guard let (id, feedback, summary) = deferredFeedback.next(owner: overlayOwner, recording: active != nil,
                                                         pendingTakes: !inFlight.isEmpty) else { return }
        overlayOwner = id
        deferredSummary = summary
        showCompletionFeedback(feedback, for: id)
        onShowPreview?()
    }

    private func hideOverlay() {
        overlayDismissal?.cancel()
        overlayDismissal = nil
        overlayOwner = nil
        overlayFeedback = .hidden
        deferredSummary = nil
        onHidePreview?()
        // Let any synchronous transition install its new owner before draining.
        Task { @MainActor [weak self] in self?.presentDeferredFeedbackIfIdle() }
    }

    private static func safeFailureCode(_ reason: String?) -> String {
        // Failure strings can carry a platform error; never log user speech.
        reason == nil ? "none" : "recognition_or_capture"
    }

    func discard() {
        guard let take = active else { return }
        preparation.recordSession { "session discarded by user" }
        resolve(take, text: nil, reason: "録音をキャンセルしました", noInput: true)
    }

    /// Never paste delayed transcripts after sleep, user switch or shutdown.
    func interruptForSystemEvent(_ reason: String) {
        postingGate.interrupt()
        meetingSession?.interrupt(reason)
        cancelBenchRecording?()
        cancelReplay()
        cancelTextOperation()
        let outstanding = Array(inFlight.values)
        // Also suppress already-finalized results waiting behind an older take.
        // Mark ALL before resolving any: resolve() drains the completion queue.
        for take in outstanding {
            take.automaticDeliverySuppressed = true
            if take.finished, let recordID = take.historyRecordID {
                updateRemembered(recordID,
                                 delivery: take.id == deliveringTakeID ? .interruptedDelivery : .cancelledDelivery,
                                 detail: take.id == deliveringTakeID
                                    ? "システム中断が発生しました。再送の前に入力先を確認してください。"
                                    : "システム中断により、待機中の自動入力を中止しました。")
            }
        }
        // Mark failed without performing automatic paste or blocking on ASR.
        for take in outstanding where !take.finished {
            resolve(take, text: nil, reason: reason)
        }
        hideOverlay()
        status = reason
    }

    static func failureCategory(_ error: Error) -> String {
        if let e = error as? GeminiLiveConnection.ConnectionError {
            switch e {
            case .finalBudgetExceeded: return "gemini.final_budget"
            case .badURL: return "gemini.bad_url"
            case .setup: return "gemini.setup"
            case .disconnected: return "gemini.disconnected"
            case .noFinal: return "gemini.no_final"
            case .stalled: return "gemini.stalled"
            case .finalizationTimeout: return "gemini.finalization_timeout"
            }
        }
        if let e = error as? AmiVoiceWebSocketConnection.ConnectionError {
            switch e {
            case .badURL: return "amivoice.bad_url"
            case .setup: return "amivoice.setup"
            case .setupTimeout: return "amivoice.setup_timeout"
            case .sendTimeout: return "amivoice.send_timeout"
            case .provider(let providerError): return "amivoice.provider.\(providerError.kind.rawValue)"
            case .receiveFailed: return "amivoice.receive_failed"
            case .disconnected: return "amivoice.disconnected"
            case .noSpeech: return "amivoice.no_speech"
            case .finalizationTimeout: return "amivoice.finalization_timeout"
            case .finalBudgetExceeded: return "amivoice.final_budget"
            }
        }
        if let e = error as? AmiVoiceProviderError {
            return "amivoice.provider.\(e.kind.rawValue)"
        }
        if let e = error as? AmiVoiceWireError {
            switch e {
            case .emptyFrame: return "amivoice.wire.empty_frame"
            case .malformedFrame: return "amivoice.wire.malformed_frame"
            case .invalidJSON: return "amivoice.wire.invalid_json"
            }
        }
        if let e = error as? AppleLocalTranscriber.LocalError {
            switch e {
            case .permission: return "apple.permission"
            case .unavailable: return "apple.unavailable"
            case .empty: return "apple.empty"
            case .finalizationTimeout: return "apple.finalization_timeout"
            case .recognitionFailure: return "apple.recognition_failure"
            case .endedBeforeAudio: return "apple.ended_before_audio"
            }
        }
        if error is CancellationError { return "cancelled" }
        return "other"
    }

    func selectShortcut(_ choice: RecordingShortcut) {
        guard choice != shortcutChoice || !shortcutProblem.isEmpty else { return }
        guard onShortcutChange?(choice) == true else {
            shortcutProblem = "このショートカットは登録できません（macOS側の割当・競合の可能性）。現在のキーを維持します"
            return
        }
        shortcutChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "recordingShortcut")
        shortcutProblem = ""
    }

    func shortcutRegistrationFailed() {
        shortcutProblem = "ショートカットを登録できません。権限・競合を確認してください"
        status = "録音キー未登録。設定から再登録してください"
    }

    func retryShortcutRegistration() {
        if onShortcutRearm?(shortcutChoice) == true {
            shortcutProblem = ""
            status = "録音キーを登録しました"
            DiagnosticLog.record("shortcut registration retried successfully")
        } else {
            shortcutRegistrationFailed()
            DiagnosticLog.record("shortcut registration retry failed")
        }
    }

    @discardableResult private func remember(_ text: String, isPartial: Bool,
                                              delivery: TranscriptRecord.Delivery,
                                              engine: String? = nil,
                                              review: TranscriptReview? = nil,
                                              recordedAt: Date = Date()) -> UUID? {
        let id = historyStore.remember(text, isPartial: isPartial, delivery: delivery,
                              engine: engine ?? (usedMode.isEmpty ? requestedMode.label : usedMode),
                              review: review, recordedAt: recordedAt, preserveWhitespace: !isPartial)
        refreshRetainedAudio()
        return id
    }

    private func updateRemembered(_ id: UUID, delivery: TranscriptRecord.Delivery, detail: String? = nil) {
        historyStore.updateDelivery(id, to: delivery, detail: detail)
    }

    @discardableResult func copyRecord(_ record: TranscriptRecord) -> Bool { TextInsertion.copy(record.text) }
    func deleteRecord(_ id: UUID) {
        if replayRecordID == id { cancelReplay() }
        historyStore.delete(id); refreshRetainedAudio()
    }
    func clearHistory() { cancelReplay(); historyStore.deleteAll() }
    func clearUsageMonitor() { usageStore.deleteAll() }

    func saveKey(_ key: String) throws {
        try KeychainStore.save(key, provider: .gemini)
        invalidateKeyRegistration()
        warmScheduleTask?.cancel()
        prewarmer.shutdown()
        scheduleWarmGemini()
        objectWillChange.send()
    }
    func deleteKey() throws {
        try KeychainStore.delete(provider: .gemini)
        invalidateKeyRegistration()
        warmScheduleTask?.cancel()
        prewarmer.shutdown()
        objectWillChange.send()
    }
    func saveAmiVoiceKey(_ key: String) throws {
        try KeychainStore.save(key, provider: .amivoice)
        invalidateKeyRegistration()
        objectWillChange.send()
    }
    func deleteAmiVoiceKey() throws {
        try KeychainStore.delete(provider: .amivoice)
        invalidateKeyRegistration()
        objectWillChange.send()
    }
    func copyLastText() { TextInsertion.copy(history.first?.text ?? previewText) }

    static func microphoneStartFailureMessage(
        _ error: Error, disposition: MicrophoneCapture.EngineLifetime.Disposition
    ) -> String {
        if error is CancellationError { return userFacingFailure(error, operation: "マイクの開始") }
        return disposition.message ?? userFacingFailure(error, operation: "マイクの開始")
    }

    /// Only app-owned error types with Japanese descriptions may supply UI detail.
    /// Framework and transport errors always pass through the domain/code mapper.
    static func userFacingFailure(_ error: Error, operation: String) -> String {
        let description: String?
        switch error {
        case let error as AppError: description = error.errorDescription
        case let error as AppleLocalTranscriber.LocalError: description = error.errorDescription
        case let error as GeminiLiveConnection.ConnectionError: description = error.errorDescription
        case let error as AmiVoiceWebSocketConnection.ConnectionError: description = error.errorDescription
        case let error as AmiVoiceProviderError: description = error.errorDescription
        case let error as AmiVoiceWireError: description = error.errorDescription
        case let error as MicrophoneDevices.DeviceError: description = error.errorDescription
        case let error as MicrophoneCapture.CaptureError: description = error.errorDescription
        case let error as RetainedAudioStore.ReplayError: description = error.errorDescription
        default: description = nil
        }
        return description ?? UserFacingErrorMessage.message(for: error, operation: operation)
    }

    enum AppError: Error, LocalizedError {
        case noKey, noAmiVoiceKey, connectionLost, audioDropped, localRecoveryBusy, localRecoveryTooLong
        var errorDescription: String? {
            switch self {
            case .noKey: return "Gemini APIキーが未登録です。設定画面でキーチェーンへ保存してください"
            case .noAmiVoiceKey: return "AmiVoice APIキーが未登録です。設定画面でキーチェーンへ保存してください"
            case .connectionLost: return "音声認識エンジンが終了しました"
            case .audioDropped: return "音声チャンクが欠落したため認識結果を破棄しました"
            case .localRecoveryBusy: return "別の録音のローカル復旧処理が実行中です。多重起動を避けるため認識を中止しました"
            case .localRecoveryTooLong: return "50秒を超える音声はAppleの一括救済対象外です。途中結果を履歴に保存します"
            }
        }
    }
}
#endif