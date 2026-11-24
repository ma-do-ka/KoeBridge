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

    enum Scale: String, CaseIterable, Identifiable {
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

    struct EngineBar: Identifiable, Equatable {
        let bucket: Date
        let engine: UsageEngine
        let count: Int
        let seconds: Double
        var id: String { "\(bucket.timeIntervalSince1970)-\(engine.rawValue)" }
    }
    struct TokenBar: Identifiable, Equatable {
        let bucket: Date
        let tokens: Int
        var id: Date { bucket }
    }

    private struct ChartKey: Equatable {
        let revision: UInt64
        let scale: Scale
        let calendar: Calendar
        let start: Date
    }
    struct ChartTotals: Equatable {
        var engines: [EngineBar] = []
        var tokens: [TokenBar] = []
        var outcomes: [UsageEngine: [UsageOutcome: Int]] = [:]
        var totalTokens = 0

        static func aggregate(events: [EngineUsageSample],
                              tokens tokenSamples: [GeminiTokenSample],
                              scale: Scale,
                              calendar: Calendar,
                              start: Date) -> ChartTotals {
            struct Bucket: Hashable {
                let date: Date
                let engine: UsageEngine
            }
            func bucket(_ date: Date) -> Date {
                calendar.dateInterval(of: scale.component, for: date)?.start ?? date
            }
            var grouped: [Bucket: (count: Int, seconds: Double)] = [:]
            var tokens: [Date: Int] = [:]
            var totals = ChartTotals()
            for event in events where event.at >= start {
                let key = Bucket(date: bucket(event.at), engine: event.engine)
                let previous = grouped[key] ?? (count: 0, seconds: 0)
                grouped[key] = (previous.count + 1, previous.seconds + event.audioSeconds)
                totals.outcomes[event.engine, default: [:]][event.outcome, default: 0] += 1
            }
            for sample in tokenSamples where sample.at >= start {
                let date = bucket(sample.at)
                tokens[date] = GeminiTokenUsage.adding(sample.totalTokens, to: tokens[date, default: 0])
                totals.totalTokens = GeminiTokenUsage.adding(sample.totalTokens, to: totals.totalTokens)
            }
            totals.engines = grouped.map {
                EngineBar(bucket: $0.key.date, engine: $0.key.engine, count: $0.value.count, seconds: $0.value.seconds)
            }.sorted {
                if $0.bucket != $1.bucket { return $0.bucket < $1.bucket }
                return $0.engine.rawValue < $1.engine.rawValue
            }
            totals.tokens = tokens.map { TokenBar(bucket: $0.key, tokens: $0.value) }.sorted { $0.bucket < $1.bucket }
            return totals
        }
    }
    struct RecentTotals: Equatable {
        var gemini = 0, amivoice = 0, apple = 0, fallback = 0, failed = 0
        var amiVoiceSeconds = 0.0
        var amiVoiceSpeechSeconds = 0.0
        var validThrough = Date.distantFuture

        static func aggregate(events: [EngineUsageSample], at now: Date) -> RecentTotals {
            var totals = RecentTotals()
            let cutoff = now.addingTimeInterval(-86_400)
            for event in events where event.at >= cutoff {
                switch event.engine {
                case .gemini:
                    totals.gemini += 1
                case .amivoice:
                    totals.amivoice += 1
                    totals.amiVoiceSeconds += event.audioSeconds
                    totals.amiVoiceSpeechSeconds += UsageSummary.effectiveAmiVoiceSpeechSeconds(for: event)
                case .apple:
                    totals.apple += 1
                }
                if event.fallback { totals.fallback += 1 }
                if event.outcome == .failure { totals.failed += 1 }
                totals.validThrough = min(totals.validThrough, event.at.addingTimeInterval(86_400))
            }
            return totals
        }
    }
    private final class RecentCache {
        var entry: (revision: UInt64, computed: Date, totals: RecentTotals)?
    }
    @State private var chartCache = DisplayCache<ChartKey, ChartTotals>()
    @State private var recentCache = RecentCache()

    private func recentTotals(at now: Date) -> RecentTotals {
        if let entry = recentCache.entry, entry.revision == controller.usageRevision,
           now >= entry.computed, now <= entry.totals.validThrough { return entry.totals }
        let totals = RecentTotals.aggregate(events: controller.monitorEvents, at: now)
        recentCache.entry = (controller.usageRevision, now, totals)
        return totals
    }

    private func chartTotals(at now: Date) -> ChartTotals {
        let calendar = Calendar.current
        let current = calendar.dateInterval(of: scale.component, for: now)?.start ?? now
        let start = calendar.date(byAdding: scale.component, value: 1 - scale.slotCount, to: current) ?? current
        let key = ChartKey(revision: controller.usageRevision, scale: scale, calendar: calendar, start: start)
        return chartCache.value(for: key) {
            ChartTotals.aggregate(events: controller.monitorEvents,
                                  tokens: controller.monitorTokens,
                                  scale: scale,
                                  calendar: calendar,
                                  start: start)
        }
    }

    var body: some View {
        let now = Date()
        let chart = chartTotals(at: now)
        let recent = recentTotals(at: now)
        let monthlyAmiVoice = UsageSummary.amiVoiceMonthlyUsage(events: controller.monitorEvents, now: now)
        return Group {
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
                                "\(recent.gemini)回",
                                detail: "過去24時間にGeminiで認識を試みた回数です。音声の追加チェックと失敗も含まれます。")
                    summaryTile("AmiVoiceの利用回数",
                                "\(recent.amivoice)回",
                                detail: "過去24時間にAmiVoiceで認識を試みた回数です。失敗も含まれます。")
                    summaryTile("Appleの利用回数",
                                "\(recent.apple)回",
                                detail: "過去24時間にAppleで認識を試みた回数です。自動切替も含まれます。")
                    summaryTile("Appleへの自動切替",
                                "\(recent.fallback)回",
                                detail: "GeminiまたはAmiVoiceを利用できない場合などにAppleで認識を試みた回数です。")
                    summaryTile("認識処理の失敗回数",
                                "\(recent.failed)回",
                                detail: "過去24時間のエンジン別の失敗回数です。Appleで救済できた録音も含まれます。")
                    summaryTile("AmiVoiceの発話時間",
                                String(format: "%.0f秒", recent.amiVoiceSpeechSeconds),
                                detail: String(format: "過去24時間のVAD発話秒数です（送信音声 %.0f秒）。", recent.amiVoiceSeconds))
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
                    .settingsControlFocus("usage").pickerStyle(.segmented).settingsTarget("usage")
                    .frame(width: 210)
                    Text(scale.rangeLabel).font(.caption).foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("認識エンジンの利用回数")

                            .font(.subheadline.weight(.semibold))
                        Text("どの時間帯にどの音声認識を試みたかを表示します。自動切替した録音は両方に計上されます。")
                            .font(.caption).foregroundStyle(.secondary)
                        if chart.engines.isEmpty {
                            emptyState("対象期間の利用実績はありません")
                        } else {
                            Chart(chart.engines) { item in
                                BarMark(x: .value("時刻", item.bucket, unit: scale.component),
                                        y: .value("試行回数", item.count))
                                    .foregroundStyle(by: .value("エンジン", item.engine.label))
                            }
                            .chartForegroundStyleScale([
                                UsageEngine.gemini.label: Color.blue,
                                UsageEngine.amivoice.label: Color.orange,
                                UsageEngine.apple.label: Color.green
                            ])
                            .frame(height: 145)
                        }
                        HStack(spacing: 12) {
                            Text("Gemini：\(chart.outcomes[.gemini]?[.success] ?? 0)成功 / \(chart.outcomes[.gemini]?[.failure] ?? 0)失敗")
                            Text("AmiVoice：\(chart.outcomes[.amivoice]?[.success] ?? 0)成功 / \(chart.outcomes[.amivoice]?[.failure] ?? 0)失敗")
                            Text("Apple：\(chart.outcomes[.apple]?[.success] ?? 0)成功 / \(chart.outcomes[.apple]?[.failure] ?? 0)失敗")
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
                        if chart.engines.isEmpty {
                            emptyState("対象期間の利用実績はありません")
                        } else {
                            Chart(chart.engines) { item in
                                BarMark(x: .value("時刻", item.bucket, unit: scale.component),
                                        y: .value("処理秒数", item.seconds))
                                    .foregroundStyle(by: .value("エンジン", item.engine.label))
                            }
                            .chartForegroundStyleScale([
                                UsageEngine.gemini.label: Color.blue,
                                UsageEngine.amivoice.label: Color.orange,
                                UsageEngine.apple.label: Color.green
                            ])
                            .frame(height: 145)
                        }

                    }
                    .padding(7)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("AmiVoice 月間無料枠（エンジン別・60分/月）")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("日本時間（JST）基準")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if monthlyAmiVoice.isEmpty {
                            emptyState("今月（日本時間）のAmiVoice利用実績はありません")
                        } else {
                            ForEach(monthlyAmiVoice, id: \.engineVariant) { bucket in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(amiVoiceVariantTitle(bucket.engineVariant))
                                            .font(.caption.weight(.semibold))
                                        Spacer()
                                        Text(String(format: "%.1f / 60.0分（残り %.1f分）",
                                                    bucket.speechSeconds / 60, bucket.freeRemainingSeconds / 60))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    ProgressView(value: bucket.freeUsageFraction)
                                        .tint(bucket.billableSeconds > 0 ? Color.orange : Color.accentColor)
                                    HStack(spacing: 8) {
                                        Text("\(bucket.takes)回・送信 \(String(format: "%.1f", bucket.audioSeconds / 60))分・発話 \(String(format: "%.1f", bucket.speechSeconds / 60))分")
                                        if bucket.fallbackToAudioCount > 0 {
                                            Text("（うち\(bucket.fallbackToAudioCount)回は音声秒で代替）")
                                        }
                                        Spacer()
                                        if bucket.billableSeconds > 0 {
                                            Text(String(format: "超過 %d秒 / 概算 ¥%.2f", bucket.billableSeconds, bucket.estimatedCostJPY))
                                                .foregroundStyle(.orange)
                                        } else {
                                            Text("無料枠内")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        Text("エンジンごとに月60分（3,600秒）のVAD発話無料枠があります。超過分は ¥0.04125/秒（¥2.475/分、税込）です。ローカル統計の保持は30日間のため、正確な利用量はAmiVoiceマイページで確認してください。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(7)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("Gemini APIのトークン使用量").settingsTarget("token")

                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("計 \(chart.totalTokens.formatted())")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if chart.tokens.isEmpty {
                            emptyState("トークン情報を取得できていません。APIが使用されていないことを意味するものではありません。")
                        } else {
                            Chart(chart.tokens) { item in
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
                    Button("利用記録を削除", role: .destructive) { confirmDelete = true }.settingsControlFocus("token")
                }
            }
            .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("利用統計をすべて削除しますか？", isPresented: $confirmDelete) {
            Button("削除", role: .destructive) { controller.clearUsageMonitor() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("対象：利用回数・音声秒数・トークン統計のみ。履歴・保存音声・診断ログ・設定は変更しません。削除は取り消せません。")
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

    private func amiVoiceVariantTitle(_ variant: String?) -> String {
        guard let variant else { return "エンジン未記録" }
        if let engine = AmiVoiceEngine(rawValue: variant) {
            return "\(engine.label)（\(variant)）"
        }
        return variant
    }
}
#endif
