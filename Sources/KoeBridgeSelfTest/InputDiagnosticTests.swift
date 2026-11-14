import Foundation
import KoeBridgeCore

struct InputDiagnosticTests {
    private let takeID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let relatedID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    func unknownReasonsAndInvalidApplicationValuesCannotLeakContent() {
        let privateText = "PRIVATE_BODY_SHOULD_NOT_APPEAR"
        let unknown = InputDiagnosticEvent.Value.reason(privateText)
        check(unknown == .token(.unknown))
        check(InputDiagnosticEvent.Value.reason("posted_then_" + privateText) == .token(.unknown))
        for code in ["posted_receipt_timeout", "system_suppressed", "verified_prior_input",
                     "selection_unavailable_on_recheck", "posted_then_selection_unavailable_on_recheck",
                     "matches", "selectionMismatch", "textMismatch"] {
            check(InputDiagnosticEvent.Value.reason(code) != .token(.unknown))
        }
        let invalid = ["", "Finder", "com..app", ".com.app", "com.app.", "com.app/field",
                       "https://private.invalid/" + privateText, "com.日本語", "com.a\nb",
                       "com.a\rb", "com.a\0b", "com.app " + privateText,
                       String(repeating: "a", count: 95) + ".b"]
        for identifier in invalid {
            let event = InputDiagnosticEvent(kind: .target, stage: .capture, fields: [
                .app: .application(identifier), .reason: unknown
            ])
            check(event.fields[.app] == .token(.unknown))
            var buffer = InputDiagnosticBuffer(takeID: takeID)
            buffer.append(event, elapsedMS: 12)
            let lines = buffer.renderedLines()
            check(!lines.joined().contains(privateText))
            check(!lines.joined().contains("private.invalid"))
        }
        for identifier in ["com.apple.finder", "com.example-product.App_module",
                           String(repeating: "a", count: 94) + ".b"] {
            let event = InputDiagnosticEvent(kind: .target, stage: .capture,
                                             fields: [.app: .application(identifier)])
            check(event.fields[.app] == .application(identifier))
        }
    }

    func largeEventsSplitWithoutLosingFieldsOrCorrelation() {
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
        check(parts.count > 1)
        for (index, line) in parts.enumerated() {
            check(line.contains("take=\(takeID.uuidString.lowercased()) "))
            check(line.contains(" t_ms=\(Int.max) "))
            check(line.contains("stage=preflight kind=reconcile"))
            check(line.contains("part=\(index + 1)/\(parts.count)"))
        }
        for line in lines {
            check(line.utf8.count <= DiagnosticLogPolicy.maximumEventBytes)
            check(DiagnosticLogPolicy.sanitizedEvent(line) == line)
        }
        let components = parts.flatMap { $0.split(separator: " ").map(String.init) }
        for field in InputDiagnosticEvent.Field.allCases {
            check(components.filter { $0.hasPrefix(field.rawValue + "=") }.count == 1)
        }
        check(components.contains("events_posted=1"))
        check(components.contains("related_take=\(relatedID.uuidString.lowercased())"))
        check(buffer.renderedLines() == lines)
    }

    func longTraceKeepsInitialCaptureTailAndLatestResult() {
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        for index in 1...400 {
            buffer.append(InputDiagnosticEvent(kind: index == 50 ? .result : .ax,
                                               stage: index == 50 ? .result : .receipt,
                                               fields: [.polls: .integer(index)]), elapsedMS: index)
        }
        check(buffer.retainedCount == 128)
        check(buffer.totalCount == 400)
        check(buffer.droppedCount == 272)
        check(Array(buffer.entries.prefix(32)).map(\.sequence) == Array(1...32))
        check(buffer.entries.contains { $0.sequence == 50 && $0.event.kind == .result })
        check(buffer.entries.last?.sequence == 400)
        check(buffer.renderedLines().first?.contains("dropped=272") == true)
        buffer.append(InputDiagnosticEvent(kind: .result, stage: .result,
                                           fields: [.outcome: .token(.verified)]), elapsedMS: 401)
        buffer.append(InputDiagnosticEvent(kind: .reconcile, stage: .reconcile,
                                           fields: [.outcome: .token(.rebased)]), elapsedMS: 402)
        check(buffer.retainedCount == 128)
        check(buffer.entries.contains { $0.sequence == 401 })
        check(!buffer.entries.contains { $0.sequence == 50 })
        check(buffer.entries.last?.sequence == 402)
    }

