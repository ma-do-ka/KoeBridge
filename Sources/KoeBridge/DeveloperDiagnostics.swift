#if os(macOS)
import AppKit
import AudioToolbox
import AVFoundation
import Combine
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
                               transportText: String?) {
        guard let token else { return }
        Task {
            await DeveloperDiagnosticsStore.shared.recordDelivery(
                takeID: takeID, delivery: delivery, detail: detail,
                transportText: transportText, token: token
            )
        }
    }
}

actor DeveloperDiagnosticsStore {
    static let shared = DeveloperDiagnosticsStore()

    static var rootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KoeBridge", isDirectory: true)
            .appendingPathComponent("DeveloperDiagnostics", isDirectory: true)
    }

    private let fm = FileManager.default
    private let encoder = JSONEncoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }

    func prepare(token: DeveloperDiagnosticsToken) throws {
        guard DeveloperDiagnostics.allows(token) else { return }
        try ensureRoot()
        try trimRetention()
    }

    func deleteAll() throws {
        let root = Self.rootURL
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    func appendGlobal(_ event: String, token: DeveloperDiagnosticsToken) {
        guard DeveloperDiagnostics.allows(token) else { return }
        do {
            try ensureRoot()
            let line = Self.jsonLine([
                "at": ISO8601DateFormatter().string(from: Date()),
                "event": event
            ])
            try append(line: line, to: Self.rootURL.appendingPathComponent("global.jsonl"),
                       maximumBytes: DeveloperDiagnosticsPolicy.maximumGlobalLogBytes,
                       resetWhenFull: true)
        } catch {
            // Development diagnostics must never interrupt dictation.
        }
    }

    func recordEvent(takeID: UUID, stage: String, fields: [String: String],
                     token: DeveloperDiagnosticsToken) {
        guard DeveloperDiagnostics.allows(token) else { return }
        do {
            let directory = try sessionDirectory(takeID)
            var payload = fields
            payload["at"] = ISO8601DateFormatter().string(from: Date())
            payload["stage"] = stage
            payload["take_id"] = takeID.uuidString.lowercased()
            try append(line: Self.jsonLine(payload),
                       to: directory.appendingPathComponent("timeline.jsonl"),
                       maximumBytes: 128 * 1024, resetWhenFull: false)
            try trimRetention()
        } catch {
            // Diagnostics are best-effort and isolated from user input.
        }
    }

    func writeInputTrace(takeID: UUID, lines: [String], token: DeveloperDiagnosticsToken) {
        guard DeveloperDiagnostics.allows(token), !lines.isEmpty else { return }
        do {
            let directory = try sessionDirectory(takeID)
            let url = directory.appendingPathComponent("input-trace.log")
            for line in lines {
                guard DeveloperDiagnostics.allows(token) else { return }
                try append(line: Data((line + "\n").utf8), to: url,
                           maximumBytes: DeveloperDiagnosticsPolicy.maximumInputTraceBytes,
                           resetWhenFull: false)
            }
            try trimRetention()
        } catch {
            // Never alter input delivery because a developer file failed.
        }
    }

    func recordRecognition(takeID: UUID, recordedAt: Date, engine: String,
                           primaryText: String?, finalText: String?, partialText: String?,
                           alternativeText: String?, pcm16LE: Data, audioTruncated: Bool,
                           token: DeveloperDiagnosticsToken) async {
        guard DeveloperDiagnostics.allows(token) else { return }
        do {
            let directory = try sessionDirectory(takeID)
            let primary = primaryText.map(DeveloperDiagnosticsPolicy.cappedText)
            let final = finalText.map(DeveloperDiagnosticsPolicy.cappedText)
            let partial = partialText.map(DeveloperDiagnosticsPolicy.cappedText)
            let alternative = alternativeText.map(DeveloperDiagnosticsPolicy.cappedText)
            let object: [String: Any] = [
                "take_id": takeID.uuidString.lowercased(),
                "recorded_at": ISO8601DateFormatter().string(from: recordedAt),
                "engine": engine,
                "primary_text": primary?.text ?? NSNull(),
                "primary_text_truncated": primary?.truncated ?? false,
                "final_text": final?.text ?? NSNull(),
                "final_text_truncated": final?.truncated ?? false,
                "partial_text": partial?.text ?? NSNull(),
                "partial_text_truncated": partial?.truncated ?? false,
                "alternative_text": alternative?.text ?? NSNull(),
                "alternative_text_truncated": alternative?.truncated ?? false,
                "audio_source": "pcm_submitted_to_recognizer_prefix",
                "audio_pcm_seconds": Double(pcm16LE.count) / Double(DeveloperDiagnosticsPolicy.pcmBytesPerSecond),
                "audio_truncated": audioTruncated
            ]
            try writeJSONObject(object, to: directory.appendingPathComponent("recognition.json"),
                                maximumBytes: 192 * 1024)

            if !pcm16LE.isEmpty {
                let temporary = try await Task.detached(priority: .utility) {
                    try Self.encodeAAC(pcm16LE)
                }.value
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard DeveloperDiagnostics.allows(token) else { return }
                let destination = directory.appendingPathComponent("audio.m4a")
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                let size = (try fm.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size > 0, size <= 192 * 1024 else {
                    recordEvent(takeID: takeID, stage: "audio_skipped",
                                fields: ["reason": "encoded_size_out_of_bounds", "bytes": "\(size)"],
                                token: token)
                    return
                }
                try fm.moveItem(at: temporary, to: destination)
                try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                     ofItemAtPath: destination.path)
            }
            try enforceSessionLimit(directory)
            try trimRetention()
        } catch {
            recordEvent(takeID: takeID, stage: "recognition_diagnostics_failed",
                        fields: ["error_domain": (error as NSError).domain,
                                 "error_code": "\((error as NSError).code)"],
                        token: token)
        }
    }

    func recordDelivery(takeID: UUID, delivery: String, detail: String,
                        transportText: String?, token: DeveloperDiagnosticsToken) {
        guard DeveloperDiagnostics.allows(token) else { return }
        do {
            let directory = try sessionDirectory(takeID)
            let transport = transportText.map(DeveloperDiagnosticsPolicy.cappedText)
            let detailCapped = DeveloperDiagnosticsPolicy.cappedText(detail)
            let object: [String: Any] = [
                "take_id": takeID.uuidString.lowercased(),
                "at": ISO8601DateFormatter().string(from: Date()),
                "delivery": delivery,
                "detail": detailCapped.text,
                "detail_truncated": detailCapped.truncated,
                "transport_text": transport?.text ?? NSNull(),
                "transport_text_truncated": transport?.truncated ?? false
            ]
            try writeJSONObject(object, to: directory.appendingPathComponent("delivery.json"),
                                maximumBytes: 96 * 1024)
            try enforceSessionLimit(directory)
            try trimRetention()
        } catch {
            // Never affect the actual delivery result.
        }
    }

    func prepareForReveal(token: DeveloperDiagnosticsToken?) throws -> URL? {
        guard let token, DeveloperDiagnostics.allows(token) else {
            return fm.fileExists(atPath: Self.rootURL.path) ? Self.rootURL : nil
        }
        try ensureRoot()
        return Self.rootURL
    }

    private func ensureRoot() throws {
        let root = Self.rootURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                             ofItemAtPath: root.path)
    }

    private func sessionDirectory(_ takeID: UUID) throws -> URL {
        try ensureRoot()
        let sessions = Self.rootURL.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                             ofItemAtPath: sessions.path)
        let directory = sessions.appendingPathComponent(takeID.uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                             ofItemAtPath: directory.path)
        return directory
    }

    private func append(line: Data, to url: URL, maximumBytes: Int,
                        resetWhenFull: Bool) throws {
        guard line.count <= maximumBytes else { return }
        let current = fileSize(url)
        if current + line.count > maximumBytes {
            guard resetWhenFull else { return }
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil,
                                attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                             ofItemAtPath: url.path)
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL,
                                 maximumBytes: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= maximumBytes else { return }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                             ofItemAtPath: url.path)
    }

    private func enforceSessionLimit(_ directory: URL) throws {
        guard directorySize(directory) <= DeveloperDiagnosticsPolicy.maximumSessionBytes else {
            // Audio is the only optional large artifact. Keep text/timelines if
            // an unexpected encoder/container overhead exceeds the session cap.
            let audio = directory.appendingPathComponent("audio.m4a")
            if fm.fileExists(atPath: audio.path) { try fm.removeItem(at: audio) }
            return
        }
    }

    private func trimRetention() throws {
        let sessions = Self.rootURL.appendingPathComponent("sessions", isDirectory: true)
        guard let urls = try? fm.contentsOfDirectory(
            at: sessions, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var directories = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        directories.sort {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        while directories.count > DeveloperDiagnosticsPolicy.maximumSessions {
            let oldest = directories.removeFirst()
            try? fm.removeItem(at: oldest)
        }
        var total = directorySize(Self.rootURL)
        while total > DeveloperDiagnosticsPolicy.maximumTotalBytes, !directories.isEmpty {
            let oldest = directories.removeFirst()
            try? fm.removeItem(at: oldest)
            total = directorySize(Self.rootURL)
        }
    }

    private func fileSize(_ url: URL) -> Int {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let number = attrs[.size] as? NSNumber else { return 0 }
        return max(0, number.intValue)
    }

    private func directorySize(_ directory: URL) -> Int {
        guard let enumerator = fm.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total = min(Int.max, total + max(0, values.fileSize ?? 0))
        }
        return total
    }

    private nonisolated static func jsonLine(_ fields: [String: String]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        var line = data
        line.append(0x0A)
        return line
    }

    private nonisolated static func encodeAAC(_ pcm16LE: Data) throws -> URL {
        guard !pcm16LE.isEmpty, pcm16LE.count.isMultiple(of: 2) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("koebridge-dev-\(UUID().uuidString).m4a")
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: 16_000, channels: 1,
                                              interleaved: true) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: DeveloperDiagnosticsPolicy.audioBitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue
        ]
        let output = try AVAudioFile(forWriting: temporary, settings: settings,
                                     commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(pcm16LE.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
              let destination = buffer.int16ChannelData?.pointee else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        pcm16LE.withUnsafeBytes { raw in
            if let source = raw.baseAddress {
                memcpy(destination, source, pcm16LE.count)
            }
        }
        try output.write(from: buffer)
        return temporary
    }
}

