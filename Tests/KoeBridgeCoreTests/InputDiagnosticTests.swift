import Foundation
import Testing
@testable import KoeBridgeCore

struct InputDiagnosticTests {
    private let takeID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let relatedID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    @Test func unknownReasonsAndInvalidApplicationValuesCannotLeakContent() {
        let privateText = "PRIVATE_BODY_SHOULD_NOT_APPEAR"
        let unknown = InputDiagnosticEvent.Value.reason(privateText)
        #expect(unknown == .token(.unknown))
        #expect(InputDiagnosticEvent.Value.reason("posted_then_" + privateText) == .token(.unknown))
        for code in ["posted_receipt_timeout", "system_suppressed", "verified_prior_input",
                     "selection_unavailable_on_recheck", "posted_then_selection_unavailable_on_recheck",
                     "matches", "selectionMismatch", "textMismatch"] {
            #expect(InputDiagnosticEvent.Value.reason(code) != .token(.unknown))
        }
        let invalid = ["", "Finder", "com..app", ".com.app", "com.app.", "com.app/field",
                       "https://private.invalid/" + privateText, "com.日本語", "com.a\nb",
                       "com.a\rb", "com.a\0b", "com.app " + privateText,
                       String(repeating: "a", count: 95) + ".b"]
        for identifier in invalid {
            let event = InputDiagnosticEvent(kind: .target, stage: .capture, fields: [
                .app: .application(identifier), .reason: unknown
            ])
            #expect(event.fields[.app] == .token(.unknown))
            var buffer = InputDiagnosticBuffer(takeID: takeID)
            buffer.append(event, elapsedMS: 12)
            let lines = buffer.renderedLines()
            #expect(!lines.joined().contains(privateText))
            #expect(!lines.joined().contains("private.invalid"))
        }
        for identifier in ["com.apple.finder", "com.example-product.App_module",
                           String(repeating: "a", count: 94) + ".b"] {
            let event = InputDiagnosticEvent(kind: .target, stage: .capture,
                                             fields: [.app: .application(identifier)])
            #expect(event.fields[.app] == .application(identifier))
        }
    }

    @Test func largeEventsSplitWithoutLosingFieldsOrCorrelation() {
        var fields = Dictionary(uniqueKeysWithValues: InputDiagnosticEvent.Field.allCases.map {
            ($0, InputDiagnosticEvent.Value.integer(Int.min))
        })
        fields[.app] = .application(String(repeating: "a", count: 94) + ".b")
        fields[.relatedTake] = .identifier(relatedID)
        fields[.reason] = .token(.postedThenFocusedElementUnavailableOnRecheck)
        fields[.eventsPosted] = .flag(true)
        let event = InputDiagnosticEvent(kind: .reconcile, stage: .preflight, fields: fields)
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        buffer.append(event, elapsedMS: Int.max)
        let lines = buffer.renderedLines()
        let parts = lines.filter { $0.contains(" event=1 ") }
        #expect(parts.count > 1)
        for (index, line) in parts.enumerated() {
            #expect(line.contains("take=\(takeID.uuidString.lowercased()) "))
            #expect(line.contains(" t_ms=\(Int.max) "))
            #expect(line.contains("stage=preflight kind=reconcile"))
            #expect(line.contains("part=\(index + 1)/\(parts.count)"))
        }
        for line in lines {
            #expect(line.utf8.count <= DiagnosticLogPolicy.maximumEventBytes)
            #expect(DiagnosticLogPolicy.sanitizedEvent(line) == line)
        }
        let components = parts.flatMap { $0.split(separator: " ").map(String.init) }
        for field in InputDiagnosticEvent.Field.allCases {
            #expect(components.filter { $0.hasPrefix(field.rawValue + "=") }.count == 1)
        }
        #expect(components.contains("events_posted=1"))
        #expect(components.contains("related_take=\(relatedID.uuidString.lowercased())"))
        #expect(buffer.renderedLines() == lines)
    }

