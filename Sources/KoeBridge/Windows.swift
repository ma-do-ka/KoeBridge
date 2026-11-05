#if os(macOS)
import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI
import KoeBridgeCore

/// Settings and history use ordinary windows; dictation uses a non-activating
/// panel on the macOS primary display, not NSScreen.main (focused window).
@MainActor final class AppWindows {
    private var settingsWindow: NSWindow?
    private var previewPanel: NSPanel?
    private var historyWindow: NSWindow?
    private var permissionWindow: NSWindow?
    private var displayObserver: NSObjectProtocol?

    init() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.movePreviewToPrimaryDisplay() }
        }
    }

    func manages(_ candidate: NSWindow?) -> Bool {
        guard let candidate else { return false }
        return candidate === settingsWindow || candidate === historyWindow || candidate === permissionWindow
    }

    func showPermissions() {
        PermissionGuide.shared.refresh()
        let window: NSWindow
        if let permissionWindow { window = permissionWindow }
        else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 510, height: 440),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "KoeBridge 初期設定・権限"
            window.center()
            window.contentView = NSHostingView(rootView: PermissionSetupView(guide: .shared))
            window.isReleasedWhenClosed = false
            permissionWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        let window: NSWindow
        if let settingsWindow { window = settingsWindow }
        else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1050, height: 710),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "KoeBridge 設定"
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(controller: .shared, guide: .shared))
            window.minSize = NSSize(width: 850, height: 610)
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showPreview() {
        let panel: NSPanel
        if let previewPanel { panel = previewPanel }
        else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 104),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false // SwiftUI material capsule draws its own subtle shadow
            panel.ignoresMouseEvents = true // no focus changes, no accidental clicks
            panel.isFloatingPanel = true
            panel.isMovable = false
            panel.level = .floating
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: PreviewView(controller: .shared))
            panel.isReleasedWhenClosed = false
            previewPanel = panel
        }
        movePreviewToPrimaryDisplay()
        panel.orderFrontRegardless() // does not activate the application or steal text focus
    }

    private func movePreviewToPrimaryDisplay() {
        guard let panel = previewPanel, let primary = NSScreen.screens.first else { return }
        let area = primary.visibleFrame
        let width = min(520.0, max(260.0, area.width - 24.0))
        let height = min(104.0, max(76.0, area.height - 20.0))
        let frame = NSRect(x: area.midX - width / 2.0,
                           y: area.minY + 12.0, width: width, height: height)
        panel.setFrame(frame, display: true)
    }

    /// Called on second shortcut press, before ASR finalization or paste.
    /// No fade, delay, or success-only condition; the overlay must disappear
    /// even if network recognition or focus-safe insertion later fails.
    func hidePreview() {
        previewPanel?.orderOut(nil)
    }

    func showHistory() {
        let window: NSWindow
        if let historyWindow { window = historyWindow }
        else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 790, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "KoeBridge 認識履歴（直近10件）"
            window.center()
            window.contentView = NSHostingView(rootView: HistoryView(controller: .shared))
            window.isReleasedWhenClosed = false
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// A minimal non-interactive floating transcription capsule.
/// Status, commands, diagnostics and history are intentionally available only
/// from the menu bar / Settings, never on the dictation overlay itself.
struct PreviewView: View {
    @ObservedObject var controller: VoiceController

    private var visibleTranscript: String {
        let stage = controller.overlayFeedback
        guard stage == .recording else { return stage.message }
        let full = controller.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return stage.message }
        return full.count > 180 ? "…" + String(full.suffix(180)) : full
    }

    private var feedbackSymbol: String {
        switch controller.overlayFeedback {
        case .hidden, .preparing: return "mic"
        case .recording: return "waveform"
        case .ending: return "stop.circle"
        case .processing: return "ellipsis"
        case .noInput: return "mic.slash"
        case .sent: return "arrow.up.circle.fill"
        case .saved: return "clock.arrow.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(controller.isRecording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: 38, height: 38)
                if controller.overlayFeedback == .processing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("文字起こしの確定処理中")
                } else {
                    Image(systemName: feedbackSymbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(controller.isRecording ? Color.red : Color.secondary)
                        .accessibilityHidden(true)
                }
            }
            Text(visibleTranscript)
                .font(.system(size: 14, weight: .medium, design: .default))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(visibleTranscript)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.17), radius: 13, x: 0, y: 5)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

