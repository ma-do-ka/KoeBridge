import Foundation
import Testing
@testable import KoeBridgeCore

/// FX-01..FX-38 acceptance fixtures for R-03 clause streaming (B-2 Soft
/// Commit). Events model engine final-segment deliveries exactly as the real
/// pipeline sees them: each event is appended to a real TranscriptAssembler
/// and the growing finalizedPrefix is fed to the segmenter.
struct SentenceSegmenterTests {
    private struct Run {
        var units: [SentenceUnit]
        var off: String
        var texts: [String] { units.map(\.text) }
        var rawAssembled: String { units.map { $0.separator + $0.text }.joined() }
    }

    private func run(_ events: [String]) -> Run {
        var assembler = TranscriptAssembler()
        var segmenter = SentenceSegmenter()
        var units: [SentenceUnit] = []
        for event in events {
            assembler.apply(.final(event))
            units += segmenter.ingest(assembler.finalized)
        }
        if let remainder = segmenter.flush() { units.append(remainder) }
        return Run(units: units, off: assembler.finalized)
    }

    private func runOne(_ text: String) -> Run { run([text]) }

    // MARK: - A: punctuation basics

    @Test func fx01_periodSplitsTwoSentences() {
        let r = runOne("きょうは雲留工房へ行く。明日は休む。")
        #expect(r.texts == ["きょうは雲留工房へ行く。", "明日は休む。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx02_threeTerminatorKinds() {
        let r = runOne("準備はできたか？はい、完了です！出発しよう。")
        #expect(r.texts == ["準備はできたか？", "はい、完了です！", "出発しよう。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx03_readingCommaNeverSplits() {
        let r = runOne("午前にタユラ倉庫へ寄り、荷物を積み、午後に戻る。")
        #expect(r.texts == ["午前にタユラ倉庫へ寄り、荷物を積み、午後に戻る。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx04_terminatorRunIsOneBoundary() {
        let r = runOne("本当にそれでいいのか？！念のため確認しよう")
        #expect(r.texts == ["本当にそれでいいのか？！", "念のため確認しよう"])
        #expect(r.rawAssembled == r.off)
    }

    // MARK: - B: quotes and brackets

    @Test func fx05_quoteInteriorPeriodSuppressed() {
        let r = runOne("担当は「予定は変更ない。」と伝えた。すぐ再開する。")
        #expect(r.texts == ["担当は「予定は変更ない。」と伝えた。", "すぐ再開する。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx06_multipleTerminatorsInsideQuote() {
        let r = runOne("「出発します！準備はいいですか？」と係員が叫んだ。")
        #expect(r.texts == ["「出発します！準備はいいですか？」と係員が叫んだ。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx07_parenInteriorPeriodSuppressed() {
        let r = runOne("議事録を確認した（詳細は第3区画の別紙を参照。改訂版あり。）。次に進む。")
        #expect(r.texts == ["議事録を確認した（詳細は第3区画の別紙を参照。改訂版あり。）。", "次に進む。"])
        #expect(r.rawAssembled == r.off)
    }

