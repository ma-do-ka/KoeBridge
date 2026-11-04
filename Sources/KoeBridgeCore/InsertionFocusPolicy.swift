/// Fail closed if an insertion target cannot be identified more precisely than
/// the frontmost window. In particular, moving between text fields inside one
/// Chrome or Electron window must not leak dictated text to the wrong field.
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