    @Test func longTraceKeepsInitialCaptureTailAndLatestResult() {
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        for index in 1...400 {
            buffer.append(InputDiagnosticEvent(kind: index == 50 ? .result : .ax,
                                               stage: index == 50 ? .result : .receipt,
                                               fields: [.polls: .integer(index)]), elapsedMS: index)
        }
        #expect(buffer.retainedCount == 128)
        #expect(buffer.totalCount == 400)
        #expect(buffer.droppedCount == 272)
        #expect(Array(buffer.entries.prefix(32)).map(\.sequence) == Array(1...32))
        #expect(buffer.entries.contains { $0.sequence == 50 && $0.event.kind == .result })
        #expect(buffer.entries.last?.sequence == 400)
        #expect(buffer.renderedLines().first?.contains("dropped=272") == true)
        buffer.append(InputDiagnosticEvent(kind: .result, stage: .result,
                                           fields: [.outcome: .token(.verified)]), elapsedMS: 401)
        buffer.append(InputDiagnosticEvent(kind: .reconcile, stage: .reconcile,
                                           fields: [.outcome: .token(.rebased)]), elapsedMS: 402)
        #expect(buffer.retainedCount == 128)
        #expect(buffer.entries.contains { $0.sequence == 401 })
        #expect(!buffer.entries.contains { $0.sequence == 50 })
        #expect(buffer.entries.last?.sequence == 402)
    }

    @Test func discardRemovesAllEvidenceAndNegativeTimeCannotCorruptTheTrace() {
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        #expect(buffer.renderedLines().isEmpty)
        buffer.append(InputDiagnosticEvent(kind: .session, stage: .requested, fields: [:]), elapsedMS: -40)
        #expect(buffer.entries.first?.elapsedMS == 0)
        #expect(buffer.renderedLines().allSatisfy { $0.contains("t_ms=0") })
        buffer.discard()
        #expect(buffer.renderedLines().isEmpty)
        #expect(buffer.retainedCount == 0 && buffer.totalCount == 0 && buffer.droppedCount == 0)
    }

    @Test func turningOffRevokesAnInFlightTraceEvenAfterTurningOnAgain() throws {
        var consent = InputDiagnosticConsent()
        #expect(!consent.isEnabled)
        #expect(consent.token == nil)
        #expect(!consent.allows(nil))
        consent.setEnabled(true)
        let oldToken = try #require(consent.token)
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        buffer.append(InputDiagnosticEvent(kind: .result, stage: .result,
                                           fields: [.outcome: .token(.unconfirmed)]), elapsedMS: 500)
        consent.setEnabled(false)
        #expect(!consent.allows(oldToken))
        consent.setEnabled(true)
        #expect(!consent.allows(oldToken))
        let oldLines = buffer.drain(consent: consent, token: oldToken)
        #expect(oldLines.isEmpty && buffer.retainedCount == 0)
        let currentToken = try #require(consent.token)
        #expect(consent.allows(currentToken))
        consent.setEnabled(true)
        #expect(consent.allows(currentToken))
        let otherConsent = InputDiagnosticConsent(enabled: true)
        #expect(!otherConsent.allows(currentToken))
    }

    @Test func deletingLogsRevokesOldEvidenceAndAllowsOnlyNewTraces() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("koebridge-input-diag-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        let store = DiagnosticFileStore(fileURL: directory.appendingPathComponent("KoeBridge.log"))
        var consent = InputDiagnosticConsent()
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        buffer.append(InputDiagnosticEvent(kind: .result, stage: .result,
                                           fields: [.reason: .reason("posted_receipt_timeout")]), elapsedMS: 600)
        let disabledLines = buffer.drain(consent: consent, token: nil)
        try store.appendBatch(disabledLines)
        #expect(!fm.fileExists(atPath: store.fileURL.path))
        #expect(!fm.fileExists(atPath: directory.path))
        consent.setEnabled(true)
        let oldToken = try #require(consent.token)
        buffer.append(InputDiagnosticEvent(kind: .result, stage: .result,
                                           fields: [.reason: .reason("posted_receipt_timeout")]), elapsedMS: 600)
        try store.appendBatch(buffer.renderedLines())
        #expect(fm.fileExists(atPath: store.fileURL.path))
        consent.invalidate()
        try store.deleteAll()
        let deletedLines = buffer.drain(consent: consent, token: oldToken)
        try store.appendBatch(deletedLines)
        #expect(deletedLines.isEmpty && buffer.retainedCount == 0)
        #expect(!fm.fileExists(atPath: store.fileURL.path))
        #expect(consent.isEnabled)
        let newToken = try #require(consent.token)
        buffer.append(InputDiagnosticEvent(kind: .result, stage: .result,
                                           fields: [.reason: .reason("verified_value_and_selection")]), elapsedMS: 800)
        let newLines = buffer.drain(consent: consent, token: newToken)
        try store.appendBatch(newLines)
        let contents = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(contents.contains("verified_value_and_selection"))
        #expect(!contents.contains("posted_receipt_timeout"))
        #expect(buffer.retainedCount == 0)
    }
}

