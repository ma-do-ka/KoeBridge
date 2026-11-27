#if os(macOS)
import AppKit
import AVFoundation
import SwiftUI
import KoeBridgeCore

/// All popover actions, disclosure and engine selection use SwiftUI Buttons;
/// no AppKit segmented picker or switch bypasses this first-mouse boundary.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension Notification.Name {
    static let settingsDestinationRequested = Notification.Name("KoeBridge.settingsDestinationRequested")
}
@MainActor enum SettingsDestination {
    static var pending: String?
}

enum StatusPopoverPermissionCardPolicy {
    static func suppressesMicrophoneWarning(noticeState: MicrophoneNoticeState?) -> Bool {
        noticeState == .permissionDenied
    }

    static func needsAttention(noticeState: MicrophoneNoticeState?, automationGranted: Bool,
                               guideNeedsAttention: Bool) -> Bool {
        suppressesMicrophoneWarning(noticeState: noticeState) ? !automationGranted : guideNeedsAttention
    }

    static func title(noticeState: MicrophoneNoticeState?, automationGranted: Bool,
                      guideNeedsAttention: Bool) -> String {
        let attentionNeeded = needsAttention(noticeState: noticeState, automationGranted: automationGranted,
                                             guideNeedsAttention: guideNeedsAttention)
        if suppressesMicrophoneWarning(noticeState: noticeState) && !attentionNeeded {
            return "自動入力の権限は正常"
        }
        return attentionNeeded ? "権限の確認が必要です" : "権限はすべて正常"
    }
}

private struct HistoryMenuButtonStyle: ButtonStyle {
    let highlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        let selected = highlighted || configuration.isPressed
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? Color(nsColor: .selectedMenuItemTextColor) : .primary)
            .background(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }
}

