import Foundation

/// Presentation-only sections. This catalog never owns recording or permission state.
public enum SettingsSection: String, CaseIterable, Sendable, Hashable {
    case general, voice, gemini, amivoice, shortcuts, profiles, history, permissions, about, bench

    public var title: String {
        switch self {
        case .general: return "一般"
        case .voice: return "音声入力"
        case .gemini: return "AI・Gemini"
        case .amivoice: return "AmiVoice"
        case .shortcuts: return "ショートカット"
        case .history: return "履歴とデータ"
        case .permissions: return "権限"
        case .profiles: return "アプリ別"
        case .about: return "KoeBridgeについて"
        case .bench: return "ベンチ録音"
        }
    }

    public var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .voice: return "mic.fill"
        case .gemini: return "sparkles"
        case .amivoice: return "waveform"
        case .shortcuts: return "keyboard"
        case .history: return "clock.arrow.circlepath"
        case .permissions: return "checkmark.shield"
        case .profiles: return "app.badge"
        case .about: return "info.circle"
        case .bench: return "record.circle"
        }
    }

    public var group: String {
        switch self {
        case .general, .voice, .gemini, .amivoice, .shortcuts, .profiles: return "基本"
        case .history, .permissions: return "データと安全"
        case .about: return "サポート"
        case .bench: return "開発ツール"
        }
    }
}

public struct SettingsSearchEntry: Identifiable, Sendable {
    public let id: String
    public let section: SettingsSection
    public let title: String
    public let keywords: String

    public init(id: String, section: SettingsSection, title: String, keywords: String) {
        self.id = id
        self.section = section
        self.title = title
        self.keywords = keywords
    }
}

