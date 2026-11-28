import Foundation

/// B-4 文案正本。GD-469 01/02/03 と GD-369 02 の確定文案をここに集約し、
/// 画面コードと回帰テストの両方が同じ文字列を参照する。
/// `verbatim` コメント付きの値は文案ファイルからの転記であり、言い換え禁止。
/// GD-369 の `[要確認:...]` 注記は裁定により文案どおり表示する。
public enum AmiVoiceVocabularyManagementCopy {
    /// 同意記録と一緒に保存する文案版の識別子。文案差し替え時に更新する。
    public static let consentCopyIdentifier = "gd369-02"

    // MARK: - 初回同意パネル（GD-369 02 §1 / verbatim）

    public static let consentTitle = "学習した語彙の AmiVoice 自動同期を有効にしますか？"
    public static let consentIntro = "音声入力の修正履歴から抽出した専門用語などを、アドバンスト・メディア社の AmiVoice へ自動同期します。開始前に、以下の内容をご確認ください。"
    public static let consentItemSentTitle = "送信するもの"
    public static let consentItemSentBody = "修正履歴から抽出した単語の **「表記」**（Hybrid エンジン利用時は **「読み」** を含む）のみを送信します。文章全体や、除外に設定した語彙、確認待ちの語彙は送信しません。"
    public static let consentItemDestinationTitle = "送信先とデータの扱い（`nolog` との違い）"
    public static let consentItemDestinationBody = "送信先はアドバンスト・メディア社の AmiVoice サーバーです。音声認識本体の **「ログ保存なし（`nolog`）」** とは別に、Hybrid エンジンの単語登録（`profileId`）では、次回以降の認識精度を高めるため登録した語彙がサーバー側プロファイルに保持されます。\n（※社内機密や人名など外部へ送りたくない語彙がある場合は、個別に除外するか本機能を OFF のままご利用ください）\n[要確認：OQ-07 サーバー側プロファイルの保持期間・削除時挙動に関する確定文言を1行追記]"
    public static let consentItemControlTitle = "やめ方と管理方法"
    public static let consentItemControlBody = "送信される語彙は用語管理画面でいつでも確認できます。自動同期の停止（OFF）、特定の単語の除外・削除、同期済み単語の一括削除は、設定画面からいつでも行えます。"
    public static let consentAgreeButton = "同意して有効にする"
    public static let consentCancelButton = "キャンセル"
    public static let consentDetailsLink = "詳しい仕組み・プライバシーを見る"

    // MARK: - 設定画面拡張（GD-369 02 §3 / verbatim）

    public static let autoSyncToggleTitle = "学習修正を AmiVoice 単語登録へ自動同期する"
    public static let autoSyncToggleSupplementHybrid = "修正した語彙から表記と読みを抽出し、AmiVoice へ自動反映します。文章全体は送信されません。現在のエンジンでは読み付き単語登録（profileId）として動作します。"
    public static let autoSyncToggleSupplementE2E = "修正した語彙から表記と読みを抽出し、AmiVoice へ自動反映します。文章全体は送信されません。現在のエンジンでは表記ブースト（profileWords）として動作します。"
    public static let openManagementButton = "用語管理・確認待ちを開く"
    public static let rollbackButton = "1 ステップ前の辞書状態へ戻す"
    public static let deleteAllButton = "AmiVoice 側の同期済み単語をすべて削除"
    public static let privacyAddendum = "**語彙の自動同期（任意・初期設定 OFF）**：有効にした場合のみ、抽出した単語の表記（Hybrid エンジン時は読みを含む）がアドバンスト・メディア社のサーバーへ送信されます。Hybrid エンジンの単語登録では、音声ログを保存しない `nolog` 接続とは別に、登録語彙がサーバー側プロファイルに保持されます。いつでも OFF・個別除外・一括削除が可能です。"

    // MARK: - 一覧画面（GD-469 01 §1 / verbatim）

