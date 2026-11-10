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
    private var clipboardFeedbackPanel: NSPanel?
    private var clipboardFeedbackDismissal: Task<Void, Never>?

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

    /// Transient, non-activating status feedback. Do not steal focus from
    /// the editor or interfere with the separate dictation preview panel.
    func showClipboardFeedback(success: Bool, statusButton: NSStatusBarButton?) {
        clipboardFeedbackDismissal?.cancel()
        let width: CGFloat = 312
        let height: CGFloat = 66
        let panel: NSPanel
        if let clipboardFeedbackPanel {
            panel = clipboardFeedbackPanel
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            clipboardFeedbackPanel = panel
        }
        panel.contentView = NSHostingView(rootView: ClipboardFeedbackBubble(success: success))
        let anchor: NSRect? = statusButton.flatMap { button in
            guard let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let visible = (statusButton?.window?.screen ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max((anchor?.midX ?? visible.midX) - width / 2, visible.minX + 8),
                    max(visible.minX + 8, visible.maxX - width - 8))
        let y = max(visible.minY + 8,
                    min((anchor?.minY ?? visible.maxY) - height - 8, visible.maxY - height - 8))
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
        clipboardFeedbackDismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2.2)) } catch { return }
            self?.clipboardFeedbackPanel?.orderOut(nil)
        }
    }

    func showHistory() {
        let window: NSWindow
        if let historyWindow { window = historyWindow }
        else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 790, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "KoeBridge 認識履歴（直近\(RecentTranscriptArchive.maximumRecords)件）"
            window.center()
            window.contentView = NSHostingView(rootView: HistoryView(controller: .shared))
            window.isReleasedWhenClosed = false
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ClipboardFeedbackBubble: View {
    let success: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(success ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(success ? "コピーしました" : "コピーできませんでした")
                    .font(.system(size: 14, weight: .semibold))
                Text(success ? "⌘Vで貼り付けできます" : "クリップボードの状態をご確認ください")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
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
        if PermissionSetupPolicy.accessibilityAction(granted: accessibilityGranted) == .openAccessibilitySettings {
            openPrivacySettings("Accessibility")
        } else {
            message = "アクセシビリティは許可されています。"
        }
    }

    func requestPostEvent() {
        refresh()
        guard PermissionSetupPolicy.postEventAction(
            accessibilityGranted: accessibilityGranted,
            postEventGranted: postEventGranted) != .needsAccessibilityFirst else {
            message = "まず『入力先へのアクセスを許可』の設定が必要です。"
            return
        }
        _ = TextInsertion.requestPostEventAccess()
        refresh()
        switch PermissionSetupPolicy.postEventAction(
            accessibilityGranted: accessibilityGranted, postEventGranted: postEventGranted) {
        case .openAccessibilitySettings:
            openPrivacySettings("Accessibility")
        case .needsAccessibilityFirst:
            message = "まず『入力先へのアクセスを許可』の設定が必要です。"
        default:
            message = "入力イベントの送信が許可されました。"
        }
    }

    private func openPrivacySettings(_ pane: String) {
        let name = pane == "Accessibility" ? "アクセシビリティ" : "マイク"
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)")!
        if NSWorkspace.shared.open(url) {
            message = "システム設定の「\(name)」を開きました。一覧でKoeBridgeをONにしてください。"
        } else {
            message = "システム設定を開けませんでした。「プライバシーとセキュリティ」の「\(name)」でKoeBridgeをONにしてください。"
        }
    }

    func requestMicrophone() {
        refresh()
        switch PermissionSetupPolicy.microphoneAction(status: microphoneStatus.rawValue) {
        case .none:
            message = "マイクは許可されています。"
            return
        case .openMicrophoneSettings:
            openPrivacySettings("Microphone")
            return
        case .showMicrophonePrompt:
            guard !microphoneRequestInProgress else { return }
        default:
            return
        }
        microphoneRequestInProgress = true
        message = "マイクの許可結果を確認しています…"
        Task { [weak self] in
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self else { return }
            self.microphoneRequestInProgress = false
            self.refresh()
            switch PermissionSetupPolicy.microphoneAction(status: self.microphoneStatus.rawValue) {
            case .none:
                self.message = "マイクの使用が許可されました。"
            case .openMicrophoneSettings:
                self.openPrivacySettings("Microphone")
            default:
                self.message = "マイクは未許可です。macOSのプライバシー設定でKoeBridgeのマイクを確認してください。"
            }
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
