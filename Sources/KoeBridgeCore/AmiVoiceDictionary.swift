import CryptoKit
import Foundation

public enum AmiVoiceDictionarySamplingRate: String, CaseIterable, Codable, Sendable {
    case rate8k = "8k"
    case rate16k = "16k"
}

public struct AmiVoiceDictionaryProfileKey: Codable, Equatable, Hashable, Sendable {
    public var engine: AmiVoiceEngine
    public var samplingRate: AmiVoiceDictionarySamplingRate

    public init(engine: AmiVoiceEngine, samplingRate: AmiVoiceDictionarySamplingRate = .rate16k) {
        self.engine = engine
        self.samplingRate = samplingRate
    }

    public var storageKey: String {
        engine.rawValue + "|" + samplingRate.rawValue
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.engine.rawValue == rhs.engine.rawValue && lhs.samplingRate == rhs.samplingRate
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(engine.rawValue)
        hasher.combine(samplingRate.rawValue)
    }
}

/// Validated server-side profile identifier. The recognition reference always
/// carries the mandatory leading colon; the stored/raw identifier never does.
public struct AmiVoiceProfileID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard let sanitized = AmiVoiceWire.sanitizeProfileId(rawValue) else { return nil }
        self.rawValue = sanitized
    }

    public var recognitionReference: String {
        ":" + rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let validated = Self(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid AmiVoice profile ID")
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AmiVoiceDictionaryEngineFamily: String, Codable, Sendable {
    case hybrid
    case e2e

    public init(engine: AmiVoiceEngine) {
        self = engine.isE2E ? .e2e : .hybrid
    }
}

public enum AmiVoiceDictionaryEntryState: String, CaseIterable, Codable, Sendable {
    case candidate
    case pendingReview = "pending_review"
    case readyToSync = "ready_to_sync"
    case autoSynced = "auto_synced"
    case syncFailed = "sync_failed"
    case autoDisabled = "auto_disabled"
    case archived
    case ignored

    public var participatesInSnapshot: Bool {
        switch self {
        case .readyToSync, .autoSynced:
            return true
        case .candidate, .pendingReview, .syncFailed, .autoDisabled, .archived, .ignored:
            return false
        }
    }
}

public enum AmiVoiceDictionarySyncErrorClass: String, Codable, Sendable {
    case authenticationMissing = "authentication_missing"
    case authenticationRejected = "authentication_rejected"
    case validation
    case network
    case timeout
    case server
    case capExceeded = "cap_exceeded"
    case profileMissing = "profile_missing"
    case store
    case unknown
}

public enum AmiVoiceDictionarySyncResultKind: String, Codable, Sendable {
    case success
    case noChanges = "no_changes"
    case disabled
    case authenticationRequired = "authentication_required"
    case authenticationRejected = "authentication_rejected"
    case validationFailed = "validation_failed"
    case temporaryFailure = "temporary_failure"
    case capExceeded = "cap_exceeded"
    case storeFailure = "store_failure"
    case alreadyInFlight = "already_in_flight"
}

public struct AmiVoiceDictionaryEngineState: Codable, Equatable, Sendable {
    public var key: AmiVoiceDictionaryProfileKey
    public var state: AmiVoiceDictionaryEntryState
    public var dirty: Bool
    public var failureCount: Int
    public var lastErrorClass: AmiVoiceDictionarySyncErrorClass?
    public var lastSyncedAt: Date?
    public var generation: UInt64

    public init(
        key: AmiVoiceDictionaryProfileKey,
        state: AmiVoiceDictionaryEntryState = .candidate,
        dirty: Bool = false,
        failureCount: Int = 0,
        lastErrorClass: AmiVoiceDictionarySyncErrorClass? = nil,
        lastSyncedAt: Date? = nil,
        generation: UInt64 = 0
    ) {
        self.key = key
        self.state = state
        self.dirty = dirty
        self.failureCount = failureCount
        self.lastErrorClass = lastErrorClass
        self.lastSyncedAt = lastSyncedAt
        self.generation = generation
    }
}

public struct AmiVoiceDictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var written: String
    public var spoken: String?
    public var className: String?
    public var alternativeWritten: String?
    public var biasing: Double?
    public var isProtected: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var engineStates: [AmiVoiceDictionaryEngineState]

    public init(
        id: UUID = UUID(),
        written: String,
        spoken: String? = nil,
        className: String? = nil,
        alternativeWritten: String? = nil,
        biasing: Double? = nil,
        isProtected: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        engineStates: [AmiVoiceDictionaryEngineState] = []
    ) {
        self.id = id
        self.written = written
        self.spoken = spoken
        self.className = className
        self.alternativeWritten = alternativeWritten
        self.biasing = biasing
        self.isProtected = isProtected
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.engineStates = engineStates
    }

    public func engineState(for key: AmiVoiceDictionaryProfileKey) -> AmiVoiceDictionaryEngineState? {
        engineStates.first { $0.key == key }
    }

    public mutating func ensureEngineState(for key: AmiVoiceDictionaryProfileKey) -> AmiVoiceDictionaryEngineState {
        if let existing = engineState(for: key) { return existing }
        let created = AmiVoiceDictionaryEngineState(key: key)
        engineStates.append(created)
        return created
    }

    public mutating func updateEngineState(
        for key: AmiVoiceDictionaryProfileKey,
        _ update: (inout AmiVoiceDictionaryEngineState) -> Void
    ) {
        _ = ensureEngineState(for: key)
        guard let index = engineStates.firstIndex(where: { $0.key == key }) else { return }
        update(&engineStates[index])
    }
}

public struct AmiVoiceDictionaryWordPayload: Codable, Equatable, Sendable {
    public var written: String
    public var spoken: String?
    public var className: String?
    public var alternativeWritten: String?
    public var biasing: Double?

    private enum CodingKeys: String, CodingKey {
        case written
        case spoken
        case className = "classname"
        case alternativeWritten = "alternativewritten"
        case biasing
    }

    public init(
        written: String,
        spoken: String? = nil,
        className: String? = nil,
        alternativeWritten: String? = nil,
        biasing: Double? = nil
    ) {
        self.written = written
        self.spoken = spoken
        self.className = className
        self.alternativeWritten = alternativeWritten
        self.biasing = biasing
    }

    public static func hybrid(written: String, spoken: String, className: String? = nil) -> Self {
        Self(written: written, spoken: spoken, className: className)
    }

    public static func e2e(written: String, alternativeWritten: String? = nil, biasing: Double? = nil) -> Self {
        Self(written: written, alternativeWritten: alternativeWritten, biasing: biasing)
    }

    public func canonical(for family: AmiVoiceDictionaryEngineFamily) -> Self {
        switch family {
        case .hybrid:
            return Self(written: written, spoken: spoken, className: className)
        case .e2e:
            return Self(written: written, alternativeWritten: alternativeWritten, biasing: biasing)
        }
    }

    public static func fingerprint(
        payloads: [Self],
        family: AmiVoiceDictionaryEngineFamily
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonicalParts = payloads
            .map { $0.canonical(for: family) }
            .compactMap { try? encoder.encode($0) }
            .map { $0.base64EncodedString() }
            .sorted()
        let joined = canonicalParts.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum AmiVoiceDictionaryValidationFailure: Error, Equatable, Sendable {
    case emptyWritten
    case forbiddenWrittenCharacter
    case missingSpoken
    case invalidSpoken
    case invalidAlternativeWritten
    case invalidBiasing
}

public enum AmiVoiceDictionaryValidator {
    public static func payload(
        for entry: AmiVoiceDictionaryEntry,
        engine: AmiVoiceEngine
    ) throws -> AmiVoiceDictionaryWordPayload {
        guard !entry.written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AmiVoiceDictionaryValidationFailure.emptyWritten
        }
        guard !hasForbiddenWrittenScalar(entry.written) else {
            throw AmiVoiceDictionaryValidationFailure.forbiddenWrittenCharacter
        }
        let className = nonEmpty(entry.className)
        switch AmiVoiceDictionaryEngineFamily(engine: engine) {
        case .hybrid:
            guard let spoken = entry.spoken,
                  !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AmiVoiceDictionaryValidationFailure.missingSpoken
            }
            guard !hasWhitespaceOrControlScalar(spoken) else {
                throw AmiVoiceDictionaryValidationFailure.invalidSpoken
            }
            return .hybrid(written: entry.written, spoken: spoken, className: className)
        case .e2e:
            if let alternative = entry.alternativeWritten,
               alternative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AmiVoiceDictionaryValidationFailure.invalidAlternativeWritten
            }
            if let biasing = entry.biasing {
                guard biasing.isFinite, biasing >= 0.0, biasing <= 1.0 else {
                    throw AmiVoiceDictionaryValidationFailure.invalidBiasing
                }
            }
            return .e2e(written: entry.written, alternativeWritten: nonEmpty(entry.alternativeWritten), biasing: entry.biasing)
        }
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    private static func hasForbiddenWrittenScalar(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar == "|" || scalar == ":" || scalar.value == 0x20 || isControl(scalar)
        }
    }

    private static func hasWhitespaceOrControlScalar(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value == 0x20 || scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D || isControl(scalar)
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20) || (scalar.value >= 0x7F && scalar.value <= 0x9F)
    }
}

