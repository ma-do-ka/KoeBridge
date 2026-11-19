#if os(macOS)
import AppKit
import ApplicationServices
import KoeBridgeCore

/// These references belong only to the current delivery adjudication.
@MainActor struct DeliveryRejection {
    let target: InsertionTarget
    let gate: InsertionTarget.DeliveryGateRead
    let rejectedAt: TimeInterval

    var windowStatus: AXError = .success
    let ownerPID: pid_t
    var systemFocus = false

    var eligible: Bool {
        ownerPID == target.pid && windowStatus == .success
            && gate.roleStatus == .success && DeliveryTargetPolicy.isDenylisted(role: gate.role)
            && gate.selectedRange.status == .noValue && gate.selectedMarker?.status == .noValue
            && gate.editable.status == .noValue && gate.subrole.value as? String != "AXSecureTextField"
            && InsertionTarget.secureExclusionReadable(gate.subrole.value, status: gate.subrole.status)
            && target.window.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true
    }
}

/// The production and test transports use the same deadline and AX type checks.
struct RecoveryAX {
    typealias Read = InsertionTarget.AttributeRead
    var now = { ProcessInfo.processInfo.systemUptime }
    var sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    var frontPID: @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var setTimeout = AXUIElementSetMessagingTimeout
    var attribute: (AXUIElement, CFString) -> Read = { element, name in
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        return Read(value: status == .success ? value : nil, status: status)
    }
    var owner: (AXUIElement) -> pid_t? = { element in
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    enum Failure: Error { case expired, unavailable }

    func configure(_ element: AXUIElement, until deadline: TimeInterval) throws {
        let remaining = deadline - now()
        guard remaining > 0 else { throw Failure.expired }
        let timeout = Float(min(remaining, 0.08)).nextDown
        guard timeout > 0, setTimeout(element, timeout) == .success else { throw Failure.unavailable }
        guard now() < deadline else { throw Failure.expired }
    }

    func read(_ element: AXUIElement, _ name: String, until deadline: TimeInterval) throws -> Read {
        try configure(element, until: deadline)
        let read = attribute(element, name as CFString)
        guard now() < deadline else { throw Failure.expired }
        return read
    }
}

@MainActor struct DeliveryRecovery {
    private static let positiveTextRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
    ]

    let original: InsertionTarget
    let systemFocus: Bool
    let rejectedAt: TimeInterval
    let ax: RecoveryAX
    let defaultFailureReason: String
    let requireSameElement: Bool
    var deadline: TimeInterval { rejectedAt + 0.100 }

    init(rejection: DeliveryRejection, ax: RecoveryAX) {
        original = rejection.target
        systemFocus = rejection.systemFocus
        rejectedAt = rejection.rejectedAt
        self.ax = ax
        defaultFailureReason = "current_target_not_text_input"
        requireSameElement = true
    }

    init(unavailableTarget: InsertionTarget, rejectedAt: TimeInterval, ax: RecoveryAX) {
        original = unavailableTarget
        systemFocus = true
        self.rejectedAt = rejectedAt
        self.ax = ax
        defaultFailureReason = "target_unavailable_at_delivery"
        requireSameElement = false
    }

    @MainActor struct Host {
        let target: InsertionTarget
        let role: String

        func matches(_ other: Host) -> Bool {
            guard target.sameField(as: other.target),
                  role == other.role, target.selectionAttribute == other.target.selectionAttribute,
                  let a = target.selection, let b = other.target.selection else { return false }
            return CFEqual(a, b)
        }
    }

    enum Sample { case button, editor(Host), rejected }

