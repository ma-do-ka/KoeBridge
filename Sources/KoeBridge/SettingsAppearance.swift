import SwiftUI
import KoeBridgeCore

// Presentation-only metadata for the eight real settings pages.
// Do not put persisted configuration or microphone state in this file.
extension SettingsSection {
    var iconTint: Color {
        switch self {
        case .general: return Color(red: 0.53, green: 0.55, blue: 0.60)
        case .voice: return Color(red: 0.06, green: 0.61, blue: 0.99)
        case .gemini: return Color(red: 0.56, green: 0.31, blue: 0.99)
        case .usage: return Color(red: 0.16, green: 0.78, blue: 0.36)
        case .history: return Color(red: 0.08, green: 0.73, blue: 0.81)
        case .permissions: return Color(red: 0.95, green: 0.27, blue: 0.33)
        case .help: return Color(red: 0.98, green: 0.58, blue: 0.17)
        case .about: return Color(red: 0.43, green: 0.36, blue: 0.94)
        }
    }

    var pageDescription: String {
        switch self {
        case .general: return "現在の利用状態と、よく使う設定への入口です。"
        case .voice: return "話した内容を文字に変換し、元の入力欄への入力を試みます。"
        case .gemini: return "Geminiを使うための接続情報と文字起こし方法を設定します。Appleの音声認識には適用されません。"
        case .usage: return "GeminiとAppleの使用回数、処理した音声の長さ、APIの利用状況を確認できます。"
        case .history: return "文字起こし履歴の確認と、不具合調査用の動作記録を管理します。"
        case .permissions: return "録音と文字入力に必要なmacOSの許可状態を確認します。許可はmacOSが管理します。"
        case .help: return "使い方と、うまく動作しないときの確認先です。"
        case .about: return "KoeBridgeのバージョンと公開ソースコードです。"
        }
    }
}

/// A single reusable rounded colorful SF Symbol tile. The adjacent text
/// provides the accessibility name, so the icon is deliberately decorative.
struct SettingsCategoryIcon: View {
    let section: SettingsSection
    let size: CGFloat

    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(section.iconTint.gradient,
                        in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.8)
            }
            .accessibilityHidden(true)
    }
}

/// Separate the dark window background from the raised interactive cards.
/// GroupBox content and original bindings remain unchanged.
struct ContrastSettingsGroupBoxStyle: GroupBoxStyle {
    let dark: Bool

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .padding(.leading, 8)

            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    dark
                        ? Color(red: 0.205, green: 0.208, blue: 0.237)
                        : Color.white,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(dark ? Color.white.opacity(0.09)
                                           : Color.black.opacity(0.08), lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// Use a native visible scroll indicator where the OS permits it, plus an
/// independent bottom affordance while more content remains below the fold.
struct SettingsIndicatedScrollView<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasMoreBelow = false
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content
        }
        .scrollIndicators(.visible)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            SettingsUXPolicy.hasMoreBelow(
                contentHeight: Double(geometry.contentSize.height),
                viewportHeight: Double(geometry.containerSize.height),
                offsetY: Double(geometry.contentOffset.y)
            )
        } action: { _, hasMore in
            if reduceMotion {
                hasMoreBelow = hasMore
            } else {
                withAnimation(.easeOut(duration: 0.16)) {
                    hasMoreBelow = hasMore
                }
            }
        }
        .overlay(alignment: .bottom) {
            if hasMoreBelow {
                ZStack(alignment: .bottomTrailing) {
                    LinearGradient(
                        colors: [.clear, (colorScheme == .dark ? Color.black : Color.white).opacity(0.20)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 52)
                    Label("下に続きがあります", systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.trailing, 22)
                        .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("下に続きがあります。スクロールして表示できます。")
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}

/// Standardize the right-hand actions without affecting sidebar or back buttons.
struct SettingsRowActionButton: View {
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void

    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 103, minHeight: 26)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

enum SettingsPermissionDisplayState: Equatable {
    case granted
    case needsReview
    case prerequisite
    case denied
    case restricted

    var text: String {
        switch self {
        case .granted: return "許可済み"
        case .needsReview: return "要確認"
        case .prerequisite: return "先に設定"
        case .denied: return "設定で変更"
        case .restricted: return "利用制限"
        }
    }

    var symbol: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .needsReview: return "exclamationmark.circle.fill"
        case .prerequisite: return "arrow.turn.down.right"
        case .denied, .restricted: return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .granted: return .green
        case .needsReview: return .orange
        case .prerequisite: return .secondary
        case .denied, .restricted: return .red
        }
    }
}

struct SettingsPermissionStatusBadge: View {
    let status: SettingsPermissionDisplayState

    var body: some View {
        Label(status.text, systemImage: status.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status.tint.opacity(0.12), in: Capsule())
            .accessibilityLabel("現在の許可状態：\(status.text)")
    }
}

enum SettingsPermissionRefreshFeedback: Equatable {
    case idle
    case refreshing
    case changed
    case unchanged

    var text: String {
        switch self {
        case .idle: return ""
        case .refreshing: return "確認中…"
        case .changed: return "更新完了"
        case .unchanged: return "変更なし"
        }
    }

    var symbol: String {
        switch self {
        case .idle, .refreshing: return "arrow.clockwise"
        case .changed, .unchanged: return "checkmark.circle.fill"
        }
    }
}
