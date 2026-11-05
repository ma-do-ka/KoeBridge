import Foundation
import Testing
@testable import KoeBridgeCore

struct SettingsNavigationTests {
    @Test func sidebarCoversEveryPageInClearGroups() {
        #expect(SettingsSection.allCases.count == 8)
        #expect(SettingsSection.voice.group == "基本")
        #expect(SettingsSection.permissions.group == "データと安全")
        #expect(SettingsSection.help.group == "サポート")
        #expect(SettingsSection.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
    }

    @Test func searchRoutesToActualSettings() {
        #expect(SettingsSearchCatalog.find("日本語ヒント").first?.section == .gemini)
        #expect(SettingsSearchCatalog.find("F8").first?.section == .voice)
        #expect(SettingsSearchCatalog.find("トークン").first?.section == .usage)
        #expect(SettingsSearchCatalog.find("マイク").contains { $0.section == .permissions })
        #expect(SettingsSearchCatalog.find("アップデート").contains { $0.section == .about && $0.id == "updates" })
        #expect(SettingsSearchCatalog.find("自動入力").contains { $0.section == .voice })
        #expect(SettingsSearchCatalog.find("  ").isEmpty)
        #expect(SettingsSearchCatalog.find("never_present_keyword_123").isEmpty)
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
        nav.select(.usage)
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
}
