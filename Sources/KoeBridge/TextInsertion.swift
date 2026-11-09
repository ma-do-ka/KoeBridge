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

        var diagnosticOutcome: InputDiagnosticEvent.Token {
            switch self {
            case .verifiedInserted: return .verified
            case .inserted: return .unconfirmed
            case .partiallySubmitted: return .partial
            case .cancelled: return .cancelled
            default: return .blocked
            }
        }
    }

    @MainActor struct Receipt {
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

    @MainActor struct Report {
        let outcome: Result
        let reason: String
        let receipt: Receipt?
        let eventsPosted: Bool
        fileprivate let target: InsertionTarget?
        fileprivate let diagnostics: InputDiagnosticTrace?

        /// Run for every still-live take before advancing the serial sender.
        /// A successful event post by itself must never unlock the next take.
        func reconciled(_ candidate: InsertionTarget, sourceTakeID: UUID? = nil,
                        candidateTakeID: UUID? = nil,
                        diagnostics nextDiagnostics: InputDiagnosticTrace? = nil) -> InsertionTarget {
            func record(_ outcome: InputDiagnosticEvent.Token, _ why: String) {
                func fields(related: UUID?) -> [InputDiagnosticEvent.Field: InputDiagnosticEvent.Value] {
                    let window: InputDiagnosticEvent.Token
                    if let target {
                        switch (target.window, candidate.window) {
                        case (nil, nil): window = .missing
                        case (let left?, let right?): window = CFEqual(left, right) ? .same : .different
                        default: window = .unavailable
                        }
                    } else { window = .unavailable }
                    var values: [InputDiagnosticEvent.Field: InputDiagnosticEvent.Value] = [
                        .outcome: .token(outcome), .reason: .reason(why), .priorReason: .reason(reason),
                        .eventsPosted: .flag(eventsPosted), .receiptAvailable: .flag(receipt != nil),
                        .element: .token(target.map { candidate.sameElement(as: $0) ? .same : .different } ?? .unavailable),
                        .window: .token(window),
                        .selection: .token(candidate.textSnapshot == nil ? .unavailable : .ok),
                        .capturedDuring: .flag(receipt.map {
                            candidate.capturedAt >= $0.postedAt && candidate.capturedAt <= $0.verifiedAt
                        } ?? false)
                    ]
                    if let related { values[.relatedTake] = .identifier(related) }
                    return values
                }
                diagnostics?.record(.reconcile, stage: .reconcile, fields(related: candidateTakeID))
                nextDiagnostics?.record(.reconcile, stage: .reconcile, fields(related: sourceTakeID))
            }
            guard let target, eventsPosted else {
                record(.unchanged, "no_events_posted")
                return candidate
            }
            guard !candidate.isBlocked else {
                record(.blocked, "already_blocked")
                return candidate
            }
            let reconciliation = InsertionReceiptPolicy.reconcile(
                candidate.textSnapshot, using: receipt?.proof,
                sameTarget: candidate.sameField(as: target), eventsPosted: eventsPosted,
                mayShareTarget: candidate.sameElement(as: target),
                capturedDuringSubmission: receipt.map {
                    candidate.capturedAt >= $0.postedAt && candidate.capturedAt <= $0.verifiedAt
                } ?? false)
            switch reconciliation {
            case .unchanged:
                record(.unchanged, "unrelated_target")
                return candidate
            case .rebased(let snapshot):
                if let updated = candidate.rebased(to: snapshot) {
                    record(.rebased, "verified_prior_input")
                    return updated
                }
                record(.blocked, "rebase_failed")
                return candidate.blockedByPriorInput()
            case .blocked:
                let why: String
                if !candidate.sameField(as: target) { why = "ambiguous_target" }
                else if receipt == nil { why = "prior_receipt_unavailable" }
                else if candidate.textSnapshot == nil { why = "candidate_snapshot_unavailable" }
                else if let snapshot = candidate.textSnapshot, !InsertionReceiptPolicy.isValid(snapshot) {
                    why = "invalid_candidate_snapshot"
                } else { why = "candidate_edit_unmatched" }
                record(.blocked, why)
                return candidate.blockedByPriorInput()
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
                        diagnostics: InputDiagnosticTrace? = nil,
                        shouldContinue: @MainActor () -> Bool = { true }) async -> Report {
        let beganAt = ProcessInfo.processInfo.systemUptime
        var sent = 0
        var planned = 0
        var polls = 0
        var unchanged = 0
        var textMismatches = 0
        var selectionMismatches = 0
        var unavailable = 0
        var receiptStartedAt: TimeInterval?
        var deadlineExceeded = false
        var budgetInsufficient = false
        func report(_ outcome: Result, _ reason: String, receipt: Receipt? = nil) -> Report {
            if let receiptStartedAt {
                diagnostics?.record(.receipt, stage: .receipt, [
                    .polls: .integer(polls), .unchanged: .integer(unchanged),
                    .textMismatch: .integer(textMismatches), .selectionMismatch: .integer(selectionMismatches),
                    .unavailable: .integer(unavailable),
                    .deadlineExceeded: .flag(deadlineExceeded
                        || ProcessInfo.processInfo.systemUptime > receiptStartedAt + 0.6),
                    .budgetInsufficient: .flag(budgetInsufficient),
                    .elapsedMS: .integer(InputDiagnosticTrace.milliseconds(since: receiptStartedAt))
                ])
            }
            diagnostics?.record(.result, stage: .result, [
                .outcome: .token(outcome.diagnosticOutcome), .reason: .reason(reason),
                .plannedChunks: .integer(planned), .sentChunks: .integer(sent),
                .eventsPosted: .flag(sent > 0), .receiptAvailable: .flag(receipt != nil),
                .totalMS: .integer(InputDiagnosticTrace.milliseconds(since: beganAt))
            ])
            return Report(outcome: outcome, reason: reason, receipt: receipt,
                          eventsPosted: sent > 0, target: target, diagnostics: diagnostics)
        }
        guard !Task.isCancelled, shouldContinue() else {
            return report(.cancelled, "delivery_cancelled_before_post")
        }
        let safeText = UnicodeTypingPlan.safeText(text)
        let parts = UnicodeTypingPlan.chunks(text)
        planned = parts.count
        guard !parts.isEmpty else { return report(.eventUnavailable, "empty_typing_payload") }
        let axAllowed = isTrusted
        let postAllowed = mayPostEvents
        if diagnostics?.isCollecting == true {
            let front = NSWorkspace.shared.frontmostApplication
            diagnostics?.record(.target, stage: .preflight, [
                .axTrusted: .flag(axAllowed), .postAllowed: .flag(postAllowed),
                .pid: .integer(Int(target?.pid ?? 0)),
                .frontPID: .integer(Int(front?.processIdentifier ?? 0)),
                .app: .application(front?.bundleIdentifier ?? ""),
                .captureAgeMS: .integer(target.map { InputDiagnosticTrace.milliseconds(since: $0.capturedAt) } ?? 0)
            ])
        }
        guard PermissionSetupPolicy.mayAttemptDirectInput(
            accessibilityGranted: axAllowed, postEventGranted: postAllowed,
            targetCaptured: target != nil) else {
            if !axAllowed { return report(.notPermitted, "accessibility_not_granted") }
            if !postAllowed { return report(.eventPermissionMissing, "post_event_permission_missing") }
            return report(.focusChanged, "target_not_captured")
        }
        guard let target else { return report(.focusChanged, "target_not_captured") }
        let initialFocus = target.focusCheck(diagnostics: diagnostics, stage: .preflight)
        guard initialFocus.allowed else { return report(.focusChanged, initialFocus.reason) }
        let before = target.observedSnapshot(timeout: 0.04, diagnostics: diagnostics, stage: .preflight)?.snapshot
        // The same caret does not prove that a user left the document alone.
        // When a readable baseline exists, reject other edits to its contents.
        if let captured = target.textSnapshot {
            guard let before else { return report(.focusChanged, "field_value_unavailable_on_recheck") }
            diagnostics?.record(.snapshot, stage: .preflight, [
                .text: .token(InsertionReceiptPolicy.sameText(captured.text, before.text) ? .same : .different),
                .selection: .token(captured.selection == before.selection ? .same : .different),
                .expectedStart: .integer(captured.selection.location),
                .expectedLength: .integer(captured.selection.length),
                .selectionStart: .integer(before.selection.location),
                .selectionLength: .integer(before.selection.length)
            ])
            guard captured == before else { return report(.focusChanged, "field_value_or_selection_changed") }
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return report(.eventUnavailable, "event_source_unavailable")
        }
        let modifierMask: CGEventFlags = [.maskAlphaShift, .maskShift, .maskControl,
                                         .maskAlternate, .maskCommand, .maskSecondaryFn]
        diagnostics?.record(.payload, stage: .posting, [
            .plannedChunks: .integer(planned), .valueUTF16: .integer(safeText.utf16.count),
            .modifiers: .integer(Int(CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).rawValue)),
            .hardwareModifiers: .integer(Int(CGEventSource.flagsState(.hidSystemState).intersection(modifierMask).rawValue))
        ])
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
                let check = target.focusCheck(requireOriginalSelection: index == 0,
                                              diagnostics: diagnostics, stage: .posting)
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
        diagnostics?.record(.payload, stage: .posting, [
            .sentChunks: .integer(sent), .eventsPosted: .flag(sent > 0), .outcome: .token(.unconfirmed)
        ])
        guard let before,
              let expected = InsertionReceiptPolicy.expectedAfter(before: before, inserted: safeText),
              !InsertionReceiptPolicy.sameText(before.text, expected.text) else {
            return report(.inserted, "posted_without_observable_edit")
        }

        // A short finite polling budget replaces fire-and-forget diagnostics.
        // AX timeouts also shrink with the remaining budget. Do not skip this
        // because the next recording is active: that is the key overlap case.
        let receiptBeganAt = ProcessInfo.processInfo.systemUptime
        receiptStartedAt = receiptBeganAt
        let deadline = receiptBeganAt + 0.6
        diagnostics?.record(.receipt, stage: .receipt, [
            .timeoutMS: .integer(600), .expectedStart: .integer(expected.selection.location),
            .expectedLength: .integer(expected.selection.length), .valueUTF16: .integer(expected.text.utf16.count)
        ])
        for _ in 0..<10 {
            guard !Task.isCancelled, shouldContinue() else {
                return report(.inserted, "delivery_cancelled_after_post")
            }
            let sleepStartedAt = ProcessInfo.processInfo.systemUptime
            do { try await Task.sleep(for: .milliseconds(35)) }
            catch { return report(.inserted, "delivery_cancelled_after_post") }
            guard !Task.isCancelled, shouldContinue() else {
                return report(.inserted, "delivery_cancelled_after_post")
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            diagnostics?.record(.receipt, stage: .receipt, [
                .waitMS: .integer(InputDiagnosticTrace.milliseconds(since: sleepStartedAt)),
                .remainingMS: .integer(Int(max(-86_400_000, min(86_400_000, remaining * 1_000))))
            ])
            guard remaining > 0.02 else {
                budgetInsufficient = true
                deadlineExceeded = remaining <= 0
                break
            }
            polls += 1
            let timeout = Float(min(0.035, remaining / 12))
            let focus = target.focusCheck(requireOriginalSelection: false, timeout: timeout,
                                          diagnostics: diagnostics, stage: .receipt)
            guard focus.allowed else { return report(.inserted, "posted_then_" + focus.reason) }
            let observed = target.observedSnapshot(timeout: timeout, diagnostics: diagnostics, stage: .receipt)?.snapshot
            // Diagnostic classification never grants input/rebase permission.
            // The exact, existing receipt verification below remains the gate.
            if diagnostics?.isCollecting == true {
                let observation = InputReceiptObservation.classify(before: before, expected: expected, after: observed)
                switch observation {
                case .unavailable, .invalidSnapshot, .notComparable: unavailable += 1
                case .unchanged: unchanged += 1
                case .selectionMismatch: selectionMismatches += 1
                case .textMismatch: textMismatches += 1
                case .matches: break
                }
                diagnostics?.record(.receipt, stage: .receipt, [.polls: .integer(polls), .reason: .reason(observation.rawValue)])
            }
            guard let after = observed else { continue }
            guard let proof = InsertionReceiptPolicy.verify(before: before, inserted: safeText,
                                                            after: after, sameTarget: true) else { continue }
            // Focus may move while AX is answering. Recheck before accepting
            // the receipt, without imposing the already-replaced old caret.
            let finalFocus = target.focusCheck(requireOriginalSelection: false, timeout: timeout,
                                               diagnostics: diagnostics, stage: .receipt)
            guard finalFocus.allowed else { return report(.inserted, "posted_then_" + finalFocus.reason) }
            guard !Task.isCancelled, shouldContinue() else {
                return report(.inserted, "delivery_cancelled_after_post")
            }
            guard ProcessInfo.processInfo.systemUptime <= deadline else { deadlineExceeded = true; break }
            let receipt = Receipt(target: target, proof: proof, postedAt: postedAt,
                                  verifiedAt: ProcessInfo.processInfo.systemUptime)
            return report(.verifiedInserted, "verified_value_and_selection", receipt: receipt)
        }
        return report(.inserted, "posted_receipt_timeout")
    }

    /// Shared clipboard helper for History actions and acoustic-held text rescue.
    @discardableResult static func copy(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}
#endif
