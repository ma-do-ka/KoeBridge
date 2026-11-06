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
}
