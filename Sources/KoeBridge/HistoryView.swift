#if os(macOS)
import Foundation
import SwiftUI
import KoeBridgeCore

struct HistoryView: View {
    @ObservedObject var controller: VoiceController
    @State private var selectedID: UUID?
    @State private var confirmDeleteAll = false

    private var selected: TranscriptRecord? {
        controller.history.first(where: { $0.id == selectedID }) ?? controller.history.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("保存した文章：\(controller.history.count) / 10件")
                    .font(.headline)
                Spacer()
                Text("直近10件を保存。音声データ・APIキーは保存しません")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !controller.historyProblem.isEmpty {
                Text(controller.historyProblem)
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if controller.history.isEmpty {
                Spacer()
                Text("保存された文字起こしはありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(controller.history) { record in
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
                                Button("文章をコピー") { controller.copyRecord(selected) }
                                Button("この文章を削除", role: .destructive) {
                                    let removing = selected.id
                                    controller.deleteRecord(removing)
                                    selectedID = controller.history.first?.id
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
        .alert("保存した10件の履歴をすべて削除しますか？", isPresented: $confirmDeleteAll) {
            Button("削除", role: .destructive) { controller.clearHistory(); selectedID = nil }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除した文字起こしはKoeBridgeから復元できません。")
        }
    }
}
#endif
