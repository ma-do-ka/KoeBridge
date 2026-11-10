import Foundation
import Testing
@testable import KoeBridgeCore

struct AppProfileTests {
    @Test func matching() {
        let first = AppProfile(bundleIdentifier: "com.example.Editor", displayName: "First")
        let disabled = AppProfile(bundleIdentifier: first.bundleIdentifier, displayName: "Disabled", isEnabled: false)
        let duplicate = AppProfile(bundleIdentifier: first.bundleIdentifier, displayName: "Second")
        #expect(AppProfileResolver.match(profiles: [disabled, first, duplicate], bundleIdentifier: first.bundleIdentifier) == first)
        #expect(AppProfileResolver.match(profiles: [disabled], bundleIdentifier: first.bundleIdentifier) == nil)
        #expect(AppProfileResolver.match(profiles: [first], bundleIdentifier: "com.example.editor") == nil)
        #expect(AppProfileResolver.match(profiles: [first], bundleIdentifier: nil) == nil)
        #expect(AppProfileResolver.match(profiles: [first], bundleIdentifier: "") == nil)
        #expect(AppProfileResolver.match(profiles: [], bundleIdentifier: first.bundleIdentifier) == nil)
    }

    @Test func vocabularyMerge() {
        let result = AppProfileResolver.mergedVocabulary(
            profileTerms: ["  Café  ", "", "Profile", "café"], globalTerms: ["CAFE", " Global ", "profile"])
        #expect(result == ["Café", "Profile", "Global"])
        let capped = AppProfileResolver.mergedVocabulary(
            profileTerms: ["priority"], globalTerms: (0..<120).map { "term\($0)" })
        #expect(capped.count == 100)
        #expect(capped.first == "priority")
        #expect(capped.last == "term98")
        #expect(AppProfileResolver.mergedVocabulary(profileTerms: [], globalTerms: []) == [])
        #expect(AppProfileResolver.mergedVocabulary(profileTerms: (0..<120).map { "p\($0)" }, globalTerms: ["global"]).count == 100)
    }

    @Test func persistenceRoundTrip() throws {
        let profile = AppProfile(bundleIdentifier: "com.example.Editor", displayName: "Editor",
            engine: "local", style: "readable", additionalVocabulary: "KoeBridge",
            registeredVocabularyEnabled: false, topicVocabularyEnabled: true,
            textContextCheckEnabled: false, audioRecheckEnabled: true, audioRecheckAlways: false,
            postProcessEnabled: true, postProcessMode: "formal")
        let decoded = try JSONDecoder().decode(AppProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        let inherited = AppProfile(bundleIdentifier: "com.example.App", displayName: "App")
        #expect(try JSONDecoder().decode(AppProfile.self, from: JSONEncoder().encode(inherited)) == inherited)
    }
}
