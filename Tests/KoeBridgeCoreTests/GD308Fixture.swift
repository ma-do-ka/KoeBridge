import Foundation
import KoeBridgeCore

/// The GD‑308 Phase‑1 evaluation set: all 60 cases in typed form.
///
/// Transcribed from the GD‑308 sources (`/tmp/gd308-samples-dataset.csv`,
/// `gd308-01-correct-pairs-by-category.md`, `gd308-02-boundary-and-hold-cases.md`,
/// `gd308-03-verification-matrix-and-oq-mapping.md`).
///
/// - `written` is the 訂正後 (after) column, `originalFragment` the 訂正前 (before) column.
///   The CSV's inline annotations — "（既存登録：…）" (group G), "（訂正回数：1回）"
///   (BND-E05), "（連続スペース）" (BND-C03), "（読み生成失敗：…）" (BND-C04) — are
///   fixture context, not part of the correction pair; the group‑G annotations are
///   encoded as `seededRegistrations` instead.
/// - `expectedReading` is the matrix's 正解読み（ひらがな・仮置き）. It is asserted by the
///   gate only for `.ready` cases: the held cases' first recommended reading is governed
///   by B‑N5 (out of scope for this chunk).
/// - `expected` is the Phase‑1 outcome the verification matrix pins for the given
///   before/after evidence. Conditional rows are resolved by the decision the matrix
///   itself states:
///     * "条件付き自動確定" gated on the OQ‑06 phonetic-distance threshold, which is
///       still unset → hold (fail-safe; see CAT2-03, CAT2-06, CAT3-01).
///     * "自動確定（辞書一致時）" / "…があるため数字の読み揺れを解消可能" → ready when the
///       generated reading agrees with Y_before exactly (CAT2-08, CAT4-05).
/// - BND-H01..H03 are Stage 6 post-registration monitoring (B‑3). They are kept here
///   for completeness of the 60 but are out of the Phase‑1 gate's assertion scope.
enum GD308Fixture {
    enum Scope: String, Sendable {
        /// The 30 category pairs (CAT1..CAT4).
        case correctPair
        /// The 27 auto-registration-forbidden boundary cases (BND-A01..BND-G03).
        case forbidden
        /// The 3 Stage‑6 monitoring cases (BND-H01..H03), out of Phase‑1 scope.
        case monitoring
    }

    enum ExpectedOutcome: Sendable {
        /// Auto-confirm with the matrix-pinned reading.
        case ready
        /// Hold queue; `nil` reason means the matrix pins the status but not the reason.
        case pendingReview(VocabularyHoldReason?)
        /// Excluded from dictionary scope; `nil` reason as above.
        case excluded(VocabularyExclusionReason?)
        /// The matrix allows either a hold or an exclusion, but never auto-registration.
        case notReady
        /// Not asserted by the Phase‑1 gate (Stage 6 / B‑3).
        case outOfScope

        var label: String {
            switch self {
            case .ready: return "ready"
            case .pendingReview(let reason): return "pendingReview(\(reason.map { String(describing: $0) } ?? "any"))"
            case .excluded(let reason): return "excluded(\(reason.map { String(describing: $0) } ?? "any"))"
            case .notReady: return "notReady"
            case .outOfScope: return "outOfScope"
            }
        }
    }

    struct TestCase: Sendable {
        let id: String
        /// Fixture group: "CAT1".."CAT4" or "BND-A".."BND-H".
        let group: String
        let scope: Scope
        let written: String
        let originalFragment: String
        /// Matrix-pinned hiragana reading (asserted only when the case is `.ready`).
        let expectedReading: String?
        let expected: ExpectedOutcome
        /// Words the matrix declares as already registered in the profile (group G).
        let seededRegistrations: [(written: String, reading: String)]

        var expectsReady: Bool {
            if case .ready = expected { return true }
            return false
        }

