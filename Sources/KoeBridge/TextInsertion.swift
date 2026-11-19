#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Dispatch
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
        let target: InsertionTarget
        let proof: InsertionReceiptPolicy.Receipt
        let postedAt: TimeInterval
        let verifiedAt: TimeInterval

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

    @MainActor struct SettledUnconfirmedPredecessor {
        let target: InsertionTarget
        let completedAt: TimeInterval
    }

    @MainActor struct Report {
        let outcome: Result
        let reason: String
        let receipt: Receipt?
        let eventsPosted: Bool
        let target: InsertionTarget?
        let diagnostics: InputDiagnosticTrace?
        let resultUptimeMS: Int
        var exactBaselineAvailable: Bool = false
        var postSendFocusVerified: Bool = false
        var completedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

        /// Preserve the actual delivery target even when a pending take was
        /// captured in another field (or had no take-start target at all).
        var unverifiedTarget: InsertionTarget? {
            guard eventsPosted, receipt == nil, let target else { return nil }
            return settledUnconfirmedPredecessor == nil ? target.blockedByPriorInput(hard: true) : target
        }

        /// Predecessor delivered all chunks with verified post-send focus on a target
        /// where exact receipt verification is structurally unavailable (e.g. marker-only)
        /// and window identity is positively established.
        var settledUnconfirmedPredecessor: SettledUnconfirmedPredecessor? {
            guard outcome == .inserted, eventsPosted, receipt == nil,
                  !exactBaselineAvailable,
                  postSendFocusVerified,
                  reason == "posted_without_observable_edit",
                  let target,
                  let window = target.window,
                  CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
            return SettledUnconfirmedPredecessor(target: target, completedAt: completedAtUptime)
        }

        /// Run for every still-live take before advancing the serial sender.
        /// A successful event post by itself must never unlock the next take.
        func reconciled(_ candidate: InsertionTarget, sourceTakeID: UUID? = nil,
                        candidateTakeID: UUID? = nil,
                        diagnostics nextDiagnostics: InputDiagnosticTrace? = nil,
                        recaptureBeforeDelivery: Bool = false) -> InsertionTarget {
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
                        .capturedDuring: receipt.map {
                            .flag(candidate.capturedAt >= $0.postedAt && candidate.capturedAt <= $0.verifiedAt)
                        } ?? .token(.unknown)
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
            let isHardBlock = receipt == nil && settledUnconfirmedPredecessor == nil
            if candidate.isBlocked {
                record(.blocked, "already_blocked")
                if isHardBlock, candidate.sameElement(as: target), !candidate.hasHardPredecessorBlock {
                    return candidate.blockedByPriorInput(hard: true)
                }
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
                return candidate.blockedByPriorInput(hard: true)
            case .blocked:
                // A verified predecessor is settled. A pending take may have
                // moved its caret or edited text since capture; its fresh
                // delivery baseline supersedes that old snapshot. Existing
                // blocked latches and unverified predecessors remain blocked.
                if recaptureBeforeDelivery, receipt != nil {
                    record(.unchanged, "verified_prior_input_recapture_pending")
                    return candidate
                }
                let why: String
                if !candidate.sameField(as: target) { why = "ambiguous_target" }
                else if receipt == nil { why = "prior_receipt_unavailable" }
                else if candidate.textSnapshot == nil { why = "candidate_snapshot_unavailable" }
                else if let snapshot = candidate.textSnapshot, !InsertionReceiptPolicy.isValid(snapshot) {
                    why = "invalid_candidate_snapshot"
                } else { why = "candidate_edit_unmatched" }
                record(.blocked, why)
                return candidate.blockedByPriorInput(hard: receipt == nil ? isHardBlock : true)
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

    // Small macOS test seam: construct exactly the events used by the posting loop.
    static func makePostingSource() -> CGEventSource? {
        CGEventSource(stateID: .privateState)
    }

    static func makeUnicodeEvents(_ text: String, source: CGEventSource) -> (CGEvent, CGEvent)? {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0), keyDown: false) else { return nil }
        Array(text.utf16).withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down.flags = []
        up.flags = []
        return (down, up)
    }

    typealias TargetCapture = @MainActor (InputDiagnosticTrace?) -> (target: InsertionTarget?, reason: String)

    struct Transport {
        var ax = RecoveryAX()
        var capture: @MainActor (InputDiagnosticTrace?) -> InsertionTarget.CaptureSample = {
            InsertionTarget.captureSample(diagnostics: $0, stage: .preflight, requireTextInput: true)
        }
        var permissions: @MainActor () -> (Bool, Bool) = { (isTrusted, mayPostEvents) }
        var checkFocus: @MainActor (InsertionTarget, Bool, InputDiagnosticTrace?, InputDiagnosticEvent.Stage, Int) -> (allowed: Bool, reason: String) = {
            $0.focusCheck(requireOriginalSelection: $1, diagnostics: $2, stage: $3, chunkOrdinal: $4)
        }
        var snapshot: @MainActor (InsertionTarget, InputDiagnosticTrace?) -> (InsertionReceiptPolicy.Snapshot?, ReceiptEligibilityReason) = { target, trace in
            var eligibility = ReceiptEligibilityReason.notAttempted
            let snapshot = target.observedSnapshot(timeout: 0.04, diagnostics: trace, stage: .preflight,
                                                   eligibility: { eligibility = $0 })?.snapshot
            return (snapshot, eligibility)
        }
        var source: @MainActor () -> CGEventSource? = { makePostingSource() }
        var events: @MainActor (String, CGEventSource) -> (CGEvent, CGEvent)? = { makeUnicodeEvents($0, source: $1) }
        var post: (CGEvent, CGEvent) -> Void = { down, up in
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// Evaluate each predecessor individually for `candidate`.
    /// Any hard predecessor matching `candidate` blocks regardless of settled entries;
    /// settled relaxation applies only to the specific settled predecessor it was classified from,
    /// and requires positive non-nil window identity (both non-nil AXUIElement and CFEqual).
    static func adjudicatePredecessors(for candidate: InsertionTarget,
                                       takeStart: InsertionTarget?,
                                       unverifiedPredecessors: [InsertionTarget],
                                       settledUnconfirmedPredecessors: [SettledUnconfirmedPredecessor])
        -> (matchingUnverified: [InsertionTarget],
            matchingSettled: [SettledUnconfirmedPredecessor],
            hasHardUnverified: Bool,
            startBlocks: Bool) {
        let candidateHasValidWindow = candidate.window.map { CFGetTypeID($0) == AXUIElementGetTypeID() } ?? false
        let matchingUnverified = unverifiedPredecessors.filter { candidate.sameElement(as: $0) }
        let matchingSettled = settledUnconfirmedPredecessors.filter { settled in
            guard candidateHasValidWindow,
                  let sWin = settled.target.window,
                  CFGetTypeID(sWin) == AXUIElementGetTypeID() else { return false }
            return candidate.sameField(as: settled.target)
        }
        let settledIDs = Set(matchingSettled.map { $0.target.instanceID })
        let hasHardUnverified = matchingUnverified.contains { unverified in
            unverified.hasHardPredecessorBlock || !settledIDs.contains(unverified.instanceID)
        }
        let freshMatchesStart = takeStart.map { candidate.sameElement(as: $0) } ?? false
        let startBlocks: Bool
        if let start = takeStart, start.isBlocked {
            if !freshMatchesStart && (!unverifiedPredecessors.isEmpty || !settledUnconfirmedPredecessors.isEmpty) {
                startBlocks = false
            } else if freshMatchesStart && !start.hasHardPredecessorBlock && !matchingSettled.isEmpty && !hasHardUnverified {
                startBlocks = false
            } else {
                startBlocks = true
            }
        } else {
            startBlocks = false
        }
        return (matchingUnverified, matchingSettled, hasHardUnverified, startBlocks)
    }

    /// Capture exactly once at the shared boundary for dictation, commands and
    /// transforms. Take-start contents/caret are only diagnostic context here.
    /// Pending unverified input remains a latch; recapture cannot unlock it.
    static func prepareTarget(takeStart: InsertionTarget?, unverifiedPredecessors: [InsertionTarget] = [],
                              settledUnconfirmedPredecessors: [SettledUnconfirmedPredecessor] = [],
                              diagnostics: InputDiagnosticTrace? = nil,
                              capture: TargetCapture = { InsertionTarget.capture(diagnostics: $0, stage: .preflight,
                                                                                requireTextInput: true) })
        -> (target: InsertionTarget?, reason: String) {
        let current = capture(diagnostics)
        let classification = DeliveryTargetPolicy.recapture(currentAvailable: current.target != nil,
            sameApp: takeStart.map { $0.pid == current.target?.pid } ?? true,
            sameElement: takeStart.flatMap { start in current.target.map { start.sameElement(as: $0) } } ?? false)
        diagnostics?.record(.target, stage: .preflight, [
            .targetRecapture: .token(classification), .reason: .reason(current.reason)
        ])
        guard let fresh = current.target else {
            let specific = ["secure_text_field", "current_target_not_text_input", "koebridge_window_is_frontmost",
                            "accessibility_not_granted"]
            return (nil, specific.contains(current.reason) ? current.reason : "target_unavailable_at_delivery")
        }
        let adjudicated = adjudicatePredecessors(for: fresh, takeStart: takeStart,
                                                 unverifiedPredecessors: unverifiedPredecessors,
                                                 settledUnconfirmedPredecessors: settledUnconfirmedPredecessors)
        guard !adjudicated.startBlocks, !adjudicated.hasHardUnverified else {
            diagnostics?.record(.target, stage: .preflight, [
                .reason: .token(.priorInputUnverified),
                .startBlocked: .flag(takeStart?.isBlocked == true),
                .freshMatchesPrior: .flag(!adjudicated.matchingUnverified.isEmpty),
                .unverifiedPredecessorCount: .integer(unverifiedPredecessors.count)
            ])
            return (fresh, "prior_input_unverified")
        }
        return (fresh, "ok")
    }

    private static func verifySettledPredecessors(_ settled: [SettledUnconfirmedPredecessor],
                                                  for fresh: InsertionTarget,
                                                  takeStart: InsertionTarget?,
                                                  unverifiedPredecessors: [InsertionTarget],
                                                  diagnostics: InputDiagnosticTrace?,
                                                  transport: Transport,
                                                  shouldContinue: @MainActor () -> Bool) async -> Bool {
        func readSelectionEqual(_ left: InsertionTarget.AttributeRead, _ right: InsertionTarget.AttributeRead,
                                kind: InputDiagnosticEvent.Token) -> Bool {
            switch kind {
            case .numericRange:
                guard left.status == .success, right.status == .success,
                      let lv = left.value, let rv = right.value,
                      CFGetTypeID(lv) == AXValueGetTypeID(), CFGetTypeID(rv) == AXValueGetTypeID(),
                      AXValueGetType(lv as! AXValue) == .cfRange, AXValueGetType(rv as! AXValue) == .cfRange else {
                    return false
                }
                var lr = CFRange()
                var rr = CFRange()
                guard AXValueGetValue(lv as! AXValue, .cfRange, &lr),
                      AXValueGetValue(rv as! AXValue, .cfRange, &rr) else { return false }
                return lr.location == rr.location && lr.length == rr.length
            case .textMarker:
                guard left.status == .success, right.status == .success,
                      let lv = left.value, let rv = right.value,
                      CFGetTypeID(lv) == AXTextMarkerRangeGetTypeID(),
                      CFGetTypeID(rv) == AXTextMarkerRangeGetTypeID() else {
                    return false
                }
                return CFEqual(lv, rv)
            default:
                return false
            }
        }

        // Window identity must be positively established (both non-nil AXUIElement and CFEqual).
        guard let freshWindow = fresh.window,
              CFGetTypeID(freshWindow) == AXUIElementGetTypeID(),
              settled.allSatisfy({
                  guard let sWindow = $0.target.window,
                        CFGetTypeID(sWindow) == AXUIElementGetTypeID() else { return false }
                  return CFEqual(freshWindow, sWindow)
              }) else { return false }

        let now = transport.ax.now()
        guard let minElapsed = settled.map({ now - $0.completedAt }).min() else { return false }
        let read1Focus = transport.checkFocus(fresh, false, diagnostics, .preflight, 0)
        guard read1Focus.allowed else { return false }
        guard let selAttr = fresh.selectionAttribute,
              CFGetTypeID(fresh.focused) == AXUIElementGetTypeID() else { return false }
        let focusedElement = fresh.focused as! AXUIElement
        guard let read1Selection = try? transport.ax.read(focusedElement, selAttr, until: transport.ax.now() + 0.040),
              read1Selection.status == .success, read1Selection.value != nil else { return false }
        do { try await transport.ax.sleep(0.035) }
        catch { return false }
        guard !Task.isCancelled, shouldContinue() else { return false }
        let read2Focus = transport.checkFocus(fresh, false, diagnostics, .preflight, 0)
        guard read2Focus.allowed else { return false }
        guard let read2Selection = try? transport.ax.read(focusedElement, selAttr, until: transport.ax.now() + 0.040),
              read2Selection.status == .success, read2Selection.value != nil else { return false }
        let selectionStable = readSelectionEqual(read1Selection, read2Selection, kind: fresh.selectionKind)
        return InsertionReceiptPolicy.mayProceedWithPredecessorState(
            operation: .dictation,
            startBlocked: takeStart?.isBlocked == true,
            freshMatchesStart: takeStart.map { fresh.sameElement(as: $0) } ?? false,
            hasHardUnverifiedPredecessorOnFresh: false,
            hasSettledUnconfirmedPredecessorOnFresh: true,
            predecessorAllEventsPosted: true,
            predecessorPostSendFocusOK: true,
            predecessorExactBaselineAvailable: false,
            elapsedSincePredecessorSeconds: minElapsed,
            firstBracketedIdentityMatches: read1Focus.allowed,
            secondBracketedIdentityMatches: read2Focus.allowed,
            bracketedSelectionStable: selectionStable)
    }

    private static func acquireDeliveryTarget(takeStart: InsertionTarget?, unverifiedPredecessors: [InsertionTarget],
                                              settledUnconfirmedPredecessors: [SettledUnconfirmedPredecessor],
                                              operation: InsertionReceiptPolicy.SettledUnconfirmedOperation,
                                              diagnostics: InputDiagnosticTrace?, capture: TargetCapture?,
                                              transport: Transport,
                                              onAdoptUnavailable: (@escaping () -> AXError) -> Void,
                                              shouldContinue: @MainActor () -> Bool,
                                              stopReason: (InsertionTarget) -> String?) async
        -> (target: InsertionTarget?, reason: String, recovered: (DeliveryRecovery, DeliveryRecovery.Host)?) {
        // Custom captures supply the older, single-sample contract.
        let sample: InsertionTarget.CaptureSample?
        let initial: (target: InsertionTarget?, reason: String)
        if let capture {
            sample = nil
            initial = capture(diagnostics)
        } else {
            let observed = transport.capture(diagnostics)
            sample = observed
            initial = observed.resolution
        }
        func failed(_ reason: String) -> (InsertionTarget?, String, (DeliveryRecovery, DeliveryRecovery.Host)?) {
            diagnostics?.record(.target, stage: .preflight, [.targetRecapture: .token(.unavailable), .reason: .reason(reason)])
            return (nil, reason, nil)
        }
        var current = initial
        var recovered: (DeliveryRecovery, DeliveryRecovery.Host)?
        let recoveryCandidate: (retry: DeliveryRecovery, baselineTarget: InsertionTarget)?
        switch sample {
        case .rejected(let denied, "current_target_not_text_input") where denied.eligible:
            if let start = takeStart, let startWindow = start.window {
                if start.pid == denied.target.pid,
                   CFGetTypeID(startWindow) == AXUIElementGetTypeID(),
                   let deniedWindow = denied.target.window,
                   CFGetTypeID(deniedWindow) == AXUIElementGetTypeID(),
                   CFEqual(startWindow, deniedWindow) {
                    recoveryCandidate = (DeliveryRecovery(rejection: denied, ax: transport.ax), denied.target)
                } else {
                    recoveryCandidate = nil
                }
            } else {
                recoveryCandidate = (DeliveryRecovery(rejection: denied, ax: transport.ax), denied.target)
            }
        case .unavailable(.focusedTextElementUnavailable, let pid?, _, _):
            let app = AXUIElementCreateApplication(pid)
            let now = transport.ax.now()
            let requiredWindow: CFTypeRef?
            if let start = takeStart, let startWindow = start.window {
                requiredWindow = (start.pid == pid && CFGetTypeID(startWindow) == AXUIElementGetTypeID()) ? startWindow : nil
            } else {
                let windowRead = try? transport.ax.read(app, kAXFocusedWindowAttribute, until: now + 0.080)
                requiredWindow = (windowRead?.status == .success && windowRead?.value.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true)
                    ? windowRead?.value : nil
            }
            if let window = requiredWindow {
                let placeholder = InsertionTarget(
                    bundleIdentifier: takeStart?.pid == pid ? takeStart?.bundleIdentifier : NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                    localizedName: takeStart?.pid == pid ? takeStart?.localizedName : NSRunningApplication(processIdentifier: pid)?.localizedName,
                    pid: pid, focused: app, window: window, selectionAttribute: nil,
                    selection: nil, textSnapshot: nil, capturedAt: now, blockedReason: nil)
                recoveryCandidate = (DeliveryRecovery(unavailableTarget: placeholder, rejectedAt: now, ax: transport.ax), placeholder)
            } else {
                recoveryCandidate = nil
            }
        default:
            recoveryCandidate = nil
        }
        if let (retry, baselineTarget) = recoveryCandidate {
            let (trusted, mayPost) = transport.permissions()
            guard trusted else { return failed("accessibility_not_granted") }
            guard mayPost else { return failed("post_event_permission_missing") }
            let result = await retry.acquire(diagnostics: diagnostics, onAdoptUnavailable: onAdoptUnavailable) {
                stopReason(baselineTarget)
            }
            guard let host = result.host else { return failed(result.reason) }
            if let stop = stopReason(host.target) { return failed(stop) }
            do {
                if let snapshot = try retry.confirmedBaseline(host, mayObserve: { stopReason(host.target) == nil }) {
                    guard let target = host.target.rebased(to: snapshot) else { return failed("recovery_host_changed") }
                    current = (target, "ok")
                } else { current = (host.target, "ok") }
            } catch {
                if let stop = stopReason(host.target) { return failed(stop) }
                return failed(retry.ax.now() >= retry.deadline ? "recovery_deadline_expired" : "recovery_host_changed")
            }
            recovered = (retry, host)
        }
        let effectiveSettled = operation == .dictation ? settledUnconfirmedPredecessors : []
        let recaptured = prepareTarget(takeStart: takeStart, unverifiedPredecessors: unverifiedPredecessors,
                                       settledUnconfirmedPredecessors: effectiveSettled,
                                       diagnostics: diagnostics, capture: { _ in current })
        if recaptured.reason == "ok", let fresh = recaptured.target {
            let adjudicated = adjudicatePredecessors(for: fresh, takeStart: takeStart,
                                                     unverifiedPredecessors: unverifiedPredecessors,
                                                     settledUnconfirmedPredecessors: effectiveSettled)
            if !adjudicated.matchingSettled.isEmpty {
                let verified = await verifySettledPredecessors(adjudicated.matchingSettled, for: fresh, takeStart: takeStart,
                    unverifiedPredecessors: unverifiedPredecessors, diagnostics: diagnostics,
                    transport: transport, shouldContinue: shouldContinue)
                if !verified {
                    diagnostics?.record(.target, stage: .preflight, [
                        .reason: .token(.priorInputUnverified),
                        .startBlocked: .flag(takeStart?.isBlocked == true),
                        .freshMatchesPrior: .flag(!adjudicated.matchingUnverified.isEmpty),
                        .unverifiedPredecessorCount: .integer(unverifiedPredecessors.count)
                    ])
                    return (fresh, "prior_input_unverified", nil)
                }
            }
        }
        return (recaptured.target, recaptured.reason, recovered)
    }

    /// Clipboard-free, serial delivery. Read-back is bounded and runs while a
    /// following recording may continue. No outcome ever resubmits posted keys.
    static func deliver(_ text: String, to takeStart: InsertionTarget?,
                        diagnostics: InputDiagnosticTrace? = nil,
                        unverifiedPredecessors: [InsertionTarget] = [],
                        settledUnconfirmedPredecessors: [SettledUnconfirmedPredecessor] = [],
                        livePriorBlock: (InsertionTarget) -> Bool = { _ in false },
                        capture: TargetCapture? = nil, transport: Transport = Transport(),
                        shouldContinue: @MainActor () -> Bool = { true }) async -> Report {
        await deliverPayload(.dictation(text), takeStart: takeStart, diagnostics: diagnostics,
                             unverifiedPredecessors: unverifiedPredecessors,
                             settledUnconfirmedPredecessors: settledUnconfirmedPredecessors,
                             capture: capture, transport: transport, livePriorBlock: livePriorBlock,
                             shouldContinue: shouldContinue)
    }

    /// Only a fixed command ID can authorize newline controls; never accepts arbitrary text.
    static func deliverCommandText(_ command: VoiceCommandID, to takeStart: InsertionTarget?,
                                   diagnostics: InputDiagnosticTrace? = nil,
                                   unverifiedPredecessors: [InsertionTarget] = [],
                                   livePriorBlock: (InsertionTarget) -> Bool = { _ in false },
                                   capture: TargetCapture? = nil, transport: Transport = Transport(),
                                   shouldContinue: @MainActor () -> Bool) async -> Report {
        await deliverPayload(.command(command), takeStart: takeStart, diagnostics: diagnostics,
                             unverifiedPredecessors: unverifiedPredecessors,
                             settledUnconfirmedPredecessors: [],
                             capture: capture, transport: transport, livePriorBlock: livePriorBlock,
                             shouldContinue: shouldContinue)
    }

    private enum Payload { case dictation(String), command(VoiceCommandID) }

    private static func deliverPayload(_ payload: Payload, takeStart: InsertionTarget?,
                                       diagnostics: InputDiagnosticTrace?,
                                       unverifiedPredecessors: [InsertionTarget],
                                       settledUnconfirmedPredecessors: [SettledUnconfirmedPredecessor],
                                       capture: TargetCapture?, transport: Transport,
                                       livePriorBlock: (InsertionTarget) -> Bool,
                                       shouldContinue: @MainActor () -> Bool) async -> Report {
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
        var receiptEligibility: ReceiptEligibilityReason = .notAttempted
        var exactBaselineAvailable = false
        var postSendFocusVerified = false
        var progress = DeliveryChunkProgress()
        var pacingBudgetExceeded = false
        var phase: InputDiagnosticEvent.Token = .preflight
        var target: InsertionTarget?
        var pacingProfile: DeliveryPacingPolicy.Profile?
        var lastSpanComparison: InputReceiptObservation.SpanComparison?
        func report(_ outcome: Result, _ reason: String, diagnosticReason: String? = nil, receipt: Receipt? = nil) -> Report {
            diagnostics?.record(.eligibility, stage: .result, [
                .selectionKind: .token(target?.selectionKind ?? .unknown),
                .receiptSkippedReason: .reason(receiptEligibility.rawValue),
                .exactBaselineAvailable: .flag(exactBaselineAvailable), .polls: .integer(polls)
            ])
            if diagnostics?.isCollecting == true {
                var fields = progress.fields
                fields[.plannedChunks] = .integer(planned)
                fields[.sentChunks] = .integer(sent)
                fields[.pacingBudgetExceeded] = .flag(pacingBudgetExceeded)
                let completed = reason == "posted_without_observable_edit" || reason == "verified_value_and_selection"
                fields[.abortPhase] = .token(completed ? .none : phase)
                fields[.abortReason] = completed ? .token(.none) : .reason(diagnosticReason ?? reason)
                if let pacingProfile {
                    fields[.pacingProfile] = .token(pacingProfile.name)
                    fields[.pacingVersion] = .integer(pacingProfile.version)
                    fields[.pacingGapMS] = .integer(Int(pacingProfile.gapNanoseconds / 1_000_000))
                    fields[.pacingBudgetMS] = .integer(Int(pacingProfile.budgetNanoseconds / 1_000_000))
                }
                diagnostics?.record(.progress, stage: .posting, fields)
            }
            if let receiptStartedAt {
                var summaryFields: [InputDiagnosticEvent.Field: InputDiagnosticEvent.Value] = [
                    .polls: .integer(polls), .unchanged: .integer(unchanged),
                    .textMismatch: .integer(textMismatches), .selectionMismatch: .integer(selectionMismatches),
                    .unavailable: .integer(unavailable),
                    .deadlineExceeded: .flag(deadlineExceeded
                        || ProcessInfo.processInfo.systemUptime > receiptStartedAt + 0.6),
                    .budgetInsufficient: .flag(budgetInsufficient),
                    .elapsedMS: .integer(InputDiagnosticTrace.milliseconds(since: receiptStartedAt))
                ]
                if let spans = lastSpanComparison {
                    summaryFields[.prefixMatches] = .flag(spans.prefixMatches)
                    summaryFields[.insertedMatches] = .flag(spans.insertedMatches)
                    summaryFields[.suffixMatches] = .flag(spans.suffixMatches)
                    summaryFields[.observedSuffixUTF16] = .integer(spans.observedSuffixUTF16)
                }
                diagnostics?.record(.receipt, stage: .receipt, summaryFields)
            }
            var resultFields: [InputDiagnosticEvent.Field: InputDiagnosticEvent.Value] = [
                .outcome: .token(outcome.diagnosticOutcome), .reason: .reason(diagnosticReason ?? reason),
                .plannedChunks: .integer(planned), .sentChunks: .integer(sent),
                .eventsPosted: .flag(sent > 0), .receiptAvailable: .flag(receipt != nil),
                .receiptMode: receipt.map { .reason($0.proof.mode.rawValue) } ?? .token(.none),
                .totalMS: .integer(InputDiagnosticTrace.milliseconds(since: beganAt))
            ]
            if let spans = lastSpanComparison {
                resultFields[.prefixMatches] = .flag(spans.prefixMatches)
                resultFields[.insertedMatches] = .flag(spans.insertedMatches)
                resultFields[.suffixMatches] = .flag(spans.suffixMatches)
                resultFields[.observedSuffixUTF16] = .integer(spans.observedSuffixUTF16)
            }
            let resultUptimeMS = diagnostics?.record(.result, stage: .result, resultFields)
                ?? InputDiagnosticTrace.uptimeMilliseconds(ProcessInfo.processInfo.systemUptime)
            return Report(outcome: outcome, reason: reason, receipt: receipt,
                          eventsPosted: sent > 0, target: target, diagnostics: diagnostics,
                          resultUptimeMS: resultUptimeMS, exactBaselineAvailable: exactBaselineAvailable,
                          postSendFocusVerified: postSendFocusVerified,
                          completedAtUptime: transport.ax.now())
        }
        guard !Task.isCancelled, shouldContinue() else {
            return report(.cancelled, "delivery_cancelled_before_post")
        }
        let operation: InsertionReceiptPolicy.SettledUnconfirmedOperation
        switch payload {
        case .dictation: operation = .dictation
        case .command: operation = .command
        }
        let effectiveSettled = operation == .dictation ? settledUnconfirmedPredecessors : []
        func stopReason(_ candidate: InsertionTarget) -> String? {
            if Task.isCancelled || !shouldContinue() { return "delivery_cancelled_before_post" }
            let adjudicated = adjudicatePredecessors(for: candidate, takeStart: takeStart,
                                                     unverifiedPredecessors: unverifiedPredecessors,
                                                     settledUnconfirmedPredecessors: effectiveSettled)
            if adjudicated.startBlocks || livePriorBlock(candidate) || adjudicated.hasHardUnverified {
                return "prior_input_unverified"
            }
            return nil
        }
        // Recovery owns the system timeout through the last pre-post host check.
        // Early returns unwind here; successful posting releases it before receipt reads.
        var restoreSystemTimeout: (() -> AXError)?
        defer { _ = restoreSystemTimeout?() }
        let recaptured = await acquireDeliveryTarget(takeStart: takeStart, unverifiedPredecessors: unverifiedPredecessors,
            settledUnconfirmedPredecessors: effectiveSettled, operation: operation,
            diagnostics: diagnostics, capture: capture, transport: transport,
            onAdoptUnavailable: { restoreSystemTimeout = $0 },
            shouldContinue: shouldContinue, stopReason: stopReason)
        target = recaptured.target
        pacingProfile = target.map { DeliveryPacingPolicy.profile(selectionKind: $0.selectionKind) }
        guard recaptured.reason == "ok" else {
            let outcome: Result
            switch recaptured.reason {
            case "accessibility_not_granted": outcome = .notPermitted
            case "post_event_permission_missing": outcome = .eventPermissionMissing
            case "delivery_cancelled_before_post": outcome = .cancelled
            default: outcome = .focusChanged
            }
            return report(outcome, recaptured.reason)
        }
        let safeText: String
        let parts: [String]
        switch payload {
        case .dictation(let text):
            safeText = UnicodeTypingPlan.safeText(text)
            parts = UnicodeTypingPlan.chunks(text)
        case .command(let command):
            safeText = command.insertionText ?? ""
            parts = safeText.isEmpty ? [] : [safeText]
        }
        planned = parts.count
        guard !parts.isEmpty else { return report(.eventUnavailable, "empty_typing_payload") }
        let (axAllowed, postAllowed) = transport.permissions()
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
        let before: InsertionReceiptPolicy.Snapshot?
        if let (recovery, adopted) = recaptured.recovered {
            if let stop = stopReason(target) {
                return report(stop == "delivery_cancelled_before_post" ? .cancelled : .focusChanged, stop)
            }
            do {
                guard case .editor(let current) = recovery.observe(until: recovery.deadline),
                      adopted.matches(current) else { throw RecoveryAX.Failure.unavailable }
                before = try recovery.confirmedBaseline(current, mayObserve: { stopReason(target) == nil })
            }
            catch {
                if let stop = stopReason(target) {
                    return report(stop == "delivery_cancelled_before_post" ? .cancelled : .focusChanged, stop)
                }
                return report(.focusChanged, recovery.ax.now() >= recovery.deadline ? "recovery_deadline_expired" : "recovery_host_changed")
            }
            receiptEligibility = before != nil ? .snapshotAvailable
                : (target.selectionKind == .textMarker ? .markerNotNumeric : .valueUnavailable)
        } else {
            var initialFocus = transport.checkFocus(target, true, diagnostics, .preflight, 0)
            if !initialFocus.allowed,
               InsertionFocusPolicy.mayRecheckTransientFocusUnavailability(
                   reason: initialFocus.reason,
                   sameProcess: transport.ax.frontPID() == target.pid,
                   alreadyRecheckedAtCheckpoint: false) {
                try? await transport.ax.sleep(0.025)
                if !Task.isCancelled, shouldContinue(), transport.ax.frontPID() == target.pid {
                    initialFocus = transport.checkFocus(target, true, diagnostics, .preflight, 0)
                }
            }
            guard initialFocus.allowed else { return report(.focusChanged, initialFocus.reason) }
            (before, receiptEligibility) = transport.snapshot(target, diagnostics)
        }
        exactBaselineAvailable = before != nil
        if case .command = payload {
            guard target.textSnapshot != nil, before != nil else {
                return report(.focusChanged, "command_baseline_unavailable")
            }
        }
        // This comparison anchors the new delivery capture, never the take-start
        // snapshot. Edits made while recording are already part of this baseline.
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
            guard captured == before else {
                let reason: String
                if InsertionReceiptPolicy.sameText(captured.text, before.text) { reason = "snapshot_selection_changed" }
                else if captured.selection == before.selection { reason = "snapshot_text_changed" }
                else { reason = "snapshot_text_and_selection_changed" }
                return report(.focusChanged, "field_value_or_selection_changed", diagnosticReason: reason)
            }
        }
        guard let source = transport.source() else {
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
        phase = .posting
        let appliedProfile = DeliveryPacingPolicy.profile(selectionKind: target.selectionKind)
        let collectTiming = diagnostics?.isCollecting == true
        for (index, part) in parts.enumerated() {
            // A long synchronous loop starves MainActor stop/cancel actions.
            // Yield between small batches, then revalidate before posting any
            // more keys. The serial sender still owns this entire delivery.
            let delay = DeliveryPacingPolicy.delayNanoseconds(beforeChunk: index, profile: appliedProfile)
            pacingBudgetExceeded = pacingBudgetExceeded
                || DeliveryPacingPolicy.budgetExceeded(beforeChunk: index, profile: appliedProfile)
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if index > 0 && index % 4 == 0 { await Task.yield() }
            guard !Task.isCancelled, shouldContinue() else {
                return report(sent == 0 ? .cancelled : .partiallySubmitted,
                              sent == 0 ? "delivery_cancelled_before_post" : "delivery_cancelled_after_partial_post")
            }
            if transport.ax.frontPID() != target.pid {
                return report(sent == 0 ? .focusChanged : .partiallySubmitted, "active_app_changed",
                              diagnosticReason: index == 0 ? "first_chunk_active_app_changed" : nil)
            }
            // Own input moves the selection. Keep field/window/owner checks
            // throughout, and the original caret check until the first post.
            if recaptured.recovered == nil && index % 4 == 0 {
                var check = transport.checkFocus(target, index == 0, diagnostics, .posting, index + 1)
                if !check.allowed,
                   InsertionFocusPolicy.mayRecheckTransientFocusUnavailability(
                       reason: check.reason,
                       sameProcess: transport.ax.frontPID() == target.pid,
                       alreadyRecheckedAtCheckpoint: false) {
                    try? await transport.ax.sleep(0.025)
                    guard !Task.isCancelled, shouldContinue() else {
                        return report(sent == 0 ? .cancelled : .partiallySubmitted,
                                      sent == 0 ? "delivery_cancelled_before_post" : "delivery_cancelled_after_partial_post")
                    }
                    if transport.ax.frontPID() != target.pid {
                        return report(sent == 0 ? .focusChanged : .partiallySubmitted, "active_app_changed",
                                      diagnosticReason: index == 0 ? "first_chunk_active_app_changed" : nil)
                    }
                    check = transport.checkFocus(target, index == 0, diagnostics, .posting, index + 1)
                }
                if !check.allowed {
                    return report(sent == 0 ? .focusChanged : .partiallySubmitted, check.reason,
                                  diagnosticReason: index == 0 ? "first_chunk_" + check.reason : check.reason)
                }
            }
            guard let (down, up) = transport.events(part, source) else {
                return report(sent == 0 ? .eventUnavailable : .partiallySubmitted, "keyboard_event_unavailable")
            }
            if let (recovery, adopted) = recaptured.recovered {
                let limit = index == 0 ? recovery.deadline : recovery.ax.now() + 0.100
                if index == 0, let stop = stopReason(target) {
                    return report(stop == "delivery_cancelled_before_post" ? .cancelled : .focusChanged, stop)
                }
                guard case .editor(let host) = recovery.observe(until: limit),
                      adopted.matchesHostIdentity(host, requireOriginalSelection: index == 0) else {
                    return report(sent == 0 ? .focusChanged : .partiallySubmitted,
                                  recovery.ax.now() >= limit ? "recovery_deadline_expired" : "recovery_host_changed")
                }
                if index == 0, let stop = stopReason(target) {
                    return report(stop == "delivery_cancelled_before_post" ? .cancelled : .focusChanged, stop)
                }
                if sent > 0, Task.isCancelled || !shouldContinue() {
                    return report(.partiallySubmitted, "delivery_cancelled_after_partial_post")
                }
                guard recovery.ax.now() < limit else {
                    return report(sent == 0 ? .focusChanged : .partiallySubmitted, "recovery_deadline_expired")
                }
            }
            let postBegan = collectTiming ? DispatchTime.now().uptimeNanoseconds : 0
            transport.post(down, up)
            let postEnded = collectTiming ? DispatchTime.now().uptimeNanoseconds : 0
            sent += 1
            if collectTiming {
                progress.posted(ordinal: sent, requestedGapNanoseconds: delay,
                                beganNanoseconds: postBegan, endedNanoseconds: postEnded)
            }
        }
        _ = restoreSystemTimeout?()
        restoreSystemTimeout = nil
        diagnostics?.record(.payload, stage: .posting, [
            .sentChunks: .integer(sent), .eventsPosted: .flag(sent > 0), .outcome: .token(.unconfirmed)
        ])
        let expected = before.flatMap { InsertionReceiptPolicy.expectedAfter(before: $0, inserted: safeText) }
        let textChanged: Bool
        if let before, let expected { textChanged = !InsertionReceiptPolicy.sameText(before.text, expected.text) }
        else { textChanged = false }
        receiptEligibility = receiptEligibility.afterPosting(expectedEditAvailable: expected != nil, textChanged: textChanged)
        guard let before, let expected, textChanged else {
            let observationBegan = ProcessInfo.processInfo.systemUptime
            let focus = transport.checkFocus(target, false, diagnostics, .receipt, sent)
            postSendFocusVerified = focus.allowed
            if diagnostics?.isCollecting == true {
                // Classification only: one bounded identity check and an
                // independent value-only probe. Neither can create a receipt.
                var attempted = false
                var valueResult: InputDiagnosticEvent.Token = .notAttempted
                var valueAvailable = false
                if focus.allowed {
                    valueAvailable = target.observedValue(timeout: 0.01, diagnostics: diagnostics, stage: .receipt,
                        requireKnownNonsecure: true, observation: { attempted = $0; valueResult = $1 }) != nil
                }
                let identityChanged = ["active_app_changed", "focused_field_changed", "focused_window_changed",
                                       "focused_element_owner_changed"].contains(focus.reason)
                diagnostics?.record(.observation, stage: .receipt, [
                    .outcome: .token(focus.allowed ? .same : identityChanged ? .different : .unknown),
                    .reason: .reason(focus.reason), .chunkOrdinal: .integer(sent),
                    .receiverObservation: .token(valueAvailable ? .valueOnly : .unavailable),
                    .valueReadAttempted: .flag(attempted), .valueReadResult: .token(valueResult),
                    .exactBaselineAvailable: .flag(exactBaselineAvailable),
                    .elapsedMS: .integer(InputDiagnosticTrace.milliseconds(since: observationBegan))
                ])
            }
            return report(.inserted, "posted_without_observable_edit")
        }

        // A short finite polling budget replaces fire-and-forget diagnostics.
        // AX timeouts also shrink with the remaining budget. Do not skip this
        // because the next recording is active: that is the key overlap case.
        let receiptBeganAt = ProcessInfo.processInfo.systemUptime
        phase = .receipt
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
                                          diagnostics: diagnostics, stage: .receipt, chunkOrdinal: sent)
            guard focus.allowed else { return report(.inserted, "posted_then_" + focus.reason) }
            let observed = target.observedSnapshot(timeout: timeout, diagnostics: diagnostics, stage: .receipt)?.snapshot
            let spans = InputReceiptObservation.compareSpans(before: before, inserted: safeText, after: observed)
            if let spans { lastSpanComparison = spans }
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
                var pollFields: [InputDiagnosticEvent.Field: InputDiagnosticEvent.Value] = [
                    .polls: .integer(polls), .reason: .reason(observation.rawValue)
                ]
                if let spans {
                    pollFields[.prefixMatches] = .flag(spans.prefixMatches)
                    pollFields[.insertedMatches] = .flag(spans.insertedMatches)
                    pollFields[.suffixMatches] = .flag(spans.suffixMatches)
                    pollFields[.observedSuffixUTF16] = .integer(spans.observedSuffixUTF16)
                }
                diagnostics?.record(.receipt, stage: .receipt, pollFields)
            }
            guard let after = observed else { continue }
            guard let proof = InsertionReceiptPolicy.verify(before: before, inserted: safeText,
                                                            after: after, sameTarget: true) else { continue }
            // Focus may move while AX is answering. Recheck before accepting
            // the receipt, without imposing the already-replaced old caret.
            let finalFocus = target.focusCheck(requireOriginalSelection: false, timeout: timeout,
                                               diagnostics: diagnostics, stage: .receipt, chunkOrdinal: sent)
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
