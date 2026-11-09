#if os(macOS)
import Foundation
import SwiftUI
import Charts
import KoeBridgeCore

/// Local metadata only; refreshed after a dictation has resolved.
struct UsageMonitorView: View {
    @ObservedObject var controller: VoiceController
    @Environment(\.colorScheme) private var colorScheme
    let focusRequest: SettingsFocusRequest?
    @State private var scale: Scale = .hour
    @State private var confirmDelete = false

    private enum Scale: String, CaseIterable, Identifiable {
        case minute, hour, day
        var id: String { rawValue }
        var label: String {
            switch self {
            case .minute: return "1分"
            case .hour: return "1時間"
            case .day: return "1日"
            }
        }
        var component: Calendar.Component {
            switch self {
            case .minute: return .minute
            case .hour: return .hour
            case .day: return .day
            }
        }
        var slotCount: Int {
            switch self {
            case .minute: return 60
            case .hour: return 24
            case .day: return 14
            }
        }
        var rangeLabel: String {
            switch self {
            case .minute: return "直近60分"
            case .hour: return "直近24時間"
            case .day: return "直近14日間"
            }
        }
    }

    private struct EngineBar: Identifiable {
        let bucket: Date
        let engine: UsageEngine
        let count: Int
        let seconds: Double
        var id: String { "\(bucket.timeIntervalSince1970)-\(engine.rawValue)" }
    }
    private struct TokenBar: Identifiable {
        let bucket: Date
        let tokens: Int
        var id: Date { bucket }
    }

    private var startOfRange: Date {
        let calendar = Calendar.current
        let current = calendar.dateInterval(of: scale.component, for: Date())?.start ?? Date()
        return calendar.date(byAdding: scale.component, value: 1 - scale.slotCount,
                             to: current) ?? current
    }

