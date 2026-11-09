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

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var enabled: Bool
        var epoch: String

        init() {
            let defaults = UserDefaults.standard
            enabled = defaults.bool(forKey: DeveloperDiagnostics.preferenceKey)
            epoch = defaults.string(forKey: DeveloperDiagnostics.epochKey) ?? UUID().uuidString
        }
    }
    private static let state = State()

    static var isEnabled: Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.enabled
    }

    static var token: DeveloperDiagnosticsToken? {
        state.lock.lock(); defer { state.lock.unlock() }
        guard state.enabled else { return nil }
        return DeveloperDiagnosticsToken(epoch: state.epoch)
    }

    @discardableResult
    static func enablePreference() -> DeveloperDiagnosticsToken {
        let epoch = UUID().uuidString
        state.lock.lock()
        state.enabled = true
        state.epoch = epoch
        state.lock.unlock()
        let defaults = UserDefaults.standard
        defaults.set(epoch, forKey: epochKey)
        defaults.set(true, forKey: preferenceKey)
        return DeveloperDiagnosticsToken(epoch: epoch)
    }

    static func disablePreference() {
        let epoch = UUID().uuidString
        state.lock.lock()
        state.enabled = false
        state.epoch = epoch
        state.lock.unlock()
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: preferenceKey)
        defaults.set(epoch, forKey: epochKey)
    }

    @discardableResult
    static func rotateEpochKeepingPreference() -> DeveloperDiagnosticsToken? {
        let epoch = UUID().uuidString
        state.lock.lock()
        guard state.enabled else { state.lock.unlock(); return nil }
        state.epoch = epoch
        state.lock.unlock()
        UserDefaults.standard.set(epoch, forKey: epochKey)
        return DeveloperDiagnosticsToken(epoch: epoch)
    }

    static func allows(_ candidate: DeveloperDiagnosticsToken?) -> Bool {
        guard let candidate, let current = token else { return false }
        return current == candidate
    }

    static func reconcileStorageOnLaunch() {
        if let token {
            Task {
                do {
                    try await DeveloperDiagnosticsStore.shared.prepare(token: token)
                } catch {
                    disablePreference()
                    try? await DeveloperDiagnosticsStore.shared.deleteAllIfStillDisabled()
                    await MainActor.run {
                        DeveloperDiagnosticsController.shared.failClosedFromStorage(error)
                    }
                }
            }
        } else {
            Task { try? await DeveloperDiagnosticsStore.shared.deleteAllIfStillDisabled() }
        }
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
        guard let token, allows(token) else { return }
        Task {
            await DeveloperDiagnosticsStore.shared.writeInputTrace(
                takeID: takeID, lines: lines, token: token
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