/// Users can search exact setting labels and common synonyms without guesswork.
public enum SettingsSearchCatalog {
    public static let entries: [SettingsSearchEntry] = [
        .init(id: "general", section: .general, title: "基本設定・準備状況", keywords: "readiness 準備 問題 API キー 許可 トラブル"),
        .init(id: "app-profiles", section: .profiles, title: "アプリ別プロファイル", keywords: "アプリ 設定 エンジン 文体 用語 後処理 bundle profile"),
        .init(id: "engine", section: .voice, title: "文字起こしの方法", keywords: "音声入力 認識エンジン engine SpeechAnalyzer SFSpeechRecognizer Gemini AmiVoice Apple ローカル オンライン"),
        .init(id: "shortcut", section: .shortcuts, title: "録音の開始・終了キー", keywords: "recording shortcut ホットキー ショートカット Command Fn F8"),
        .init(id: "autopaste", section: .voice, title: "認識した文章を自動入力する", keywords: "autoPaste safety 貼り付け 文字入力 クリップボード"),
        .init(id: "apikey", section: .gemini, title: "Gemini APIキー", keywords: "API key Keychain 接続 登録 更新 削除 キーチェーン"),
        .init(id: "amivoice-apikey", section: .amivoice, title: "AmiVoice APIキー", keywords: "AmiVoice APPKEY API key Keychain 接続 登録 更新 削除 キーチェーン"),
        .init(id: "amivoice-engine", section: .amivoice, title: "AmiVoice 認識エンジン", keywords: "AmiVoice エンジン E2E Hybrid 汎用 会話 バッチ -a2-ja-general"),
        .init(id: "amivoice-privacy", section: .amivoice, title: "AmiVoice プライバシーと料金", keywords: "AmiVoice プライバシー 料金 nolog ログ保存なし 無料枠 60分 0.04125 2.475"),
        .init(id: "amivoice-vocabulary-sync", section: .amivoice, title: "学習修正を AmiVoice 単語登録へ自動同期する", keywords: "AmiVoice 自動同期 語彙 用語 sync 同意 オプトイン 学習修正 単語登録"),
        .init(id: "amivoice-vocabulary-management", section: .amivoice, title: "用語管理（AmiVoice 自動同期）", keywords: "AmiVoice 用語管理 確認待ち 除外 削除 一時停止 同期履歴 ロールバック 一括削除 vocabulary"),
        .init(id: "japanese", section: .gemini, title: "日本語での認識を優先する", keywords: "Japanese hint ja-JP 日本語ヒント 言語"),
        .init(id: "smart", section: .gemini, title: "文字起こしスタイル", keywords: "style SMART VERBATIM 逐語 読みやすく AIエージェント指示 プロンプト 技術用語 命令 文章整形"),
        .init(id: "vocabulary-assistance", section: .gemini, title: "専門用語の補助", keywords: "登録した用語を使う 開発 IT 話題 辞書 チェックボックス"),
        .init(id: "words", section: .gemini, title: "固有名詞・専門用語を登録", keywords: "vocabulary dictionary 辞書 GitHub Python 用語"),
        .init(id: "context-check", section: .gemini, title: "Mac内の句読点整理", keywords: "文章のつながり 句読点 音声 再認識 照合 疑わしい 毎回 チェックボックス"),
        .init(id: "usage", section: .history, title: "認識エンジンの利用回数", keywords: "使用統計 グラフ Gemini AmiVoice Apple 失敗 切替"),
        .init(id: "token", section: .history, title: "Gemini APIのトークン使用量", keywords: "API usageMetadata 料金 回数 秒数"),
        .init(id: "history", section: .history, title: "文字起こし履歴", keywords: "history copy delete learning original alternative 過去の文章 コピー 削除 修正 学習 元の文章 候補"),
        .init(id: "protected-apps", section: .history, title: "入力証拠を最小化するアプリ", keywords: "privacy protected apps receipt evidence プライバシー 保護 アプリ 入力証拠 最小化 バンドル"),
        .init(id: "logging", section: .history, title: "問題調査用の記録を残す", keywords: "diagnostics log consent 診断ログ デバッグ 履歴 開発 削除 保存先"),
        .init(id: "accessibility", section: .permissions, title: "入力先へのアクセスを許可", keywords: "accessibility permission 権限 アクセシビリティ セキュリティ"),
        .init(id: "post", section: .permissions, title: "文字の入力操作を許可", keywords: "PostEvent permission 権限 キーボード"),
        .init(id: "microphone", section: .permissions, title: "マイクの使用を許可", keywords: "microphone permission 録音 権限 プライバシー"),
        .init(id: "help", section: .about, title: "使い方とトラブル対処", keywords: "操作 よくある質問"),
        .init(id: "about", section: .about, title: "KoeBridgeについて", keywords: "情報 ライセンス GitHub バージョン"),
        .init(id: "updates", section: .about, title: "アップデート", keywords: "更新 確認 自動確認 Stable GitHub 最新版 リリース ダウンロード インストール"),
        .init(id: "launchAtLogin", section: .general, title: "ログイン時に自動起動", keywords: "login startup 常駐"),
        .init(id: "timings", section: .general, title: "直近の処理時間", keywords: "latency 秒数"),
        .init(id: "microphone-device", section: .voice, title: "マイクを選択", keywords: "microphone device 入力機器"),
        .init(id: "bluetooth-warm", section: .voice, title: "Bluetoothマイクの接続準備", keywords: "Bluetooth warm 接続維持"),
        .init(id: "output-volume-guard", section: .voice, title: "録音中の音量ガード", keywords: "volume guard 再生音量 上限 Bluetooth"),
        .init(id: "clause-streaming", section: .voice, title: "文節ストリーミング", keywords: "文 確定 先行 後処理 試験的 streaming sentence"),
        .init(id: "preview", section: .voice, title: "録音プレビュー", keywords: "progressive preview 確定 暫定"),
        .init(id: "snippets", section: .voice, title: "定型文・スニペット", keywords: "snippets DATE TIME CLIPBOARD 署名"),
        .init(id: "voice-commands", section: .voice, title: "音声コマンド", keywords: "voice commands 入力をキャンセルして 改行して 段落を変えて 改行 送信 取消"),
        .init(id: "meeting", section: .voice, title: "会議モード", keywords: "meeting システム音声 録音"),
        .init(id: "activation", section: .shortcuts, title: "録音キーの動作", keywords: "activation toggle hold hybrid ホールド ハイブリッド モード"),
        .init(id: "mouse", section: .shortcuts, title: "マウスボタン", keywords: "mouse trigger 中央 サイド"),
        .init(id: "transform-shortcut", section: .shortcuts, title: "選択テキストを変換", keywords: "transform shortcut 指示 キー"),
        .init(id: "translate-shortcut", section: .shortcuts, title: "選択テキストを翻訳", keywords: "translate shortcut キー"),
        .init(id: "fix-shortcut", section: .shortcuts, title: "直前の入力を修正", keywords: "fix last input shortcut キー"),
        .init(id: "prewarm", section: .gemini, title: "録音前に接続を準備する", keywords: "Gemini prewarm 待ち時間"),
        .init(id: "japanese-spacing", section: .gemini, title: "日本語の間の半角スペースを削除する", keywords: "空白 逐語 文字起こし"),
        .init(id: "post-processing", section: .gemini, title: "LLM後処理", keywords: "post processing Apple 文を整える"),
        .init(id: "post-mode", section: .gemini, title: "後処理モード", keywords: "post processing mode"),
        .init(id: "learned-terms", section: .gemini, title: "学習した語彙", keywords: "learned terms 修正 辞書"),
        .init(id: "audio-recheck", section: .gemini, title: "音声の再照合とタイミング", keywords: "audio recheck policy 疑わしい 毎回"),
        .init(id: "context", section: .gemini, title: "再照合に送る文脈", keywords: "context master 再チェック"),
        .init(id: "context-app", section: .gemini, title: "文脈のアプリ名", keywords: "context app"),
        .init(id: "context-selection", section: .gemini, title: "文脈の選択テキスト", keywords: "context selection"),
        .init(id: "context-surrounding", section: .gemini, title: "文脈の周辺テキスト", keywords: "context surrounding"),
        .init(id: "translation", section: .gemini, title: "翻訳の方向", keywords: "translation direction 日本語 英語"),
        .init(id: "presets", section: .gemini, title: "選択テキストの変換・プリセットチェーン", keywords: "transform mode preset chains ステップ 並べ替え"),
        .init(id: "retention", section: .history, title: "音声の保存と削除", keywords: "audio retention WAV 7日 250 MB"),
        .init(id: "permission-guide", section: .permissions, title: "音声認識と入力監視の案内", keywords: "Speech recognition input monitoring guide"),
        .init(id: "registered-vocabulary", section: .gemini, title: "登録した用語を使う", keywords: "registered vocabulary 辞書 有効"),
        .init(id: "topic-vocabulary", section: .gemini, title: "開発・ITの用語を使う", keywords: "topic vocabulary IT 用語 補助"),
        .init(id: "audio-policy", section: .gemini, title: "音声と照合するタイミング", keywords: "audio recheck policy 疑わしい 毎回"),
        .init(id: "transform-mode", section: .gemini, title: "変換キーの動作", keywords: "transform mode 音声 指示 プリセット"),
        .init(id: "selected-preset", section: .gemini, title: "実行するプリセット", keywords: "selected transform preset チェーン 選ぶ"),
        .init(id: "bench-recording", section: .bench, title: "ベンチ録音", keywords: "ベンチ録音 録音 ベンチマーク コーパス WAV")
    ]

