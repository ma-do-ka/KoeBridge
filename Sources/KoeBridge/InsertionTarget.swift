#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import KoeBridgeCore

/// A conservative target snapshot. Never activate another application just to type.
@MainActor struct InsertionTarget {
    let pid: pid_t
    let focused: CFTypeRef
    let window: CFTypeRef?
    let selectionAttribute: String?
    private(set) var selection: CFTypeRef?
    private(set) var textSnapshot: InsertionReceiptPolicy.Snapshot?
    private(set) var capturedAt: TimeInterval
    private var blockedReason: String?

    var isBlocked: Bool { blockedReason != nil }

    private typealias Field = InputDiagnosticEvent.Field
    private typealias Value = InputDiagnosticEvent.Value
    private typealias Token = InputDiagnosticEvent.Token
    private typealias Stage = InputDiagnosticEvent.Stage

    private struct AttributeRead {
        let value: CFTypeRef?
        let status: AXError
    }

    /// Observe the calls already needed for insertion. No attribute values,
    /// object descriptions, or extra diagnostic AX reads are collected.
    private static func copyAX(_ element: AXUIElement, name: CFString,
                               operation: Token, scope: Token = .focusedElement,
                               timeout: Float = 0.08, configureTimeout: Bool = true,
                               diagnostics: InputDiagnosticTrace?, stage: Stage) -> AttributeRead {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        let began = diagnostics.map { _ in ProcessInfo.processInfo.systemUptime }
        let timeoutStatus = configureTimeout ? AXUIElementSetMessagingTimeout(element, timeout) : nil
        var value: CFTypeRef?
        var status = AXError.failure
        defer {
            // Setting a timeout on the system-wide object changes the process
            // default. Never leave a short receipt-poll timeout installed.
            let resetStatus = scope == .system ? AXUIElementSetMessagingTimeout(element, 0) : nil
            if let diagnostics, let began {
                var fields: [Field: Value] = [
                    .operation: .token(operation), .scope: .token(scope),
                    .error: .integer(Int(status.rawValue)),
                    .timeoutMS: .integer(Int((Double(timeout) * 1_000).rounded())),
                    .elapsedMS: .integer(Self.elapsedMilliseconds(since: began)),
                    .outcome: .token(status == .success ? (value == nil ? .missing : .ok) : .unavailable)
                ]
                if let timeoutStatus { fields[.timeoutError] = .integer(Int(timeoutStatus.rawValue)) }
                if let resetStatus { fields[.resetError] = .integer(Int(resetStatus.rawValue)) }
                diagnostics.record(.ax, stage: stage, fields)
            }
        }
        status = AXUIElementCopyAttributeValue(element, name, &value)
        return AttributeRead(value: status == .success ? value : nil, status: status)
    }

    private static func elapsedMilliseconds(since began: TimeInterval) -> Int {
        InputDiagnosticTrace.milliseconds(since: began)
    }

    private static func owner(of element: AXUIElement, diagnostics: InputDiagnosticTrace?,
                              stage: Stage) -> (pid: pid_t, status: AXError) {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        let began = diagnostics.map { _ in ProcessInfo.processInfo.systemUptime }
        var pid: pid_t = 0
        let status = AXUIElementGetPid(element, &pid)
        if let diagnostics, let began {
            diagnostics.record(.ax, stage: stage, [
                .operation: .token(.owner), .scope: .token(.focusedElement),
                .error: .integer(Int(status.rawValue)),
                .pid: status == .success ? .integer(Int(pid)) : .token(.unavailable),
                .elapsedMS: .integer(elapsedMilliseconds(since: began))
            ])
        }
        return (pid, status)
    }

