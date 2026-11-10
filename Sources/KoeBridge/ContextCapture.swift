#if os(macOS)
import AppKit
import KoeBridgeCore

struct CapturedContext {
    var appName: String?
    var selectedText: String?
    var surroundingText: String?

    var fields: String {
        [(appName != nil ? "app" : nil), (selectedText != nil ? "selection" : nil),
         (surroundingText != nil ? "surrounding" : nil)].compactMap { $0 }.joined(separator: ",")
    }
    var prompt: String? {
        let parts = [appName.map { "アプリ名: \($0)" },
                     selectedText.map { "選択テキスト: \($0)" },
                     surroundingText.map { "周辺テキスト: \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

@MainActor enum ContextCapture {
    static func capture(target: InsertionTarget?, app: Bool, selection: Bool,
                        surrounding: Bool) -> CapturedContext {
        CapturedContext(
            appName: app ? (target.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.localizedName }
                ?? NSWorkspace.shared.frontmostApplication?.localizedName).map(ContextTextPolicy.selected) : nil,
            selectedText: selection ? target?.selectedContextText().map(ContextTextPolicy.selected) : nil,
            surroundingText: surrounding ? target?.textSnapshot.map {
                ContextTextPolicy.surrounding($0.text, selection: $0.selection)
            } : nil)
    }
}
#endif
