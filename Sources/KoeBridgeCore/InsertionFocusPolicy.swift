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

/// Positive input evidence is required at delivery; selection alone can also
/// belong to a read-only document. AX text roles support editors whose value
/// or selection cannot be observed, including marker-based browser editors.
public enum DeliveryTargetPolicy {
    public static func blockedReason(role: String?, subrole: String?, editable: Bool,
                                     subroleReadable: Bool = true) -> String? {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return "secure_text_field"
        }
        guard subroleReadable, let role else { return "target_unavailable_at_delivery" }
        guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) || editable else {
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
