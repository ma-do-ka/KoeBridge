import Foundation
import Testing
@testable import KoeBridgeCore

struct SettingsNavigationTests {
    @Test func sidebarCoversEveryPageInClearGroups() {
        #expect(SettingsSection.allCases.map(\.title) == ["一般", "音声入力", "AI・Gemini", "ショートカット", "アプリ別", "履歴とデータ", "権限", "KoeBridgeについて"])
        #expect(SettingsSection.voice.group == "基本")
        #expect(SettingsSection.permissions.group == "データと安全")
        #expect(SettingsSection.about.group == "サポート")
        #expect(SettingsSection.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    }

    @Test func searchRoutesToActualSettings() {
        #expect(SettingsSearchCatalog.find("日本語ヒント").first?.section == .gemini)
        #expect(SettingsSearchCatalog.find("F8").first?.section == .shortcuts)
        #expect(SettingsSearchCatalog.find("トークン").first?.section == .history)
        #expect(SettingsSearchCatalog.find("マイク").contains { $0.section == .permissions })
        #expect(SettingsSearchCatalog.find("アップデート").contains { $0.section == .about && $0.id == "updates" })
        #expect(SettingsSearchCatalog.find("自動入力").contains { $0.section == .voice })
        #expect(SettingsSearchCatalog.find("専門用語の補助").contains { $0.section == .gemini && $0.id == "vocabulary-assistance" })
        #expect(SettingsSearchCatalog.find("開発 IT").contains { $0.section == .gemini && $0.id == "vocabulary-assistance" })
        #expect(SettingsSearchCatalog.find("Mac内の句読点整理").contains { $0.section == .gemini && $0.id == "context-check" })
        #expect(SettingsSearchCatalog.find("音声 照合").contains { $0.section == .gemini && $0.id == "context-check" })
        #expect(SettingsSearchCatalog.find("  ").isEmpty)
        #expect(SettingsSearchCatalog.find("never_present_keyword_123").isEmpty)
    }

    @Test func everyCatalogEntryResolvesToAnAnchorOnItsOwningPage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        // Explicit composition graph, independently audited against SettingsView.
        let files: [SettingsSection: [String]] = [
            .general: ["SettingsGeneralPage.swift"],
            .voice: ["SettingsVoicePage.swift", "MicrophoneSettingsRow.swift"],
            .gemini: ["SettingsGeminiPage.swift", "SettingsTransformPresets.swift"],
            .shortcuts: ["SettingsShortcutsPage.swift", "SettingsInputControls.swift"],
            .profiles: ["SettingsView.swift"],
            .history: ["SettingsPrivacyPage.swift", "UsageMonitorView.swift"],
            .permissions: ["SettingsPermissionsPage.swift"],
            .about: ["SettingsSupportPages.swift"]
        ]
        let pattern = try NSRegularExpression(pattern: #"\.settingsTarget\("([^"]+)"\)"#)
        var anchors: [SettingsSection: Set<String>] = [:]
        for (page, names) in files {
            for name in names {
                let source = try String(contentsOf: root.appendingPathComponent("Sources/KoeBridge/" + name), encoding: .utf8)
                for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    let range = try #require(Range(match.range(at: 1), in: source))
                    anchors[page, default: []].insert(String(source[range]))
                }
            }
        }
        #expect(Set(SettingsSearchCatalog.entries.map(\.id)).count == SettingsSearchCatalog.entries.count)
        for entry in SettingsSearchCatalog.entries {
            #expect(anchors[entry.section, default: []].contains(entry.id), "Missing anchor: \(entry.id) on \(entry.section)")
        }
        #expect(!SettingsSearchCatalog.find("モード").contains { $0.section == .profiles })
        #expect(SettingsSearchCatalog.find("context selection").map(\.id) == ["context-selection"])
    }

    @Test func updateCenterHasExactlyOneRealDestination() {
        let destinations = SettingsSearchCatalog.entries.filter { $0.id == "updates" }
        #expect(destinations.count == 1)
        #expect(destinations.first?.section == .about)
        #expect(destinations.first?.title == "アップデート")
    }

    @Test func backForwardTruncatesFutureAfterNewChoice() {
        var nav = SettingsNavigation()
        #expect(nav.selected == .voice)
        nav.select(.gemini)
        nav.select(.history)
        nav.back()
        #expect(nav.selected == .gemini)
        #expect(nav.canGoForward)
        nav.select(.permissions)
        #expect(nav.selected == .permissions)
        #expect(!nav.canGoForward)
        nav.back()
        #expect(nav.selected == .gemini)
        nav.forward()
        #expect(nav.selected == .permissions)
    }

    @Test func repeatedPageDoesNotAddDuplicateNavigation() {
        var nav = SettingsNavigation()
        nav.select(.voice)
        #expect(nav.pages.count == 1)
        for _ in 0..<200 {
            nav.select(.gemini)
            nav.select(.voice)
        }
        #expect(nav.pages.count <= 40)
        #expect(nav.index < nav.pages.count)
    }

    @Test func repeatedSearchAndUpdateRequestsStillProduceScrollEvents() throws {
        for id in ["words", "updates"] {
            let entry = try #require(SettingsSearchCatalog.entries.first { $0.id == id })
            var nav = SettingsNavigation()
            nav.focus(entry)
            let first = try #require(nav.focusRequest)
            let originalPages = nav.pages

            // The anchor is unchanged, but a new user action must still scroll.
            nav.focus(entry)
            let second = try #require(nav.focusRequest)
            #expect(first != second)
            #expect(first.id == second.id)
            #expect(second.section == nav.selected)
            #expect(nav.pages == originalPages)
        }
    }

    @Test func pageNavigationClearsOldSearchRequests() throws {
        let entry = try #require(SettingsSearchCatalog.entries.first { $0.id == "updates" })
        var nav = SettingsNavigation()
        nav.focus(entry)
        nav.select(.about)
        #expect(nav.focusRequest == nil)
        #expect(nav.pages == [.voice, .about])

        nav.focus(entry)
        nav.back()
        #expect(nav.selected == .voice)
        #expect(nav.focusRequest == nil)
        nav.forward()
        #expect(nav.selected == .about)
        #expect(nav.focusRequest == nil)

        nav.focus(entry)
        nav.select(.permissions)
        #expect(nav.selected == .permissions)
        #expect(nav.focusRequest == nil)
    }
}
