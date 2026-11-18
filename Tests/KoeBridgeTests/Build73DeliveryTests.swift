#if os(macOS)
import ApplicationServices
import Foundation
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct Build73DeliveryTests {
    private typealias Read = InsertionTarget.AttributeRead

    /// Real CF identities and CF ranges, with an in-memory AX tree and no CGEvent posting.
    @MainActor private final class Fixture {
        let pid: pid_t = 12345
        let field = AXUIElementCreateApplication(12345)
        let window = AXUIElementCreateApplication(12346)
        let other = AXUIElementCreateApplication(12347)
        var now = 0.0
        var slots: [Double] = []
        var posts = 0
        var captures = 0
        var role: String? = "AXButton"
        var bundle = "com.meta.endo"
        var subrole = Read(value: nil, status: .noValue)
        var selection = Read(value: nil, status: .noValue)
        var marker = Read(value: nil, status: .noValue)
        var editable = Read(value: nil, status: .noValue)
        var front: pid_t = 12345
        var owner: pid_t? = 12345
        var currentWindow: AXUIElement?
        var currentField: AXUIElement?
        var elementWindow: AXUIElement?
        var allowed = true
        var blocked = false
        var timeoutOK = true
        var onWait: (() -> Void)?
        var onRead: ((String) -> Void)?
        var onPost: (() -> Void)?
        var initialSnapshot: InsertionReceiptPolicy.Snapshot?
        var before: InsertionReceiptPolicy.Snapshot?
        var attributes: [String] = []
        var checkpoints: [InputDiagnosticEvent.Stage] = []
        var onCheck: ((InputDiagnosticEvent.Stage) -> Void)?

        init() {
            currentWindow = window
            currentField = field
            elementWindow = window
        }

        func range(_ location: Int = 0, _ length: Int = 0) -> Read {
            var range = CFRange(location: location, length: length)
            return Read(value: AXValueCreate(.cfRange, &range), status: .success)
        }

        func recover(_ newRole: String = "AXTextField") {
            role = newRole
            selection = range()
        }

        func liveMarker(_ seed: UInt8 = 2) -> Read {
            var start = seed, end = seed + 1
            return Read(value: AXTextMarkerRangeCreateWithBytes(nil, &start, 1, &end, 1), status: .success)
        }

        func attribute(_ name: String) -> Read {
            attributes.append(name)
            onRead?(name)
            func identity(_ value: CFTypeRef?) -> Read {
                Read(value: value, status: value == nil ? .noValue : .success)
            }
            switch name {
            case kAXFocusedUIElementAttribute: return identity(currentField)
            case kAXFocusedWindowAttribute: return identity(currentWindow)
            case kAXWindowAttribute: return identity(elementWindow)
            case kAXRoleAttribute: return identity(role.map { $0 as CFString })
            case kAXSubroleAttribute: return subrole
            case kAXSelectedTextRangeAttribute: return selection
            case "AXSelectedTextMarkerRange": return marker
            case "AXEditable": return editable
            case kAXValueAttribute: return Read(value: nil, status: .attributeUnsupported)
            default: Issue.record("unexpected AX attribute"); return Read(value: nil, status: .failure)
            }
        }

        func transport() -> TextInsertion.Transport {
            var t = TextInsertion.Transport()
            t.ax.now = { self.now }
            t.ax.sleep = { delay in
                await MainActor.run {
                    self.now += delay
                    self.slots.append(self.now)
                    self.onWait?()
                }
            }
            t.ax.frontPID = { self.front }
            t.ax.setTimeout = { _, duration in
                #expect(duration > 0 && duration <= 0.080)
                return self.timeoutOK ? .success : .failure
            }
            t.ax.owner = { _ in self.owner }
            t.ax.attribute = { _, name in self.attribute(name as String) }
            t.capture = { trace in
                self.captures += 1
                let name: String? = self.selection.value != nil ? kAXSelectedTextRangeAttribute
                    : self.marker.value != nil ? "AXSelectedTextMarkerRange" : nil
                let target = InsertionTarget(bundleIdentifier: self.bundle, localizedName: nil,
                    pid: self.pid, focused: self.field, window: self.currentWindow, selectionAttribute: name,
                    selection: self.selection.value ?? self.marker.value, textSnapshot: self.initialSnapshot,
                    capturedAt: self.now, blockedReason: nil)
                let gate = InsertionTarget.DeliveryGateRead(role: self.role, subrole: self.subrole,
                    selectedRange: self.selection, selectedMarker: self.marker, editable: self.editable)
                let rejection = DeliveryRejection(target: target, gate: gate, rejectedAt: self.now)
                if let reason = gate.rejection(hasTextSelection: name != nil, diagnostics: trace, stage: .preflight,
                                               began: nil, retryCandidate: rejection.eligible) {
                    return (nil, reason, rejection)
                }
                return (target, "ok", nil)
            }
            t.permissions = { (true, true) }
            t.snapshot = { _, _ in (self.before, self.before == nil ? .selectionMissing : .snapshotAvailable) }
            t.checkFocus = { target, original, trace, stage, ordinal in
                self.checkpoints.append(stage)
                self.onCheck?(stage)
                var reads = InsertionTarget.FocusReads()
                reads.frontPID = { self.front }
                reads.focused = { _, _, _, _ in self.currentField }
                reads.owner = { _, _, _ in (self.owner ?? 0, self.owner == nil ? .failure : .success) }
                reads.attribute = { _, name, _, _, _, _, _ in self.attribute(name as String) }
                return target.focusCheck(requireOriginalSelection: original, diagnostics: trace,
                                         stage: stage, chunkOrdinal: ordinal, reads: reads)
            }
            t.post = { _, _ in self.posts += 1; self.onPost?() }
            return t
        }

        func deliver(_ text: String = "x", trace: InputDiagnosticTrace? = nil) async -> TextInsertion.Report {
            await TextInsertion.deliver(text, to: nil, diagnostics: trace, transport: transport(),
                livePriorBlock: { _ in self.blocked }, shouldContinue: { self.allowed })
        }
    }

    @Test func endoAndFirstSampleControl() async {
        let stuck = Fixture()
        let report = await stuck.deliver()
        #expect(report.reason == "current_target_not_text_input" && stuck.posts == 0)
        #expect(stuck.captures == 1 && stuck.slots == [0.030, 0.060])
        #expect(!stuck.attributes.contains("AXParent") && !stuck.attributes.contains("AXChildren"))
        for slot in [1, 2] {
            let f = Fixture()
            f.onWait = { if f.slots.count == slot { f.recover(slot == 1 ? "AXTextField" : "AXTextArea") } }
            let sent = await f.deliver()
            #expect(sent.outcome == .inserted && sent.receipt == nil && f.posts == 1)
            #expect(f.slots.count == slot && f.captures == 1)
        }
        // Representative non-denylisted role; the original trace did not record its name.
        let normal = Fixture()
        normal.role = "AXGroup"
        let control = await normal.deliver(String(repeating: "a", count: 29))
        #expect(control.outcome == .inserted && normal.posts == 2 && normal.slots.isEmpty)
        #expect(normal.captures == 1 && !normal.attributes.contains(kAXRoleAttribute))
    }

    @Test func initialEligibilityIsNarrow() async {
        let cases: [(Fixture) -> Void] = [
            { $0.bundle = "com.example.Editor" }, { $0.role = "AXCheckBox" }, { $0.currentWindow = nil },
            { $0.role = nil }, { $0.role = "AXSecureTextField" }, { $0.blocked = true },
            { $0.selection = Read(value: nil, status: .cannotComplete) },
            { $0.editable = Read(value: nil, status: .attributeUnsupported) },
            { $0.marker = Read(value: nil, status: .attributeUnsupported) },
            { $0.subrole = Read(value: nil, status: .failure) }
        ]
        for change in cases {
            let f = Fixture()
            change(f)
            _ = await f.deliver()
            #expect(f.posts == 0 && f.slots.isEmpty)
        }
    }

    @Test func recoveryRefusesInvalidOrDifferentHostsAtFirstObservation() async {
        let changes: [(Fixture) -> Void] = [
            { $0.front += 1 }, { $0.owner = nil }, { $0.owner = 9 },
            { $0.currentWindow = $0.other }, { $0.currentWindow = nil }, { $0.currentField = $0.other },
            { $0.elementWindow = $0.other }, { $0.role = nil }, { $0.role = "AXSecureTextField" },
            { $0.subrole = Read(value: "AXSecureTextField" as CFString, status: .success) },
            { $0.subrole = Read(value: kCFBooleanTrue, status: .success) },
            { $0.subrole = Read(value: nil, status: .cannotComplete) },
            { $0.selection = Read(value: nil, status: .noValue) },
            { $0.selection = $0.range(-1) }, { $0.selection = $0.range(Int.max, 1) },
            { $0.selection = Read(value: "bad" as CFString, status: .success); $0.marker = $0.liveMarker() },
            { $0.selection = Read(value: nil, status: .noValue); $0.marker = Read(value: "bad" as CFString, status: .success) },
            { $0.role = "AXButton"; $0.selection = Read(value: nil, status: .noValue); $0.marker = $0.liveMarker() },
            { $0.timeoutOK = false }
        ]
        for change in changes {
            let f = Fixture()
            f.onWait = { f.recover(); change(f) }
            let result = await f.deliver()
            #expect(result.outcome == .focusChanged && f.posts == 0 && f.slots.count == 1)
        }
    }

    @Test func deadlineAndInterruptedWait() async {
        for time in [0.09999, 0.100, 0.101] {
            let f = Fixture()
            f.onWait = { f.recover(); f.now = time }
            _ = await f.deliver()
            #expect(f.posts == (time < 0.100 ? 1 : 0))
        }
        let slow = Fixture()
        slow.onWait = { slow.recover() }
        slow.onRead = { if $0 == kAXSelectedTextRangeAttribute { slow.now = 0.101 } }
        _ = await slow.deliver()
        #expect(slow.posts == 0)
        let missed = Fixture()
        missed.onWait = { missed.now = 0.070 }
        _ = await missed.deliver()
        #expect(missed.posts == 0 && missed.slots.count == 1)
        for reason in ["prior_input_unverified", "delivery_cancelled_before_post"] {
            let f = Fixture()
            f.onWait = { f.recover(); f.blocked = reason == "prior_input_unverified"; f.allowed = f.blocked }
            let result = await f.deliver()
            #expect(result.reason == reason && f.posts == 0 && f.attributes.isEmpty)
        }
        let cancelled = Fixture()
        cancelled.onWait = { withUnsafeCurrentTask { $0?.cancel() } }
        let result = await Task { await cancelled.deliver() }.value
        #expect(result.outcome == .cancelled && cancelled.posts == 0)
    }

    @Test func commandAndCommitChecks() async {
        let markerOnly = Fixture()
        markerOnly.onWait = { markerOnly.role = "AXTextArea"; markerOnly.marker = markerOnly.liveMarker() }
        let command = await TextInsertion.deliverCommandText(.newline, to: nil, transport: markerOnly.transport()) { true }
        #expect(command.reason == "command_baseline_unavailable" && markerOnly.posts == 0)
        let markerOK = Fixture()
        markerOK.onWait = { markerOK.role = "AXTextArea"; markerOK.marker = markerOK.liveMarker() }
        _ = await markerOK.deliver()
        #expect(markerOK.posts == 1)
        for regression in ["role", "secure", "selection", "latch", "deadline", "focus"] {
            let f = Fixture()
            var reads = 0
            f.onWait = { f.recover() }
            f.onRead = { name in
                if name == kAXSelectedTextRangeAttribute {
                    reads += 1
                    if reads == 4 {
                        switch regression {
                        case "role": f.role = "AXButton"
                        case "secure": f.subrole = Read(value: "AXSecureTextField" as CFString, status: .success)
                        case "selection": f.selection = f.range(1)
                        case "latch": f.blocked = true
                        case "deadline": f.now = 0.100
                        default: f.currentField = f.other
                        }
                    }
                }
            }
            _ = await f.deliver()
            #expect(reads == 4 && f.posts == 0 && f.slots.count == 1)
        }
        for regression in ["secure", "role", "window", "selection", "movedCaret"] {
            let f = Fixture()
            f.onWait = { f.recover() }
            f.onPost = {
                switch regression {
                case "secure": f.subrole = Read(value: "AXSecureTextField" as CFString, status: .success)
                case "role": f.role = "AXButton"
                case "window": f.currentWindow = f.other
                case "selection": f.selection = Read(value: nil, status: .noValue)
                default: f.selection = f.range(1)
                }
            }
            let result = await f.deliver(String(repeating: "x", count: 17))
            #expect(result.outcome == (regression == "movedCaret" ? .inserted : .partiallySubmitted))
            #expect(f.posts == (regression == "movedCaret" ? 2 : 1) && f.slots.count == 1 && f.captures == 1)
        }
    }

    @Test func zeroPostReasonsComeFromTheFailingReads() async throws {
        typealias Stage = InputDiagnosticEvent.Stage
        let cases: [(String, Stage, (Fixture) -> Void)] = [
            ("focused_field_changed", .preflight, { $0.currentField = $0.other }),
            ("first_chunk_focused_field_changed", .posting, { $0.currentField = $0.other }),
            ("first_chunk_focused_window_changed", .posting, { $0.currentWindow = $0.other }),
            ("first_chunk_focused_element_owner_changed", .posting, { $0.owner = 99 }),
            ("first_chunk_marker_selection_changed", .posting, { $0.marker = $0.liveMarker(5) }),
            ("first_chunk_focused_window_unavailable_on_recheck", .posting, { $0.currentWindow = nil }),
            ("first_chunk_focused_element_owner_unavailable", .posting, { $0.owner = nil }),
            ("first_chunk_focused_element_unavailable_on_recheck", .posting, { $0.currentField = nil }),
            ("captured_selection_invalid", .preflight, { _ in }),
            ("field_value_unavailable_on_recheck", .preflight, { _ in }),
            ("snapshot_text_changed", .preflight, { $0.before = .init(text: "y", selection: .init(location: 0, length: 0)) }),
            ("snapshot_selection_changed", .preflight, { $0.before = .init(text: "x", selection: .init(location: 1, length: 0)) })
        ]
        for (reason, stage, change) in cases {
            let f = Fixture()
            f.role = "AXTextArea"
            if reason == "captured_selection_invalid" {
                f.selection = Read(value: "bad" as CFString, status: .success)
                f.marker = f.liveMarker()
            } else if reason.contains("snapshot") || reason.contains("field_value") {
                f.selection = f.range()
                f.initialSnapshot = .init(text: "x", selection: .init(location: 0, length: 0))
            } else { f.marker = f.liveMarker() }
            f.onCheck = { if $0 == stage { change(f) } }
            let consent = InputDiagnosticConsent(enabled: true)
            let trace = InputDiagnosticTrace(takeID: UUID(), consent: try #require(consent.token),
                                             permits: { consent.allows($0) })
            let result = await f.deliver(trace: trace)
            #expect(result.outcome == .focusChanged && f.posts == 0 && f.slots.isEmpty)
            let code = try #require(InputDiagnosticEvent.Token(rawValue: reason))
            #expect(trace.buffer.entries.last?.event.fields[.reason] == .token(code))
        }
    }
}
#endif