    /// Capture and revalidation must use the same resolution rule. Some web
    /// editors expose focus on the application's tree but not the system tree.
    private static func focusedElement(for pid: pid_t, timeout: Float = 0.08,
                                       diagnostics: InputDiagnosticTrace?, stage: Stage) -> CFTypeRef? {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        let app = AXUIElementCreateApplication(pid)
        let system = AXUIElementCreateSystemWide()
        for (root, scope) in [(app, Token.application), (system, Token.system)] {
            let read = copyAX(root, name: kAXFocusedUIElementAttribute as CFString,
                              operation: .focusedElement, scope: scope, timeout: timeout,
                              diagnostics: diagnostics, stage: stage)
            guard let candidate = read.value else { continue }
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else {
                diagnostics?.record(.target, stage: stage, [
                    .scope: .token(scope), .element: .token(.invalidType)
                ])
                continue
            }
            let element = unsafeBitCast(candidate, to: AXUIElement.self)
            let owner = Self.owner(of: element, diagnostics: diagnostics, stage: stage)
            diagnostics?.record(.target, stage: stage, [
                .scope: .token(scope),
                .owner: .token(owner.status == .success ? (owner.pid == pid ? .same : .different) : .unavailable)
            ])
            if owner.status == .success && owner.pid == pid {
                return candidate
            }
        }
        return nil
    }

