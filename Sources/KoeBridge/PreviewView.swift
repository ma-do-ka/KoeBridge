#if os(macOS)
import Foundation
import SwiftUI
import KoeBridgeCore

/// A minimal non-interactive floating transcription capsule.
/// Status, commands, diagnostics and history are intentionally available only
/// from the menu bar / Settings, never on the dictation overlay itself.
struct PreviewView: View {
    @ObservedObject var controller: VoiceController

    private var visibleTranscript: String {
        let stage = controller.overlayFeedback
        if stage == .transforming && controller.textOperationRunning { return controller.status }
        guard stage == .recording else { return stage.message }
        let full = controller.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return stage.message }
        return full.count > 180 ? "…" + String(full.suffix(180)) : full
    }

    private var styledTranscript: Text {
        guard controller.progressivePreviewEnabled,
              controller.overlayFeedback == .recording,
              !controller.previewText.allSatisfy({ $0.isWhitespace }) else {
            return Text(visibleTranscript)
        }
        // Trim and clip the combined text exactly as the single-style preview does,
        // while preserving the provider boundary within the visible suffix.
        let prefix = controller.previewFinalizedText
        let tail = controller.previewVolatileText
        let full = prefix + tail
        let leading = full.count - full.drop(while: { $0.isWhitespace }).count
        let trimmed = String(full.drop(while: { $0.isWhitespace })
            .reversed().drop(while: { $0.isWhitespace }).reversed())
        let skipped = leading + max(0, trimmed.count - 180)
        let visible = String(trimmed.suffix(180))
        let finalCount = min(visible.count, max(0, prefix.count - skipped))
        return Text(trimmed.count > 180 ? "…" : "")
            + Text(String(visible.prefix(finalCount)))
            + Text(String(visible.dropFirst(finalCount))).foregroundColor(.secondary)
    }

    private var feedbackSymbol: String {
        switch controller.overlayFeedback {
        case .hidden, .preparing: return "mic"
        case .recording: return "waveform"
        case .ending: return "stop.circle"
        case .processing, .checking, .transforming: return "ellipsis"
        case .noInput: return "mic.slash"
        case .sent: return "arrow.up.circle.fill"
        case .saved: return "clock.arrow.circlepath"
        case .heldForReview, .transformCopied: return "doc.on.clipboard"
        case .failed, .transformFailed: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(controller.isRecording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: 38, height: 38)
                if controller.overlayFeedback == .preparing || controller.overlayFeedback == .processing || controller.overlayFeedback == .checking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(controller.overlayFeedback == .preparing ? "マイクの接続準備中" : "文字起こしの確定処理中")
                } else {
                    Image(systemName: feedbackSymbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(controller.isRecording ? Color.red : Color.secondary)
                        .accessibilityHidden(true)
                }
            }
            styledTranscript
                .font(.system(size: 14, weight: .medium, design: .default))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(visibleTranscript)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.17), radius: 13, x: 0, y: 5)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}
#endif
