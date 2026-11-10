#if os(macOS)
import SwiftUI
import KoeBridgeCore

/// Delimited section on the Voice page; drafts persist in place like other settings.
struct SettingsSnippetsPage: View {
    @ObservedObject var controller: VoiceController
    @State private var editedRule: UUID?
    @FocusState private var focusedTrigger: UUID?

    private func append(_ token: String) {
        let id = editedRule ?? controller.snippets.first?.id
        guard let index = controller.snippets.firstIndex(where: { $0.id == id }) else { return }
        controller.snippets[index].template += token
        editedRule = id
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if controller.snippets.isEmpty {
                    Text("例：「メール締め」と言うと署名入りの定型文が入ります。")
                        .foregroundStyle(.secondary)
                }
                ForEach($controller.snippets) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(rule.trigger.isEmpty ? "呼び出す言葉" : rule.trigger) → \(rule.template)")
                                .lineLimit(1).font(.callout)
                            Spacer()
                            Button(role: .destructive) {
                                controller.snippets.removeAll { $0.id == rule.id }
                                if editedRule == rule.id { editedRule = controller.snippets.first?.id }
                            } label: { Image(systemName: "trash") }
                            .help("このスニペットを削除")
                            .accessibilityLabel("スニペットを削除")
                        }
                        TextField("呼び出す言葉（例：メール締め）", text: $rule.trigger)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedTrigger, equals: rule.id)
                            .onChange(of: rule.trigger) { _, _ in editedRule = rule.id }
                        Text("挿入する定型文").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $rule.template)
                            .font(.body)
                            .frame(minHeight: 72, maxHeight: 120)
                            .border(Color.secondary.opacity(0.25))
                            .accessibilityLabel("挿入する定型文")
                            .onChange(of: rule.template) { _, _ in editedRule = rule.id }
                            .simultaneousGesture(TapGesture().onEnded { editedRule = rule.id })
                        Divider()
                    }
                }
                Button {
                    let rule = SnippetRule(trigger: "", template: "")
                    controller.snippets.append(rule)
                    editedRule = rule.id
                    DispatchQueue.main.async { focusedTrigger = rule.id }
                } label: { Label("スニペットを追加", systemImage: "plus") }
                Text("最後に編集した定型文へ挿入（未編集なら先頭の定型文）")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("日付 {{DATE}}") { append("{{DATE}}") }
                    Button("時刻 {{TIME}}") { append("{{TIME}}") }
                    Button("クリップボード {{CLIPBOARD}}") { append("{{CLIPBOARD}}") }
                }
                .font(.caption)
                .disabled(controller.snippets.isEmpty)
                Text("AIを使わず、このMac内で決まった規則に従い、自動入力の直前に置き換えます。{{CLIPBOARD}} は、その定型文が実際に展開される瞬間だけクリップボードを読みます。空の呼び出し語は無視します。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("スニペット", systemImage: "text.badge.plus")
        }
    }
}
#endif