public struct AmiVoiceDictionaryEntryRejection: Equatable, Sendable {
    public enum Field: String, Equatable, Sendable {
        case written
        case spoken
        case className
        case alternativeWritten
        case unknown
    }

    public var field: Field
    public var value: String?

    public init(field: Field, value: String?) {
        self.field = field
        self.value = value
    }
}

public enum AmiVoiceDictionaryTemporaryFailure: Equatable, Sendable {
    case network
    case timeout
    case cancelled
    case serverStatus(Int)
    case unexpectedStatus(Int)
}

public enum AmiVoiceDictionaryTransportError: Error, Equatable, Sendable {
    case invalidRequest
    case authentication
    case entryValidation(AmiVoiceDictionaryEntryRejection?)
    case profileMissing
    case limitExceeded
    case temporary(AmiVoiceDictionaryTemporaryFailure)
    case malformedResponse
}

public protocol AmiVoiceDictionaryTransport: Sendable {
    func fetchWords(
        engine: AmiVoiceEngine,
        samplingRate: AmiVoiceDictionarySamplingRate,
        profileID: AmiVoiceProfileID,
        apiKey: String
    ) async throws -> [AmiVoiceDictionaryWordPayload]

    func replaceWords(
        engine: AmiVoiceEngine,
        samplingRate: AmiVoiceDictionarySamplingRate,
        profileID: AmiVoiceProfileID,
        apiKey: String,
        payloads: [AmiVoiceDictionaryWordPayload]
    ) async throws -> [AmiVoiceDictionaryWordPayload]
}

public final class AmiVoiceDictionaryNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class AmiVoiceDictionarySessionBox: @unchecked Sendable {
    let session: URLSession

    init(session: URLSession) {
        self.session = session
    }
}

public struct AmiVoiceDictionaryAPIClient: AmiVoiceDictionaryTransport {
    public typealias Perform = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let endpointBase = "https://acp-api.amivoice.com"

    private let perform: Perform

    public init(perform: @escaping Perform) {
        self.perform = perform
    }

    public init() {
        self.perform = Self.makeDefaultPerform()
    }

    public static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: AmiVoiceDictionaryNoRedirectDelegate(), delegateQueue: nil)
    }

    private static func makeDefaultPerform() -> Perform {
        let box = AmiVoiceDictionarySessionBox(session: makeEphemeralSession())
        return { request in
            let (data, response) = try await box.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AmiVoiceDictionaryTransportError.malformedResponse
            }
            return (data, http)
        }
    }

    public static func makeURL(
        engine: AmiVoiceEngine,
        samplingRate: AmiVoiceDictionarySamplingRate,
        profileID: AmiVoiceProfileID
    ) throws -> URL {
        let raw = endpointBase + "/profilewords/" + engine.rawValue + "/" + profileID.rawValue
        guard var components = URLComponents(string: raw) else {
            throw AmiVoiceDictionaryTransportError.invalidRequest
        }
        components.queryItems = [URLQueryItem(name: "adf", value: samplingRate.rawValue)]
        guard let url = components.url else {
            throw AmiVoiceDictionaryTransportError.invalidRequest
        }
        return url
    }

    public static func makeRequest(
        method: String,
        engine: AmiVoiceEngine,
        samplingRate: AmiVoiceDictionarySamplingRate,
        profileID: AmiVoiceProfileID,
        apiKey: String,
        payloads: [AmiVoiceDictionaryWordPayload]? = nil
    ) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw AmiVoiceDictionaryTransportError.authentication }
        var request = URLRequest(url: try makeURL(engine: engine, samplingRate: samplingRate, profileID: profileID))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let payloads {
            struct Body: Encodable { let profilewords: [AmiVoiceDictionaryWordPayload] }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            request.httpBody = try encoder.encode(Body(profilewords: payloads))
        }
        return request
    }

    public func fetchWords(
        engine: AmiVoiceEngine,
        samplingRate: AmiVoiceDictionarySamplingRate,
        profileID: AmiVoiceProfileID,
        apiKey: String
    ) async throws -> [AmiVoiceDictionaryWordPayload] {
        let request = try Self.makeRequest(
            method: "GET",
            engine: engine,
            samplingRate: samplingRate,
            profileID: profileID,
            apiKey: apiKey
        )
        let data = try await execute(request)
        return try Self.decodeWords(from: data)
    }

    public func replaceWords(
        engine: AmiVoiceEngine,
        samplingRate: AmiVoiceDictionarySamplingRate,
        profileID: AmiVoiceProfileID,
        apiKey: String,
        payloads: [AmiVoiceDictionaryWordPayload]
    ) async throws -> [AmiVoiceDictionaryWordPayload] {
        let request = try Self.makeRequest(
            method: "POST",
            engine: engine,
            samplingRate: samplingRate,
            profileID: profileID,
            apiKey: apiKey,
            payloads: payloads
        )
        let data = try await execute(request)
        return try Self.decodeWords(from: data)
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await perform(request)
            try Self.throwIfError(response: response, data: data)
            return data
        } catch let error as AmiVoiceDictionaryTransportError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut { throw AmiVoiceDictionaryTransportError.temporary(.timeout) }
            if error.code == .cancelled { throw AmiVoiceDictionaryTransportError.temporary(.cancelled) }
            throw AmiVoiceDictionaryTransportError.temporary(.network)
        } catch {
            if error is CancellationError { throw AmiVoiceDictionaryTransportError.temporary(.cancelled) }
            throw AmiVoiceDictionaryTransportError.temporary(.network)
        }
    }

    private static func decodeWords(from data: Data) throws -> [AmiVoiceDictionaryWordPayload] {
        struct Body: Decodable { let profilewords: [AmiVoiceDictionaryWordPayload] }
        guard let decoded = try? JSONDecoder().decode(Body.self, from: data) else {
            throw AmiVoiceDictionaryTransportError.malformedResponse
        }
        return decoded.profilewords
    }

    private static func throwIfError(response: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        switch response.statusCode {
        case 400, 422:
            throw AmiVoiceDictionaryTransportError.entryValidation(parseEntryRejection(from: data))
        case 401, 403:
            throw AmiVoiceDictionaryTransportError.authentication
        case 404:
            throw AmiVoiceDictionaryTransportError.profileMissing
        case 413:
            throw AmiVoiceDictionaryTransportError.limitExceeded
        case 408, 409, 425, 429:
            throw AmiVoiceDictionaryTransportError.temporary(.serverStatus(response.statusCode))
        default:
            if response.statusCode >= 500 {
                throw AmiVoiceDictionaryTransportError.temporary(.serverStatus(response.statusCode))
            }
            throw AmiVoiceDictionaryTransportError.temporary(.unexpectedStatus(response.statusCode))
        }
    }

    private static func parseEntryRejection(from data: Data) -> AmiVoiceDictionaryEntryRejection? {
        struct ErrorBody: Decodable { let message: String? }
        guard let message = try? JSONDecoder().decode(ErrorBody.self, from: data).message else { return nil }
        let patterns: [(String, AmiVoiceDictionaryEntryRejection.Field)] = [
            ("invalid written: ", .written),
            ("invalid spoken: ", .spoken),
            ("invalid class name: ", .className),
            ("invalid alternative written: ", .alternativeWritten)
        ]
        for (prefix, field) in patterns where message.hasPrefix(prefix) {
            return AmiVoiceDictionaryEntryRejection(field: field, value: String(message.dropFirst(prefix.count)))
        }
        if message.hasPrefix("invalid ") {
            return AmiVoiceDictionaryEntryRejection(field: .unknown, value: nil)
        }
        return nil
    }
}

