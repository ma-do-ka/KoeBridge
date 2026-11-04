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

}
