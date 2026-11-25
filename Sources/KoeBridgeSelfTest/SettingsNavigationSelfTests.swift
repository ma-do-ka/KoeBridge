import KoeBridgeCore

struct SettingsNavigationSelfTests {
    func repeatedSearchAndUpdateRequestsStillScroll() throws {
        for id in ["words", "updates"] {
            let entry = try require(SettingsSearchCatalog.entries.first { $0.id == id })
            var navigation = SettingsNavigation()
            navigation.focus(entry)
            let first = try require(navigation.focusRequest)
            let pages = navigation.pages

            navigation.focus(entry)
            let second = try require(navigation.focusRequest)
            check(first != second)
            check(first.id == second.id)
            check(second.section == navigation.selected)
            check(navigation.pages == pages)
        }
    }

    func pageChangesDoNotReplayAStaleSearch() throws {
        let entry = try require(SettingsSearchCatalog.entries.first { $0.id == "updates" })
        var navigation = SettingsNavigation()
        navigation.focus(entry)
        navigation.select(.about)
        check(navigation.focusRequest == nil)
        check(navigation.pages == [.voice, .about])

        navigation.focus(entry)
        navigation.back()
        check(navigation.selected == .voice && navigation.focusRequest == nil)
        navigation.forward()
        check(navigation.selected == .about && navigation.focusRequest == nil)

        navigation.focus(entry)
        navigation.select(.permissions)
        check(navigation.selected == .permissions && navigation.focusRequest == nil)
    }

    func amiVoiceSectionAndSearchCatalogEntriesRouteCorrectly() throws {
        check(SettingsSection.allCases.map(\.rawValue) == [
            "general", "voice", "gemini", "amivoice", "shortcuts", "profiles", "history", "permissions", "about"
        ])
        check(SettingsSection.amivoice.group == "基本")
        for id in ["amivoice-apikey", "amivoice-engine", "amivoice-privacy"] {
            let entry = try require(SettingsSearchCatalog.entries.first { $0.id == id })
            check(entry.section == .amivoice)
        }
        check(SettingsSearchCatalog.find("AmiVoice APIキー").contains { $0.section == .amivoice && $0.id == "amivoice-apikey" })
        check(SettingsSearchCatalog.find("AmiVoice エンジン").contains { $0.section == .amivoice && $0.id == "amivoice-engine" })
        check(SettingsSearchCatalog.find("AmiVoice nolog").contains { $0.section == .amivoice && $0.id == "amivoice-privacy" })
    }
}
