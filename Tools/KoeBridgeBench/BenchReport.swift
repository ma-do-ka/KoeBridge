import Foundation
import KoeBridgeCore

enum BenchReportBuilder {
    private struct Series {
        let engine: BenchEngine
        let variant: String
        let rows: [BenchResultRecord]

        var label: String {
            switch engine {
            case .amivoice:
                return "AmiVoice（\(variant)）"
            case .apple, .gemini:
                return variant == "baseline" ? engine.displayName : "\(engine.displayName)（\(variant)）"
            }
        }
    }

    static func make(
        runID: String,
        manifest: CorpusManifest,
        results: [BenchResultRecord],
        options: BenchOptions,
        gitCommit: String,
        missingKeySources: [BenchEngine: String] = [:]
    ) -> String {
        var lines: [String] = []
        lines.append("# KoeBridgeBench レポート")
        lines.append("")
        lines.append("- Run ID: `\(runID)`")
        lines.append("- Git commit: `\(gitCommit)`")
        lines.append("- OS version: `\(BenchIO.osVersion())`")
        lines.append("- Apple backend: `\(BenchIO.appleBackend())`")
        lines.append("- pacing: `\(options.pacing.rawValue)`, order: `\(options.order.rawValue)`")
        lines.append("- engines: `\(options.engines.map(\.rawValue).joined(separator: ","))`")
        let keyStatusSummary = options.engines.map { engine in
            if engine == .apple {
                return "\(engine.rawValue)=不要"
            }
            if let source = missingKeySources[engine] {
                return "\(engine.rawValue)=missing_key（\(source)）"
            }
            return "\(engine.rawValue)=ok"
        }.joined(separator: ", ")
        lines.append("- API keys: `\(keyStatusSummary)`")
        lines.append("- AmiVoice engine: `\(options.amivoiceEngine)`")
        lines.append("- vocabulary arm: `\(options.vocabFile == nil ? "baseline" : "vocab-ablation")`（Apple は語彙指定非対応）")
        lines.append("- 同一音声検査: 全エンジンの結果に同じ `pcm_sha256` を記録し、集計前に一致を確認")
        lines.append("")

        for track in [1, 2] {
            appendTrackSection(lines: &lines, track: track, manifest: manifest, results: results)
            appendLatencySection(lines: &lines, track: track, results: results)
            appendCostSection(lines: &lines, track: track, results: results)
        }

        appendFailureSection(lines: &lines, results: results)
        appendMetricNotes(lines: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendTrackSection(
        lines: inout [String],
        track: Int,
        manifest: CorpusManifest,
        results: [BenchResultRecord]
    ) {
        let title = track == 1 ? "Track 1（実音声）" : "Track 2（合成音声・再現性付録）"
        lines.append("## \(title)")
        lines.append("")
        lines.append("Track 1 と Track 2 は音声特性が異なるため、常に別表として扱います。")
        lines.append("")
        lines.append("### カテゴリ別 `cer_norm`")
        lines.append("")
        lines.append("| カテゴリ | N_ref | Apple | Gemini Live | AmiVoice |")
        lines.append("| --- | ---: | --- | --- | --- |")
        for category in 1...6 {
            let clips = manifest.clips.filter { $0.track == track && $0.category == category }
            let nref = referenceLength(clips)
            let name = clips.first?.category_name ?? "category \(category)"
            let cells = BenchEngine.allCases.map { engine in
                categoryCell(track: track, category: category, engine: engine, manifest: manifest, results: results)
            }
            lines.append("| \(category). \(markdown(name)) | \(nref) | \(cells.joined(separator: " | ")) |")
        }
        let totalClips = manifest.clips.filter { $0.track == track }
        let totalCells = BenchEngine.allCases.map { engine in
            categoryCell(track: track, category: nil, engine: engine, manifest: manifest, results: results)
        }
        lines.append("| **全体** | **\(referenceLength(totalClips))** | \(totalCells.joined(separator: " | ")) |")
        lines.append("")

        lines.append("### エンジン別 CER 概要（失敗クリップは成功分と100%削除ペナルティ込みを併記）")
        lines.append("")
        lines.append("| エンジン | 成功クリップ | cer_norm | cer_strict | cer_strict（日本語スペース適用後） |")
        lines.append("| --- | ---: | ---: | ---: | ---: |")
        for item in series(results: results.filter { $0.track == track }) {
            let clips = benchmarkClips(rows: item.rows, manifest: manifest)
            let total = clips.count
            guard total > 0 else {
                lines.append("| \(markdown(item.label)) | 0/0 | N/A | N/A | N/A |")
                continue
            }
            let succeeded = BenchmarkCER.succeededCount(clips: clips)
            let spacingTransform: @Sendable (String) -> String = {
                JapaneseDictationSpacing.adopt($0, enabled: true, protectedTerms: [])
            }
            let norm = cerCell(clips: clips, mode: .normalized)
            let strict = cerCell(clips: clips, mode: .strict)
            let spacing = cerCell(clips: clips, mode: .strictTransformed(spacingTransform))
            lines.append("| \(markdown(item.label)) | \(succeeded)/\(total) | \(norm) | \(strict) | \(spacing) |")
        }
        lines.append("")
    }

    private static func appendLatencySection(lines: inout [String], track: Int, results: [BenchResultRecord]) {
        lines.append("## レイテンシ（Track \(track)）")
        lines.append("")
        lines.append("| エンジン | connect_ms p50 | connect_ms p90 | connect_ms p95 | connect_ms max | ttfi_ms p50 | ttfi_ms p90 | ttfi_ms p95 | ttfi_ms max | stop_to_final_ms p50 | stop_to_final_ms p90 | stop_to_final_ms p95 | stop_to_final_ms max |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for item in series(results: results.filter { $0.track == track }) {
            let connect = LatencySummary(samples: item.rows.compactMap(\.connect_ms))
            let ttfi = LatencySummary(samples: item.rows.compactMap(\.ttfi_ms))
            let stop = LatencySummary(samples: item.rows.compactMap(\.stop_to_final_ms))
            let values = [connect, ttfi, stop].flatMap { summary in
                [summary.p50, summary.p90, summary.p95, summary.max].map { milliseconds($0) }
            }
            lines.append("| \(markdown(item.label)) | \(values.joined(separator: " | ")) |")
        }
        lines.append("")
    }

    private static func appendCostSection(lines: inout [String], track: Int, results: [BenchResultRecord]) {
        lines.append("## 費用の参考値（Track \(track)）")
        lines.append("")
        lines.append("無料枠と限界単価を分けて示します。無料枠は月次・エンジン単位で両Trackの合計へ適用されます。為替・課金判定・プロバイダ側の無料枠適用は確定値ではありません。")
        lines.append("")
        lines.append("| エンジン | 音声秒 | 発話秒（課金用） | 無料枠の扱い | 限界単価 | 推定費用 JPY |")
        lines.append("| --- | ---: | ---: | --- | --- | ---: |")
        for item in series(results: results.filter { $0.track == track }) {
            let audioSeconds = item.rows.compactMap(\.audio_seconds).reduce(0, +)
            let speechSeconds = item.rows.compactMap(\.speech_seconds).reduce(0, +)
            let cost = item.rows.map(\.estimated_cost_jpy).reduce(0, +)
            let freeAllowance: String
            let marginalRate: String
            switch item.engine {
            case .apple:
                freeAllowance = "APIなし"
                marginalRate = "¥0/秒"
            case .gemini:
                freeAllowance = "この表では差し引かない"
                marginalRate = String(format: "$%.3f/音声分（参考混合単価）", BenchmarkCost.geminiBlendedUSDPerMinute)
            case .amivoice:
                freeAllowance = String(format: "月%.0f秒/エンジン", BenchmarkCost.amiVoiceFreeSecondsPerMonth)
                marginalRate = String(format: "¥%.4f/発話秒（nolog）", BenchmarkCost.amiVoiceNologJPYPerSecond)
            }
            lines.append("| \(markdown(item.label)) | \(seconds(audioSeconds)) | \(seconds(speechSeconds)) | \(freeAllowance) | \(marginalRate) | \(yen(cost)) |")
        }
        lines.append("")
    }

    private static func appendFailureSection(lines: inout [String], results: [BenchResultRecord]) {
        lines.append("## 失敗・タイムアウト一覧")
        lines.append("")
        for track in [1, 2] {
            lines.append("### Track \(track)")
            lines.append("")
            let failed = results
                .filter { $0.track == track && $0.status != "success" }
                .sorted { left, right in
                    let leftRank = BenchEngine(rawValue: left.engine)?.reportRank ?? 99
                    let rightRank = BenchEngine(rawValue: right.engine)?.reportRank ?? 99
                    if leftRank != rightRank { return leftRank < rightRank }
                    if left.clip_id != right.clip_id { return left.clip_id < right.clip_id }
                    return left.variant < right.variant
                }
            if failed.isEmpty {
                lines.append("該当なし（0件）")
            } else {
                lines.append("| clip_id | エンジン | status | 要因 |")
                lines.append("| --- | --- | --- | --- |")
                for row in failed {
                    let engine = BenchEngine(rawValue: row.engine)?.displayName ?? row.engine
                    lines.append("| `\(row.clip_id)` | \(markdown(engine)) | `\(markdown(row.status))` | \(markdown(row.error ?? "不明")) |")
                }
            }
            lines.append("")
        }
    }

    private static func appendMetricNotes(lines: inout [String]) {
        lines.append("## 指標メモ")
        lines.append("")
        lines.append("- `cer_norm`: Unicode NFKC、ASCII大文字の小文字化、空白・規定句読点の除去後に計算した文字誤り率。マイクロ平均は `Σedits / ΣN_ref`。")
        lines.append("- `cer_strict`: Unicode NFC 正規化のみを行い、空白・句読点・大文字小文字を保持した文字誤り率。")
        lines.append("- `cer_strict（日本語スペース適用後）`: 参照文と仮説の双方へ同じ日本語スペース採用変換を適用した後の strict CER。")
        lines.append("- `connect_ms`: 接続またはローカル認識器の準備時間。AmiVoiceは共有実装が遅延接続のため、最初の音声送信呼び出しに含まれる準備時間を呼び出し側で測定。")
        lines.append("- `ttfi_ms`: 最初の音声送信から最初の途中または確定テキストまで。`-a2b-ja-general` では途中結果がないため N/A。")
        lines.append("- `stop_to_final_ms`: 音声終了の送信開始から最終確定テキスト取得まで。")
        lines.append("- 失敗クリップはカテゴリ表・概要表ともに、成功分と100%削除ペナルティ込み値を併記。")
        lines.append("")
    }

    private static func categoryCell(
        track: Int,
        category: Int?,
        engine: BenchEngine,
        manifest: CorpusManifest,
        results: [BenchResultRecord]
    ) -> String {
        let rows = results.filter { row in
            row.track == track
                && row.engine == engine.rawValue
                && (category.map { row.category == $0 } ?? true)
        }
        guard !rows.isEmpty else { return "—" }
        let clips = benchmarkClips(rows: rows, manifest: manifest)
        return cerCell(clips: clips, mode: .normalized)
    }

    private static func cerCell(clips: [BenchmarkClip], mode: BenchmarkCER.Mode) -> String {
        let total = clips.count
        guard total > 0 else { return "—" }
        let succeeded = BenchmarkCER.succeededCount(clips: clips)
        let successValue = BenchmarkCER.corpusMicroAverage(clips: clips, mode: mode)
        let penaltyValue = BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: clips, mode: mode)
        // corpusMicroAverage is nil exactly when every clip failed (Chunk 6 fix);
        // in the two branches below at least one clip succeeded, so the value
        // exists — the map fallback is unreachable and only satisfies the type.
        let successText = successValue.map(percent) ?? "N/A"
        if succeeded == total {
            return successText
        }
        if succeeded == 0 {
            return "N/A（成功 0/\(total)、ペナルティ込み \(percent(penaltyValue))）"
        }
        return "\(successText)（成功 \(succeeded)/\(total)、ペナルティ込み \(percent(penaltyValue))）"
    }

    private static func benchmarkClips(rows: [BenchResultRecord], manifest: CorpusManifest) -> [BenchmarkClip] {
        let clipsByID = Dictionary(uniqueKeysWithValues: manifest.clips.map { ($0.id, $0) })
        return rows.compactMap { row in
            guard let clip = clipsByID[row.clip_id] else { return nil }
            return BenchmarkClip(
                category: String(clip.category),
                reference: clip.reference,
                hypothesis: row.status == "success" ? row.raw_text : nil
            )
        }
    }

    private static func series(results: [BenchResultRecord]) -> [Series] {
        let grouped = Dictionary(grouping: results) { row in
            row.engine + "\u{1f}" + row.variant
        }
        return grouped.values.map { rows in
            let first = rows[0]
            return Series(
                engine: BenchEngine(rawValue: first.engine) ?? .apple,
                variant: first.variant,
                rows: rows
            )
        }.sorted { left, right in
            if left.engine.reportRank != right.engine.reportRank {
                return left.engine.reportRank < right.engine.reportRank
            }
            return left.variant < right.variant
        }
    }

    private static func referenceLength(_ clips: [CorpusClip]) -> Int {
        clips.reduce(0) { total, clip in
            total + BenchmarkNormalize.forCER(clip.reference).count
        }
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value * 100.0)
    }

    private static func milliseconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "N/A" }
        return String(format: "%.1f", value)
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func yen(_ value: Double) -> String {
        String(format: "¥%.2f", value)
    }

    private static func markdown(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
