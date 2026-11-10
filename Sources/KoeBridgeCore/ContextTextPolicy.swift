import Foundation

public enum ContextTextPolicy {
    public static let maximumCharacters = 2_000

    public static func selected(_ text: String) -> String {
        String(text.prefix(maximumCharacters))
    }

    /// AX offsets are UTF-16. Start up to half a window before the selection,
    /// then keep the start of that window, including at most 2,000 characters.
    public static func surrounding(_ text: String, selection: InsertionReceiptPolicy.Selection?) -> String {
        guard let selection, selection.location >= 0,
              selection.location <= text.utf16.count else { return selected(text) }
        let offset = max(0, selection.location - maximumCharacters / 2)
        // Search backward only within the grapheme containing this UTF-16
        // position. Conversion to a String index requires a Character boundary;
        // no whole-document Character scan or NSString copy is needed.
        var position = text.utf16.index(text.utf16.startIndex, offsetBy: offset)
        while String.Index(position, within: text) == nil {
            text.utf16.formIndex(before: &position)
        }
        let boundary = String.Index(position, within: text)!
        return String(text[boundary...].prefix(maximumCharacters))
    }
}
