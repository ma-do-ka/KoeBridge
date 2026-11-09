import Foundation

/// A bounded, private diagnostics store. Access must be serialized by its caller.
/// Only opt-in diagnostic events should be passed here, never transcribed text.
public struct DiagnosticFileStore {
    public let fileURL: URL
    public var rotatedURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".1")
    }

    public let maximumFileBytes: Int
    public let maximumGenerations: Int

    public init(fileURL: URL,
                maximumFileBytes: Int = DiagnosticLogPolicy.maximumFileBytes,
                maximumGenerations: Int = DiagnosticLogPolicy.maximumFiles) {
        precondition(maximumFileBytes > 0 && maximumGenerations > 0)
        self.fileURL = fileURL
        self.maximumFileBytes = maximumFileBytes
        self.maximumGenerations = maximumGenerations
    }

    private func generationURL(_ generation: Int) -> URL {
        generation == 0 ? fileURL : fileURL.appendingPathExtension(String(generation))
    }

    /// Include older generations left by a store with a larger retention limit.
    private func allGenerationURLs() throws -> [URL] {
        let directory = fileURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [fileURL] }
        let prefix = fileURL.lastPathComponent + "."
        let older = try FileManager.default.contentsOfDirectory(at: directory,
                                                              includingPropertiesForKeys: nil).filter {
            let name = $0.lastPathComponent
            guard name.hasPrefix(prefix) else { return false }
            let suffix = name.dropFirst(prefix.count)
            return !suffix.isEmpty && suffix.allSatisfy { $0 >= "0" && $0 <= "9" }
        }
        return [fileURL] + older
    }

    public func append(_ event: String, at timestamp: Date = Date()) throws {
        try appendBatch([event], at: timestamp)
    }

    /// Flush bounded evidence after input has resolved. Formatting, file opens
    /// and permission updates happen once per batch, outside the receipt poll.
    public func appendBatch(_ events: [String], at timestamp: Date = Date()) throws {
        let safeEvents = events.compactMap(DiagnosticLogPolicy.sanitizedEvent)
        guard !safeEvents.isEmpty else { return }
        let date = ISO8601DateFormatter().string(from: timestamp)
        let cap = maximumFileBytes
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        // Never follow a user-controlled symlink into an unrelated file.
        let generations = try allGenerationURLs()
        for url in generations {
            try validateRegularFileIfPresent(url)
        }
        for url in generations where fm.fileExists(atPath: url.path) {
            // Apply the advertised limit to every generation, including an
            // oversized old file left by another version or external edits.
            if fileSize(url) > cap {
                try fm.removeItem(at: url)
            } else {
                try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                     ofItemAtPath: url.path)
            }
        }
        var current = fileSize(fileURL)
        var writer: FileHandle?
        defer { try? writer?.close() }
        for safe in safeEvents {
            let bytes = Data("\(date) \(safe)\n".utf8)
            guard bytes.count <= cap else { continue }
            if DiagnosticLogPolicy.needsRotation(existingBytes: current, incomingBytes: bytes.count,
                                                maximumFileBytes: cap) {
                try writer?.close()
                writer = nil
                let oldest = generationURL(maximumGenerations - 1)
                if fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
                if maximumGenerations > 1 {
                    for generation in stride(from: maximumGenerations - 2, through: 0, by: -1) {
                        let source = generationURL(generation)
                        if fm.fileExists(atPath: source.path) {
                            try fm.moveItem(at: source, to: generationURL(generation + 1))
                        }
                    }
                }
                current = 0
            }
            if writer == nil {
                if !fm.fileExists(atPath: fileURL.path) {
                    guard fm.createFile(atPath: fileURL.path, contents: nil,
                                        attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
                        throw StoreError.createFailed
                    }
                }
                writer = try FileHandle(forWritingTo: fileURL)
                _ = try writer?.seekToEnd()
            }
            try writer?.write(contentsOf: bytes)
            current += bytes.count
        }
    }

    public func deleteAll() throws {
        let fm = FileManager.default
        for url in try allGenerationURLs() {
            if fm.fileExists(atPath: url.path) || (try? isSymbolicLink(url)) == true {
                try fm.removeItem(at: url)
            }
        }
    }

    public func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func isSymbolicLink(_ url: URL) throws -> Bool {
        // `attributesOfItem` follows the symlink; use `lstat` via URL values
        // carefully, without logging anything from the linked destination.
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    private func validateRegularFileIfPresent(_ url: URL) throws {
        if try isSymbolicLink(url) { throw StoreError.invalidFile }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw StoreError.invalidFile
        }
    }

    public enum StoreError: Error {
        case invalidFile, createFailed
    }
}
