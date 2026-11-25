import Foundation
import CryptoKit
import KoeBridgeCore

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
