import Foundation

/// Presentation-only sections. This catalog never owns recording or permission state.
public enum SettingsSection: String, CaseIterable, Sendable, Hashable {
    case general, voice, gemini, usage, history, permissions, help, about

    public var title: String {
        switch self {
        case .general: return "一般"
        case .voice: return "音声入力"
        case .gemini: return "Gemini"
        case .usage: return "利用統計"
        case .history: return "履歴と記録"
        case .permissions: return "利用許可"
        case .help: return "ヘルプ"
        case .about: return "情報"
        }
    }

    public var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .voice: return "mic.fill"
        case .gemini: return "sparkles"
        case .usage: return "chart.bar.fill"
        case .history: return "clock.arrow.circlepath"
        case .permissions: return "checkmark.shield"
        case .help: return "questionmark.circle"
        case .about: return "info.circle"
        }
    }

    public var group: String {
        switch self {
        case .general, .voice, .gemini, .usage: return "基本"
        case .history, .permissions: return "データと安全"
        case .help, .about: return "サポート"
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
        .init(id: "general", section: .general, title: "基本設定・準備状況", keywords: "全般 エンジン 録音キー 自動入力 文字起こしスタイル API キー 許可 トラブル"),
        .init(id: "engine", section: .voice, title: "文字起こしの方法", keywords: "音声入力 認識エンジン Gemini Apple ローカル オンライン"),
        .init(id: "shortcut", section: .voice, title: "録音の開始・終了キー", keywords: "ホットキー ショートカット Command Fn F8"),
        .init(id: "autopaste", section: .voice, title: "認識した文章を自動入力する", keywords: "貼り付け 文字入力 クリップボード"),
        .init(id: "apikey", section: .gemini, title: "Gemini APIキー", keywords: "接続 登録 更新 削除 キーチェーン"),
        .init(id: "japanese", section: .gemini, title: "日本語での認識を優先する", keywords: "日本語ヒント ja-JP 言語"),
        .init(id: "smart", section: .gemini, title: "文字起こしスタイル", keywords: "SMART VERBATIM 逐語 読みやすく AIエージェント指示 プロンプト 技術用語 命令 文章整形"),
        .init(id: "vocabulary-assistance", section: .gemini, title: "専門用語の補助", keywords: "登録した用語を使う 開発 IT 話題 辞書 チェックボックス"),
        .init(id: "words", section: .gemini, title: "固有名詞・専門用語を登録", keywords: "辞書 GitHub Python 用語"),
        .init(id: "context-check", section: .gemini, title: "文脈チェック", keywords: "文章のつながり 句読点 音声 再認識 照合 疑わしい 毎回 チェックボックス"),
        .init(id: "usage", section: .usage, title: "認識エンジンの利用回数", keywords: "使用統計 グラフ Gemini Apple 失敗 切替"),
        .init(id: "token", section: .usage, title: "Gemini APIのトークン使用量", keywords: "API usageMetadata 料金 回数 秒数"),
        .init(id: "history", section: .history, title: "文字起こし履歴", keywords: "過去の文章 コピー 削除"),
        .init(id: "logging", section: .history, title: "問題調査用の記録を残す", keywords: "診断ログ デバッグ 履歴 開発"),
        .init(id: "accessibility", section: .permissions, title: "入力先へのアクセスを許可", keywords: "権限 アクセシビリティ セキュリティ"),
        .init(id: "post", section: .permissions, title: "文字の入力操作を許可", keywords: "権限 PostEvent キーボード"),
        .init(id: "microphone", section: .permissions, title: "マイクの使用を許可", keywords: "録音 権限 プライバシー"),
        .init(id: "help", section: .help, title: "使い方とトラブル対処", keywords: "操作 よくある質問"),
        .init(id: "about", section: .about, title: "KoeBridgeについて", keywords: "情報 ライセンス GitHub バージョン"),
        .init(id: "updates", section: .about, title: "アップデート", keywords: "更新 確認 自動確認 Stable GitHub 最新版 リリース ダウンロード インストール")
    ]

    public static func find(_ query: String) -> [SettingsSearchEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
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
