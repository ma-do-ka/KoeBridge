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

}
