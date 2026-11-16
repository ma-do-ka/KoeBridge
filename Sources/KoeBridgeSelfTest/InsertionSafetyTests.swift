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
        for hasTextSelection in [false, true] {
            for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
                check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil, editable: false,
                                                          hasTextSelection: hasTextSelection) == nil)
                check(DeliveryTargetPolicy.blockedReason(role: role, subrole: "AXSecureTextField", editable: true,
                                                          hasTextSelection: hasTextSelection) == "secure_text_field")
            }
            check(DeliveryTargetPolicy.blockedReason(role: "AXSecureTextField", subrole: nil, editable: true,
                                                      hasTextSelection: hasTextSelection,
                                                      subroleReadable: false) == "secure_text_field")
            check(DeliveryTargetPolicy.blockedReason(role: "AXGroup", subrole: nil, editable: true,
                                                      hasTextSelection: hasTextSelection) == nil)
            // Failed/invalid subrole reads cannot be treated as a known missing
            // subrole, even with selection evidence. Legitimate absence passes above.
            for role in ["AXTextField", "AXGroup"] {
                check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil, editable: true,
                                                          hasTextSelection: hasTextSelection,
                                                          subroleReadable: false) == "target_unavailable_at_delivery")
            }
            check(DeliveryTargetPolicy.blockedReason(role: nil, subrole: nil, editable: true,
                                                      hasTextSelection: hasTextSelection) == "target_unavailable_at_delivery")
            check(DeliveryTargetPolicy.blockedReason(role: nil, subrole: "AXSecureTextField", editable: true,
                                                      hasTextSelection: hasTextSelection,
                                                      subroleReadable: false) == "secure_text_field")
        }
        for role in ["AXButton", "AXStaticText", "AXWebArea", "AXGroup"] {
            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil, editable: false,
                                                      hasTextSelection: false) == "current_target_not_text_input")
        }
    }

    func markerSelectionAcceptsNonTextRolesWithoutEditable() {
        // Incident shape: AXSelectedTextMarkerRange is the only positive text evidence.
        // No role-name exclusion may override it, including for WebView roles.
        for role in ["AXGroup", "AXWebArea"] {
            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil, editable: false,
                                                      hasTextSelection: true) == nil)
        }
    }

    func numericSelectionAcceptsNonTextRoleWithoutEditable() {
        // AXSelectedTextRange supplies the same positive evidence to this policy.
        check(DeliveryTargetPolicy.blockedReason(role: "AXGroup", subrole: nil, editable: false,
                                                  hasTextSelection: true) == nil)
    }

    func recaptureClassifiesOnlyCurrentIdentityWithoutCaretOrContent() {
        check(DeliveryTargetPolicy.recapture(currentAvailable: false, sameApp: false, sameElement: false) == .unavailable)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: true, sameElement: true) == .sameElement)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: true, sameElement: false) == .differentElement)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: false, sameElement: true) == .differentApp)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: false, sameElement: false) == .differentApp)
    }
}