    func discardRemovesAllEvidenceAndNegativeTimeCannotCorruptTheTrace() {
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        check(buffer.renderedLines().isEmpty)
        buffer.append(InputDiagnosticEvent(kind: .session, stage: .requested, fields: [:]), elapsedMS: -40)
        check(buffer.entries.first?.elapsedMS == 0)
        check(buffer.renderedLines().allSatisfy { $0.contains("t_ms=0") })
        buffer.discard()
        check(buffer.renderedLines().isEmpty)
        check(buffer.retainedCount == 0 && buffer.totalCount == 0 && buffer.droppedCount == 0)
    }

    func turningOffRevokesAnInFlightTraceEvenAfterTurningOnAgain() throws {
        var consent = InputDiagnosticConsent()
        check(!consent.isEnabled)
        check(consent.token == nil)
        check(!consent.allows(nil))
        consent.setEnabled(true)
        let oldToken = try require(consent.token)
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        buffer.append(InputDiagnosticEvent(kind: .result, stage: .result,
                                           fields: [.outcome: .token(.unconfirmed)]), elapsedMS: 500)
        consent.setEnabled(false)
        check(!consent.allows(oldToken))
        consent.setEnabled(true)
        check(!consent.allows(oldToken))
        let oldLines = buffer.drain(consent: consent, token: oldToken)
        check(oldLines.isEmpty && buffer.retainedCount == 0)
        let currentToken = try require(consent.token)
        check(consent.allows(currentToken))
        consent.setEnabled(true)
        check(consent.allows(currentToken))
        let otherConsent = InputDiagnosticConsent(enabled: true)
        check(!otherConsent.allows(currentToken))
    }

    func deletingLogsRevokesOldEvidenceAndAllowsOnlyNewTraces() throws {
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
        check(!fm.fileExists(atPath: store.fileURL.path))
        check(!fm.fileExists(atPath: directory.path))
        consent.setEnabled(true)
        let oldToken = try require(consent.token)
        buffer.append(InputDiagnosticEvent(kind: .result, stage: .result,
                                           fields: [.reason: .reason("posted_receipt_timeout")]), elapsedMS: 600)
        try store.appendBatch(buffer.renderedLines())
        check(fm.fileExists(atPath: store.fileURL.path))
        consent.invalidate()
        try store.deleteAll()
        let deletedLines = buffer.drain(consent: consent, token: oldToken)
        try store.appendBatch(deletedLines)
        check(deletedLines.isEmpty && buffer.retainedCount == 0)
        check(!fm.fileExists(atPath: store.fileURL.path))
        check(consent.isEnabled)
        let newToken = try require(consent.token)
        buffer.append(InputDiagnosticEvent(kind: .result, stage: .result,
                                           fields: [.reason: .reason("verified_value_and_selection")]), elapsedMS: 800)
        let newLines = buffer.drain(consent: consent, token: newToken)
        try store.appendBatch(newLines)
        let contents = try String(contentsOf: store.fileURL, encoding: .utf8)
        check(contents.contains("verified_value_and_selection"))
        check(!contents.contains("posted_receipt_timeout"))
        check(buffer.retainedCount == 0)
    }
}

extension InputDiagnosticTests {
    func numericCapabilityKeepsTheExistingBaselineMilestone() {
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        for index in 0..<40 {
            buffer.append(.init(kind: .ax, stage: .capture, fields: [:]), elapsedMS: index)
        }
        buffer.append(.init(kind: .snapshot, stage: .preflight, fields: [
            .selectionKind: .token(.numericRange), .selectionStart: .integer(12), .selectionLength: .integer(0),
            .selectionRead: .token(.ok), .valueReadAttempted: .flag(true), .valueReadResult: .token(.ok),
            .exactBaselineAvailable: .flag(true), .receiptSkippedReason: .token(.snapshotAvailable)
        ]), elapsedMS: 41)
        for index in 0..<1_000 {
            buffer.append(.init(kind: .ax, stage: .receipt, fields: [:]), elapsedMS: 50 + index)
        }
        let summaries = buffer.renderedLines().filter { $0.hasPrefix("input_summary") }
        for section in ["before", "capability"] {
            check(summaries.contains { $0.contains("section=\(section) ") && $0.contains("selection_start=12") })
        }
        check(summaries.joined().contains("receipt_skipped_reason=snapshot_available"))
        check(buffer.retainedCount == 128 && buffer.droppedCount == buffer.totalCount - 128)
    }

