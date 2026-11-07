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
