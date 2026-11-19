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

    public static func isTransientFocusUnavailability(_ reason: String) -> Bool {
        reason == "focused_element_unavailable_on_recheck"
            || reason == "focused_window_unavailable_on_recheck"
            || reason == "selection_unavailable_on_recheck"
    }

    /// Authorize at most one bounded 25 ms recheck per checkpoint when an AX
    /// focus/selection read returns transient unavailability while the target
    /// process remains frontmost. Genuine mismatches (`*_changed`, `*_invalid*`)
    /// never qualify.
    public static func mayRecheckTransientFocusUnavailability(reason: String,
                                                              sameProcess: Bool,
                                                              alreadyRecheckedAtCheckpoint: Bool) -> Bool {
        guard sameProcess, !alreadyRecheckedAtCheckpoint else { return false }
        return isTransientFocusUnavailability(reason)
    }
}

/// Secure/unavailable targets fail closed. Live selection or AXEditable evidence
/// takes priority over role names; without evidence, known controls are excluded.
/// Other focused editors need not expose selection or AXEditable.
public enum DeliveryTargetPolicy {
    private static let nonTextRoles = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXMenuBarItem", "AXLink", "AXSlider", "AXIncrementor",
        "AXStepper", "AXSwitch", "AXStaticText", "AXImage", "AXDisclosureTriangle"
    ]

    public static func isDenylisted(role: String?) -> Bool {
        role.map { nonTextRoles.contains($0) } ?? false
    }

    static func diagnosticRoleBucket(_ role: String) -> String {
        if nonTextRoles.contains(role) { return role }
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField":
            return role
        default:
            return "other"
        }
    }

    public static func blockedReason(role: String?, subrole: String?, editable: Bool,
                                     hasTextSelection: Bool,
                                     subroleReadable: Bool = true) -> String? {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return "secure_text_field"
        }
        guard subroleReadable, let role else { return "target_unavailable_at_delivery" }
        if hasTextSelection || editable { return nil }
        if nonTextRoles.contains(role) {
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

    public enum RecoveryAction: Equatable, Sendable {
        case waitOnButton
        case acceptEditor
        case reject
    }

    private static let positiveTextRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
    ]

    /// Evaluate a candidate element observed during bounded pre-send recovery.
    /// - Case A (`isSameElement == true`): any denylisted role (`DeliveryTargetPolicy.isDenylisted(role:)`)
    ///   waits when selection/editable are absent; `AXTextField`/`AXTextArea` with live selection accepts.
    /// - Case B (`isSameElement == false`, allowed only when `requireSameElement == false`):
    ///   requires same process, same owner, same focused window, same element window,
    ///   non-secure role/subrole, and positive editor evidence (either a positive text role
    ///   with valid typed selection, or a non-denylisted role with `editable == true` and
    ///   valid typed selection).
    public static func recoveryCandidateAction(requireSameElement: Bool,
                                               sameProcess: Bool,
                                               sameOwner: Bool,
                                               sameFocusedWindow: Bool,
                                               sameElementWindow: Bool,
                                               isSameElement: Bool,
                                               bundleIdentifier: String? = nil,
                                               role: String?,
                                               subrole: String?,
                                               subroleReadable: Bool,
                                               hasValidNumericSelection: Bool,
                                               hasValidMarkerSelection: Bool,
                                               rangeAbsent: Bool,
                                               markerAbsent: Bool,
                                               editable: Bool?,
                                               editableAbsent: Bool) -> RecoveryAction {
        guard sameProcess, sameOwner, sameFocusedWindow else { return .reject }
        guard isSameElement || !requireSameElement else { return .reject }
        guard let role, subroleReadable,
              role != "AXSecureTextField", subrole != "AXSecureTextField" else { return .reject }
        if requireSameElement && isSameElement && isDenylisted(role: role) {
            guard rangeAbsent, markerAbsent, editableAbsent else { return .reject }
            return .waitOnButton
        }
        guard sameElementWindow else { return .reject }
        let hasSelection = hasValidNumericSelection || hasValidMarkerSelection
        guard hasSelection else { return .reject }
        if requireSameElement && isSameElement {
            if ["AXTextField", "AXTextArea"].contains(role) {
                return .acceptEditor
            }
            if bundleIdentifier == "com.meta.endo",
               !isDenylisted(role: role),
               hasValidMarkerSelection,
               editable != false {
                return .acceptEditor
            }
            return .reject
        }
        // Case B: Unavailable initial focus (requireSameElement == false).
        guard !isDenylisted(role: role) else { return .reject }
        if positiveTextRoles.contains(role) {
            return .acceptEditor
        }
        return editable == true ? .acceptEditor : .reject
    }
}
