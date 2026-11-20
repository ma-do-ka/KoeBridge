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
    private func generationNames(in dir: Int32) throws -> [String] {
        let fd = dup(dir)
        guard fd >= 0 else { throw posixError() }
        guard let stream = fdopendir(fd) else {
            let error = posixError()
            close(fd)
            throw error
        }
        defer { closedir(stream) }
        let base = fileURL.lastPathComponent
        let prefix = base + "."
        var names = [base]
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posixError() }
                return names
            }
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(validatingCString: bytes.bindMemory(to: CChar.self).baseAddress!)
            }
            guard let name, name.hasPrefix(prefix) else { continue }
            let suffix = name.dropFirst(prefix.count)
            if !suffix.isEmpty && suffix.utf8.allSatisfy({ (48...57).contains($0) }) { names.append(name) }
        }
    }

    public func append(_ event: String, at timestamp: Date = Date()) throws {
        try appendBatch([event], at: timestamp)
    }

    /// Flush bounded evidence after input has resolved. Formatting, file opens
    /// and permission updates happen once per batch, outside the receipt poll.
    public func appendBatch(_ events: [String], at timestamp: Date = Date()) throws {
        try appendTimedBatch(events.map { (event: $0, at: timestamp) })
    }

    public func appendTimedBatch(_ events: [(event: String, at: Date)]) throws {
        let safeEvents = events.compactMap { item in
            DiagnosticLogPolicy.sanitizedEvent(item.event).map { (event: $0, at: item.at) }
        }
        guard !safeEvents.isEmpty else { return }
        let formatter = ISO8601DateFormatter()
        let cap = maximumFileBytes
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let dir = open(fileURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw posixError() }
        defer { close(dir) }
        let base = fileURL.lastPathComponent
        let names = try generationNames(in: dir)
        // Check every candidate before changing permissions or pruning any file.
        for name in names { _ = try regularInfo(dir, name) }
        for name in names {
            guard let info = try regularInfo(dir, name) else { continue }
            let suffix = String(name.dropFirst(base.count + 1))
            let number = Int(suffix)
            let retained = name == base || number.map { $0 > 0 && $0 < maximumGenerations && String($0) == suffix } == true
            if !retained || info.st_size > cap {
                guard unlinkat(dir, name, 0) == 0 else { throw posixError() }
            } else {
                let file = try openRegular(dir, name, flags: O_RDONLY)
                try file.close()
            }
        }
        var current = Int(try regularInfo(dir, base)?.st_size ?? 0)
        var writer: FileHandle?
        defer { try? writer?.close() }
        for safe in safeEvents {
            let bytes = Data("\(formatter.string(from: safe.at)) \(safe.event)\n".utf8)
            guard bytes.count <= cap else { continue }
            if DiagnosticLogPolicy.needsRotation(existingBytes: current, incomingBytes: bytes.count,
                                                maximumFileBytes: cap) {
                try writer?.close()
                writer = nil
                try rotate(dir, firstRecord: bytes)
                current = bytes.count
            } else {
                if writer == nil { writer = try openRegular(dir, base, flags: O_WRONLY | O_APPEND | O_CREAT) }
                try writer?.write(contentsOf: bytes)
                current += bytes.count
            }
        }
    }

    private func rotate(_ dir: Int32, firstRecord: Data) throws {
        let temporary = ".KoeBridge-\(UUID().uuidString).tmp"
        let staged = try openRegular(dir, temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { _ = unlinkat(dir, temporary, 0) }
        try staged.write(contentsOf: firstRecord)
        try staged.synchronize()
        try staged.close()

        for generation in (1..<maximumGenerations).reversed() {
            let source = generationURL(generation - 1).lastPathComponent
            let destination = generationURL(generation).lastPathComponent
            let existing = try regularInfo(dir, destination)
            if try regularInfo(dir, source) != nil {
                guard renameat(dir, source, dir, destination) == 0 else { throw posixError() }
            } else if existing != nil {
                guard unlinkat(dir, destination, 0) == 0 else { throw posixError() }
            }
        }
        _ = try regularInfo(dir, fileURL.lastPathComponent)
        guard renameat(dir, temporary, dir, fileURL.lastPathComponent) == 0 else { throw posixError() }
    }

    private func regularInfo(_ dir: Int32, _ name: String, requireSingleLink: Bool = true) throws -> stat? {
        var info = stat()
        if fstatat(dir, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        guard info.st_mode & S_IFMT == S_IFREG, (!requireSingleLink || info.st_nlink == 1) else { throw StoreError.invalidFile }
        return info
    }

    private func openRegular(_ dir: Int32, _ name: String, flags: Int32) throws -> FileHandle {
        let fd = openat(dir, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw StoreError.invalidFile }
        guard fchmod(fd, 0o600) == 0 else { throw posixError() }
        return file
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    public func deleteAll() throws {
        let dir = open(fileURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else {
            if errno == ENOENT { return }
            throw posixError()
        }
        defer { close(dir) }
        for name in try generationNames(in: dir) {
            guard try regularInfo(dir, name, requireSingleLink: false) != nil else { continue }
            if unlinkat(dir, name, 0) != 0 && errno != ENOENT { throw posixError() }
        }
    }

    public func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    public enum StoreError: Error {
        case invalidFile, createFailed
    }
}
