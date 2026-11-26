import Foundation
import CryptoKit
import Darwin
import KoeBridgeCore
import KoeBridgePOSIX

/// Small lock-protected probe for provider callbacks. Callbacks can cross tasks even
/// though the benchmark runner itself is MainActor-isolated.
final class BenchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var firstTranscriptAt: ContinuousClock.Instant?

    func markFirstTranscript(at instant: ContinuousClock.Instant = .now) {
        lock.lock()
        if firstTranscriptAt == nil { firstTranscriptAt = instant }
        lock.unlock()
    }

    func firstTranscript() -> ContinuousClock.Instant? {
        lock.lock()
        let value = firstTranscriptAt
        lock.unlock()
        return value
    }
}

enum BenchClock {
    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000.0
            + Double(components.attoseconds) / 1_000_000_000_000_000.0
    }

    static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        milliseconds(start.duration(to: end))
    }
}

enum BenchIO {
    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func inspectAudio(clip: CorpusClip, audioDir: String) -> AudioLoadState {
        let url = URL(fileURLWithPath: audioDir, isDirectory: true).appendingPathComponent(clip.file)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let wav = try Data(contentsOf: url)
            let pcm = try PCM16WAV.extractPCM(wav)
            let seconds = Double(pcm.count) / 32_000.0
            let digest = sha256Hex(pcm)
            if let locked = clip.sha256, locked != digest {
                return .hashMismatch(actual: digest)
            }
            guard seconds <= 45.0 else {
                return .invalid("45秒のAppleローカル上限を超えています")
            }
            return .loaded(ClipAudio(
                pcm: pcm,
                sha256: digest,
                bytes: pcm.count,
                seconds: seconds
            ))
        } catch {
            if clip.sha256 != nil {
                return .hashMismatch(actual: "invalid_wav")
            }
            return .invalid("canonical 16 kHz PCM16 mono WAV ではありません")
        }
    }

    static var cacheRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("koebridge-bench", isDirectory: true)
    }

    static var quotaLedgerURL: URL {
        cacheRoot.appendingPathComponent("quota-ledger.json")
    }

    static var quotaLockURL: URL {
        cacheRoot.appendingPathComponent("quota-ledger.lock")
    }

    static var quotaReservationsDir: URL {
        cacheRoot.appendingPathComponent("quota-reservations", isDirectory: true)
    }

    static func loadLedger() throws -> QuotaLedger {
        let url = quotaLedgerURL
        guard FileManager.default.fileExists(atPath: url.path) else { return QuotaLedger() }
        do {
            let data = try Data(contentsOf: url)
            let ledger = try JSONDecoder().decode(QuotaLedger.self, from: data)
            guard ledger.schema_version == 1 else {
                throw BenchFailure.quota("quota-ledger.json の schema_version が不正です")
            }
            return ledger
        } catch let failure as BenchFailure {
            throw failure
        } catch {
            throw BenchFailure.quota("quota-ledger.json を読めません。ライブ実行を中止してください")
        }
    }

    static func saveLedger(_ ledger: QuotaLedger) throws {
        let url = quotaLedgerURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(ledger)
            try data.write(to: url, options: .atomic)
        } catch {
            throw BenchFailure.quota("quota-ledger.json を更新できません。以降のネットワーク呼び出しを中止します")
        }
    }

    static func withQuotaLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: quotaReservationsDir, withIntermediateDirectories: true)
        } catch {
            throw BenchFailure.quota("quotaキャッシュディレクトリを作成できません。ライブ実行を中止してください")
        }
        let lockFD = open(quotaLockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard lockFD >= 0 else {
            throw BenchFailure.quota("quota-ledger.lock を開けません (errno=\(errno))")
        }
        defer { close(lockFD) }

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            if KBFileLockTryExclusive(lockFD) == 0 {
                break
            }
            let err = errno
            if err == EINTR { continue }
            if err == EWOULDBLOCK || err == EAGAIN {
                if ContinuousClock.now >= deadline {
                    throw BenchFailure.quota("quota-ledger.lock の取得がタイムアウトしました。他の実行が停止していないか確認してください")
                }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            throw BenchFailure.quota("quota-ledger.lock を取得できません (errno=\(err))")
        }
        return try body()
    }

    static func writeReservation(_ reservation: QuotaReservation, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(reservation)
            try data.write(to: url, options: .atomic)
        } catch {
            throw BenchFailure.quota("quota予約ファイルを書き込めません。ライブ実行を中止します")
        }
    }

    static func reserveAmiVoiceQuota(
        runID: String,
        month: String,
        engine: String,
        plannedSeconds: Double,
        monthlyCapSeconds: Double
    ) throws -> QuotaReservationSession? {
        try withQuotaLock {
            let activeReserved = try reconcileAndSumActiveReservations(
                month: month,
                engine: engine,
                excludingRunID: runID
            )
            let ledger = try loadLedger()
            let committed = ledger.months[month]?[engine] ?? 0.0
            let projected = committed + activeReserved + plannedSeconds
            guard projected <= monthlyCapSeconds else {
                if activeReserved > 0 {
                    throw BenchFailure.quota(String(
                        format: "AmiVoice月次上限を超えるためネットワーク呼び出し前に中止します: ledger=%.1fs reserved=%.1fs planned=%.1fs cap=%.1fs",
                        committed, activeReserved, plannedSeconds, monthlyCapSeconds
                    ))
                }
                throw BenchFailure.quota(String(
                    format: "AmiVoice月次上限を超えるためネットワーク呼び出し前に中止します: ledger=%.1fs planned=%.1fs cap=%.1fs",
                    committed, plannedSeconds, monthlyCapSeconds
                ))
            }

            guard plannedSeconds > 0 else {
                return nil
            }

            let lockURL = quotaReservationsDir.appendingPathComponent("\(runID).lock")
            let reservationURL = quotaReservationsDir.appendingPathComponent("\(runID).json")
            let runLockFD = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
            guard runLockFD >= 0 else {
                throw BenchFailure.quota("quota予約ロックファイルを作成できません (errno=\(errno))")
            }
            if KBFileLockTryExclusive(runLockFD) != 0 {
                let err = errno
                close(runLockFD)
                throw BenchFailure.quota("quota予約ロックを取得できません (errno=\(err))")
            }

            let nowEpoch = Date().timeIntervalSince1970
            let reservation = QuotaReservation(
                schema_version: 1,
                run_id: runID,
                month: month,
                engine: engine,
                pid: ProcessInfo.processInfo.processIdentifier,
                reserved_seconds: plannedSeconds,
                remaining_seconds: plannedSeconds,
                created_at_epoch: nowEpoch
            )
            do {
                try writeReservation(reservation, to: reservationURL)
            } catch {
                try? FileManager.default.removeItem(at: lockURL)
                close(runLockFD)
                throw error
            }
            return QuotaReservationSession(
                runID: runID,
                month: month,
                engine: engine,
                reservationURL: reservationURL,
                lockURL: lockURL,
                runLockFD: runLockFD,
                reservedSeconds: plannedSeconds,
                createdAtEpoch: nowEpoch
            )
        }
    }

    private static func reconcileAndSumActiveReservations(
        month: String,
        engine: String,
        excludingRunID: String
    ) throws -> Double {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: quotaReservationsDir,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw BenchFailure.quota("quota予約ディレクトリを読めません。ライブ実行を中止してください")
        }

        var activeTotal = 0.0
        var liveReservationBasenames = Set<String>()

        for entry in entries where entry.pathExtension == "json" {
            let base = entry.deletingPathExtension().lastPathComponent
            if base == excludingRunID { continue }
            let lockURL = quotaReservationsDir.appendingPathComponent("\(base).lock")
            let probeFD = open(lockURL.path, O_RDONLY | O_CLOEXEC)
            if probeFD < 0 {
                if errno == ENOENT {
                    try? FileManager.default.removeItem(at: entry)
                    continue
                }
                throw BenchFailure.quota("quota予約ロック状態を確認できません: \(lockURL.lastPathComponent)")
            }
            let lockResult = KBFileLockTryExclusive(probeFD)
            let lockErr = errno
            close(probeFD)

            if lockResult == 0 {
                // Previous holder exited/crashed without releasing; reclaim stale reservation.
                try? FileManager.default.removeItem(at: entry)
                try? FileManager.default.removeItem(at: lockURL)
                continue
            }
            if lockErr != EWOULDBLOCK && lockErr != EAGAIN {
                throw BenchFailure.quota("quota予約ロック検証に失敗しました (errno=\(lockErr))")
            }

            liveReservationBasenames.insert(base)
            let reservation: QuotaReservation
            do {
                let data = try Data(contentsOf: entry)
                reservation = try JSONDecoder().decode(QuotaReservation.self, from: data)
                guard reservation.schema_version == 1 else {
                    throw BenchFailure.quota("quota予約ファイルの schema_version が不正です: \(entry.lastPathComponent)")
                }
            } catch let failure as BenchFailure {
                throw failure
            } catch {
                throw BenchFailure.quota("実行中のquota予約ファイルを読めません: \(entry.lastPathComponent)")
            }

            if reservation.month == month,
               reservation.engine == engine,
               reservation.remaining_seconds.isFinite,
               reservation.remaining_seconds > 0 {
                activeTotal += reservation.remaining_seconds
            }
        }

        for entry in entries where entry.pathExtension == "lock" {
            let base = entry.deletingPathExtension().lastPathComponent
            if base == excludingRunID || liveReservationBasenames.contains(base) { continue }
            let jsonURL = quotaReservationsDir.appendingPathComponent("\(base).json")
            if !FileManager.default.fileExists(atPath: jsonURL.path) {
                let probeFD = open(entry.path, O_RDONLY | O_CLOEXEC)
                if probeFD >= 0 {
                    let lockResult = KBFileLockTryExclusive(probeFD)
                    close(probeFD)
                    if lockResult == 0 {
                        try? FileManager.default.removeItem(at: entry)
                    }
                }
            }
        }

        return activeTotal
    }

    static func jstMonthKey(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let year = components.year, let month = components.month else {
            return "unknown-month"
        }
        return String(format: "%04d-%02d", year, month)
    }

    static func loadVocabulary(path: String?) throws -> [String] {
        guard let path else { return [] }
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            return text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            throw BenchFailure.input("vocab-file を読めません: \(path)")
        }
    }

    static func keychainValue(service: String, account: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func geminiAPIKey() -> String? {
        keychainValue(service: "dev.koebridge.gemini-api", account: "personal-key")
            ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
    }

    static func amiVoiceAPIKey() -> String? {
        keychainValue(service: "dev.koebridge.amivoice-api", account: "api-key")
            ?? ProcessInfo.processInfo.environment["AMIVOICE_API_KEY"]
    }

    static func repoRoot(manifestPath: String) -> String? {
        let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
        guard manifestURL.lastPathComponent == "manifest.json" else { return nil }
        let corpus = manifestURL.deletingLastPathComponent()
        let bench = corpus.deletingLastPathComponent()
        let tools = bench.deletingLastPathComponent()
        let root = tools.deletingLastPathComponent()
        guard corpus.lastPathComponent == "corpus",
              bench.lastPathComponent == "KoeBridgeBench",
              tools.lastPathComponent == "Tools" else { return nil }
        return root.path
    }

    static func gitCommit(manifestPath: String) -> String {
        guard let root = repoRoot(manifestPath: manifestPath) else { return "unknown" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root, "rev-parse", "HEAD"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return "unknown"
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "unknown" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static func appleBackend() -> String {
        if #available(macOS 26, *) {
            return "speechAnalyzer"
        }
        return "sfSpeech"
    }

    static func runID(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return formatter.string(from: now) + "-" + suffix
    }

    static func errorMessage(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? String(describing: type(of: error)) : message
    }
}

final class QuotaReservationSession {
    let runID: String
    let month: String
    let engine: String
    private let reservationURL: URL
    private let lockURL: URL
    private var runLockFD: Int32
    private let initialReservedSeconds: Double
    private var remainingSeconds: Double
    private let createdAtEpoch: Double
    private var isReleased = false

    init(
        runID: String,
        month: String,
        engine: String,
        reservationURL: URL,
        lockURL: URL,
        runLockFD: Int32,
        reservedSeconds: Double,
        createdAtEpoch: Double
    ) {
        self.runID = runID
        self.month = month
        self.engine = engine
        self.reservationURL = reservationURL
        self.lockURL = lockURL
        self.runLockFD = runLockFD
        self.initialReservedSeconds = reservedSeconds
        self.remainingSeconds = reservedSeconds
        self.createdAtEpoch = createdAtEpoch
    }

    deinit {
        if runLockFD >= 0 {
            close(runLockFD)
            runLockFD = -1
        }
    }

    func recordClip(plannedClipSeconds: Double, actualConsumedSeconds: Double) throws {
        guard !isReleased else { return }
        try BenchIO.withQuotaLock {
            if actualConsumedSeconds > 0 {
                var ledger = try BenchIO.loadLedger()
                var monthEntries = ledger.months[month] ?? [:]
                monthEntries[engine] = (monthEntries[engine] ?? 0.0) + actualConsumedSeconds
                ledger.months[month] = monthEntries
                try BenchIO.saveLedger(ledger)
            }
            remainingSeconds = max(0.0, remainingSeconds - max(0.0, plannedClipSeconds))
            let updated = QuotaReservation(
                schema_version: 1,
                run_id: runID,
                month: month,
                engine: engine,
                pid: ProcessInfo.processInfo.processIdentifier,
                reserved_seconds: initialReservedSeconds,
                remaining_seconds: remainingSeconds,
                created_at_epoch: createdAtEpoch
            )
            try BenchIO.writeReservation(updated, to: reservationURL)
        }
    }

    func release() throws {
        guard !isReleased else { return }
        isReleased = true
        defer {
            if runLockFD >= 0 {
                close(runLockFD)
                runLockFD = -1
            }
        }
        try BenchIO.withQuotaLock {
            try? FileManager.default.removeItem(at: reservationURL)
            try? FileManager.default.removeItem(at: lockURL)
        }
    }

    func releaseBestEffort() {
        try? release()
    }
}
