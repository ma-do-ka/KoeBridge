
import KoeBridgeCore

struct InsertionSafetyTests {
    func neverPasteToWindowOnlyTarget(_ sameProcess: Bool) {
        check(!InsertionFocusPolicy.mayPaste(sameProcess: sameProcess, sameWindow: true,
                                               sameElement: nil, selectionMatches: nil))
    }

    // This gate compares against the fresh delivery capture, not take start.
    func caretDriftAfterDeliveryCaptureBlocksPostingWhenObservable() {
        check(!InsertionFocusPolicy.mayPaste(sameProcess: true, sameWindow: true,
                                               sameElement: true, selectionMatches: false))
    }

    func validCaptureAndCurrentFocusPermitPaste() {
        check(InsertionFocusPolicy.mayPaste(sameProcess: true, sameWindow: true,
                                              sameElement: true, selectionMatches: true))
    }

    func unknownCaretMayPasteOnlyWhenTheSameTextFieldIsVerified() {
        check(InsertionFocusPolicy.mayPaste(sameProcess: true, sameWindow: true,
                                              sameElement: true, selectionMatches: nil))
    }

    func focusedElementOwnedByDifferentProcessMustBlockPaste() {
        check(!InsertionFocusPolicy.mayPaste(sameProcess: true, sameWindow: true,
                                               sameElement: true, selectionMatches: true,
                                               sameElementOwner: false))
    }

    func windowOrAppDriftAfterDeliveryCaptureMustBlockPosting() {
        for sameProcess in [false, true] {
            for sameWindow in [false, true] {
                if sameProcess && sameWindow { continue }
                check(!InsertionFocusPolicy.mayPaste(sameProcess: sameProcess, sameWindow: sameWindow,
                                                       sameElement: true, selectionMatches: true))
            }
        }
    }
}

extension InsertionSafetyTests {
    func currentTextInputValidationExcludesSecureAndNonInputTargets() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil, editable: false) == nil)
            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: "AXSecureTextField", editable: true) == "secure_text_field")
        }
        check(DeliveryTargetPolicy.blockedReason(role: "AXSecureTextField", subrole: nil, editable: true) == "secure_text_field")
        check(DeliveryTargetPolicy.blockedReason(role: "AXGroup", subrole: nil, editable: true) == nil)
        // Failed/invalid subrole reads cannot be treated as a known missing
        // subrole; ordinary unsupported/no-value reads remain usable above.
        check(DeliveryTargetPolicy.blockedReason(role: "AXTextField", subrole: nil, editable: true,
                                                  subroleReadable: false) == "target_unavailable_at_delivery")
        check(DeliveryTargetPolicy.blockedReason(role: "AXGroup", subrole: nil, editable: true,
                                                  subroleReadable: false) == "target_unavailable_at_delivery")
        for role in ["AXButton", "AXStaticText", "AXWebArea", "AXGroup"] {
            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil, editable: false) == "current_target_not_text_input")
        }
        check(DeliveryTargetPolicy.blockedReason(role: nil, subrole: nil, editable: true) == "target_unavailable_at_delivery")
    }

    func recaptureClassifiesOnlyCurrentIdentityWithoutCaretOrContent() {
        check(DeliveryTargetPolicy.recapture(currentAvailable: false, sameApp: false, sameElement: false) == .unavailable)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: true, sameElement: true) == .sameElement)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: true, sameElement: false) == .differentElement)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: false, sameElement: true) == .differentApp)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: false, sameElement: false) == .differentApp)
    }
}
