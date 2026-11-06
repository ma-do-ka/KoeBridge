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
    fileprivate var textSnapshot: InsertionReceiptPolicy.Snapshot?
    fileprivate var capturedAt: TimeInterval
    fileprivate var blockedReason: String?

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
    fileprivate func observedSnapshot(timeout: Float) -> (snapshot: InsertionReceiptPolicy.Snapshot,
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

    fileprivate func sameElement(as other: InsertionTarget) -> Bool {
        pid == other.pid && CFEqual(focused, other.focused)
    }

    fileprivate func sameField(as other: InsertionTarget) -> Bool {
        guard sameElement(as: other) else { return false }
        switch (window, other.window) {
        case (nil, nil): return true
        case (let lhs?, let rhs?): return CFEqual(lhs, rhs)
        default: return false
        }
    }

    fileprivate func rebased(to snapshot: InsertionReceiptPolicy.Snapshot) -> InsertionTarget? {
        guard blockedReason == nil,
              selectionAttribute == kAXSelectedTextRangeAttribute as String else { return nil }
        var range = CFRange(location: snapshot.selection.location, length: snapshot.selection.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var updated = self
        updated.selection = value
        updated.textSnapshot = snapshot
        return updated
    }

    fileprivate func blockedByPriorInput() -> InsertionTarget {
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

@MainActor enum TextInsertion {
    enum Result {
        case verifiedInserted
        case inserted             // All events posted; receiving app acceptance unconfirmed.
        case partiallySubmitted   // Some events posted; never automatically retry.
        case cancelled            // Cancelled before any events were posted.
        case focusChanged
        case notPermitted
        case eventPermissionMissing
        case eventUnavailable
    }

    struct Receipt {
        fileprivate let target: InsertionTarget
        fileprivate let proof: InsertionReceiptPolicy.Receipt
        fileprivate let postedAt: TimeInterval
        fileprivate let verifiedAt: TimeInterval

        func rebased(_ candidate: InsertionTarget) -> InsertionTarget? {
            guard candidate.blockedReason == nil else { return nil }
            let reconciliation = InsertionReceiptPolicy.reconcile(
                candidate.textSnapshot, using: proof,
                sameTarget: candidate.sameField(as: target), eventsPosted: true,
                capturedDuringSubmission: candidate.capturedAt >= postedAt
                    && candidate.capturedAt <= verifiedAt)
            guard case .rebased(let snapshot) = reconciliation else { return nil }
            return candidate.rebased(to: snapshot)
        }
    }

    struct Report {
        let outcome: Result
        let reason: String
        let receipt: Receipt?
        let eventsPosted: Bool
        fileprivate let target: InsertionTarget?

        /// Run for every still-live take before advancing the serial sender.
        /// A successful event post by itself must never unlock the next take.
        func reconciled(_ candidate: InsertionTarget) -> InsertionTarget {
            guard let target, eventsPosted, candidate.blockedReason == nil else { return candidate }
            let reconciliation = InsertionReceiptPolicy.reconcile(
                candidate.textSnapshot, using: receipt?.proof,
                sameTarget: candidate.sameField(as: target), eventsPosted: eventsPosted,
                mayShareTarget: candidate.sameElement(as: target),
                capturedDuringSubmission: receipt.map {
                    candidate.capturedAt >= $0.postedAt && candidate.capturedAt <= $0.verifiedAt
                } ?? false)
            switch reconciliation {
            case .unchanged: return candidate
            case .rebased(let snapshot): return candidate.rebased(to: snapshot) ?? candidate.blockedByPriorInput()
            case .blocked: return candidate.blockedByPriorInput()
            }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }
    static var mayPostEvents: Bool { CGPreflightPostEventAccess() }

    /// Invoke only from a deliberate user action, never while recording.
    @discardableResult static func requestPostEventAccess() -> Bool {
        CGRequestPostEventAccess()
    }

    @discardableResult static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Clipboard-free, serial delivery. Read-back is bounded and runs while a
    /// following recording may continue. No outcome ever resubmits posted keys.
    static func deliver(_ text: String, to target: InsertionTarget?,
                        shouldContinue: @MainActor () -> Bool = { true }) async -> Report {
        var sent = 0
        func report(_ outcome: Result, _ reason: String, receipt: Receipt? = nil) -> Report {
            Report(outcome: outcome, reason: reason, receipt: receipt,
                   eventsPosted: sent > 0, target: target)
        }
        guard !Task.isCancelled, shouldContinue() else {
            return report(.cancelled, "delivery_cancelled_before_post")
        }
        let safeText = UnicodeTypingPlan.safeText(text)
        let parts = UnicodeTypingPlan.chunks(text)
        guard !parts.isEmpty else { return report(.eventUnavailable, "empty_typing_payload") }
        let axAllowed = isTrusted
        let postAllowed = mayPostEvents
        guard PermissionSetupPolicy.mayAttemptDirectInput(
            accessibilityGranted: axAllowed, postEventGranted: postAllowed,
            targetCaptured: target != nil) else {
            if !axAllowed { return report(.notPermitted, "accessibility_not_granted") }
            if !postAllowed { return report(.eventPermissionMissing, "post_event_permission_missing") }
            return report(.focusChanged, "target_not_captured")
        }
        guard let target else { return report(.focusChanged, "target_not_captured") }
        let initialFocus = target.focusCheck()
        guard initialFocus.allowed else { return report(.focusChanged, initialFocus.reason) }
        let before = target.observedSnapshot(timeout: 0.04)?.snapshot
        // The same caret does not prove that a user left the document alone.
        // When a readable baseline exists, reject other edits to its contents.
        if let captured = target.textSnapshot {
            guard let before else { return report(.focusChanged, "field_value_unavailable_on_recheck") }
            guard captured == before else { return report(.focusChanged, "field_value_or_selection_changed") }
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return report(.eventUnavailable, "event_source_unavailable")
        }
        let postedAt = ProcessInfo.processInfo.systemUptime
        for (index, part) in parts.enumerated() {
            guard !Task.isCancelled, shouldContinue() else {
                return report(sent == 0 ? .cancelled : .partiallySubmitted,
                              sent == 0 ? "delivery_cancelled_before_post" : "delivery_cancelled_after_partial_post")
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid {
                return report(sent == 0 ? .focusChanged : .partiallySubmitted, "active_app_changed")
            }
            // Own input moves the selection. Keep field/window/owner checks
            // throughout, and the original caret check until the first post.
            if index % 4 == 0 {
                let check = target.focusCheck(requireOriginalSelection: index == 0)
                if !check.allowed {
                    return report(sent == 0 ? .focusChanged : .partiallySubmitted, check.reason)
                }
            }
            let units = Array(part.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0), keyDown: false) else {
                return report(sent == 0 ? .eventUnavailable : .partiallySubmitted, "keyboard_event_unavailable")
            }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.flags = []
            up.flags = []
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            sent += 1
        }
        DiagnosticLog.record("direct typing posted; chunksSent=\(sent); destinationAcceptance=unverified; clipboard=untouched")
        guard let before,
              let expected = InsertionReceiptPolicy.expectedAfter(before: before, inserted: safeText),
              !InsertionReceiptPolicy.sameText(before.text, expected.text) else {
            return report(.inserted, "posted_without_observable_edit")
        }

        // A short finite polling budget replaces fire-and-forget diagnostics.
        // AX timeouts also shrink with the remaining budget. Do not skip this
        // because the next recording is active: that is the key overlap case.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        for _ in 0..<10 {
            guard !Task.isCancelled, shouldContinue() else {
                return report(.inserted, "delivery_cancelled_after_post")
            }
            do { try await Task.sleep(for: .milliseconds(35)) }
            catch { return report(.inserted, "delivery_cancelled_after_post") }
            guard !Task.isCancelled, shouldContinue() else {
                return report(.inserted, "delivery_cancelled_after_post")
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0.02 else { break }
            let timeout = Float(min(0.035, remaining / 12))
            let focus = target.focusCheck(requireOriginalSelection: false, timeout: timeout)
            guard focus.allowed else { return report(.inserted, "posted_then_" + focus.reason) }
            guard let after = target.observedSnapshot(timeout: timeout)?.snapshot else { continue }
            guard let proof = InsertionReceiptPolicy.verify(before: before, inserted: safeText,
                                                            after: after, sameTarget: true) else { continue }
            // Focus may move while AX is answering. Recheck before accepting
            // the receipt, without imposing the already-replaced old caret.
            let finalFocus = target.focusCheck(requireOriginalSelection: false, timeout: timeout)
            guard finalFocus.allowed else { return report(.inserted, "posted_then_" + finalFocus.reason) }
            guard !Task.isCancelled, shouldContinue() else {
                return report(.inserted, "delivery_cancelled_after_post")
            }
            guard ProcessInfo.processInfo.systemUptime <= deadline else { break }
            let receipt = Receipt(target: target, proof: proof, postedAt: postedAt,
                                  verifiedAt: ProcessInfo.processInfo.systemUptime)
            DiagnosticLog.record("direct input receipt=verified_value_and_utf16_selection")
            return report(.verifiedInserted, "verified_value_and_selection", receipt: receipt)
        }
        DiagnosticLog.record("direct input receipt=unconfirmed; no_automatic_retry")
        return report(.inserted, "posted_receipt_timeout")
    }

    /// Only explicit user action in the History panel uses the clipboard.
    @discardableResult static func copy(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}
#endif
