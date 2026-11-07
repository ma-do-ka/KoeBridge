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
}
