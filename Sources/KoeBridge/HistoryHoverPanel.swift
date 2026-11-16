#if os(macOS)
import AppKit
import SwiftUI
import KoeBridgeCore

/// Popover-only style: padding and empty layout space belong to the label's hit area.
struct PopoverButtonStyle: ButtonStyle {
    enum Appearance { case plain, bordered, prominent }
    var appearance: Appearance = .plain
    var selected = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if appearance == .prominent {
                configuration.label.foregroundStyle(.white)
            } else {
                configuration.label
            }
        }
            .frame(maxWidth: .infinity)
            .padding(.vertical, appearance == .plain ? 2 : 5)
            .padding(.horizontal, appearance == .plain ? 0 : 8)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if appearance == .bordered {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.3))
                }
            }
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.65 : 1)
    }

    private var background: Color {
        switch appearance {
        case .plain: .clear
        case .bordered: selected ? .accentColor.opacity(0.18) : .secondary.opacity(0.12)
        case .prominent: .accentColor
        }
    }
}

/// Tracks the entire row, with screen coordinates independent of SwiftUI layout spaces.
struct HistoryHoverAnchor: NSViewRepresentable {
    let onEnter: (NSRect, NSWindow) -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) {
        view.onEnter = onEnter
        view.onExit = onExit
    }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { view.onExit?() }

    final class TrackingView: NSView {
        var onEnter: ((NSRect, NSWindow) -> Void)?
        var onExit: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) {
            guard let window else { return }
            onEnter?(window.convertToScreen(convert(bounds, to: nil)), window)
        }
        override func mouseExited(with event: NSEvent) { onExit?() }
    }
}

/// Neither showing nor clicking this panel may make KoeBridge the input target.
final class HistoryPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class HistoryHoverPanelController {
    private var panel: HistoryPreviewPanel?
    private var recordID: UUID?
    private var rowHovered = false
    private var panelHovered = false
    private var dismissal: Task<Void, Never>?

    static func frame(anchor: NSRect, popover: NSRect, visible: NSRect) -> NSRect {
        let gap: CGFloat = 6
        let left = max(0, popover.minX - visible.minX - gap)
        let right = max(0, visible.maxX - popover.maxX - gap)
        let useRight = right >= left
        let width = min(360, max(left, right))
        let height = min(360, visible.height)
        let x = useRight ? popover.maxX + gap : popover.minX - gap - width
        let y = min(max(anchor.maxY - height, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func show(_ record: TranscriptRecord, anchor: NSRect, parent: NSWindow,
              onInsert: @escaping () -> Void, onCopy: @escaping () -> Void) {
        dismissal?.cancel()
        rowHovered = true
        let panel = panel ?? HistoryPreviewPanel(contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        let visible = (parent.screen ?? NSScreen.screens.first)?.visibleFrame ?? parent.frame
        panel.setFrame(Self.frame(anchor: anchor, popover: parent.frame, visible: visible), display: true)
        if recordID == record.id, panel.isVisible { return }
        recordID = record.id
        panelHovered = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = parent.level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FirstMouseHostingView(rootView: HistoryHoverContent(
            record: record, onInsert: onInsert, onCopy: onCopy,
            onHover: { [weak self] inside in
                guard let self else { return }
                self.panelHovered = inside
                if inside { self.dismissal?.cancel() } else { self.scheduleDismissal() }
            }))
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFrontRegardless() // No activate(), makeKey(), or focusable text controls.
    }

    func leave(_ id: UUID) {
        guard recordID == id else { return }
        rowHovered = false
        scheduleDismissal()
    }

    func contains(_ point: NSPoint) -> Bool {
        panel?.isVisible == true && panel?.frame.contains(point) == true
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        dismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, !self.rowHovered, !self.panelHovered else { return }
            self.hide()
        }
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        if let panel { panel.parent?.removeChildWindow(panel) }
        panel?.orderOut(nil)
        recordID = nil
        rowHovered = false
        panelHovered = false
    }
}

private struct HistoryHoverContent: View {
    let record: TranscriptRecord
    let onInsert: () -> Void
    let onCopy: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.recordedAt.formatted(date: .abbreviated, time: .standard))
                .font(.caption2).foregroundStyle(.secondary)
            ScrollView {
                Text(record.text).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            HStack {
                Button("入力する", action: onInsert)
                Button("コピー", action: onCopy)
            }.font(.caption).buttonStyle(PopoverButtonStyle(appearance: .bordered))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }
}
#endif
