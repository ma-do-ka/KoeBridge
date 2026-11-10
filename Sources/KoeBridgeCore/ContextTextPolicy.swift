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
        let start = String.Index(utf16Offset: offset, in: text)
        // Round a possible surrogate/grapheme boundary down to a Character boundary.
        let boundary = text.indices.last(where: { $0 <= start }) ?? text.startIndex
        return String(text[boundary...].prefix(maximumCharacters))
    }
}