// Synthetic fixtures only. Do not check a user's diagnostic logs into the repo.
extension InputDiagnosticTests {
    @Test func receiptNoiseCannotEvictPayloadOrExpectedEdit() {
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        for n in 1...32 {
            buffer.append(.init(kind: .ax, stage: .capture, fields: [.polls: .integer(n)]), elapsedMS: n)
        }
        buffer.append(.init(kind: .payload, stage: .posting, fields: [
            .valueUTF16: .integer(48), .plannedChunks: .integer(3),
            .modifiers: .integer(0), .hardwareModifiers: .integer(0)
        ]), elapsedMS: 40)
        buffer.append(.init(kind: .receipt, stage: .receipt, fields: [
            .timeoutMS: .integer(600), .expectedStart: .integer(48),
            .expectedLength: .integer(0), .valueUTF16: .integer(57)
        ]), elapsedMS: 41)
        for n in 35...1_000 {
            buffer.append(.init(kind: .ax, stage: .receipt, fields: [.error: .integer(0)]), elapsedMS: n)
        }
        #expect(buffer.retainedCount == 128)
        #expect(buffer.droppedCount == buffer.totalCount - buffer.retainedCount)
        #expect(buffer.entries.contains { $0.sequence == 33 })
        #expect(buffer.entries.contains { $0.sequence == 34 })
        #expect(Array(buffer.entries.prefix(32)).map(\.sequence) == Array(1...32))
        let output = buffer.renderedLines()
        #expect(output.contains { $0.contains("section=payload") && $0.contains("hardware_modifiers=0") })
        #expect(output.contains { $0.contains("section=expected") && $0.contains("value_utf16=57") })
        #expect(output.allSatisfy { $0.utf8.count <= 320 && DiagnosticLogPolicy.sanitizedEvent($0) == $0 })
    }

    @Test func summariesCorrelateBuildAppRecognitionAndOutcome() {
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        let events: [InputDiagnosticEvent] = [
            .init(kind: .session, stage: .requested, fields: [.build: .integer(30), .engine: .token(.gemini)]),
            .init(kind: .target, stage: .capture, fields: [.app: .application("com.example.Editor"), .pid: .integer(123)]),
            .init(kind: .session, stage: .result, fields: [.recognizedUTF16: .integer(48), .outcome: .token(.ok)]),
            .init(kind: .receipt, stage: .receipt, fields: [.polls: .integer(10), .textMismatch: .integer(9), .unchanged: .integer(1), .deadlineExceeded: .flag(false)]),
            .init(kind: .result, stage: .result, fields: [.eventsPosted: .flag(true), .outcome: .token(.unconfirmed), .reason: .token(.postedReceiptTimeout), .sentChunks: .integer(3)])
        ]
        for (i, event) in events.enumerated() { buffer.append(event, elapsedMS: i) }
        let summaries = buffer.renderedLines().filter { $0.hasPrefix("input_summary v=2 ") }
        let text = summaries.joined(separator: "\n")
        #expect(text.contains("section=requested") && text.contains("build=30"))
        #expect(text.contains("section=target") && text.contains("app=com.example.Editor"))
        #expect(text.contains("section=recognition") && text.contains("recognized_utf16=48"))
        #expect(text.contains("section=result") && text.contains("reason=posted_receipt_timeout"))
        #expect(!text.contains("outcome=verified"))
        #expect(summaries.allSatisfy { $0.contains("take=\(takeID.uuidString.lowercased())") && $0.utf8.count <= 320 })
    }