public struct AmiVoiceDictionaryProfile: Codable, Equatable, Sendable {
    public var key: AmiVoiceDictionaryProfileKey
    public var profileID: AmiVoiceProfileID
    public var lastSyncedFingerprint: String?
    public var lastSyncAt: Date?
    public var lastResult: AmiVoiceDictionarySyncResultKind?
    public var lastErrorClass: AmiVoiceDictionarySyncErrorClass?
    public var consecutiveTemporaryFailures: Int
    public var backoffUntil: Date?
    public var authenticationBlocked: Bool

    public init(
        key: AmiVoiceDictionaryProfileKey,
        profileID: AmiVoiceProfileID,
        lastSyncedFingerprint: String? = nil,
        lastSyncAt: Date? = nil,
        lastResult: AmiVoiceDictionarySyncResultKind? = nil,
        lastErrorClass: AmiVoiceDictionarySyncErrorClass? = nil,
        consecutiveTemporaryFailures: Int = 0,
        backoffUntil: Date? = nil,
        authenticationBlocked: Bool = false
    ) {
        self.key = key
        self.profileID = profileID
        self.lastSyncedFingerprint = lastSyncedFingerprint
        self.lastSyncAt = lastSyncAt
        self.lastResult = lastResult
        self.lastErrorClass = lastErrorClass
        self.consecutiveTemporaryFailures = consecutiveTemporaryFailures
        self.backoffUntil = backoffUntil
        self.authenticationBlocked = authenticationBlocked
    }
}

