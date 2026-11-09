#if os(macOS)
import AudioToolbox
import AVFoundation
import Foundation
import KoeBridgeCore

actor DeveloperDiagnosticsStore {
    static let shared = DeveloperDiagnosticsStore()

    static var rootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KoeBridge", isDirectory: true)
            .appendingPathComponent("DeveloperDiagnostics", isDirectory: true)
    }

    private let fm = FileManager.default
    private init() {}

    func prepare(token: DeveloperDiagnosticsToken) throws {
        guard DeveloperDiagnostics.allows(token) else { return }
        try ensureRoot()
        let temporary = Self.rootURL.appendingPathComponent(".tmp", isDirectory: true)
        if fm.fileExists(atPath: temporary.path) {
            try? fm.removeItem(at: temporary)
        }
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
                       maximumBytes: DeveloperDiagnosticsPolicy.maximumTimelineBytes, resetWhenFull: false)
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
            let primary = primaryText.map { DeveloperDiagnosticsPolicy.cappedText($0) }
            let final = finalText.map { DeveloperDiagnosticsPolicy.cappedText($0) }
            let partial = partialText.map { DeveloperDiagnosticsPolicy.cappedText($0) }
            let alternative = alternativeText.map { DeveloperDiagnosticsPolicy.cappedText($0) }
            let object: [String: Any] = [
                "take_id": takeID.uuidString.lowercased(),
                "recorded_at": ISO8601DateFormatter().string(from: recordedAt),
                "engine": engine,
                "primary_text": primary?.text as Any? ?? NSNull(),
                "primary_text_truncated": primary?.truncated ?? false,
                "final_text": final?.text as Any? ?? NSNull(),
                "final_text_truncated": final?.truncated ?? false,
                "partial_text": partial?.text as Any? ?? NSNull(),
                "partial_text_truncated": partial?.truncated ?? false,
                "alternative_text": alternative?.text as Any? ?? NSNull(),
                "alternative_text_truncated": alternative?.truncated ?? false,
                "audio_source": "pcm_submitted_to_recognizer_prefix",
                "audio_pcm_seconds": Double(pcm16LE.count) / Double(DeveloperDiagnosticsPolicy.pcmBytesPerSecond),
                "audio_truncated": audioTruncated
            ]
            try writeJSONObject(object, to: directory.appendingPathComponent("recognition.json"),
                                maximumBytes: DeveloperDiagnosticsPolicy.maximumRecognitionBytes)

            if !pcm16LE.isEmpty {
                let temporaryDirectory = Self.rootURL.appendingPathComponent(".tmp", isDirectory: true)
                try fm.createDirectory(
                    at: temporaryDirectory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                                     ofItemAtPath: temporaryDirectory.path)
                let temporary = temporaryDirectory
                    .appendingPathComponent("audio-\(UUID().uuidString).m4a")
                try await Task.detached(priority: .utility) {
                    try Self.encodeAAC(pcm16LE, to: temporary)
                }.value
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard DeveloperDiagnostics.allows(token) else { return }
                let destination = directory.appendingPathComponent("audio.m4a")
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                let attributes = try fm.attributesOfItem(atPath: temporary.path)
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                guard size > 0, size <= DeveloperDiagnosticsPolicy.maximumEncodedAudioBytes else {
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
                        transportText: String?, observedDelta: String?,
                        token: DeveloperDiagnosticsToken) {
        guard DeveloperDiagnostics.allows(token) else { return }
        do {
            let directory = try sessionDirectory(takeID)
            let transport = transportText.map { DeveloperDiagnosticsPolicy.cappedText($0) }
            let detailCapped = DeveloperDiagnosticsPolicy.cappedText(detail)
            let observed = observedDelta.map { DeveloperDiagnosticsPolicy.cappedText($0) }
            let object: [String: Any] = [
                "take_id": takeID.uuidString.lowercased(),
                "at": ISO8601DateFormatter().string(from: Date()),
                "delivery": delivery,
                "detail": detailCapped.text,
                "detail_truncated": detailCapped.truncated,
                "transport_text": transport?.text as Any? ?? NSNull(),
                "transport_text_truncated": transport?.truncated ?? false,
                "observed_change": observed?.text as Any? ?? NSNull(),
                "observed_change_truncated": observed?.truncated ?? false
            ]
            try writeJSONObject(object, to: directory.appendingPathComponent("delivery.json"),
                                maximumBytes: DeveloperDiagnosticsPolicy.maximumDeliveryBytes)
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
        try ensurePrivateDirectory(Self.rootURL)
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw StoreError.unsafePath
        }
        if fm.fileExists(atPath: url.path) {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw StoreError.unsafePath
            }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: 0o700)])
        }
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                             ofItemAtPath: url.path)
    }

    private func validateRegularFileIfPresent(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw StoreError.unsafePath
        }
        guard fm.fileExists(atPath: url.path) else { return }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw StoreError.unsafePath
        }
    }

    private func sessionDirectory(_ takeID: UUID) throws -> URL {
        try ensureRoot()
        let sessions = Self.rootURL.appendingPathComponent("sessions", isDirectory: true)
        try ensurePrivateDirectory(sessions)
        let directory = sessions.appendingPathComponent(takeID.uuidString.lowercased(), isDirectory: true)
        try ensurePrivateDirectory(directory)
        return directory
    }

    private func append(line: Data, to url: URL, maximumBytes: Int,
                        resetWhenFull: Bool) throws {
        guard line.count <= maximumBytes else { return }
        try validateRegularFileIfPresent(url)
        let current = fileSize(url)
        let (nextSize, overflowed) = current.addingReportingOverflow(line.count)
        if overflowed || nextSize > maximumBytes {
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
        try validateRegularFileIfPresent(url)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= maximumBytes else { return }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                             ofItemAtPath: url.path)
    }

    private func enforceSessionLimit(_ directory: URL) throws {
        guard directorySize(directory) > DeveloperDiagnosticsPolicy.maximumSessionBytes else { return }
        // Preserve the comparison summary first. Remove the largest optional
        // evidence in a deterministic order if unexpected overhead/corruption
        // exceeds the advertised per-session cap.
        for name in ["audio.m4a", "input-trace.log", "timeline.jsonl"] {
            let url = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
            if directorySize(directory) <= DeveloperDiagnosticsPolicy.maximumSessionBytes { return }
        }
        // Never retain a session larger than the hard cap.
        try fm.removeItem(at: directory)
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
            let size = max(0, values.fileSize ?? 0)
            let (next, overflowed) = total.addingReportingOverflow(size)
            total = overflowed ? Int.max : next
        }
        return total
    }

    private nonisolated static func jsonLine(_ fields: [String: String]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        var line = data
        line.append(0x0A)
        return line
    }

    enum StoreError: Error {
        case unsafePath
    }

    private nonisolated static func encodeAAC(_ pcm16LE: Data, to temporary: URL) throws {
        guard !pcm16LE.isEmpty, pcm16LE.count.isMultiple(of: 2) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path) else {
            throw CocoaError(.fileNoSuchFile)
        }
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
    }
}
#endif
