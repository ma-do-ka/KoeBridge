#if os(macOS)
import AppKit
import ApplicationServices
import KoeBridgeCore

/// These references belong only to the current delivery adjudication.
@MainActor struct DeliveryRejection {
    let target: InsertionTarget
    let gate: InsertionTarget.DeliveryGateRead
    let rejectedAt: TimeInterval

    var eligible: Bool {
        target.bundleIdentifier == "com.meta.endo" && gate.role == "AXButton"
            && gate.selectedRange.status == .noValue && gate.selectedMarker?.status == .noValue
            && gate.editable.status == .noValue && gate.subrole.value as? String != "AXSecureTextField"
            && InsertionTarget.secureExclusionReadable(gate.subrole.value, status: gate.subrole.status)
            && target.window.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true
        // capture has already verified the element and its owner PID.
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
    let rejection: DeliveryRejection
    let ax: RecoveryAX
    var deadline: TimeInterval { rejection.rejectedAt + 0.100 }

    @MainActor struct Host {
        let target: InsertionTarget
        let role: String

        func matches(_ other: Host) -> Bool {
            guard role == other.role, target.selectionAttribute == other.target.selectionAttribute,
                  let a = target.selection, let b = other.target.selection else { return false }
            return CFEqual(a, b)
        }
    }

    enum Sample { case button, editor(Host), rejected }

    func observe(until limit: TimeInterval, index: Int? = nil,
                 diagnostics: InputDiagnosticTrace? = nil) -> Sample {
        let original = rejection.target
        var fields: [InputDiagnosticEvent.Field: InputDiagnosticEvent.Value] = [
            .roleBucket: .roleBucket(nil), .subroleState: .token(.skipped),
            .selectedRangeState: .token(.skipped), .selectedMarkerState: .token(.skipped),
            .editableState: .token(.skipped), .window: .token(.unknown),
            .element: .token(.unknown), .owner: .token(.unknown), .elementWindow: .token(.unknown)
        ]
        defer {
            if let index {
                fields[.retryIndex] = .integer(index)
                fields[.elapsedMS] = .integer(Int((ax.now() - rejection.rejectedAt) * 1000))
                fields[.deadlineExceeded] = .flag(ax.now() >= limit)
                diagnostics?.record(.retry, stage: .preflight, fields)
            }
        }
        let samePID = ax.frontPID() == original.pid
        fields[.frontMatches] = .flag(samePID)
        guard samePID, let window = original.window else { return .rejected }
        let app = AXUIElementCreateApplication(original.pid)
        do {
            let focus = try ax.read(app, kAXFocusedUIElementAttribute, until: limit)
            func equal(_ read: RecoveryAX.Read, _ expected: CFTypeRef) -> Bool {
                guard read.status == .success, let value = read.value,
                      CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
                return CFEqual(expected, value)
            }
            let sameElement = equal(focus, original.focused)
            fields[.element] = .flag(sameElement)
            guard sameElement else { return .rejected }
            let element = unsafeBitCast(original.focused, to: AXUIElement.self)
            try ax.configure(element, until: limit)
            let sameOwner = ax.owner(element) == original.pid
            fields[.owner] = .flag(sameOwner)
            guard sameOwner else { return .rejected }
            let sameWindow = equal(try ax.read(app, kAXFocusedWindowAttribute, until: limit), window)
            fields[.window] = .flag(sameWindow)
            guard sameWindow else { return .rejected }
            func read(_ name: String) throws -> RecoveryAX.Read {
                try ax.read(element, name, until: limit)
            }
            let roleRead = try read(kAXRoleAttribute)
            let role = roleRead.value as? String
            fields[.roleBucket] = .roleBucket(role)
            let sub = try read(kAXSubroleAttribute)
            fields[.subroleState] = .token(sub.diagnosticState(hasValue: sub.value is String))
            guard roleRead.status == .success, let role,
                  InsertionTarget.secureExclusionReadable(sub.value, status: sub.status),
                  sub.value as? String != "AXSecureTextField",
                  ["AXButton", "AXTextField", "AXTextArea"].contains(role) else { return .rejected }
            let rangeName = kAXSelectedTextRangeAttribute as String
            let markerName = "AXSelectedTextMarkerRange"
            let range = try read(rangeName)
            fields[.selectedRangeState] = .token(range.diagnosticState(hasValue: range.value != nil))
            let name: String
            let selection: CFTypeRef
            if let value = range.value {
                guard range.status == .success, role != "AXButton",
                      let decoded = InsertionTarget.numericSelection(value).range,
                      !decoded.location.addingReportingOverflow(decoded.length).overflow else {
                    return .rejected
                }
                name = rangeName
                selection = value
            } else {
                guard range.status == .noValue || range.status == .attributeUnsupported || range.status == .success
                else { return .rejected }
                let marker = try read(markerName)
                fields[.selectedMarkerState] = .token(marker.diagnosticState(hasValue: marker.value != nil))
                if role == "AXButton" {
                    guard range.status == .noValue, marker.status == .noValue else { return .rejected }
                    let editable = try read("AXEditable")
                    fields[.editableState] = .token(editable.diagnosticState(hasValue: editable.value != nil))
                    return editable.status == .noValue && ax.now() < limit ? .button : .rejected
                }
                guard marker.status == .success, let value = marker.value,
                      CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return .rejected }
                name = markerName
                selection = value
            }
            let elementWindow = equal(try read(kAXWindowAttribute), window)
            fields[.elementWindow] = .flag(elementWindow)
            guard elementWindow, ax.frontPID() == original.pid,
                  equal(try ax.read(app, kAXFocusedUIElementAttribute, until: limit), original.focused),
                  equal(try ax.read(app, kAXFocusedWindowAttribute, until: limit), window) else { return .rejected }
            try ax.configure(element, until: limit)
            guard ax.owner(element) == original.pid,
                  try read(kAXRoleAttribute).value as? String == role else { return .rejected }
            let finalSubrole = try read(kAXSubroleAttribute)
            guard InsertionTarget.secureExclusionReadable(finalSubrole.value, status: finalSubrole.status),
                  finalSubrole.value as? String != "AXSecureTextField", ax.now() < limit else { return .rejected }
            let target = InsertionTarget(bundleIdentifier: original.bundleIdentifier, localizedName: original.localizedName,
                pid: original.pid, focused: original.focused, window: window, selectionAttribute: name,
                selection: selection, textSnapshot: nil, capturedAt: ax.now(), blockedReason: nil)
            return .editor(Host(target: target, role: role))
        } catch { return .rejected }
    }

    /// Take a single value snapshot, bracketed by consistent host and selection reads.
    /// Marker ranges have no numeric baseline and can never authorize a command.
    func confirmedBaseline(_ host: Host) throws -> InsertionReceiptPolicy.Snapshot? {
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
        guard case .editor(let current) = observe(until: deadline), host.matches(current) else {
            throw RecoveryAX.Failure.unavailable
        }
        return snapshot
    }

    func acquire(diagnostics: InputDiagnosticTrace?, stopReason: () -> String?)
        async -> (host: Host?, reason: String) {
        var result = "current_target_not_text_input"
        var attempts = 0
        defer {
            diagnostics?.record(.retry, stage: .result, [
                .retryIndex: .integer(attempts), .reason: .reason(result),
                .deadlineExceeded: .flag(ax.now() >= deadline)
            ])
        }
        for index in 1...2 {
            let slot = rejection.rejectedAt + Double(index) * 0.030
            let delay = slot - ax.now()
            if let stop = stopReason() { result = stop; break }
            if index == 2 && delay <= 0 { break }
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