    /// AX grants belong to the actual running process, including its signature.
    static func capture(diagnostics: InputDiagnosticTrace? = nil) -> (target: InsertionTarget?, reason: String) {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        let began = diagnostics.map { _ in ProcessInfo.processInfo.systemUptime }
        func failure(_ reason: String) -> (target: InsertionTarget?, reason: String) {
            diagnostics?.record(.target, stage: .capture, [
                .reason: .reason(reason), .outcome: .token(.blocked),
                .elapsedMS: .integer(began.map { Self.elapsedMilliseconds(since: $0) } ?? 0)
            ])
            return (nil, reason)
        }
        let trusted = AXIsProcessTrusted()
        diagnostics?.record(.target, stage: .capture, [.axTrusted: .flag(trusted)])
        guard trusted else { return failure("accessibility_not_granted") }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return failure("no_frontmost_application")
        }
        diagnostics?.record(.target, stage: .capture, [
            .pid: .integer(Int(app.processIdentifier)),
            .app: app.bundleIdentifier.map { .application($0) } ?? .token(.unavailable)
        ])
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return failure("koebridge_window_is_frontmost")
        }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = focusedElement(for: app.processIdentifier, diagnostics: diagnostics, stage: .capture) else {
            return failure("focused_text_element_unavailable")
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        let owner = Self.owner(of: element, diagnostics: diagnostics, stage: .capture)
        guard owner.status == .success else { return failure("focus_owner_unavailable") }
        guard owner.pid == app.processIdentifier else { return failure("focus_owner_mismatch") }
        let window = copyAX(appAX, name: kAXFocusedWindowAttribute as CFString,
                            operation: .focusedWindow, scope: .application,
                            diagnostics: diagnostics, stage: .capture).value
        let selectionAttribute: String?
        let selection: CFTypeRef?
        if let range = copyAX(element, name: kAXSelectedTextRangeAttribute as CFString,
                              operation: .selectedRange, diagnostics: diagnostics, stage: .capture).value {
            selectionAttribute = kAXSelectedTextRangeAttribute as String
            selection = range
        } else if let marker = copyAX(element, name: "AXSelectedTextMarkerRange" as CFString,
                                     operation: .selectedMarker, diagnostics: diagnostics, stage: .capture).value {
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
                if let observed = target.observedSnapshot(timeout: 0.04, diagnostics: diagnostics, stage: .capture) {
                    target.textSnapshot = observed.snapshot
                    target.selection = observed.selection
                    break
                }
            }
        }
        target.capturedAt = ProcessInfo.processInfo.systemUptime
        if let diagnostics {
            var fields: [Field: Value] = [
                .reason: .token(.ok), .outcome: .token(.ok),
                .pid: .integer(Int(target.pid)), .element: .token(.ok),
                .owner: .token(.same), .window: .token(window == nil ? .missing : .ok),
                .selectionKind: .token(target.selectionKind),
                .elapsedMS: .integer(began.map { Self.elapsedMilliseconds(since: $0) } ?? 0)
            ]
            if let window, CFGetTypeID(window) != AXUIElementGetTypeID() {
                fields[.window] = .token(.invalidType)
            }
            if selectionAttribute == kAXSelectedTextRangeAttribute as String, let selected = target.selection {
                let decoded = numericSelection(selected)
                fields[.selection] = .token(decoded.outcome)
                if let range = decoded.range {
                    fields[.selectionStart] = .integer(range.location)
                    fields[.selectionLength] = .integer(range.length)
                }
            }
            diagnostics.record(.target, stage: .capture, fields)
        }
        return (target, "ok")
    }

    private var selectionKind: Token {
        guard let selectionAttribute else { return .none }
        if selectionAttribute == (kAXSelectedTextRangeAttribute as String) { return .numericRange }
        if selectionAttribute == "AXSelectedTextMarkerRange" { return .textMarker }
        return .unknown
    }

    /// Many browser editors do not expose AXValue. Unknown contents never
    /// authorize a caret rebase, and secure field contents are not collected.
    func observedValue(timeout: Float = 0.04, diagnostics: InputDiagnosticTrace? = nil,
                       stage: InputDiagnosticEvent.Stage = .preflight) -> String? {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        var evidence: [Field: Value]? = diagnostics.map { _ in [.operation: .token(.value)] }
        var outcome: Token = .unavailable
        defer {
            if let diagnostics, var fields = evidence {
                fields[.outcome] = .token(outcome)
                diagnostics.record(.snapshot, stage: stage, fields)
            }
        }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            evidence?[.element] = .token(.invalidType)
            outcome = .invalidType
            return nil
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        let subrole = Self.copyAX(element, name: kAXSubroleAttribute as CFString,
                                  operation: .subrole, timeout: timeout,
                                  diagnostics: diagnostics, stage: stage)
        if subrole.status == .success, (subrole.value as? String) == "AXSecureTextField" {
            evidence?[.subrole] = .token(.secure)
            outcome = .secure
            return nil
        }
        evidence?[.subrole] = .token(subrole.status != .success ? .unavailable
                                     : subrole.value == nil ? .missing
                                     : subrole.value is String ? .ok : .invalidType)
        // The existing value read shares the timeout installed for subrole.
        let value = Self.copyAX(element, name: kAXValueAttribute as CFString,
                                operation: .value, timeout: timeout, configureTimeout: false,
                                diagnostics: diagnostics, stage: stage)
        guard let raw = value.value else {
            outcome = value.status == .success ? .missing : .unavailable
            return nil
        }
        guard let text = raw as? String else {
            outcome = .invalidType
            return nil
        }
        let count = text.utf16.count
        evidence?[.valueUTF16] = .integer(count)
        guard count <= InsertionReceiptPolicy.maximumObservableUTF16Count else {
            outcome = .tooLarge
            return nil
        }
        outcome = .ok
        return text
    }

    /// Read text between two equal selections, so a moving editor does not
    /// combine a previous caret with a later partial value. Opaque marker
    /// ranges cannot be turned into numeric offsets by guessing.
    func observedSnapshot(timeout: Float, diagnostics: InputDiagnosticTrace? = nil,
                          stage: InputDiagnosticEvent.Stage = .preflight)
        -> (snapshot: InsertionReceiptPolicy.Snapshot, selection: CFTypeRef)? {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        var evidence: [Field: Value]? = diagnostics.map { _ in [
            .operation: .token(.selectedRange), .selectionKind: .token(selectionKind)
        ] }
        var outcome: Token = .unavailable
        defer {
            if let diagnostics, var fields = evidence {
                fields[.outcome] = .token(outcome)
                diagnostics.record(.snapshot, stage: stage, fields)
            }
        }
        guard selectionAttribute == kAXSelectedTextRangeAttribute as String else { return nil }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            evidence?[.element] = .token(.invalidType)
            outcome = .invalidType
            return nil
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        let firstRead = Self.copyAX(element, name: kAXSelectedTextRangeAttribute as CFString,
                                    operation: .selectedRange, timeout: timeout,
                                    diagnostics: diagnostics, stage: stage)
        guard let first = firstRead.value else {
            evidence?[.selection] = .token(firstRead.status == .success ? .missing : .unavailable)
            return nil
        }
        guard let text = observedValue(timeout: timeout, diagnostics: diagnostics, stage: stage) else {
            evidence?[.text] = .token(.unavailable)
            return nil
        }
        let lastRead = Self.copyAX(element, name: kAXSelectedTextRangeAttribute as CFString,
                                   operation: .selectedRange, timeout: timeout,
                                   diagnostics: diagnostics, stage: stage)
        guard let last = lastRead.value else {
            evidence?[.selection] = .token(lastRead.status == .success ? .missing : .unavailable)
            return nil
        }
        let firstRange = Self.numericSelection(first)
        let lastRange = Self.numericSelection(last)
        guard let initialRange = firstRange.range else {
            evidence?[.selection] = .token(firstRange.outcome)
            outcome = firstRange.outcome
            return nil
        }
        guard let range = lastRange.range else {
            evidence?[.selection] = .token(lastRange.outcome)
            outcome = lastRange.outcome
            return nil
        }
        evidence?[.expectedStart] = .integer(initialRange.location)
        evidence?[.expectedLength] = .integer(initialRange.length)
        evidence?[.selectionStart] = .integer(range.location)
        evidence?[.selectionLength] = .integer(range.length)
        evidence?[.valueUTF16] = .integer(text.utf16.count)
        guard initialRange == range else {
            evidence?[.selection] = .token(.different)
            outcome = .selectionMoved
            return nil
        }
        let snapshot = InsertionReceiptPolicy.Snapshot(text: text, selection: range)
        guard InsertionReceiptPolicy.isValid(snapshot) else {
            evidence?[.selection] = .token(.invalidRange)
            outcome = .invalidRange
            return nil
        }
        evidence?[.selection] = .token(.same)
        outcome = .ok
        return (snapshot, last)
    }

    private static func numericSelection(_ value: CFTypeRef)
        -> (range: InsertionReceiptPolicy.Selection?, outcome: Token) {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return (nil, .invalidType) }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return (nil, .invalidType) }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return (nil, .invalidRange) }
        return (InsertionReceiptPolicy.Selection(location: range.location, length: range.length), .ok)
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

    func focusCheck(requireOriginalSelection: Bool = true, timeout: Float = 0.08,
                    diagnostics: InputDiagnosticTrace? = nil,
                    stage: InputDiagnosticEvent.Stage = .preflight) -> (allowed: Bool, reason: String) {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        let began = diagnostics.map { _ in ProcessInfo.processInfo.systemUptime }
        var evidence: [Field: Value]? = diagnostics.map { _ in [
            .pid: .integer(Int(pid)), .originalSelection: .flag(requireOriginalSelection),
            .selectionKind: .token(selectionKind),
            .selection: .token(requireOriginalSelection ? .unknown : .skipped),
            .captureAgeMS: .integer(Self.elapsedMilliseconds(since: capturedAt))
        ] }
        func result(_ allowed: Bool, _ reason: String) -> (allowed: Bool, reason: String) {
            if let diagnostics, var fields = evidence {
                fields[.reason] = .reason(reason)
                fields[.outcome] = .token(allowed ? .ok : .blocked)
                fields[.elapsedMS] = .integer(began.map { Self.elapsedMilliseconds(since: $0) } ?? 0)
                diagnostics.record(.focus, stage: stage, fields)
            }
            return (allowed, reason)
        }
        if let blockedReason { return result(false, blockedReason) }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        evidence?[.frontPID] = frontPID.map { .integer(Int($0)) } ?? .token(.unavailable)
        guard let frontPID else { return result(false, "frontmost_application_unavailable") }
        let sameProcess = frontPID == pid
        guard sameProcess else { return result(false, "active_app_changed") }
        guard let currentFocused = Self.focusedElement(for: pid, timeout: timeout,
                                                       diagnostics: diagnostics, stage: stage) else {
            evidence?[.element] = .token(.unavailable)
            return result(false, "focused_element_unavailable_on_recheck")
        }
        let sameElement = CFEqual(focused, currentFocused)
        evidence?[.element] = .token(sameElement ? .same : .different)
        guard sameElement else { return result(false, "focused_field_changed") }
        let sameWindow: Bool
        var windowFailure: String?
        if let original = window {
            let appAX = AXUIElementCreateApplication(pid)
            let currentWindow = Self.copyAX(appAX, name: kAXFocusedWindowAttribute as CFString,
                                             operation: .focusedWindow, scope: .application,
                                             timeout: timeout, diagnostics: diagnostics, stage: stage)
            if let value = currentWindow.value {
                if CFGetTypeID(original) == AXUIElementGetTypeID(), CFGetTypeID(value) == AXUIElementGetTypeID() {
                    sameWindow = CFEqual(original, value)
                    evidence?[.window] = .token(sameWindow ? .same : .different)
                    if !sameWindow { windowFailure = "focused_window_changed" }
                } else {
                    sameWindow = false
                    evidence?[.window] = .token(.invalidType)
                    windowFailure = "focused_window_invalid_on_recheck"
                }
            } else {
                sameWindow = false
                evidence?[.window] = .token(currentWindow.status == .success ? .missing : .unavailable)
                windowFailure = "focused_window_unavailable_on_recheck"
            }
        } else {
            // A missing capture-time window was already permitted only when
            // the exact field and its owning process still match.
            sameWindow = true
            evidence?[.window] = .token(.unknown)
        }
        let element = unsafeBitCast(currentFocused, to: AXUIElement.self)
        let owner = Self.owner(of: element, diagnostics: diagnostics, stage: stage)
        let sameElementOwner = owner.status == .success && owner.pid == pid
        evidence?[.owner] = .token(owner.status != .success ? .unavailable
                                   : sameElementOwner ? .same : .different)
        var selectionMatches: Bool?
        var selectionFailure: String?
        if requireOriginalSelection, let selectionAttribute, let selection {
            let numeric = selectionAttribute == kAXSelectedTextRangeAttribute as String
            let currentSelection = Self.copyAX(element, name: selectionAttribute as CFString,
                                                operation: numeric ? .selectedRange : .selectedMarker,
                                                timeout: timeout, diagnostics: diagnostics, stage: stage)
            if let value = currentSelection.value {
                if numeric {
                    let expected = Self.numericSelection(selection)
                    let observed = Self.numericSelection(value)
                    if let range = expected.range {
                        evidence?[.expectedStart] = .integer(range.location)
                        evidence?[.expectedLength] = .integer(range.length)
                    }
                    if let range = observed.range {
                        evidence?[.selectionStart] = .integer(range.location)
                        evidence?[.selectionLength] = .integer(range.length)
                    }
                    if let expectedRange = expected.range, let observedRange = observed.range {
                        selectionMatches = expectedRange == observedRange
                        evidence?[.selection] = .token(selectionMatches == true ? .same : .different)
                        if selectionMatches == false { selectionFailure = "caret_or_selection_changed" }
                    } else {
                        selectionMatches = false
                        evidence?[.selection] = .token(expected.range == nil ? expected.outcome : observed.outcome)
                        selectionFailure = expected.range == nil ? "captured_selection_invalid"
                            : "selection_value_invalid_on_recheck"
                    }
                } else {
                    // Marker ranges are opaque. Do not infer numeric offsets
                    // or substitute pointer identity for their CF equality.
                    selectionMatches = CFEqual(selection, value)
                    evidence?[.selection] = .token(selectionMatches == true ? .same : .different)
                    if selectionMatches == false { selectionFailure = "caret_or_selection_changed" }
                }
            } else {
                selectionMatches = false
                evidence?[.selection] = .token(currentSelection.status == .success ? .missing : .unavailable)
                selectionFailure = "selection_unavailable_on_recheck"
            }
        }
        // Preserve the original fail-closed decisions and failure precedence;
        // a failed read is never misreported as proof that the user moved.
        if let windowFailure { return result(false, windowFailure) }
        guard sameElementOwner else {
            return result(false, owner.status == .success ? "focused_element_owner_changed"
                          : "focused_element_owner_unavailable")
        }
        if let selectionFailure { return result(false, selectionFailure) }
        let permitted = InsertionFocusPolicy.mayPaste(sameProcess: sameProcess,
                                                       sameWindow: sameWindow,
                                                       sameElement: sameElement,
                                                       selectionMatches: selectionMatches,
                                                       sameElementOwner: sameElementOwner)
        return result(permitted, permitted ? "ok" : "focus_verification_failed")
    }

    func stillCurrent(requireOriginalSelection: Bool = true) -> Bool {
        focusCheck(requireOriginalSelection: requireOriginalSelection).allowed
    }
}

#endif
