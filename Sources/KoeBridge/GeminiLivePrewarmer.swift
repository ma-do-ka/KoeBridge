#if os(macOS)
import Foundation
import KoeBridgeCore

/// Owns only an unused setup connection. Adoption transfers all ownership to a take.
@MainActor final class GeminiLivePrewarmer {
    private enum State {
        case idle
        case warming(UUID, Task<Void, Never>, GeminiLiveConnection, GeminiPrewarmSnapshot)
        case ready(GeminiLiveConnection, GeminiPrewarmSnapshot, Date)
    }
    private let makeConnection: () -> GeminiLiveConnection
    init(makeConnection: @escaping @MainActor () -> GeminiLiveConnection = { GeminiLiveConnection() }) {
        self.makeConnection = makeConnection
    }
    private var state: State = .idle
    private var expiry: Task<Void, Never>?

    /// The provider returns nil when disabled, a take is active, or no key is available.
    @discardableResult func warmIfNeeded(snapshotProvider: () -> (snapshot: GeminiPrewarmSnapshot, apiKey: String)?) -> Task<Void, Never>? {
        guard let input = snapshotProvider() else { return nil }
        switch state {
        case .warming(_, let task, _, let snapshot):
            if snapshot == input.snapshot { return task }
            shutdown()
        case .ready(let connection, let snapshot, let warmedAt):
            if connection.isUsableForPrewarm && GeminiPrewarmPolicy.isUsable(
                snapshot: snapshot, current: input.snapshot, warmedAt: warmedAt, now: Date()) { return nil }
            shutdown()
        case .idle: break
        }
        let connection = makeConnection()
        let id = UUID()
        let task = Task { [weak self] in
            do {
                try await connection.connect(apiKey: input.apiKey, vocabulary: input.snapshot.vocabulary,
                                             style: input.snapshot.style, japaneseHint: input.snapshot.japaneseHint)
                try Task.checkCancellation()
                guard let self, case .warming(let currentID, _, _, _) = self.state, currentID == id else {
                    connection.cancel()
                    return
                }
                self.state = .ready(connection, input.snapshot, Date())
                DiagnosticLog.record("gemini prewarm success")
                self.expiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(GeminiPrewarmPolicy.maximumWarmAge)) }
                    catch { return }
                    self?.shutdown()
                }
            } catch {
                connection.cancel()
                guard let self, case .warming(let currentID, _, _, _) = self.state, currentID == id else { return }
                self.state = .idle
                DiagnosticLog.record("gemini prewarm failure")
            }
        }
        state = .warming(id, task, connection, input.snapshot)
        return task
    }

    /// Assign ownership before the first suspension so cancelling preparation closes the socket.
    func connectForTake(current: GeminiPrewarmSnapshot, enabled: Bool, apiKey: String,
                        assign: (GeminiLiveConnection) -> Void) async throws -> GeminiLiveConnection {
        if enabled, let warm = adopt(current: current) {
            assign(warm)
            DiagnosticLog.record("gemini prewarm adopted")
            return warm
        }
        DiagnosticLog.record("gemini prewarm miss")
        let fresh = makeConnection()
        assign(fresh)
        try await fresh.connect(apiKey: apiKey, vocabulary: current.vocabulary,
                                style: current.style, japaneseHint: current.japaneseHint)
        return fresh
    }

    private func adopt(current: GeminiPrewarmSnapshot) -> GeminiLiveConnection? {
        if case .ready(let connection, let snapshot, let warmedAt) = state {
            if connection.isUsableForPrewarm && GeminiPrewarmPolicy.isUsable(
                snapshot: snapshot, current: current, warmedAt: warmedAt, now: Date()) {
                expiry?.cancel()
                expiry = nil
                state = .idle
                return connection
            }
        }
        // A take never waits for an unfinished warm; retain the original cold path.
        shutdown()
        return nil
    }

    func shutdown() {
        expiry?.cancel()
        expiry = nil
        switch state {
        case .warming(_, let task, let connection, _): task.cancel(); connection.cancel()
        case .ready(let connection, _, _): connection.cancel()
        case .idle: break
        }
        state = .idle
    }
}
#endif