        init(
            _ id: String,
            group: String,
            scope: Scope,
            written: String,
            originalFragment: String,
            expectedReading: String? = nil,
            expected: ExpectedOutcome,
            seededRegistrations: [(written: String, reading: String)] = []
        ) {
            self.id = id
            self.group = group
            self.scope = scope
            self.written = written
            self.originalFragment = originalFragment
            self.expectedReading = expectedReading
            self.expected = expected
            self.seededRegistrations = seededRegistrations
        }
    }

    /// The matrix's vocabulary type for each category (gd308-03 §1.1, 語彙タイプ).
    static func expectedTermType(for group: String) -> VocabularyTermType? {
        switch group {
        case "CAT1": return .kana
        case "CAT2": return .kanjiMixed
        case "CAT3": return .alphabet
        case "CAT4": return .numericMixed
        default: return nil
        }
    }

    static let allCases: [TestCase] = correctPairs + boundaryCases

    // MARK: - 01-correct-pairs-by-category.md (30)

    private static let correctPairs: [TestCase] = [
        // 1. カタカナ／ひらがな語 — 7/7 auto-confirm (matrix §1.1, §3.1-2).
        TestCase("CAT1-01", group: "CAT1", scope: .correctPair,
                 written: "クロハネ", originalFragment: "黒羽",
                 expectedReading: "くろはね", expected: .ready),
        TestCase("CAT1-02", group: "CAT1", scope: .correctPair,
                 written: "アストラ", originalFragment: "明日とら",
                 expectedReading: "あすとら", expected: .ready),
        TestCase("CAT1-03", group: "CAT1", scope: .correctPair,
                 written: "ハルカゼ", originalFragment: "春風",
                 expectedReading: "はるかぜ", expected: .ready),
        TestCase("CAT1-04", group: "CAT1", scope: .correctPair,
                 written: "シロガネ", originalFragment: "白金",
                 expectedReading: "しろがね", expected: .ready),
        TestCase("CAT1-05", group: "CAT1", scope: .correctPair,
                 written: "ゆうなぎ", originalFragment: "夕凪",
                 expectedReading: "ゆうなぎ", expected: .ready),
        TestCase("CAT1-06", group: "CAT1", scope: .correctPair,
                 written: "タカネー", originalFragment: "高値",
                 expectedReading: "たかねー", expected: .ready),
        TestCase("CAT1-07", group: "CAT1", scope: .correctPair,
                 written: "クモゲート", originalFragment: "雲ゲート",
                 expectedReading: "くもげーと", expected: .ready),

        // 2. 漢字・かな混じり語 — 3〜4 auto-confirm among 8 (matrix §1.1).
        TestCase("CAT2-01", group: "CAT2", scope: .correctPair,
                 written: "アストラ同期", originalFragment: "アストラ動機",
                 expectedReading: "あすとらどうき", expected: .ready),
        TestCase("CAT2-02", group: "CAT2", scope: .correctPair,
                 written: "稼働監視基盤", originalFragment: "稼働監視基板",
                 expectedReading: "かどうかんしきばん", expected: .ready),
        // 条件付き (せつえい vs せってい): OQ-06 distance threshold unset → hold.
        TestCase("CAT2-03", group: "CAT2", scope: .correctPair,
                 written: "音声入力設定", originalFragment: "音声入力設営",
                 expectedReading: "おんせいにゅうりょくせってい",
                 expected: .pendingReview(.phoneticDivergence)),
        TestCase("CAT2-04", group: "CAT2", scope: .correctPair,
                 written: "白峰データ", originalFragment: "白峯データ",
                 expectedReading: "しらみねでーた", expected: .ready),
        // 難読 + Y_before/Y_after mismatch → 保留（Y_before 推奨）.
        TestCase("CAT2-05", group: "CAT2", scope: .correctPair,
                 written: "霧峰システム", originalFragment: "切峰システム",
                 expectedReading: "きりみねしすてむ", expected: .pendingReview(nil)),
        // 条件付き (清濁の微小差): OQ-06 threshold unset → hold.
        TestCase("CAT2-06", group: "CAT2", scope: .correctPair,
                 written: "朝霧パイプライン", originalFragment: "朝切パイプライン",
                 expectedReading: "あさぎりぱいぷらいん", expected: .pendingReview(nil)),
        // 難読（辞書が別読みした場合 Y_before を一次証拠として保持）→ 保留.
        TestCase("CAT2-07", group: "CAT2", scope: .correctPair,
                 written: "水無瀬基盤", originalFragment: "みなせ基板",
                 expectedReading: "みなせきばん", expected: .pendingReview(nil)),
        // 自動確定（辞書一致時）: Y_before と辞書読みが一致 → ready.
        TestCase("CAT2-08", group: "CAT2", scope: .correctPair,
                 written: "夕凪帳票", originalFragment: "ゆうなぎ調表",
                 expectedReading: "ゆうなぎちょうひょう", expected: .ready),

        // 3. 英字・アルファベット略語 — 2 auto-confirm among 8 (matrix §1.1).
        // 条件付き (促音差 ぜっきゅう vs ぜっときゅー): OQ-06 unset → 保留.
        TestCase("CAT3-01", group: "CAT3", scope: .correctPair,
                 written: "ZQDB", originalFragment: "絶級DB",
                 expectedReading: "ぜっときゅーでぃーびー", expected: .pendingReview(nil)),
        // ローマ字固有名詞 → 保留（Y_before 推奨）.
        TestCase("CAT3-02", group: "CAT3", scope: .correctPair,
                 written: "Kurohane", originalFragment: "黒羽",
                 expectedReading: "くろはね",
                 expected: .pendingReview(.phoneticDivergence)),
        TestCase("CAT3-03", group: "CAT3", scope: .correctPair,
                 written: "VKLN", originalFragment: "ブイケーエルエヌ",
                 expectedReading: "ぶいけーえるえぬ", expected: .ready),
        TestCase("CAT3-04", group: "CAT3", scope: .correctPair,
                 written: "NXR", originalFragment: "エヌエックスアール",
                 expectedReading: "えぬえっくすあーる", expected: .ready),
        TestCase("CAT3-05", group: "CAT3", scope: .correctPair,
                 written: "KumoGate", originalFragment: "くもげーと",
                 expectedReading: "くもげーと", expected: .pendingReview(nil)),
        TestCase("CAT3-06", group: "CAT3", scope: .correctPair,
                 written: "HoshiDB", originalFragment: "星DB",
                 expectedReading: "ほしでぃーびー", expected: .pendingReview(nil)),
        TestCase("CAT3-07", group: "CAT3", scope: .correctPair,
                 written: "SoraGrid", originalFragment: "そらグリッド",
                 expectedReading: "そらぐりっど", expected: .pendingReview(nil)),
        TestCase("CAT3-08", group: "CAT3", scope: .correctPair,
                 written: "KazeLog", originalFragment: "風ログ",
                 expectedReading: "かぜろぐ", expected: .pendingReview(nil)),

        // 4. 数字・記号・英日混在語 — 2 auto-confirm among 7 (matrix §1.1).
        TestCase("CAT4-01", group: "CAT4", scope: .correctPair,
                 written: "MIRA基盤", originalFragment: "ミラ基盤",
                 expectedReading: "みらきばん",
                 expected: .pendingReview(.ambiguousAlphabetReading)),
        TestCase("CAT4-02", group: "CAT4", scope: .correctPair,
                 written: "Kurohane連携", originalFragment: "黒羽連携",
                 expectedReading: "くろはねれんけい", expected: .pendingReview(nil)),
        TestCase("CAT4-03", group: "CAT4", scope: .correctPair,
                 written: "Astora Sync", originalFragment: "アストラシンク",
                 expectedReading: "あすとらしんく",
                 expected: .pendingReview(.writtenContainsForbiddenCharacters)),
        TestCase("CAT4-04", group: "CAT4", scope: .correctPair,
                 written: "ZQDB同期", originalFragment: "ぜっときゅーでぃーびー同期",
                 expectedReading: "ぜっときゅーでぃーびーどうき", expected: .ready),
        // 条件付き (数字読み揺れ) だが Y_before に「ぶいつー」の明確な対応音がある → ready.
        TestCase("CAT4-05", group: "CAT4", scope: .correctPair,
                 written: "V2連携", originalFragment: "ブイツー連携",
                 expectedReading: "ぶいつーれんけい", expected: .ready),
        TestCase("CAT4-06", group: "CAT4", scope: .correctPair,
                 written: "ステップB設計", originalFragment: "ステップびー設計",
                 expectedReading: "すてっぷびーせっけい", expected: .ready),
        TestCase("CAT4-07", group: "CAT4", scope: .correctPair,
                 written: "KumoGate第3版", originalFragment: "くもげーとだいさんはん",
                 expectedReading: "くもげーとだいさんはん", expected: .pendingReview(nil)),
    ]