    /// Search never surfaces the developer-tools entry until it is unlocked.
    public static func find(_ query: String,
                            developerToolsUnlocked: Bool = false) -> [SettingsSearchEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            guard entry.section.isAvailable(developerToolsUnlocked: developerToolsUnlocked) else { return false }
            let haystack = entry.title + " " + entry.keywords + " " + entry.section.title
            return words.allSatisfy { haystack.localizedStandardContains($0) }
        }
    }
}

/// An explicit scroll request. Repeating the same search result must still
/// produce a different value so SwiftUI does not coalesce it into a no-op.
public struct SettingsFocusRequest: Equatable, Sendable {
    public let id: String
    public let section: SettingsSection
    public let sequence: UInt64

    fileprivate init(entry: SettingsSearchEntry, sequence: UInt64) {
        self.id = entry.id
        self.section = entry.section
        self.sequence = sequence
    }
}

public struct SettingsNavigation: Equatable, Sendable {
    public private(set) var pages: [SettingsSection] = [.voice]
    public private(set) var index: Int = 0
    public private(set) var focusRequest: SettingsFocusRequest?
    private var focusSequence: UInt64 = 0
    public var selected: SettingsSection { pages[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < pages.count }

    public init() {}

    public mutating func select(_ page: SettingsSection) {
        focusRequest = nil
        guard page != selected else { return }
        pages = Array(pages.prefix(index + 1))
        pages.append(page)
        index += 1
        // Bound navigation history, not user data.
        if pages.count > 40 {
            pages.removeFirst(pages.count - 40)
            index = pages.count - 1
        }
    }

    /// Drops pages that are no longer available (for example the hidden
    /// developer-tools page after re-locking). Removing a page can join two
    /// equal neighbours, so adjacent duplicates are collapsed. Back and
    /// Forward then can never return to a page that is no longer reachable.
    /// If the selected page is removed, the fallback becomes the selection
    /// after the retained history.
    public mutating func pruneUnavailable(_ isAvailable: (SettingsSection) -> Bool,
                                          fallback: SettingsSection) {
        guard !pages.allSatisfy(isAvailable) else { return }
        let previous = selected
        var retained: [SettingsSection] = []
        for page in pages where isAvailable(page) {
            if retained.last != page { retained.append(page) }
        }
        focusRequest = nil
        guard isAvailable(previous) else {
            if retained.last != fallback { retained.append(fallback) }
            pages = retained
            index = pages.count - 1
            return
        }
        // The retained prefix has the same shape as the retained history, so
        // its last entry is the still-available selection.
        var retainedThroughSelection: [SettingsSection] = []
        for page in pages[0...index] where isAvailable(page) {
            if retainedThroughSelection.last != page { retainedThroughSelection.append(page) }
        }
        pages = retained
        index = max(0, retainedThroughSelection.count - 1)
    }

    public mutating func focus(_ entry: SettingsSearchEntry) {
        select(entry.section)
        focusSequence &+= 1
        focusRequest = SettingsFocusRequest(entry: entry, sequence: focusSequence)
    }

    public mutating func back() {
        guard canGoBack else { return }
        focusRequest = nil
        index -= 1
    }
    public mutating func forward() {
        guard canGoForward else { return }
        focusRequest = nil
        index += 1
    }
}