@MainActor final class DeveloperDiagnosticsController: ObservableObject {
    static let shared = DeveloperDiagnosticsController()

    @Published private(set) var enabled: Bool
    @Published private(set) var statusMessage = ""

    private init() {
        enabled = DeveloperDiagnostics.isEnabled
    }

    func enable() {
        let token = DeveloperDiagnostics.enablePreference()
        enabled = true
        statusMessage = "開発用診断を有効にしました。音声サンプルと認識文字列をこのMac内だけに保存します。"
        Task {
            do {
                try await DeveloperDiagnosticsStore.shared.prepare(token: token)
            } catch {
                await MainActor.run {
                    self.statusMessage = "開発用診断フォルダーを準備できません：\(error.localizedDescription)"
                }
            }
        }
    }

    func disableAndDelete() {
        DeveloperDiagnostics.disablePreference()
        enabled = false
        statusMessage = "開発用診断を停止し、保存データを削除しています…"
        Task {
            do {
                try await DeveloperDiagnosticsStore.shared.deleteAll()
                await MainActor.run {
                    self.statusMessage = "開発用診断を停止し、保存データを削除しました。"
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "開発用診断は停止しましたが、保存データを削除できません：\(error.localizedDescription)"
                }
            }
        }
    }

    func deleteData() {
        _ = DeveloperDiagnostics.rotateEpochKeepingPreference()
        statusMessage = "開発用診断データを削除しています…"
        Task {
            do {
                try await DeveloperDiagnosticsStore.shared.deleteAll()
                if let token = DeveloperDiagnostics.token {
                    try await DeveloperDiagnosticsStore.shared.prepare(token: token)
                }
                await MainActor.run {
                    self.statusMessage = "開発用診断データを削除しました。"
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "開発用診断データを削除できません：\(error.localizedDescription)"
                }
            }
        }
    }

    func revealInFinder() {
        let token = DeveloperDiagnostics.token
        Task {
            do {
                let url = try await DeveloperDiagnosticsStore.shared.prepareForReveal(token: token)
                await MainActor.run {
                    guard let url else {
                        self.statusMessage = "開発用診断データはまだありません。"
                        return
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "開発用診断フォルダーを開けません：\(error.localizedDescription)"
                }
            }
        }
    }
}
#endif