@MainActor struct StatusPopoverView: View {
    @ObservedObject var controller: VoiceController
    @ObservedObject var guide: PermissionGuide
    let historyMenu: RecentHistoryMenuState
    let onOpenSettings: () -> Void
    let onOpenMicrophoneSettings: () -> Void
    let onOpenSoundSettings: () -> Void
    let onOpenSystemMicrophoneSettings: () -> Void
    let onRestartApplication: () -> Void
    let onOpenHistory: () -> Void
    let onOpenPermissions: () -> Void
    let onOpenUsage: () -> Void
    let onCheckForUpdates: () -> Void
    let onQuit: () -> Void
    let onToggleRecording: () -> Void
    let onToggleMeeting: () -> Void
    let onDiscard: () -> Void
    let onCopyRecord: (UUID) -> Void
    let onInsertRecord: (TranscriptRecord) -> Void
    let onHoverRecord: (TranscriptRecord, NSRect, NSWindow) -> Void
    let onLeaveRecord: (UUID) -> Void
    let onHideHistoryPreview: () -> Void
    let onContentSizeChange: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let notice = controller.microphoneNotice {
                microphoneNoticeBanner(notice)
            }
            VStack(spacing: 5) {
                Button(action: onToggleRecording) {
                    VStack(spacing: 3) {
                        Text(controller.isRecording ? "■ 音声入力を確定" : "● 音声入力を開始")
                            .fontWeight(.semibold)
                        Text(controller.shortcutChoice.label).font(.caption2)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(PopoverButtonStyle(appearance: .prominent))
                if controller.busy && controller.isRecording {
                    Button("録音を破棄", action: onDiscard).font(.caption).foregroundStyle(.secondary)
                        .buttonStyle(PopoverButtonStyle())
                }
            }
            if controller.lastTextOperationOutput != nil && !controller.textOperationRunning {
                Button("途中までの変換結果をコピー") { controller.copyTextOperationOutput() }
                    .font(.caption).buttonStyle(PopoverButtonStyle(appearance: .bordered))
            }
            if controller.meetingModeEnabled || controller.meetingRunning {
                Button(controller.meetingRunning ? "会議モードを停止" : "会議モードを開始") {
                    onToggleMeeting()
                }.buttonStyle(PopoverButtonStyle(appearance: .bordered))
                    .disabled(!controller.meetingRunning && !controller.canStartMeeting)
                if !controller.meetingStatus.isEmpty {
                    Text(controller.meetingStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(action: onOpenUsage) { usageCard }.buttonStyle(PopoverButtonStyle())
            Button(action: onOpenPermissions) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(permissionCardTitle,
                          systemImage: permissionCardNeedsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(permissionCardNeedsAttention ? Color.orange : Color.green)
                    HStack {
                        if permissionCardMicrophoneWarningSuppressed {
                            permissionLabel("自動入力", granted: permissionCardAutomationGranted)
                            Spacer()
                        } else {
                            permissionLabel("マイク", granted: guide.microphoneStatus == .authorized)
                            Spacer()
                            permissionLabel("自動入力", granted: permissionCardAutomationGranted)
                        }
                    }.font(.caption2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(permissionCardNeedsAttention ? Color.orange.opacity(0.14) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(PopoverButtonStyle())
            Divider()
            Button {
                historyMenu.isExpanded.toggle()
                if !historyMenu.isExpanded { onHideHistoryPreview() }
            } label: {
                HStack {
                    Text("認識履歴（直近\(RecentHistoryMenuPolicy.maximumDisplayedRecords)件）")
                    Spacer()
                    Image(systemName: historyMenu.isExpanded ? "chevron.down" : "chevron.right")
                }
            }.buttonStyle(HistoryMenuButtonStyle(highlighted: historyMenu.hovered == .header))
                .onHover { inside in
                    if inside { historyMenu.hovered = .header }
                    else if historyMenu.hovered == .header { historyMenu.hovered = nil }
                }
            if historyMenu.isExpanded {
                let entries = RecentHistoryMenuPolicy.entries(from: controller.history)
                if entries.isEmpty {
                    Text(controller.historyProblem.isEmpty ? "保存された認識履歴はありません" : "履歴を読み込めません")
                        .font(.caption).foregroundStyle(.secondary).disabled(true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(entries, id: \.recordID) { entry in
                                let row = RecentHistoryMenuState.Row.record(entry.recordID)
                                Button {
                                    onCopyRecord(entry.recordID)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundStyle(historyMenu.hovered == row ? Color(nsColor: .selectedMenuItemTextColor) : .secondary)
                                        Text(controller.isHistorySaved(entry.recordID) ? entry.preview : "未保存・" + entry.preview).font(.caption).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(HistoryMenuButtonStyle(highlighted: historyMenu.hovered == row)).help(entry.copyHelp)
                                    .background(HistoryHoverAnchor(
                                        onEnter: { rect, window in
                                            if let record = controller.history.first(where: { $0.id == entry.recordID }) {
                                                historyMenu.hovered = row
                                                onHoverRecord(record, rect, window)
                                            }
                                        }, onExit: {
                                            if historyMenu.hovered == row { historyMenu.hovered = nil }
                                            onLeaveRecord(entry.recordID)
                                        }))
                                    .accessibilityAction(named: "入力する") {
                                        if let record = controller.history.first(where: { $0.id == entry.recordID }) {
                                            onInsertRecord(record)
                                        }
                                    }
                            }
                        }
                    }.frame(height: min(CGFloat(entries.count) * 46, 230))
                }
                Button("履歴をすべて表示…", action: onOpenHistory).font(.caption)
                    .buttonStyle(PopoverButtonStyle(appearance: .bordered))
            }
            Divider()
            HStack {
                Button("設定…", action: onOpenSettings)
                Button("アップデート…", action: onCheckForUpdates)
                Button("終了", action: onQuit)
            }.font(.caption).buttonStyle(PopoverButtonStyle()).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 348).fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { onContentSizeChange(geometry.size) }
                    .onChange(of: geometry.size) { _, size in onContentSizeChange(size) }
            }
        }
    }

    private var permissionCardAutomationGranted: Bool {
        guide.accessibilityGranted && guide.postEventGranted
    }

    private var permissionCardMicrophoneWarningSuppressed: Bool {
        StatusPopoverPermissionCardPolicy.suppressesMicrophoneWarning(noticeState: controller.microphoneNotice?.state)
    }

    private var permissionCardNeedsAttention: Bool {
        StatusPopoverPermissionCardPolicy.needsAttention(
            noticeState: controller.microphoneNotice?.state,
            automationGranted: permissionCardAutomationGranted,
            guideNeedsAttention: guide.needsAttention)
    }

    private var permissionCardTitle: String {
        StatusPopoverPermissionCardPolicy.title(
            noticeState: controller.microphoneNotice?.state,
            automationGranted: permissionCardAutomationGranted,
            guideNeedsAttention: guide.needsAttention)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Group {
                    if let icon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "waveform").resizable().scaledToFit().padding(7)
                    }
                }.frame(width: 36, height: 36)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Text("KoeBridge").fontWeight(.semibold)
                Spacer(minLength: 4)
                Circle().fill(headerStatusColor).frame(width: 6, height: 6)
                Text(controller.status).font(.caption2).lineLimit(2)
            }
            // Three explicit engine buttons avoid nested AppKit menu tracking.
            HStack(spacing: 6) {
                ForEach(RecognitionMode.allCases) { mode in
                    Button { controller.requestedMode = mode } label: {
                        Text(mode.shortLabel)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(controller.requestedMode == mode ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(PopoverButtonStyle(appearance: .bordered, selected: controller.requestedMode == mode))
                    .tint(controller.requestedMode == mode ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(mode.label)
                    .accessibilityAddTraits(controller.requestedMode == mode ? [.isSelected] : [])
                }
            }
            Text(controller.requestedMode.label).font(.caption2).foregroundStyle(.secondary)
        }
    }


    private var headerStatusColor: Color {
        if controller.isRecording { return .red }
        guard let state = controller.microphoneNotice?.state else { return .green }
        return state.severity == .critical ? .red : .orange
    }

    private func performNoticeAction(_ action: MicrophoneNoticeAction) {
        switch action {
        case .restartApplication: onRestartApplication()
        case .openSystemSettings: onOpenSystemMicrophoneSettings()
        case .openMicrophoneSettings: onOpenMicrophoneSettings()
        case .openSoundSettings: onOpenSoundSettings()
        case .retryRecording: onToggleRecording()
        case .dismiss: controller.dismissMicrophoneNotice()
        }
    }

    private func microphoneNoticeBanner(_ notice: MicrophoneNotice) -> some View {
        let color: Color = notice.state.severity == .critical ? .red : .orange
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: notice.state.severity == .critical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(color)
                    .accessibilityLabel(notice.state.severity == .critical ? "重大" : "警告")
                VStack(alignment: .leading, spacing: 3) {
                    Text(notice.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(notice.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button(notice.primaryAction.title) { performNoticeAction(notice.primaryAction) }
                    .font(.caption)
                    .buttonStyle(PopoverButtonStyle(appearance: .bordered))
                if let secondary = notice.secondaryAction {
                    Button(secondary.title) { performNoticeAction(secondary) }
                        .font(.caption)
                        .buttonStyle(PopoverButtonStyle(appearance: .bordered))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private struct WeekKey: Equatable {
        let revision: UInt64
        let calendar: Calendar
        let day: Date
    }
    @State private var weekCache = DisplayCache<WeekKey, [UsageSummary.DayTotal]>()

    private var usageCard: some View {
        let now = Date()
        let calendar = Calendar.current
        let key = WeekKey(revision: controller.usageRevision, calendar: calendar, day: calendar.startOfDay(for: now))
        let days = weekCache.value(for: key) {
            UsageSummary.dailyTotals(events: controller.monitorEvents, days: 7, now: now, calendar: calendar)
        }
        let today = days[6]
        let maximum = max(days.map(\.totalSeconds).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("今日の利用").font(.caption).fontWeight(.semibold)
            HStack {
                stat("\(today.takes)", caption: "回")
                Spacer()
                stat(String(format: "%.0f", today.totalSeconds / 60), caption: "音声分")
                Spacer()
                stat(String(format: "%.1f", today.amiVoiceSeconds / 60), caption: "AmiVoice分")
                Spacer()
                stat(String(format: "$%.2f", UsageSummary.estimatedCostUSD(geminiSeconds: today.geminiSeconds)), caption: "Gemini推定")
            }
            if controller.monitorEvents.isEmpty {
                Text("まだ利用記録がありません").font(.caption2).foregroundStyle(.secondary)
            }
            if today.amiVoiceSeconds > 0 {
                Text("AmiVoice分は送信した音声の時間です。無料枠の消費はVAD発話秒数で計上されます。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(days, id: \.dayStart) { day in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(day.dayStart == today.dayStart ? 1 : 0.85))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(2, 30 * day.totalSeconds / maximum))
                            .accessibilityLabel("\(day.dayStart.formatted(date: .abbreviated, time: .omitted)): \(day.totalSeconds / 60)分")
                    }
                }.frame(height: 30)
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func permissionLabel(_ title: String, granted: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(granted ? Color.green : Color.orange).frame(width: 5, height: 5)
            Text(title).foregroundStyle(.secondary)
        }
    }
}
#endif
