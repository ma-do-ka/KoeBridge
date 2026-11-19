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
    func row1StaticTextWithMarkerIsAccepted() {
        check(DeliveryTargetPolicy.blockedReason(role: "AXStaticText", subrole: nil,
            editable: false, hasTextSelection: true) == nil)
        // Deliberate trade-off: even a button role loses to live marker evidence.
        check(DeliveryTargetPolicy.blockedReason(role: "AXButton", subrole: nil,
            editable: false, hasTextSelection: true) == nil)
    }

    func row2FocusedEditorsWithoutEvidenceAreAccepted() {
        // ecf0cc05: unavailable AXEditable and both selection attributes (-25212).
        for role in ["AXGroup", "AXWebArea", "AXCustomEditor"] {
            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                editable: false, hasTextSelection: false) == nil)
        }
    }

    func row3NativeTextRolesAreAccepted() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            for editable in [false, true] {
                for selection in [false, true] {
                    check(DeliveryTargetPolicy.blockedReason(role: role, subrole: "AXSearchField",
                        editable: editable, hasTextSelection: selection) == nil)
                }
            }
        }
    }

    func row4NumericSelectionOverridesAnyNonsecureRole() {
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                     "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
                     "AXSlider", "AXIncrementor", "AXStepper", "AXSwitch",
                     "AXStaticText", "AXImage", "AXDisclosureTriangle"] + ["AXGroup", "AXCustomEditor"] {
            for editable in [false, true] {
                check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                    editable: editable, hasTextSelection: true) == nil)
            }
        }
    }

    func row5EditableOverridesAnyNonsecureRole() {
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                     "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
                     "AXSlider", "AXIncrementor", "AXStepper", "AXSwitch",
                     "AXStaticText", "AXImage", "AXDisclosureTriangle"] + ["AXGroup", "AXCustomEditor"] {
            for selection in [false, true] {
                check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                    editable: true, hasTextSelection: selection) == nil)
            }
        }
    }

    func row6ControlsWithoutEvidenceBlock() {
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                     "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
                     "AXSlider", "AXIncrementor", "AXStepper", "AXSwitch",
                     "AXStaticText", "AXImage", "AXDisclosureTriangle"] {
            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                editable: false, hasTextSelection: false) == "current_target_not_text_input")
        }
    }

    func row7PureStaticLabelBlocks() {
        check(DeliveryTargetPolicy.blockedReason(role: "AXStaticText", subrole: nil,
            editable: false, hasTextSelection: false) == "current_target_not_text_input")
    }

    func row8SecureRoleOrSubroleAlwaysBlocks() {
        let roles: [String?] = [nil, "AXButton", "AXTextField", "AXSecureTextField"]
        for role in roles {
            for subrole in [nil, "AXSecureTextField"] as [String?] {
                guard role == "AXSecureTextField" || subrole == "AXSecureTextField" else { continue }
                for readable in [false, true] {
                    for editable in [false, true] {
                        for selection in [false, true] {
                            check(DeliveryTargetPolicy.blockedReason(role: role, subrole: subrole,
                                editable: editable, hasTextSelection: selection,
                                subroleReadable: readable) == "secure_text_field")
                        }
                    }
                }
            }
        }
    }

    func row9UnavailableRoleOrSubroleAlwaysBlocks() {
        for role in [nil, "AXGroup", "AXButton", "AXTextField"] as [String?] {
            for readable in [false, true] {
                guard role == nil || !readable else { continue }
                for editable in [false, true] {
                    for selection in [false, true] {
                        check(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                            editable: editable, hasTextSelection: selection,
                            subroleReadable: readable) == "target_unavailable_at_delivery")
                    }
                }
            }
        }
    }

    func recaptureClassifiesOnlyCurrentIdentityWithoutCaretOrContent() {
        check(DeliveryTargetPolicy.recapture(currentAvailable: false, sameApp: false, sameElement: false) == .unavailable)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: true, sameElement: true) == .sameElement)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: true, sameElement: false) == .differentElement)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: false, sameElement: true) == .differentApp)
        check(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: false, sameElement: false) == .differentApp)
    }

    func recoveryCandidateRequiresSameWindowAndPositiveEditorEvidenceForDifferentElement() {
        // Case A (Build 73 pin): Same element transitions from AXButton -> AXTextField/AXTextArea with selection.
        check(DeliveryTargetPolicy.recoveryCandidateAction(
            requireSameElement: true, sameProcess: true, sameOwner: true, sameFocusedWindow: true,
            sameElementWindow: true, isSameElement: true, role: "AXButton", subrole: nil,
            subroleReadable: true, hasValidNumericSelection: false, hasValidMarkerSelection: false,
            rangeAbsent: true, markerAbsent: true, editable: nil, editableAbsent: true) == .waitOnButton)
        for role in ["AXTextField", "AXTextArea"] {
            check(DeliveryTargetPolicy.recoveryCandidateAction(
                requireSameElement: true, sameProcess: true, sameOwner: true, sameFocusedWindow: true,
                sameElementWindow: true, isSameElement: true, role: role, subrole: nil,
                subroleReadable: true, hasValidNumericSelection: true, hasValidMarkerSelection: false,
                rangeAbsent: false, markerAbsent: true, editable: nil, editableAbsent: true) == .acceptEditor)
        }
        // When requireSameElement is true (Endo AXButton rejection), a different element is never adopted.
        check(DeliveryTargetPolicy.recoveryCandidateAction(
            requireSameElement: true, sameProcess: true, sameOwner: true, sameFocusedWindow: true,
            sameElementWindow: true, isSameElement: false, role: "AXTextArea", subrole: nil,
            subroleReadable: true, hasValidNumericSelection: true, hasValidMarkerSelection: false,
            rangeAbsent: false, markerAbsent: true, editable: true, editableAbsent: false) == .reject)

        // Case B positive: Unavailable initial focus (requireSameElement == false) adopts a different element
        // in the same window/process ONLY when it has positive editor evidence.
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            check(DeliveryTargetPolicy.recoveryCandidateAction(
                requireSameElement: false, sameProcess: true, sameOwner: true, sameFocusedWindow: true,
                sameElementWindow: true, isSameElement: false, role: role, subrole: nil,
                subroleReadable: true, hasValidNumericSelection: true, hasValidMarkerSelection: false,
                rangeAbsent: false, markerAbsent: true, editable: nil, editableAbsent: true) == .acceptEditor)
            check(DeliveryTargetPolicy.recoveryCandidateAction(
                requireSameElement: false, sameProcess: true, sameOwner: true, sameFocusedWindow: true,
                sameElementWindow: true, isSameElement: false, role: role, subrole: nil,
                subroleReadable: true, hasValidNumericSelection: false, hasValidMarkerSelection: true,
                rangeAbsent: true, markerAbsent: false, editable: nil, editableAbsent: true) == .acceptEditor)
        }
        for role in ["AXGroup", "AXWebArea"] {
            check(DeliveryTargetPolicy.recoveryCandidateAction(
                requireSameElement: false, sameProcess: true, sameOwner: true, sameFocusedWindow: true,
                sameElementWindow: true, isSameElement: false, role: role, subrole: nil,
                subroleReadable: true, hasValidNumericSelection: false, hasValidMarkerSelection: true,
                rangeAbsent: true, markerAbsent: false, editable: true, editableAbsent: false) == .acceptEditor)
        }

        // Condition 2 (i): Different-window or different-app element is NEVER adopted.
        for (sameProc, sameOwn, sameWin, sameElemWin) in [
            (false, true, true, true),
            (true, false, true, true),
            (true, true, false, true),
            (true, true, true, false)
        ] {
            check(DeliveryTargetPolicy.recoveryCandidateAction(
                requireSameElement: false, sameProcess: sameProc, sameOwner: sameOwn,
                sameFocusedWindow: sameWin, sameElementWindow: sameElemWin, isSameElement: false,
                role: "AXTextArea", subrole: nil, subroleReadable: true,
                hasValidNumericSelection: true, hasValidMarkerSelection: false,
                rangeAbsent: false, markerAbsent: true, editable: true, editableAbsent: false) == .reject)
        }

        // Condition 2 (ii): Same-window element WITHOUT positive editor evidence is NEVER adopted.
        // - Non-text control role (even with selection or editable)
        for control in ["AXButton", "AXLink", "AXStaticText", "AXCheckBox"] {
            check(DeliveryTargetPolicy.recoveryCandidateAction(
                requireSameElement: false, sameProcess: true, sameOwner: true, sameFocusedWindow: true,
                sameElementWindow: true, isSameElement: false, role: control, subrole: nil,
                subroleReadable: true, hasValidNumericSelection: true, hasValidMarkerSelection: false,
                rangeAbsent: false, markerAbsent: true, editable: true, editableAbsent: false) == .reject)
        }
        // - Generic container (AXGroup / AXWebArea) without AXEditable == true
        for editable in [nil, false] as [Bool?] {
            check(DeliveryTargetPolicy.recoveryCandidateAction(
                requireSameElement: false, sameProcess: true, sameOwner: true, sameFocusedWindow: true,
                sameElementWindow: true, isSameElement: false, role: "AXGroup", subrole: nil,
                subroleReadable: true, hasValidNumericSelection: true, hasValidMarkerSelection: false,
                rangeAbsent: false, markerAbsent: true, editable: editable, editableAbsent: editable == nil) == .reject)
        }
        // - Positive text role or editable container without a valid typed selection
        check(DeliveryTargetPolicy.recoveryCandidateAction(
            requireSameElement: false, sameProcess: true, sameOwner: true, sameFocusedWindow: true,
            sameElementWindow: true, isSameElement: false, role: "AXTextArea", subrole: nil,
            subroleReadable: true, hasValidNumericSelection: false, hasValidMarkerSelection: false,
            rangeAbsent: true, markerAbsent: true, editable: true, editableAbsent: false) == .reject)
        check(DeliveryTargetPolicy.recoveryCandidateAction(
            requireSameElement: false, sameProcess: true, sameOwner: true, sameFocusedWindow: true,
            sameElementWindow: true, isSameElement: false, role: "AXGroup", subrole: nil,
            subroleReadable: true, hasValidNumericSelection: false, hasValidMarkerSelection: false,
            rangeAbsent: true, markerAbsent: true, editable: true, editableAbsent: false) == .reject)
        // - Secure role or subrole
        check(DeliveryTargetPolicy.recoveryCandidateAction(
            requireSameElement: false, sameProcess: true, sameOwner: true, sameFocusedWindow: true,
            sameElementWindow: true, isSameElement: false, role: "AXSecureTextField", subrole: nil,
            subroleReadable: true, hasValidNumericSelection: true, hasValidMarkerSelection: false,
            rangeAbsent: false, markerAbsent: true, editable: true, editableAbsent: false) == .reject)
        check(DeliveryTargetPolicy.recoveryCandidateAction(
            requireSameElement: false, sameProcess: true, sameOwner: true, sameFocusedWindow: true,
            sameElementWindow: true, isSameElement: false, role: "AXTextField", subrole: "AXSecureTextField",
            subroleReadable: true, hasValidNumericSelection: true, hasValidMarkerSelection: false,
            rangeAbsent: false, markerAbsent: true, editable: true, editableAbsent: false) == .reject)
    }
}