    public static let managementTitle = "用語管理（AmiVoice 自動同期）"
    public static let managementSubtitle = "音声入力の修正から覚えた専門用語や固有名詞を確認・編集できます。同期済みの語彙は次回以降の認識精度向上に使われます。"
    public static func countSummary(active: Int) -> String {
        "登録中：\(active) 語（上限目安 1,000 語）"
    }
    public static func filteredSummary(total: Int, filtered: Int) -> String {
        "全 \(total) 語中 \(filtered) 語を表示"
    }
    public static let addEntryButton = "用語を追加"
    public static let menuSyncNow = "今すぐ同期"
    public static let menuRollback = "1 ステップ前の辞書状態へ戻す"
    public static let menuDeleteAll = "AmiVoice 側の同期済み単語をすべて削除…"

    // MARK: - エンジン別案内バー（GD-469 01 §2 / verbatim）

    public static let engineBarHybrid = "Hybrid エンジン使用中：表記と読みを AmiVoice の単語登録（ユーザー辞書）へ自動同期します。"
    public static let engineBarHybridAction = "同期設定を開く"
    public static let engineBarE2E = "E2E エンジン使用中：表記のみを認識時の単語強調（profileWords）として送信します。読みの登録は不要です。"
    public static let engineBarE2EAction = "認識エンジンを変更"
    public static let engineBarSyncOff = "自動同期は現在 OFF です。用語の確認や手動編集はできますが、AmiVoice 側へは送信されません。"
    public static let engineBarSyncOffAction = "自動同期を ON にする"
    public static let engineBarAuthMissing = "AmiVoice の API 接続が未設定または無効なため、自動同期を停止しています。"
    public static let engineBarAuthAction = "API 接続を確認"

    // MARK: - ステータスバッジ・フィルタ（GD-469 01 §3 / verbatim）

    public static let statusLabelSynced = "同期済み"
    public static let statusTooltipSynced = "AmiVoice 側へ反映済みです。次回以降の音声認識で使われます。"
    public static let statusLabelPendingReview = "確認待ち"
    public static let statusTooltipPendingReview = "読みの確認または競合の解消が必要です。承認するまで AmiVoice へは送信されません。"
    public static func filterTabPendingReview(_ count: Int) -> String {
        "確認待ち（\(count)）"
    }
    public static let statusLabelReadyToSync = "同期待ち"
    public static let statusTooltipReadyToSync = "次のバックグラウンド同期で AmiVoice へ反映されます。"
    public static let statusLabelAutoDisabled = "一時停止"
    public static let statusTooltipAutoDisabled = "誤変換の兆候を検知したため自動で取り下げました。読みを見直すか除外できます。"
    public static let statusLabelSyncFailed = "同期失敗"
    public static let statusTooltipSyncFailed = "形式エラーなどにより登録できませんでした。内容を確認して修正してください。"
    public static let filterTabAttention = "要確認"
    public static let statusLabelArchived = "上限退避"
    public static let statusTooltipArchived = "登録上限に近づいたため、長期間使われていない自動同期語として同期対象から外しました。"
    public static let statusLabelIgnored = "除外"
    public static let statusTooltipIgnored = "AmiVoice へ送信しない設定です。同じ修正をしても自動では再登録されません。"
    public static let statusLabelProtected = "保護"
    public static let statusTooltipProtected = "手動登録または承認済みの語彙です。上限到達時も自動で入れ替えられません。"
    public static let filterTabAll = "すべて"
    public static func attentionBanner(_ count: Int) -> String {
        "確認が必要な用語が \(count) 件あります。承認するまで確認待ちの用語は AmiVoice へ送信されません。"
    }
    public static let attentionBannerButton = "確認待ちだけを表示"

    // MARK: - 検索・並び替え・列見出し（GD-469 01 §4 / verbatim）

    public static let searchPlaceholder = "表記や読みで検索"
    public static let searchClearLabel = "検索条件をクリア"
    public static let resetFilterButton = "条件を解除してすべて表示"
    public static let sortLabel = "並び替え："
    public static let sortOptionAttention = "確認が必要な順"
    public static let sortOptionNewest = "更新が新しい順"
    public static let sortOptionCorrectionCount = "訂正回数が多い順"
    public static let sortOptionWritten = "表記順（A→Z・五十音）"
    public static let columnWritten = "表記"
    public static let columnReading = "読み"
    public static let columnReadingE2E = "読み（E2E では未使用）"
    public static let columnStatus = "状態"
    public static let columnUpdatedAt = "最終更新"
    public static let columnActions = "操作"
    public static let rowActionEdit = "編集"
    public static let rowActionReview = "確認する"
    public static let rowActionExclude = "除外"
    public static let rowActionDelete = "削除"