    func deliveryDiagnosticsSurviveNoiseWithinTheExistingBudget() {
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        for index in 0..<40 {
            buffer.append(.init(kind: .ax, stage: .capture, fields: [.error: .integer(0)]), elapsedMS: index)
        }
        let events: [InputDiagnosticEvent] = [
            .init(kind: .snapshot, stage: .preflight, fields: [
                .selectionKind: .token(.textMarker), .selectionRead: .token(.notAttempted),
                .valueReadAttempted: .flag(false), .valueReadResult: .token(.notAttempted),
                .exactBaselineAvailable: .flag(false), .receiptSkippedReason: .token(.markerNotNumeric)
            ]),
            .init(kind: .focus, stage: .posting, fields: [
                .requireOriginalSelection: .flag(false), .selectionComparison: .token(.skipped),
                .chunkOrdinal: .integer(101), .outcome: .token(.ok)
            ]),
            .init(kind: .eligibility, stage: .result, fields: [
                .receiptSkippedReason: .token(.markerNotNumeric), .exactBaselineAvailable: .flag(false)
            ]),
            .init(kind: .progress, stage: .posting, fields: [
                .plannedChunks: .integer(102), .sentChunks: .integer(102), .lastPostedOrdinal: .integer(102),
                .gapCount: .integer(101), .actualGapLastUS: .integer(20_310),
                .pacingProfile: .token(.unobservableSelectionV1), .pacingVersion: .integer(1),
                .pacingGapMS: .integer(20), .pacingBudgetMS: .integer(2_000), .pacingBudgetExceeded: .flag(true),
                .abortPhase: .token(.none), .abortReason: .token(.none)
            ]),
            .init(kind: .observation, stage: .receipt, fields: [
                .outcome: .token(.same), .receiverObservation: .token(.valueOnly),
                .valueReadAttempted: .flag(true), .valueReadResult: .token(.ok),
                .exactBaselineAvailable: .flag(false)
            ]),
            .init(kind: .result, stage: .result, fields: [.outcome: .token(.unconfirmed)])
        ]
        for (index, event) in events.enumerated() { buffer.append(event, elapsedMS: 50 + index) }
        for index in 0..<3_000 {
            buffer.append(.init(kind: .ax, stage: .receipt, fields: [.error: .integer(0)]), elapsedMS: 100 + index)
            check(buffer.retainedCount <= 128)
        }
        check(buffer.retainedCount == 128)
        check(buffer.droppedCount == buffer.totalCount - 128)
        for event in events { check(buffer.entries.contains { $0.event == event }) }
        let summaries = buffer.renderedLines().filter { $0.hasPrefix("input_summary") }.joined(separator: "\n")
        for section in ["capability", "checkpoint", "eligibility", "progress", "observation", "result"] {
            check(summaries.contains("section=\(section) "))
        }
        for field in ["require_original_selection=0", "selection_comparison=skipped", "chunk_ordinal=101",
                      "receipt_skipped_reason=marker_not_numeric", "value_read_result=not_attempted",
                      "exact_baseline_available=0", "receiver_observation=value_only",
                      "pacing_profile=unobservable_selection_v1", "pacing_budget_exceeded=1",
                      "last_posted_ordinal=102", "gap_count=101"] {
            check(summaries.contains(field))
        }
        check(!summaries.contains("outcome=verified"))
        check(buffer.renderedLines().allSatisfy { $0.utf8.count <= 320 && DiagnosticLogPolicy.sanitizedEvent($0) == $0 })
    }

    func abortEvidenceAndUnavailableObserverAreProtected() {
        var buffer = InputDiagnosticBuffer(takeID: takeID)
        for index in 0..<40 {
            buffer.append(.init(kind: .ax, stage: .capture, fields: [:]), elapsedMS: index)
        }
        buffer.append(.init(kind: .progress, stage: .posting, fields: [
            .lastPostedOrdinal: .integer(6), .abortPhase: .token(.posting),
            .abortReason: .token(.activeAppChanged)
        ]), elapsedMS: 41)
        buffer.append(.init(kind: .observation, stage: .receipt, fields: [
            .outcome: .token(.unknown), .receiverObservation: .token(.unavailable),
            .valueReadAttempted: .flag(false), .valueReadResult: .token(.notAttempted)
        ]), elapsedMS: 42)
        for index in 0..<500 {
            buffer.append(.init(kind: .ax, stage: .receipt, fields: [:]), elapsedMS: 50 + index)
        }
        let lines = buffer.renderedLines().joined()
        check(lines.contains("abort_reason=active_app_changed"))
        check(lines.contains("abort_phase=posting"))
        check(lines.contains("last_posted_ordinal=6"))
        check(lines.contains("receiver_observation=unavailable"))
        check(lines.contains("value_read_result=not_attempted"))
    }

}
