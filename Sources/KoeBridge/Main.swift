#if os(macOS)
import AppKit
import Combine
import Carbon
import Darwin
import KoeBridgePOSIX
import CoreGraphics
import SwiftUI
import KoeBridgeCore

/// Presets verified against shipped source / official shortcut documentation.
/// Existing persisted keys (including F8/F9) are preserved by their raw values.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case recording, transformSelection, translateSelection
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recording: return "録音の開始・終了キー"
        case .transformSelection: return "選択テキストを変換"
        case .translateSelection: return "選択テキストを翻訳"
        }
    }
}

enum RecordingShortcut: String, CaseIterable, Identifiable {
    case controlOptionSpace
    case controlShiftSpace
    case rightCommand
    case rightOption
    case rightControl
    case rightShift
    case fnKey
    case fnSpace
    case f5, f6, f7, f8, f9, f10, f11, f12, f13

    var id: String { rawValue }

    var label: String {
        switch self {
        case .controlOptionSpace: return "Control + Option + Space（既定）"
        case .controlShiftSpace: return "Control + Shift + Space"
        case .rightCommand: return "右 Command (⌘)"
        case .rightOption: return "右 Option (⌥)"
        case .rightControl: return "右 Control (⌃)"
        case .rightShift: return "右 Shift (⇧)"
        case .fnKey: return "Fn / Globe（キーボード依存）"
        case .fnSpace: return "Fn + Space（競合に注意）"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        case .f13: return "F13"
        }
    }

    /// Bare physical modifiers / Fn+Space cannot be registered with Carbon.
    var usesEventTap: Bool {
        switch self {
        case .rightCommand, .rightOption, .rightControl, .rightShift, .fnKey, .fnSpace: return true
        default: return false
        }
    }

    var modifierKeyCode: Int? {
        switch self {
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        case .rightShift: return 60
        case .fnKey: return 63
        default: return nil
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .controlOptionSpace, .controlShiftSpace, .fnSpace: return UInt32(kVK_Space)
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        case .rightShift: return 60
        case .fnKey: return 63
        case .f5: return UInt32(kVK_F5)
        case .f6: return UInt32(kVK_F6)
        case .f7: return UInt32(kVK_F7)
        case .f8: return UInt32(kVK_F8)
        case .f9: return UInt32(kVK_F9)
        case .f10: return UInt32(kVK_F10)
        case .f11: return UInt32(kVK_F11)
        case .f12: return UInt32(kVK_F12)
        case .f13: return UInt32(kVK_F13)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .controlShiftSpace: return UInt32(controlKey | shiftKey)
        default: return 0
        }
    }
}

@main struct KoeBridgeLaunch {
    // An OS file lock prevents two copies from competing for the same hotkey,
    // microphone and text injection. It is released automatically on process exit.
    private static var instanceLockFD: Int32 = -1

