#if os(macOS)
import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import KoeBridgeCore

/// A conservative target snapshot. Never activate another application just to type.
@MainActor struct InsertionTarget {
    let instanceID = UUID()
    let bundleIdentifier: String?
    let localizedName: String?
    let pid: pid_t
    let focused: CFTypeRef
    let window: CFTypeRef?
    let selectionAttribute: String?
    private(set) var selection: CFTypeRef?
    private(set) var textSnapshot: InsertionReceiptPolicy.Snapshot?
    private(set) var receiptFieldNature = InsertionReceiptPolicy.FieldNature.unknown
    private(set) var capturedAt: TimeInterval
    private(set) var blockedReason: String?
    private(set) var hasHardPredecessorBlock = false

    var isBlocked: Bool { blockedReason != nil }

    private typealias Field = InputDiagnosticEvent.Field
    private typealias Value = InputDiagnosticEvent.Value
    typealias Token = InputDiagnosticEvent.Token
    typealias Stage = InputDiagnosticEvent.Stage

    struct AttributeRead {
        let value: CFTypeRef?
        let status: AXError
        var timeoutConfigurationFailed = false

        func diagnosticState(hasValue: Bool, classifyTimeout: Bool = true) -> InputDiagnosticEvent.Token {
            switch status {
            case .success:
                if hasValue { return .value }
                return value == nil ? .noValue : .error
            case .noValue: return .noValue
            case .attributeUnsupported: return .unsupported
            case .cannotComplete where classifyTimeout: return .timeout
            default: return .error
            }
        }
    }

    @MainActor struct DeliveryGateRead {
        let role: String?
        let subrole: AttributeRead
        let selectedRange: AttributeRead
        let selectedMarker: AttributeRead?
        let editable: AttributeRead
        var roleStatus: AXError = .success

