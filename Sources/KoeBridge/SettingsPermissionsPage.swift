#if os(macOS)
import AVFoundation
import SwiftUI
import KoeBridgeCore

/// Permission refresh feedback is transient and is cleared when this page closes.
struct SettingsPermissionsPage: View {
    @ObservedObject var guide: PermissionGuide
    @Environment(\.colorScheme) private var colorScheme
    @State private var permissionRefreshFeedback: SettingsPermissionRefreshFeedback = .idle
    @State private var permissionRefreshSequence = 0
    let focusRequest: SettingsFocusRequest?
    let showPermissions: () -> Void

    var body: some View {
        SettingsPageScrollView(section: .permissions, focusRequest: focusRequest) {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(spacing: 0) {
                        permissionRow("入力先へのアクセスを許可",
                                      description: "文字を入力する場所を確認し、意図しない入力を防ぐために必要です。macOSのアクセシビリティ機能を利用します。",
                                      icon: "hand.raised.fill",
                                      status: guide.accessibilityGranted ? .granted : .needsReview,
                                      canRequest: !guide.accessibilityGranted) {
                            guide.requestAccessibility()
                        }
                        .id("accessibility")
                        Divider()
                        permissionRow("文字の入力操作を許可",
                                      description: "認識した文章を、ほかのアプリへキーボード入力として送信するために必要です。",
                                      icon: "keyboard.fill",
                                      status: guide.postEventGranted ? .granted
                                          : (guide.accessibilityGranted ? .needsReview : .prerequisite),
                                      canRequest: !guide.postEventGranted && guide.accessibilityGranted) {
                            guide.requestPostEvent()
                        }
                        .id("post")
                        Divider()
                        permissionRow("マイクの使用を許可",
                                      description: "音声を録音して文字起こしするために必要です。音声は選択した認識方法に従って処理されます。",
                                      icon: "mic.fill",
                                      status: guide.microphoneStatus == .authorized ? .granted
                                          : (guide.microphoneStatus == .denied ? .denied
                                             : (guide.microphoneStatus == .restricted ? .restricted : .needsReview)),
                                      canRequest: guide.microphoneStatus != .authorized && !guide.microphoneRequestInProgress,
                                      buttonTitle: guide.microphoneStatus == .notDetermined
                                          ? "許可を求める" : "対処方法") {
                            guide.requestMicrophone()
                        }
                        .id("microphone")
                    }
                    .padding(8)
                } label: {
                    Label("アプリの利用許可", systemImage: "checkmark.shield")
                }
                if !guide.message.isEmpty {
                    Label {
                        Text(guide.message)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                    }
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colorScheme == .dark ? Color.white.opacity(0.09) : Color.blue.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 10))
                }
                GroupBox {
                    VStack(spacing: 0) {
                        SettingsRow("許可状態を再確認",
                                    description: "macOSで変更した許可状態を読み直します。",
                                    icon: "arrow.clockwise") {
                            HStack(spacing: 10) {
                                SettingsRowActionButton("再確認") {
                                    refreshPermissionStatus()
                                }
                                .disabled(permissionRefreshFeedback == .refreshing)
                                .accessibilityHint("macOSの現在の許可状態を読み直し、結果を横に表示します")
                                if permissionRefreshFeedback == .refreshing {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("確認中…")
                                    }
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("許可状態を確認中")
                                } else if permissionRefreshFeedback != .idle {
                                    Label(permissionRefreshFeedback.text,
                                          systemImage: permissionRefreshFeedback.symbol)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.green)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .accessibilityLabel("許可状態の確認結果：\(permissionRefreshFeedback.text)")
                                        .accessibilityAddTraits(.updatesFrequently)
                                }
                            }
                        }
                        Divider()
                        SettingsRow("利用許可の案内を開く",
                                    description: "必要な許可と設定方法をまとめて確認できます。",
                                    icon: "questionmark.circle") {
                            SettingsRowActionButton("案内を開く") { showPermissions() }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("許可の操作", systemImage: "arrow.clockwise")
                }
                Text("一度拒否した許可は、再要求してもダイアログが表示されない場合があります。macOSのシステム設定「プライバシーとセキュリティ」で確認してください。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { guide.refresh() }
        .onDisappear {
            permissionRefreshSequence += 1
            permissionRefreshFeedback = .idle
        }
    }

    private var permissionSnapshot: PermissionStateSnapshot {
        PermissionStateSnapshot(
            accessibilityGranted: guide.accessibilityGranted,
            postEventGranted: guide.postEventGranted,
            microphoneStatusRaw: guide.microphoneStatus.rawValue
        )
    }

    /// OS permission checks are synchronous. Show a short inline result
    /// without claiming that a permission was newly granted.
    private func refreshPermissionStatus() {
        let before = permissionSnapshot
        permissionRefreshSequence += 1
        let sequence = permissionRefreshSequence
        permissionRefreshFeedback = .refreshing
        Task { @MainActor in
            await Task.yield()
            guard permissionRefreshSequence == sequence else { return }
            guide.refreshFromSettings()
            let result = SettingsUXPolicy.refreshResult(before: before, after: permissionSnapshot)
            permissionRefreshFeedback = result == .changed ? .changed : .unchanged
            try? await Task.sleep(for: .seconds(3))
            if permissionRefreshSequence == sequence {
                permissionRefreshFeedback = .idle
            }
        }
    }

    private func permissionRow(
        _ title: String, description: String, icon: String,
        status: SettingsPermissionDisplayState, canRequest: Bool,
        buttonTitle: String = "許可を求める",
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 9) {
                SettingsPermissionStatusBadge(status: status)
                if status == .granted {
                    Text("操作不要")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if status == .prerequisite {
                    Text("上の許可を先に設定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    SettingsRowActionButton(buttonTitle, action: action)
                        .disabled(!canRequest)
                }
            }
            .frame(minWidth: 138, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 93, alignment: .center)
        .padding(.vertical, 7)
    }
}
#endif