    // MARK: - 02-boundary-and-hold-cases.md (30: 27 forbidden + 3 monitoring)

    private static let boundaryCases: [TestCase] = [
        // A. 短読ガード (1〜2 mora) — 保留 pending_review.
        TestCase("BND-A01", group: "BND-A", scope: .forbidden,
                 written: "QA", originalFragment: "課",
                 expected: .pendingReview(.shortReadingGuard)),
        TestCase("BND-A02", group: "BND-A", scope: .forbidden,
                 written: "NOA", originalFragment: "野合",
                 expected: .pendingReview(.shortReadingGuard)),
        TestCase("BND-A03", group: "BND-A", scope: .forbidden,
                 written: "K", originalFragment: "系",
                 expected: .pendingReview(.shortReadingGuard)),
        TestCase("BND-A04", group: "BND-A", scope: .forbidden,
                 written: "RI", originalFragment: "理",
                 expected: .pendingReview(.shortReadingGuard)),

        // B. 長読ガード (>20 mora / 文丸ごと).
        TestCase("BND-B01", group: "BND-B", scope: .forbidden,
                 written: "霧峰システム次世代音声認識基盤運用管理ポータル",
                 originalFragment: "霧峰システム次世代音声認識基板運用管理ポータル",
                 expected: .pendingReview(.longReadingGuard)),
        // 除外（対象外）または保留 → never ready.
        TestCase("BND-B02", group: "BND-B", scope: .forbidden,
                 written: "明日の会議までにアストラ同期の設定を確認します",
                 originalFragment: "明日の会議までにアストラ動機の設定を確認します",
                 expected: .notReady),
        // 保留または除外 → never ready.
        TestCase("BND-B03", group: "BND-B", scope: .forbidden,
                 written: "クロハネ基盤とミドリノ帳票の夜間バッチ連携手順書",
                 originalFragment: "クロハネ基板とミドリノ調表の夜間バッチ連携手順書",
                 expected: .notReady),

        // C. 表記禁止文字・文字種制約違反.
        TestCase("BND-C01", group: "BND-C", scope: .forbidden,
                 written: "Astora|Sync", originalFragment: "アストラパイプシンク",
                 expected: .pendingReview(.writtenContainsForbiddenCharacters)),
        // 除外または保留（サニタイズ要確認）→ never ready.
        TestCase("BND-C02", group: "BND-C", scope: .forbidden,
                 written: "Kurohane:v2", originalFragment: "クロハネブイツー",
                 expected: .notReady),
        TestCase("BND-C03", group: "BND-C", scope: .forbidden,
                 written: "Astora  Sync", originalFragment: "アストラシンク",
                 expected: .pendingReview(nil)),
        TestCase("BND-C04", group: "BND-C", scope: .forbidden,
                 written: "ZQDB", originalFragment: "絶級DB",
                 expected: .pendingReview(nil)),

        // D. 音韻乖離・音響大外れ・認識元差 — 保留.
        TestCase("BND-D01", group: "BND-D", scope: .forbidden,
                 written: "Kurohane", originalFragment: "全然違う",
                 expected: .pendingReview(.phoneticDivergence)),
        TestCase("BND-D02", group: "BND-D", scope: .forbidden,
                 written: "霧峰システム", originalFragment: "会議資料",
                 expected: .pendingReview(.phoneticDivergence)),
        TestCase("BND-D03", group: "BND-D", scope: .forbidden,
                 written: "ZQDB", originalFragment: "データベース",
                 expected: .pendingReview(.phoneticDivergence)),
        TestCase("BND-D04", group: "BND-D", scope: .forbidden,
                 written: "アストラ同期", originalFragment: "システム障害",
                 expected: .pendingReview(.phoneticDivergence)),

        // E. 訂正範囲ノイズ・一過性修正・回数不足.
        TestCase("BND-E01", group: "BND-E", scope: .forbidden,
                 written: "霧峰", originalFragment: "えーと霧峰",
                 expected: .pendingReview(nil)),
        TestCase("BND-E02", group: "BND-E", scope: .forbidden,
                 written: "アストラ同期", originalFragment: "アストラ同期を",
                 expected: .pendingReview(nil)),
        TestCase("BND-E03", group: "BND-E", scope: .forbidden,
                 written: "アストラ同期", originalFragment: "アストラ同期、",
                 expected: .excluded(.noiseOnly)),
        TestCase("BND-E04", group: "BND-E", scope: .forbidden,
                 written: "仕様を変更した", originalFragment: "機能を追加した",
                 expected: .excluded(.noiseOnly)),
        // 留め置き candidate（蓄積中）: not auto-registrable in Phase 1.
        TestCase("BND-E05", group: "BND-E", scope: .forbidden,
                 written: "霧峰システム", originalFragment: "切峰システム",
                 expected: .pendingReview(nil)),

        // F. 難読・読み方拮抗・数字読み揺れ — 保留.
        TestCase("BND-F01", group: "BND-F", scope: .forbidden,
                 written: "MIRA", originalFragment: "ミラ",
                 expected: .pendingReview(nil)),
        TestCase("BND-F02", group: "BND-F", scope: .forbidden,
                 written: "NORA", originalFragment: "ノラ",
                 expected: .pendingReview(nil)),
        TestCase("BND-F03", group: "BND-F", scope: .forbidden,
                 written: "Kurohane204", originalFragment: "黒羽二〇四",
                 expected: .pendingReview(nil)),
        // 難読不一致 + Y_before の1音ズレ (つきあげ vs つきかげ) → 音韻乖離で保留.
        TestCase("BND-F04", group: "BND-F", scope: .forbidden,
                 written: "月影モジュール", originalFragment: "突き上げモジュール",
                 expected: .pendingReview(.phoneticDivergence)),

        // G. 同一クラス内重複読み衝突 — 保留（競合提示）, existing words seeded.
        TestCase("BND-G01", group: "BND-G", scope: .forbidden,
                 written: "Kurohane", originalFragment: "黒羽",
                 expected: .pendingReview(.duplicateReadingCollision),
                 seededRegistrations: [(written: "クロハネ", reading: "くろはね")]),
        TestCase("BND-G02", group: "BND-G", scope: .forbidden,
                 written: "アストラ動悸", originalFragment: "アストラ動機",
                 expected: .pendingReview(.duplicateReadingCollision),
                 seededRegistrations: [(written: "アストラ同期", reading: "あすとらどうき")]),
        TestCase("BND-G03", group: "BND-G", scope: .forbidden,
                 written: "切峰", originalFragment: "霧峰",
                 expected: .pendingReview(nil),
                 seededRegistrations: [(written: "霧峰", reading: "きりみね")]),

        // H. 登録後モニタリング (Stage 6 / B-3) — out of Phase‑1 assertion scope.
        TestCase("BND-H01", group: "BND-H", scope: .monitoring,
                 written: "", originalFragment: "", expected: .outOfScope),
        TestCase("BND-H02", group: "BND-H", scope: .monitoring,
                 written: "", originalFragment: "", expected: .outOfScope),
        TestCase("BND-H03", group: "BND-H", scope: .monitoring,
                 written: "", originalFragment: "", expected: .outOfScope),
    ]
}