    // MARK: - 上限警告バナー（GD-469 01 §5 / verbatim）

    public static func softCapTitle(active: Int) -> String {
        "登録語数が上限目安に近づいています（\(active) / 1,000 語）"
    }
    public static let softCapBody = "上限の 1,000 語を超えると、長期間使われていない自動同期語から順に同期対象外へ退避されます（手動登録・承認済みの用語は保護されます）。"
    public static let softCapButton = "整理候補を見る"
    public static let hardCapTitle = "登録語数が上限（1,000 語）に達したため、新規の自動同期を一時停止しています"
    public static let hardCapBody = "手動登録・承認済みの保護対象だけで上限に達しています。不要な用語を除外または削除すると、自動同期を再開できます。"
    public static let hardCapButton = "保護中の用語を確認"

    // MARK: - 同期ステータスバー（GD-469 01 §6 / verbatim）

    public static func syncBarSynced(_ timestamp: String) -> String {
        "最終同期：\(timestamp)（AmiVoice と同期済み）"
    }
    public static let syncBarSyncing = "AmiVoice と同期しています…（音声入力はそのまま使えます）"
    public static func syncBarPending(_ count: Int) -> String {
        "オフラインのため未同期の変更が \(count) 件あります。接続が戻りしだい自動で再同期します。"
    }
    public static let syncBarResyncButton = "今すぐ再同期"

    // MARK: - 空状態（GD-469 01 §7 / verbatim）

    public static let emptyOnTitle = "まだ同期された用語はありません"
    public static let emptyOnBody = "普段どおり音声入力の結果を修正していくと、よく使う専門用語や固有名詞がここに自動で集まります。手動であらかじめ登録することもできます。"
    public static let emptyOnAssurance = "用語が未登録のままでも、KoeBridge の音声入力は標準設定でそのまま使えます。"
    public static let emptyOnHint = "登録の例（架空）：表記「アストラ同期」／読み「あすとらどうき」、表記「Kurohane」／読み「くろはね」"
    public static let emptyPrimaryButton = "最初の用語を追加する"
    public static let emptyOffTitle = "まだ用語は登録されていません"
    public static let emptyOffBody = "「学習修正を AmiVoice 単語登録へ自動同期する」を ON にすると、修正履歴から覚えた用語をここで管理できます。手動での用語登録だけでも利用できます。"
    public static let emptyOffAssurance = "未登録のままでも音声入力はそのまま使えます。"
    public static let emptyOffSecondaryLink = "自動同期の設定を見る"
    public static let emptyFilteredTitle = "条件に一致する用語が見つかりませんでした"
    public static let emptyFilteredBody = "入力したキーワードに誤字がないか確認するか、状態の絞り込みを緩めてもう一度お試しください。"

    // MARK: - 追加・編集フォーム（GD-469 02 §1 / verbatim）

