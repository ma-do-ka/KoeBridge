#if os(macOS)
import AppKit
import AVFoundation
import SwiftUI
import KoeBridgeCore

@MainActor struct StatusPopoverView: View {
    @ObservedObject var controller: VoiceController
    @ObservedObject var guide: PermissionGuide
    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void
    let onOpenPermissions: () -> Void
    let onCheckForUpdates: () -> Void
    let onQuit: () -> Void
    let onToggleRecording: () -> Void
    let onDiscard: () -> Void
    let onCopyRecord: (TranscriptRecord) -> Void
    @State private var historyExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(spacing: 5) {
                Button(action: onToggleRecording) {
                    VStack(spacing: 3) {
                        Text(controller.isRecording ? "■ 音声入力を確定" : "● 音声入力を開始")
                            .fontWeight(.semibold)
                        Text(controller.shortcutChoice.label).font(.caption2)
                    }.frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.borderedProminent)
                if controller.busy && controller.isRecording {
                    Button("録音を破棄", action: onDiscard).font(.caption).foregroundStyle(.secondary)
                }
            }
            if controller.lastTextOperationOutput != nil && !controller.textOperationRunning {
                Button("途中までの変換結果をコピー") { controller.copyTextOperationOutput() }
                    .font(.caption)
            }
            if controller.meetingModeEnabled || controller.meetingRunning {
                Button(controller.meetingRunning ? "会議モードを停止" : "会議モードを開始") {
                    controller.toggleMeeting()
                }.disabled(!controller.meetingRunning && !controller.canStartMeeting)
                if !controller.meetingStatus.isEmpty {
                    Text(controller.meetingStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            usageCard
            Button(action: onOpenPermissions) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(guide.needsAttention ? "権限の確認が必要です" : "権限はすべて正常",
                          systemImage: guide.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(guide.needsAttention ? Color.orange : Color.green)
                    HStack {
                        permissionLabel("マイク", granted: guide.microphoneStatus == .authorized)
                        Spacer()
                        permissionLabel("自動入力", granted: guide.accessibilityGranted && guide.postEventGranted)
                    }.font(.caption2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Divider()
            Button {
                historyExpanded.toggle()
            } label: {
                HStack {
                    Text("認識履歴（直近\(RecentHistoryMenuPolicy.maximumDisplayedRecords)件）")
                    Spacer()
                    Image(systemName: historyExpanded ? "chevron.down" : "chevron.right")
                }
            }.buttonStyle(.plain)
            if historyExpanded {
                let entries = RecentHistoryMenuPolicy.entries(from: controller.history)
                if entries.isEmpty {
                    Text(controller.historyProblem.isEmpty ? "保存された認識履歴はありません" : "履歴を読み込めません")
                        .font(.caption).foregroundStyle(.secondary).disabled(true)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(entries, id: \.recordID) { entry in
                                Button {
                                    if let record = controller.history.first(where: { $0.id == entry.recordID }) {
                                        onCopyRecord(record)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Text(entry.preview).font(.caption).lineLimit(1)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).help(entry.copyHelp)
                            }
                        }
                    }.frame(height: min(CGFloat(entries.count) * 42, 210))
                }
                Button("履歴をすべて表示…", action: onOpenHistory).font(.caption)
            }
            Divider()
            Button(action: onOpenSettings) {
                HStack { Text("設定…"); Spacer(); Text("⌘,").foregroundStyle(.secondary) }
            }.buttonStyle(.plain)
            Button("アップデートを確認…", action: onCheckForUpdates).buttonStyle(.plain)
            Divider()
            HStack {
                Button("マイク・自動入力の権限…", action: onOpenPermissions)
                Spacer()
                Button("終了", action: onQuit)
            }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 348).fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
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
                Circle().fill(controller.isRecording ? Color.red : Color.green).frame(width: 6, height: 6)
                Text(controller.status).font(.caption2).lineLimit(2)
            }
            // Two explicit engine buttons avoid nested AppKit menu tracking.
            HStack(spacing: 6) {
                ForEach(RecognitionMode.allCases) { mode in
                    Button { controller.requestedMode = mode } label: {
                        Text(mode == .gemini ? "Gemini" : "Apple")
                            .font(.caption).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(controller.requestedMode == mode ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(mode.label)
                    .accessibilityAddTraits(controller.requestedMode == mode ? [.isSelected] : [])
                }
            }
            Text(controller.requestedMode.label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var usageCard: some View {
        let now = Date()
        let today = UsageSummary.todayTotals(events: controller.monitorEvents, now: now)
        let days = UsageSummary.dailyTotals(events: controller.monitorEvents, days: 7, now: now)
        let maximum = max(days.map(\.totalSeconds).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            Text("今日の利用").font(.caption).fontWeight(.semibold)
            HStack {
                stat("\(today.takes)", caption: "回")
                Spacer()
                stat(String(format: "%.0f", today.totalSeconds / 60), caption: "音声分")
                Spacer()
                stat(String(format: "$%.2f", UsageSummary.estimatedCostUSD(geminiSeconds: today.geminiSeconds)), caption: "推定")
            }
            if controller.monitorEvents.isEmpty {
                Text("まだ利用記録がありません").font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(days, id: \.dayStart) { day in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(day.dayStart == today.dayStart ? 1 : 0.85))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(2, 30 * day.totalSeconds / maximum))
                            .accessibilityLabel("\(day.dayStart.formatted(date: .abbreviated, time: .omitted)): \(day.totalSeconds / 60)分")
                    }
                }.frame(height: 30)
            }
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
