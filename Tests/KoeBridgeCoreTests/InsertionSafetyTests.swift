import Testing
@testable import KoeBridgeCore

struct InsertionSafetyTests {
    @Test(arguments: [false, true]) func neverPasteToWindowOnlyTarget(_ sameProcess: Bool) {
        #expect(!InsertionFocusPolicy.mayPaste(sameProcess: sameProcess, sameWindow: true,
                                               sameElement: nil, selectionMatches: nil))
    }

    // This gate compares against the fresh delivery capture, not take start.
    @Test func caretDriftAfterDeliveryCaptureBlocksPostingWhenObservable() {
        #expect(!InsertionFocusPolicy.mayPaste(sameProcess: true, sameWindow: true,
                                               sameElement: true, selectionMatches: false))
    }

    @Test func validCaptureAndCurrentFocusPermitPaste() {
        #expect(InsertionFocusPolicy.mayPaste(sameProcess: true, sameWindow: true,
                                              sameElement: true, selectionMatches: true))
    }

    @Test func unknownCaretMayPasteOnlyWhenTheSameTextFieldIsVerified() {
        #expect(InsertionFocusPolicy.mayPaste(sameProcess: true, sameWindow: true,
                                              sameElement: true, selectionMatches: nil))
    }

    @Test func focusedElementOwnedByDifferentProcessMustBlockPaste() {
        #expect(!InsertionFocusPolicy.mayPaste(sameProcess: true, sameWindow: true,
                                               sameElement: true, selectionMatches: true,
                                               sameElementOwner: false))
    }

    @Test func windowOrAppDriftAfterDeliveryCaptureMustBlockPosting() {
        for sameProcess in [false, true] {
            for sameWindow in [false, true] {
                if sameProcess && sameWindow { continue }
                #expect(!InsertionFocusPolicy.mayPaste(sameProcess: sameProcess, sameWindow: sameWindow,
                                                       sameElement: true, selectionMatches: true))
            }
        }
    }
}

extension InsertionSafetyTests {
    @Test func row1StaticTextWithMarkerIsAccepted() {
        #expect(DeliveryTargetPolicy.blockedReason(role: "AXStaticText", subrole: nil,
            editable: false, hasTextSelection: true) == nil)
        // Deliberate trade-off: even a button role loses to live marker evidence.
        #expect(DeliveryTargetPolicy.blockedReason(role: "AXButton", subrole: nil,
            editable: false, hasTextSelection: true) == nil)
    }

    @Test func row2FocusedEditorsWithoutEvidenceAreAccepted() {
        // ecf0cc05: unavailable AXEditable and both selection attributes (-25212).
        for role in ["AXGroup", "AXWebArea", "AXCustomEditor"] {
            #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                editable: false, hasTextSelection: false) == nil)
        }
    }

    @Test func row3NativeTextRolesAreAccepted() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            for editable in [false, true] {
                for selection in [false, true] {
                    #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: "AXSearchField",
                        editable: editable, hasTextSelection: selection) == nil)
                }
            }
        }
    }

    @Test func row4NumericSelectionOverridesAnyNonsecureRole() {
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                     "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
                     "AXSlider", "AXIncrementor", "AXStepper", "AXSwitch",
                     "AXStaticText", "AXImage", "AXDisclosureTriangle"] + ["AXGroup", "AXCustomEditor"] {
            for editable in [false, true] {
                #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                    editable: editable, hasTextSelection: true) == nil)
            }
        }
    }

    @Test func row5EditableOverridesAnyNonsecureRole() {
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                     "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
                     "AXSlider", "AXIncrementor", "AXStepper", "AXSwitch",
                     "AXStaticText", "AXImage", "AXDisclosureTriangle"] + ["AXGroup", "AXCustomEditor"] {
            for selection in [false, true] {
                #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                    editable: true, hasTextSelection: selection) == nil)
            }
        }
    }

    @Test func row6ControlsWithoutEvidenceBlock() {
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                     "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
                     "AXSlider", "AXIncrementor", "AXStepper", "AXSwitch",
                     "AXStaticText", "AXImage", "AXDisclosureTriangle"] {
            #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                editable: false, hasTextSelection: false) == "current_target_not_text_input")
        }
    }

    @Test func row7PureStaticLabelBlocks() {
        #expect(DeliveryTargetPolicy.blockedReason(role: "AXStaticText", subrole: nil,
            editable: false, hasTextSelection: false) == "current_target_not_text_input")
    }

    @Test func row8SecureRoleOrSubroleAlwaysBlocks() {
        let roles: [String?] = [nil, "AXButton", "AXTextField", "AXSecureTextField"]
        for role in roles {
            for subrole in [nil, "AXSecureTextField"] as [String?] {
                guard role == "AXSecureTextField" || subrole == "AXSecureTextField" else { continue }
                for readable in [false, true] {
                    for editable in [false, true] {
                        for selection in [false, true] {
                            #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: subrole,
                                editable: editable, hasTextSelection: selection,
                                subroleReadable: readable) == "secure_text_field")
                        }
                    }
                }
            }
        }
    }

    @Test func row9UnavailableRoleOrSubroleAlwaysBlocks() {
        for role in [nil, "AXGroup", "AXButton", "AXTextField"] as [String?] {
            for readable in [false, true] {
                guard role == nil || !readable else { continue }
                for editable in [false, true] {
                    for selection in [false, true] {
                        #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                            editable: editable, hasTextSelection: selection,
                            subroleReadable: readable) == "target_unavailable_at_delivery")
                    }
                }
            }
        }
    }

    @Test func recaptureClassifiesOnlyCurrentIdentityWithoutCaretOrContent() {
        #expect(DeliveryTargetPolicy.recapture(currentAvailable: false, sameApp: false, sameElement: false) == .unavailable)
        #expect(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: true, sameElement: true) == .sameElement)
        #expect(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: true, sameElement: false) == .differentElement)
        #expect(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: false, sameElement: true) == .differentApp)
        #expect(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: false, sameElement: false) == .differentApp)
    }
}