    public static let formTitleAdd = "用語を追加"
    public static let formTitleEdit = "用語を編集"
    public static let formWrittenLabel = "表記"
    public static let formWrittenNote = "音声認識の結果として出力したい文字を入力します。半角の「|」「:」は使えません。半角スペースは自動的に「_」として登録されます。"
    public static let formWrittenPlaceholder = "例：アストラ同期、Astora Sync"
    public static let formReadingLabel = "読み"
    public static let formReadingNote = "実際に発音するとおりの読みをひらがな（またはカタカナ）で入力します。1〜2 文字の短い読みは他の言葉と誤変換されやすいためご注意ください。[要確認：OQ-05 文字種統一]"
    public static let formReadingPlaceholder = "例：あすとらどうき、くろはね"
    public static let formAlternativeReadingLabel = "別の読みを追加（任意）"
    public static let formAlternativeReadingNote = "同じ表記に複数の呼び方・略称がある場合は追加できます（既存の読みは残ります）。"
    public static let formAlternativeReadingPlaceholder = "例：くろはね、くろ"
    public static let formClassLabel = "品詞・クラス（任意）"
    public static let formClassNote = "未指定のままで問題ありません（標準設定が使われます）。"
    public static let formClassPlaceholder = "指定なし（標準）"
    public static let formSyncModeLabel = "AmiVoice への同期"
    public static let formSyncModeNote = "「同期する」にすると AmiVoice へ反映され、保護対象（自動入替の対象外）になります。「除外する」にすると送信せず、自動再登録も止めます。"
    public static let formSyncModeSync = "同期する（推奨）"
    public static let formSyncModeExclude = "除外する（送信しない）"
    public static let formLearningSourceLabel = "学習のきっかけ（参考）"
    public static func formLearningSource(fragment: String, term: String, corrections: Int) -> String {
        "直近の修正：「\(fragment)」→「\(term)」（訂正回数：\(corrections) 回／認識元：AmiVoice）"
    }
    public static let formSaveAddButton = "追加して同期"
    public static let formSaveAddButtonSyncOff = "追加する"
    public static let formSaveEditButton = "変更を保存"
    public static let formSaving = "保存中…"
    public static let formCancelButton = "キャンセル"
    public static func savedToast(surface: String) -> String {
        "「\(surface)」を保存しました。バックグラウンドで AmiVoice へ反映します。"
    }
    public static func savedToastSyncOff(surface: String) -> String {
        "「\(surface)」を保存しました（自動同期が OFF のため、ローカルのみに保存されています）。"
    }

    // MARK: - 確認待ちレビュー（GD-469 02 §2 / verbatim）

    public static let reviewPanelTitle = "読みの確認が必要です"
    public static let reviewReasonPhonetic = "表記から推定した読みと、修正前の発音手がかりが一致しなかったため確認待ちにしました。"
    public static func reviewReasonShortReading(_ mora: Int) -> String {
        "読みが短く（\(mora) 文字）、日常の言葉と誤変換される可能性があるため自動登録を見送りました。"
    }
    public static func reviewReasonDuplicateReading(surface: String, reading: String) -> String {
        "すでに登録済みの「\(surface)」と同じ読み（「\(reading)」）のため、上書きせず確認待ちにしました。"
    }
    public static let reviewReasonDivergence = "修正前のテキストと推定読みの差が大きいため、誤登録を防ぐ目的で確認待ちにしました。"
    public static let reviewReasonAlphanumeric = "英字・数字を含むため、実際の発音に近い読みを選んでください。"
    public static func reviewSuggestedChip(_ reading: String) -> String {
        "発音からの推奨候補：\(reading)"
    }
    public static let reviewApproveButton = "この読みで承認して同期"
    public static let reviewExcludeButton = "除外する（同期しない）"
    public static let reviewLaterButton = "あとで確認する"

    // MARK: - 確認ダイアログ（GD-469 02 §3 / verbatim）

    public static let unsavedTitle = "保存していない変更があります"
    public static let unsavedBody = "このまま画面を閉じると、入力中の変更は失われます。保存してから閉じますか？"
    public static let unsavedSaveAndClose = "保存して閉じる"
    public static let unsavedContinueEditing = "編集を続ける"
    public static let unsavedDiscard = "変更を破棄"

    public static func excludeToast(surface: String) -> String {
        "「\(surface)」を同期対象から除外しました（AmiVoice 側からも削除します）。"
    }
    public static let excludeUndoButton = "元に戻す"
    public static func excludeConfirmTitle(surface: String) -> String {
        "「\(surface)」を同期から除外しますか？"
    }
    public static let excludeConfirmBody = "AmiVoice 側の単語登録からも削除され、今後同じ修正を行っても自動では再登録されなくなります。後から「除外」タブで解除できます。"
    public static let excludeConfirmButton = "除外する"

    public static func deleteConfirmTitle(surface: String) -> String {
        "「\(surface)」を削除しますか？"
    }
    public static let deleteConfirmBody = "この用語を KoeBridge の用語一覧と AmiVoice 側の単語登録から削除します。この操作は取り消せません。今後また自動登録されるのを防ぎたい場合は「除外」を選んでください。"
    public static let deleteConfirmButton = "削除する"
    public static let deleteConfirmExcludeInstead = "除外にする"