    private static func acquireInstanceLock() -> Bool {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KoeBridge", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
        } catch { return false }
        let lockFile = folder.appendingPathComponent("instance.lock")
        let fd = lockFile.path.withCString { Darwin.open($0, O_RDWR | O_CREAT, mode_t(0o600)) }
        guard fd >= 0 else { return false }
        guard KBFileLockTryExclusive(fd) == 0 else {
            Darwin.close(fd)
            return false
        }
        instanceLockFD = fd
        return true
    }

    static func main() {
        guard acquireInstanceLock() else {
            fputs("KoeBridge: another instance is running, or the instance lock cannot be acquired.\n", stderr)
            return
        }
        let app = NSApplication.shared
        let delegate = KoeBridgeAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor final class KoeBridgeAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private var shortcut: GlobalShortcut?
    private var transformShortcutMonitor: GlobalShortcut?
    private var translateShortcutMonitor: GlobalShortcut?
    private let windows = AppWindows()
    private let controller = VoiceController.shared
    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowKeyMonitor: Any?
    private var updateCheckTimer: Timer?
    private let statusPopover = NSPopover()
    private var recordingObservation: AnyCancellable?
    private var lastPopoverClosedAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "KoeBridge")
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusPopover.behavior = .transient
        statusPopover.delegate = self
        statusPopover.animates = true
        let hosting = NSHostingController(rootView: StatusPopoverView(
            controller: controller, guide: PermissionGuide.shared,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onOpenHistory: { [weak self] in self?.showHistory() },
            onOpenPermissions: { [weak self] in self?.showPermissions() },
            onCheckForUpdates: { [weak self] in self?.checkForUpdates() },
            onQuit: { [weak self] in self?.quit() },
            onToggleRecording: { [weak self] in self?.afterClosingPopover { $0.controller.toggle() } },
            onDiscard: { [weak self] in self?.afterClosingPopover { $0.controller.discard() } },
            onCopyRecord: { [weak self] record in self?.copyRecentHistory(record) }
        ))
        hosting.sizingOptions = [.preferredContentSize]
        statusPopover.contentViewController = hosting
        recordingObservation = controller.$isRecording.sink { [weak self] recording in
            self?.item.button?.image = NSImage(
                systemSymbolName: recording ? "record.circle" : "waveform",
                accessibilityDescription: "KoeBridge")
        }

        // This never activates KoeBridge or takes keyboard focus from the text field.
        controller.onShowPreview = { [weak self] in self?.windows.showPreview() }
        controller.onHidePreview = { [weak self] in self?.windows.hidePreview() }
        controller.onShowHistory = { [weak self] in self?.windows.showHistory() }
        controller.onShowPermissions = { [weak self] in self?.windows.showPermissions() }
        installWindowShortcuts()

        transformShortcutMonitor = GlobalShortcut(action: .transformSelection)
        controller.onTransformShortcutChange = { [weak self] choice in
            guard let self else { return false }
            if let choice { return self.transformShortcutMonitor?.register(choice) ?? false }
            self.transformShortcutMonitor = GlobalShortcut(action: .transformSelection)
            return true
        }
        if let choice = controller.transformShortcut,
           transformShortcutMonitor?.register(choice) != true {
            controller.status = "変換ショートカットを登録できません（キーの競合を確認してください）"
        }
        translateShortcutMonitor = GlobalShortcut(action: .translateSelection)
        controller.onTranslateShortcutChange = { [weak self] choice in
            guard let self else { return false }
            if let choice { return self.translateShortcutMonitor?.register(choice) ?? false }
            self.translateShortcutMonitor = GlobalShortcut(action: .translateSelection)
            return true
        }
        if let choice = controller.translateShortcut,
           translateShortcutMonitor?.register(choice) != true {
            controller.status = "翻訳ショートカットを登録できません（キーの競合を確認してください）"
        }
        shortcut = GlobalShortcut()
        controller.onShortcutChange = { [weak self] choice in
            self?.shortcut?.register(choice) ?? false
        }
        controller.onShortcutRearm = { [weak self] choice in
            self?.shortcut?.register(choice, rearm: true) ?? false
        }
        controller.onInputConfigurationChange = { [weak self] in
            guard let self else { return }
            self.shortcut?.configureMouse()
            if let choice = self.controller.translateShortcut,
               self.translateShortcutMonitor?.register(choice, rearm: true) != true {
                self.controller.status = "翻訳ショートカットを登録できません"
            }
            if let choice = self.controller.transformShortcut,
               self.transformShortcutMonitor?.register(choice, rearm: true) != true {
                self.controller.status = "変換ショートカットを登録できません"
            }
            if self.shortcut?.register(self.controller.shortcutChoice, rearm: true) != true {
                self.controller.shortcutRegistrationFailed()
            }
        }
        shortcut?.configureMouse()
        if shortcut?.register(controller.shortcutChoice) != true {
            controller.shortcutRegistrationFailed()
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.controller.interruptForSystemEvent("Macのスリープにより録音を中断しました。途中結果は履歴に保存しました")
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.controller.interruptForSystemEvent("ユーザーセッションが切り替わったため録音を中断しました")
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.controller.interruptForSystemEvent("スリープ復帰により録音を中断しました")
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self.controller.retryShortcutRegistration()
            }
        })
        DiagnosticLog.record("startup; version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"); accessibility=\(TextInsertion.isTrusted); postEvent=\(TextInsertion.mayPostEvents)")
        if PermissionGuide.shared.needsAttention {
            windows.showPermissions()
            PermissionGuide.shared.promptOnFirstLaunch()
        }
        // Only checks signed-off stable release metadata; never installs
        // code in the background or interrupts a dictation session.
        KoeBridgeUpdateManager.shared.checkIfDue()
        // A persistent menu-bar app may stay open for days; revisit the
        // 24-hour due check hourly without polling GitHub every hour.
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in
                KoeBridgeUpdateManager.shared.checkIfDue()
            }
        }
    }

    // User consent is required: show the initial setup window rather than
    // claiming permissions have been enabled by the app.
    // Permission prompts are serialized so native alerts do not overlap.
    // (This block is called at the end of applicationDidFinishLaunching.)

    /// Accessory apps have no normal visible app menu. Handle the standard
    /// window shortcuts locally, only while one of our ordinary windows is key.
    private func installWindowShortcuts() {
        windowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
                  self.windows.manages(event.window ?? NSApp.keyWindow),
                  let letter = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch letter {
            case "w":
                (event.window ?? NSApp.keyWindow)?.performClose(nil)
                return nil
            case "q":
                NSApp.terminate(nil)
                return nil
            default: return event
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        PermissionGuide.shared.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
        controller.interruptForSystemEvent("アプリ終了により録音を中断しました")
        if let windowKeyMonitor { NSEvent.removeMonitor(windowKeyMonitor); self.windowKeyMonitor = nil }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusPopover.performClose(nil)
            let menu = NSMenu()
            add(menu, "設定…", #selector(showSettings))
            add(menu, "アップデートを確認…", #selector(checkForUpdates))
            menu.addItem(.separator())
            add(menu, "KoeBridgeを終了", #selector(quit))
            // Anchored NSMenu.popUp runs native menu tracking without assigning
            // item.menu or recursively invoking the status button action.
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        } else if statusPopover.isShown {
            statusPopover.performClose(nil)
        } else {
            // A transient popover closes on the button's mouseDown, before this
            // mouseUp action runs; without this guard, the click that closed it
            // would immediately reopen it instead of toggling it shut.
            if let closedAt = lastPopoverClosedAt, Date().timeIntervalSince(closedAt) < 0.2 { return }
            PermissionGuide.shared.refresh()
            if let hosting = statusPopover.contentViewController {
                statusPopover.contentSize = hosting.view.fittingSize
            }
            statusPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClosedAt = Date()
    }

    /// Close first so insertion-target capture sees the user's original editor.
    private func afterClosingPopover(_ action: @escaping (KoeBridgeAppDelegate) -> Void) {
        statusPopover.performClose(nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            action(self)
        }
    }

    private func copyRecentHistory(_ record: TranscriptRecord) {
        afterClosingPopover { delegate in
            let current = delegate.controller.history.first { $0.id == record.id }
            let copied = current.map { delegate.controller.copyRecord($0) } ?? false
            delegate.windows.showClipboardFeedback(success: copied, statusButton: delegate.item.button)
        }
    }

    private func add(_ menu: NSMenu, _ title: String, _ selector: Selector) {
        let menuItem = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        menuItem.target = self
    }
    @objc private func showHistory() {
        statusPopover.performClose(nil)
        windows.showHistory()
    }
    @objc private func showSettings() {
        statusPopover.performClose(nil)
        windows.showSettings()
    }
    @objc private func checkForUpdates() {
        statusPopover.performClose(nil)
        windows.showSettings()
        let updater = KoeBridgeUpdateManager.shared
        updater.requestUpdatePage()
        Task { await updater.checkNow() }
    }
    @objc private func showPermissions() {
        statusPopover.performClose(nil)
        windows.showPermissions()
    }
    @objc private func quit() {
        statusPopover.performClose(nil)
        controller.discard()
        NSApp.terminate(nil)
    }
}

/// Carbon for standard combinations, Quartz event tap for bare right-side
/// modifiers. Re-registration is transactional: a failed new shortcut leaves
/// the previously working one installed.
@MainActor private final class GlobalShortcut {
    private let action: ShortcutAction
    nonisolated private let signature: OSType
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var modifierMonitor: ModifierShortcutMonitor?
    private var activeChoice: RecordingShortcut?
    private static var nextHotKeyID: UInt32 = 1
    private var policy = ShortcutActivationPolicy()
    private var mouseMonitor: MouseShortcutMonitor?
    private var monitorGeneration = UUID()
    private var carbonGate = HotKeyPressGate()

    func configureMouse() {
        operationPressDown = false
        policy.reset()
        policy.mode = VoiceController.shared.shortcutActivationMode
        mouseMonitor?.stop()
        mouseMonitor = nil
        let button = VoiceController.shared.mouseTriggerButton
        guard button != .none else { return }
        let monitor = MouseShortcutMonitor(button: button) { [weak self] pressed, time in
            self?.route(pressed: pressed, at: time)
        }
        mouseMonitor = monitor
        monitor.start()
    }

    private var operationPressDown = false
    private func route(pressed: Bool, at time: TimeInterval) {
        if self.action == .translateSelection ||
            (self.action == .transformSelection && VoiceController.shared.transformMode == .preset) {
            if !pressed { operationPressDown = false; return }
            guard !operationPressDown else { return }
            operationPressDown = true
            if self.action == .translateSelection { VoiceController.shared.translateSelection() }
            else { VoiceController.shared.transformSelection() }
            return
        }
        let action = pressed ? policy.pressed(at: time) : policy.released(at: time)
        if self.action == .transformSelection {
            switch action {
            case .toggle: VoiceController.shared.transformSelection()
            case .begin: VoiceController.shared.transformSelection()
            case .commit: VoiceController.shared.transformInstructionEnded()
            case nil: break
            }
            return
        }
        switch action {
        case .toggle: VoiceController.shared.toggle()
        case .begin: VoiceController.shared.shortcutPressBegan()
        case .commit: VoiceController.shared.shortcutPressEnded()
        case nil: break
        }
    }
    private var carbonReleaseRecovery: Task<Void, Never>?

    init(action: ShortcutAction = .recording) {
        self.action = action
        switch action {
        case .recording: self.signature = OSType(0x4B4F4542)
        case .transformSelection: self.signature = OSType(0x4B4F4554)
        case .translateSelection: self.signature = OSType(0x4B4F454C)
        }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased))
        ]
        let callback: EventHandlerUPP = { _, event, raw -> OSStatus in
            guard let event, let raw else { return noErr }
            var pressedID = EventHotKeyID(signature: 0, id: 0)
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &pressedID
            )
            guard status == noErr else { return noErr }
            let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let monitor = Unmanaged<GlobalShortcut>.fromOpaque(raw).takeUnretainedValue()
            guard pressedID.signature == monitor.signature else { return OSStatus(eventNotHandledErr) }
            let keyID = pressedID.id
            DispatchQueue.main.async { [weak monitor] in
                monitor?.handleCarbonEvent(id: keyID, pressed: isPress)
            }
            return noErr
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(), callback, types.count,
            &types, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        if status != noErr {
            handlerRef = nil
            DiagnosticLog.record("carbon handler registration failed; OSStatus=\(status)")
        }
    }

    private func handleCarbonEvent(id: UInt32, pressed: Bool) {
        // A late release from a replaced Carbon registration must not cancel
        // the new registration's missing-release watchdog.
        guard carbonGate.isRegistered(id) else { return }
        let shouldToggle = carbonGate.receive(id: id, pressed: pressed)
        if !pressed {
            carbonReleaseRecovery?.cancel()
            carbonReleaseRecovery = nil
        }
        if pressed {
            guard shouldToggle else { return }
            route(pressed: true, at: ProcessInfo.processInfo.systemUptime)
            scheduleCarbonReleaseRecovery(id: id)
        } else {
            route(pressed: false, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// Carbon sometimes loses kEventHotKeyReleased (e.g. re-registration
    /// during a held key). If Input Monitoring is already granted, verify
    /// the actual physical key is UP before rearming. Never synthesize a
    /// second toggle, and never require this permission for ordinary F-keys.
    private func scheduleCarbonReleaseRecovery(id: UInt32) {
        carbonReleaseRecovery?.cancel()
        carbonReleaseRecovery = nil
        guard CGPreflightListenEventAccess(),
              let choice = activeChoice, !choice.usesEventTap else { return }
        carbonReleaseRecovery = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            for _ in 0..<80 {
                guard let self, !Task.isCancelled,
                      self.activeChoice == choice else { return }
                let code = CGKeyCode(choice.keyCode)
                if !CGEventSource.keyState(.combinedSessionState, key: code) {
                    do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                    if !CGEventSource.keyState(.combinedSessionState, key: code),
                       self.carbonGate.recoverMissedRelease(id: id, physicalKeyStillDown: false) {
                        self.route(pressed: false, at: ProcessInfo.processInfo.systemUptime)
                        DiagnosticLog.record("carbon missing key-up recovered using physical state")
                        return
                    }
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    func register(_ choice: RecordingShortcut, rearm: Bool = false) -> Bool {
        let controller = VoiceController.shared
        let bindings: [(ShortcutAction, RecordingShortcut?)] = [
            (.recording, controller.shortcutChoice),
            (.transformSelection, controller.transformShortcut),
            (.translateSelection, controller.translateShortcut)
        ]
        guard !bindings.contains(where: { $0.0 != action && $0.1 == choice }) else { return false }
        if activeChoice == choice && !rearm { return true }
        operationPressDown = false
        policy.reset()
        policy.mode = VoiceController.shared.shortcutActivationMode
        carbonReleaseRecovery?.cancel()
        carbonReleaseRecovery = nil
        // In the Settings retry path, a monitor can report as registered even
        // after macOS disabled its event tap or lost the key-release event.
        // Rebuild the monitor rather than returning true without doing anything.
        if choice.usesEventTap {
            let generation = UUID()
            let oneShot = action == .translateSelection ||
                (action == .transformSelection && controller.transformMode == .preset)
            let candidate = ModifierShortcutMonitor(choice: choice, mode: oneShot ? .hold : controller.shortcutActivationMode) { [weak self] pressed, time in
                guard let self, self.monitorGeneration == generation else { return }
                self.route(pressed: pressed, at: time)
            }
            guard candidate.start() else {
                DiagnosticLog.record("modifier shortcut event tap registration failed")
                return false
            }
            monitorGeneration = generation
            let oldMonitor = modifierMonitor
            modifierMonitor = candidate
            oldMonitor?.stop()
            if let old = hotKeyRef { UnregisterEventHotKey(old) }
            hotKeyRef = nil
            carbonGate.activate(nil)
            activeChoice = choice
            return true
        }
        guard handlerRef != nil else { return false }
        let removedForRearm = rearm && activeChoice == choice && hotKeyRef != nil
        if removedForRearm, let old = hotKeyRef {
            // Carbon does not permit the same combination to be registered
            // twice. Unregister the old one for the explicit user retry only.
            UnregisterEventHotKey(old)
            hotKeyRef = nil
            carbonGate.activate(nil)
            activeChoice = nil
        }
        let id = EventHotKeyID(signature: signature, id: Self.nextHotKeyID)
        Self.nextHotKeyID &+= 1
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(choice.keyCode, choice.modifiers, id,
                                         GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let candidate else {
            DiagnosticLog.record("carbon hotkey registration failed; OSStatus=\(status)")
            if removedForRearm {
                // Re-registration during a manual retry can lose a race with
                // another shortcut owner. Attempt to recover the old binding.
                let rollback = EventHotKeyID(signature: signature, id: Self.nextHotKeyID)
                Self.nextHotKeyID &+= 1
                var restored: EventHotKeyRef?
                let restoredStatus = RegisterEventHotKey(
                    choice.keyCode, choice.modifiers, rollback,
                    GetApplicationEventTarget(), 0, &restored
                )
                if restoredStatus == noErr, let restored {
                    hotKeyRef = restored
                    carbonGate.activate(rollback.id)
                    activeChoice = choice
                    DiagnosticLog.record("carbon shortcut restored after failed rearm")
                } else {
                    DiagnosticLog.record("carbon shortcut rollback failed; OSStatus=\(restoredStatus)")
                }
            }
            return false
        }
        if let old = hotKeyRef { UnregisterEventHotKey(old) }
        hotKeyRef = candidate
        carbonGate.activate(id.id)
        modifierMonitor?.stop()
        modifierMonitor = nil
        activeChoice = choice
        return true
    }

    deinit {
        carbonReleaseRecovery?.cancel()
        modifierMonitor?.stop()
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

/// A passive event tap on a DEDICATED thread. The main AppKit run loop must
/// never process all key events, or a slow UI/ASR task can disable the tap.
/// Only Fn+Space consumes its matched Space keystrokes.
private final class ModifierShortcutMonitor {
    private let choice: RecordingShortcut
    private let mode: ShortcutActivationMode
    private let onEdge: (Bool, TimeInterval) -> Void
    // Detector and fnSpaceHeld are accessed only on the event-tap thread.
    private var detector: ModifierToggleDetector?
    private var fnSpaceHeld = false
    private var releaseUpSamples = 0
    private let lifecycleLock = NSLock()
    private var active = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var workerLoop: CFRunLoop?
    private var worker: Thread?

    init(choice: RecordingShortcut, mode: ShortcutActivationMode,
         onEdge: @escaping (Bool, TimeInterval) -> Void) {
        self.choice = choice
        self.mode = mode
        self.onEdge = onEdge
        if let code = choice.modifierKeyCode {
            detector = ModifierToggleDetector(targetKeyCode: code)
        }
    }

    private var isActive: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return active
    }

    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        lifecycleLock.lock()
        guard !active else { lifecycleLock.unlock(); return false }
        active = true
        lifecycleLock.unlock()

        let t = Thread { [self] in
            let mask: CGEventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
                | (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            guard let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: choice == .fnSpace ? .defaultTap : .listenOnly,
                eventsOfInterest: mask,
                callback: Self.callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                lifecycleLock.lock()
                active = false
                worker = nil
                lifecycleLock.unlock()
                ready.signal()
                return
            }
            guard let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
                CFMachPortInvalidate(eventTap)
                lifecycleLock.lock()
                active = false
                worker = nil
                lifecycleLock.unlock()
                ready.signal()
                return
            }
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, runSource, CFRunLoopMode.commonModes)
            lifecycleLock.lock()
            self.tap = eventTap
            self.source = runSource
            self.workerLoop = loop
            lifecycleLock.unlock()
            CGEvent.tapEnable(tap: eventTap, enable: true)
            let releaseTimer = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in
                self?.reconcileLostModifierUp()
            }
            RunLoop.current.add(releaseTimer, forMode: .common)
            ready.signal()

            // A bounded run-loop slice makes stop safe even if CFRunLoopStop
            // races the first run or a key-up never arrives.
            while isActive {
                _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.25, true)
            }
            releaseTimer.invalidate()
            CFRunLoopRemoveSource(loop, runSource, CFRunLoopMode.commonModes)
            CFMachPortInvalidate(eventTap)
            detector?.reset()
            fnSpaceHeld = false
            releaseUpSamples = 0
            lifecycleLock.lock()
            self.tap = nil
            self.source = nil
            self.workerLoop = nil
            self.worker = nil
            lifecycleLock.unlock()
        }
        t.name = "dev.koebridge.shortcut-monitor"
        t.qualityOfService = .userInteractive
        lifecycleLock.lock()
        worker = t
        lifecycleLock.unlock()
        t.start()
        guard ready.wait(timeout: .now() + 5) == .success else {
            stop()
            return false
        }
        lifecycleLock.lock()
        let success = tap != nil
        lifecycleLock.unlock()
        if !success { stop() }
        return success
    }

    func stop() {
        lifecycleLock.lock()
        active = false
        let loop = workerLoop
        lifecycleLock.unlock()
        if let loop { CFRunLoopWakeUp(loop) }
        // The worker holds a strong reference to self until the tap is fully
        // invalidated; no dangling passUnretained callback is possible.
    }

    private static let callback: CGEventTapCallBack = { _, type, event, raw in
        guard let raw else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<ModifierShortcutMonitor>.fromOpaque(raw).takeUnretainedValue()
        guard monitor.isActive else { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if (monitor.mode != .toggle && monitor.detector?.isHeld == true) || monitor.fnSpaceHeld {
                monitor.requestEdge(false, at: ProcessInfo.processInfo.systemUptime)
            }
            monitor.detector?.reset()
            monitor.fnSpaceHeld = false
            monitor.releaseUpSamples = 0
            if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let swallow = monitor.handle(type: type, event: event)
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if choice == .fnSpace {
            if type == .keyUp && code == Int(kVK_Space) && fnSpaceHeld {
                fnSpaceHeld = false
                requestEdge(false, at: Double(event.timestamp) / 1_000_000_000)
                return true
            }
            if type == .keyDown && code == Int(kVK_Space) {
                let others: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
                guard event.flags.contains(.maskSecondaryFn),
                      event.flags.intersection(others).isEmpty else { return false }
                if !fnSpaceHeld && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    fnSpaceHeld = true
                    requestEdge(true, at: Double(event.timestamp) / 1_000_000_000)
                }
                return true
            }
            return false
        }
        if type == .keyDown {
            detector?.otherKeyDown()
            return false
        }
        if type == .flagsChanged, choice.modifierKeyCode != nil {
            let flag: CGEventFlags
            switch choice {
            case .rightCommand: flag = .maskCommand
            case .rightOption: flag = .maskAlternate
            case .rightControl: flag = .maskControl
            case .rightShift: flag = .maskShift
            case .fnKey: flag = .maskSecondaryFn
            default: return false
            }
            let all: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl,
                                     .maskShift, .maskSecondaryFn]
            let other = event.flags.intersection(all.subtracting(flag))
            if mode == .toggle {
                if detector?.flagsChanged(keyCode: code,
                                         targetFlagPresent: event.flags.contains(flag),
                                         otherModifierPresent: !other.isEmpty) == true {
                    requestCompletedTap(at: Double(event.timestamp) / 1_000_000_000)
                }
            } else if let pressed = detector?.activationEdge(keyCode: code,
                                      targetFlagPresent: event.flags.contains(flag),
                                      otherModifierPresent: !other.isEmpty) {
                requestEdge(pressed, at: Double(event.timestamp) / 1_000_000_000)
            }
        }
        return false
    }

    // Both the timer and event-tap callbacks run on the dedicated worker.
    // After two physically confirmed UP samples, resolve a missing release.
    // If the key remains held, the detector is never re-armed by the timer.
    private func reconcileLostModifierUp() {
        guard isActive, let code = choice.modifierKeyCode,
              detector?.isHeld == true, CGPreflightListenEventAccess() else {
            releaseUpSamples = 0
            return
        }
        if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) {
            releaseUpSamples = 0
            return
        }
        releaseUpSamples += 1
        guard releaseUpSamples >= 2 else { return }
        releaseUpSamples = 0
        if detector?.isHeld == true {
            let completedTap = detector?.recoverPhysicalRelease() == true
            let time = ProcessInfo.processInfo.systemUptime
            if mode == .toggle {
                if completedTap { requestCompletedTap(at: time) }
            } else {
                requestEdge(false, at: time)
            }
            DispatchQueue.main.async {
                DiagnosticLog.record("modifier missing key-up recovered using physical state")
            }
        }
    }

    // Deliver a toggle tap together so recovery cannot leave a policy press down.
    private func requestCompletedTap(at time: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            self.onEdge(true, time)
            self.onEdge(false, time)
        }
    }

    private func requestEdge(_ pressed: Bool, at time: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isActive == true else { return }
            self?.onEdge(pressed, time)
        }
    }

    deinit { stop() }
}
#else
@main struct KoeBridgeLaunch {
    static func main() { print("KoeBridge requires macOS 15 or newer.") }
}
#endif