public struct AmiVoiceDictionarySyncStatus: Codable, Equatable, Sendable {
    public var automaticSyncEnabled: Bool
    public var lastResult: AmiVoiceDictionarySyncResultKind?
    public var pendingCount: Int
    public var quarantinedCount: Int
    public var lastErrorClass: AmiVoiceDictionarySyncErrorClass?
    public var lastSyncAt: Date?
    public var backoffUntil: Date?
    public var activeProfileID: String?
    public var softCapExceeded: Bool

    public init(
        automaticSyncEnabled: Bool,
        lastResult: AmiVoiceDictionarySyncResultKind?,
        pendingCount: Int,
        quarantinedCount: Int,
        lastErrorClass: AmiVoiceDictionarySyncErrorClass?,
        lastSyncAt: Date?,
        backoffUntil: Date?,
        activeProfileID: String?,
        softCapExceeded: Bool
    ) {
        self.automaticSyncEnabled = automaticSyncEnabled
        self.lastResult = lastResult
        self.pendingCount = pendingCount
        self.quarantinedCount = quarantinedCount
        self.lastErrorClass = lastErrorClass
        self.lastSyncAt = lastSyncAt
        self.backoffUntil = backoffUntil
        self.activeProfileID = activeProfileID
        self.softCapExceeded = softCapExceeded
    }