    public static let deleteAllTitle = "AmiVoice 側の同期済み単語をすべて削除しますか？"
    public static func deleteAllBody(syncedCount: Int) -> String {
        "AmiVoice サーバー上に登録されている KoeBridge 由来の単語（現在 \(syncedCount) 語）をすべて削除します。削除後、自動同期は自動で OFF になります（ローカルの用語一覧の扱いは次から選べます）。[要確認：OQ-04/OQ-07 サーバー側即時削除の反映タイミングを追記]"
    }
    public static let deleteAllOptionServerOnly = "AmiVoice 側だけ削除し、KoeBridge の一覧は残す（推奨）"
    public static let deleteAllOptionBoth = "AmiVoice 側と KoeBridge の一覧の両方を削除する"
    public static let deleteAllConfirmButton = "すべて削除する"
    public static let deleteAllToast = "AmiVoice 側の同期済み単語をすべて削除し、自動同期を OFF にしました。"
    public static let deleteAllSyncOffNotice = "自動同期が OFF のため、AmiVoice 側への送信は行わず、KoeBridge 内の一覧だけを削除します。"

    public static let rollbackTitle = "1 ステップ前の辞書状態へ戻しますか？"
    public static func rollbackBody(lastSyncAt: String, added: Int, updated: Int, removed: Int) -> String {
        "直前の自動同期（\(lastSyncAt)：追加 \(added) 語・変更 \(updated) 語・削除 \(removed) 語）を取り消し、その直前の状態へ戻します。音声認識の精度が不安定になったときにお使いください。"
    }
    public static let rollbackConfirmButton = "1 ステップ前へ戻す"
    public static let rollbackToast = "1 ステップ前の辞書状態へ戻しました。バックグラウンドで AmiVoice へ反映します。"

    // MARK: - バリデーション（GD-469 03 §3 / verbatim）

    public static let validationEmptyWritten = "表記が入力されていません。音声認識で出力したい文字を入力してください。"
    public static let validationEmptyReading = "読みが入力されていません。実際の発音に近いひらがな（またはカタカナ）を入力してください。"
    public static let validationForbiddenWritten = "表記に半角の「|」や「:」は使用できません。該当の記号を削除するか、別の表記へ変更してください。"
    public static let validationInvalidReading = "読みにはひらがな（またはカタカナ）のみ入力できます。漢字や英数字をかなに直してください。"
    public static let validationLongReading = "読みが長すぎるため登録できません（上限目安：20 モーラ）。文章ではなく単語単位に短くしてください。"
    public static let validationDuplicatePair = "同じ「表記」と「読み」の組み合わせがすでに登録されています。一覧から既存の用語をご確認ください。"
    public static func warningShortReading(_ mora: Int) -> String {
        "読みが短いため（\(mora) 文字）、普段の別の言葉が誤変換されることがあります。このまま登録する場合は、認識結果に違和感がないか後ほどご確認ください。"
    }
    public static func warningDuplicateReading(reading: String, surface: String) -> String {
        "同じ読み「\(reading)」がすでに「\(surface)」で使われています。誤変換を避けるため、別の読みにするか既存用語の見直しをおすすめします。"
    }
    public static let noticeWrittenSpace = "表記に含まれる半角スペースは、AmiVoice の仕様に合わせて半角下線（_）として登録されます（例：Astora_Sync）。"

    // MARK: - 同期エラー・通知（GD-469 03 §4 / verbatim）

    public static let syncErrorTemporary = "一時的な通信エラーのため AmiVoice への同期を保留しています（音声入力は通常どおり使えます）。接続が戻りしだい自動で再試行します。"
    public static let syncErrorTemporaryButton = "今すぐ再同期"
    public static func syncErrorValidation(_ failed: Int) -> String {
        "一部の用語（\(failed) 件）を AmiVoice へ登録できませんでした。他の正常な用語は同期済みです。「要確認」から内容を見直してください。"
    }
    public static let syncErrorValidationButton = "要確認を表示"
    public static let syncErrorCap = "AmiVoice の単語登録が上限（1,000 語）に達したため、新しい用語を同期できませんでした。不要な用語を除外・削除してから再同期してください。"
    public static let syncErrorCapButton = "整理する"
    public static let syncErrorAuth = "AmiVoice の API キーが確認できないため自動同期を停止しています。「API 接続」設定でキーを確認してください。"
    public static let syncErrorAuthButton = "API 接続を開く"
    public static let saveFailure = "変更を保存できませんでした。入力内容はそのまま残っています。少し時間をおいてもう一度「変更を保存」を押してください。"
    public static func quarantineNotice(surface: String) -> String {
        "「\(surface)」は別の言葉へ何度も修正されたため、誤変換を防ぐ目的で一時停止しました（AmiVoice 側からも取り下げ済み）。必要に応じて読みを見直すか除外してください。"
    }
    public static let ineffectiveMemo = "登録後も同じ修正が続いています。実際の発音に合わせて「読み」を見直すか、別の読みを追加してみてください。"

