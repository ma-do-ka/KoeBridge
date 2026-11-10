#if os(macOS)
import SwiftUI
import KoeBridgeCore

final class TransformPresetEditorState: ObservableObject {
    @Published var stepsByPreset: [UUID: [SettingsTransformPresets.EditorStep]] = [:]
    @Published var editedStep: UUID?
    @Published var editedPreset: UUID?
    func initialize(_ presets: [TransformPreset]) {
        for preset in presets where stepsByPreset[preset.id] == nil {
            stepsByPreset[preset.id] = preset.steps.map { .init(text: $0) }
        }
    }
}

struct SettingsTransformPresets: View {
    @ObservedObject var controller: VoiceController
    struct EditorStep: Identifiable {
        let id = UUID()
        var text: String
    }

    @ObservedObject var editor: TransformPresetEditorState
    private var stepsByPreset: [UUID: [EditorStep]] {
        get { editor.stepsByPreset }
        nonmutating set { editor.stepsByPreset = newValue }
    }
    private var editedStep: UUID? {
        get { editor.editedStep }
        nonmutating set { editor.editedStep = newValue }
    }
    private var editedPreset: UUID? {
        get { editor.editedPreset }
        nonmutating set { editor.editedPreset = newValue }
    }

    private func updateSteps(_ steps: [EditorStep], for id: UUID) {
        stepsByPreset[id] = steps
        guard let index = controller.transformPresets.firstIndex(where: { $0.id == id }) else { return }
        controller.transformPresets[index].steps = steps.map(\.text)
    }

    private func stepText(_ stepID: UUID, in presetID: UUID) -> Binding<String> {
        Binding {
            stepsByPreset[presetID]?.first(where: { $0.id == stepID })?.text ?? ""
        } set: { text in
            guard var steps = stepsByPreset[presetID],
                  let index = steps.firstIndex(where: { $0.id == stepID }) else { return }
            steps[index].text = text
            updateSteps(steps, for: presetID)
            editedPreset = presetID; editedStep = stepID
        }
    }

    private func movePreset(_ id: UUID, by offset: Int) {
        guard let index = controller.transformPresets.firstIndex(where: { $0.id == id }),
              controller.transformPresets.indices.contains(index + offset) else { return }
        controller.transformPresets.swapAt(index, index + offset)
    }

    private func insert(_ instruction: String) {
        let id = editedPreset ?? controller.selectedTransformPresetID ?? controller.transformPresets.first?.id
        guard let index = controller.transformPresets.firstIndex(where: { $0.id == id }) else { return }
        let presetID = controller.transformPresets[index].id
        var steps = stepsByPreset[presetID] ?? []
        if let index = steps.firstIndex(where: { $0.id == editedStep }) {
            steps[index].text += instruction
        } else {
            let step = EditorStep(text: instruction)
            steps.append(step)
            editedStep = step.id
        }
        updateSteps(steps, for: presetID)
        editedPreset = id
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("変換キーの動作", selection: $controller.transformMode) {
                    Text("音声で指示").tag(TransformMode.spoken)
                    Text("プリセットを使う").tag(TransformMode.preset)
                }.settingsControlFocus("presets", "transform-mode").pickerStyle(.segmented).settingsTarget("transform-mode")
                Picker("実行するプリセット", selection: $controller.selectedTransformPresetID) {
                    Text("選択してください").tag(Optional<UUID>.none)
                    ForEach(controller.transformPresets) { preset in
                        Text(preset.name.isEmpty ? "名前未入力" : preset.name).tag(Optional(preset.id))
                    }
                }
                .settingsControlFocus("selected-preset").settingsTarget("selected-preset")
                if controller.transformPresets.isEmpty {
                    Text("プリセットはありません。追加して、順番に実行する指示を入力してください。")
                        .foregroundStyle(.secondary)
                }
                ForEach($controller.transformPresets) { $preset in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("プリセット名", text: $preset.name).textFieldStyle(.roundedBorder)
                            Button { movePreset(preset.id, by: -1) } label: { Text("上へ") }
                                .disabled(controller.transformPresets.first?.id == preset.id)
                                .help("プリセットを上へ移動").accessibilityLabel("プリセット「\(preset.name)」を上へ移動")
                            Button { movePreset(preset.id, by: 1) } label: { Text("下へ") }
                                .disabled(controller.transformPresets.last?.id == preset.id)
                                .help("プリセットを下へ移動").accessibilityLabel("プリセット「\(preset.name)」を下へ移動")
                            Button(role: .destructive) {
                                controller.transformPresets.removeAll { $0.id == preset.id }
                                stepsByPreset.removeValue(forKey: preset.id)
                                if controller.selectedTransformPresetID == preset.id { controller.selectedTransformPresetID = nil }
                                if editedPreset == preset.id { editedPreset = nil; editedStep = nil }
                            } label: { Image(systemName: "trash") }
                            .help("プリセットを削除").accessibilityLabel("プリセット「\(preset.name)」を削除")
                        }
                        if preset.steps.isEmpty {
                            Text("ステップがありません。自由な言葉で指示を追加してください。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        let steps = stepsByPreset[preset.id] ?? []
                        ForEach(steps) { step in
                            let index = steps.firstIndex(where: { $0.id == step.id }) ?? 0
                            HStack {
                                Text("\(index + 1)").monospacedDigit()
                                TextField("変換の指示", text: stepText(step.id, in: preset.id))
                                    .textFieldStyle(.roundedBorder)
                                    .simultaneousGesture(TapGesture().onEnded {
                                        editedPreset = preset.id; editedStep = step.id
                                    })
                                Button {
                                    var reordered = steps
                                    reordered.swapAt(index, index - 1)
                                    updateSteps(reordered, for: preset.id)
                                } label: { Text("上へ") }
                                    .disabled(index == 0).help("ステップを上へ移動").accessibilityLabel("ステップ\(index + 1)を上へ移動")
                                Button {
                                    var reordered = steps
                                    reordered.swapAt(index, index + 1)
                                    updateSteps(reordered, for: preset.id)
                                } label: { Text("下へ") }
                                    .disabled(index == steps.count - 1).help("ステップを下へ移動").accessibilityLabel("ステップ\(index + 1)を下へ移動")
                                Button(role: .destructive) {
                                    updateSteps(steps.filter { $0.id != step.id }, for: preset.id)
                                    if editedStep == step.id { editedStep = nil }
                                } label: { Image(systemName: "trash") }
                                .help("ステップを削除").accessibilityLabel("ステップ\(index + 1)を削除")
                            }
                        }
                        Button("ステップを追加") {
                            let step = EditorStep(text: "")
                            updateSteps(steps + [step], for: preset.id)
                            editedPreset = preset.id; editedStep = step.id
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
                    let step = EditorStep(text: "")
                    stepsByPreset[preset.id] = [step]
                    editedPreset = preset.id; editedStep = step.id
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