    public static func make(
        automaticSyncEnabled: Bool,
        entries: [AmiVoiceDictionaryEntry],
        profile: AmiVoiceDictionaryProfile?,
        key: AmiVoiceDictionaryProfileKey
    ) -> Self {
        let states = entries.compactMap { $0.engineState(for: key) }
        let pendingCount = states.filter { $0.dirty && $0.state.participatesInSnapshot }.count
        let quarantinedCount = states.filter { $0.state == .pendingReview || $0.state == .syncFailed }.count
        let activeCount = states.filter { $0.state.participatesInSnapshot }.count
        return Self(
            automaticSyncEnabled: automaticSyncEnabled,
            lastResult: profile?.lastResult,
            pendingCount: pendingCount,
            quarantinedCount: quarantinedCount,
            lastErrorClass: profile?.lastErrorClass,
            lastSyncAt: profile?.lastSyncAt,
            backoffUntil: profile?.backoffUntil,
            activeProfileID: AmiVoiceDictionarySyncPolicy.recognitionProfileID(
                automaticSyncEnabled: automaticSyncEnabled,
                entries: entries,
                profile: profile,
                key: key
            ),
            softCapExceeded: activeCount >= AmiVoiceDictionarySyncPolicy.softEntryLimit
        )
    }
}

public final class AmiVoiceDictionarySyncStore: @unchecked Sendable {
    public static let entriesKey = "amiVoiceDictionaryEntries"
    public static let profilesKey = "amiVoiceDictionaryProfiles"
    public static let automaticSyncEnabledKey = "amiVoiceDictionaryAutoSyncEnabled"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var entriesStore: SettingsArray<AmiVoiceDictionaryEntry>
    private var profilesStore: SettingsArray<AmiVoiceDictionaryProfile>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entriesStore = SettingsArray(Self.entriesKey, defaults: defaults)
        profilesStore = SettingsArray(Self.profilesKey, defaults: defaults)
    }

    public var automaticSyncEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return defaults.bool(forKey: Self.automaticSyncEnabledKey)
        }
        set {
            lock.lock()
            defaults.set(newValue, forKey: Self.automaticSyncEnabledKey)
            lock.unlock()
        }
    }

    public func loadEntries() -> [AmiVoiceDictionaryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entriesStore.rows
    }

    @discardableResult public func saveEntries(_ rows: [AmiVoiceDictionaryEntry]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entriesStore.save(rows)
    }

    public func loadProfiles() -> [AmiVoiceDictionaryProfile] {
        lock.lock()
        defer { lock.unlock() }
        return profilesStore.rows
    }

    @discardableResult public func saveProfiles(_ rows: [AmiVoiceDictionaryProfile]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return profilesStore.save(rows)
    }

    public func profile(for key: AmiVoiceDictionaryProfileKey) -> AmiVoiceDictionaryProfile? {
        loadProfiles().first { $0.key == key }
    }

    public func resetCorruptValues() {
        lock.lock()
        entriesStore.resetCorruptValue()
        profilesStore.resetCorruptValue()
        lock.unlock()
    }
}

public enum AmiVoiceDictionarySyncPolicy {
    public static let softEntryLimit = 800
    public static let hardEntryLimit = 1_000
    public static let defaultDebounceInterval: TimeInterval = 300
    public static let temporaryFailureBaseBackoff: TimeInterval = 30
    public static let temporaryFailureMaximumBackoff: TimeInterval = 3_600
    public static let maximumAutomaticRetryCount = 5
    public static let maximumValidationIsolationAttempts = 8

    public static func recognitionProfileID(
        automaticSyncEnabled: Bool,
        entries: [AmiVoiceDictionaryEntry],
        profile: AmiVoiceDictionaryProfile?,
        key: AmiVoiceDictionaryProfileKey
    ) -> String? {
        guard automaticSyncEnabled, let profile else { return nil }
        let hasSyncedWord = entries.contains { entry in
            entry.engineState(for: key)?.state == .autoSynced
        }
        guard hasSyncedWord else { return nil }
        return profile.profileID.rawValue
    }

    public static func temporaryBackoff(failureCount: Int) -> TimeInterval {
        let clampedCount = max(1, failureCount)
        let exponent = min(clampedCount - 1, 7)
        let multiplier = pow(2.0, Double(exponent))
        return min(temporaryFailureMaximumBackoff, temporaryFailureBaseBackoff * multiplier)
    }
}