    func observe(until limit: TimeInterval, index: Int? = nil,
                 diagnostics: InputDiagnosticTrace? = nil) -> Sample {
        var fields: [InputDiagnosticEvent.Field: InputDiagnosticEvent.Value] = [
            .roleBucket: .roleBucket(nil), .subroleState: .token(.skipped),
            .selectedRangeState: .token(.skipped), .selectedMarkerState: .token(.skipped),
            .editableState: .token(.skipped), .window: .token(.unknown),
            .element: .token(.unknown), .owner: .token(.unknown), .elementWindow: .token(.unknown)
        ]
        defer {
            if let index {
                fields[.retryIndex] = .integer(index)
                fields[.elapsedMS] = .integer(Int((ax.now() - rejectedAt) * 1000))
                fields[.deadlineExceeded] = .flag(ax.now() >= limit)
                diagnostics?.record(.retry, stage: .preflight, fields)
            }
        }
        let app = AXUIElementCreateApplication(original.pid)
        func matches(_ read: RecoveryAX.Read, _ expected: CFTypeRef, field: InputDiagnosticEvent.Field) -> Bool {
            guard read.status == .success, let value = read.value else {
                fields[field] = .token(.unavailable)
                return false
            }
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                fields[field] = .token(.invalidType)
                return false
            }
            let equal = CFEqual(expected, value)
            fields[field] = .flag(equal)
            return equal
        }
        func focus(in windowElement: AXUIElement?) throws -> RecoveryAX.Read {
            let first = try ax.read(app, kAXFocusedUIElementAttribute, until: limit)
            if first.value != nil { return first }
            guard first.status == .noValue || first.status == .attributeUnsupported || first.status == .success
            else { return first }
            if systemFocus {
                // System-wide timeout changes the process default. Restore it even on late IPC.
                let system = AXUIElementCreateSystemWide()
                let result = Result { try ax.read(system, kAXFocusedUIElementAttribute, until: limit) }
                guard ax.setTimeout(system, 0) == .success else { throw RecoveryAX.Failure.unavailable }
                let sysRead = try result.get()
                if sysRead.value != nil { return sysRead }
            }
            if let windowElement, !requireSameElement {
                let winFocus = try ax.read(windowElement, kAXFocusedUIElementAttribute, until: limit)
                if winFocus.value != nil { return winFocus }
            }
            return first
        }
        func resolveCandidate() throws -> (element: AXUIElement, sameElement: Bool, window: CFTypeRef)? {
            let samePID = ax.frontPID() == original.pid
            fields[.frontMatches] = .flag(samePID)
            guard samePID else { return nil }
            let expectedWindow: CFTypeRef
            if let capturedWindow = original.window {
                expectedWindow = capturedWindow
            } else {
                let winRead = try ax.read(app, kAXFocusedWindowAttribute, until: limit)
                guard winRead.status == .success, let value = winRead.value,
                      CFGetTypeID(value) == AXUIElementGetTypeID() else {
                    fields[.window] = .token(winRead.value == nil ? .unavailable : .invalidType)
                    return nil
                }
                expectedWindow = value
            }
            let windowElement = unsafeBitCast(expectedWindow, to: AXUIElement.self)
            let focusRead = try focus(in: windowElement)
            guard focusRead.status == .success, let value = focusRead.value else {
                fields[.element] = .token(.unavailable)
                return nil
            }
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                fields[.element] = .token(.invalidType)
                return nil
            }
            let isSameElement = CFEqual(original.focused, value)
            fields[.element] = .flag(isSameElement)
            guard isSameElement || !requireSameElement else { return nil }
            let candidate = unsafeBitCast(value, to: AXUIElement.self)
            try ax.configure(candidate, until: limit)
            guard let owner = ax.owner(candidate) else {
                fields[.owner] = .token(.unavailable)
                return nil
            }
            let sameOwner = owner == original.pid
            fields[.owner] = .flag(sameOwner)
            guard sameOwner else { return nil }
            guard matches(try ax.read(app, kAXFocusedWindowAttribute, until: limit), expectedWindow, field: .window) else {
                return nil
            }
            return (candidate, isSameElement, expectedWindow)
        }
        do {
            guard let resolved = try resolveCandidate() else {
                if defaultFailureReason == "target_unavailable_at_delivery",
                   ax.frontPID() == original.pid,
                   fields[.element] == .token(.unavailable),
                   ax.now() < limit {
                    return .button
                }
                return .rejected
            }
            let element = resolved.element
            let isSameElement = resolved.sameElement
            let window = resolved.window
            func read(_ name: String) throws -> RecoveryAX.Read {
                try ax.read(element, name, until: limit)
            }
            let roleRead = try read(kAXRoleAttribute)
            let role = roleRead.value as? String
            fields[.role] = .token(roleRead.diagnosticState(hasValue: role != nil))
            fields[.roleBucket] = .roleBucket(role)
            let sub = try read(kAXSubroleAttribute)
            fields[.subroleState] = .token(sub.diagnosticState(hasValue: sub.value is String))
            guard roleRead.status == .success, let role,
                  InsertionTarget.secureExclusionReadable(sub.value, status: sub.status),
                  sub.value as? String != "AXSecureTextField",
                  role != "AXSecureTextField" else { return .rejected }
            if isSameElement {
                guard DeliveryTargetPolicy.isDenylisted(role: role)
                    || ["AXTextField", "AXTextArea"].contains(role) else { return .rejected }
            } else {
                // Case B: Different element in the same window/process requires positive editor evidence
                // and must not be a denylisted control role unless AXEditable == true with live selection.
                guard Self.positiveTextRoles.contains(role) || !DeliveryTargetPolicy.isDenylisted(role: role) else {
                    return .rejected
                }
            }
            let rangeName = kAXSelectedTextRangeAttribute as String
            let markerName = "AXSelectedTextMarkerRange"
            let range = try read(rangeName)
            fields[.selectedRangeState] = .token(range.diagnosticState(hasValue: range.value != nil))
            let name: String
            let selection: CFTypeRef
            if let value = range.value {
                let decoded = InsertionTarget.numericSelection(value)
                guard let numeric = decoded.range else {
                    fields[.selectedRangeState] = .token(decoded.outcome)
                    return .rejected
                }
                guard !numeric.location.addingReportingOverflow(numeric.length).overflow else {
                    fields[.selectedRangeState] = .token(.invalidRange)
                    return .rejected
                }
                guard range.status == .success, !DeliveryTargetPolicy.isDenylisted(role: role) else { return .rejected }
                name = rangeName
                selection = value
            } else {
                guard range.status == .noValue || range.status == .attributeUnsupported || range.status == .success
                else { return .rejected }
                let marker = try read(markerName)
                fields[.selectedMarkerState] = .token(marker.diagnosticState(hasValue: marker.value != nil))
                if isSameElement && DeliveryTargetPolicy.isDenylisted(role: role) {
                    guard range.status == .noValue, marker.status == .noValue else { return .rejected }
                    let editable = try read("AXEditable")
                    fields[.editableState] = .token(editable.diagnosticState(hasValue: editable.value != nil))
                    return editable.status == .noValue && ax.now() < limit ? .button : .rejected
                }
                guard marker.status == .success, let value = marker.value else { return .rejected }
                guard CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else {
                    fields[.selectedMarkerState] = .token(.invalidType)
                    return .rejected
                }
                name = markerName
                selection = value
            }
            if !isSameElement && !Self.positiveTextRoles.contains(role) {
                let editable = try read("AXEditable")
                let editableTrue = editable.status == .success
                    && editable.value.map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true
                    && (editable.value as? Bool) == true
                fields[.editableState] = .token(editableTrue ? .trueValue : editable.diagnosticState(hasValue: false))
                guard editableTrue else { return .rejected }
            }
            guard matches(try read(kAXWindowAttribute), window, field: .elementWindow),
                  let rechecked = try resolveCandidate(),
                  CFEqual(rechecked.element, element),
                  CFEqual(rechecked.window, window) else { return .rejected }
            let finalRole = try read(kAXRoleAttribute)
            fields[.roleBucket] = .roleBucket(finalRole.value as? String)
            guard finalRole.status == .success, finalRole.value as? String == role else { return .rejected }
            let finalSubrole = try read(kAXSubroleAttribute)
            fields[.subroleState] = .token(finalSubrole.diagnosticState(hasValue: finalSubrole.value is String))
            guard InsertionTarget.secureExclusionReadable(finalSubrole.value, status: finalSubrole.status),
                  finalSubrole.value as? String != "AXSecureTextField", ax.frontPID() == original.pid,
                  ax.now() < limit else { return .rejected }
            let target = InsertionTarget(bundleIdentifier: original.bundleIdentifier, localizedName: original.localizedName,
                pid: original.pid, focused: element, window: window, selectionAttribute: name,
                selection: selection, textSnapshot: nil, capturedAt: ax.now(), blockedReason: nil)
            return .editor(Host(target: target, role: role))
        } catch { return .rejected }
    }

    /// Take a single value snapshot, bracketed by consistent host and selection reads.
    /// Marker ranges have no numeric baseline and can never authorize a command.
    func confirmedBaseline(_ host: Host, mayObserve: () -> Bool) throws -> InsertionReceiptPolicy.Snapshot? {
        var snapshot: InsertionReceiptPolicy.Snapshot?
        if host.target.selectionKind == .numericRange, let value = host.target.selection,
           let range = InsertionTarget.numericSelection(value).range {
            let element = unsafeBitCast(host.target.focused, to: AXUIElement.self)
            let read = try ax.read(element, kAXValueAttribute, until: deadline)
            if read.status == .success, let text = read.value as? String,
               text.utf16.count <= InsertionReceiptPolicy.maximumObservableUTF16Count {
                let candidate = InsertionReceiptPolicy.Snapshot(text: text, selection: range)
                if InsertionReceiptPolicy.isValid(candidate) { snapshot = candidate }
            }
        }
        guard mayObserve(), case .editor(let current) = observe(until: deadline), host.matches(current) else {
            throw RecoveryAX.Failure.unavailable
        }
        return snapshot
    }

    func acquire(diagnostics: InputDiagnosticTrace?, stopReason: () -> String?)
        async -> (host: Host?, reason: String) {
        var result = defaultFailureReason
        var attempts = 0
        defer {
            diagnostics?.record(.retry, stage: .result, [
                .retryIndex: .integer(attempts), .reason: .reason(result),
                .deadlineExceeded: .flag(ax.now() >= deadline)
            ])
        }
        for index in 1...2 {
            let slot = rejectedAt + Double(index) * 0.030
            if let stop = stopReason() { result = stop; break }
            let now = ax.now()
            // A missed second slot is never replayed after a delayed first observation.
            if index == 2 && now >= slot { break }
            let delay = slot - now
            do { if delay > 0 { try await ax.sleep(delay) } }
            catch { result = "delivery_cancelled_before_post"; break }
            if let stop = stopReason() { result = stop; break }
            guard ax.now() < deadline else { result = "recovery_deadline_expired"; break }
            attempts = index
            switch observe(until: deadline, index: index, diagnostics: diagnostics) {
            case .button: continue
            case .editor(let host):
                guard ax.now() < deadline else { result = "recovery_deadline_expired"; return (nil, result) }
                result = "ok"
                return (host, result)
            case .rejected:
                result = ax.now() >= deadline ? "recovery_deadline_expired" : "recovery_host_changed"
                return (nil, result)
            }
        }
        if ax.now() >= deadline { result = "recovery_deadline_expired" }
        return (nil, result)
    }
}
#endif