    // MARK: - ロールバック履歴・状態表示（文案の一覧用補助。GD-469 の確定行のみ正本）

    /// スナップショットの trigger 種別表示。文案に一覧固有の行が無いため、
    /// CRS-01 の用語統一に沿った中立表記を使う。
    public static func snapshotTriggerLabel(_ trigger: AmiVoiceDictionarySnapshotTrigger) -> String {
        switch trigger {
        case .normal: return "自動同期"
        case .manualImmediate: return "今すぐ同期"
        case .launchRestore: return "起動時の復元"
        case .rollback: return "1 ステップ前へ戻す操作"
        }
    }

    public static func snapshotStatusLabel(_ status: AmiVoiceDictionarySnapshotStatus) -> String {
        switch status {
        case .reflected: return "反映済み"
        case .failed: return "反映失敗"
        }
    }

    /// ロールバック後の反映が未完了のときの警告。GD-469 03 §4① の文体に合わせた中立表記。
    public static let rollbackReflectionPending = "前回の戻し結果が AmiVoice 側へまだ反映されていません（音声入力は通常どおり使えます）。接続が戻りしだい自動で再試行します。"
    public static let rollbackReflectionRetry = "反映を再試行"
    public static let rollbackHistoryTitle = "同期履歴"
    public static func rollbackToSnapshotButton(_ timestamp: String) -> String {
        "この状態（\(timestamp)）へ戻す"
    }

    // MARK: - 状態ラベル解決

    /// GD-469 01 §3 のバッジ表。状態は短いラベル語で必ず文字として出す（色のみ依存禁止）。
    public static func statusLabel(for state: AmiVoiceDictionaryEntryState) -> String {
        switch state {
        case .autoSynced: return statusLabelSynced
        case .pendingReview: return statusLabelPendingReview
        case .readyToSync: return statusLabelReadyToSync
        case .autoDisabled: return statusLabelAutoDisabled
        case .syncFailed: return statusLabelSyncFailed
        case .archived: return statusLabelArchived
        case .ignored: return statusLabelIgnored
        case .candidate: return statusLabelPendingReview
        }
    }

    public static func statusTooltip(for state: AmiVoiceDictionaryEntryState) -> String {
        switch state {
        case .autoSynced: return statusTooltipSynced
        case .pendingReview: return statusTooltipPendingReview
        case .readyToSync: return statusTooltipReadyToSync
        case .autoDisabled: return statusTooltipAutoDisabled
        case .syncFailed: return statusTooltipSyncFailed
        case .archived: return statusTooltipArchived
        case .ignored: return statusTooltipIgnored
        case .candidate: return statusTooltipPendingReview
        }
    }

    /// 状態バッジに添える図形アイコン名（SF Symbols）。色だけに頼らない表記ルールの形状側。
    public static func statusSymbol(for state: AmiVoiceDictionaryEntryState) -> String {
        switch state {
        case .autoSynced: return "checkmark.circle.fill"
        case .pendingReview: return "questionmark.circle.fill"
        case .readyToSync: return "clock.circle.fill"
        case .autoDisabled: return "pause.circle.fill"
        case .syncFailed: return "exclamationmark.triangle.fill"
        case .archived: return "archivebox.fill"
        case .ignored: return "minus.circle.fill"
        case .candidate: return "questionmark.circle.fill"
        }
    }

    // MARK: - 確認待ち理由の解決（GD-469 02 §2 の5理由＋中立フォールバック）