struct HistoryView: View {
    @ObservedObject var controller: VoiceController
    @State private var selectedID: UUID?
    @State private var confirmDeleteAll = false

    private var selected: TranscriptRecord? {
        controller.history.first(where: { $0.id == selectedID }) ?? controller.history.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("保存した文章：\(controller.history.count) / 10件")
                    .font(.headline)
                Spacer()
                Text("直近10件を保存。音声データ・APIキーは保存しません")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !controller.historyProblem.isEmpty {
                Text(controller.historyProblem)
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if controller.history.isEmpty {
                Spacer()
                Text("保存された文字起こしはありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(controller.history) { record in
                                Button {
                                    selectedID = record.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Text(record.text.replacingOccurrences(of: "\n", with: " "))
                                            .lineLimit(2).font(.body)
                                        Text(record.delivery.label)
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(selected?.id == record.id
                                                ? Color.accentColor.opacity(0.14)
                                                : Color.secondary.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }.frame(width: 255)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        if let selected {
                            Text("\(selected.engine) / \(selected.isPartial ? "認識途中" : "確定結果")")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(selected.delivery.label)
                                .font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                Text(selected.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            HStack {
                                Spacer()
                                Button("文章をコピー") { controller.copyRecord(selected) }
                                Button("この文章を削除", role: .destructive) {
                                    let removing = selected.id
                                    controller.deleteRecord(removing)
                                    selectedID = controller.history.first?.id
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            HStack {
                Text("自動入力が相手のアプリで受け付けられたかは確認できません。必要に応じて文章をコピーしてください。")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("履歴をすべて削除", role: .destructive) { confirmDeleteAll = true }
                    .disabled(controller.history.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 650, minHeight: 390)
        .alert("保存した10件の履歴をすべて削除しますか？", isPresented: $confirmDeleteAll) {
            Button("削除", role: .destructive) { controller.clearHistory(); selectedID = nil }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除した文字起こしはKoeBridgeから復元できません。")
        }
    }
}

/// The OS owns both security decisions. This view requests prompts and
/// reflects actual process permissions; it never claims to enable them.
@MainActor final class PermissionGuide: ObservableObject {
    static let shared = PermissionGuide()
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var postEventGranted = false
    @Published private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var microphoneRequestInProgress = false
    @Published private(set) var message = ""

    private init() { refresh() }
    var needsAttention: Bool {
        PermissionSetupPolicy.shouldShowSetup(accessibilityGranted: accessibilityGranted,
                                               postEventGranted: postEventGranted,
                                               microphoneGranted: microphoneStatus == .authorized)
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        postEventGranted = CGPreflightPostEventAccess()
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Remove old action messages before displaying freshly read OS status.
    func refreshFromSettings() {
        message = ""
        refresh()
    }

    func requestAccessibility() {
        _ = TextInsertion.requestAccessibility()
        refresh()
        message = accessibilityGranted
            ? "アクセシビリティは許可されています。"
            : "macOSの許可画面でKoeBridgeをONにしてください。必要ならアプリを終了して再起動します。"
    }

    func requestPostEvent() {
        refresh()
        guard accessibilityGranted else {
            message = "まず『入力先へのアクセスを許可』の設定が必要です。"
            return
        }
        _ = TextInsertion.requestPostEventAccess()
        refresh()
        message = postEventGranted
            ? "入力イベントの送信が許可されました。"
            : "文字の入力操作は未許可です。macOSが再度ダイアログを出さない場合、プライバシー設定でKoeBridgeを確認してください。"
    }

    func requestMicrophone() {
        refresh()
        guard microphoneStatus == .notDetermined, !microphoneRequestInProgress else {
            message = microphoneStatus == .authorized
                ? "マイクは許可されています。"
                : "マイクの利用を拒否済みの場合はmacOSのプライバシー設定から変更してください。"
            return
        }
        microphoneRequestInProgress = true
        message = "マイクの許可結果を確認しています…"
        Task { [weak self] in
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self else { return }
            self.microphoneRequestInProgress = false
            self.refresh()
            self.message = self.microphoneStatus == .authorized
                ? "マイクの使用が許可されました。"
                : "マイクは未許可です。macOSのプライバシー設定でKoeBridgeのマイクを確認してください。"
        }
    }

    /// Only on the first app launch. Show the native microphone dialog and
    /// the native accessibility guidance, one after the other.
    func promptOnFirstLaunch() {
        let key = "permissionsIntroRequestedV044"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task { [weak self] in
            guard let self else { return }
            self.refresh()
            if self.microphoneStatus == .notDetermined {
                self.microphoneRequestInProgress = true
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                self.microphoneRequestInProgress = false
                self.refresh()
            }
            if !self.accessibilityGranted { self.requestAccessibility() }
            // One consent request on first launch after this feature is added.
            // If macOS has already denied it, subsequent requests may show no
            // prompt. The separate button and Settings guidance remain available.
            self.refresh()
            if self.accessibilityGranted && !self.postEventGranted {
                self.requestPostEvent()
            }
        }
    }
}

struct PermissionSetupView: View {
    @ObservedObject var guide: PermissionGuide

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("音声入力に必要な許可")
                    .font(.title2).fontWeight(.semibold)
                Text("マイクによる録音と、ほかのアプリへの文字入力のためにmacOSの利用許可が必要です。")
                    .font(.caption).foregroundStyle(.secondary)
                permissionHelpRow(
                    "入力先へのアクセスを許可",
                    description: "入力先を確認し、意図しない場所への入力を防ぐために必要です。",
                    icon: "hand.raised.fill",
                    isGranted: guide.accessibilityGranted,
                    canRequest: !guide.accessibilityGranted
                ) { guide.requestAccessibility() }
                Divider()
                permissionHelpRow(
                    "文字の入力操作を許可",
                    description: "認識した文字を、ほかのアプリへ入力するために必要です。",
                    icon: "keyboard.fill",
                    isGranted: guide.postEventGranted,
                    canRequest: !guide.postEventGranted && guide.accessibilityGranted
                ) { guide.requestPostEvent() }
                Divider()
                permissionHelpRow(
                    "マイクの使用を許可",
                    description: "音声を録音して文字に変換するために必要です。",
                    icon: "mic.fill",
                    isGranted: guide.microphoneStatus == .authorized,
                    canRequest: guide.microphoneStatus != .authorized && !guide.microphoneRequestInProgress
                ) { guide.requestMicrophone() }
                Text("一度拒否した許可はmacOSのシステム設定「プライバシーとセキュリティ」から変更してください。入力先へのアクセスが許可済みでも、文字の入力操作が未許可の場合は入力できません。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !guide.message.isEmpty {
                    Text(guide.message)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !guide.needsAttention {
                    Text("必要な許可は確認済みです。「閉じる」で案内を閉じ、入力したい欄をクリックしてから録音してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("許可状態を再確認") {
                        guide.refresh()
                        if !guide.needsAttention { NSApp.keyWindow?.performClose(nil) }
                    }
                    Spacer()
                    Button("閉じる") { NSApp.keyWindow?.performClose(nil) }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 510, height: 440)
    }

    private func permissionHelpRow(
        _ title: String, description: String, icon: String,
        isGranted: Bool, canRequest: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 23)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(description)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(isGranted ? "許可済み" : "未許可")
                    .font(.caption)
                    .foregroundStyle(isGranted ? Color.green : Color.orange)
                Button("許可を求める", action: action)
                    .disabled(!canRequest)
            }
        }
    }
}
#endif