    private func bucket(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: scale.component, for: date)?.start ?? date
    }

    private var engineBars: [EngineBar] {
        struct Key: Hashable {
            let date: Date
            let engine: UsageEngine
        }
        var grouped: [Key: (count: Int, seconds: Double)] = [:]
        for event in controller.monitorEvents where event.at >= startOfRange {
            let key = Key(date: bucket(event.at), engine: event.engine)
            let previous = grouped[key] ?? (count: 0, seconds: 0)
            grouped[key] = (previous.count + 1, previous.seconds + event.audioSeconds)
        }
        return grouped.map {
            EngineBar(bucket: $0.key.date, engine: $0.key.engine,
                      count: $0.value.count, seconds: $0.value.seconds)
        }.sorted { $0.bucket < $1.bucket }
    }

    private var tokenBars: [TokenBar] {
        var grouped: [Date: Int] = [:]
        for sample in controller.monitorTokens where sample.at >= startOfRange {
            let key = bucket(sample.at)
            grouped[key] = UsageAggregation.addingTokens(grouped[key] ?? 0, sample.totalTokens)
        }
        return grouped.map { TokenBar(bucket: $0.key, tokens: $0.value) }
            .sorted { $0.bucket < $1.bucket }
    }

    private func outcomeCount(_ engine: UsageEngine, _ outcome: UsageOutcome) -> Int {
        controller.monitorEvents.filter {
            $0.at >= startOfRange && $0.engine == engine && $0.outcome == outcome
        }.count
    }

    private var last24Hours: [EngineUsageSample] {
        controller.monitorEvents.filter { $0.at >= Date().addingTimeInterval(-86_400) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            SettingsIndicatedScrollView {
                VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Spacer()
                    Text("v1.0.1-c  試験機能")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !controller.monitorProblem.isEmpty {
                    Text(controller.monitorProblem)
                        .font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    summaryTile("Geminiの利用回数",
                                "\(last24Hours.filter { $0.engine == .gemini }.count)回",
                                detail: "過去24時間にGeminiで認識を試みた回数です。音声の追加チェックと失敗も含まれます。")
                    summaryTile("Appleの利用回数",
                                "\(last24Hours.filter { $0.engine == .apple }.count)回",
                                detail: "過去24時間にAppleで認識を試みた回数です。自動切替も含まれます。")
                    summaryTile("Appleへの自動切替",
                                "\(last24Hours.filter { $0.fallback }.count)回",
                                detail: "Geminiを利用できない場合などにAppleで認識を試みた回数です。")
                    summaryTile("認識処理の失敗回数",
                                "\(last24Hours.filter { $0.outcome == .failure }.count)回",
                                detail: "過去24時間のエンジン別の失敗回数です。Appleで救済できた録音も含まれます。")
                }

                HStack(alignment: .center, spacing: 15) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("グラフの表示単位")
                            .font(.subheadline.weight(.semibold))
                        Text("分・時間・日単位に切り替えて利用状況を確認できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("グラフの表示単位", selection: $scale) {
                        ForEach(Scale.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    Text(scale.rangeLabel).font(.caption).foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("GeminiとAppleの利用回数")
                            .id("usage")
                            .font(.subheadline.weight(.semibold))
                        Text("どの時間帯にどちらの音声認識を試みたかを表示します。自動切替した録音は両方に計上されます。")
                            .font(.caption).foregroundStyle(.secondary)
                        if engineBars.isEmpty {
                            emptyState("対象期間の利用実績はありません")
                        } else {
                            Chart(engineBars) { item in
                                BarMark(x: .value("時刻", item.bucket, unit: scale.component),
                                        y: .value("試行回数", item.count))
                                    .foregroundStyle(by: .value("エンジン", item.engine.label))
                            }
                            .chartForegroundStyleScale([
                                UsageEngine.gemini.label: Color.blue,
                                UsageEngine.apple.label: Color.green
                            ])
                            .frame(height: 145)
                        }
                        HStack(spacing: 12) {
                            Text("Gemini：\(outcomeCount(.gemini, .success))成功 / \(outcomeCount(.gemini, .failure))失敗")
                            Text("Apple：\(outcomeCount(.apple, .success))成功 / \(outcomeCount(.apple, .failure))失敗")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(7)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("音声の処理時間")
                            .font(.subheadline.weight(.semibold))
                        Text("各エンジンに送信・投入した音声データの秒数です。無音も含まれます。")
                            .font(.caption).foregroundStyle(.secondary)
                        if engineBars.isEmpty {
                            emptyState("対象期間の利用実績はありません")
                        } else {
                            Chart(engineBars) { item in
                                BarMark(x: .value("時刻", item.bucket, unit: scale.component),
                                        y: .value("処理秒数", item.seconds))
                                    .foregroundStyle(by: .value("エンジン", item.engine.label))
                            }
                            .chartForegroundStyleScale([
                                UsageEngine.gemini.label: Color.blue,
                                UsageEngine.apple.label: Color.green
                            ])
                            .frame(height: 145)
                        }

                    }
                    .padding(7)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("Gemini APIのトークン使用量")
                                .id("token")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("計 \(UsageAggregation.totalTokens(controller.monitorTokens.lazy.filter { $0.at >= startOfRange }).formatted())")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if tokenBars.isEmpty {
                            emptyState("トークン情報を取得できていません。APIが使用されていないことを意味するものではありません。")
                        } else {
                            Chart(tokenBars) { item in
                                BarMark(x: .value("受信時刻", item.bucket, unit: scale.component),
                                        y: .value("トークン数", item.tokens))
                                    .foregroundStyle(Color.blue)
                            }
                            .frame(height: 145)
                        }
                        Text("Google APIが報告したトークン数を受信時刻で集計します。未取得分は推定しません。請求額とは異なります。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(7)
                }

                HStack {
                    Text("利用統計はこのMac内に最大30日保存します。録音音声・認識した文章・APIキーは利用統計には保存しません。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("利用記録を削除", role: .destructive) { confirmDelete = true }
                }
            }
            .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                if let focusRequest { proxy.scrollTo(focusRequest.id, anchor: .top) }
            }
            .onChange(of: focusRequest) { _, target in
                if let target {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(target.id, anchor: .top)
                    }
                }
            }
        }
        .alert("利用統計を削除しますか？", isPresented: $confirmDelete) {
            Button("削除", role: .destructive) { controller.clearUsageMonitor() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("利用回数・音声秒数・トークン統計のみを削除します。認識履歴や設定には影響しません。")
        }
    }

    private func summaryTile(_ label: String, _ value: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .center)
        .padding(10)
        .background(
            colorScheme == .dark
                ? Color(red: 0.205, green: 0.208, blue: 0.237)
                : Color.white,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(colorScheme == .dark
                              ? Color.white.opacity(0.09)
                              : Color.black.opacity(0.08), lineWidth: 1)
        }
    }

    private func emptyState(_ label: String) -> some View {
        Text(label)
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 85)
    }
}
#endif
