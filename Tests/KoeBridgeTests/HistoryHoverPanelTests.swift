#if os(macOS)
import AppKit
import Testing
@testable import KoeBridge

@MainActor struct HistoryHoverPanelTests {
    @Test func previewCannotTakeKeyboardFocus() {
        let panel = HistoryPreviewPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test func placementChoosesRoomierSideAndStaysOnScreen() {
        // Includes a display left of the primary display and one above it.
        for visible in [NSRect(x: 0, y: 0, width: 1440, height: 900),
                        NSRect(x: -1280, y: 100, width: 1280, height: 800),
                        NSRect(x: 0, y: 900, width: 800, height: 600)] {
            for rightEdge in [false, true] {
                let popover = NSRect(x: rightEdge ? visible.maxX - 348 : visible.minX,
                                     y: visible.maxY - 500, width: 348, height: 500)
                for rowY in [visible.minY + 10, visible.maxY - 30] {
                    let anchor = NSRect(x: popover.minX + 16, y: rowY, width: 316, height: 35)
                    let frame = HistoryHoverPanelController.frame(anchor: anchor, popover: popover, visible: visible)
                    #expect(visible.contains(frame))
                    #expect(!frame.intersects(popover))
                    #expect(rightEdge ? frame.maxX < popover.minX : frame.minX > popover.maxX)
                }
            }
        }
    }

    @Test func narrowScreenReducesPanelWidth() {
        let visible = NSRect(x: 0, y: 0, width: 640, height: 480)
        let popover = NSRect(x: 140, y: 0, width: 348, height: 450)
        let frame = HistoryHoverPanelController.frame(anchor: popover, popover: popover, visible: visible)
        #expect(frame.width == 146)
        #expect(visible.contains(frame))
        #expect(!frame.intersects(popover))
    }
}
#endif
