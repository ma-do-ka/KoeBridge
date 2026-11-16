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
    @Test func currentTextInputValidationExcludesSecureAndNonInputTargets() {
        for hasTextSelection in [false, true] {
            for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
                #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil, editable: false,
                                                          hasTextSelection: hasTextSelection) == nil)
                #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: "AXSecureTextField", editable: true,
                                                          hasTextSelection: hasTextSelection) == "secure_text_field")
            }
            #expect(DeliveryTargetPolicy.blockedReason(role: "AXSecureTextField", subrole: nil, editable: true,
                                                      hasTextSelection: hasTextSelection,
                                                      subroleReadable: false) == "secure_text_field")
            #expect(DeliveryTargetPolicy.blockedReason(role: "AXGroup", subrole: nil, editable: true,
                                                      hasTextSelection: hasTextSelection) == nil)
            // Failed/invalid subrole reads cannot be treated as a known missing
            // subrole, even with selection evidence. Legitimate absence passes above.
            for role in ["AXTextField", "AXGroup"] {
                #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil, editable: true,
                                                          hasTextSelection: hasTextSelection,
                                                          subroleReadable: false) == "target_unavailable_at_delivery")
            }
            #expect(DeliveryTargetPolicy.blockedReason(role: nil, subrole: nil, editable: true,
                                                      hasTextSelection: hasTextSelection) == "target_unavailable_at_delivery")
            #expect(DeliveryTargetPolicy.blockedReason(role: nil, subrole: "AXSecureTextField", editable: true,
                                                      hasTextSelection: hasTextSelection,
                                                      subroleReadable: false) == "secure_text_field")
        }
        for role in ["AXButton", "AXStaticText", "AXWebArea", "AXGroup"] {
            #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil, editable: false,
                                                      hasTextSelection: false) == "current_target_not_text_input")
        }
    }

    @Test func markerSelectionAcceptsNonTextRolesWithoutEditable() {
        // Incident shape: AXSelectedTextMarkerRange is the only positive text evidence.
        // No role-name exclusion may override it, including for WebView roles.
        for role in ["AXGroup", "AXWebArea"] {
            #expect(DeliveryTargetPolicy.blockedReason(role: role, subrole: nil, editable: false,
                                                      hasTextSelection: true) == nil)
        }
    }

    @Test func numericSelectionAcceptsNonTextRoleWithoutEditable() {
        // AXSelectedTextRange supplies the same positive evidence to this policy.
        #expect(DeliveryTargetPolicy.blockedReason(role: "AXGroup", subrole: nil, editable: false,
                                                  hasTextSelection: true) == nil)
    }

    @Test func recaptureClassifiesOnlyCurrentIdentityWithoutCaretOrContent() {
        #expect(DeliveryTargetPolicy.recapture(currentAvailable: false, sameApp: false, sameElement: false) == .unavailable)
        #expect(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: true, sameElement: true) == .sameElement)
        #expect(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: true, sameElement: false) == .differentElement)
        #expect(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: false, sameElement: true) == .differentApp)
        #expect(DeliveryTargetPolicy.recapture(currentAvailable: true, sameApp: false, sameElement: false) == .differentApp)
    }
}
