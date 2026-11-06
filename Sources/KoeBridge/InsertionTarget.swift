#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import KoeBridgeCore

/// A conservative target snapshot. Never activate another application just to type.
struct InsertionTarget {
    let pid: pid_t
    let focused: CFTypeRef
    let window: CFTypeRef?
    let selectionAttribute: String?
    private(set) var selection: CFTypeRef?
    private(set) var textSnapshot: InsertionReceiptPolicy.Snapshot?
    private(set) var capturedAt: TimeInterval
    private var blockedReason: String?

    var isBlocked: Bool { blockedReason != nil }

    private static func copyAX(_ element: AXUIElement, name: CFString,
                               timeout: Float = 0.08) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    /// Capture and revalidation must use the same resolution rule. Some web
    /// editors expose focus on the application's tree but not the system tree.
    private static func focusedElement(for pid: pid_t, timeout: Float = 0.08) -> CFTypeRef? {
        let app = AXUIElementCreateApplication(pid)
        let system = AXUIElementCreateSystemWide()
        for root in [app, system] {
            guard let candidate = copyAX(root, name: kAXFocusedUIElementAttribute as CFString,
                                         timeout: timeout),
                  CFGetTypeID(candidate) == AXUIElementGetTypeID() else { continue }
            let element = unsafeBitCast(candidate, to: AXUIElement.self)
            var owner: pid_t = 0
            if AXUIElementGetPid(element, &owner) == .success && owner == pid {
                return candidate
            }
        }
        return nil
    }

    /// AX grants belong to the actual running process, including its signature.
    static func capture() -> (target: InsertionTarget?, reason: String) {
        guard AXIsProcessTrusted() else { return (nil, "accessibility_not_granted") }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return (nil, "no_frontmost_application")
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return (nil, "koebridge_window_is_frontmost")
        }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = focusedElement(for: app.processIdentifier) else {
            return (nil, "focused_text_element_unavailable")
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success,
              owner == app.processIdentifier else { return (nil, "focus_owner_mismatch") }
        let window = copyAX(appAX, name: kAXFocusedWindowAttribute as CFString)
        let selectionAttribute: String?
        let selection: CFTypeRef?
        if let range = copyAX(element, name: kAXSelectedTextRangeAttribute as CFString) {
            selectionAttribute = kAXSelectedTextRangeAttribute as String
            selection = range
        } else if let marker = copyAX(element, name: "AXSelectedTextMarkerRange" as CFString) {
            selectionAttribute = "AXSelectedTextMarkerRange"
            selection = marker
        } else {
            selectionAttribute = nil
            selection = nil
        }
        var target = InsertionTarget(pid: app.processIdentifier, focused: focused,
                                     window: window, selectionAttribute: selectionAttribute,
                                     selection: selection, textSnapshot: nil,
                                     capturedAt: ProcessInfo.processInfo.systemUptime,
                                     blockedReason: nil)
        // Keep this local and ephemeral. It is never sent to a model or logged.
        // A second bounded attempt covers an editor consuming an earlier take.
        if selectionAttribute == kAXSelectedTextRangeAttribute as String {
            for _ in 0..<2 {
                if let observed = target.observedSnapshot(timeout: 0.04) {
                    target.textSnapshot = observed.snapshot
                    target.selection = observed.selection
                    break
                }
            }
        }
        target.capturedAt = ProcessInfo.processInfo.systemUptime
        return (target, "ok")
    }

    /// Many browser editors do not expose AXValue. Unknown contents never
    /// authorize a caret rebase, and secure field contents are not collected.
    func observedValue(timeout: Float = 0.04) -> String? {
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, timeout)
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == "AXSecureTextField" { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              text.utf16.count <= InsertionReceiptPolicy.maximumObservableUTF16Count else { return nil }
        return text
    }