    /// B-2 の保留理由を GD-469 の確定理由文へ写像する。文案に該当しない
    /// 理由は中立の汎用行を返す。
    public static func reviewReasonText(
        for reason: VocabularyHoldReason?,
        reading: String?,
        existingSurface: String?,
        moraCount: Int
    ) -> String {
        guard let reason else {
            return reviewReasonFallback
        }
        switch reason {
        case .phoneticDivergence:
            return reviewReasonPhonetic
        case .shortReadingGuard:
            return reviewReasonShortReading(moraCount)
        case .duplicateReadingCollision:
            return reviewReasonDuplicateReading(surface: existingSurface ?? "登録済みの用語", reading: reading ?? "")
        case .readingGenerationUnavailable, .invalidWrittenCharacters:
            return reviewReasonDivergence
        case .ambiguousAlphabetReading, .numericReadingAmbiguous, .readingCharacterInvalid:
            return reviewReasonAlphanumeric
        case .writtenContainsForbiddenCharacters, .writtenEmptyAfterNormalization,
             .punctuationOnlyRewrite, .sameSoundOrthographyChange, .fillerOrParticleInclusion,
             .longReadingGuard, .capExceededSoft, .capExceededSafety:
            return reviewReasonFallback
        }
    }

    /// 文案に割り当てのない保留理由への中立フォールバック（プレースホルダー）。
    public static let reviewReasonFallback = "内容を確認のうえ、読みを決めてから承認してください。"

    // MARK: - その他の中立補助行（文案未定義分・プレースホルダー）

    /// 一覧を再取得するときの補助。文案に無いので最小の行のみ追加する。
    public static let restoreExcludedButton = "除外を解除"
    public static let quarantineRestoreButton = "この読みで復帰"
    public static let quarantineEditButton = "読みを見直す"
    public static let managementCloseButton = "閉じる"
    public static let reviewSectionTitle = "確認待ち"
    public static let entriesSectionTitle = "用語一覧"
    public static func lastUpdatedLabel(_ timestamp: String) -> String {
        "最終更新：\(timestamp)"
    }
    public static func deleteAllOutcomeLocalOnly(_ removed: Int) -> String {
        "自動同期が OFF のため送信せず、KoeBridge 内の一覧から \(removed) 語を削除しました。"
    }
    public static func learningSourceFallback(fragment: String, term: String) -> String {
        "直近の修正：「\(fragment)」→「\(term)」（認識元：AmiVoice）"
    }
    public static let rollbackListEmpty = "戻せる同期履歴がまだありません。同期が反映されるとここに表示されます。"
    public static let reviewNoSuggestion = "推奨読みはありません。読みを入力してください。"
    public static let rollbackDisabledNotice = "自動同期が OFF のため、この操作は実行されませんでした。先に自動同期を ON にしてください。"
    public static func snapshotWordCount(_ count: Int) -> String {
        "同期時点の登録数：\(count) 語"
    }
    public static func undoExcludedToast(surface: String) -> String {
        "「\(surface)」の除外を解除しました。バックグラウンドで AmiVoice へ反映します。"
    }
    /// Restore toast for a quarantined (.autoDisabled) row. Distinct from the
    /// un-exclude toast so the user can tell quarantine recovery from除外解除。
    /// 文案未定義のプレースホルダー（コピーレビュー待ち）。
    public static func quarantineRestoredToast(surface: String) -> String {
        "「\(surface)」を同期対象へ復帰しました。バックグラウンドで AmiVoice へ反映します。"
    }
    public static func approveToast(surface: String) -> String {
        "「\(surface)」を承認しました。バックグラウンドで AmiVoice へ反映します。"
    }
    public static func deleteToast(surface: String) -> String {
        "「\(surface)」を削除しました。バックグラウンドで AmiVoice へ反映します。"
    }
    public static func deleteToastSyncOff(surface: String) -> String {
        "「\(surface)」を削除しました（自動同期が OFF のため、ローカルのみから削除されています）。"
    }
    public static let syncEnabledNotice = "自動同期を ON にしました。"
    public static let syncDisabledNotice = "自動同期を OFF にしました。AmiVoice への送信は行われません。"
}
