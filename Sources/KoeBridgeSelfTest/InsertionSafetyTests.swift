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
    func currentTargetValidationExcludesSecureAndUnavailableTargets() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXGroup", "AXButton"] {
            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: "AXSecureTextField") == "secure_text_field")
            // Failed/invalid subrole reads cannot become legitimate absence.
            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                                                      subroleReadable: false) == "target_unavailable_at_delivery")
        }
        check(DeliveryTargetPolicy.blockedReason(role: nil, subrole: nil) == "target_unavailable_at_delivery")
        for subroleReadable in [false, true] {
            check(DeliveryTargetPolicy.blockedReason(role: "AXSecureTextField", subrole: nil,
                                                      subroleReadable: subroleReadable) == "secure_text_field")
            check(DeliveryTargetPolicy.blockedReason(role: nil, subrole: "AXSecureTextField",
                                                      subroleReadable: subroleReadable) == "secure_text_field")
            check(DeliveryTargetPolicy.blockedReason(role: "AXButton", subrole: "AXSecureTextField",
                                                      subroleReadable: subroleReadable) == "secure_text_field")
        }
    }

    func focusedEditorsWithoutSelectionOrEditableAreAccepted() {
        // ecf0cc05: AXGroup with a legitimately absent subrole, AXEditable and
        // both selection attributes unavailable. Those signals are not gate inputs.
        for role in ["AXGroup", "AXWebArea", "AXTextField", "AXTextArea", "AXComboBox", "AXCustomEditor"] {
            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil) == nil)
            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: "AXSearchField") == nil)
        }
    }

    func nonTextControlRolesAlwaysBlock() {
        // Selection and AXEditable can never override this denylist.
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                     "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
                     "AXSlider", "AXIncrementor", "AXStepper", "AXSwitch",
                     "AXStaticText", "AXImage", "AXDisclosureTriangle"] {
            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil) == "current_target_not_text_input")
        }
    }

    func recaptureClassifiesOnlyCurrentIdentityWithoutCaretOrContent() {
        check(DeliveryTargetPolicy.recapture(currentAvailable: false, sameApp: false, sameElement: false) == .unavailable)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: true, sameElement: true) == .sameElement)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: true, sameElement: false) == .differentElement)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: false, sameElement: true) == .differentApp)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: false, sameElement: false) == .differentApp)
    }
}
