#if os(macOS)
import ApplicationServices
import Foundation
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct Build73DeliveryTests {
    fileprivate typealias Read = InsertionTarget.AttributeRead

    /// Real CF identities and CF ranges, with an in-memory AX tree and no CGEvent posting.
    @MainActor fileprivate final class Fixture {
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
        var value = Read(value: nil, status: .attributeUnsupported)
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
            case kAXValueAttribute: return value
            default: Issue.record("unexpected AX attribute"); return Read(value: nil, status: .failure)
            }
        }

        func transport(systemFocus: Bool = false) -> TextInsertion.Transport {
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
                if self.posts == 0 { #expect(Double(duration) <= 0.100 - self.now) }
                return self.timeoutOK ? .success : .failure
            }
            t.ax.restoreSystemTimeout = { .success }
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
                let rejection = DeliveryRejection(target: target, gate: gate, rejectedAt: self.now,
                                                  ownerPID: self.owner ?? 0, systemFocus: systemFocus)
                if let reason = gate.rejection(hasTextSelection: name != nil, diagnostics: trace, stage: .preflight,
                                               began: nil, retryCandidate: rejection.eligible) {
                    return .rejected(rejection, reason)
                }
                return .accepted(target)
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
            await TextInsertion.deliver(text, to: nil, diagnostics: trace,
                livePriorBlock: { _ in self.blocked }, transport: transport(), shouldContinue: { self.allowed })
        }
    }

    @Test func externalTextRequiresAffirmativeSecurityAttributes() throws {
        let f = Fixture()
        f.recover()
        let text = "fixture selection"
        f.value = Read(value: text as CFString, status: .success)
        let normal = Read(value: "AXTextField" as CFString, status: .success)
        let standard = Read(value: "AXStandard" as CFString, status: .success)
        let secure = Read(value: "AXSecureTextField" as CFString, status: .success)
        let timeout = Read(value: nil, status: .cannotComplete)
        let wrongType = Read(value: NSNumber(value: 1), status: .success)
        let absent = Read(value: nil, status: .attributeUnsupported)
        let target = InsertionTarget(bundleIdentifier: f.bundle, localizedName: nil, pid: f.pid,
            focused: f.field, window: f.window, selectionAttribute: kAXSelectedTextRangeAttribute,
            selection: f.selection.value, textSnapshot: .init(text: "cached private body",
                selection: .init(location: 0, length: 0)), capturedAt: 0, blockedReason: nil)
        for (role, subrole, allowed) in [(secure, standard, false), (normal, secure, false),
            (normal, timeout, false), (normal, wrongType, false), (timeout, standard, false),
            (wrongType, standard, false), (normal, absent, false), (normal, standard, true)] {
            var contentReads = 0
            var reads = InsertionTarget.FocusReads()
            reads.attribute = { _, name, _, _, _, _, _ in
                switch name as String {
                case kAXRoleAttribute: return role
                case kAXSubroleAttribute: return subrole
                case kAXSelectedTextAttribute, kAXValueAttribute:
                    contentReads += 1
                    return f.value
                default: return f.attribute(name as String)
                }
            }
            let selection = InsertionTarget.captureExternalSelection(captureTarget: { _ in target }, reads: reads)?.1
            #expect(selection == (allowed ? text : nil))
            let context = ContextCapture.capture(target: target, app: false, selection: true,
                                                surrounding: true, reads: reads)
            #expect(context?.selectedText == (allowed ? text : nil))
            #expect(context?.surroundingText == (allowed ? text : nil))
            #expect((context?.prompt != nil) == allowed)
            let surroundingOnly = ContextCapture.capture(target: target, app: false, selection: false,
                                                         surrounding: true, reads: reads)
            #expect(surroundingOnly?.surroundingText == (allowed ? text : nil))
            #expect(contentReads == (allowed ? 4 : 0))

            if allowed || subrole.status == .attributeUnsupported {
                #expect(target.selectedContextText(externalText: nil, reads: reads) == text)
                #expect(target.observedSnapshot(timeout: 0.04, reads: reads)?.snapshot.text == text)
            }
        }

        // The context selection succeeds, then the body security probe times out.
        // The earlier selection must not escape in a partially populated prompt.
        var subroleQueries = 0
        var reads = InsertionTarget.FocusReads()
        reads.attribute = { _, name, _, _, _, _, _ in
            switch name as String {
            case kAXRoleAttribute: return normal
            case kAXSubroleAttribute:
                subroleQueries += 1
                return subroleQueries == 1 ? standard : timeout
            case kAXSelectedTextAttribute: return f.value
            default: return f.attribute(name as String)
            }
        }
        #expect(ContextCapture.capture(target: target, app: true, selection: true,
                                       surrounding: true, reads: reads) == nil)

        let refused = InsertionTarget.captureExternalSelection(captureTarget: { access in
            _ = target.observedSnapshot(timeout: 0.04, externalText: access, reads: reads)
            subroleQueries = 0
            return target
        }, reads: reads)
        #expect(refused == nil)
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

    @Test func parentMarkerProvidesNoAuthorityAndHistoryRechecksPendingWork() async {
        let button = Fixture()
        var transport = button.transport()
        let parent = AXUIElementCreateApplication(8888)
        let retainedMarker = button.liveMarker()
        var ancestorReads = 0
        transport.ax.attribute = { element, name in
            if name as String == kAXParentAttribute {
                ancestorReads += 1
                return Read(value: parent, status: .success)
            }
            if CFEqual(parent, element) {
                ancestorReads += 1
                return name as String == "AXSelectedTextMarkerRange" ? retainedMarker : Read(value: nil, status: .noValue)
            }
            return button.attribute(name as String)
        }
        let blocked = await DictationDelivery.send("x", to: nil, transport: transport, shouldContinue: { true })
        #expect(blocked.historyInsertionDetail.contains("current_target_not_text_input"))
        #expect(blocked.delivery == .blockedFocus && button.slots.count == 2 && button.posts == 0 && ancestorReads == 0)
        let history = Fixture()
        var pending = false
        history.onWait = { history.recover(); pending = true }
        let busy = await DictationDelivery.send("x", to: nil, transport: history.transport(), shouldContinue: { !pending })
        #expect(busy.report?.outcome == .cancelled && history.posts == 0 && history.attributes.isEmpty)
        let explicit = Fixture()
        explicit.onWait = { explicit.recover() }
        let submitted = await DictationDelivery.send("x", to: nil, transport: explicit.transport(), shouldContinue: { true })
        #expect(submitted.delivery == .attemptedUnconfirmed && explicit.posts == 1)
    }

    @Test func initialEligibilityIsNarrow() async {
        // Broadened denylisted roles across apps enter bounded recovery when all-noValue evidence holds (Fix 1a / I9b).
        for (bundle, role) in [("com.meta.endo", "AXButton"),
                               ("com.example.Editor", "AXButton"),
                               ("com.meta.endo", "AXCheckBox"),
                               ("com.google.Chrome", "AXStaticText")] {
            let f = Fixture()
            f.bundle = bundle
            f.role = role
            _ = await f.deliver()
            #expect(f.posts == 0 && f.slots.count == 2)
        }
        // Ineligible cases never enter recovery (0 posts, 0 waits).
        let ineligibleCases: [(Fixture) -> Void] = [
            { $0.currentWindow = nil },
            { $0.role = nil }, { $0.role = "AXSecureTextField" }, { $0.blocked = true },
            { $0.subrole = Read(value: "AXSecureTextField" as CFString, status: .success) },
            { $0.selection = Read(value: nil, status: .cannotComplete) },
            { $0.editable = Read(value: nil, status: .attributeUnsupported) },
            { $0.marker = Read(value: nil, status: .attributeUnsupported) },
            { $0.subrole = Read(value: nil, status: .failure) }
        ]
        for change in ineligibleCases {
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
        let delayed = Fixture()
        delayed.onWait = {
            if delayed.slots.count == 1 { delayed.now = 0.045 }
            else { delayed.recover() }
        }
        _ = await delayed.deliver()
        #expect(delayed.slots == [0.030, 0.060] && delayed.posts == 1)
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
                    if reads == 5 {
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
            #expect(reads == 5 && f.posts == 0 && f.slots.count == 1)
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
            ("snapshot_text_and_selection_changed", .preflight, { $0.before = .init(text: "y", selection: .init(location: 1, length: 0)) }),
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
            let expectedSlots: [Double] = (reason == "first_chunk_focused_window_unavailable_on_recheck"
                || reason == "first_chunk_focused_element_unavailable_on_recheck") ? [0.025] : []
            #expect(result.outcome == .focusChanged && f.posts == 0 && f.slots == expectedSlots)
            let code = try #require(InputDiagnosticEvent.Token(rawValue: reason))
            #expect(trace.buffer.entries.last?.event.fields[.reason] == .token(code))
        }
    }
    @Test func rejectionTraceAndSavedHistoryHaveOneTerminalOutcome() async throws {
        let consent = InputDiagnosticConsent(enabled: true)
        let trace = InputDiagnosticTrace(takeID: UUID(), consent: try #require(consent.token),
                                         permits: { consent.allows($0) })
        let f = Fixture()
        let result = await f.deliver(trace: trace)
        let entries = trace.buffer.entries.map(\.event)
        let attempts = entries.filter { $0.kind == .retry && $0.stage == .preflight && $0.fields[.retryIndex] != nil }
        #expect(attempts.count == 2)
        for attempt in attempts {
            #expect(attempt.fields[.roleBucket] == .roleBucket("AXButton"))
            #expect(attempt.fields[.selectedRangeState] == .token(.noValue))
            #expect(attempt.fields[.selectedMarkerState] == .token(.noValue))
            #expect(attempt.fields[.editableState] == .token(.noValue))
            #expect(attempt.fields[.element] == .flag(true) && attempt.fields[.window] == .flag(true))
            #expect(attempt.fields[.deadlineExceeded] == .flag(false))
        }
        #expect(entries.filter { $0.fields[.outcome] == .token(.blocked) }.count == 1)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let file = path.appendingPathComponent("history.json")
        var history = TranscriptHistoryStore(fileURL: file)
        let pending = history.remember("fixture", isPartial: false, delivery: .pending, engine: "test")
        let id = try #require(pending)
        DictationDelivery.classify(result).updateSavedRecord(id, in: &history)
        let entry = try #require(try RecentTranscriptArchive(fileURL: file).entries.first)
        #expect(entry.id == id && entry.delivery == .blockedFocus && entry.deliveryDetail?.contains("テキスト入力欄") == true)
    }

    @Test func normalPermissionEventAndCancellationAbortsPostNothing() async {
        for reason in ["accessibility_not_granted", "post_event_permission_missing", "event_source_unavailable",
                       "keyboard_event_unavailable", "delivery_cancelled_before_post", "empty_typing_payload"] {
            let f = Fixture()
            f.role = "AXGroup"
            var t = f.transport()
            switch reason {
            case "accessibility_not_granted": t.permissions = { (false, true) }
            case "post_event_permission_missing": t.permissions = { (true, false) }
            case "event_source_unavailable": t.source = { nil }
            case "keyboard_event_unavailable": t.events = { _, _ in nil }
            case "delivery_cancelled_before_post": f.onCheck = { _ in f.allowed = false }
            default: break
            }
            let result = await TextInsertion.deliver(reason == "empty_typing_payload" ? "" : "x", to: nil,
                                                      transport: t, shouldContinue: { f.allowed })
            #expect(result.reason == reason && f.posts == 0 && f.captures == 1 && f.slots.isEmpty)
        }
    }

    @Test func numericCommandRequiresTwoMatchingBaselinesAndCommitsOnce() async {
        for changed in [false, true] {
            let f = Fixture()
            var values = 0
            f.onWait = { f.recover() }
            f.onRead = { name in
                if name == kAXValueAttribute {
                    values += 1
                    f.value = Read(value: (changed && values == 2 ? "b" : "a") as CFString, status: .success)
                }
            }
            // End receipt polling after the one posted chunk; no real AX is consulted.
            f.onPost = { f.allowed = false }
            let result = await TextInsertion.deliverCommandText(.newline, to: nil, transport: f.transport()) { f.allowed }
            #expect(values == 2 && f.posts == (changed ? 0 : 1))
            #expect(result.outcome == (changed ? .focusChanged : .inserted))
            #expect(result.receipt == nil)
        }
    }

    @Test func boundedValueObservationAndTypedSelections() throws {
        let f = Fixture()
        f.recover()
        let target = try #require(f.transport().capture(nil).resolution.target)
        for persistent in [false, true] {
            var attempts = 0
            var reads = InsertionTarget.FocusReads()
            reads.attribute = { _, name, _, _, _, _, _ in
                if name as String == kAXValueAttribute {
                    attempts += 1
                    return persistent || attempts == 1 ? Read(value: nil, status: .cannotComplete)
                        : Read(value: "a" as CFString, status: .success)
                }
                return f.attribute(name as String)
            }
            let (snapshot, reason) = target.deliveryBaseline(diagnostics: nil, reads: reads)
            #expect(attempts == 2)
            #expect(snapshot?.text == (persistent ? nil : "a"))
            #expect(reason == (persistent ? .valueUnavailable : .snapshotAvailable))
        }
        let overflow = try #require(f.range(Int.max, 1).value)
        let valid = try #require(f.range(2, 3).value)
        let marker = try #require(f.liveMarker().value)
        #expect(InsertionTarget.decodeSelection(overflow, kind: .numericRange) == nil)
        #expect(InsertionTarget.decodeSelection(valid, kind: .numericRange) == .numeric(.init(location: 2, length: 3)))
        #expect(InsertionTarget.decodeSelection(marker, kind: .textMarker) == .marker(marker))
        #expect(InsertionTarget.decodeSelection(valid, kind: .textMarker) == nil)
        #expect(InsertionTarget.decodeSelection(marker, kind: .numericRange) == nil)
        var readCount = 0
        let result = InsertionTarget.copyAX(f.field, name: kAXValueAttribute as CFString, operation: .value,
            setTimeout: { _, _ in .failure }, read: { _, _, _ in readCount += 1; return .success },
            diagnostics: nil, stage: .preflight)
        #expect(result.value == nil && result.status != .success && readCount == 0)
        var failedSetup = InsertionTarget.FocusReads()
        failedSetup.attribute = { element, name, operation, scope, timeout, trace, stage in
            InsertionTarget.copyAX(element, name: name, operation: operation, scope: scope, timeout: timeout,
                setTimeout: { _, _ in .failure }, read: { _, _, _ in readCount += 1; return .success },
                diagnostics: trace, stage: stage)
        }
        #expect(target.observedSnapshot(timeout: 0.04, reads: failedSetup) == nil)
        #expect(readCount == 0)
    }

    @Test func deferredSummaryIncludesEveryKindOnceWithCounts() throws {
        var queue = DictationDelivery.DeferredFeedback()
        let deliveries: [TranscriptRecord.Delivery] = [.partiallyDirect, .attemptedUnconfirmed, .blockedFocus]
        for _ in 0..<100 {
            for value in deliveries {
                let queued = queue.enqueueIfSuppressed(.init(delivery: value, detail: "", report: nil),
                                                       id: UUID(), owner: nil, recording: true)
                #expect(queued)
            }
        }
        #expect(queue.kindCount == 3)
        let next = queue.next(owner: nil, recording: false, pendingTakes: false)
        let summary = try #require(next)
        for label in ["部分送信", "受理未確認", "未送信"] { #expect(summary.2.contains("\(label) 100件")) }
        #expect(queue.kindCount == 0)
    }

    @Test func historyAndDeferredFeedbackRespectOwnership() {
        let old = UUID(), newer = UUID()
        for (delivery, title, feedback) in [
            (TranscriptRecord.Delivery.verifiedInserted, "入力先への反映を確認しました", nil as OverlayFeedback?),
            (.attemptedUnconfirmed, "受理未確認", .deferredUnconfirmed),
            (.partiallyDirect, "部分送信", .deferredPartial),
            (.blockedFocus, "未送信", .deferredUnsent)
        ] {
            var queue = DictationDelivery.DeferredFeedback()
            let detail = DictationDelivery.description(delivery, reason: "secure_text_field")
            let outcome = DictationDelivery.Outcome(delivery: delivery, detail: detail, report: nil)
            #expect(outcome.historyInsertionTitle == title)
            if delivery == .blockedFocus { #expect(outcome.detail.contains("パスワード")) }
            let suppressed = queue.enqueueIfSuppressed(outcome, id: old, owner: old, recording: false)
            #expect(!suppressed)
            for recording in [true, false] {
                #expect(queue.enqueueIfSuppressed(outcome, id: old, owner: newer, recording: recording) == (feedback != nil))
                #expect(queue.next(owner: newer, recording: true, pendingTakes: true) == nil)
                #expect(queue.next(owner: newer, recording: false, pendingTakes: false) == nil)
                #expect(queue.next(owner: nil, recording: false, pendingTakes: true) == nil)
                let next = queue.next(owner: nil, recording: false, pendingTakes: false)
                #expect(next?.1 == feedback)
                if feedback != nil { #expect(next?.0 == old) }
                #expect(queue.next(owner: nil, recording: false, pendingTakes: false) == nil)
            }
        }
        let record = TranscriptRecord(recordedAt: Date(), engine: "test", text: "fixture", isPartial: false,
                                      delivery: .blockedFocus)
        #expect(DictationDelivery.historyStart(record: record, busy: true) == .failure(.busy))
        #expect(DictationDelivery.historyStart(record: nil, busy: false) == .failure(.missing))
        #expect(DictationDelivery.historyStart(record: record, busy: false) == .success(record))
        for copied in [true, false] {
            let rescue = DictationDelivery.HeldCopy(copied: copied)
            #expect(rescue.feedback == (copied ? .heldForReview : .saved))
            #expect(rescue.diagnostic == (copied ? "copied=1" : "copied=0"))
        }
    }

    @Test func onlyWholeNonverifiedFinalResultsSurviveArchiveReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        var store = TranscriptHistoryStore(fileURL: file)
        let classifications: [(TextInsertion.Result?, TranscriptRecord.Delivery?)] = [
            (nil, .blockedFocus), (.cancelled, .blockedFocus), (.focusChanged, .blockedFocus),
            (.eventUnavailable, .insertionUnavailable), (.notPermitted, .missingPermission),
            (.eventPermissionMissing, .missingPermission), (.partiallySubmitted, .partiallyDirect),
            (.inserted, .attemptedUnconfirmed), (.verifiedInserted, nil)
        ]
        var expected = 0
        for kind in VoiceController.GeneratedOperation.allCases {
            for (result, delivery) in classifications {
                let report = result.map {
                    TextInsertion.Report(outcome: $0, reason: "ok", receipt: nil,
                        eventsPosted: [.verifiedInserted, .partiallySubmitted, .inserted].contains($0),
                        target: nil, diagnostics: nil, resultUptimeMS: 0)
                }
                kind.save("intermediate", final: false, report: report, engine: "test", in: &store)
                let final = "  final " + String(expected) + "\n"
                kind.save(final, final: true, report: report, engine: "test", in: &store)
                if let delivery {
                    expected += 1
                    let record = try #require(store.entries.first { $0.text == final && $0.kind == kind.rawValue })
                    #expect(record.delivery == delivery && !record.isPartial && record.deliveryDetail != nil)
                }
                #expect(store.entries.count == expected)
            }
        }
        #expect(try RecentTranscriptArchive(fileURL: file).entries == store.entries)
        for (result, delivery, reason, expectedToken) in [
            (TextInsertion.Result.inserted, TranscriptRecord.Delivery.attemptedUnconfirmed, "posted_receipt_timeout", true),
            (.inserted, .attemptedUnconfirmed, "posted_without_observable_edit", true),
            (.partiallySubmitted, .partiallyDirect, "posted_then_active_app_changed", true),
            (.inserted, .attemptedUnconfirmed, "PRIVATE_USER_TEXT_MUST_NEVER_APPEAR", false),
            (.verifiedInserted, .verifiedInserted, "verified_value_and_selection", false)
        ] {
            let report = TextInsertion.Report(outcome: result, reason: reason, receipt: nil,
                eventsPosted: true, target: nil, diagnostics: nil, resultUptimeMS: 0)
            let classified = DictationDelivery.classify(report)
            #expect(classified.delivery == delivery)
            if expectedToken {
                #expect(classified.historyInsertionDetail.contains("（\(reason)）"))
            } else {
                #expect(!classified.historyInsertionDetail.contains(reason))
            }
            if let pending = store.remember("detail-\(reason)", isPartial: false, delivery: .pending, engine: "test") {
                classified.updateSavedRecord(pending, in: &store)
                let saved = try #require(store.entries.first { $0.id == pending })
                #expect(saved.deliveryDetail == classified.historyInsertionDetail)
                #expect(!((saved.deliveryDetail ?? "").contains("PRIVATE_USER_TEXT")))
            }
        }
    }

    @Test(arguments: [true, false])
    func rejectedTargetRestoresTimeoutOnlyForSystemFocus(systemFocus: Bool) async {
        enum Exit: CaseIterable { case adopted, partial, rejected, expired, interrupted }
        for exit in Exit.allCases {
            let f = Fixture()
            var t = f.transport(systemFocus: systemFocus)
            let system = AXUIElementCreateSystemWide()
            var reads = 0
            var systemReads = 0
            var readsAtRestore: [Int] = []
            t.ax.restoreSystemTimeout = {
                readsAtRestore.append(reads)
                return .cannotComplete
            }
            t.ax.attribute = { element, name in
                reads += 1
                if name as String == kAXFocusedUIElementAttribute {
                    if CFEqual(element, system) {
                        systemReads += 1
                    } else if systemFocus {
                        return Read(value: nil, status: .noValue)
                    }
                    if exit == .expired { f.now = 0.100 }
                }
                return f.attribute(name as String)
            }
            if exit == .interrupted {
                let sleep = t.ax.sleep
                t.ax.sleep = { delay in
                    if !f.slots.isEmpty { throw CancellationError() }
                    try await sleep(delay)
                }
            } else {
                f.onWait = {
                    f.recover()
                    if exit == .rejected { f.currentField = f.other }
                }
            }
            if exit == .partial { f.onPost = { f.currentField = f.other } }
            f.onCheck = { stage in
                if stage == .receipt { #expect(readsAtRestore == (systemFocus ? [reads] : [])) }
            }
            let result = await TextInsertion.deliver(String(repeating: "a", count: 29), to: nil, transport: t)
            #expect((systemReads > 0) == systemFocus)
            #expect(readsAtRestore == (systemFocus ? [reads] : []))
            switch exit {
            case .adopted:
                #expect(result.outcome == .inserted && f.posts == 2 && f.checkpoints.contains(.receipt))
            case .partial:
                #expect(result.outcome == .partiallySubmitted && result.reason == "recovery_host_changed" && f.posts == 1)
            case .rejected:
                #expect(result.reason == "recovery_host_changed" && f.posts == 0)
            case .expired:
                #expect(result.reason == "recovery_deadline_expired" && f.posts == 0)
            case .interrupted:
                #expect(result.reason == "delivery_cancelled_before_post" && f.posts == 0)
            }
        }
    }

    @Test func unavailableRecoveryRestoresSystemTimeoutOnceAfterItsFinalRead() async {
        enum Exit: CaseIterable { case adopted, rejected, expired, interrupted }
        for exit in Exit.allCases {
            let f = Fixture()
            f.recover()
            var t = f.transport()
            t.capture = { _ in
                .unavailable(.focusedTextElementUnavailable, pid: f.pid, focused: nil, ownerStatus: nil)
            }
            let system = AXUIElementCreateSystemWide()
            var reads = 0
            var systemReads = 0
            var readsAtRestore: [Int] = []
            t.ax.restoreSystemTimeout = {
                readsAtRestore.append(reads)
                return .cannotComplete
            }
            t.ax.attribute = { element, name in
                reads += 1
                if name as String == kAXFocusedUIElementAttribute {
                    if CFEqual(element, system) {
                        systemReads += 1
                        if exit == .expired { f.now = 0.100 }
                        if f.slots.count == 2 { return Read(value: f.field, status: .success) }
                    }
                    return Read(value: nil, status: .noValue)
                }
                return f.attribute(name as String)
            }
            if exit == .rejected { f.owner = 99999 }
            if exit == .interrupted {
                let sleep = t.ax.sleep
                t.ax.sleep = { delay in
                    if !f.slots.isEmpty { throw CancellationError() }
                    try await sleep(delay)
                }
            }
            f.onCheck = { stage in
                if stage == .receipt { #expect(readsAtRestore == [reads]) }
            }
            let result = await TextInsertion.deliver("x", to: nil, transport: t)
            #expect(systemReads > 0)
            #expect(readsAtRestore == [reads])
            switch exit {
            case .adopted:
                #expect(result.outcome == .inserted && f.posts == 1)
            case .rejected:
                #expect(result.reason == "recovery_host_changed" && f.posts == 0)
            case .expired:
                #expect(result.reason == "recovery_deadline_expired" && f.posts == 0)
            case .interrupted:
                #expect(result.reason == "delivery_cancelled_before_post" && f.posts == 0)
            }
        }
    }

    @Test func unavailableInitialFocusRecoversSameWindowPositiveEditorAndRejectsLackOfEvidenceOrWindowChange() async {
        // 1. Positive case: initial capture returns .unavailable(.focusedTextElementUnavailable),
        // then slot 1 (+30ms) exposes a positive editor element in the same window (AXTextArea with numeric selection
        // or AXGroup with AXEditable == true and marker selection).
        for useEditableGroup in [false, true] {
            let f = Fixture()
            f.bundle = "com.google.Chrome"
            f.currentField = nil
            var t = f.transport()
            t.capture = { _ in
                f.captures += 1
                return .unavailable(.focusedTextElementUnavailable, pid: f.pid, focused: nil, ownerStatus: nil)
            }
            f.onWait = {
                f.currentField = f.field
                if useEditableGroup {
                    f.role = "AXGroup"
                    f.editable = Read(value: kCFBooleanTrue, status: .success)
                    f.marker = f.liveMarker()
                } else {
                    f.role = "AXTextArea"
                    f.selection = f.range(0, 0)
                }
            }
            let sent = await TextInsertion.deliver("x", to: nil, transport: t) { f.allowed }
            #expect(sent.outcome == .inserted && f.posts == 1 && f.slots == [0.030])
        }

        // 2. Slot 1 still unavailable (nil), slot 2 (+60ms) exposes positive editor in the same window -> recovers.
        let slot2 = Fixture()
        slot2.bundle = "com.google.Chrome"
        slot2.currentField = nil
        var t2 = slot2.transport()
        t2.capture = { _ in
            slot2.captures += 1
            return .unavailable(.focusedTextElementUnavailable, pid: slot2.pid, focused: nil, ownerStatus: nil)
        }
        slot2.onWait = {
            if slot2.slots.count == 2 {
                slot2.currentField = slot2.field
                slot2.role = "AXTextField"
                slot2.selection = slot2.range(0, 0)
            }
        }
        let sent2 = await TextInsertion.deliver("x", to: nil, transport: t2) { slot2.allowed }
        #expect(sent2.outcome == .inserted && slot2.posts == 1 && slot2.slots == [0.030, 0.060])

        // 3. Both slots remain unavailable -> fails closed with target_unavailable_at_delivery (0 posts).
        let unrecovered = Fixture()
        unrecovered.bundle = "com.google.Chrome"
        unrecovered.currentField = nil
        var tUnrec = unrecovered.transport()
        tUnrec.capture = { _ in
            unrecovered.captures += 1
            return .unavailable(.focusedTextElementUnavailable, pid: unrecovered.pid, focused: nil, ownerStatus: nil)
        }
        let blockedUnrec = await TextInsertion.deliver("x", to: nil, transport: tUnrec) { unrecovered.allowed }
        #expect(blockedUnrec.outcome == .focusChanged && blockedUnrec.reason == "target_unavailable_at_delivery")
        #expect(unrecovered.posts == 0 && unrecovered.slots == [0.030, 0.060])

        // 4. Condition 2 (i): Different-window or different-app element is NEVER adopted (0 posts).
        let crossHostCases: [(Fixture) -> Void] = [
            { $0.front += 1 },                     // frontmost app changed
            { $0.owner = 99999 },                  // element owned by different process
            { $0.currentWindow = $0.other },       // app focused window changed
            { $0.elementWindow = $0.other }        // element's kAXWindowAttribute is a different window
        ]
        for mutate in crossHostCases {
            let f = Fixture()
            f.bundle = "com.google.Chrome"
            f.currentField = nil
            var t = f.transport()
            t.capture = { _ in
                f.captures += 1
                return .unavailable(.focusedTextElementUnavailable, pid: f.pid, focused: nil, ownerStatus: nil)
            }
            f.onWait = {
                f.currentField = f.field
                f.role = "AXTextArea"
                f.selection = f.range(0, 0)
                mutate(f)
            }
            let result = await TextInsertion.deliver("x", to: nil, transport: t) { f.allowed }
            #expect(result.outcome == .focusChanged && f.posts == 0 && f.slots.count == 1)
        }

        // 5. Condition 2 (ii): Same-window element WITHOUT positive editor evidence is NEVER adopted (0 posts).
        let noEvidenceCases: [(Fixture) -> Void] = [
            // Non-text control role without selection/editable
            { $0.role = "AXButton"; $0.selection = Read(value: nil, status: .noValue) },
            // Non-text control role even with selection
            { $0.role = "AXButton"; $0.selection = $0.range(0, 0) },
            // Generic container role (AXGroup) with no selection and no AXEditable == true
            { $0.role = "AXGroup"; $0.selection = Read(value: nil, status: .noValue); $0.editable = Read(value: nil, status: .noValue) },
            // Generic container role (AXGroup) with selection but AXEditable != true
            { $0.role = "AXGroup"; $0.selection = $0.range(0, 0); $0.editable = Read(value: kCFBooleanFalse, status: .success) },
            // Positive text role (AXTextArea) but lacking both numeric and marker selection
            { $0.role = "AXTextArea"; $0.selection = Read(value: nil, status: .noValue); $0.marker = Read(value: nil, status: .noValue) },
            // Secure text field role or subrole
            { $0.role = "AXSecureTextField"; $0.selection = $0.range(0, 0) },
            { $0.role = "AXTextField"; $0.subrole = Read(value: "AXSecureTextField" as CFString, status: .success); $0.selection = $0.range(0, 0) }
        ]
        for configure in noEvidenceCases {
            let f = Fixture()
            f.bundle = "com.google.Chrome"
            f.currentField = nil
            var t = f.transport()
            t.capture = { _ in
                f.captures += 1
                return .unavailable(.focusedTextElementUnavailable, pid: f.pid, focused: nil, ownerStatus: nil)
            }
            f.onWait = {
                f.currentField = f.field
                configure(f)
            }
            let result = await TextInsertion.deliver("x", to: nil, transport: t) { f.allowed }
            #expect(result.outcome == .focusChanged && f.posts == 0 && f.slots.count == 1)
        }
    }

    @Test func transientFocusUnavailabilityRecoversOnSingle25msRecheckAndFailsClosedOtherwise() async {
        // 1. Preflight transient unavailability recovers on single 25 ms recheck.
        do {
            let f = Fixture()
            f.role = "AXTextField"
            f.selection = f.range(0, 0)
            var checks = 0
            f.onCheck = { stage in
                if stage == .preflight {
                    checks += 1
                    f.currentField = checks == 1 ? nil : f.field
                }
            }
            let result = await f.deliver()
            #expect(checks == 2 && f.posts == 1 && f.slots == [0.025])
            #expect(result.outcome == .inserted)
        }

        // 2. Persistent preflight unavailability fails closed after the single 25 ms recheck.
        do {
            let f = Fixture()
            f.role = "AXTextField"
            f.selection = f.range(0, 0)
            f.onCheck = { stage in
                if stage == .preflight { f.currentField = nil }
            }
            let result = await f.deliver()
            #expect(result.outcome == .focusChanged && result.reason == "focused_element_unavailable_on_recheck")
            #expect(f.posts == 0 && f.slots == [0.025])
        }

        // 3. Genuine mismatch (focused_field_changed) fails closed immediately without a 25 ms recheck.
        do {
            let f = Fixture()
            f.role = "AXTextField"
            f.selection = f.range(0, 0)
            f.onCheck = { stage in
                if stage == .preflight { f.currentField = f.other }
            }
            let result = await f.deliver()
            #expect(result.outcome == .focusChanged && result.reason == "focused_field_changed")
            #expect(f.posts == 0 && f.slots.isEmpty)
        }
    }

    @Test func denylistedRolesRecoverInEndoAndChromeAndFailClosedWhenPersistingOrSecure() async {
        // 1 & 2. AXStaticText with all-noValue evidence in com.meta.endo and com.google.Chrome
        //        transitioning to AXTextArea with a valid numeric selection at slot 1 or slot 2 -> delivers once.
        for bundle in ["com.meta.endo", "com.google.Chrome"] {
            for recoverSlot in [1, 2] {
                let f = Fixture()
                f.bundle = bundle
                f.role = "AXStaticText"
                f.onWait = {
                    if f.slots.count == recoverSlot {
                        f.recover("AXTextArea")
                    }
                }
                let result = await f.deliver()
                #expect(result.outcome == .inserted && f.posts == 1 && f.slots.count == recoverSlot)
            }
        }

        // 3. AXStaticText persisting across all slots -> 0 posts, reason current_target_not_text_input.
        for bundle in ["com.meta.endo", "com.google.Chrome"] {
            let f = Fixture()
            f.bundle = bundle
            f.role = "AXStaticText"
            let result = await f.deliver()
            #expect(result.outcome == .focusChanged && result.reason == "current_target_not_text_input")
            #expect(f.posts == 0 && f.slots == [0.030, 0.060])
        }

        // 4. AXButton persisting -> unchanged behaviour (0 posts, reason current_target_not_text_input, 2 slots).
        do {
            let f = Fixture()
            f.bundle = "com.meta.endo"
            f.role = "AXButton"
            let result = await f.deliver()
            #expect(result.outcome == .focusChanged && result.reason == "current_target_not_text_input")
            #expect(f.posts == 0 && f.slots == [0.030, 0.060])
        }

        // 5. Secure field / unreadable subrole with a denylisted role -> never enters recovery (0 retries / 0 slots).
        let ineligibleCases: [(Fixture) -> Void] = [
            { $0.role = "AXStaticText"; $0.subrole = Read(value: "AXSecureTextField" as CFString, status: .success) },
            { $0.role = "AXButton"; $0.subrole = Read(value: "AXSecureTextField" as CFString, status: .success) },
            { $0.role = "AXStaticText"; $0.subrole = Read(value: nil, status: .failure) },
            { $0.role = "AXStaticText"; $0.subrole = Read(value: nil, status: .cannotComplete) }
        ]
        for configure in ineligibleCases {
            let f = Fixture()
            configure(f)
            let result = await f.deliver()
            #expect(result.outcome == .focusChanged && f.posts == 0 && f.slots.isEmpty)
        }
    }

    @Test func reviewerProbesI1aI1bI6aI6bI7aI7bI7cI8() async throws {
        // I1a: Unavailable-recovery multi-chunk delivery must reject element identity swap on chunk >= 1.
        do {
            let f = Fixture()
            f.bundle = "com.google.Chrome"
            f.currentField = nil
            var t = f.transport()
            t.capture = { _ in
                f.captures += 1
                return .unavailable(.focusedTextElementUnavailable, pid: f.pid, focused: nil, ownerStatus: nil)
            }
            f.onWait = {
                f.currentField = f.field
                f.role = "AXTextArea"
                f.selection = f.range(0, 0)
            }
            f.onPost = {
                // Swap to a different element in the same window with identical role/selection before chunk 1.
                f.currentField = f.other
            }
            let outcome = await DictationDelivery.send(String(repeating: "a", count: 29), to: nil, transport: t) { f.allowed }
            let result = try #require(outcome.report)
            #expect(result.outcome == .partiallySubmitted && result.reason == "recovery_host_changed")
            #expect(f.posts == 1)
            // I8: Partial submission with recovery_host_changed must preserve partial delivery detail.
            #expect(outcome.historyInsertionDetail.contains("入力が途中で中断しました"))
            #expect(outcome.historyInsertionDetail.contains("（recovery_host_changed）"))
        }

        // I8: Partial submission with recovery_deadline_expired must also preserve partial delivery detail.
        do {
            let partialDeadline = TextInsertion.Report(
                outcome: .partiallySubmitted, reason: "recovery_deadline_expired",
                receipt: nil, eventsPosted: true, target: nil, diagnostics: nil, resultUptimeMS: 1_000)
            let outcome = DictationDelivery.Outcome(
                delivery: .partiallyDirect,
                detail: DictationDelivery.description(.partiallyDirect, reason: "recovery_deadline_expired"),
                report: partialDeadline)
            #expect(outcome.historyInsertionDetail.contains("入力が途中で中断しました"))
            #expect(outcome.historyInsertionDetail.contains("（recovery_deadline_expired）"))
        }

        // I1b: Pre-send unavailable-recovery must bind to takeStart's window when takeStart?.window != nil.
        do {
            let f = Fixture()
            f.bundle = "com.google.Chrome"
            let startWindow = AXUIElementCreateApplication(77777)
            let takeStart = InsertionTarget(bundleIdentifier: f.bundle, localizedName: "Chrome",
                                            pid: f.pid, focused: f.field, window: startWindow,
                                            selectionAttribute: kAXSelectedTextRangeAttribute,
                                            selection: f.range(0, 0).value, textSnapshot: nil,
                                            capturedAt: 0, blockedReason: nil)
            f.currentField = nil
            var t = f.transport()
            t.capture = { _ in
                f.captures += 1
                return .unavailable(.focusedTextElementUnavailable, pid: f.pid, focused: nil, ownerStatus: nil)
            }
            f.onWait = {
                // App's current focused window is f.window (different from takeStart.window = startWindow).
                f.currentField = f.field
                f.role = "AXTextArea"
                f.selection = f.range(0, 0)
            }
            let rejected = await TextInsertion.deliver("x", to: takeStart, transport: t) { f.allowed }
            #expect(rejected.outcome == .focusChanged && f.posts == 0 && f.slots.count == 1)

            // When currentWindow and elementWindow match takeStart.window, recovery succeeds.
            let fSame = Fixture()
            fSame.bundle = "com.google.Chrome"
            fSame.currentWindow = startWindow
            fSame.elementWindow = startWindow
            fSame.currentField = nil
            var tSame = fSame.transport()
            tSame.capture = { _ in
                fSame.captures += 1
                return .unavailable(.focusedTextElementUnavailable, pid: fSame.pid, focused: nil, ownerStatus: nil)
            }
            fSame.onWait = {
                fSame.currentField = fSame.field
                fSame.role = "AXTextArea"
                fSame.selection = fSame.range(0, 0)
            }
            let accepted = await TextInsertion.deliver("x", to: takeStart, transport: tSame) { fSame.allowed }
            #expect(accepted.outcome == .inserted && fSame.posts == 1 && fSame.slots.count == 1)
        }

        // I6a + Nit: Endo AXButton / AXStaticText recovering on the same element to AXGroup with marker selection.
        for initialRole in ["AXButton", "AXStaticText"] {
            let f = Fixture()
            f.bundle = "com.meta.endo"
            f.role = initialRole
            f.onWait = {
                f.role = "AXGroup"
                f.marker = f.liveMarker()
                f.editable = Read(value: nil, status: .noValue)
            }
            let result = await f.deliver()
            #expect(result.outcome == .inserted && f.posts == 1 && f.slots.count == 1)
        }

        // I7a: Pre-chunk-1 (.posting index == 0) transient unavailability recovers after a single 25 ms recheck.
        do {
            let f = Fixture()
            f.role = "AXTextField"
            f.selection = f.range(0, 0)
            var postingChecks = 0
            f.onCheck = { stage in
                if stage == .posting {
                    postingChecks += 1
                    f.currentField = postingChecks == 1 ? nil : f.field
                }
            }
            let result = await f.deliver("x")
            #expect(result.outcome == .inserted && postingChecks == 2 && f.posts == 1 && f.slots == [0.025])
        }

        // I7b: Receipt-stage transient unavailability does not consume a 25 ms sleep in the receipt path.
        do {
            let f = Fixture()
            f.role = "AXTextField"
            f.marker = f.liveMarker()
            var receiptChecks = 0
            f.onCheck = { stage in
                if stage == .receipt {
                    receiptChecks += 1
                    f.currentField = nil
                }
            }
            let result = await f.deliver("b")
            #expect(result.eventsPosted && !result.postSendFocusVerified && f.posts == 1 && f.slots.isEmpty && receiptChecks == 1)
        }

        // I7c: Affirmative mismatch (e.g. focused_window_changed) dominates transient selection_unavailable_on_recheck.
        do {
            let f = Fixture()
            f.role = "AXTextField"
            f.selection = f.range(0, 0)
            f.onCheck = { stage in
                if stage == .preflight {
                    f.currentWindow = f.other
                    f.selection = Read(value: nil, status: .noValue)
                }
            }
            let result = await f.deliver("x")
            #expect(result.outcome == .focusChanged && result.reason == "focused_window_changed")
            #expect(f.posts == 0 && f.slots.isEmpty)
        }

        // I11: Unavailable-target recovery consults the system-wide AX root when app/window focus is nil,
        //      using bounded reads, and enforces same-PID / same-window / positive-editor evidence.
        do {
            func runSystemOnlyProbe(mutateOnWait: ((Fixture) -> Void)? = nil) async -> (report: TextInsertion.Report, fixture: Fixture, systemReads: Int) {
                let f = Fixture()
                f.bundle = "com.google.Chrome"
                f.currentField = nil
                var systemFocusAvailable = false
                var systemReads = 0
                let appElement = AXUIElementCreateApplication(f.pid)
                let systemElement = AXUIElementCreateSystemWide()
                var t = f.transport()
                t.capture = { _ in
                    f.captures += 1
                    return .unavailable(.focusedTextElementUnavailable, pid: f.pid, focused: nil, ownerStatus: nil)
                }
                t.ax.attribute = { element, name in
                    if name as String == kAXFocusedUIElementAttribute {
                        if CFEqual(element, systemElement) {
                            systemReads += 1
                            return Read(value: systemFocusAvailable ? f.field : nil,
                                        status: systemFocusAvailable ? .success : .noValue)
                        }
                        if CFEqual(element, appElement) || CFEqual(element, f.window) {
                            return Read(value: nil, status: .noValue)
                        }
                    }
                    return f.attribute(name as String)
                }
                f.onWait = {
                    systemFocusAvailable = true
                    f.role = "AXTextArea"
                    f.selection = f.range(0, 0)
                    mutateOnWait?(f)
                }
                let report = await TextInsertion.deliver("x", to: nil, transport: t) { f.allowed }
                return (report, f, systemReads)
            }

            // 1. Editor reachable ONLY via system-wide root with same PID/window and valid evidence -> posts once.
            let ok = await runSystemOnlyProbe()
            #expect(ok.report.outcome == .inserted && ok.fixture.posts == 1 && ok.fixture.slots == [0.030] && ok.systemReads >= 2)

            // 2. Same system-only shape with mismatched window or owner -> 0 posts.
            for mismatch in [
                { (f: Fixture) in f.owner = 99999 },
                { (f: Fixture) in f.currentWindow = f.other },
                { (f: Fixture) in f.elementWindow = f.other }
            ] {
                let bad = await runSystemOnlyProbe(mutateOnWait: mismatch)
                #expect(bad.report.outcome == .focusChanged && bad.fixture.posts == 0 && bad.fixture.slots == [0.030] && bad.systemReads >= 1)
            }
        }
    }
}
// The synthetic receiver has already applied the event when the receipt poll begins.
@MainActor private func readyReceiptPoll() async {
    await withCheckedContinuation { $0.resume() }
}

@MainActor struct Build78PostingTests {
    private typealias Fixture = Build73DeliveryTests.Fixture

    enum Producer { case translation, preset, take, voiceTransform, fixLast, command, history }

    /// Both selection producers call the same post-generation entry. Each request
    /// has its own take/selection identity, capture counter, and event receiver.
    @MainActor private final class Sender {
        let f = Fixture()
        let take = DictationTake(preferred: .local, style: .verbatim, japaneseHint: false,
                                 vocabulary: [], shouldPaste: true, options: .init())
        let start: InsertionTarget
        let ticket: UUID
        var observed = InsertionReceiptPolicy.Snapshot(text: "ab", selection: .init(location: 0, length: 1))

        init(ticket: UUID) {
            self.ticket = ticket
            f.recover()
            f.before = observed
            f.initialSnapshot = observed
            f.selection = f.range(0, 1)
            // A synthetic source capture, separate from the delivery-time recapture.
            start = f.transport().capture(nil).resolution.target!
            take.target = start
            f.captures = 0
        }

        func source(_ producer: Producer) -> TextInsertion.PostingGate.Source {
            switch producer {
            case .take: return .take(take)
            case .voiceTransform, .fixLast:
                take.transformSelection = "x"
                take.isFixLastInput = producer == .fixLast
                return .take(take)
            case .command:
                take.commandCandidate = .newline
                return .take(take)
            case .history: return .history(start, requestedAt: ticket)
            case .translation, .preset: return .selection(start)
            }
        }

        func transport() -> TextInsertion.Transport {
            var t = f.transport()
            t.waitForReceiptPoll = readyReceiptPoll
            var prepared = ""
            t.events = { part, source in
                prepared = part
                return TextInsertion.makeUnicodeEvents(part, source: source)
            }
            t.post = { _, _ in
                self.f.posts += 1
                self.observed = InsertionReceiptPolicy.expectedAfter(before: self.observed, inserted: prepared)!
                self.f.selection = self.f.range(self.observed.selection.location)
                self.f.onPost?()
            }
            let check = t.checkFocus
            t.receiptFocus = { target, _, trace, ordinal in check(target, false, trace, .receipt, ordinal) }
            t.receiptSnapshot = { _, _, _ in self.observed }
            return t
        }
    }

    @Test func valueFailureKeepsPredecessorHardBlocked() async throws {
        let gate = TextInsertion.PostingGate { _, _ in }
        let sender = Sender(ticket: try #require(gate.historyTicket))
        sender.f.initialSnapshot = nil
        var transport = sender.transport()
        transport.snapshot = { _, _ in (nil, .valueUnavailable) }
        let report = await gate.post(.dictation("B"), from: sender.source(.take), transport: transport) { true }
        #expect(report.eventsPosted && report.postSendFocusVerified)
        #expect(report.settledUnconfirmedPredecessor == nil && report.unverifiedTarget?.hasHardPredecessorBlock == true)
    }

    @Test func monotonicExpiryAndQuietTimeIgnoreWallClockSteps() async throws {
        let gate = TextInsertion.PostingGate { _, _ in }
        let sender = Sender(ticket: try #require(gate.historyTicket))
        let result = await gate.post(.dictation("B"), from: sender.source(.take), transport: sender.transport()) { true }
        let anchor = LastDeliveryAnchor(receipt: try #require(result.receipt), sourceRecordID: nil)
        let origin = anchor.deliveredAt
        var simulated = (wall: Date(), monotonic: origin)
        for jump in [3600.0, -7200.0] {
            simulated.wall.addTimeInterval(jump)
            #expect(anchor.isFresh(at: simulated.monotonic))
            #expect(!FinalizationPolicy.canFinish(endedAt: origin, lastFinalAt: origin,
                                                 endAcknowledgedAt: origin, now: simulated.monotonic))
        }
        simulated.monotonic = origin.advanced(by: .milliseconds(400))
        #expect(FinalizationPolicy.canFinish(endedAt: origin, lastFinalAt: origin,
                                            endAcknowledgedAt: origin, now: simulated.monotonic))
        #expect(anchor.isFresh(at: origin.advanced(by: .seconds(599))))
        #expect(!anchor.isFresh(at: origin.advanced(by: .seconds(600))))
    }

    @Test func historyIntentCoversWaitAndReleasesOnEveryExit() async throws {
        enum Exit: CaseIterable { case completed, refused, expired, interrupted, waitCancelled }
        for exit in Exit.allCases {
            let gate = TextInsertion.PostingGate { _, _ in }
            let ticket = try #require(gate.reserveHistory())
            let sender = Sender(ticket: ticket)
            var performed = false
            var updateStarts = 0
            func checkUpdate() {
                KoeBridgeInAppUpdater.checkForUpdatesFromMenu(isUpdateCycleActive: false, hasPendingWork: gate.hasPendingWork,
                    configured: true, explanation: "", setStatus: { _ in }, presentInformationalAlert: { _, _, _, _ in nil },
                    showUpdateInFocus: {}, showUpdatePage: {}, check: { updateStarts += 1 })
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(exit == .expired ? -1 : 5))
            await gate.performHistoryIntent(ticket, deadline: deadline, wait: {
                checkUpdate()
                #expect(updateStarts == 0 && !gate.isHeld)
                if exit == .interrupted { gate.interrupt() }
                if exit == .waitCancelled { throw CancellationError() }
            }) {
                performed = true
                if exit == .refused { return }
                sender.f.onPost = { checkUpdate(); #expect(updateStarts == 0) }
                _ = await gate.post(.dictation("B"), from: sender.source(.history), transport: sender.transport()) { true }
            }
            #expect(performed == (exit == .completed || exit == .refused))
            if exit == .interrupted {
                _ = await gate.post(.dictation("B"), from: sender.source(.history), transport: sender.transport()) { true }
            }
            #expect(sender.f.posts == (exit == .completed ? 1 : 0))
            checkUpdate()
            #expect(updateStarts == 1 && !gate.hasPendingWork)
        }
    }

    @Test func explicitHistoryPinsFieldWhileOrdinaryRecaptureUsesCurrentField() async throws {
        for producer in [Producer.history, .take] {
            let gate = TextInsertion.PostingGate { _, _ in }
            let sender = Sender(ticket: try #require(gate.historyTicket))
            sender.f.currentWindow = sender.f.other
            let report = await gate.post(.dictation("B"), from: sender.source(producer), transport: sender.transport()) { true }
            #expect(report.outcome == (producer == .history ? .focusChanged : .verifiedInserted))
            #expect(sender.f.posts == (producer == .history ? 0 : 1))
        }
    }

    @Test func predecessorIsReconciledUnderOwnershipAfterFinalize() async throws {
        var sequence: [String] = []
        let pending = Sender(ticket: UUID())
        var gate: TextInsertion.PostingGate!
        gate = TextInsertion.PostingGate { report, sourceID in
            #expect(gate.isHeld && gate.historyTicket == nil)
            VoiceController.reconcileDelivery(report, sourceTakeID: sourceID, into: pending.take)
            sequence.append("reconcile")
        }
        let sender = Sender(ticket: try #require(gate.historyTicket))
        sender.f.onPost = { gate.interrupt() }
        _ = await gate.post(.dictation(String(repeating: "z", count: 96)), from: sender.source(.take),
                            transport: sender.transport(), finalize: { _ in
            #expect(gate.isHeld && gate.historyTicket == nil)
            sequence.append("finalize")
        }) { true }
        #expect(sequence == ["finalize", "reconcile"] && !gate.isHeld)
        let next = await gate.post(.dictation("x"), from: pending.source(.take), transport: pending.transport()) { true }
        #expect(next.reason == "prior_input_unverified" && pending.f.posts == 0)
    }

    @Test func competingProducersPostZeroUntilReceiptAndReconciliationFinish() async {
        let pairs: [(Producer, Producer)] = [
            (.translation, .take), (.preset, .take), (.take, .translation), (.take, .preset),
            (.history, .history), (.history, .take), (.history, .translation),
            (.translation, .preset), (.preset, .translation), (.take, .history),
            (.voiceTransform, .translation), (.fixLast, .preset), (.command, .translation),
            (.translation, .voiceTransform), (.preset, .fixLast), (.preset, .command)
        ]
        for (first, second) in pairs {
            // Exercise each suspension boundary without depending on scheduler timing.
            for phase in [InputDiagnosticEvent.Stage.preflight, .posting, .receipt] {
                // A voice command is exactly one event pair, so its last boundary is its receipt.
                if first == .command && phase == .posting { continue }
                let gate = TextInsertion.PostingGate(reconcile: { _, _ in })
                let holder = Sender(ticket: gate.historyTicket!)
                let contender = Sender(ticket: gate.historyTicket!)
                var attempts = 0
                var finalized = 0
                func compete() async {
                    attempts += 1
                    #expect(gate.isHeld && gate.historyTicket == nil)
                    let secondReport = await gate.post(second == .command ? .command(.newline) : .dictation("B"), from: contender.source(second),
                        transport: contender.transport(), finalize: { _ in Issue.record("busy request reconciled") }) { true }
                    #expect(secondReport.reason == "posting_busy" && !secondReport.eventsPosted && secondReport.receipt == nil)
                    #expect(contender.f.posts == 0 && contender.f.captures == 0)
                    #expect(!gate.withSelectionWrite { Issue.record("busy fix changed AX selection") })
                }
                var t = holder.transport()
                let check = t.checkFocus
                t.checkFocus = { target, original, trace, stage, ordinal in
                    if attempts == 0 && stage == phase && (stage == .preflight || (stage == .posting && ordinal == 5)) {
                        return (false, "focused_element_unavailable_on_recheck")
                    }
                    return check(target, original, trace, stage, ordinal)
                }
                t.ax.sleep = { delay in
                    #expect(delay == 0.025)
                    await compete()
                }
                t.waitForReceiptPoll = { if phase == .receipt { await compete() } }
                let text = String(repeating: "a", count: 96)
                let payload: TextInsertion.Payload = first == .command ? .command(.newline) : .dictation(text)
                let report = await gate.post(payload, from: holder.source(first), transport: t,
                    finalize: { _ in
                        finalized += 1
                        #expect(gate.isHeld && gate.historyTicket == nil)
                        #expect(!gate.withSelectionWrite { Issue.record("released before reconciliation") })
                    }) { true }
                #expect(report.outcome == .verifiedInserted && report.receipt?.proof.inserted == (first == .command ? "\n" : text))
                #expect(attempts == 1 && finalized == 1 && holder.f.posts == (first == .command ? 1 : 6) && holder.f.captures == 1)
                let wrote = gate.withSelectionWrite { #expect(gate.isHeld) }
                #expect(wrote)
                let third = Sender(ticket: gate.historyTicket!)
                let next = await gate.post(.dictation("C"), from: third.source(.history),
                                           transport: third.transport(), finalize: { _ in }) { true }
                #expect(next.outcome == .verifiedInserted && third.f.posts == 1)
            }
        }
    }

    @Test func cancelledOrPartialOwnerFinalizesBeforeReleaseAndNeverResends() async {
        enum Stop: CaseIterable { case partialFocus, supersededSelection, cancelledTask, systemInterrupt, cancelledDuringReceipt }
        for stop in Stop.allCases {
            var pendingTake: DictationTake?
            let gate = TextInsertion.PostingGate { report, source in
                if let pendingTake { VoiceController.reconcileDelivery(report, sourceTakeID: source, into: pendingTake) }
            }
            let holder = Sender(ticket: gate.historyTicket!)
            let pending = Sender(ticket: gate.historyTicket!)
            pendingTake = pending.take
            let operation = UUID()
            var currentID = operation
            var finalized = 0
            let task = Task { @MainActor in
                var t = holder.transport()
                holder.f.onPost = {
                    guard holder.f.posts == 1 else { return }
                    switch stop {
                    case .partialFocus: holder.f.currentField = holder.f.other
                    case .supersededSelection: currentID = UUID()
                    case .cancelledTask: withUnsafeCurrentTask { $0?.cancel() }
                    case .systemInterrupt: gate.interrupt()
                    case .cancelledDuringReceipt: break
                    }
                }
                t.waitForReceiptPoll = { withUnsafeCurrentTask { $0?.cancel() } }
                let source = holder.source(stop == .supersededSelection ? .translation : .history)
                return await gate.post(.dictation(String(repeating: "z", count: 96)), from: source, transport: t,
                    finalize: { report in
                        #expect(gate.isHeld)
                        finalized += 1
                    }) { currentID == operation }
            }
            let result = await task.value
            holder.f.onPost = nil
            #expect(finalized == 1 && !gate.isHeld && result.receipt == nil)
            #expect(result.outcome == (stop == .cancelledDuringReceipt ? .inserted : .partiallySubmitted))
            #expect(holder.f.posts == (stop == .cancelledDuringReceipt ? 6 : 1))
            let blocked = await gate.post(.dictation("B"), from: pending.source(.take),
                transport: pending.transport(), finalize: { _ in }) { true }
            #expect(blocked.reason == "prior_input_unverified" && pending.f.posts == 0)
            let independent = Sender(ticket: gate.historyTicket!)
            let third = await gate.post(.dictation("C"), from: independent.source(.take),
                                         transport: independent.transport(), finalize: { _ in }) { true }
            #expect(third.outcome == .verifiedInserted && independent.f.posts == 1)
        }
    }

    @Test func anchorSurvivesBusyRejectionAndClearsOnAdmission() async throws {
        let gate = TextInsertion.PostingGate(reconcile: { _, _ in })
        let initial = Sender(ticket: try #require(gate.historyTicket))
        let recordID = UUID()
        let seed = await gate.post(.dictation("A"), from: initial.source(.take), transport: initial.transport(),
            finalize: { report in
                if let receipt = report.receipt {
                    gate.lastDeliveryAnchor = LastDeliveryAnchor(receipt: receipt, sourceRecordID: recordID)
                }
            }) { true }
        #expect(seed.outcome == .verifiedInserted)
        let prior = try #require(gate.lastDeliveryAnchor)
        let history = Sender(ticket: try #require(gate.historyTicket))
        let contender = Sender(ticket: history.ticket)
        var transport = history.transport()
        transport.waitForReceiptPoll = {
            for producer in [Producer.take, .command, .voiceTransform, .fixLast, .translation, .preset] {
                let payload: TextInsertion.Payload = producer == .command ? .command(.newline) : .dictation("B")
                let report = await gate.post(payload, from: contender.source(producer), transport: contender.transport()) { true }
                #expect(report.reason == "posting_busy" && !report.eventsPosted)
                #expect(gate.lastDeliveryAnchor?.sourceRecordID == recordID)
                #expect(gate.lastDeliveryAnchor?.deliveredAt == prior.deliveredAt)
            }
        }
        let holder = await gate.post(.dictation("H"), from: history.source(.history), transport: transport) { true }
        #expect(holder.outcome == .verifiedInserted && contender.f.captures == 0 && contender.f.posts == 0)
        #expect(gate.lastDeliveryAnchor?.sourceRecordID == recordID)

        var failing = contender.transport()
        failing.permissions = {
            #expect(gate.isHeld && gate.lastDeliveryAnchor == nil)
            return (false, false)
        }
        let admitted = await gate.post(.dictation("B"), from: contender.source(.take), transport: failing) { true }
        #expect(admitted.outcome == .notPermitted && !admitted.eventsPosted)
        #expect(contender.f.captures == 1 && contender.f.posts == 0 && gate.lastDeliveryAnchor == nil)
    }

    @Test func historyTicketDetectsCompletedDeliveryDuringPopoverDelay() async {
        let gate = TextInsertion.PostingGate(reconcile: { _, _ in })
        let delayed = Sender(ticket: gate.historyTicket!)
        let first = Sender(ticket: gate.historyTicket!)
        let report = await gate.post(.dictation("A"), from: first.source(.take),
            transport: first.transport(), finalize: { _ in }) { true }
        #expect(report.outcome == .verifiedInserted && !gate.isHeld)
        let busy = await gate.post(.dictation("B"), from: delayed.source(.history),
            transport: delayed.transport(), finalize: { _ in }) { true }
        #expect(busy.reason == "posting_busy" && delayed.f.posts == 0 && delayed.f.captures == 0)
    }
}

@MainActor struct Build78FocusTests {
    private typealias Fixture = Build73DeliveryTests.Fixture
    private typealias Read = InsertionTarget.AttributeRead
    private typealias Stage = InputDiagnosticEvent.Stage

    /// Inject below resolution. App, system and focused-window candidates all
    /// pass through the production type checks, owner lookup, and fallback rules.
    private func rootTransport(_ f: Fixture,
        configure: @escaping @MainActor (inout InsertionTarget.FocusReads, Stage, Int) -> Void = { _, _, _ in }
    ) -> TextInsertion.Transport {
        var t = f.transport()
        t.waitForReceiptPoll = readyReceiptPoll
        t.checkFocus = { target, original, trace, stage, ordinal in
            var reads = InsertionTarget.FocusReads()
            reads.frontPID = { f.front }
            reads.owner = { _, _, _ in (f.owner ?? 0, f.owner == nil ? .failure : .success) }
            reads.attribute = { _, name, _, _, _, _, _ in f.attribute(name as String) }
            configure(&reads, stage, ordinal)
            return target.focusCheck(requireOriginalSelection: original, diagnostics: trace,
                                     stage: stage, chunkOrdinal: ordinal, reads: reads)
        }
        return t
    }

    @Test func siblingWindowAndOwnerSwapsStopBeforeEveryAffectedChunk() async {
        enum Swap: String, CaseIterable {
            case sibling = "focused_field_changed", window = "focused_window_changed", owner = "focused_element_owner_changed"
        }
        for n in 2...5 {
            for index in 0..<n {
                for swap in Swap.allCases {
                    let f = Fixture()
                    f.recover("AXTextField")
                    var originalPosts = 0
                    var wrongPosts = 0
                    var t = rootTransport(f) { _, stage, ordinal in
                        guard stage == .posting, ordinal == index + 1 else { return }
                        switch swap {
                        case .sibling: f.currentField = f.other
                        case .window: f.currentWindow = f.other
                        case .owner: f.owner = 9876
                        }
                    }
                    t.post = { _, _ in
                        if CFEqual(f.currentField!, f.field), CFEqual(f.currentWindow!, f.window), f.owner == f.pid {
                            originalPosts += 1
                        } else { wrongPosts += 1 }
                    }
                    let report = await TextInsertion.deliver(String(repeating: "a", count: 16 * n), to: nil, transport: t)
                    #expect(report.reason == swap.rawValue && report.receipt == nil)
                    #expect(report.outcome == (index == 0 ? .focusChanged : .partiallySubmitted))
                    #expect(originalPosts == index && wrongPosts == 0 && f.captures == 1 && f.slots.isEmpty)
                }
            }
        }
    }

    @Test func resolutionOwnerMismatchCannotRecoverButMissingAndFailedReadsCan() async {
        enum Shape: CaseIterable { case foreignOwner, absent, failedGetPid, readError }
        let checkpoints: [(Stage, Int)] = [(.preflight, 0), (.posting, 1), (.posting, 2)]
        for (stage, ordinal) in checkpoints {
            for shape in Shape.allCases {
                let f = Fixture()
                f.recover()
                var attempts = 0
                var reasons: [String] = []
                var t = rootTransport(f) { reads, current, chunk in
                    guard current == stage, chunk == ordinal else { return }
                    attempts += 1
                    guard attempts == 1 else { return } // Original field is available on the next check.
                    let attribute = reads.attribute
                    reads.attribute = { element, name, operation, scope, timeout, trace, stage in
                        if operation == .focusedElement {
                            if scope == .application {
                                switch shape {
                                case .foreignOwner, .failedGetPid: return Read(value: f.other, status: .success)
                                case .readError: return Read(value: nil, status: .cannotComplete)
                                case .absent: break
                                }
                            }
                            return Read(value: nil, status: .noValue)
                        }
                        return attribute(element, name, operation, scope, timeout, trace, stage)
                    }
                    reads.owner = { element, _, _ in
                        guard CFEqual(element, f.other) else { return (f.pid, .success) }
                        return (9876, shape == .failedGetPid ? .failure : .success)
                    }
                }
                let check = t.checkFocus
                t.checkFocus = { target, original, trace, current, chunk in
                    let result = check(target, original, trace, current, chunk)
                    if current == stage && chunk == ordinal { reasons.append(result.reason) }
                    return result
                }
                let report = await TextInsertion.deliver(String(repeating: "a", count: 32), to: nil, transport: t)
                if stage == .posting && shape == .foreignOwner {
                    #expect(report.reason == "focused_element_owner_changed")
                    #expect(report.outcome == (ordinal == 1 ? .focusChanged : .partiallySubmitted))
                    #expect(f.posts == ordinal - 1 && attempts == 1 && f.slots.isEmpty)
                } else {
                    #expect(reasons == ["focused_element_unavailable_on_recheck", "ok"])
                    #expect(report.outcome == .inserted && f.posts == 2 && attempts == 2 && f.slots == [0.025])
                }
            }
        }
    }

    @Test func stableShapesPostAllChunksAndCompareSelectionOnlyAtTheFirst() async {
        enum Shape: CaseIterable { case numeric, marker, noWindow, noSelection, systemOnly, windowOnly }
        for shape in Shape.allCases {
            for n in (shape == .numeric ? [1, 5, 102] : [1, 5]) {
                let f = Fixture()
                f.recover()
                f.selection = f.range(4, 3) // Replace a nonempty selection on the first post.
                if shape == .noWindow { f.currentWindow = nil }
                if shape == .marker || shape == .noSelection { f.selection = Read(value: nil, status: .noValue) }
                if shape == .marker { f.marker = f.liveMarker() }
                var ordinals: [Int] = []
                var selectionReads: [Int] = []
                let t = rootTransport(f) { reads, stage, ordinal in
                    if stage == .posting { ordinals.append(ordinal) }
                    let attribute = reads.attribute
                    reads.attribute = { element, name, op, scope, timeout, trace, readStage in
                        if stage == .posting && (op == .selectedMarker || op == .selectedRange) {
                            selectionReads.append(ordinal)
                        }
                        if op == .focusedElement && ((shape == .systemOnly && scope != .system)
                            || (shape == .windowOnly && scope != .focusedWindow)) {
                            return Read(value: nil, status: .noValue)
                        }
                        return attribute(element, name, op, scope, timeout, trace, readStage)
                    }
                }
                f.onPost = {
                    if shape == .marker { f.marker = f.liveMarker(UInt8(f.posts + 5)) }
                    else if shape != .noSelection { f.selection = f.range(4 + 16 * f.posts) }
                }
                let report = await TextInsertion.deliver(String(repeating: "a", count: 16 * n), to: nil, transport: t)
                #expect(report.outcome == .inserted && f.posts == n && f.captures == 1)
                f.onPost = nil
                #expect(ordinals == Array(1...n) && selectionReads == (shape == .noSelection ? [] : [1]))
            }
        }
    }
}

// Isolate single-delivery transport fixtures from each other while exercising the production gate.
extension TextInsertion {
    /// Clipboard-free, serial delivery. Read-back is bounded and runs while a
    /// following recording may continue. No outcome ever resubmits posted keys.
    static func deliver(_ text: String, to takeStart: InsertionTarget?,
                        diagnostics: InputDiagnosticTrace? = nil,
                        unverifiedPredecessors: [InsertionTarget] = [],
                        settledUnconfirmedPredecessors: [SettledUnconfirmedPredecessor] = [],
                        livePriorBlock: (InsertionTarget) -> Bool = { _ in false },
                        capture: TargetCapture? = nil, transport: Transport = Transport(),
                        shouldContinue: @MainActor () -> Bool = { true }) async -> Report {
        await PostingGate(reconcile: { _, _ in }).submit(.dictation(text), takeStart: takeStart, diagnostics: diagnostics,
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
        await PostingGate(reconcile: { _, _ in }).submit(.command(command), takeStart: takeStart, diagnostics: diagnostics,
                             unverifiedPredecessors: unverifiedPredecessors,
                             settledUnconfirmedPredecessors: [],
                             capture: capture, transport: transport, livePriorBlock: livePriorBlock,
                             shouldContinue: shouldContinue)
    }
}

extension DictationDelivery {
    static func send(_ text: String, to target: InsertionTarget?,
                     diagnostics: InputDiagnosticTrace? = nil,
                     unverifiedPredecessors: [InsertionTarget] = [],
                     settledUnconfirmedPredecessors: [TextInsertion.SettledUnconfirmedPredecessor] = [],
                     livePriorBlock: (InsertionTarget) -> Bool = { _ in false },
                     capture: TextInsertion.TargetCapture? = nil, transport: TextInsertion.Transport = .init(),
                     shouldContinue: @MainActor () -> Bool) async -> Outcome {
        let report = await TextInsertion.deliver(text, to: target, diagnostics: diagnostics,
                                                 unverifiedPredecessors: unverifiedPredecessors,
                                                 settledUnconfirmedPredecessors: settledUnconfirmedPredecessors,
                                                 livePriorBlock: livePriorBlock,
                                                 capture: capture, transport: transport,
                                                 shouldContinue: shouldContinue)
        return classify(report)
    }
}
#endif
