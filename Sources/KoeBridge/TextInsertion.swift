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
    let selection: CFTypeRef?

    private static func copyAX(_ element: AXUIElement, name: CFString) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.75)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    /// Prefer the application's own accessibility tree. Some web/electron
    /// editors expose focus there but not through the system-wide tree.
    /// Both capture AND later validation must use the same resolution rule.
    private static func focusedElement(for pid: pid_t) -> CFTypeRef? {
        let app = AXUIElementCreateApplication(pid)
        let system = AXUIElementCreateSystemWide()
        for root in [app, system] {
            guard let candidate = copyAX(root, name: kAXFocusedUIElementAttribute as CFString),
                  CFGetTypeID(candidate) == AXUIElementGetTypeID() else { continue }
            let element = unsafeBitCast(candidate, to: AXUIElement.self)
            var owner: pid_t = 0
            if AXUIElementGetPid(element, &owner) == .success && owner == pid {
                return candidate
            }
        }
        return nil
    }

    /// Return a machine-readable reason rather than silently dropping input.
    /// AX grants are process-specific; a visible enabled toggle in Settings
    /// does not prove that this running (possibly re-signed) process is trusted.
    static func capture() -> (target: InsertionTarget?, reason: String) {
        guard AXIsProcessTrusted() else { return (nil, "accessibility_not_granted") }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return (nil, "no_frontmost_application")
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return (nil, "koebridge_window_is_frontmost")
        }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        // This same helper is also used by stillCurrent().
        // Otherwise an app-tree capture can fail validation even without
        // any genuine focus change.
        guard let focused = focusedElement(for: app.processIdentifier) else {
            return (nil, "focused_text_element_unavailable")
        }
        let focusedElement = unsafeBitCast(focused, to: AXUIElement.self)
        var owner: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &owner) == .success,
              owner == app.processIdentifier else {
            return (nil, "focus_owner_mismatch")
        }
        let window = copyAX(appAX, name: kAXFocusedWindowAttribute as CFString)
        let selectionAttribute: String?
        let selection: CFTypeRef?
        if let range = copyAX(focusedElement, name: kAXSelectedTextRangeAttribute as CFString) {
            selectionAttribute = kAXSelectedTextRangeAttribute as String
            selection = range
        } else if let marker = copyAX(focusedElement, name: "AXSelectedTextMarkerRange" as CFString) {
            selectionAttribute = "AXSelectedTextMarkerRange"
            selection = marker
        } else {
            selectionAttribute = nil
            selection = nil
        }
        return (InsertionTarget(pid: app.processIdentifier, focused: focused,
                                window: window, selectionAttribute: selectionAttribute,
                                selection: selection), "ok")
    }

    /// Read the current editable text only to assess whether a posted event
    /// had an observable effect; never log or persist the field's contents.
    /// Many browser editors do not expose AXValue, so nil is not an error.
    func observedValue() -> String? {
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        // Optional diagnostics must not recreate the old seconds-long lag.
        // Do NOT use the normal 750ms focus-query timeout for read-back.
        AXUIElementSetMessagingTimeout(element, 0.12)
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == "AXSecureTextField" { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, text.utf16.count <= 200_000 else { return nil }
        return text
    }

    func focusCheck(requireOriginalSelection: Bool = true) -> (allowed: Bool, reason: String) {
        let sameProcess = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        guard sameProcess else { return (false, "active_app_changed") }
        let currentFocused = Self.focusedElement(for: pid)
        guard let currentFocused else { return (false, "focused_element_missing_on_recheck") }
        let sameElement = CFEqual(focused, currentFocused)
        guard sameElement else { return (false, "focused_field_changed") }
        let sameWindow: Bool
        if let original = window {
            let appAX = AXUIElementCreateApplication(pid)
            sameWindow = Self.copyAX(appAX, name: kAXFocusedWindowAttribute as CFString)
                .map { CFEqual(original, $0) } ?? false
        } else { sameWindow = true }
        var selectionMatches: Bool?
        let element = unsafeBitCast(currentFocused, to: AXUIElement.self)
        var focusedPID: pid_t = 0
        let sameElementOwner = AXUIElementGetPid(element, &focusedPID) == .success && focusedPID == pid
        if requireOriginalSelection, let selectionAttribute, let selection {
            let focusedElement = element
            selectionMatches = Self.copyAX(focusedElement, name: selectionAttribute as CFString)
                .map { CFEqual(selection, $0) } ?? false
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

@MainActor enum TextInsertion {
    enum Result {
        case inserted             // Events sent; receiving app acceptance not proven.
        case partiallySubmitted   // Some events sent before focus change/failure.
        case focusChanged
        case notPermitted
        case eventPermissionMissing
        case eventUnavailable
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Posting synthesized keys is protected separately from reading AX state.
    /// AXIsProcessTrusted() alone does not guarantee CGEventPost permission.
    static var mayPostEvents: Bool { CGPreflightPostEventAccess() }

    /// Invoke only from a deliberate user action, NEVER while recording.
    @discardableResult static func requestPostEventAccess() -> Bool {
        CGRequestPostEventAccess()
    }

    /// Never prompt during dictation: prompts can steal the input focus.
    @discardableResult static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Browser and Electron editors can acknowledge an AXSelectedText write
    /// without updating their actual editable document. v0.4.1 treated that
    /// acknowledgment as completed typing, silently losing the transcript.
    ///
    /// Do not use AXSelectedText as the normal insertion mechanism. A Unicode
    /// keyboard event is the only automatic transport; it never touches the
    /// general pasteboard. It is still not guaranteed to be accepted by every
    /// application, which is why an optional read-back records observability.
    private static func observeAfterTyping(_ target: InsertionTarget,
                                           before: String?, inserted: String) {
        Task { @MainActor in
            // Deliveries are asynchronous across application processes.
            try? await Task.sleep(for: .milliseconds(180))
            // A following F8 is higher priority than optional read-back.
            guard !VoiceController.shared.busy else {
                DiagnosticLog.record("direct input observation=skipped_next_recording")
                return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
                DiagnosticLog.record("direct input observation=skipped_focus_changed")
                return
            }
            let after = target.observedValue()
            switch DirectInputObservation.classify(before: before,
                                                    after: after,
                                                    inserted: inserted) {
            case .verifiedInsertion:
                DiagnosticLog.record("direct input observation=verified_ax_value_change")
            case .unchanged:
                DiagnosticLog.record("direct input observation=ax_value_unchanged_at_180ms; no_automatic_retry")
            case .changedButUnverified:
                DiagnosticLog.record("direct input observation=ax_value_changed_but_unverified; no_automatic_retry")
            case .unobservable:
                DiagnosticLog.record("direct input observation=unavailable; transport_unverified")
            }
        }
    }

    /// Automatic delivery is clipboard-free. Synthetic Unicode events are used
    /// even when an app advertises a writable AXSelectedText attribute: some
    /// apps report AX success but silently ignore that write. NEVER retry on
    /// an unverified delivery; doing so can duplicate text.
    static func deliver(_ text: String, to target: InsertionTarget?) -> Result {
        let parts = UnicodeTypingPlan.chunks(text)
        guard !parts.isEmpty else { return .eventUnavailable }
        let axAllowed = isTrusted
        let postAllowed = mayPostEvents
        guard PermissionSetupPolicy.mayAttemptDirectInput(
            accessibilityGranted: axAllowed,
            postEventGranted: postAllowed,
            targetCaptured: target != nil) else {
            let reason = !axAllowed ? "accessibility_missing"
                : (!postAllowed ? "post_event_permission_missing" : "target_not_captured")
            DiagnosticLog.record("direct typing blocked; reason=\(reason)")
            if !axAllowed { return .notPermitted }
            if !postAllowed { return .eventPermissionMissing }
            return .focusChanged
        }
        guard let target else { return .focusChanged }
        let initialFocus = target.focusCheck()
        guard initialFocus.allowed else {
            DiagnosticLog.record("direct typing blocked; reason=\(initialFocus.reason)")
            return .focusChanged
        }
        let diagnosticsActive = DiagnosticLog.isEnabled
        let beforeValue = diagnosticsActive ? target.observedValue() : nil
        DiagnosticLog.record("direct input path=unicode_keyboard_primary; chunks=\(parts.count); axValueObservable=\(beforeValue != nil)")
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .eventUnavailable
        }
        var sent = 0
        for (index, part) in parts.enumerated() {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid {
                return sent == 0 ? .focusChanged : .partiallySubmitted
            }
            // The selection/caret changes as characters are entered. Check
            // the original selection only BEFORE the first synthetic event.
            // Periodic focus checks limit text sent to the wrong field.
            if index % 4 == 0 {
                let check = target.focusCheck(requireOriginalSelection: index == 0)
                if !check.allowed {
                    DiagnosticLog.record("direct typing interrupted; reason=\(check.reason); eventsSent=\(sent)")
                    return sent == 0 ? .focusChanged : .partiallySubmitted
                }
            }
            let units = Array(part.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0), keyDown: false) else {
                return sent == 0 ? .eventUnavailable : .partiallySubmitted
            }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            // Never turn dictation into a keyboard shortcut.
            down.flags = []
            up.flags = []
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            sent += 1
        }
        DiagnosticLog.record("direct typing posted; path=unicode_keyboard_primary; chunksSent=\(sent); destinationAcceptance=unverified; clipboard=untouched")
        if diagnosticsActive {
            observeAfterTyping(target, before: beforeValue,
                               inserted: UnicodeTypingPlan.safeText(text))
        }
        return .inserted
    }

    /// Only explicit user action in the History panel uses the clipboard.
    @discardableResult static func copy(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}
#endif
