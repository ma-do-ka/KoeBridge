import Foundation
import KoeBridgePOSIX

struct FileLockTests {
    func secondHandleCannotAcquireUntilFirstCloses() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("koebridge-filelock-test-\(UUID().uuidString)")
        let created = FileManager.default.createFile(atPath: url.path, contents: Data())
        check(created)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try FileHandle(forWritingTo: url)
        defer { try? first.close() }
        let second = try FileHandle(forWritingTo: url)
        defer { try? second.close() }
        check(KBFileLockTryExclusive(first.fileDescriptor) == 0)
        check(KBFileLockTryExclusive(second.fileDescriptor) == -1)
        try first.close()
        check(KBFileLockTryExclusive(second.fileDescriptor) == 0)
    }
}
