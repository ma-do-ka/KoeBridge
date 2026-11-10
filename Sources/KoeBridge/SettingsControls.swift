#if os(macOS)
import SwiftUI
import KoeBridgeCore

/// Search and menu requests carry their own identity, including repeated jumps
/// to the same setting. A page never responds to another section's anchor.
struct SettingsPageScrollView<Content: View>: View {
    let section: SettingsSection
    let focusRequest: SettingsFocusRequest?
    private let content: Content

    init(section: SettingsSection, focusRequest: SettingsFocusRequest?,
         @ViewBuilder content: () -> Content) {
        self.section = section
        self.focusRequest = focusRequest
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            SettingsIndicatedScrollView { content.environment(\.settingsFocusRequest, focusRequest) }
                .task(id: focusRequest) {
                    await Task.yield() // Let the selected page lay out its anchor tree first.
                    guard !Task.isCancelled else { return }
                    scrollToRequestedSetting(using: proxy)
                }
        }
    }

    private func scrollToRequestedSetting(using proxy: ScrollViewProxy) {
        guard let focusRequest, focusRequest.section == section else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(focusRequest.id, anchor: .top)
        }
    }
}


private struct SettingsFocusRequestKey: EnvironmentKey {
    static let defaultValue: SettingsFocusRequest? = nil
}
extension EnvironmentValues {
    var settingsFocusRequest: SettingsFocusRequest? {
        get { self[SettingsFocusRequestKey.self] }
        set { self[SettingsFocusRequestKey.self] = newValue }
    }
}

private struct SettingsTarget: ViewModifier {
    let id: String
    @Environment(\.settingsFocusRequest) private var request
    @State private var highlighted = false
    func body(content: Content) -> some View {
        content.id(id)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(highlighted ? 0.8 : 0), lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .task(id: request) {
                highlighted = false
                guard request?.id == id else { return }
                do {
                    try await Task.sleep(for: .milliseconds(220))
                    highlighted = true
                    try await Task.sleep(for: .seconds(1.4))
                    withAnimation { highlighted = false }
                } catch { highlighted = false }
            }
    }
}

/// Apply to the first actual interactive control, separately from the card anchor.
private struct SettingsControlFocus: ViewModifier {
    let ids: [String]
    @Environment(\.settingsFocusRequest) private var request
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused)
            .task(id: request) {
                guard let request, ids.contains(request.id) else { return }
                do {
                    try await Task.sleep(for: .milliseconds(240))
                    focused = true
                } catch { }
            }
    }
}
extension View {
    func settingsTarget(_ id: String) -> some View { modifier(SettingsTarget(id: id)) }
    func settingsControlFocus(_ ids: String...) -> some View { modifier(SettingsControlFocus(ids: ids)) }
    func settingsControlFocus(ids: [String]) -> some View { modifier(SettingsControlFocus(ids: ids)) }
}

/// Each setting has a plain-language label and a short secondary explanation.
struct SettingsRow<Accessory: View>: View {
    let title: String
    let description: String
    let icon: String?
    private let accessory: Accessory

    init(_ title: String, description: String, icon: String? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.description = description
        self.icon = icon
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            } else {
                Color.clear
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
                .frame(minWidth: 126, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
        .padding(.vertical, 7)
    }
}

/// Both the overview and detailed pages use the same choices and bindings.
/// Width, presentation style and accessibility wording remain page-specific.
struct SettingsRecognitionPicker: View {
    let title: String
    @Binding var selection: RecognitionMode

    init(_ title: String, selection: Binding<RecognitionMode>) {
        self.title = title
        self._selection = selection
    }

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Gemini API").tag(RecognitionMode.gemini)
            Text("Apple（Mac内）").tag(RecognitionMode.local)
        }
        .labelsHidden()
    }
}

struct SettingsShortcutPicker: View {
    let title: String
    @Binding var selection: RecordingShortcut

    init(_ title: String, selection: Binding<RecordingShortcut>) {
        self.title = title
        self._selection = selection
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(RecordingShortcut.allCases) { shortcut in
                Text(shortcut.label).tag(shortcut)
            }
        }
        .labelsHidden()
    }
}

struct SettingsTranscriptionStylePicker: View {
    let title: String
    @Binding var selection: TranscriptionStyle

    init(_ title: String, selection: Binding<TranscriptionStyle>) {
        self.title = title
        self._selection = selection
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(TranscriptionStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        }
        .labelsHidden()
    }
}
#endif
