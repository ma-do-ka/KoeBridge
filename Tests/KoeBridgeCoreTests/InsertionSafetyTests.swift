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
    @Test func currentTargetValidationExcludesSecureAndUnavailableTargets() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXGroup", "AXButton"] {
            #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: "AXSecureTextField") == "secure_text_field")
            // Failed/invalid subrole reads cannot become legitimate absence.
            #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil,
                                                      subroleReadable: false) == "target_unavailable_at_delivery")
        }
        #expect(DeliveryTargetPolicy.blockedReason(role: nil, subrole: nil) == "target_unavailable_at_delivery")
        for subroleReadable in [false, true] {
            #expect(DeliveryTargetPolicy.blockedReason(role: "AXSecureTextField", subrole: nil,
                                                      subroleReadable: subroleReadable) == "secure_text_field")
            #expect(DeliveryTargetPolicy.blockedReason(role: nil, subrole: "AXSecureTextField",
                                                      subroleReadable: subroleReadable) == "secure_text_field")
            #expect(DeliveryTargetPolicy.blockedReason(role: "AXButton", subrole: "AXSecureTextField",
                                                      subroleReadable: subroleReadable) == "secure_text_field")
        }
    }

    @Test func focusedEditorsWithoutSelectionOrEditableAreAccepted() {
        // ecf0cc05: AXGroup with a legitimately absent subrole, AXEditable and
        // both selection attributes unavailable. Those signals are not gate inputs.
        for role in ["AXGroup", "AXWebArea", "AXTextField", "AXTextArea", "AXComboBox", "AXCustomEditor"] {
            #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil) == nil)
            #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: "AXSearchField") == nil)
        }
    }

    @Test func nonTextControlRolesAlwaysBlock() {
        // Selection and AXEditable can never override this denylist.
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                     "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink",
                     "AXSlider", "AXIncrementor", "AXStepper", "AXSwitch",
                     "AXStaticText", "AXImage", "AXDisclosureTriangle"] {
            #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil) == "current_target_not_text_input")
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
