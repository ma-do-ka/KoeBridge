import Foundation

/// Phase 0 minimal telemetry (GD-737): on-device aggregation only.
/// Numbers and existing enum/diagnostic codes are the only recorded values.
/// Speech content, recognized text, field text, clipboard, window titles,
/// URLs, target-app identifiers, user/device identifiers and network
/// activity are never part of this module — it has no networking at all.
///
/// Counting is an in-memory dictionary update; the daily aggregate flushes
/// to one app-local JSON file asynchronously and infrequently. Any error in
/// counting or persistence is swallowed: measurement is fail-open and can
/// never delay, block, or fail the dictation/delivery paths.
public enum LocalDiagnosticEvent: Sendable {
    case fieldRead(milliseconds: Int, timedOut: Bool)
    case micReplacementAttempt
    case micVerificationDeferral
    case micRecoverySuccess
    case micUnrecovered
    case failure(code: String)
    case fieldNature(InsertionReceiptPolicy.FieldNature)
    case volumeGuardActivation
    case failClosed(code: String)
}

public struct LocalDiagnosticDailySummary: Codable, Equatable, Sendable {
    public static let fieldReadBucketLabels = [
        "0-5ms", "6-10ms", "11-20ms", "21-40ms", "41-80ms", "81-160ms", "161ms+"
    ]

    /// Ordered upper bounds (inclusive) matching `fieldReadBucketLabels`.
    private static let fieldReadBucketEdges = [5, 10, 20, 40, 80, 160]

    public static func fieldReadBucket(milliseconds: Int) -> String {
        for (edge, label) in zip(fieldReadBucketEdges, fieldReadBucketLabels) {
            if milliseconds <= edge { return label }
        }
        return fieldReadBucketLabels.last!
    }

    public var fieldReadMilliseconds: [String: Int] = [:]
    public var fieldReadTimeouts = 0
    public var micReplacementAttempts = 0
    public var micVerificationDeferrals = 0
    public var micRecoverySuccesses = 0
    public var micUnrecovered = 0
    public var failures: [String: Int] = [:]
    public var fieldNatureNormal = 0
    public var fieldNatureProtected = 0
    public var fieldNatureUnknown = 0
    public var volumeGuardActivations = 0
    public var failClosed: [String: Int] = [:]

    public init() {}

    /// Dynamic keys are existing diagnostic codes only. Anything that does
    /// not look like an enum code is dropped instead of recorded, so no
    /// content string can ever enter an aggregate.
    public static func isAllowedCode(_ code: String) -> Bool {
        let bytes = code.utf8
        return !bytes.isEmpty && bytes.count <= 64 && bytes.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || byte == 45 || byte == 95 || byte == 46
        }
    }

    private static func saturating(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }

    public mutating func merge(_ other: Self) {
        fieldReadTimeouts += other.fieldReadTimeouts
        micReplacementAttempts += other.micReplacementAttempts
        micVerificationDeferrals += other.micVerificationDeferrals
        micRecoverySuccesses += other.micRecoverySuccesses
        micUnrecovered += other.micUnrecovered
        fieldNatureNormal += other.fieldNatureNormal
        fieldNatureProtected += other.fieldNatureProtected
        fieldNatureUnknown += other.fieldNatureUnknown
        volumeGuardActivations += other.volumeGuardActivations
        for (key, count) in other.fieldReadMilliseconds {
            guard Self.fieldReadBucketLabels.contains(key) else { continue }
            fieldReadMilliseconds[key] = (fieldReadMilliseconds[key] ?? 0) + count
        }
        for (key, count) in other.failures {
            guard Self.isAllowedCode(key) else { continue }
            failures[key] = (failures[key] ?? 0) + count
        }
        for (key, count) in other.failClosed {
            guard Self.isAllowedCode(key) else { continue }
            failClosed[key] = (failClosed[key] ?? 0) + count
        }
    }

    package mutating func apply(_ event: LocalDiagnosticEvent) {
        switch event {
        case .fieldRead(let milliseconds, let timedOut):
            guard milliseconds >= 0 else { return }
            let bucket = Self.fieldReadBucket(milliseconds: milliseconds)
            fieldReadMilliseconds[bucket] = Self.saturating(fieldReadMilliseconds[bucket] ?? 0)
            if timedOut { fieldReadTimeouts = Self.saturating(fieldReadTimeouts) }
        case .micReplacementAttempt:
            micReplacementAttempts = Self.saturating(micReplacementAttempts)
        case .micVerificationDeferral:
            micVerificationDeferrals = Self.saturating(micVerificationDeferrals)
        case .micRecoverySuccess:
            micRecoverySuccesses = Self.saturating(micRecoverySuccesses)
        case .micUnrecovered:
            micUnrecovered = Self.saturating(micUnrecovered)
        case .failure(let code):
            guard Self.isAllowedCode(code) else { return }
            failures[code] = Self.saturating(failures[code] ?? 0)
        case .fieldNature(let nature):
            switch nature {
            case .normal: fieldNatureNormal = Self.saturating(fieldNatureNormal)
            case .protected: fieldNatureProtected = Self.saturating(fieldNatureProtected)
            case .unknown: fieldNatureUnknown = Self.saturating(fieldNatureUnknown)
            }
        case .volumeGuardActivation:
            volumeGuardActivations = Self.saturating(volumeGuardActivations)
        case .failClosed(let code):
            guard Self.isAllowedCode(code) else { return }
            failClosed[code] = Self.saturating(failClosed[code] ?? 0)
        }
    }
}

