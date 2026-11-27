#if os(macOS)
import SwiftUI
import KoeBridgeCore

struct SettingsBenchRecordingPage: View {
    @ObservedObject var controller: VoiceController
    @ObservedObject var coordinator: BenchRecordingCoordinator
    @ObservedObject private var microphones = MicrophoneDeviceStore.shared
    @ObservedObject private var nativeUpdater = KoeBridgeInAppUpdater.shared
    let focusRequest: SettingsFocusRequest?

    private var currentItem: BenchRecordingItem {
        coordinator.currentItem
    }

    private var currentProgress: BenchRecordingProgressStore.ItemProgress? {
        coordinator.progressStore.progress(for: currentItem.clipID)
    }

    private var recordButtonDisabled: Bool {
        if coordinator.state == .stopping { return true }
        if coordinator.state == .idle {
            return controller.busy || controller.phase != .idle || controller.meetingRunning || nativeUpdater.blocksRecording
        }
        return false
    }

    private var activeMicrophoneLabel: String {
        if microphones.selectedUID.isEmpty {
            return microphones.systemLabel
        }
        if let match = microphones.devices.first(where: { $0.uid == microphones.selectedUID }) {
            return match.name
        }
        return microphones.selectedDeviceMissing ? "選択したマイク（未接続）" : "選択中のマイク"
    }

    var body: some View {
        SettingsPageScrollView(section: .bench, focusRequest: focusRequest) {
            VStack(alignment: .leading, spacing: 18) {
                progressGroupBox
                    .settingsTarget("bench-recording")
                currentItemGroupBox
                itemListGroupBox
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            coordinator.reloadProgress()
            Task { await microphones.refresh() }
        }
    }

    private var progressGroupBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("録音済み: \(coordinator.recordedCount) / \(coordinator.totalCount)")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("マイク: \(activeMicrophoneLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(coordinator.recordedCount), total: Double(coordinator.totalCount))
                    .progressViewStyle(.linear)
                Text("この画面はベンチマーク用WAVファイル（PCM16LE / 16 kHz / モノラル）をローカル保存する開発ツールです。音声認識への送信、履歴記録、利用統計加算、自動入力は一切行いません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("保存先: ~/.cache/koebridge-bench/audio/（WAVと recording-progress.json）")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if coordinator.progressStore.loadOutcome == .recoveredFromCorrupt {
                    Label("進捗ファイル（~/.cache/koebridge-bench/audio/recording-progress.json）を読み込めなかったため空の状態で再開しました。既存のWAVファイルは削除していません。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
        } label: {
            Label("進捗と保存先", systemImage: "chart.bar.doc.horizontal")
        }
    }

    private var currentItemGroupBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(currentItem.sentence.id)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                    Text(currentItem.sentence.category.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("・")
                        .foregroundStyle(.secondary)
                    Text(currentItem.voice.promptLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(currentItem.voice == .whisper ? Color.indigo : Color.blue)
                    Text("（\(currentItem.repetition)回目）")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                    if let progress = currentProgress {
                        Label("録音済み（\(String(format: "%.2f", progress.duration))秒）",
                              systemImage: progress.isTooShort || progress.isTooLong ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(progress.isTooShort || progress.isTooLong ? Color.orange : Color.green)
                    }
                }

                Text(currentItem.sentence.referenceText)
                    .font(.system(size: 22, weight: .semibold))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 12) {
                    Button {
                        coordinator.toggleRecording()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: buttonSymbol)
                            Text(buttonTitle)
                                .fontWeight(.semibold)
                        }
                        .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(coordinator.state == .recording ? .red : .accentColor)
                    .controlSize(.large)
                    .disabled(recordButtonDisabled)
                    .settingsControlFocus("bench-recording")

                    if coordinator.state == .recording {
                        Label(String(format: "録音中 %.1f秒 / 60.0秒", coordinator.elapsedSeconds),
                              systemImage: "waveform")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.red)
                    } else if coordinator.state == .preparing {
                        ProgressView().controlSize(.small)
                        Text("マイクを準備しています…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if coordinator.state == .stopping {
                        ProgressView().controlSize(.small)
                        Text("WAVファイルを保存しています…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    if coordinator.state == .idle,
                       let next = coordinator.nextUnrecordedItem,
                       next.clipID != currentItem.clipID {
                        Button("次の未録音項目へ") {
                            coordinator.selectNextUnrecorded()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Text("クリップID: \(currentItem.fileName)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                if controller.busy || controller.phase != .idle || controller.meetingRunning || nativeUpdater.blocksRecording {
                    Text("通常の音声入力・会議モード・更新処理の実行中は録音できません。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let status = coordinator.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = coordinator.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if coordinator.recordedCount == coordinator.totalCount {
                    Label("48クリップすべて録音済みです。下のリストから任意の項目を選んで再録音できます。", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(8)
        } label: {
            Label(currentProgress == nil ? "次の未録音項目" : "選択中の項目（再録音で上書き）", systemImage: "text.bubble")
        }
    }

    private var itemListGroupBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(BenchRecordingGroup.all) { group in
                    let items = BenchRecordingItem.items(in: group)
                    let groupRecorded = items.filter { coordinator.progressStore.isRecorded($0.clipID) }.count
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(group.title)
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(groupRecorded) / \(items.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                        VStack(spacing: 4) {
                            ForEach(items) { item in
                                itemRow(item)
                            }
                        }
                    }
                    if group != BenchRecordingGroup.all.last {
                        Divider()
                    }
                }
            }
            .padding(8)
        } label: {
            Label("全48クリップ一覧", systemImage: "list.bullet.rectangle")
        }
    }

    private func itemRow(_ item: BenchRecordingItem) -> some View {
        let progress = coordinator.progressStore.progress(for: item.clipID)
        let isSelected = item.clipID == currentItem.clipID
        return Button {
            coordinator.select(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: rowStatusSymbol(progress))
                    .foregroundStyle(rowStatusColor(progress))
                    .frame(width: 18)
                Text(item.sentence.id)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .frame(width: 28, alignment: .leading)
                Text(item.sentence.referenceText)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let progress {
                    Text(String(format: "%.2f秒", progress.duration))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(progress.isTooShort || progress.isTooLong ? Color.orange : Color.secondary)
                    if progress.isTooShort {
                        Text("0.3秒未満")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else if progress.isTooLong {
                        Text("45秒超")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("未録音")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!coordinator.canSelectItem)
    }

    private var buttonTitle: String {
        switch coordinator.state {
        case .idle: return currentProgress == nil ? "録音開始" : "再録音"
        case .preparing: return "キャンセル"
        case .recording: return "停止"
        case .stopping: return "保存中…"
        }
    }

    private var buttonSymbol: String {
        switch coordinator.state {
        case .idle: return "record.circle"
        case .preparing: return "xmark.circle"
        case .recording: return "stop.circle.fill"
        case .stopping: return "hourglass"
        }
    }

    private func rowStatusSymbol(_ progress: BenchRecordingProgressStore.ItemProgress?) -> String {
        guard let progress else { return "circle" }
        return progress.isTooShort || progress.isTooLong ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private func rowStatusColor(_ progress: BenchRecordingProgressStore.ItemProgress?) -> Color {
        guard let progress else { return .secondary }
        return progress.isTooShort || progress.isTooLong ? .orange : .green
    }
}
#endif
