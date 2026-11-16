#if os(macOS)
import ApplicationServices
import CoreGraphics
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
    private func target(pid: pid_t = 10_001, element: CFTypeRef? = nil,
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
            selection = "opaque-marker" as CFString
        }
        return InsertionTarget(bundleIdentifier: "com.example.Editor", localizedName: "Editor", pid: pid,
            focused: element ?? AXUIElementCreateApplication(pid), window: nil,
            selectionAttribute: selectionAttribute, selection: selection,
            textSnapshot: numeric ? .init(text: text, selection: .init(location: caret, length: 0)) : nil,
            capturedAt: 1, blockedReason: nil)
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
            #expect(InsertionReceiptPolicy.verify(before: before, inserted: "語", after: after, sameTarget: true) != nil)
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
        let proof = try #require(InsertionReceiptPolicy.verify(before: before, inserted: "語", after: after, sameTarget: true))
        let receipt = TextInsertion.Receipt(target: delivery, proof: proof, postedAt: 1, verifiedAt: 2)
        let verified = TextInsertion.Report(outcome: .verifiedInserted, reason: "verified_value_and_selection",
                                           receipt: receipt, eventsPosted: true, target: delivery, diagnostics: nil)
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
                                          receipt: nil, eventsPosted: true, target: delivery, diagnostics: nil)
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
        #expect(DictationDelivery.skipped(suppressed: true, requiresReview: false, shouldPaste: true)?.delivery == .blockedFocus)
    }
}
#endif