/// The on-disk aggregate. `days` keys are local `yyyy-MM-dd` stamps; every
/// value is a count. The file stays small and human-readable.
public struct LocalDiagnosticArchive: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var build: Int
    public var days: [String: LocalDiagnosticDailySummary]

    public init(schema: Int = LocalDiagnosticArchive.currentSchema, build: Int,
                days: [String: LocalDiagnosticDailySummary]) {
        self.schema = schema
        self.build = build
        self.days = days
    }
}

/// An optional, private, bounded device-local aggregate of diagnostic
/// counters. Never stores transcripts, PCM, identifiers, or any string a
/// caller supplied that is not an existing diagnostic code.
public final class LocalDiagnosticCounter: @unchecked Sendable {
    public static let preferenceKey = "localDiagnosticsEnabled"
    public static let retentionDays = 30
    public static let flushInterval: TimeInterval = 30
    public static let maximumFileBytes = 256 * 1024

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KoeBridge", isDirectory: true)
            .appendingPathComponent("local-diagnostics.json")
    }

    private let fileURL: URL
    private let build: () -> Int
    private let now: () -> Date
    private let calendar: Calendar
    private let write: (LocalDiagnosticArchive, URL) throws -> Void
    private let remove: (URL) throws -> Void

    private let queue = DispatchQueue(label: "dev.koebridge.local-diagnostics", qos: .utility)
    private let lock = NSLock()
    // Counters only ever change under `lock`, which is a leaf lock: it is
    // never held across file I/O and is not shared with any other lane.
    private var enabled: Bool
    private var days: [String: LocalDiagnosticDailySummary] = [:]
    private var loaded = false
    private var writable = true
    private var pendingFlush: DispatchWorkItem?
    private var lastFailure: String?

    public init(fileURL: URL = LocalDiagnosticCounter.defaultFileURL,
                enabled: Bool = true,
                build: @escaping @Sendable () -> Int = {
                    Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
                },
                now: @escaping @Sendable () -> Date = { Date() },
                calendar: Calendar = .current,
                write: ((LocalDiagnosticArchive, URL) throws -> Void)? = nil,
                remove: ((URL) throws -> Void)? = nil) {
        self.fileURL = fileURL
        self.enabled = enabled
        self.build = build
        self.now = now
        self.calendar = calendar
        self.write = write ?? Self.defaultWrite
        self.remove = remove ?? Self.defaultRemove
        queue.async { [self] in load() }
    }

    public var isEnabled: Bool {
        lock.withLock { enabled }
    }

    public var storeFileURL: URL { fileURL }

    public func setEnabled(_ value: Bool) {
        lock.withLock {
            enabled = value
            if !value {
                // OFF is immediately inert: drop in-memory aggregates and any
                // queued write so nothing can reach the file while OFF.
                days = [:]
                pendingFlush?.cancel()
                pendingFlush = nil
            }
        }
    }

    /// Day stamps sort chronologically as `yyyy-MM-dd` strings.
    private func dayKey(for date: Date) -> String {
        var copy = calendar
        copy.timeZone = calendar.timeZone
        let parts = copy.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func load() {
        var storedDays: [String: LocalDiagnosticDailySummary] = [:]
        var readable = true
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            do {
                let attributes = try fm.attributesOfItem(atPath: fileURL.path)
                if let size = (attributes[.size] as? NSNumber)?.intValue,
                   size > Self.maximumFileBytes {
                    readable = false
                } else {
                    let decoded = try JSONDecoder().decode(LocalDiagnosticArchive.self,
                                                           from: Data(contentsOf: fileURL))
                    storedDays = decoded.days.filter { Self.isDayKey($0.key) }
                }
            } catch {
                // Do not replace an unreadable archive with a fresh file.
                readable = false
            }
        }
        lock.withLock {
            loaded = true
            writable = readable
            // A wipe or OFF that landed while the file was being read must
            // not be undone by repopulating counters from the archive.
            if enabled {
                for (key, summary) in storedDays {
                    days[key, default: LocalDiagnosticDailySummary()].merge(summary)
                }
                if readable { pruneLocked() }
                if !days.isEmpty { scheduleFlushLocked() }
            }
        }
    }

    private static func isDayKey(_ key: String) -> Bool {
        let bytes = key.utf8
        guard bytes.count == 10 else { return false }
        for (index, byte) in bytes.enumerated() {
            if index == 4 || index == 7 {
                guard byte == 45 else { return false }
            } else {
                guard (48...57).contains(byte) else { return false }
            }
        }
        return true
    }

    private func pruneLocked() {
        let cutoff = dayKey(for: now().addingTimeInterval(-Double(Self.retentionDays) * 86_400))
        let today = dayKey(for: now())
        days = days.filter { $0.key >= cutoff && $0.key <= today }
        if days.count > Self.retentionDays {
            let keep = Set(days.keys.sorted().suffix(Self.retentionDays))
            days = days.filter { keep.contains($0.key) }
        }
    }

    private func scheduleFlushLocked() {
        guard pendingFlush == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.persist() }
        pendingFlush = item
        queue.asyncAfter(deadline: .now() + Self.flushInterval, execute: item)
    }

    public func record(_ event: LocalDiagnosticEvent) {
        lock.withLock {
            guard enabled else { return }
            days[dayKey(for: now()), default: LocalDiagnosticDailySummary()].apply(event)
            scheduleFlushLocked()
        }
    }

    /// Persist once on the counter's own queue. All write errors are
    /// swallowed; a failure leaves the counters intact for a later flush.
    private func persist() {
        let archive: LocalDiagnosticArchive? = lock.withLock {
            pendingFlush = nil
            guard enabled, writable else { return nil }
            pruneLocked()
            return LocalDiagnosticArchive(build: build(), days: days)
        }
        guard let archive else { return }
        do {
            try write(archive, fileURL)
        } catch {
            lock.withLock { lastFailure = String(describing: type(of: error)) }
        }
    }

    /// Async, coalesced with the scheduled low-frequency flush.
    public func flush() {
        queue.async { [self] in persist() }
    }

    /// Used by tests and user actions that need the file on disk now.
    public func flushBlocking() {
        queue.sync { persist() }
    }

    /// Remove the stored aggregate and clear in-memory counters. Removal and
    /// the in-memory clear run on the counter's own queue so a startup
    /// `load()` still in flight cannot resurrect wiped aggregates, and a
    /// previously unreadable archive stops blocking persistence afterwards.
    public func deleteAll() throws {
        try queue.sync {
            try remove(fileURL)
            lock.withLock {
                days = [:]
                pendingFlush?.cancel()
                pendingFlush = nil
                writable = true
            }
        }
    }

    /// Current in-memory snapshot (for inspection and tests).
    public func snapshot() -> LocalDiagnosticArchive {
        lock.withLock { LocalDiagnosticArchive(build: build(), days: days) }
    }

    private static func defaultWrite(_ archive: LocalDiagnosticArchive, to fileURL: URL) throws {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                             ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= maximumFileBytes else { return }
        try data.write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                             ofItemAtPath: fileURL.path)
    }

    private static func defaultRemove(_ fileURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
    }
}

/// The process-wide counter facade used by instrumentation points.
/// Default state is ON (dispatcher-adjudicated): strictly local, no
/// transmission, fully viewable and wipeable from Settings.
public enum LocalDiagnostics {
    nonisolated(unsafe) public static var counter = LocalDiagnosticCounter(
        enabled: UserDefaults.standard.object(forKey: LocalDiagnosticCounter.preferenceKey) as? Bool ?? true)

    /// Every call is a bounded in-memory update; it cannot throw and must
    /// stay cheap on the capture/delivery lanes.
    public static func record(_ event: LocalDiagnosticEvent) {
        counter.record(event)
    }

    public static var isEnabled: Bool { counter.isEnabled }
    public static var fileURL: URL { counter.storeFileURL }

    /// Consent changes synchronously with the settings control. Turning OFF
    /// performs the full deletion of stored aggregates in the same flow.
    @MainActor public static func preferenceDidChange(_ enabled: Bool) {
        counter.setEnabled(enabled)
        if !enabled {
            try? counter.deleteAll()
        }
    }

    /// Explicit user-initiated wipe (also used while measurement stays ON).
    @MainActor public static func deleteAll() throws {
        try counter.deleteAll()
    }
}
