#if os(macOS)
import Foundation
import KoeBridgeCore

struct DeveloperDiagnosticsToken: Equatable, Sendable {
    fileprivate let epoch: String
}

/// Explicitly opt-in diagnostics that may contain short audio and transcript text.
/// Ordinary KoeBridge.log remains content-free and uses a separate consent path.
enum DeveloperDiagnostics {
    static let preferenceKey = "developerDiagnosticsEnabled"
    private static let epochKey = "developerDiagnosticsEpoch"
    private static let tokenLock = NSLock()

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: preferenceKey)
    }

    static var token: DeveloperDiagnosticsToken? {
        tokenLock.lock(); defer { tokenLock.unlock() }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: preferenceKey) else { return nil }
        var epoch = defaults.string(forKey: epochKey)
        if epoch == nil {
            epoch = UUID().uuidString
            defaults.set(epoch, forKey: epochKey)
        }
        return epoch.map(DeveloperDiagnosticsToken.init(epoch:))
    }

    @discardableResult
    static func enablePreference() -> DeveloperDiagnosticsToken {
        tokenLock.lock(); defer { tokenLock.unlock() }
        let epoch = UUID().uuidString
        let defaults = UserDefaults.standard
        defaults.set(epoch, forKey: epochKey)
        defaults.set(true, forKey: preferenceKey)
        return DeveloperDiagnosticsToken(epoch: epoch)
    }

    static func disablePreference() {
        tokenLock.lock(); defer { tokenLock.unlock() }
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: preferenceKey)
        defaults.set(UUID().uuidString, forKey: epochKey)
    }

    @discardableResult
    static func rotateEpochKeepingPreference() -> DeveloperDiagnosticsToken? {
        tokenLock.lock(); defer { tokenLock.unlock() }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: preferenceKey) else { return nil }
        let epoch = UUID().uuidString
        defaults.set(epoch, forKey: epochKey)
        return DeveloperDiagnosticsToken(epoch: epoch)
    }

    static func allows(_ candidate: DeveloperDiagnosticsToken?) -> Bool {
        guard let candidate, let current = token else { return false }
        return current == candidate
    }

    static func purgeStaleDataIfDisabled() {
        guard !isEnabled else { return }
        Task { try? await DeveloperDiagnosticsStore.shared.deleteAll() }
    }

    static func appendGlobal(_ event: String) {
        guard let token else { return }
        Task { await DeveloperDiagnosticsStore.shared.appendGlobal(event, token: token) }
    }

    static func recordEvent(takeID: UUID, stage: String, fields: [String: String] = [:]) {
        guard let token else { return }
        Task {
            await DeveloperDiagnosticsStore.shared.recordEvent(
                takeID: takeID, stage: stage, fields: fields, token: token
            )
        }
    }

    static func writeInputTrace(takeID: UUID, lines: [String],
                                token: DeveloperDiagnosticsToken?) {
        guard allows(token) else { return }
        Task {
            await DeveloperDiagnosticsStore.shared.writeInputTrace(
                takeID: takeID, lines: lines, token: token!
            )
        }
    }

    static func recordRecognition(takeID: UUID, recordedAt: Date, engine: String,
                                  primaryText: String?, finalText: String?, partialText: String?,
                                  alternativeText: String?, pcm16LE: Data) {
        guard let token else { return }
        let cappedPCM = DeveloperDiagnosticsPolicy.cappedPCM(pcm16LE)
        Task {
            await DeveloperDiagnosticsStore.shared.recordRecognition(
                takeID: takeID, recordedAt: recordedAt, engine: engine,
                primaryText: primaryText, finalText: finalText,
                partialText: partialText, alternativeText: alternativeText,
                pcm16LE: cappedPCM.data, audioTruncated: cappedPCM.truncated,
                token: token
            )
        }
    }

    static func recordDelivery(takeID: UUID, delivery: String, detail: String,
                               transportText: String?, observedDelta: String? = nil) {
        guard let token else { return }
        Task {
            await DeveloperDiagnosticsStore.shared.recordDelivery(
                takeID: takeID, delivery: delivery, detail: detail,
                transportText: transportText, observedDelta: observedDelta, token: token
            )
        }
    }
}
#endif