    /// GD-729 案C + fixture: a standalone quote is never a boundary, but a
    /// quote that CLOSES after an interior terminator and is not followed by
    /// a continuation particle ends the unit (FX-08 adopted rule).
    @Test func fx08_standaloneQuoteCloseAfterInteriorTerminator() {
        let r = runOne("「これで完了です。」次の議題へ移る。")
        #expect(r.texts == ["「これで完了です。」", "次の議題へ移る。"])
        #expect(r.units.first?.source == .quoteClose)
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx09_closeQuoteBeforeToContinues() {
        let r = runOne("係員は「明日は雨だ。傘を持て」と言いかけて止まった。以上。")
        #expect(r.texts == ["係員は「明日は雨だ。傘を持て」と言いかけて止まった。", "以上。"])
        #expect(r.rawAssembled == r.off)
    }

    // MARK: - C: punctuation lookalikes that are not boundaries

    @Test func fx10_decimalPoint() {
        let r = runOne("温度は36.5度で、誤差は0.02だった。正常範囲だ。")
        #expect(r.texts == ["温度は36.5度で、誤差は0.02だった。", "正常範囲だ。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx11_versionAndThousandsSeparators() {
        let r = runOne("版数は2.4.1で、予算は1,250,000円だ。承認を待つ。")
        #expect(r.texts == ["版数は2.4.1で、予算は1,250,000円だ。", "承認を待つ。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx12_abbreviationPeriods() {
        let r = runOne("規格はK.R.S.に準拠し、担当はDr.タユラだ。報告を終える。")
        #expect(r.texts == ["規格はK.R.S.に準拠し、担当はDr.タユラだ。", "報告を終える。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx13_ellipsisIsNotABoundary() {
        let r = runOne("うーん……少し待ってほしい。すぐ確認する。")
        #expect(r.texts == ["うーん……少し待ってほしい。", "すぐ確認する。"])
        #expect(r.rawAssembled == r.off)
    }

    // MARK: - D: final-event edge vs punctuation

    @Test func fx14_eventEdgeAloneDoesNotSplit() {
        let r = run(["明日の荷物は", "第5倉庫へ運ぶ。"])
        #expect(r.texts == ["明日の荷物は第5倉庫へ運ぶ。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx15_quoteStateCrossesEventBoundary() {
        let r = run(["担当者は「了解した", "。」と答えた。次へ進む。"])
        #expect(r.texts == ["担当者は「了解した。」と答えた。", "次へ進む。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx16_completedUnitsAheadOfUnfinishedTail() {
        let r = run(["第一報です。現場は異常なし！続報は", "10分後に出す。"])
        #expect(r.texts == ["第一報です。", "現場は異常なし！", "続報は10分後に出す。"])
        #expect(r.rawAssembled == r.off)
    }

    // MARK: - E: 128-unit cap degrade

    @Test func fx17_exactly128UnitsNoDegrade() {
        let events = (1...128).map { "項目\($0)を確認。" }
        let r = run(events)
        #expect(r.units.count == 128)
        #expect(r.units.last?.source == .terminator)
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx18_over128FoldsRemainderIntoOneUnit() {
        let events = (1...135).map { "項目\($0)を確認。" }
        let r = run(events)
        #expect(r.units.count == 129)
        let tail = (129...135).map { "項目\($0)を確認。" }.joined()
        #expect(r.units.last?.text == tail)
        #expect(r.units.last?.source == .capacity)
        #expect(r.rawAssembled == r.off)
    }

    // MARK: - F: assembly equivalence at spacing edges

    @Test func fx19_boundaryWhitespaceSurvivesVerbatim() {
        let r = run(["テスト完了。 ", " Next stepは確認だ。"])
        #expect(r.texts == ["テスト完了。", "Next stepは確認だ。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx20_alnumAndBracketAfterTerminators() {
        let r = run(["型番はAB-12です。CD-34も確認！", "（補足あり）以上。"])
        #expect(r.texts == ["型番はAB-12です。", "CD-34も確認！", "（補足あり）以上。"])
        #expect(r.rawAssembled == r.off)
    }

    // MARK: - GD-730 additions (FX-21..FX-38)

    @Test func fx21_longTakeSixSentences() {
        let r = run(["本日の定例を始めます。まず進捗を共有します。",
                     "設計書は昨日レビューが終わりました。指摘は三点ありました。",
                     "今日中に修正して再提出します。最後に日程を確認します。"])
        #expect(r.texts == ["本日の定例を始めます。", "まず進捗を共有します。",
                            "設計書は昨日レビューが終わりました。", "指摘は三点ありました。",
                            "今日中に修正して再提出します。", "最後に日程を確認します。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx22_commaTailJoinsNextSegment() {
        let r = run(["一つ目の案は費用を抑えられますが、工期が長くなります。",
                     "二つ目の案は、人員を追加して、期限を優先する進め方で、",
                     "三つ目の案は範囲を絞って来月に出す方針です。比較表を共有します。ご意見をお願いします。"])
        #expect(r.texts == ["一つ目の案は費用を抑えられますが、工期が長くなります。",
                            "二つ目の案は、人員を追加して、期限を優先する進め方で、三つ目の案は範囲を絞って来月に出す方針です。",
                            "比較表を共有します。", "ご意見をお願いします。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx23_decimalInUnit() {
        let r = runOne("前月比は3.5パーセントです。次に在庫数を確認します。")
        #expect(r.texts == ["前月比は3.5パーセントです。", "次に在庫数を確認します。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx24_versionString() {
        let r = runOne("検証環境をv2.4.1へ更新しました。設定ファイルは変えていません。")
        #expect(r.texts == ["検証環境をv2.4.1へ更新しました。", "設定ファイルは変えていません。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx25_unitEndingInAlnumBeforePeriod() {
        let r = run(["予算の上限は120万円です。", "対象サイズは256MB。予備領域も確保します。"])
        #expect(r.texts == ["予算の上限は120万円です。", "対象サイズは256MB。", "予備領域も確保します。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx26_asciiAbbreviationsAndSpaces() {
        let r = run(["詳細はRFC 9999を参照してください。", "応答形式はJSONです。API v2で動作します。"])
        #expect(r.texts == ["詳細はRFC 9999を参照してください。", "応答形式はJSONです。", "API v2で動作します。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx27_exclamationAndQuestion() {
        let r = run(["これで準備は完了ですか？はい、大丈夫です！", "では開始しましょう。"])
        #expect(r.texts == ["これで準備は完了ですか？", "はい、大丈夫です！", "では開始しましょう。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx28_ellipsisMidAndTrailing() {
        let r = run(["一応確認してみますが…おそらく明日になります。", "結果はまた連絡します…"])
        #expect(r.texts == ["一応確認してみますが…おそらく明日になります。", "結果はまた連絡します…"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx29_dashIsNotABoundary() {
        let r = run(["結論としては──今回は見送ります。", "理由は二つあります──予算と納期です。"])
        #expect(r.texts == ["結論としては──今回は見送ります。", "理由は二つあります──予算と納期です。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx30_identicalSentencesNotDeduped() {
        let r = run(["確認します。確認します。", "記録を残します。"])
        #expect(r.texts == ["確認します。", "確認します。", "記録を残します。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx31_nearDuplicateSentencesKeptInOrder() {
        let r = run(["来週の水曜日に会議を入れます。", "来週の木曜日に会議を入れます。"])
        #expect(r.texts == ["来週の水曜日に会議を入れます。", "来週の木曜日に会議を入れます。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx32_pauseEdgeWithoutPunctuationJoins() {
        let r = run(["午前の作業はここまでで", "午後は別の案件に移ります。"])
        #expect(r.texts == ["午前の作業はここまでで午後は別の案件に移ります。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx33_pauseEdgeWithPunctuationSplits() {
        let r = run(["資料の送付は終わりました。", "ところで、来月の予定表は更新済みですか？"])
        #expect(r.texts == ["資料の送付は終わりました。", "ところで、来月の予定表は更新済みですか？"])
        #expect(r.rawAssembled == r.off)
    }

    /// The '.' before an ASCII letter is a boundary (FX-34). The fixture's
    /// literal "Alpha. Beta" output is the whole-take post-process result;
    /// the executable invariant here is the split plus ON == OFF assembly.
    @Test func fx34_asciiPeriodBeforeAsciiLetter() {
        let r = run(["テスト環境はAlpha.", "Beta環境へ切り替えます。"])
        #expect(r.texts == ["テスト環境はAlpha.", "Beta環境へ切り替えます。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx35_noSpaceBetweenJapaneseUnits() {
        let r = run(["昨日の議事録を確認しました。", "次の担当者へ引き継ぎます。"])
        #expect(r.texts == ["昨日の議事録を確認しました。", "次の担当者へ引き継ぎます。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx36_numericStyleStaysPerUnit() {
        let r = run(["合計は1000円です。", "残高は二千円です。"])
        #expect(r.texts == ["合計は1000円です。", "残高は二千円です。"])
        #expect(r.rawAssembled == r.off)
    }

    /// FX-37 tolerates either treatment of a no-punctuation event edge. v1
    /// implements the FX-14 rule (punctuation only), so this joins into one
    /// unit and stays identical to the OFF result.
    @Test func fx37_noPunctuationEdgeJoins() {
        let r = run(["では次の議題に入ります", "新規案件の進捗報告です。"])
        #expect(r.texts == ["では次の議題に入ります新規案件の進捗報告です。"])
        #expect(r.rawAssembled == r.off)
    }

    @Test func fx38_cap130Sentences() {
        let events = (1...130).map { "項目\($0)を確認しました。" }
        let r = run(events)
        #expect(r.units.count == 129)
        let tail = (129...130).map { "項目\($0)を確認しました。" }.joined()
        #expect(r.units.last?.text == tail)
        #expect(r.units.last?.source == .capacity)
        #expect(r.rawAssembled == r.off)
    }

    // MARK: - cross-fixture invariants

    /// Sentence-wise deterministic processing joined equals whole-take
    /// processing for every fixture: concat(separator + proc(text)) must
    /// equal proc(whole) for any context-free proc.
    @Test func sentenceWiseJoinEqualsWholeTakeProcessing() {
        let fixtures: [[String]] = [
            ["きょうは雲留工房へ行く。明日は休む。"],
            ["準備はできたか？はい、完了です！出発しよう。"],
            ["議事録を確認した（詳細は第3区画の別紙を参照。改訂版あり。）。次に進む。"],
            ["「これで完了です。」次の議題へ移る。"],
            ["明日の荷物は", "第5倉庫へ運ぶ。"],
            ["担当者は「了解した", "。」と答えた。次へ進む。"],
            ["第一報です。現場は異常なし！続報は", "10分後に出す。"],
            ["テスト環境はAlpha.", "Beta環境へ切り替えます。"],
            ["型番はAB-12です。CD-34も確認！", "（補足あり）以上。"]
        ]
        func proc(_ s: String) -> String { s.replacingOccurrences(of: "確認", with: "検証") }
        for events in fixtures {
            let r = run(events)
            let joined = r.units.map { $0.separator + proc($0.text) }.joined()
            #expect(joined == proc(r.off))
        }
    }

    /// Per-sentence fallback: a unit whose processing failed keeps its raw
    /// text in the assembly instead of being dropped or replaced.
    @Test func perSentenceFallbackKeepsOriginalText() {
        let r = runOne("第一報です。現場は異常なし！続報を出す。")
        let processed: [Int: String?] = [0: "加工済み。", 1: nil, 2: "末尾加工。"]
        let assembled = r.units.map { $0.separator + (processed[$0.index].flatMap { $0 } ?? $0.text) }.joined()
        #expect(assembled == "加工済み。現場は異常なし！末尾加工。")
    }

    /// A rewritten finalized prefix (retry/rescue) conflicts and the caller
    /// falls back to whole-take handling rather than mixing texts.
    @Test func conflictedPrefixFlagsDegrade() {
        var segmenter = SentenceSegmenter()
        _ = segmenter.ingest("確認します。次へ進みます。")
        let emitted = segmenter.ingest("まったく別の確定テキスト")
        #expect(emitted.isEmpty)
        #expect(segmenter.conflicted)
    }

    /// Unclosed quote at take end flushes the whole remainder as one unit.
    @Test func unclosedQuoteFlushesAsOneUnit() {
        let r = runOne("会議で「来週の資料を更新しますと伝えました。")
        #expect(r.units.count == 1)
        #expect(r.texts == ["会議で「来週の資料を更新しますと伝えました。"])
        #expect(r.units.first?.source == .flush)
    }

    /// Quote state is per-take: a fresh segmenter carries nothing over.
    @Test func noCrossTakeCarryOver() {
        var first = SentenceSegmenter()
        _ = first.ingest("会議で「未閉の引用を残したまま")
        _ = first.flush()
        var second = SentenceSegmenter()
        let units = second.ingest("通常の文です。次の文です。")
        #expect(units.map(\.text) == ["通常の文です。", "次の文です。"])
    }
}
