#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import KoeBridgeCore

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
            guard !candidate.isBlocked else { return nil }
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
            guard let target, eventsPosted, !candidate.isBlocked else { return candidate }
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
            // A long synchronous loop starves MainActor stop/cancel actions.
            // Yield between small batches, then revalidate before posting any
            // more keys. The serial sender still owns this entire delivery.
            if index > 0 && index % 4 == 0 { await Task.yield() }
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
