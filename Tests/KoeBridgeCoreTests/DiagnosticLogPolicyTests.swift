import Foundation
import Testing
@testable import KoeBridgeCore

struct DiagnosticLogPolicyTests {
    @Test func explicitlyOptedInOnly() {
        #expect(!DiagnosticLogPolicy.isEnabled(storedValue: nil))
        #expect(!DiagnosticLogPolicy.isEnabled(storedValue: false))
        #expect(DiagnosticLogPolicy.isEnabled(storedValue: true))
    }
    @Test func shortSingleLineEvents() {
        #expect(DiagnosticLogPolicy.sanitizedEvent("ready\nstatus=ok\rmore") == "ready status=ok more")
        #expect(DiagnosticLogPolicy.sanitizedEvent("") == nil)
        #expect(DiagnosticLogPolicy.sanitizedEvent("secret\0value") == nil)
        #expect(DiagnosticLogPolicy.sanitizedEvent(String(repeating: "x", count: 321)) == nil)
    }
    @Test func rotationCapsGrowth() {
        let max = DiagnosticLogPolicy.maximumFileBytes
        #expect(max == 192 * 1024)
        #expect(DiagnosticLogPolicy.maximumFiles == 2)
        #expect(!DiagnosticLogPolicy.needsRotation(existingBytes: 0, incomingBytes: 300))
        #expect(!DiagnosticLogPolicy.needsRotation(existingBytes: max - 10, incomingBytes: 10))
        #expect(DiagnosticLogPolicy.needsRotation(existingBytes: max - 10, incomingBytes: 11))
    }
    @Test func stoppedSessionStatusIsPersistable() throws {
        let original = TranscriptRecord(engine: "Apple", text: "確認",
                                        isPartial: false, delivery: .blockedFocus)
        let restored = try JSONDecoder().decode(TranscriptRecord.self, from: JSONEncoder().encode(original))
        #expect(restored.delivery == .blockedFocus)
    }
    @Test func rotationAndDeletionOnRealFiles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("koebridge-tests-\(UUID())")
        defer { try? fm.removeItem(at: dir) }
        let store = DiagnosticFileStore(fileURL: dir.appendingPathComponent("KoeBridge.log"))
        for i in 0..<1_300 { try store.append("event=\(i) " + String(repeating: "a", count: 250)) }
        let latest = store.fileSize(store.fileURL)
        let older = store.fileSize(store.rotatedURL)
        #expect(latest > 0)
        #expect(older > 0)
        #expect(latest <= DiagnosticLogPolicy.maximumFileBytes)
        #expect(older <= DiagnosticLogPolicy.maximumFileBytes)
        let attributes = try fm.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try store.deleteAll()
        #expect(!fm.fileExists(atPath: store.fileURL.path))
        #expect(!fm.fileExists(atPath: store.rotatedURL.path))
    }
    @Test func symbolicLinkCannotRedirectLogging() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("koebridge-link-tests-\(UUID())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.txt")
        try Data("untouched".utf8).write(to: target)
        let log = dir.appendingPathComponent("KoeBridge.log")
        try fm.createSymbolicLink(at: log, withDestinationURL: target)
        #expect(throws: Error.self) { try DiagnosticFileStore(fileURL: log).append("new log") }
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    }

    @Test func batchedEventsRotateInOrderAndKeepBothFilesPrivate() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-diag-batch-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let store = DiagnosticFileStore(fileURL: directory.appendingPathComponent("KoeBridge.log"))
        let events = (0..<1_800).map { "case=\($0) " + String(repeating: "x", count: 230) }
        try store.appendBatch(events, at: Date(timeIntervalSince1970: 0))
        for url in [store.fileURL, store.rotatedURL] {
            #expect(store.fileSize(url) > 0)
            #expect(store.fileSize(url) <= DiagnosticLogPolicy.maximumFileBytes)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let older = try String(contentsOf: store.rotatedURL, encoding: .utf8)
        let current = try String(contentsOf: store.fileURL, encoding: .utf8)
        let lines = (older + current).split(separator: "\n")
        let ids = lines.compactMap { line -> Int? in
            line.split(separator: " ").dropFirst().first.flatMap { Int($0.dropFirst(5)) }
        }
        let first = try #require(ids.first)
        #expect(first > 0)
        #expect(ids.count == lines.count)
        #expect(ids == Array(first..<1_800))
        let names = try fm.contentsOfDirectory(atPath: directory.path)
        #expect(Set(names) == Set(["KoeBridge.log", "KoeBridge.log.1"]))
    }

    @Test func oversizedRotatedFileIsRemovedBeforeTheNextNormalRotation() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-diag-limit-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let store = DiagnosticFileStore(fileURL: directory.appendingPathComponent("KoeBridge.log"))
        try store.append("event=before")
        let oversized = Data(repeating: 0x78, count: DiagnosticLogPolicy.maximumFileBytes + 1)
        try oversized.write(to: store.rotatedURL)
        try store.appendBatch(["event=second", "event=third"])
        #expect(!fm.fileExists(atPath: store.rotatedURL.path))
        let retained = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(retained.contains("event=before"))
        #expect(retained.contains("event=second"))
        #expect(retained.contains("event=third"))
        for url in [store.fileURL, store.rotatedURL] { try oversized.write(to: url) }
        try store.appendBatch(["event=fresh"])
        #expect(store.fileSize(store.fileURL) <= DiagnosticLogPolicy.maximumFileBytes)
        #expect(store.fileSize(store.rotatedURL) <= DiagnosticLogPolicy.maximumFileBytes)
        let fresh = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(fresh.contains("event=fresh"))
        #expect(fresh.split(separator: "\n").count == 1)
    }

    @Test func invalidBatchDoesNotCreateFilesOrAcceptANonregularDestination() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-diag-empty-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let store = DiagnosticFileStore(fileURL: directory.appendingPathComponent("KoeBridge.log"))
        try store.appendBatch([])
        try store.appendBatch(["", String(repeating: "x", count: 321), "event=bad\0value"])
        #expect(!fm.fileExists(atPath: directory.path))
        try fm.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        let marker = store.fileURL.appendingPathComponent("marker.txt")
        try Data("unchanged".utf8).write(to: marker)
        var rejected = false
        do { try store.appendBatch(["event=valid"]) }
        catch DiagnosticFileStore.StoreError.invalidFile { rejected = true }
        #expect(rejected)
        let contents = try String(contentsOf: marker, encoding: .utf8)
        #expect(contents == "unchanged")
    }

    @Test func threeGenerationsRotateAndDeleteAll() throws {
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
        #expect(fm.fileExists(atPath: store.rotatedURL.path))
        #expect(fm.fileExists(atPath: second.path))
        #expect(!fm.fileExists(atPath: third.path))
        for (url, event) in [(second, "event=second"), (store.rotatedURL, "event=third"),
                             (store.fileURL, "event=latest")] {
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(contents.contains(event))
            #expect(!contents.contains("event=oldest"))
            #expect(store.fileSize(url) <= 64)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        // Deletion also removes generations left by a larger prior limit.
        try Data("previous limit".utf8).write(to: third)
        try store.deleteAll()
        #expect(try fm.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func oversizedOlderGenerationIsRemovedAndPermissionsAreEnforced() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-diag-older-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let store = DiagnosticFileStore(fileURL: directory.appendingPathComponent("KoeBridge.log"),
                                        maximumFileBytes: 128, maximumGenerations: 3)
        try store.append("event=before")
        let older = store.fileURL.appendingPathExtension("2")
        try Data(repeating: 0x78, count: 129).write(to: older)
        try store.append("event=after")
        #expect(!fm.fileExists(atPath: older.path))
        try Data("retained".utf8).write(to: older)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: older.path)
        try store.append("event=last")
        let attributes = try fm.attributesOfItem(atPath: older.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try store.deleteAll()
        #expect(try fm.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func defaultStoreLimitsAndRetentionPresets() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-diag-default-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let store = DiagnosticFileStore(fileURL: directory.appendingPathComponent("KoeBridge.log"))
        #expect(store.maximumFileBytes == 192 * 1024)
        #expect(store.maximumGenerations == 2)
        try store.appendBatch((0..<2_000).map { "event=\($0) " + String(repeating: "x", count: 250) })
        #expect(Set(try fm.contentsOfDirectory(atPath: directory.path)) == Set(["KoeBridge.log", "KoeBridge.log.1"]))
        for url in [store.fileURL, store.rotatedURL] {
            #expect(store.fileSize(url) > 0 && store.fileSize(url) <= 192 * 1024)
        }
        let main = DiagnosticLogPolicy.main
        let microphone = DiagnosticLogPolicy.microphone
        #expect(main.maximumFileBytes == 256 * 1024 && main.maximumGenerations == 3)
        #expect(microphone.maximumFileBytes == 256 * 1024 && microphone.maximumGenerations == 8)
        #expect(microphone.maximumFileBytes * microphone.maximumGenerations > main.maximumFileBytes * main.maximumGenerations)
        #expect(DiagnosticLogPolicy.needsRotation(existingBytes: 60, incomingBytes: 5, maximumFileBytes: 64))
        #expect(!DiagnosticLogPolicy.needsRotation(existingBytes: 60, incomingBytes: 4, maximumFileBytes: 64))
    }
}
