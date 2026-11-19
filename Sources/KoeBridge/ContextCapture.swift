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
                        surrounding: Bool, reads: InsertionTarget.FocusReads = .init()) -> CapturedContext? {
        let access = InsertionTarget.ExternalTextAccess()
        let selected = selection ? target?.selectedContextText(externalText: access, reads: reads) : nil
        guard !access.refused else { return nil }
        let snapshot = surrounding ? target?.observedSnapshot(timeout: 0.04, externalText: access, reads: reads)?.snapshot : nil
        guard !access.refused else { return nil }
        return CapturedContext(
            appName: app ? (target.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.localizedName }
                ?? NSWorkspace.shared.frontmostApplication?.localizedName).map(ContextTextPolicy.selected) : nil,
            selectedText: selected.map(ContextTextPolicy.selected),
            surroundingText: snapshot.map {
                ContextTextPolicy.surrounding($0.text, selection: $0.selection)
            })
    }
}
#endif