    /// Read text between two equal selections, so a moving editor does not
    /// combine a previous caret with a later partial value. Opaque marker
    /// ranges cannot be turned into numeric offsets by guessing.
    func observedSnapshot(timeout: Float) -> (snapshot: InsertionReceiptPolicy.Snapshot,
                                                          selection: CFTypeRef)? {
        guard selectionAttribute == kAXSelectedTextRangeAttribute as String,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        guard let first = Self.copyAX(element, name: kAXSelectedTextRangeAttribute as CFString,
                                      timeout: timeout),
              let text = observedValue(timeout: timeout),
              let last = Self.copyAX(element, name: kAXSelectedTextRangeAttribute as CFString,
                                     timeout: timeout),
              CFEqual(first, last), let range = Self.numericSelection(last) else { return nil }
        let snapshot = InsertionReceiptPolicy.Snapshot(text: text, selection: range)
        guard InsertionReceiptPolicy.isValid(snapshot) else { return nil }
        return (snapshot, last)
    }

    private static func numericSelection(_ value: CFTypeRef) -> InsertionReceiptPolicy.Selection? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return InsertionReceiptPolicy.Selection(location: range.location, length: range.length)
    }

    func sameElement(as other: InsertionTarget) -> Bool {
        pid == other.pid && CFEqual(focused, other.focused)
    }

    func sameField(as other: InsertionTarget) -> Bool {
        guard sameElement(as: other) else { return false }
        switch (window, other.window) {
        case (nil, nil): return true
        case (let lhs?, let rhs?): return CFEqual(lhs, rhs)
        default: return false
        }
    }

    func rebased(to snapshot: InsertionReceiptPolicy.Snapshot) -> InsertionTarget? {
        guard blockedReason == nil,
              selectionAttribute == kAXSelectedTextRangeAttribute as String else { return nil }
        var range = CFRange(location: snapshot.selection.location, length: snapshot.selection.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var updated = self
        updated.selection = value
        updated.textSnapshot = snapshot
        return updated
    }

    func blockedByPriorInput() -> InsertionTarget {
        var updated = self
        updated.blockedReason = "prior_input_unverified"
        return updated
    }

    func focusCheck(requireOriginalSelection: Bool = true,
                    timeout: Float = 0.08) -> (allowed: Bool, reason: String) {
        if let blockedReason { return (false, blockedReason) }
        let sameProcess = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        guard sameProcess else { return (false, "active_app_changed") }
        guard let currentFocused = Self.focusedElement(for: pid, timeout: timeout) else {
            return (false, "focused_element_missing_on_recheck")
        }
        let sameElement = CFEqual(focused, currentFocused)
        guard sameElement else { return (false, "focused_field_changed") }
        let sameWindow: Bool
        if let original = window {
            let appAX = AXUIElementCreateApplication(pid)
            sameWindow = Self.copyAX(appAX, name: kAXFocusedWindowAttribute as CFString,
                                     timeout: timeout).map { CFEqual(original, $0) } ?? false
        } else { sameWindow = true }
        var selectionMatches: Bool?
        let element = unsafeBitCast(currentFocused, to: AXUIElement.self)
        var focusedPID: pid_t = 0
        let sameElementOwner = AXUIElementGetPid(element, &focusedPID) == .success && focusedPID == pid
        if requireOriginalSelection, let selectionAttribute, let selection {
            selectionMatches = Self.copyAX(element, name: selectionAttribute as CFString,
                                           timeout: timeout).map { CFEqual(selection, $0) } ?? false
        }
        guard sameWindow else { return (false, "focused_window_changed") }
        guard sameElementOwner else { return (false, "focused_element_owner_changed") }
        if selectionMatches == false { return (false, "caret_or_selection_changed") }
        let permitted = InsertionFocusPolicy.mayPaste(sameProcess: sameProcess,
                                                       sameWindow: sameWindow,
                                                       sameElement: sameElement,
                                                       selectionMatches: selectionMatches,
                                                       sameElementOwner: sameElementOwner)
        return (permitted, permitted ? "ok" : "focus_verification_failed")
    }

    func stillCurrent(requireOriginalSelection: Bool = true) -> Bool {
        focusCheck(requireOriginalSelection: requireOriginalSelection).allowed
    }
}

#endif
