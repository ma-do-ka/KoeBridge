import Foundation
import KoeBridgeCore

struct DiagnosticLogPolicyTests {
    func disabledByDefaultEvenWhenUnset() {
        check(!DiagnosticLogPolicy.isEnabled(storedValue: nil))
        check(!DiagnosticLogPolicy.isEnabled(storedValue: false))
        check(DiagnosticLogPolicy.isEnabled(storedValue: true))
    }
    func normalEventCannotBreakIntoTwoLogLines() {
        check(DiagnosticLogPolicy.sanitizedEvent("ready\nstate=ok\rmore") == "ready state=ok more")
        check(DiagnosticLogPolicy.sanitizedEvent("") == nil)
        check(DiagnosticLogPolicy.sanitizedEvent("secret\0value") == nil)
        check(DiagnosticLogPolicy.sanitizedEvent(String(repeating: "x", count: 321)) == nil)
        check(DiagnosticLogPolicy.sanitizedEvent(String(repeating: "x", count: 320)) != nil)
    }
    func boundedRotationMath() {
        let max = DiagnosticLogPolicy.maximumFileBytes
        check(max == 192 * 1024)
        check(DiagnosticLogPolicy.maximumFiles == 2)
        check(!DiagnosticLogPolicy.needsRotation(existingBytes: 0, incomingBytes: 400))
        check(!DiagnosticLogPolicy.needsRotation(existingBytes: max - 50, incomingBytes: 50))
        check(DiagnosticLogPolicy.needsRotation(existingBytes: max - 50, incomingBytes: 51))
        check(DiagnosticLogPolicy.needsRotation(existingBytes: max + 10, incomingBytes: 20))
    }
    func systemInterruptionArchiveValueRoundTrips() throws {
        let original = TranscriptRecord(engine: "Gemini", text: "テスト",
                                        isPartial: false, delivery: .blockedFocus)
        let restored = try JSONDecoder().decode(TranscriptRecord.self, from: JSONEncoder().encode(original))
        check(restored.delivery == .blockedFocus)
        check(restored.text == "テスト")
        check(!restored.delivery.label.isEmpty)
    }
    func onDiskRotationAndDeletionAreBounded() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-diag-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let log = directory.appendingPathComponent("KoeBridge.log")
        let store = DiagnosticFileStore(fileURL: log)
        for i in 0..<1_300 {
            try store.append("case=\(i); code=" + String(repeating: "x", count: 250))
        }
        let current = store.fileSize(log)
        let older = store.fileSize(store.rotatedURL)
        check(current > 0 && current <= DiagnosticLogPolicy.maximumFileBytes)
        check(older > 0 && older <= DiagnosticLogPolicy.maximumFileBytes)
        check(current + older <= DiagnosticLogPolicy.maximumFileBytes * DiagnosticLogPolicy.maximumFiles)
        let attributes = try fm.attributesOfItem(atPath: log.path)
        let perms = (attributes[.posixPermissions] as? NSNumber)?.intValue
        check(perms == 0o600)
        try store.deleteAll()
        check(!fm.fileExists(atPath: log.path))
        check(!fm.fileExists(atPath: store.rotatedURL.path))
    }
    func aSymlinkMustNotBeOverwritten() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("koebridge-link-\(UUID())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let safeTarget = dir.appendingPathComponent("original.txt")
        try Data("stay unchanged".utf8).write(to: safeTarget)
        let log = dir.appendingPathComponent("KoeBridge.log")
        try fm.createSymbolicLink(at: log, withDestinationURL: safeTarget)
        let store = DiagnosticFileStore(fileURL: log)
        checkThrows(Error.self) { try store.append("no write") }
        let original = try String(contentsOf: safeTarget, encoding: .utf8)
        check(original == "stay unchanged")
    }

    func batchedEventsRotateInOrderAndKeepBothFilesPrivate() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-diag-batch-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let store = DiagnosticFileStore(fileURL: directory.appendingPathComponent("KoeBridge.log"))
        let events = (0..<1_800).map { "case=\($0) " + String(repeating: "x", count: 230) }
        try store.appendBatch(events, at: Date(timeIntervalSince1970: 0))
        for url in [store.fileURL, store.rotatedURL] {
            check(store.fileSize(url) > 0)
            check(store.fileSize(url) <= DiagnosticLogPolicy.maximumFileBytes)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let older = try String(contentsOf: store.rotatedURL, encoding: .utf8)
        let current = try String(contentsOf: store.fileURL, encoding: .utf8)
        let lines = (older + current).split(separator: "\n")
        let ids = lines.compactMap { line -> Int? in
            line.split(separator: " ").dropFirst().first.flatMap { Int($0.dropFirst(5)) }
        }
        let first = try require(ids.first)
        check(first > 0)
        check(ids.count == lines.count)
        check(ids == Array(first..<1_800))
        let names = try fm.contentsOfDirectory(atPath: directory.path)
        check(Set(names) == Set(["KoeBridge.log", "KoeBridge.log.1"]))
    }

    func oversizedRotatedFileIsRemovedBeforeTheNextNormalRotation() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-diag-limit-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let store = DiagnosticFileStore(fileURL: directory.appendingPathComponent("KoeBridge.log"))
        try store.append("event=before")
        let oversized = Data(repeating: 0x78, count: DiagnosticLogPolicy.maximumFileBytes + 1)
        try oversized.write(to: store.rotatedURL)
        try store.appendBatch(["event=second", "event=third"])
        check(!fm.fileExists(atPath: store.rotatedURL.path))
        let retained = try String(contentsOf: store.fileURL, encoding: .utf8)
        check(retained.contains("event=before"))
        check(retained.contains("event=second"))
        check(retained.contains("event=third"))
        for url in [store.fileURL, store.rotatedURL] { try oversized.write(to: url) }
        try store.appendBatch(["event=fresh"])
        check(store.fileSize(store.fileURL) <= DiagnosticLogPolicy.maximumFileBytes)
        check(store.fileSize(store.rotatedURL) <= DiagnosticLogPolicy.maximumFileBytes)
        let fresh = try String(contentsOf: store.fileURL, encoding: .utf8)
        check(fresh.contains("event=fresh"))
        check(fresh.split(separator: "\n").count == 1)
    }

    func invalidBatchDoesNotCreateFilesOrAcceptANonregularDestination() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-diag-empty-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let store = DiagnosticFileStore(fileURL: directory.appendingPathComponent("KoeBridge.log"))
        try store.appendBatch([])
        try store.appendBatch(["", String(repeating: "x", count: 321), "event=bad\0value"])
        check(!fm.fileExists(atPath: directory.path))
        try fm.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        let marker = store.fileURL.appendingPathComponent("marker.txt")
        try Data("unchanged".utf8).write(to: marker)
        var rejected = false
        do { try store.appendBatch(["event=valid"]) }
        catch DiagnosticFileStore.StoreError.invalidFile { rejected = true }
        check(rejected)
        let contents = try String(contentsOf: marker, encoding: .utf8)
        check(contents == "unchanged")
    }

    func threeGenerationsRotateAndDeleteAll() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-diag-three-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let store = DiagnosticFileStore(fileURL: directory.appendingPathComponent("KoeBridge.log"),
                                        maximumFileBytes: 64, maximumGenerations: 3)
        let second = store.fileURL.appendingPathExtension("2")
        let third = store.fileURL.appendingPathExtension("3")
        // Each timestamped event fits alone, but two cannot fit in 64 bytes.
        try store.appendBatch(["event=oldest", "event=second", "event=third", "event=latest"],
                              at: Date(timeIntervalSince1970: 0))
        check(fm.fileExists(atPath: store.rotatedURL.path))
        check(fm.fileExists(atPath: second.path))
        check(!fm.fileExists(atPath: third.path))
        for (url, event) in [(second, "event=second"), (store.rotatedURL, "event=third"),
                             (store.fileURL, "event=latest")] {
            let contents = try String(contentsOf: url, encoding: .utf8)
            check(contents.contains(event))
            check(!contents.contains("event=oldest"))
            check(store.fileSize(url) <= 64)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        // Deletion also removes generations left by a larger prior limit.
        try Data("previous limit".utf8).write(to: third)
        try store.deleteAll()
        let remainingFiles = try fm.contentsOfDirectory(atPath: directory.path)
        check(remainingFiles.isEmpty)
    }

    func oversizedOlderGenerationIsRemovedAndPermissionsAreEnforced() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-diag-older-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let store = DiagnosticFileStore(fileURL: directory.appendingPathComponent("KoeBridge.log"),
                                        maximumFileBytes: 128, maximumGenerations: 3)
        try store.append("event=before")
        let older = store.fileURL.appendingPathExtension("2")
        try Data(repeating: 0x78, count: 129).write(to: older)
        try store.append("event=after")
        check(!fm.fileExists(atPath: older.path))
        try Data("retained".utf8).write(to: older)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: older.path)
        try store.append("event=last")
        let attributes = try fm.attributesOfItem(atPath: older.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try store.deleteAll()
        let remainingFiles = try fm.contentsOfDirectory(atPath: directory.path)
        check(remainingFiles.isEmpty)
    }

    func defaultStoreLimitsAndRetentionPresets() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-diag-default-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let store = DiagnosticFileStore(fileURL: directory.appendingPathComponent("KoeBridge.log"))
        check(store.maximumFileBytes == 192 * 1024)
        check(store.maximumGenerations == 2)
        try store.appendBatch((0..<2_000).map { "event=\($0) " + String(repeating: "x", count: 250) })
        let directoryContents = try fm.contentsOfDirectory(atPath: directory.path)
        check(Set(directoryContents) == Set(["KoeBridge.log", "KoeBridge.log.1"]))
        for url in [store.fileURL, store.rotatedURL] {
            check(store.fileSize(url) > 0 && store.fileSize(url) <= 192 * 1024)
        }
        let main = DiagnosticLogPolicy.main
        let microphone = DiagnosticLogPolicy.microphone
        check(main.maximumFileBytes == 256 * 1024 && main.maximumGenerations == 3)
        check(microphone.maximumFileBytes == 256 * 1024 && microphone.maximumGenerations == 8)
        check(microphone.maximumFileBytes * microphone.maximumGenerations > main.maximumFileBytes * main.maximumGenerations)
        check(DiagnosticLogPolicy.needsRotation(existingBytes: 60, incomingBytes: 5, maximumFileBytes: 64))
        check(!DiagnosticLogPolicy.needsRotation(existingBytes: 60, incomingBytes: 4, maximumFileBytes: 64))
    }
}
