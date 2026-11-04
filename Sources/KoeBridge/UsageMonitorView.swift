#if os(macOS)
import Foundation
import SwiftUI
import Charts
import KoeBridgeCore

/// Local metadata only; refreshed after a dictation has resolved.
struct UsageMonitorView: View {
    @ObservedObject var controller: VoiceController
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
            grouped[bucket(sample.at), default: 0] += sample.totalTokens
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
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("利用統計")
                            .font(.system(size: 20, weight: .semibold))
                        Text("認識エンジンとGemini APIの使用実績をMac内で集計します。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("v1.0.1-c  試験機能")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !controller.monitorProblem.isEmpty {
                    Text(controller.monitorProblem)
                        .font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                HStack(spacing: 9) {
                    summaryTile("Gemini 試行",
                                "\(last24Hours.filter { $0.engine == .gemini }.count)回")
                    summaryTile("Apple 試行",
                                "\(last24Hours.filter { $0.engine == .apple }.count)回")
                    summaryTile("Appleへ切替",
                                "\(last24Hours.filter { $0.fallback }.count)回")
                    summaryTile("試行失敗",
                                "\(last24Hours.filter { $0.outcome == .failure }.count)回")
                }

                HStack {
                    Text("集計間隔").font(.subheadline.weight(.semibold))
                    Picker("集計間隔", selection: $scale) {
                        ForEach(Scale.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    Spacer()
                    Text(scale.rangeLabel).font(.caption).foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("エンジン別の利用回数").font(.subheadline.weight(.semibold))
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
                        Text("エンジン別の処理音声時間（PCM秒）")
                            .font(.subheadline.weight(.semibold))
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
                        Text("音声データを実際に送信・処理した秒数です。無音区間も含みます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(7)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("Gemini API：報告されたトークン数")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("計 \(controller.monitorTokens.filter { $0.at >= startOfRange }.reduce(0) { $0 + $1.totalTokens }.formatted())")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if tokenBars.isEmpty {
                            emptyState("APIからトークン情報を取得できていません")
                        } else {
                            Chart(tokenBars) { item in
                                BarMark(x: .value("受信時刻", item.bucket, unit: scale.component),
                                        y: .value("トークン数", item.tokens))
                                    .foregroundStyle(Color.blue)
                            }
                            .frame(height: 145)
                        }
                        Text("API応答の usageMetadata を受信時刻で集計。未報告分は推定・補完せず、Googleの確定請求額とは異なる場合があります。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(7)
                }

                HStack {
                    Text("データはこのMacに最大30日保存。音声・文字起こし・APIキーは記録しません。録音確定後に更新されます。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("利用統計を削除", role: .destructive) { confirmDelete = true }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("利用統計を削除しますか？", isPresented: $confirmDelete) {
            Button("削除", role: .destructive) { controller.clearUsageMonitor() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("利用回数・音声秒数・トークン統計のみを削除します。認識履歴や設定には影響しません。")
        }
    }

    private func summaryTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func emptyState(_ label: String) -> some View {
        Text(label)
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 85)
    }
}
#endif