        func rejection(hasTextSelection: Bool, diagnostics: InputDiagnosticTrace?,
                       stage: InputDiagnosticEvent.Stage, began: TimeInterval?, retryCandidate: @autoclosure () -> Bool = false) -> String? {
            let subroleValue = subrole.value as? String
            let editableValue = editable.value.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0 as? Bool : nil }
            guard let reason = DeliveryTargetPolicy.blockedReason(
                role: role, subrole: subroleValue, editable: editableValue ?? false,
                hasTextSelection: hasTextSelection,
                subroleReadable: InsertionTarget.secureExclusionReadable(subrole.value, status: subrole.status)
            ) else { return nil }
            let pending = retryCandidate()
            guard let diagnostics, diagnostics.isCollecting else { return reason }
            let editableState: InputDiagnosticEvent.Token
            if let rawEditable = editable.value, CFGetTypeID(rawEditable) == CFBooleanGetTypeID(),
               let editableValue {
                editableState = editableValue ? .trueValue : .falseValue
            } else {
                editableState = editable.diagnosticState(hasValue: false, classifyTimeout: false)
            }
            diagnostics.record(pending ? .retry : .target, stage: stage, [
                .reason: .reason(reason), .outcome: .token(pending ? .pendingRetry : .blocked),
                .elapsedMS: .integer(began.map { InsertionTarget.elapsedMilliseconds(since: $0) } ?? 0),
                .roleBucket: .roleBucket(role),
                .subroleState: .token(subrole.diagnosticState(hasValue: subroleValue != nil)),
                .selectedRangeState: .token(selectedRange.diagnosticState(hasValue: selectedRange.value != nil)),
                // A successful numeric read skips the marker read entirely.
                .selectedMarkerState: .token(selectedMarker.map { $0.diagnosticState(hasValue: $0.value != nil) } ?? .skipped),
                .editableState: .token(editableState),
                .denylistHit: .flag(DeliveryTargetPolicy.isDenylisted(role: role))
            ])
            return reason
        }
    }

    /// Record content-free status and duration for bounded AX reads.
    static func copyAX(_ element: AXUIElement, name: CFString,
                       operation: Token, scope: Token = .focusedElement,
                       timeout: Float = 0.08,
                       setTimeout: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout,
                       read: (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyAttributeValue,
                       diagnostics: InputDiagnosticTrace?, stage: Stage) -> AttributeRead {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        let began = diagnostics.map { _ in ProcessInfo.processInfo.systemUptime }
        let timeoutStatus = setTimeout(element, timeout)
        var value: CFTypeRef?
        var status = AXError.failure
        defer {
            // Setting a timeout on the system-wide object changes the process
            // default. Never leave a short receipt-poll timeout installed.
            let resetStatus = scope == .system ? setTimeout(element, 0) : nil
            if let diagnostics, let began {
                var fields: [Field: Value] = [
                    .operation: .token(operation), .scope: .token(scope),
                    .error: .integer(Int(status.rawValue)),
                    .timeoutMS: .integer(Int((Double(timeout) * 1_000).rounded())),
                    .elapsedMS: .integer(Self.elapsedMilliseconds(since: began)),
                    .outcome: .token(status == .success ? (value == nil ? .missing : .ok) : .unavailable)
                ]
                fields[.timeoutError] = .integer(Int(timeoutStatus.rawValue))
                if let resetStatus { fields[.resetError] = .integer(Int(resetStatus.rawValue)) }
                diagnostics.record(.ax, stage: stage, fields)
            }
        }
        guard timeoutStatus == .success else {
            status = timeoutStatus
            return AttributeRead(value: nil, status: .cannotComplete, timeoutConfigurationFailed: true)
        }
        status = read(element, name, &value)
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
                                       diagnostics: InputDiagnosticTrace?, stage: Stage) -> (value: CFTypeRef, system: Bool)? {
        guard case .found(let value, let system) = resolveFocus(for: pid, timeout: timeout, diagnostics: diagnostics,
            stage: stage, reads: FocusReads(), stopOnOwnerMismatch: false) else { return nil }
        return (value, system)
    }

    private enum FocusResolution {
        case found(CFTypeRef, system: Bool)
        case ownerChanged
        case unavailable
    }

    private static func resolveFocus(for pid: pid_t, timeout: Float, diagnostics: InputDiagnosticTrace?,
                                     stage: Stage, reads: FocusReads, stopOnOwnerMismatch: Bool) -> FocusResolution {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        let app = AXUIElementCreateApplication(pid)
        let system = AXUIElementCreateSystemWide()
        func validated(_ read: AttributeRead, scope: Token) -> FocusResolution {
            guard let candidate = read.value else { return .unavailable }
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else {
                diagnostics?.record(.target, stage: stage, [
                    .scope: .token(scope), .element: .token(.invalidType)
                ])
                return .unavailable
            }
            let element = unsafeBitCast(candidate, to: AXUIElement.self)
            let owner = reads.owner(element, diagnostics, stage)
            diagnostics?.record(.target, stage: stage, [
                .scope: .token(scope),
                .owner: .token(owner.status == .success ? (owner.pid == pid ? .same : .different) : .unavailable)
            ])
            guard owner.status == .success else { return .unavailable }
            guard owner.pid == pid else { return stopOnOwnerMismatch ? .ownerChanged : .unavailable }
            return .found(candidate, system: scope == .system)
        }
        var mayAwakenViaWindow = true
        for (root, scope) in [(app, Token.application), (system, Token.system)] {
            let read = reads.attribute(root, kAXFocusedUIElementAttribute as CFString, .focusedElement, scope, timeout, diagnostics, stage)
            let resolved = validated(read, scope: scope)
            switch resolved {
            case .found, .ownerChanged: return resolved
            case .unavailable: break
            }
            if read.value != nil || (read.status != .noValue && read.status != .attributeUnsupported) {
                mayAwakenViaWindow = false
            }
        }
        // In Chromium/Electron apps, querying kAXFocusedWindowAttribute awakens
        // lazy renderer accessibility trees when kAXFocusedUIElementAttribute
        // initially returns .noValue / .attributeUnsupported on the application and system roots.
        guard mayAwakenViaWindow else { return .unavailable }
        let windowRead = reads.attribute(app, kAXFocusedWindowAttribute as CFString, .focusedWindow, .application, timeout, diagnostics, stage)
        guard windowRead.status == .success, let windowCandidate = windowRead.value,
              CFGetTypeID(windowCandidate) == AXUIElementGetTypeID() else { return .unavailable }
        let windowElement = unsafeBitCast(windowCandidate, to: AXUIElement.self)
        let windowFocus = reads.attribute(windowElement, kAXFocusedUIElementAttribute as CFString, .focusedElement, .focusedWindow, timeout, diagnostics, stage)
        let resolved = validated(windowFocus, scope: .focusedWindow)
        switch resolved {
        case .found, .ownerChanged: return resolved
        case .unavailable: break
        }
        guard windowFocus.value == nil,
              windowFocus.status == .noValue || windowFocus.status == .attributeUnsupported else { return .unavailable }
        let reawakenedApp = reads.attribute(app, kAXFocusedUIElementAttribute as CFString, .focusedElement, .application, timeout, diagnostics, stage)
        return validated(reawakenedApp, scope: .application)
    }

    /// Distinguish a legitimate absent subrole from a failed or mistyped read.
    static func secureExclusionReadable(_ value: CFTypeRef?, status: AXError) -> Bool {
        status == .attributeUnsupported || status == .noValue
            || (status == .success && (value == nil || value is String))
    }

    static func fieldHintStatusReadable(_ status: AXError) -> Bool {
        let succeeded: Bool = status == .success
        let noValue: Bool = status == .noValue
        let unsupported: Bool = status == .attributeUnsupported
        let successOrNoValue: Bool = succeeded || noValue
        return successOrNoValue || unsupported
    }

    enum CaptureSample {
        case accepted(InsertionTarget)
        case rejected(DeliveryRejection, String)
        case unavailable(InputDiagnosticEvent.Token, pid: pid_t?, focused: CFTypeRef?, ownerStatus: AXError?)

        var resolution: (target: InsertionTarget?, reason: String) {
            switch self {
            case .accepted(let target): return (target, "ok")
            case .rejected(_, let reason): return (nil, reason)
            case .unavailable(let reason, _, _, _): return (nil, reason.rawValue)
            }
        }
    }

    static func capture(diagnostics: InputDiagnosticTrace? = nil,
                        stage: InputDiagnosticEvent.Stage = .capture, requireTextInput: Bool = false,
                        externalText: ExternalTextAccess? = nil,
                        protectedBundleIdentifiers: Set<String>? = [])
        -> (target: InsertionTarget?, reason: String) {
        captureSample(diagnostics: diagnostics, stage: stage, requireTextInput: requireTextInput,
                      externalText: externalText, protectedBundleIdentifiers: protectedBundleIdentifiers).resolution
    }

    static func captureSample(diagnostics: InputDiagnosticTrace?, stage: InputDiagnosticEvent.Stage,
                              requireTextInput: Bool, externalText: ExternalTextAccess? = nil,
                              protectedBundleIdentifiers: Set<String>? = []) -> CaptureSample {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        let began = diagnostics.map { _ in ProcessInfo.processInfo.systemUptime }
        func failure(_ reason: Token, pid: pid_t? = nil, focused: CFTypeRef? = nil,
                     ownerStatus: AXError? = nil) -> CaptureSample {
            diagnostics?.record(.target, stage: stage, [
                .reason: .token(reason), .outcome: .token(.blocked),
                .elapsedMS: .integer(began.map { Self.elapsedMilliseconds(since: $0) } ?? 0)
            ])
            return .unavailable(reason, pid: pid, focused: focused, ownerStatus: ownerStatus)
        }
        let trusted = AXIsProcessTrusted()
        diagnostics?.record(.target, stage: stage, [.axTrusted: .flag(trusted)])
        guard trusted else { return failure(.accessibilityNotGranted) }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return failure(.noFrontmostApplication)
        }
        diagnostics?.record(.target, stage: stage, [
            .pid: .integer(Int(app.processIdentifier)),
            .app: app.bundleIdentifier.map { .application($0) } ?? .token(.unavailable)
        ])
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return failure(.koebridgeWindowIsFrontmost, pid: app.processIdentifier)
        }
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        guard let resolved = focusedElement(for: app.processIdentifier, diagnostics: diagnostics, stage: stage) else {
            return failure(.focusedTextElementUnavailable, pid: app.processIdentifier)
        }
        let focused = resolved.value
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        let owner = Self.owner(of: element, diagnostics: diagnostics, stage: stage)
        guard owner.status == .success else { return failure(.focusOwnerUnavailable, pid: app.processIdentifier, focused: focused, ownerStatus: owner.status) }
        guard owner.pid == app.processIdentifier else { return failure(.focusOwnerMismatch, pid: app.processIdentifier, focused: focused, ownerStatus: owner.status) }
        let windowRead = copyAX(appAX, name: kAXFocusedWindowAttribute as CFString,
                            operation: .focusedWindow, scope: .application,
                            diagnostics: diagnostics, stage: stage)
        let window = windowRead.value
        let selectionAttribute: String?
        let selection: CFTypeRef?
        let rangeRead = copyAX(element, name: kAXSelectedTextRangeAttribute as CFString,
                               operation: .selectedRange, diagnostics: diagnostics, stage: stage)
        let markerRead: AttributeRead?
        if let range = rangeRead.value {
            markerRead = nil
            selectionAttribute = kAXSelectedTextRangeAttribute as String
            selection = range
        } else {
            let read = copyAX(element, name: "AXSelectedTextMarkerRange" as CFString,
                              operation: .selectedMarker, diagnostics: diagnostics, stage: stage)
            markerRead = read
            selectionAttribute = read.value == nil ? nil : "AXSelectedTextMarkerRange"
            selection = read.value
        }
        if let selection, decodeSelection(selection, kind: markerRead == nil ? .numericRange : .textMarker) == nil {
            return failure(.capturedSelectionInvalid, pid: app.processIdentifier)
        }
        var target = InsertionTarget(bundleIdentifier: app.bundleIdentifier, localizedName: app.localizedName,
                                     pid: app.processIdentifier, focused: focused,
                                     window: window, selectionAttribute: selectionAttribute,
                                     selection: selection, textSnapshot: nil,
                                     capturedAt: ProcessInfo.processInfo.systemUptime,
                                     blockedReason: nil)
        if requireTextInput {
            let roleRead = copyAX(element, name: kAXRoleAttribute as CFString, operation: .role,
                              diagnostics: diagnostics, stage: stage)
            let subroleRead = copyAX(element, name: kAXSubroleAttribute as CFString, operation: .subrole,
                                     diagnostics: diagnostics, stage: stage)
            let editableRead = copyAX(element, name: "AXEditable" as CFString, operation: .editable,
                                      diagnostics: diagnostics, stage: stage)
            let editableValue = editableRead.value.flatMap {
                CFGetTypeID($0) == CFBooleanGetTypeID() ? $0 as? Bool : nil
            }
            let titleRead = copyAX(element, name: "AXTitle" as CFString, operation: .title,
                                   timeout: 0.02, diagnostics: diagnostics, stage: stage)
            let descriptionRead = copyAX(element, name: "AXDescription" as CFString,
                                         operation: .fieldDescription, timeout: 0.02,
                                         diagnostics: diagnostics, stage: stage)
            let placeholderRead = copyAX(element, name: "AXPlaceholderValue" as CFString,
                                         operation: .placeholder, timeout: 0.02,
                                         diagnostics: diagnostics, stage: stage)
            let fieldHints: [String?] = [
                target.localizedName,
                titleRead.value as? String,
                descriptionRead.value as? String,
                placeholderRead.value as? String
            ]
            let titleHintReadable: Bool = InsertionTarget.fieldHintStatusReadable(titleRead.status)
            let descriptionHintReadable: Bool = InsertionTarget.fieldHintStatusReadable(descriptionRead.status)
            let placeholderHintReadable: Bool = InsertionTarget.fieldHintStatusReadable(placeholderRead.status)
            let titleAndDescriptionHintsReadable: Bool = titleHintReadable && descriptionHintReadable
            let hintReadsReadable: Bool = titleAndDescriptionHintsReadable && placeholderHintReadable
            let gate = DeliveryGateRead(role: roleRead.value as? String, subrole: subroleRead, selectedRange: rangeRead,
                                        selectedMarker: markerRead, editable: editableRead, roleStatus: roleRead.status)
            lazy var rejection = DeliveryRejection(target: target, gate: gate, rejectedAt: ProcessInfo.processInfo.systemUptime,
                                                   windowStatus: windowRead.status, ownerPID: owner.pid,
                                                   systemFocus: resolved.system)
            if let reason = gate.rejection(hasTextSelection: selection != nil, diagnostics: diagnostics,
                                           stage: stage, began: began,
                                           retryCandidate: rejection.eligible) {
                LocalDiagnostics.record(.failClosed(code: reason))
                return .rejected(rejection, reason)
            }
            let roleValue: String? = roleRead.value as? String
            let subroleValue: String? = subroleRead.value as? String
            let hasTextSelection: Bool = selection != nil
            let secureInputEnabled: Bool = IsSecureEventInputEnabled()
            let roleAttributeReadable: Bool = roleRead.status == .success
            let roleAndHintsReadable: Bool = roleAttributeReadable && hintReadsReadable
            let subroleAttributeReadable: Bool = InsertionTarget.secureExclusionReadable(
                subroleRead.value, status: subroleRead.status
            )
            let attributesReadable: Bool = roleAndHintsReadable && subroleAttributeReadable
            let receiptFieldNature: InsertionReceiptPolicy.FieldNature = InsertionReceiptPolicy.fieldNature(
                role: roleValue,
                subrole: subroleValue,
                editable: editableValue,
                hasTextSelection: hasTextSelection,
                bundleIdentifier: target.bundleIdentifier,
                labelHints: fieldHints,
                secureInputEnabled: secureInputEnabled,
                attributesReadable: attributesReadable,
                protectedBundleIdentifiers: protectedBundleIdentifiers
            )
            LocalDiagnostics.record(.fieldNature(receiptFieldNature))
            target = target.withReceiptFieldNature(receiptFieldNature)
        }
        // Keep this delivery baseline ephemeral. External surrounding context
        // takes a fresh security-checked snapshot.
        // A second bounded attempt covers an editor consuming an earlier take.
        if selectionAttribute == kAXSelectedTextRangeAttribute as String {
            for _ in 0..<2 {
                if let observed = target.observedSnapshot(timeout: 0.04, diagnostics: diagnostics, stage: stage,
                                                          externalText: externalText) {
                    target.textSnapshot = observed.snapshot
                    target.selection = observed.selection
                    break
                }
                if externalText?.refused == true { break }
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
            diagnostics.record(.target, stage: stage, fields)
        }
        return .accepted(target)
    }

    /// Receipt reads allow editors without a subrole. Text leaving the app
    /// requires affirmative, typed answers from both security attributes.
    final class ExternalTextAccess {
        private(set) var refused = false

        // One operation can perform multiple reads (including snapshot retries).
        // A later successful AX call cannot undo an earlier security refusal.
        func permits(role: AttributeRead, subrole: AttributeRead) -> Bool {
            guard !refused, role.status == .success, let roleName = role.value as? String,
                  subrole.status == .success, let subroleName = subrole.value as? String,
                  roleName != "AXSecureTextField", subroleName != "AXSecureTextField" else {
                refused = true
                return false
            }
            return true
        }
    }

    static func captureExternalSelection(
        captureTarget: @MainActor (ExternalTextAccess) -> InsertionTarget? = { InsertionTarget.capture(externalText: $0).target },
        reads: FocusReads = FocusReads()
    ) -> (InsertionTarget, String)? {
        let access = ExternalTextAccess()
        guard let target = captureTarget(access), !access.refused, target.selection != nil,
              let selected = target.selectedContextText(externalText: access, reads: reads), !selected.isEmpty else { return nil }
        return (target, selected)
    }

    func selectedContextText(externalText: ExternalTextAccess?, reads: FocusReads = FocusReads()) -> String? {
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        func read(_ name: String, _ operation: Token) -> AttributeRead {
            reads.attribute(element, name as CFString, operation, .focusedElement, 0.08, nil, .capture)
        }
        let subrole = read(kAXSubroleAttribute, .subrole)
        if let externalText {
            guard externalText.permits(role: read(kAXRoleAttribute, .role), subrole: subrole) else { return nil }
        } else if subrole.timeoutConfigurationFailed || (subrole.status == .success && subrole.value as? String == "AXSecureTextField") {
            return nil
        }
        return read(kAXSelectedTextAttribute, .value).value as? String
    }

    var selectionKind: InputDiagnosticEvent.Token {
        guard let selectionAttribute else { return .none }
        if selectionAttribute == (kAXSelectedTextRangeAttribute as String) { return .numericRange }
        if selectionAttribute == "AXSelectedTextMarkerRange" { return .textMarker }
        return .unknown
    }

    /// Many browser editors do not expose AXValue. Unknown contents never
    /// authorize a caret rebase, and secure field contents are not collected.
    func observedValue(timeout: Float = 0.04, diagnostics: InputDiagnosticTrace? = nil,
                       stage: InputDiagnosticEvent.Stage = .preflight,
                       requireKnownNonsecure: Bool = false, externalText: ExternalTextAccess? = nil,
                       reads: FocusReads = FocusReads(),
                       observation: ((Bool, InputDiagnosticEvent.Token) -> Void)? = nil) -> String? {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        var evidence: [Field: Value]? = diagnostics.map { _ in [.operation: .token(.value)] }
        var outcome: Token = .unavailable
        var attempted = false
        var readTimedOut = false
        let began = diagnostics.map { _ in ProcessInfo.processInfo.systemUptime }
        let counterBegan = ProcessInfo.processInfo.systemUptime
        defer {
            LocalDiagnostics.record(.fieldRead(
                milliseconds: Self.elapsedMilliseconds(since: counterBegan),
                timedOut: readTimedOut))
            observation?(attempted, outcome)
            if let diagnostics, var fields = evidence {
                fields[.outcome] = .token(outcome)
                fields[.valueReadAttempted] = .flag(attempted)
                fields[.valueReadResult] = .token(outcome)
                fields[.elapsedMS] = .integer(began.map { Self.elapsedMilliseconds(since: $0) } ?? 0)
                diagnostics.record(.snapshot, stage: stage, fields)
            }
        }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            evidence?[.element] = .token(.invalidType)
            outcome = .invalidType
            return nil
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        let subrole = reads.attribute(element, kAXSubroleAttribute as CFString, .subrole, .focusedElement,
                                      timeout, diagnostics, stage)
        readTimedOut = subrole.status == .cannotComplete
        if let externalText {
            let role = reads.attribute(element, kAXRoleAttribute as CFString, .role, .focusedElement,
                                       timeout, diagnostics, stage)
            readTimedOut = readTimedOut || role.status == .cannotComplete
            guard externalText.permits(role: role, subrole: subrole) else { return nil }
        }
        guard !subrole.timeoutConfigurationFailed else { return nil }
        if subrole.status == .success, (subrole.value as? String) == "AXSecureTextField" {
            evidence?[.subrole] = .token(.secure)
            outcome = .secure
            return nil
        }
        evidence?[.subrole] = .token(subrole.status != .success ? .unavailable
                                     : subrole.value == nil ? .missing
                                     : subrole.value is String ? .ok : .invalidType)
        // Extra diagnostic-only probes fail closed if secure-field exclusion
        // cannot be established. Existing receipt reads retain their policy.
        if requireKnownNonsecure && (subrole.status != .success || !(subrole.value is String)) {
            outcome = .unknown
            return nil
        }
        attempted = true
        let value = reads.attribute(element, kAXValueAttribute as CFString, .value, .focusedElement,
                                    timeout, diagnostics, stage)
        readTimedOut = readTimedOut || value.status == .cannotComplete
        guard let raw = value.value else {
            outcome = value.status == .attributeUnsupported ? .unsupported : value.status == .success ? .missing : .unavailable
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

    /// Keep the original four-read preflight budget even when retrying AXValue.
    func deliveryBaseline(diagnostics: InputDiagnosticTrace?, reads: FocusReads = FocusReads())
        -> (InsertionReceiptPolicy.Snapshot?, ReceiptEligibilityReason) {
        var reason = ReceiptEligibilityReason.notAttempted
        let deadline = ProcessInfo.processInfo.systemUptime + 0.16
        var bounded = reads
        bounded.attribute = { element, name, operation, scope, timeout, trace, stage in
            let remaining = Float(deadline - ProcessInfo.processInfo.systemUptime).nextDown
            guard remaining > 0 else { return AttributeRead(value: nil, status: .cannotComplete) }
            return reads.attribute(element, name, operation, scope, min(timeout, remaining), trace, stage)
        }
        for _ in 0..<2 {
            let result = observedSnapshot(timeout: 0.04, diagnostics: diagnostics, reads: bounded,
                                          eligibility: { reason = $0 })
            if let result { return (result.snapshot, reason) }
            if reason != .valueUnavailable { break }
        }
        return (nil, reason)
    }

    /// Read text between two equal selections, so a moving editor does not
    /// combine a previous caret with a later partial value. Opaque marker
    /// ranges cannot be turned into numeric offsets by guessing.
    func observedSnapshot(timeout: Float, diagnostics: InputDiagnosticTrace? = nil,
                          stage: InputDiagnosticEvent.Stage = .preflight,
                          externalText: ExternalTextAccess? = nil, reads: FocusReads = FocusReads(),
                          eligibility: ((ReceiptEligibilityReason) -> Void)? = nil)
        -> (snapshot: InsertionReceiptPolicy.Snapshot, selection: CFTypeRef)? {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        var evidence: [Field: Value]? = diagnostics.map { _ in [
            .operation: .token(.selectedRange), .selectionKind: .token(selectionKind)
        ] }
        var outcome: Token = .unavailable
        var selectionRead: Token = .notAttempted
        var valueRead: Token = .notAttempted
        var valueAttempted = false
        defer {
            let reason = ReceiptEligibilityReason.classify(selectionKind: selectionKind,
                selectionRead: selectionRead, valueRead: valueRead, snapshotAvailable: outcome == .ok)
            eligibility?(reason)
            if let diagnostics, var fields = evidence {
                fields[.outcome] = .token(outcome)
                fields[.selectionRead] = .token(selectionRead)
                fields[.valueReadAttempted] = .flag(valueAttempted)
                fields[.valueReadResult] = .token(valueRead)
                fields[.exactBaselineAvailable] = .flag(outcome == .ok)
                fields[.receiptSkippedReason] = .reason(reason.rawValue)
                diagnostics.record(.snapshot, stage: stage, fields)
            }
        }
        guard selectionAttribute == kAXSelectedTextRangeAttribute as String else { return nil }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            evidence?[.element] = .token(.invalidType)
            outcome = .invalidType
            selectionRead = .invalidType
            return nil
        }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        let firstRead = reads.attribute(element, kAXSelectedTextRangeAttribute as CFString, .selectedRange,
                                        .focusedElement, timeout, diagnostics, stage)
        selectionRead = firstRead.status != .success ? .unavailable : firstRead.value == nil ? .missing : .ok
        guard let first = firstRead.value else {
            evidence?[.selection] = .token(firstRead.status == .success ? .missing : .unavailable)
            return nil
        }
        let firstRange = Self.numericSelection(first)
        guard let initialRange = firstRange.range else {
            evidence?[.selection] = .token(firstRange.outcome)
            outcome = firstRange.outcome
            selectionRead = firstRange.outcome
            return nil
        }
        guard let text = observedValue(timeout: timeout, diagnostics: diagnostics, stage: stage,
                                      externalText: externalText, reads: reads, observation: { attempted, result in
                                          valueAttempted = attempted
                                          valueRead = result
                                      }) else {
            evidence?[.text] = .token(.unavailable)
            return nil
        }
        let lastRead = reads.attribute(element, kAXSelectedTextRangeAttribute as CFString, .selectedRange,
                                        .focusedElement, timeout, diagnostics, stage)
        selectionRead = lastRead.status != .success ? .unavailable : lastRead.value == nil ? .missing : .ok
        guard let last = lastRead.value else {
            evidence?[.selection] = .token(lastRead.status == .success ? .missing : .unavailable)
            return nil
        }
        let lastRange = Self.numericSelection(last)
        guard let range = lastRange.range else {
            evidence?[.selection] = .token(lastRange.outcome)
            outcome = lastRange.outcome
            selectionRead = lastRange.outcome
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

    enum DecodedSelection: Equatable {
        case numeric(InsertionReceiptPolicy.Selection)
        case marker(CFTypeRef)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.numeric(let a), .numeric(let b)): return a == b
            case (.marker(let a), .marker(let b)): return CFEqual(a, b)
            default: return false
            }
        }
    }

    static func decodeSelection(_ value: CFTypeRef, kind: Token) -> DecodedSelection? {
        switch kind {
        case .numericRange: return numericSelection(value).range.map(DecodedSelection.numeric)
        case .textMarker: return CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() ? .marker(value) : nil
        default: return nil
        }
    }

    static func numericSelection(_ value: CFTypeRef)
        -> (range: InsertionReceiptPolicy.Selection?, outcome: InputDiagnosticEvent.Token) {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return (nil, .invalidType) }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return (nil, .invalidType) }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.length >= 0, range.length <= Int.max - range.location else { return (nil, .invalidRange) }
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

    func withReceiptFieldNature(_ nature: InsertionReceiptPolicy.FieldNature) -> InsertionTarget {
        var updated = self
        updated.receiptFieldNature = nature
        return updated
    }

    func removingTextSnapshot() -> InsertionTarget {
        var updated = self
        updated.textSnapshot = nil
        return updated
    }

    func removingTextSnapshotUnlessNormal() -> InsertionTarget {
        receiptFieldNature == .normal ? self : removingTextSnapshot()
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

    /// Write the actual AX selection, then verify numeric range, full value,
    /// focus identity and selected text. rebased(to:) alone never writes AX.
    func selectDeliveredSpan(before: InsertionReceiptPolicy.Snapshot,
                             after: InsertionReceiptPolicy.Snapshot,
                             submitted: String) -> InsertionTarget? {
        guard focusCheck(requireOriginalSelection: false).allowed,
              observedSnapshot(timeout: 0.08)?.snapshot == after else { return nil }
        let span = InsertionReceiptPolicy.Selection(location: before.selection.location, length: submitted.utf16.count)
        let selected = InsertionReceiptPolicy.Snapshot(text: after.text, selection: span)
        guard InsertionReceiptPolicy.isValid(selected),
              let target = rebased(to: selected), let value = target.selection else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success,
              target.focusCheck().allowed,
              target.observedSnapshot(timeout: 0.08)?.snapshot == selected,
              let readBack = target.selectedContextText(externalText: nil),
              InsertionReceiptPolicy.sameText(readBack, submitted) else { return nil }
        return target
    }

    func blockedByPriorInput(hard: Bool = false) -> InsertionTarget {
        LocalDiagnostics.record(.failClosed(code: "prior_input_unverified"))
        var updated = self
        updated.blockedReason = "prior_input_unverified"
        if hard { updated.hasHardPredecessorBlock = true }
        return updated
    }

    struct FocusReads {
        var frontPID: @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        // Optional already-resolved field for transport fixtures. Live reads use both AX roots.
        var focused: (@MainActor (pid_t, Float, InputDiagnosticTrace?, InputDiagnosticEvent.Stage) -> CFTypeRef?)?
        var owner: @MainActor (AXUIElement, InputDiagnosticTrace?, InputDiagnosticEvent.Stage) -> (pid: pid_t, status: AXError) = {
            InsertionTarget.owner(of: $0, diagnostics: $1, stage: $2)
        }
        var attribute: @MainActor (AXUIElement, CFString, InputDiagnosticEvent.Token, InputDiagnosticEvent.Token,
                                   Float, InputDiagnosticTrace?, InputDiagnosticEvent.Stage) -> AttributeRead = {
            InsertionTarget.copyAX($0, name: $1, operation: $2, scope: $3, timeout: $4,
                                   diagnostics: $5, stage: $6)
        }
    }

    func focusCheck(requireOriginalSelection: Bool = true, timeout: Float = 0.08,
                    diagnostics: InputDiagnosticTrace? = nil,
                    stage: InputDiagnosticEvent.Stage = .preflight,
                    chunkOrdinal: Int = 0, reads: FocusReads = FocusReads()) -> (allowed: Bool, reason: String) {
        let diagnostics = diagnostics?.isCollecting == true ? diagnostics : nil
        let began = diagnostics.map { _ in ProcessInfo.processInfo.systemUptime }
        var evidence: [Field: Value]? = diagnostics.map { _ in [
            .pid: .integer(Int(pid)), .originalSelection: .flag(requireOriginalSelection),
            .requireOriginalSelection: .flag(requireOriginalSelection),
            .chunkOrdinal: .integer(chunkOrdinal),
            .selectionKind: .token(selectionKind),
            .selection: .token(requireOriginalSelection ? .unknown : .skipped),
            .captureAgeMS: .integer(Self.elapsedMilliseconds(since: capturedAt))
        ] }
        func result(_ allowed: Bool, _ reason: String) -> (allowed: Bool, reason: String) {
            if let diagnostics, var fields = evidence {
                fields[.reason] = .reason(reason)
                fields[.outcome] = .token(allowed ? .ok : .blocked)
                // Failed/missing reads are unknown comparisons, never drift.
                switch fields[.selection] {
                case .token(.same)?: fields[.selectionComparison] = .token(.same)
                case .token(.different)?: fields[.selectionComparison] = .token(.different)
                default: fields[.selectionComparison] = .token(requireOriginalSelection ? .unknown : .skipped)
                }
                fields[.elapsedMS] = .integer(began.map { Self.elapsedMilliseconds(since: $0) } ?? 0)
                diagnostics.record(.focus, stage: stage, fields)
            }
            if !allowed { LocalDiagnostics.record(.failClosed(code: reason)) }
            return (allowed, reason)
        }
        if let blockedReason { return result(false, blockedReason) }
        let frontPID = reads.frontPID()
        evidence?[.frontPID] = frontPID.map { .integer(Int($0)) } ?? .token(.unavailable)
        guard let frontPID else { return result(false, "frontmost_application_unavailable") }
        let sameProcess = frontPID == pid
        guard sameProcess else { return result(false, "active_app_changed") }
        let resolution: FocusResolution
        if let focused = reads.focused {
            resolution = focused(pid, timeout, diagnostics, stage).map { .found($0, system: false) } ?? .unavailable
        } else {
            resolution = Self.resolveFocus(for: pid, timeout: timeout, diagnostics: diagnostics, stage: stage,
                                           reads: reads, stopOnOwnerMismatch: stage == .posting)
        }
        let currentFocused: CFTypeRef
        switch resolution {
        case .found(let element, _): currentFocused = element
        case .ownerChanged:
            evidence?[.owner] = .token(.different)
            return result(false, "focused_element_owner_changed")
        case .unavailable:
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
            let currentWindow = reads.attribute(appAX, kAXFocusedWindowAttribute as CFString, .focusedWindow,
                                                .application, timeout, diagnostics, stage)
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
        let owner = reads.owner(element, diagnostics, stage)
        let sameElementOwner = owner.status == .success && owner.pid == pid
        evidence?[.owner] = .token(owner.status != .success ? .unavailable
                                   : sameElementOwner ? .same : .different)
        var selectionMatches: Bool?
        var selectionFailure: String?
        if requireOriginalSelection, let selectionAttribute, let selection {
            let numeric = selectionAttribute == kAXSelectedTextRangeAttribute as String
            let currentSelection = reads.attribute(element, selectionAttribute as CFString,
                                                   numeric ? .selectedRange : .selectedMarker, .focusedElement,
                                                   timeout, diagnostics, stage)
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
                    guard let expected = Self.decodeSelection(selection, kind: .textMarker),
                          let actual = Self.decodeSelection(value, kind: .textMarker) else {
                        return result(false, "selection_value_invalid_on_recheck")
                    }
                    selectionMatches = expected == actual
                    evidence?[.selection] = .token(selectionMatches == true ? .same : .different)
                    if selectionMatches == false { selectionFailure = "marker_selection_changed" }
                }
            } else {
                selectionMatches = false
                evidence?[.selection] = .token(currentSelection.status == .success ? .missing : .unavailable)
                selectionFailure = "selection_unavailable_on_recheck"
            }
        }
        // Preserve the original fail-closed decisions and failure precedence;
        // an affirmative mismatch or invalid value dominates transient unavailability
        // so it is never eligible for a transient-unavailability recheck.
        let ownerFailure: String? = sameElementOwner ? nil
            : (owner.status == .success ? "focused_element_owner_changed" : "focused_element_owner_unavailable")
        for failure in [windowFailure, ownerFailure, selectionFailure].compactMap({ $0 }) {
            if !InsertionFocusPolicy.isTransientFocusUnavailability(failure) {
                return result(false, failure)
            }
        }
        if let windowFailure { return result(false, windowFailure) }
        if let ownerFailure { return result(false, ownerFailure) }
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
