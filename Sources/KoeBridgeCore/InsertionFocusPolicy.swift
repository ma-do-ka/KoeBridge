/// Once delivery captures the current target, keep posting anchored to that
/// field. Movement before delivery is handled by a fresh capture, not this gate.
public enum InsertionFocusPolicy {
    public static func mayPaste(sameProcess: Bool, sameWindow: Bool,
                                sameElement: Bool?, selectionMatches: Bool?,
                                sameElementOwner: Bool = true) -> Bool {
        guard sameProcess, sameWindow, sameElement == true, sameElementOwner else { return false }
        if let selectionMatches { return selectionMatches }
        // Editors without an AX selection still work if the exact same AX
        // focused element can be verified. A caret move inside it is unknown.
        return true
    }
}

/// Secure/unavailable targets fail closed. Live selection or AXEditable evidence
/// takes priority over role names; without evidence, known controls are excluded.
/// Other focused editors need not expose selection or AXEditable.
public enum DeliveryTargetPolicy {
    public static func blockedReason(role: String?, subrole: String?, editable: Bool,
                                     hasTextSelection: Bool,
                                     subroleReadable: Bool = true) -> String? {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return "secure_text_field"
        }
        guard subroleReadable, let role else { return "target_unavailable_at_delivery" }
        if hasTextSelection || editable { return nil }
        if ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
            "AXMenuItem", "AXMenuBarItem", "AXLink", "AXSlider", "AXIncrementor",
            "AXStepper", "AXSwitch", "AXStaticText", "AXImage", "AXDisclosureTriangle"].contains(role) {
            return "current_target_not_text_input"
        }
        return nil
    }

    public static func recapture(currentAvailable: Bool, sameApp: Bool,
                                 sameElement: Bool) -> InputDiagnosticEvent.Token {
        guard currentAvailable else { return .unavailable }
        guard sameApp else { return .differentApp }
        return sameElement ? .sameElement : .differentElement
    }
}
