#if os(macOS)
import AppKit
import KoeBridgeCore

/// Main-run-loop, listen-only mouse tap. Clicks always reach their normal target.
@MainActor final class MouseShortcutMonitor {
    private let button: MouseTriggerButton
    private let onEdge: (Bool, TimeInterval) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var active = false
    private var isHeld = false

    init(button: MouseTriggerButton, onEdge: @escaping (Bool, TimeInterval) -> Void) {
        self.button = button
        self.onEdge = onEdge
    }

    func start() {
        guard button != .none else { return }
        let mask = (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
            place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, raw in
                guard let raw else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<MouseShortcutMonitor>.fromOpaque(raw).takeUnretainedValue()
                // Installed on the main run loop; policy and controller remain main-actor owned.
                MainActor.assumeIsolated {
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if monitor.isHeld {
                            monitor.onEdge(false, ProcessInfo.processInfo.systemUptime)
                            monitor.isHeld = false
                        }
                        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    } else if monitor.active,
                              event.getIntegerValueField(.mouseEventButtonNumber) == monitor.button.buttonNumber,
                              type == .otherMouseDown || type == .otherMouseUp {
                        monitor.isHeld = type == .otherMouseDown
                        monitor.onEdge(type == .otherMouseDown, Double(event.timestamp) / 1_000_000_000)
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            DiagnosticLog.record("mouse shortcut event tap registration failed; Input Monitoring permission may be required")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            DiagnosticLog.record("mouse shortcut event tap run-loop source creation failed")
            return
        }
        self.tap = tap
        self.source = source
        active = true
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        // Invalidate the callback before its unretained owner is released.
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    func stop() {
        if isHeld {
            onEdge(false, ProcessInfo.processInfo.systemUptime)
            isHeld = false
        }
        active = false
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }
}
#endif
