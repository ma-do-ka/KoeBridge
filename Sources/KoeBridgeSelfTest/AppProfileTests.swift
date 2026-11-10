import Foundation
import KoeBridgeCore

struct AppProfileTests {
    func matching() {
        let first = AppProfile(bundleIdentifier: "com.example.Editor", displayName: "First")
        let disabled = AppProfile(bundleIdentifier: first.bundleIdentifier, displayName: "Disabled", isEnabled: false)
        let duplicate = AppProfile(bundleIdentifier: first.bundleIdentifier, displayName: "Second")
        check(AppProfileResolver.match(profiles: [disabled, first, duplicate], bundleIdentifier: first.bundleIdentifier) == first)
        check(AppProfileResolver.match(profiles: [disabled], bundleIdentifier: first.bundleIdentifier) == nil)
        check(AppProfileResolver.match(profiles: [first], bundleIdentifier: "com.example.editor") == nil)
        check(AppProfileResolver.match(profiles: [first], bundleIdentifier: nil) == nil)
        check(AppProfileResolver.match(profiles: [first], bundleIdentifier: "") == nil)
        check(AppProfileResolver.match(profiles: [], bundleIdentifier: first.bundleIdentifier) == nil)
    }

    func vocabularyMerge() {
        let result = AppProfileResolver.mergedVocabulary(
            profileTerms: ["  Café  ", "", "Profile", "café"], globalTerms: ["CAFE", " Global ", "profile"])
        check(result == ["Café", "Profile", "Global"])
        let capped = AppProfileResolver.mergedVocabulary(
            profileTerms: ["priority"], globalTerms: (0..<120).map { "term\($0)" })
        check(capped.count == 100)
        check(capped.first == "priority")
        check(capped.last == "term98")
        check(AppProfileResolver.mergedVocabulary(profileTerms: [], globalTerms: []) == [])
        check(AppProfileResolver.mergedVocabulary(profileTerms: (0..<120).map { "p\($0)" }, globalTerms: ["global"]).count == 100)
    }

    func persistenceRoundTrip() throws {
        let profile = AppProfile(bundleIdentifier: "com.example.Editor", displayName: "Editor",
            engine: "local", style: "readable", additionalVocabulary: "KoeBridge",
            registeredVocabularyEnabled: false, topicVocabularyEnabled: true,
            textContextCheckEnabled: false, audioRecheckEnabled: true, audioRecheckAlways: false,
            postProcessEnabled: true, postProcessMode: "formal")
        let decoded = try JSONDecoder().decode(AppProfile.self, from: JSONEncoder().encode(profile))
        check(decoded == profile)
        let inherited = AppProfile(bundleIdentifier: "com.example.App", displayName: "App")
        let inheritedDecoded = try JSONDecoder().decode(AppProfile.self, from: JSONEncoder().encode(inherited))
        check(inheritedDecoded == inherited)
    }
}
