import Foundation

/// A bounded, private diagnostics store. Access must be serialized by its caller.
/// Only opt-in diagnostic events should be passed here, never transcribed text.
public struct DiagnosticFileStore {
    public let fileURL: URL
    public var rotatedURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".1")
    }

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func append(_ event: String, at timestamp: Date = Date()) throws {
        guard let safe = DiagnosticLogPolicy.sanitizedEvent(event) else { return }
        let line = "\(ISO8601DateFormatter().string(from: timestamp)) \(safe)\n"
        let bytes = Data(line.utf8)
        let cap = DiagnosticLogPolicy.maximumFileBytes
        guard bytes.count <= cap else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        // Never follow a user-controlled symlink into an unrelated file.
        if try isSymbolicLink(fileURL) {
            throw StoreError.invalidFile
        }
        if try isSymbolicLink(rotatedURL) {
            throw StoreError.invalidFile
        }
        let current = fileSize(fileURL)
        if current > cap {
            // Prior versions and external file modifications may exceed the
            // cap. Preserve a normal-size rotated generation, discard an
            // oversized diagnostics file rather than keeping it forever.
            try fm.removeItem(at: fileURL)
        } else if DiagnosticLogPolicy.needsRotation(existingBytes: current,
                                                     incomingBytes: bytes.count) {
            if fm.fileExists(atPath: rotatedURL.path) {
                try fm.removeItem(at: rotatedURL)
            }
            try fm.moveItem(at: fileURL, to: rotatedURL)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            guard fm.createFile(atPath: fileURL.path, contents: nil,
                                attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
                throw StoreError.createFailed
            }
        }
        let writer = try FileHandle(forWritingTo: fileURL)
        defer { try? writer.close() }
        _ = try writer.seekToEnd()
        try writer.write(contentsOf: bytes)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                             ofItemAtPath: fileURL.path)
    }

    public func deleteAll() throws {
        let fm = FileManager.default
        for url in [fileURL, rotatedURL] {
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

    public enum StoreError: Error {
        case invalidFile, createFailed
    }
}