    @Test func actualDoubleReadCaretIsNotLabeledAsPlannedCaret() {
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        buffer.append(.init(kind: .receipt, stage: .receipt, fields: [
            .timeoutMS: .integer(600), .expectedStart: .integer(99), .expectedLength: .integer(0)
        ]), elapsedMS: 40)
        buffer.append(.init(kind: .snapshot, stage: .receipt, fields: [
            .expectedStart: .integer(11), .expectedLength: .integer(0),
            .selectionStart: .integer(11), .selectionLength: .integer(0), .valueUTF16: .integer(11)
        ]), elapsedMS: 50)
        let lines = buffer.renderedLines()
        let expected = lines.filter { $0.contains("section=expected ") }.joined()
        let observed = lines.filter { $0.contains("section=observed ") }.joined()
        #expect(expected.contains("expected_start=99"))
        #expect(observed.contains("first_read_start=11"))
        #expect(!observed.contains("expected_start="))
        #expect(lines.contains { $0.hasPrefix("input_diag v=1 ") && $0.contains("expected_start=11") })
    }

    @Test func summaryConsentRevocationErasesMilestonesAsWellAsTrace() throws {
        var consent = InputDiagnosticConsent(enabled: true)
        let token = try #require(consent.token)
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        buffer.append(.init(kind: .result, stage: .result, fields: [.reason: .token(.postedReceiptTimeout)]), elapsedMS: 5)
        #expect(buffer.renderedLines().contains { $0.hasPrefix("input_summary") })
        consent.invalidate()
        #expect(buffer.drain(consent: consent, token: token).isEmpty)
        #expect(buffer.renderedLines().isEmpty)
        buffer.append(.init(kind: .ax, stage: .capture, fields: [:]), elapsedMS: 1)
        #expect(!buffer.renderedLines().joined().contains("posted_receipt_timeout"))
    }

    @Test func milestonesStayBoundedAndKeepFirstAndLastReadbacks() {
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        for index in 0..<3_000 {
            buffer.append(.init(kind: .snapshot, stage: .receipt, fields: [
                .selectionStart: .integer(index), .expectedStart: .integer(index)
            ]), elapsedMS: index)
            #expect(buffer.retainedCount <= 128)
        }
        let lines = buffer.renderedLines()
        #expect(lines.contains { $0.contains("section=first_observed ") && $0.contains("selection_start=0") })
        #expect(lines.contains { $0.contains("section=observed ") && $0.contains("selection_start=2999") })
        #expect(lines.filter { $0.hasPrefix("input_summary") }.count <= 4)
    }

    @Test func longestSummaryFieldsAreBoundedAndSanitized() {
        var fields = Dictionary(uniqueKeysWithValues: InputDiagnosticEvent.Field.allCases.map {
            ($0, InputDiagnosticEvent.Value.integer(Int.max))
        })
        fields[.app] = .application(String(repeating: "a", count: 94) + ".b")
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        buffer.append(.init(kind: .target, stage: .capture, fields: fields), elapsedMS: Int.max)
        let summaries = buffer.renderedLines().filter { $0.hasPrefix("input_summary") }
        #expect(!summaries.isEmpty)
        #expect(summaries.allSatisfy { $0.utf8.count <= 320 && DiagnosticLogPolicy.sanitizedEvent($0) == $0 })
        for field in InputDiagnosticEvent.Field.allCases {
            #expect(summaries.flatMap { $0.split(separator: " ") }.filter { $0.hasPrefix(field.rawValue + "=") }.count == 1)
        }
    }

    @Test func configurableRetentionDoesNotChangeDefaultLimit() {
        let take = UUID()
        var ordinary = InputDiagnosticBuffer(takeID: take)
        var developer = InputDiagnosticBuffer(takeID: take, maximumEvents: 512,
                                              preservedInitialEvents: 64)
        let event = InputDiagnosticEvent(kind: .session, stage: .requested, fields: [:])
        for i in 0..<600 {
            ordinary.append(event, elapsedMS: i)
            developer.append(event, elapsedMS: i)
        }
        #expect(ordinary.retainedCount == InputDiagnosticBuffer.maximumEvents)
        #expect(developer.retainedCount == 512)
        #expect(ordinary.droppedCount > developer.droppedCount)
    }
}
