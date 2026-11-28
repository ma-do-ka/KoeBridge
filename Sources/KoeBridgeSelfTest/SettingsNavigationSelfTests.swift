import Foundation
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
            "general", "voice", "gemini", "amivoice", "shortcuts", "profiles", "history", "permissions", "about", "bench"
        ])
        check(SettingsSection.amivoice.group == "基本")
        check(SettingsSection.bench.group == "開発ツール")
        check(SettingsSection.bench.title == "ベンチ録音")
        for id in ["amivoice-apikey", "amivoice-engine", "amivoice-privacy", "amivoice-vocabulary-sync", "amivoice-vocabulary-management"] {
            let entry = try require(SettingsSearchCatalog.entries.first { $0.id == id })
            check(entry.section == .amivoice)
        }
        check(SettingsSearchCatalog.find("AmiVoice APIキー").contains { $0.section == .amivoice && $0.id == "amivoice-apikey" })
        check(SettingsSearchCatalog.find("AmiVoice エンジン").contains { $0.section == .amivoice && $0.id == "amivoice-engine" })
        check(SettingsSearchCatalog.find("AmiVoice nolog").contains { $0.section == .amivoice && $0.id == "amivoice-privacy" })
        check(SettingsSearchCatalog.find("AmiVoice 自動同期").contains { $0.section == .amivoice && $0.id == "amivoice-vocabulary-sync" })
        check(SettingsSearchCatalog.find("用語管理").contains { $0.section == .amivoice && $0.id == "amivoice-vocabulary-management" })
        check(SettingsSearchCatalog.find("AmiVoice").contains { $0.section == .voice && $0.id == "engine" })
        check(SettingsSearchCatalog.find("AmiVoice").contains { $0.section == .history && $0.id == "usage" })
        check(SettingsSearchCatalog.find("入力証拠 最小化").contains { $0.section == .history && $0.id == "protected-apps" })
        check(SettingsSearchCatalog.find("診断カウンタ").contains { $0.section == .history && $0.id == "local-diagnostics" })
        check(SettingsSearchCatalog.find("ベンチ録音", developerToolsUnlocked: true).contains { $0.section == .bench && $0.id == "bench-recording" })
        check(SettingsSearchCatalog.find("録音", developerToolsUnlocked: true).contains { $0.section == .bench && $0.id == "bench-recording" })
        check(SettingsSearchCatalog.find("ベンチマーク", developerToolsUnlocked: true).contains { $0.section == .bench && $0.id == "bench-recording" })
        check(SettingsSearchCatalog.find("ベンチ録音").isEmpty)
    }

    func developerToolsStayHiddenUntilKonamiUnlock() throws {
        check(!SettingsSection.bench.isAvailable(developerToolsUnlocked: false))
        check(SettingsSection.bench.isAvailable(developerToolsUnlocked: true))
        check(SettingsSection.general.isAvailable(developerToolsUnlocked: false))
        check(SettingsSearchCatalog.find("録音").allSatisfy { $0.section != .bench })

        var sequence = DeveloperToolsUnlockSequence()
        for keyCode in DeveloperToolsUnlockSequence.keyCodes.dropLast() {
            let completed = sequence.advance(keyCode: keyCode)
            check(!completed)
        }
        check(sequence.progress == DeveloperToolsUnlockSequence.keyCodes.count - 1)
        let finalKey = DeveloperToolsUnlockSequence.keyCodes[DeveloperToolsUnlockSequence.keyCodes.count - 1]
        let completed = sequence.advance(keyCode: finalKey)
        check(completed)
        check(sequence.progress == 0)

        let suite = "KoeBridge.Konami." + UUID().uuidString
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        check(!DeveloperToolsUnlockStore.isUnlocked(defaults: defaults))
        let unlocked = DeveloperToolsUnlockStore.toggle(defaults: defaults)
        check(unlocked)
        check(DeveloperToolsUnlockStore.isUnlocked(defaults: defaults))
        let relocked = DeveloperToolsUnlockStore.toggle(defaults: defaults)
        check(!relocked)
        check(!DeveloperToolsUnlockStore.isUnlocked(defaults: defaults))
    }

    func relockingDropsBenchFromNavigationHistory() throws {
        let locked = { (section: SettingsSection) in section.isAvailable(developerToolsUnlocked: false) }

        // (a) Re-lock while the bench page is open: Forward cannot return.
        var viewingBench = SettingsNavigation()
        viewingBench.select(.bench)
        check(viewingBench.selected == .bench)
        viewingBench.pruneUnavailable(locked, fallback: .voice)
        check(viewingBench.selected == .voice)
        check(!viewingBench.canGoForward)
        viewingBench.forward()
        check(viewingBench.selected == .voice)
        check(!viewingBench.pages.contains(.bench))

        // (b) Re-lock on a later page after visiting bench: Back cannot return.
        var behindBench = SettingsNavigation()
        behindBench.select(.bench)
        behindBench.select(.about)
        behindBench.pruneUnavailable(locked, fallback: .voice)
        check(behindBench.selected == .about)
        check(behindBench.pages == [.voice, .about])
        behindBench.back()
        check(behindBench.selected == .voice)
        check(!behindBench.pages.contains(.bench))
    }
}
