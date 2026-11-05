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
