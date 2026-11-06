#if os(macOS)
import AppKit
import Carbon
import Darwin
import KoeBridgePOSIX
import CoreGraphics
import SwiftUI
import KoeBridgeCore

/// Presets verified against shipped source / official shortcut documentation.
/// Existing persisted keys (including F8/F9) are preserved by their raw values.
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

@MainActor final class KoeBridgeAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var shortcut: GlobalShortcut?
    private let windows = AppWindows()
    private let controller = VoiceController.shared
    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowKeyMonitor: Any?
    private var updateCheckTimer: Timer?
    private let recentHistoryMenu = NSMenu(title: "認識履歴（直近10件）")

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "KoeBridge")
        let menu = NSMenu()
        menu.delegate = self
        recentHistoryMenu.delegate = self
        item.menu = menu

        // This never activates KoeBridge or takes keyboard focus from the text field.
        controller.onShowPreview = { [weak self] in self?.windows.showPreview() }
        controller.onHidePreview = { [weak self] in self?.windows.hidePreview() }
        controller.onShowHistory = { [weak self] in self?.windows.showHistory() }
        controller.onShowPermissions = { [weak self] in self?.windows.showPermissions() }
        installWindowShortcuts()

        shortcut = GlobalShortcut()
        controller.onShortcutChange = { [weak self] choice in
            self?.shortcut?.register(choice) ?? false
        }
        controller.onShortcutRearm = { [weak self] choice in
            self?.shortcut?.register(choice, rearm: true) ?? false
        }
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentHistoryMenu {
            populateRecentHistoryMenu(menu)
            return
        }
        guard menu === item.menu else { return }
        menu.removeAllItems()
        let title = controller.isRecording ? "■ 音声入力を確定" : "● 音声入力を開始"
        add(menu, title, #selector(toggle))
        // Native AppKit submenus open on mouse hover or keyboard navigation.
        let historyItem = NSMenuItem(title: "認識履歴（直近10件）", action: nil, keyEquivalent: "")
        historyItem.submenu = recentHistoryMenu
        menu.addItem(historyItem)
        add(menu, "設定…", #selector(showSettings))
        add(menu, "アップデートを確認…", #selector(checkForUpdates))
        add(menu, "マイク・自動入力の権限…", #selector(showPermissions))
        if controller.busy { add(menu, "録音を破棄", #selector(discard)) }
        menu.addItem(.separator())
        add(menu, "KoeBridgeを終了", #selector(quit))
    }

    private func populateRecentHistoryMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = RecentHistoryMenuPolicy.entries(from: controller.history)
        if entries.isEmpty {
            let title = controller.historyProblem.isEmpty
                ? "保存された認識履歴はありません" : "履歴を読み込めません"
            let empty = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, entry) in entries.enumerated() {
                let date = entry.recordedAt.formatted(date: .abbreviated, time: .shortened)
                let row = NSMenuItem(
                    title: "\(index + 1). \(date)  \(entry.preview)",
                    action: #selector(copyRecentHistory(_:)), keyEquivalent: ""
                )
                row.target = self
                row.representedObject = entry.recordID.uuidString
                row.toolTip = entry.copyHelp
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        add(menu, "履歴をすべて表示…", #selector(showHistory))
    }

    /// A click copies the exact stored text. No typing, app activation,
    /// clipboard modification on hover, or new transcription is performed.
    @objc private func copyRecentHistory(_ sender: NSMenuItem) {
        let copied: Bool
        if let raw = sender.representedObject as? String,
           let id = UUID(uuidString: raw),
           let record = controller.history.first(where: { $0.id == id }) {
            copied = controller.copyRecord(record)
        } else {
            copied = false // A record may have been deleted while the menu was open.
        }
        // Let native menu tracking close before presenting a no-focus HUD.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            self.windows.showClipboardFeedback(success: copied, statusButton: self.item.button)
        }
    }

    private func add(_ menu: NSMenu, _ title: String, _ selector: Selector) {
        let menuItem = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        menuItem.target = self
    }
    @objc private func toggle() { controller.toggle() }
    @objc private func showHistory() { windows.showHistory() }
    @objc private func showSettings() { windows.showSettings() }
    @objc private func checkForUpdates() {
        windows.showSettings()
        let updater = KoeBridgeUpdateManager.shared
        updater.requestUpdatePage()
        Task { await updater.checkNow() }
    }
    @objc private func showPermissions() { windows.showPermissions() }
    @objc private func discard() { controller.discard() }
    @objc private func quit() { controller.discard(); NSApp.terminate(nil) }
}

/// Carbon for standard combinations, Quartz event tap for bare right-side
/// modifiers. Re-registration is transactional: a failed new shortcut leaves
/// the previously working one installed.
@MainActor private final class GlobalShortcut {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var modifierMonitor: ModifierShortcutMonitor?
    private var activeChoice: RecordingShortcut?
    private var nextHotKeyID: UInt32 = 1
    private var carbonGate = HotKeyPressGate()
    private var carbonReleaseRecovery: Task<Void, Never>?

    init() {
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
        guard shouldToggle else { return }
        VoiceController.shared.toggle()
        scheduleCarbonReleaseRecovery(id: id)
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
                        DiagnosticLog.record("carbon missing key-up recovered using physical state")
                        return
                    }
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    func register(_ choice: RecordingShortcut, rearm: Bool = false) -> Bool {
        if activeChoice == choice && !rearm { return true }
        carbonReleaseRecovery?.cancel()
        carbonReleaseRecovery = nil
        // In the Settings retry path, a monitor can report as registered even
        // after macOS disabled its event tap or lost the key-release event.
        // Rebuild the monitor rather than returning true without doing anything.
        if choice.usesEventTap {
            let candidate = ModifierShortcutMonitor(choice: choice)
            guard candidate.start() else {
                DiagnosticLog.record("modifier shortcut event tap registration failed")
                return false
            }
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
        let id = EventHotKeyID(signature: OSType(0x4B4F4542), id: nextHotKeyID)
        nextHotKeyID &+= 1
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(choice.keyCode, choice.modifiers, id,
                                         GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let candidate else {
            DiagnosticLog.record("carbon hotkey registration failed; OSStatus=\(status)")
            if removedForRearm {
                // Re-registration during a manual retry can lose a race with
                // another shortcut owner. Attempt to recover the old binding.
                let rollback = EventHotKeyID(signature: OSType(0x4B4F4542), id: nextHotKeyID)
                nextHotKeyID &+= 1
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

    init(choice: RecordingShortcut) {
        self.choice = choice
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
                return true
            }
            if type == .keyDown && code == Int(kVK_Space) {
                let others: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
                guard event.flags.contains(.maskSecondaryFn),
                      event.flags.intersection(others).isEmpty else { return false }
                if !fnSpaceHeld && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    fnSpaceHeld = true
                    requestToggle()
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
            if detector?.flagsChanged(keyCode: code,
                                      targetFlagPresent: event.flags.contains(flag),
                                      otherModifierPresent: !other.isEmpty) == true {
                requestToggle()
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
        if detector?.recoverPhysicalRelease() == true {
            requestToggle()
            DispatchQueue.main.async {
                DiagnosticLog.record("modifier missing key-up recovered using physical state")
            }
        }
    }

    private func requestToggle() {
        DispatchQueue.main.async { [weak self] in
            guard self?.isActive == true else { return }
            VoiceController.shared.toggle()
        }
    }

    deinit { stop() }
}
#else
@main struct KoeBridgeLaunch {
    static func main() { print("KoeBridge requires macOS 15 or newer.") }
}
#endif
