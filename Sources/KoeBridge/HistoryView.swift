#if os(macOS)
import Foundation
import SwiftUI
import KoeBridgeCore

struct HistoryView: View {
    @ObservedObject var controller: VoiceController
    @State private var selectedID: UUID?
    @State private var confirmDeleteAll = false
    @State private var query = ""
    @State private var learningRecord: TranscriptRecord?

    private var filteredHistory: [TranscriptRecord] {
        HistorySearch.filter(controller.history, query: query)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selected: TranscriptRecord? {
        filteredHistory.first(where: { $0.id == selectedID }) ?? filteredHistory.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isSearching
                     ? "\(filteredHistory.count)件が一致（全\(controller.history.count)件）"
                     : "保存した文章：\(controller.history.count) / \(RecentTranscriptArchive.maximumRecords)件")
                    .font(.headline)
                Spacer()
                Text("直近\(RecentTranscriptArchive.maximumRecords)件を保存。音声データ・APIキーは保存しません")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !controller.historyProblem.isEmpty {
                Text(controller.historyProblem)
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("履歴を検索", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("履歴を検索")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("検索をクリア")
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("文章内を検索します。空白で区切ると、すべての語句を含む履歴を表示します。")
                .font(.caption).foregroundStyle(.secondary)
            if controller.history.isEmpty {
                Spacer()
                Text("保存された文字起こしはありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        if filteredHistory.isEmpty {
                            Text("「\(query.trimmingCharacters(in: .whitespacesAndNewlines))」に一致する履歴はありません")
                                .foregroundStyle(.secondary)
                            Text("検索する語句を減らすか、検索欄をクリアしてください。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(filteredHistory) { record in
                                    Button {
                                        selectedID = record.id
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Text(record.text.replacingOccurrences(of: "\n", with: " "))
                                                .lineLimit(2).font(.body)
                                            Text(record.delivery.label)
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(selected?.id == record.id
                                                    ? Color.accentColor.opacity(0.14)
                                                    : Color.secondary.opacity(0.07))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }.frame(width: 255)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        if let selected {
                            Text("\(selected.engine) / \(selected.isPartial ? "認識途中" : "確定結果")")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(selected.delivery.label)
                                .font(.caption).foregroundStyle(.secondary)
                            if let detail = selected.deliveryDetail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if let review = selected.review {
                                Text(review.note)
                                    .font(.caption)
                                    .foregroundStyle(review.status == .needsReview ? Color.orange : Color.secondary)
                                    .textSelection(.enabled)
                            }
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(selected.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                    if let original = selected.review?.originalText, original != selected.text {
                                        Divider()
                                        Text("追加チェック前の文章").font(.caption).foregroundStyle(.secondary)
                                        Text(original).textSelection(.enabled)
                                    }
                                    if let alternative = selected.review?.alternativeText {
                                        Divider()
                                        Text("音声の再認識結果（自動置換していません）")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(alternative).textSelection(.enabled)
                                        Button("再認識結果をコピー") { TextInsertion.copy(alternative) }
                                    }
                                }
                            }
                            HStack {
                                Spacer()
                                Button("修正して学習") { learningRecord = selected }
                                Button("文章をコピー") { controller.copyRecord(selected) }
                                Button("この文章を削除", role: .destructive) {
                                    let removing = selected.id
                                    controller.deleteRecord(removing)
                                    selectedID = filteredHistory.first?.id
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            HStack {
                Text("反映を確認できないアプリでは「受理は未確認」と表示します。再送の前に入力先を確認してください。")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("履歴をすべて削除", role: .destructive) { confirmDeleteAll = true }
                    .disabled(controller.history.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 650, minHeight: 390)
        .sheet(item: $learningRecord) { record in
            HistoryLearningEditor(controller: controller, record: record)
        }
        .alert("保存した履歴（\(controller.history.count)件）をすべて削除しますか？", isPresented: $confirmDeleteAll) {
            Button("削除", role: .destructive) { controller.clearHistory(); selectedID = nil }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除した文字起こしはKoeBridgeから復元できません。")
        }
    }
}
private struct HistoryLearningEditor: View {
    @ObservedObject var controller: VoiceController
    let record: TranscriptRecord
    @Environment(\.dismiss) private var dismiss
    @State private var fragment = ""
    @State private var term = ""
    @State private var saved = false

    private var hint: String? {
        LearnedTermPolicy.validationHint(fragment: fragment, term: term, recordText: record.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("修正して学習").font(.headline)
            ScrollView { Text(record.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 140)
            Button("文章をコピー") { controller.copyRecord(record) }
            TextField("誤り：", text: $fragment)
            TextField("正しい表記：", text: $term)
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            Text("履歴の文章は変更せず、指定した表記を認識の候補として保存します。")
                .font(.caption).foregroundStyle(.secondary)
            if saved { Text("語彙に学習しました").foregroundStyle(.green) }
            HStack {
                Button("閉じる") { dismiss() }
                Spacer()
                Button("語彙に学習する") { saved = controller.learn(fragment: fragment, term: term, from: record) }
                    .disabled(hint != nil)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20).frame(width: 480)
        .onChange(of: fragment) { saved = false }
        .onChange(of: term) { saved = false }
        .task(id: saved) {
            guard saved else { return }
            do {
                try await Task.sleep(for: .milliseconds(800))
                dismiss()
            } catch { }
        }
    }
}
#endif
