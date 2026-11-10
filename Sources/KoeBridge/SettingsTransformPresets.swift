#if os(macOS)
import SwiftUI
import KoeBridgeCore

struct SettingsTransformPresets: View {
    @ObservedObject var controller: VoiceController
    @State private var editedStep: Int?
    @State private var editedPreset: UUID?

    private func movePreset(_ id: UUID, by offset: Int) {
        guard let index = controller.transformPresets.firstIndex(where: { $0.id == id }),
              controller.transformPresets.indices.contains(index + offset) else { return }
        controller.transformPresets.swapAt(index, index + offset)
    }

    private func insert(_ instruction: String) {
        let id = editedPreset ?? controller.selectedTransformPresetID ?? controller.transformPresets.first?.id
        guard let index = controller.transformPresets.firstIndex(where: { $0.id == id }) else { return }
        if let step = editedStep, controller.transformPresets[index].steps.indices.contains(step) {
            controller.transformPresets[index].steps[step] += instruction
        } else {
            controller.transformPresets[index].steps.append(instruction)
            editedStep = controller.transformPresets[index].steps.count - 1
        }
        editedPreset = id
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("変換キーの動作", selection: $controller.transformMode) {
                    Text("音声で指示").tag(TransformMode.spoken)
                    Text("プリセットを使う").tag(TransformMode.preset)
                }.pickerStyle(.segmented)
                Picker("実行するプリセット", selection: $controller.selectedTransformPresetID) {
                    Text("選択してください").tag(Optional<UUID>.none)
                    ForEach(controller.transformPresets) { preset in
                        Text(preset.name.isEmpty ? "名前未入力" : preset.name).tag(Optional(preset.id))
                    }
                }
                if controller.transformPresets.isEmpty {
                    Text("プリセットはありません。追加して、順番に実行する指示を入力してください。")
                        .foregroundStyle(.secondary)
                }
                ForEach($controller.transformPresets) { $preset in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("プリセット名", text: $preset.name).textFieldStyle(.roundedBorder)
                            Button { movePreset(preset.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(controller.transformPresets.first?.id == preset.id)
                                .help("プリセットを上へ移動").accessibilityLabel("プリセットを上へ移動")
                            Button { movePreset(preset.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(controller.transformPresets.last?.id == preset.id)
                                .help("プリセットを下へ移動").accessibilityLabel("プリセットを下へ移動")
                            Button(role: .destructive) {
                                controller.transformPresets.removeAll { $0.id == preset.id }
                                if controller.selectedTransformPresetID == preset.id { controller.selectedTransformPresetID = nil }
                                if editedPreset == preset.id { editedPreset = nil; editedStep = nil }
                            } label: { Image(systemName: "trash") }
                            .help("プリセットを削除").accessibilityLabel("プリセットを削除")
                        }
                        if preset.steps.isEmpty {
                            Text("ステップがありません。自由な言葉で指示を追加してください。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(preset.steps.indices, id: \.self) { index in
                            HStack {
                                Text("\(index + 1)").monospacedDigit()
                                TextField("変換の指示", text: $preset.steps[index])
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: preset.steps[index]) { _, _ in
                                        editedPreset = preset.id; editedStep = index
                                    }
                                    .simultaneousGesture(TapGesture().onEnded {
                                        editedPreset = preset.id; editedStep = index
                                    })
                                Button { preset.steps.swapAt(index, index - 1); editedStep = nil } label: { Image(systemName: "arrow.up") }
                                    .disabled(index == 0).help("ステップを上へ移動").accessibilityLabel("ステップを上へ移動")
                                Button { preset.steps.swapAt(index, index + 1); editedStep = nil } label: { Image(systemName: "arrow.down") }
                                    .disabled(index == preset.steps.count - 1).help("ステップを下へ移動").accessibilityLabel("ステップを下へ移動")
                                Button(role: .destructive) {
                                    preset.steps.remove(at: index); editedStep = nil
                                } label: { Image(systemName: "trash") }
                                .help("ステップを削除").accessibilityLabel("ステップを削除")
                            }
                        }
                        Button("ステップを追加") {
                            preset.steps.append("")
                            editedPreset = preset.id; editedStep = preset.steps.count - 1
                        }
                        if !preset.isValid {
                            Text("名前と1つ以上のステップを入力してください。空の指示は実行できません。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
                Button {
                    let preset = TransformPreset(name: "", steps: [""])
                    controller.transformPresets.append(preset)
                    controller.selectedTransformPresetID = preset.id
                    editedPreset = preset.id; editedStep = 0
                } label: { Label("プリセットを追加", systemImage: "plus") }
                Text("最後に編集したステップへ挿入（未編集なら選択中のプリセットへ追加）")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("英語に翻訳して") { insert("英語に翻訳して") }
                    Button("丁寧な文体にして") { insert("丁寧な文体にして") }
                }.font(.caption).disabled(controller.transformPresets.isEmpty)
                Text("音声モードでは選択後にキーを押して指示を話します。プリセットは録音せず、上から順に変換し、すべて成功したときだけ選択範囲へ反映します。各ステップの入力は2,000文字以内、全体で30秒までです。失敗時は途中の結果をステータスからコピーできます。履歴・スニペット・自動文章整形は使いません。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("選択テキストの変換", systemImage: "text.bubble") }
    }
}
#endif
