#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct TextInsertionTransportTests {
    @Test func privateSourceAndKeyDownOnlyUnicode() throws {
        let source = try #require(TextInsertion.makePostingSource())
        // makePostingSource constructs the source with .privateState; event state IDs
        // are not a reliable probe, and the source accessor returns a unique private table ID.
        let (down, up) = try #require(TextInsertion.makeUnicodeEvents("日本語A", source: source))
        #expect(down.flags.isEmpty && up.flags.isEmpty)
        #expect(down.getIntegerValueField(.keyboardEventKeycode) == 0)
        #expect(up.getIntegerValueField(.keyboardEventKeycode) == 0)
        #expect(down.type == .keyDown && up.type == .keyUp)
        var downLength = 0
        var upLength = 0
        var units = [UniChar](repeating: 0, count: 64)
        units.withUnsafeMutableBufferPointer { buffer in
            down.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &downLength,
                                          unicodeString: buffer.baseAddress)
        }
        #expect(String(decoding: units.prefix(downLength), as: UTF16.self) == "日本語A")
        units.withUnsafeMutableBufferPointer { buffer in
            up.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &upLength,
                                        unicodeString: buffer.baseAddress)
        }
        // With no attached Unicode string, keyUp readback can synthesize the layout
        // character for virtualKey 0. Its length need not be zero; it must never carry the payload.
        #expect(String(decoding: units.prefix(upLength), as: UTF16.self) != "日本語A")
    }

    @Test func unconfirmedFeedbackDoesNotChangeSubmissionSemantics() {
        let verified = DictationDelivery.Outcome(delivery: .verifiedInserted, detail: "", report: nil)
        let unconfirmed = DictationDelivery.Outcome(delivery: .attemptedUnconfirmed, detail: "", report: nil)
        let blocked = DictationDelivery.Outcome(delivery: .blockedFocus, detail: "", report: nil)
        #expect(verified.submitted && unconfirmed.submitted)
        #expect(!blocked.submitted)
        #expect(verified.submissionFeedback == .sent)
        #expect(unconfirmed.submissionFeedback == .sentUnconfirmed)
        #expect(blocked.submissionFeedback == nil)
    }

    // Synthetic AX identities only. These tests never post keyboard events or
    // depend on the user's frontmost application/accessibility permissions.
    private func target(pid: pid_t = 10_001, element: CFTypeRef? = nil, window: CFTypeRef? = nil,
                        text: String = "ab", caret: Int = 1,
                        selectionAttribute: String? = kAXSelectedTextRangeAttribute as String) -> InsertionTarget {
        var range = CFRange(location: caret, length: 0)
        let numeric = selectionAttribute == kAXSelectedTextRangeAttribute as String
        let selection: CFTypeRef?
        if selectionAttribute == nil {
            selection = nil
        } else if numeric {
            selection = AXValueCreate(.cfRange, &range)
        } else {
            var start: UInt8 = 1, end: UInt8 = 2
            selection = AXTextMarkerRangeCreateWithBytes(nil, &start, 1, &end, 1)
        }
        return InsertionTarget(bundleIdentifier: "com.example.Editor", localizedName: "Editor", pid: pid,
            focused: element ?? AXUIElementCreateApplication(pid), window: window,
            selectionAttribute: selectionAttribute, selection: selection,
            textSnapshot: numeric ? .init(text: text, selection: .init(location: caret, length: 0)) : nil,
            capturedAt: 1, blockedReason: nil)
            .withReceiptFieldNature(.normal)
    }

    @Test func textSnapshotRetentionRequiresPositiveNormalFieldNature() {
        let base = target()
        #expect(base.receiptFieldNature == .normal)
        #expect(base.removingTextSnapshotUnlessNormal().textSnapshot != nil)
        for nature in [InsertionReceiptPolicy.FieldNature.unknown, .protected] {
            let stripped = base.withReceiptFieldNature(nature).removingTextSnapshotUnlessNormal()
            #expect(stripped.receiptFieldNature == nature)
            #expect(stripped.textSnapshot == nil)
        }
    }

    @Test func deliveryAcceptsEditorsWithNoNumericOrMarkerSelection() throws {
        let attributes: [String?] = [nil, kAXSelectedTextRangeAttribute as String, "AXSelectedTextMarkerRange"]
        let controls = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                     "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
                     "AXSlider", "AXIncrementor", "AXStepper", "AXSwitch",
                     "AXStaticText", "AXImage", "AXDisclosureTriangle"]
        for selectionAttribute in attributes {
            let current = target(selectionAttribute: selectionAttribute)
            // ecf0cc05 and the Build 66/67 editor shapes share the same gate:
            // neither AXEditable nor a selection is needed to accept them.
            for role in ["AXGroup", "AXWebArea", "AXTextField", "AXTextArea", "AXComboBox", "AXCustomEditor"] + controls {
                let isControl = controls.contains(role)
                if isControl && current.selection == nil { continue }
                let prepared = TextInsertion.prepareTarget(takeStart: current, capture: { _ in
                    if let reason = DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                        editable: false, hasTextSelection: current.selection != nil) {
                        return (nil, reason)
                    }
                    return (current, "ok")
                })
                #expect(prepared.reason == "ok")
                let fresh = try #require(prepared.target)
                #expect(fresh.sameElement(as: current))
                let expectedKind: InputDiagnosticEvent.Token = selectionAttribute == nil ? .none
                    : selectionAttribute == kAXSelectedTextRangeAttribute as String ? .numericRange : .textMarker
                #expect(fresh.selectionKind == expectedKind)
                if expectedKind == .numericRange {
                    #expect(fresh.selection != nil && fresh.textSnapshot != nil)
                    #expect(DeliveryPacingPolicy.profile(selectionKind: fresh.selectionKind) == .numericSelection)
                } else {
                    #expect(fresh.textSnapshot == nil)
                    #expect((fresh.selection == nil) == (expectedKind == .none))
                    let profile = DeliveryPacingPolicy.profile(selectionKind: fresh.selectionKind)
                    #expect(profile == .unobservableSelection && profile.gapNanoseconds == 20_000_000)
                    var eligibility: ReceiptEligibilityReason?
                    #expect(fresh.observedSnapshot(timeout: 0.04, eligibility: { eligibility = $0 }) == nil)
                    #expect(eligibility == (expectedKind == .none ? .selectionMissing : .markerNotNumeric))
                }
            }
        }
    }

    @Test func deliveryBlocksControlsWithoutEvidenceAndAlwaysBlocksSecureOrUnavailableTargets() {
        let attributes: [String?] = [nil, kAXSelectedTextRangeAttribute as String, "AXSelectedTextMarkerRange"]
        var cases: [(String?, String?, Bool, String)] = [
            ("AXSecureTextField", nil, true, "secure_text_field"),
            ("AXSecureTextField", nil, false, "secure_text_field"),
            ("AXTextField", "AXSecureTextField", true, "secure_text_field"),
            (nil, "AXSecureTextField", false, "secure_text_field"),
            ("AXButton", "AXSecureTextField", false, "secure_text_field"),
            (nil, nil, true, "target_unavailable_at_delivery"),
            ("AXGroup", nil, false, "target_unavailable_at_delivery"),
            ("AXButton", nil, false, "target_unavailable_at_delivery")
        ]
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                     "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
                     "AXSlider", "AXIncrementor", "AXStepper", "AXSwitch",
                     "AXStaticText", "AXImage", "AXDisclosureTriangle"] {
            cases.append((role, nil, true, "current_target_not_text_input"))
        }
        for selectionAttribute in attributes {
            let current = target(selectionAttribute: selectionAttribute)
            for (role, subrole, readable, expected) in cases {
                // Controls with live selection are accepted in v4 (tested above).
                if expected == "current_target_not_text_input" && current.selection != nil { continue }
                let prepared = TextInsertion.prepareTarget(takeStart: current, capture: { _ in
                    if let reason = DeliveryTargetPolicy.blockedReason(role: role, subrole: subrole,
                                                                       editable: false,
                                                                       hasTextSelection: current.selection != nil,
                                                                       subroleReadable: readable) {
                        return (nil, reason)
                    }
                    return (current, "ok")
                })
                #expect(prepared.target == nil && prepared.reason == expected)
            }
        }
    }

    @Test func deliveryEditableEvidenceOverridesControlsButNeverSecureOrUnavailable() throws {
        let current = target(selectionAttribute: nil)
        let cases: [(role: String?, subrole: String?, readable: Bool, expected: String)] = [
            ("AXStaticText", nil, true, "ok"),
            ("AXButton", nil, true, "ok"),
            ("AXSecureTextField", nil, true, "secure_text_field"),
            ("AXButton", "AXSecureTextField", true, "secure_text_field"),
            (nil, nil, true, "target_unavailable_at_delivery"),
            ("AXButton", nil, false, "target_unavailable_at_delivery")
        ]
        for item in cases {
            let prepared = TextInsertion.prepareTarget(takeStart: current, capture: { _ in
                if let reason = DeliveryTargetPolicy.blockedReason(role: item.role, subrole: item.subrole,
                    editable: true, hasTextSelection: false, subroleReadable: item.readable) {
                    return (nil, reason)
                }
                return (current, "ok")
            })
            #expect(prepared.reason == item.expected)
            if item.expected == "ok" {
                let fresh = try #require(prepared.target)
                #expect(fresh.sameElement(as: current))
            } else {
                #expect(prepared.target == nil)
            }
        }
    }

    @Test func currentCaretAndNewlineEditsReplaceTakeStartBaseline() throws {
        let start = target()
        for current in [target(caret: 2), target(text: "a\nb", caret: 2)] {
            var captures = 0
            let prepared = TextInsertion.prepareTarget(takeStart: start, capture: { _ in
                captures += 1
                return (current, "ok")
            })
            #expect(captures == 1 && prepared.reason == "ok")
            let fresh = try #require(prepared.target)
            #expect(fresh.textSnapshot == current.textSnapshot)
            #expect(fresh.textSnapshot != start.textSnapshot)
            let before = try #require(fresh.textSnapshot)
            let after = try #require(InsertionReceiptPolicy.expectedAfter(before: before, inserted: "語"))
            #expect(after.selection.location == current.textSnapshot!.selection.location + 1)
            #expect(after.text == (before.text == "ab" ? "ab語" : "a\n語b"))
            #expect(InsertionReceiptPolicy.verify(before: before, inserted: "語", after: after, sameTarget: true, fieldNature: .normal) != nil)
        }
    }

    @Test func currentFieldAppAndSelectionKindAreAuthoritative() throws {
        let start = target()
        let differentField = target(element: AXUIElementCreateSystemWide(), selectionAttribute: "AXSelectedTextMarkerRange")
        let differentApp = target(pid: 10_002, selectionAttribute: nil)
        for current in [differentField, differentApp] {
            let prepared = TextInsertion.prepareTarget(takeStart: start, capture: { _ in (current, "ok") })
            #expect(prepared.reason == "ok")
            let fresh = try #require(prepared.target)
            #expect(fresh.sameElement(as: current))
            #expect(!fresh.sameElement(as: start))
            #expect(DeliveryPacingPolicy.profile(selectionKind: fresh.selectionKind) == .unobservableSelection)
        }
        let noStart = TextInsertion.prepareTarget(takeStart: nil, capture: { _ in (differentApp, "ok") })
        #expect(noStart.reason == "ok" && noStart.target?.pid == differentApp.pid)
    }

    @Test func unverifiedPredecessorCannotBeBypassedByMovingToItsFreshTarget() async {
        let old = target()
        let current = target(pid: 10_002)
        let blocked = await TextInsertion.deliver("語", to: old, unverifiedPredecessors: [current],
                                                  capture: { _ in (current, "ok") })
        #expect(blocked.outcome == .focusChanged && blocked.reason == "prior_input_unverified")
        #expect(!blocked.eventsPosted && blocked.receipt == nil && blocked.unverifiedTarget == nil)
        let nilStart = TextInsertion.prepareTarget(takeStart: nil, unverifiedPredecessors: [current],
                                                   capture: { _ in (current, "ok") })
        #expect(nilStart.reason == "prior_input_unverified")
        let unrelated = TextInsertion.prepareTarget(takeStart: old, unverifiedPredecessors: [old],
                                                    capture: { _ in (current, "ok") })
        #expect(unrelated.reason == "ok")
        let sticky = TextInsertion.prepareTarget(takeStart: old.blockedByPriorInput(),
                                                 capture: { _ in (current, "ok") })
        #expect(sticky.reason == "prior_input_unverified")
    }

    // Keep telemetry in memory with isolated consent. These cases do not
    // inspect the live accessibility tree, post events, or write diagnostic files.
    private func trace(_ id: UUID = UUID()) throws -> InputDiagnosticTrace {
        let consent = InputDiagnosticConsent(enabled: true)
        return InputDiagnosticTrace(takeID: id, consent: try #require(consent.token),
                                    permits: { consent.allows($0) })
    }

    @Test func captureRejectionsRetainRawAXEvidence() throws {
        let diagnostics = try trace()
        let absent = InsertionTarget.AttributeRead(value: nil, status: .noValue)
        let unsupported = InsertionTarget.AttributeRead(value: nil, status: .attributeUnsupported)
        let timeout = InsertionTarget.AttributeRead(value: nil, status: .cannotComplete)
        let secure = InsertionTarget.AttributeRead(value: "AXSecureTextField" as CFString, status: .success)
        let editableTrue = InsertionTarget.AttributeRead(value: kCFBooleanTrue, status: .success)
        let editableFalse = InsertionTarget.AttributeRead(value: kCFBooleanFalse, status: .success)
        typealias Gate = InsertionTarget.DeliveryGateRead
        let cases: [(gate: Gate, selected: Bool, reason: String, fields: [String])] = [
            (Gate(role: "AXStaticText", subrole: absent, selectedRange: absent,
                  selectedMarker: absent, editable: absent),
             false, "current_target_not_text_input",
             ["role_bucket=AXStaticText", "subrole_state=noValue", "selected_range_state=noValue",
              "selected_marker_state=noValue", "editable_state=noValue", "denylist_hit=1"]),
            (Gate(role: "AXSecureTextField", subrole: absent, selectedRange: absent,
                  selectedMarker: unsupported, editable: editableFalse),
             false, "secure_text_field",
             ["role_bucket=AXSecureTextField", "subrole_state=noValue", "selected_range_state=noValue",
              "selected_marker_state=unsupported", "editable_state=false", "denylist_hit=0"]),
            (Gate(role: "AXTextField", subrole: secure,
                  selectedRange: .init(value: target().selection, status: .success),
                  selectedMarker: nil, editable: editableTrue),
             true, "secure_text_field",
             ["role_bucket=AXTextField", "subrole_state=value", "selected_range_state=value",
              "selected_marker_state=skipped", "editable_state=true", "denylist_hit=0"]),
            (Gate(role: "private-field-name", subrole: timeout, selectedRange: unsupported,
                  selectedMarker: timeout, editable: timeout),
             false, "target_unavailable_at_delivery",
             ["role_bucket=other", "subrole_state=timeout", "selected_range_state=unsupported",
              "selected_marker_state=timeout", "editable_state=error", "denylist_hit=0"]),
            (Gate(role: nil, subrole: unsupported, selectedRange: .init(value: nil, status: .failure),
                  selectedMarker: absent, editable: unsupported),
             false, "target_unavailable_at_delivery",
             ["role_bucket=none", "subrole_state=unsupported", "selected_range_state=error",
              "selected_marker_state=noValue", "editable_state=unsupported", "denylist_hit=0"]),
            (Gate(role: "AXSecureTextField", subrole: absent, selectedRange: absent,
                  selectedMarker: absent, editable: .init(value: NSNumber(value: 0), status: .success)),
             false, "secure_text_field",
             ["role_bucket=AXSecureTextField", "subrole_state=noValue", "selected_range_state=noValue",
              "selected_marker_state=noValue", "editable_state=error", "denylist_hit=0"])
        ]
        for (gate, selected, reason, expectedFields) in cases {
            let count = diagnostics.buffer.entries.count
            #expect(gate.rejection(hasTextSelection: selected, diagnostics: diagnostics,
                                   stage: .preflight, began: nil) == reason)
            #expect(diagnostics.buffer.entries.count == count + 1)
            let event = try #require(diagnostics.buffer.entries.last?.event)
            #expect(event.kind == .target && event.stage == .preflight)
            #expect(event.fields[.reason] == .reason(reason))
            #expect(event.fields[.outcome] == .token(.blocked))
            var line = InputDiagnosticBuffer(takeID: diagnostics.takeID)
            line.append(event, elapsedMS: 0)
            let rendered = line.renderedLines().joined(separator: " ")
            for field in expectedFields { #expect(rendered.contains(field)) }
            #expect(!rendered.contains("private-field-name"))
        }
    }

    @Test func markerOnlyOverlapRecordsAttachmentAndBothGuardConditionsWithoutPosting() async throws {
        let sourceID = UUID()
        let current = target(selectionAttribute: "AXSelectedTextMarkerRange")
        let source = TextInsertion.Report(outcome: .inserted, reason: "posted_without_observable_edit",
                                          receipt: nil, eventsPosted: true, target: current, diagnostics: nil,
                                          resultUptimeMS: 1_188)
        let candidate = DictationTake(preferred: .local, style: .verbatim, japaneseHint: false,
                                      vocabulary: [], shouldPaste: true, options: .init())
        candidate.target = current
        let diagnostics = try trace(candidate.id)
        candidate.inputDiagnostics = diagnostics
        VoiceController.reconcileDelivery(source, sourceTakeID: sourceID, into: candidate)
        #expect(candidate.target?.isBlocked == true)
        #expect(candidate.unverifiedInputTargets.count == 1)
        #expect(candidate.unverifiedInputTargets.first?.sameElement(as: current) == true)

        let attachment = try #require(diagnostics.buffer.entries.first { $0.event.kind == .reconcileAttachment }?.event)
        #expect(attachment.stage == .reconcile)
        #expect(attachment.fields[.sourceTake] == .shortIdentifier(sourceID))
        #expect(attachment.fields[.candidateTake] == .shortIdentifier(candidate.id))
        #expect(attachment.fields[.sourceEventsPosted] == .flag(true))
        #expect(attachment.fields[.sourceReceiptPresent] == .flag(false))
        #expect(attachment.fields[.candidateState] == .token(.recording))
        #expect(attachment.fields[.sourceResultUptimeMS] == .integer(1_188))
        #expect(attachment.fields[.candidateCaptureUptimeMS] == .integer(1_000))
        let fields = try #require(diagnostics.buffer.entries.first { $0.event.kind == .reconcile }?.event.fields)
        #expect(fields[.capturedDuring] == .token(.unknown))
        let sent = await TextInsertion.deliver("synthetic", to: candidate.target, diagnostics: diagnostics,
            unverifiedPredecessors: candidate.unverifiedInputTargets, capture: { _ in (current, "ok") })
        #expect(sent.outcome == .focusChanged && sent.reason == "prior_input_unverified" && !sent.eventsPosted)
        let both = try #require(diagnostics.buffer.entries.first { $0.event.fields[.startBlocked] != nil }?.event.fields)
        #expect(both[.startBlocked] == .flag(true))
        #expect(both[.freshMatchesPrior] == .flag(true))
        #expect(both[.unverifiedPredecessorCount] == .integer(1))
        let result = try #require(diagnostics.buffer.entries.last { $0.event.kind == .result }?.event.fields)
        #expect(result[.sentChunks] == .integer(0))
        #expect(result[.uptimeMS] == .integer(sent.resultUptimeMS))

        let cases: [(InsertionTarget?, [InsertionTarget], Bool, Bool)] = [
            (candidate.target, [], true, false),
            (nil, [current], false, true)
        ]
        for (start, predecessors, startBlocked, freshMatches) in cases {
            let trace = try self.trace()
            let prepared = TextInsertion.prepareTarget(takeStart: start, unverifiedPredecessors: predecessors,
                                                       diagnostics: trace, capture: { _ in (current, "ok") })
            #expect(prepared.reason == "prior_input_unverified")
            let evidence = try #require(trace.buffer.entries.last?.event.fields)
            #expect(evidence[.startBlocked] == .flag(startBlocked))
            #expect(evidence[.freshMatchesPrior] == .flag(freshMatches))
            #expect(evidence[.unverifiedPredecessorCount] == .integer(predecessors.count))
        }

        let rendered = diagnostics.buffer.renderedLines().joined(separator: " ") + " "
        #expect(rendered.contains("captured_during=unknown"))
        #expect(rendered.contains("source_take=\(sourceID.uuidString.prefix(8).lowercased()) "))
        #expect(rendered.contains("candidate_take=\(candidate.id.uuidString.prefix(8).lowercased()) "))
        #expect(!rendered.contains("synthetic") && !rendered.contains("opaque-marker"))
    }

    @Test func finishedCandidateWithoutCaptureStillRecordsAnAttachedUnknownPredecessor() throws {
        let candidate = DictationTake(preferred: .local, style: .verbatim, japaneseHint: false,
                                      vocabulary: [], shouldPaste: true, options: .init())
        candidate.finished = true
        let diagnostics = try trace(candidate.id)
        candidate.inputDiagnostics = diagnostics
        let source = TextInsertion.Report(outcome: .inserted, reason: "posted_without_observable_edit",
            receipt: nil, eventsPosted: true, target: target(), diagnostics: nil, resultUptimeMS: 1_188)
        VoiceController.reconcileDelivery(source, sourceTakeID: nil, into: candidate)
        #expect(candidate.target == nil && candidate.unverifiedInputTargets.count == 1)
        let attachment = try #require(diagnostics.buffer.entries.first { $0.event.kind == .reconcileAttachment }?.event)
        #expect(attachment.fields[.sourceTake] == .token(.unknown))
        #expect(attachment.fields[.candidateState] == .token(.finished))
        #expect(attachment.fields[.candidateCaptureUptimeMS] == .token(.unknown))
    }

    @Test func capturedDuringWithReceiptStillRendersTheInclusivePostingWindow() throws {
        let current = target()
        let before = try #require(current.textSnapshot)
        let after = try #require(InsertionReceiptPolicy.expectedAfter(before: before, inserted: "B"))
        let proof = try #require(InsertionReceiptPolicy.verify(before: before, inserted: "B", after: after, sameTarget: true, fieldNature: .normal))
        for (posted, verified, expected) in [(1.0, 2.0, true), (0.0, 1.0, true), (1.1, 2.0, false)] {
            let diagnostics = try trace()
            let report = TextInsertion.Report(outcome: .verifiedInserted, reason: "verified_value_and_selection",
                receipt: .init(target: current, proof: proof, postedAt: posted, verifiedAt: verified),
                eventsPosted: true, target: current, diagnostics: diagnostics, resultUptimeMS: 2_000)
            _ = report.reconciled(current)
            let event = try #require(diagnostics.buffer.entries.last?.event)
            #expect(event.fields[.capturedDuring] == .flag(expected))
            #expect(diagnostics.buffer.renderedLines().contains { $0.contains("captured_during=\(expected ? 1 : 0)") })
        }
    }

    @Test func unavailableAndInvalidCurrentTargetsBlockBothTransportEntrypointsAndHistoryOutcome() async {
        let start = target()
        for reason in ["focused_text_element_unavailable", "koebridge_window_is_frontmost",
                       "secure_text_field", "current_target_not_text_input"] {
            let expected = ["secure_text_field", "current_target_not_text_input", "koebridge_window_is_frontmost"].contains(reason)
                ? reason : "target_unavailable_at_delivery"
            var captures = 0
            let capture: TextInsertion.TargetCapture = { _ in captures += 1; return (nil, reason) }
            let ordinary = await TextInsertion.deliver("認識結果", to: start, capture: capture)
            let command = await TextInsertion.deliverCommandText(.newline, to: start, capture: capture) { true }
            let history = await DictationDelivery.send("認識結果", to: start, capture: capture) { true }
            #expect(captures == 3)
            for report in [ordinary, command] {
                #expect(report.outcome == .focusChanged && report.reason == expected)
                #expect(!report.eventsPosted && report.receipt == nil)
            }
            #expect(history.delivery == .blockedFocus && !history.submitted)
            #expect(history.detail.contains(reason == "koebridge_window_is_frontmost" ? "設定画面" : "現在")
                && history.detail.contains("履歴"))
        }
        let nilStart = await DictationDelivery.send("結果", to: nil,
            capture: { _ in (nil, "focused_text_element_unavailable") }) { true }
        #expect(nilStart.detail.contains("現在の入力欄") && !nilStart.detail.contains("カーソル"))
    }

    @Test func accessibilityCaptureFailurePreservesPermissionOutcomeAndHistoryMessage() async throws {
        let starts: [InsertionTarget?] = [target(), nil]
        for start in starts {
            var captures = 0
            let capture: TextInsertion.TargetCapture = { _ in
                captures += 1
                return (nil, "accessibility_not_granted")
            }
            let prepared = TextInsertion.prepareTarget(takeStart: start, capture: capture)
            #expect(prepared.target == nil && prepared.reason == "accessibility_not_granted")
            let ordinary = await TextInsertion.deliver("認識結果", to: start, capture: capture)
            let command = await TextInsertion.deliverCommandText(.newline, to: start, capture: capture) { true }
            let history = await DictationDelivery.send("認識結果", to: start, capture: capture) { true }
            let historyReport = try #require(history.report)
            #expect(captures == 4)
            for report in [ordinary, command, historyReport] {
                #expect(report.outcome == .notPermitted && report.reason == "accessibility_not_granted")
                #expect(!report.eventsPosted && report.receipt == nil && report.unverifiedTarget == nil)
                #expect(report.target == nil)
            }
            #expect(history.delivery == .missingPermission && !history.submitted)
            #expect(history.submissionFeedback == nil)
            #expect(history.detail == "アクセシビリティの許可が必要です。認識結果は履歴に保存しました。")
        }
        #expect(DictationDelivery.description(.missingPermission, reason: "post_event_permission_missing")
            == "入力に必要な権限がありません。認識結果は履歴に保存しました。")
        #expect(DictationDelivery.description(.verifiedInserted, reason: "accessibility_not_granted")
            == "入力先への反映を確認しました。履歴に保存済みです。")
    }

    @Test func receiptsAndPredecessorsUseFreshIdentityWithoutPinningPendingTakeCaret() throws {
        let takeStart = target()
        let delivery = target(pid: 10_002, caret: 2)
        let before = try #require(delivery.textSnapshot)
        let after = try #require(InsertionReceiptPolicy.expectedAfter(before: before, inserted: "語"))
        let proof = try #require(InsertionReceiptPolicy.verify(before: before, inserted: "語", after: after, sameTarget: true, fieldNature: .normal))
        let receipt = TextInsertion.Receipt(target: delivery, proof: proof, postedAt: 1, verifiedAt: 2)
        let verified = TextInsertion.Report(outcome: .verifiedInserted, reason: "verified_value_and_selection",
                                           receipt: receipt, eventsPosted: true, target: delivery, diagnostics: nil, resultUptimeMS: 2_000)
        #expect(verified.unverifiedTarget == nil)
        #expect(verified.reconciled(takeStart).sameElement(as: takeStart))
        let pending = target(pid: delivery.pid, caret: 1)
        #expect(verified.reconciled(pending).isBlocked) // Old snapshot policy remains conservative.
        let awaitingRecapture = verified.reconciled(pending, recaptureBeforeDelivery: true)
        #expect(!awaitingRecapture.isBlocked)
        let currentAfter = target(pid: delivery.pid, text: after.text, caret: after.selection.location)
        let prepared = TextInsertion.prepareTarget(takeStart: awaitingRecapture,
                                                   capture: { _ in (currentAfter, "ok") })
        #expect(prepared.reason == "ok" && prepared.target?.textSnapshot == after)
        // A latch installed by an actually unverified predecessor is sticky.
        #expect(verified.reconciled(pending.blockedByPriorInput(), recaptureBeforeDelivery: true).isBlocked)
        let unknown = TextInsertion.Report(outcome: .inserted, reason: "posted_receipt_timeout",
                                          receipt: nil, eventsPosted: true, target: delivery, diagnostics: nil, resultUptimeMS: 2_000)
        #expect(unknown.unverifiedTarget?.sameElement(as: delivery) == true)
        #expect(unknown.unverifiedTarget?.sameElement(as: takeStart) == false)
        #expect(unknown.reconciled(pending, recaptureBeforeDelivery: true).isBlocked)
    }

    @Test func failedSecureSubroleReadsCannotBecomeOrdinaryTextInputs() {
        for status in [AXError.cannotComplete, .failure, .notImplemented, .apiDisabled, .invalidUIElement] {
            #expect(!InsertionTarget.secureExclusionReadable(nil, status: status))
        }
        #expect(!InsertionTarget.secureExclusionReadable(kCFBooleanTrue, status: .success))
        for status in [AXError.success, .attributeUnsupported, .noValue] {
            #expect(InsertionTarget.secureExclusionReadable(nil, status: status))
        }
        #expect(InsertionTarget.secureExclusionReadable("AXSearchField" as CFString, status: .success))
        #expect(DeliveryTargetPolicy.blockedReason(role: "AXTextField", subrole: "AXSecureTextField",
            editable: true, hasTextSelection: true) == "secure_text_field")
    }

    @Test func cancellationBeforeDeliveryDoesNotCaptureOrPost() async {
        var captured = false
        let report = await TextInsertion.deliver("語", to: target(), capture: { _ in
            captured = true
            return (nil, "focused_text_element_unavailable")
        }) { false }
        #expect(!captured && !report.eventsPosted)
        #expect(report.outcome == .cancelled && report.reason == "delivery_cancelled_before_post")
        #expect(DictationDelivery.skipped(suppressed: true, requiresReview: false, shouldPaste: true)?.delivery == .cancelledDelivery)
    }

    @Test func settledUnconfirmedPredecessorAndTargetScopedLatchTransportBehavior() async throws {
        let winA = AXUIElementCreateApplication(20_001)
        let winB = AXUIElementCreateApplication(20_002)
        let fieldA = target(pid: 10_001, window: winA, selectionAttribute: "AXSelectedTextMarkerRange")
        let fieldB = target(pid: 10_002, window: winB, selectionAttribute: "AXSelectedTextMarkerRange")
        let source = TextInsertion.Report(outcome: .inserted, reason: "posted_without_observable_edit",
                                          receipt: nil, eventsPosted: true, target: fieldA, diagnostics: nil,
                                          resultUptimeMS: 1_100, exactBaselineAvailable: false,
                                          postSendFocusVerified: true, completedAtUptime: 1.000)
        #expect(source.settledUnconfirmedPredecessor != nil)
        let candidate = DictationTake(preferred: .local, style: .verbatim, japaneseHint: false,
                                      vocabulary: [], shouldPaste: true, options: .init())
        candidate.target = fieldA
        VoiceController.reconcileDelivery(source, sourceTakeID: UUID(), into: candidate)
        #expect(candidate.target?.isBlocked == true)
        #expect(candidate.unverifiedInputTargets.count == 1)
        #expect(candidate.settledUnconfirmedInputTargets.count == 1)

        // 1. Target-scoped latch: moving to unrelated fieldB unblocks prepareTarget.
        let movedToB = TextInsertion.prepareTarget(takeStart: candidate.target,
                                                   unverifiedPredecessors: candidate.unverifiedInputTargets,
                                                   settledUnconfirmedPredecessors: candidate.settledUnconfirmedInputTargets,
                                                   capture: { _ in (fieldB, "ok") })
        #expect(movedToB.reason == "ok" && movedToB.target?.sameElement(as: fieldB) == true)

        // 2. Voice commands keep strict rule even when settledUnconfirmedInputTargets is populated.
        let commandBlocked = await TextInsertion.deliverCommandText(.newline, to: candidate.target,
                                                                    unverifiedPredecessors: candidate.unverifiedInputTargets,
                                                                    capture: { _ in (fieldA, "ok") }) { true }
        #expect(commandBlocked.outcome == .focusChanged && commandBlocked.reason == "prior_input_unverified" && !commandBlocked.eventsPosted)

        // 3. Predecessor with exactBaselineAvailable == true (posted_receipt_timeout) never creates settledUnconfirmedPredecessor.
        let timeoutSource = TextInsertion.Report(outcome: .inserted, reason: "posted_receipt_timeout",
                                                 receipt: nil, eventsPosted: true, target: fieldA, diagnostics: nil,
                                                 resultUptimeMS: 1_100, exactBaselineAvailable: true,
                                                 postSendFocusVerified: true, completedAtUptime: 1.000)
        #expect(timeoutSource.settledUnconfirmedPredecessor == nil)

        // 4. I3: Predecessor with postSendFocusVerified == false never creates settledUnconfirmedPredecessor.
        let unverifiedFocusSource = TextInsertion.Report(outcome: .inserted, reason: "posted_without_observable_edit",
                                                         receipt: nil, eventsPosted: true, target: fieldA, diagnostics: nil,
                                                         resultUptimeMS: 1_100, exactBaselineAvailable: false,
                                                         postSendFocusVerified: false, completedAtUptime: 1.000)
        #expect(unverifiedFocusSource.settledUnconfirmedPredecessor == nil)

        // 5. I4: Predecessor with target.window == nil never creates settledUnconfirmedPredecessor.
        let windowlessField = target(pid: 10_001, window: nil, selectionAttribute: "AXSelectedTextMarkerRange")
        let windowlessSource = TextInsertion.Report(outcome: .inserted, reason: "posted_without_observable_edit",
                                                    receipt: nil, eventsPosted: true, target: windowlessField, diagnostics: nil,
                                                    resultUptimeMS: 1_100, exactBaselineAvailable: false,
                                                    postSendFocusVerified: true, completedAtUptime: 1.000)
        #expect(windowlessSource.settledUnconfirmedPredecessor == nil)

        // 6. I2: Coexistence of settled-unconfirmed predecessor + hard unverified predecessor (e.g. posted_receipt_timeout)
        //        on the same element must keep prepareTarget, stopReason, and DictationTake.hasPriorBlock hard-blocked.
        VoiceController.reconcileDelivery(timeoutSource, sourceTakeID: UUID(), into: candidate)
        #expect(candidate.unverifiedInputTargets.count == 2)
        #expect(candidate.settledUnconfirmedInputTargets.count == 1)
        #expect(candidate.target?.hasHardPredecessorBlock == true)
        #expect(candidate.hasPriorBlock(for: fieldA))
        let blockedByCoexistingHard = TextInsertion.prepareTarget(
            takeStart: candidate.target,
            unverifiedPredecessors: candidate.unverifiedInputTargets,
            settledUnconfirmedPredecessors: candidate.settledUnconfirmedInputTargets,
            capture: { _ in (fieldA, "ok") })
        #expect(blockedByCoexistingHard.target?.sameElement(as: fieldA) == true
            && blockedByCoexistingHard.reason == "prior_input_unverified")

        // 7. I4: Bracketed settled verification requires non-nil window identity and two successful AX selection reads.
        let settledOnlyTake = DictationTake(preferred: .local, style: .verbatim, japaneseHint: false,
                                            vocabulary: [], shouldPaste: true, options: .init())
        settledOnlyTake.target = fieldA
        VoiceController.reconcileDelivery(source, sourceTakeID: UUID(), into: settledOnlyTake)
        #expect(!settledOnlyTake.hasPriorBlock(for: fieldA))

        var markerByte: UInt8 = 7
        let markerValue = try #require(AXTextMarkerRangeCreateWithBytes(nil, &markerByte, 1, &markerByte, 1))
        let markerFieldA = InsertionTarget(bundleIdentifier: "com.meta.endo", localizedName: "Muse",
                                           pid: 10_001, focused: fieldA.focused, window: winA,
                                           selectionAttribute: "AXSelectedTextMarkerRange",
                                           selection: markerValue, textSnapshot: nil,
                                           capturedAt: 1.200, blockedReason: nil)
                                           .withReceiptFieldNature(.normal)
        // If live AX selection read returns .noValue (nil), verifySettledPredecessors must NOT fall back to fresh.selection.
        var failingTransport = TextInsertion.Transport()
        failingTransport.ax.now = { 1.300 }
        failingTransport.ax.sleep = { _ in }
        failingTransport.ax.frontPID = { 10_001 }
        failingTransport.ax.owner = { _ in 10_001 }
        failingTransport.ax.attribute = { _, _ in .init(value: nil, status: .noValue) }
        failingTransport.capture = { _, _ in .accepted(markerFieldA) }
        let blockedOnNoLiveSelection = await TextInsertion.deliver(
            "追加入力", to: settledOnlyTake.target,
            unverifiedPredecessors: settledOnlyTake.unverifiedInputTargets,
            settledUnconfirmedPredecessors: settledOnlyTake.settledUnconfirmedInputTargets,
            transport: failingTransport) { true }
        #expect(blockedOnNoLiveSelection.outcome == .focusChanged && blockedOnNoLiveSelection.reason == "prior_input_unverified")
        #expect(!blockedOnNoLiveSelection.eventsPosted)

        // 8. I10: A verified receipt reconciled after a settled unconfirmed predecessor on the same field
        //         must NOT promote the soft block to hard (unverified stays 1, settled stays 1,
        //         hasHardPredecessorBlock stays false, and follow-up take performs 2 bracketed selection reads and 1 post).
        let i10Take = DictationTake(preferred: .local, style: .verbatim, japaneseHint: false,
                                    vocabulary: [], shouldPaste: true, options: .init())
        i10Take.target = markerFieldA
        let settledMarkerReport = TextInsertion.Report(
            outcome: .inserted, reason: "posted_without_observable_edit",
            receipt: nil, eventsPosted: true, target: markerFieldA, diagnostics: nil,
            resultUptimeMS: 1_100, exactBaselineAvailable: false,
            postSendFocusVerified: true, completedAtUptime: 1.000)
        VoiceController.reconcileDelivery(settledMarkerReport, sourceTakeID: UUID(), into: i10Take)
        #expect(i10Take.unverifiedInputTargets.count == 1)
        #expect(i10Take.settledUnconfirmedInputTargets.count == 1)
        #expect(i10Take.target?.isBlocked == true && i10Take.target?.hasHardPredecessorBlock == false)

        let numericFieldA = InsertionTarget(
            bundleIdentifier: "com.meta.endo", localizedName: "Muse",
            pid: 10_001, focused: fieldA.focused, window: winA,
            selectionAttribute: kAXSelectedTextRangeAttribute as String,
            selection: target(pid: 10_001, caret: 0).selection,
            textSnapshot: .init(text: "A", selection: .init(location: 1, length: 0)),
            capturedAt: 1.050, blockedReason: nil)
        let verifiedBefore = try #require(numericFieldA.textSnapshot)
        let verifiedAfter = try #require(InsertionReceiptPolicy.expectedAfter(before: verifiedBefore, inserted: "B"))
        let verifiedProof = try #require(InsertionReceiptPolicy.verify(before: verifiedBefore, inserted: "B",
                                                                       after: verifiedAfter, sameTarget: true, fieldNature: .normal))
        let verifiedReport = TextInsertion.Report(
            outcome: .verifiedInserted, reason: "verified_value_and_selection",
            receipt: .init(target: numericFieldA, proof: verifiedProof, postedAt: 1.060, verifiedAt: 1.090),
            eventsPosted: true, target: numericFieldA, diagnostics: nil,
            resultUptimeMS: 1_090, exactBaselineAvailable: true,
            postSendFocusVerified: true, completedAtUptime: 1.090)
        VoiceController.reconcileDelivery(verifiedReport, sourceTakeID: UUID(), into: i10Take)
        #expect(i10Take.unverifiedInputTargets.count == 1)
        #expect(i10Take.settledUnconfirmedInputTargets.count == 1)
        #expect(i10Take.target?.hasHardPredecessorBlock == false)
        #expect(!i10Take.hasPriorBlock(for: markerFieldA))

        var bracketedMarkerReads = 0
        var posts = 0
        var i10Transport = TextInsertion.Transport()
        var currentNow = 1.300
        i10Transport.ax.now = { currentNow }
        i10Transport.ax.sleep = { delay in currentNow += delay }
        i10Transport.ax.frontPID = { 10_001 }
        i10Transport.ax.setTimeout = { _, _ in .success }
        i10Transport.ax.owner = { _ in 10_001 }
        i10Transport.ax.attribute = { _, name in
            switch name as String {
            case kAXFocusedWindowAttribute, kAXWindowAttribute:
                return .init(value: winA, status: .success)
            case kAXFocusedUIElementAttribute:
                return .init(value: markerFieldA.focused, status: .success)
            case "AXSelectedTextMarkerRange":
                bracketedMarkerReads += 1
                return .init(value: markerValue, status: .success)
            default:
                return .init(value: nil, status: .noValue)
            }
        }
        i10Transport.capture = { _, _ in .accepted(markerFieldA) }
        i10Transport.permissions = { (true, true) }
        i10Transport.snapshot = { _, _ in (nil, .markerNotNumeric) }
        i10Transport.checkFocus = { _, _, _, _, _ in (true, "ok") }
        i10Transport.post = { _, _ in posts += 1 }
        let i10Result = await TextInsertion.deliver(
            "x", to: i10Take.target,
            unverifiedPredecessors: i10Take.unverifiedInputTargets,
            settledUnconfirmedPredecessors: i10Take.settledUnconfirmedInputTargets,
            livePriorBlock: { i10Take.hasPriorBlock(for: $0) },
            transport: i10Transport) { true }
        #expect(i10Result.outcome == .inserted && bracketedMarkerReads == 2 && posts == 1)

        // Control: a partial or numeric-unverified predecessor coexisting with a settled one still hard-blocks (0 reads, 0 posts).
        for hardReport in [
            TextInsertion.Report(outcome: .partiallySubmitted, reason: "active_app_changed",
                                 receipt: nil, eventsPosted: true, target: markerFieldA, diagnostics: nil,
                                 resultUptimeMS: 1_150, exactBaselineAvailable: false,
                                 postSendFocusVerified: false, completedAtUptime: 1.150),
            TextInsertion.Report(outcome: .inserted, reason: "posted_without_observable_edit",
                                 receipt: nil, eventsPosted: true, target: markerFieldA, diagnostics: nil,
                                 resultUptimeMS: 1_150, exactBaselineAvailable: true,
                                 postSendFocusVerified: true, completedAtUptime: 1.150)
        ] {
            let hardTake = DictationTake(preferred: .local, style: .verbatim, japaneseHint: false,
                                         vocabulary: [], shouldPaste: true, options: .init())
            hardTake.target = markerFieldA
            VoiceController.reconcileDelivery(settledMarkerReport, sourceTakeID: UUID(), into: hardTake)
            VoiceController.reconcileDelivery(hardReport, sourceTakeID: UUID(), into: hardTake)
            #expect(hardTake.target?.hasHardPredecessorBlock == true)
            #expect(hardTake.hasPriorBlock(for: markerFieldA))
            bracketedMarkerReads = 0
            posts = 0
            let blockedHard = await TextInsertion.deliver(
                "x", to: hardTake.target,
                unverifiedPredecessors: hardTake.unverifiedInputTargets,
                settledUnconfirmedPredecessors: hardTake.settledUnconfirmedInputTargets,
                livePriorBlock: { hardTake.hasPriorBlock(for: $0) },
                transport: i10Transport) { true }
            #expect(blockedHard.outcome == .focusChanged && blockedHard.reason == "prior_input_unverified")
            #expect(bracketedMarkerReads == 0 && posts == 0)
        }
    }
}
#endif
