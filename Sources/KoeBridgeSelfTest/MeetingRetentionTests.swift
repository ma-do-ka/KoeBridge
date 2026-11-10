import Foundation
import KoeBridgeCore

struct MeetingRetentionTests {
    func canonicalWAVRoundTripAndMalformedHeaders() throws {
        let pcm = Data((0..<1024).map { UInt8(truncatingIfNeeded: $0) })
        let wav = try PCM16WAV.encode(pcm)
        try check(try PCM16WAV.extractPCM(wav) == pcm)
        try check(try GeminiRecheckWire.wav(pcm16LE: pcm) == wav)
        // Every header field is checked, including sample rate, channels and lengths.
        for offset in 0..<44 {
            var malformed = wav
            malformed[offset] ^= 1
            checkThrows(GeminiRecheckWire.RecheckError.self) { _ = try PCM16WAV.extractPCM(malformed) }
        }
        checkThrows(GeminiRecheckWire.RecheckError.self) { _ = try PCM16WAV.extractPCM(Data(wav.dropLast())) }
        checkThrows(GeminiRecheckWire.RecheckError.self) { _ = try PCM16WAV.encode(Data([0])) }
        checkThrows(GeminiRecheckWire.RecheckError.self) { _ = try PCM16WAV.encode(Data()) }
        let maximum = Data(repeating: 127, count: 14_000_000)
        try check(try PCM16WAV.extractPCM(PCM16WAV.encode(maximum)) == maximum)
        checkThrows(GeminiRecheckWire.RecheckError.self) { _ = try PCM16WAV.encode(Data(count: 14_000_002)) }
    }

    func backwardCompatibilityAndAppendOnlyResults() throws {
        let record = TranscriptRecord(engine: "Apple", text: "original", isPartial: false,
            delivery: .reviewRequired, review: .init(status: .needsReview, note: "review", alternativeText: "alternative"))
        let encoded = try JSONEncoder().encode(record)
        var old = try require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["audioAsset", "retranscriptions", "kind", "audioUnavailableReason"] { old.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(TranscriptRecord.self, from: JSONSerialization.data(withJSONObject: old))
        check(decoded.audioAsset == nil && decoded.retranscriptions.isEmpty && decoded.kind == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        var archive = try RecentTranscriptArchive(fileURL: file)
        try archive.insert(record)
        let asset = TranscriptRecord.AudioAsset(relativeFileName: record.id.uuidString + ".wav", pcmByteCount: 4,
            recordedAt: record.recordedAt, expiresAt: record.recordedAt.addingTimeInterval(604800))
        try archive.updateAudio(id: record.id, asset: asset, reason: nil)
        try archive.appendRetranscription(id: record.id, result: .init(engine: "Gemini", text: "new one"))
        try archive.appendRetranscription(id: record.id, result: .init(engine: "Apple", text: "new two"))
        let reopened = try RecentTranscriptArchive(fileURL: file)
        let saved = try require(reopened.entries.first)
        check(saved.text == record.text && saved.review == record.review && saved.delivery == record.delivery)
        check(saved.retranscriptions.map(\.text) == ["new one", "new two"])
        check(saved.audioAsset == asset)
        try archive.updateAudio(id: record.id, asset: nil, reason: "expired")
        check(archive.entries.first?.text == "original" && archive.entries.first?.retranscriptions.count == 2)
        var history = TranscriptHistoryStore(fileURL: file)
        let meetingID = try require(history.remember("meeting", isPartial: false,
            delivery: .automaticPasteDisabled, engine: "Apple", kind: "meeting"))
        let meeting = try require(RecentTranscriptArchive(fileURL: file).entries.first { $0.id == meetingID })
        check(meeting.kind == "meeting" && meeting.audioAsset == nil && meeting.delivery == .automaticPasteDisabled)
    }

    func independentSourceTimelineSortsByCaptureRatherThanCompletion() {
        var transcript = MeetingTranscript()
        transcript.append(source: .system, offset: 9, text: "system second")
        transcript.append(source: .microphone, offset: 3.5, text: "mic first")
        transcript.append(source: .system, offset: 60, text: "next chunk")
        transcript.append(source: .microphone, offset: 0, text: "  ")
        check(transcript.segments.count == 3)
        check(transcript.text == "[00:03] 自分［マイク］\nmic first\n\n[00:09] 相手［システム音声］\nsystem second\n\n[01:00] 相手［システム音声］\nnext chunk")
    }
}
