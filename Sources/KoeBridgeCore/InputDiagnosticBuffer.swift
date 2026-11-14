import Foundation

/// A short in-memory trace for one recording. The original capture and the
/// most recent failure evidence survive a long stream of repeated AX failures.
/// Milestones protect the actual send plan and read-back expectation from being
/// evicted by repetitive successful AX calls. No text is retained.
public struct InputDiagnosticBuffer: Sendable {
    public static let maximumEvents = 128
    public static let preservedInitialEvents = 32

    public struct Entry: Equatable, Sendable {
        public let sequence: Int
        public let elapsedMS: Int
        public let event: InputDiagnosticEvent
    }

    public let takeID: UUID
    public private(set) var entries: [Entry] = []
    public private(set) var droppedCount = 0
    public private(set) var totalCount = 0
    public var retainedCount: Int { entries.count }
    /// Finite slots bound both retention and the human-readable summary. A slot
    /// points to a real event; it never invents a successful operation.
    private enum Milestone: String, CaseIterable, Sendable {
        case requested, target, captured, recognition, preflight, focus
        case before, payload, posted, expected, firstObserved = "first_observed"
        case observed, counts, result, firstReconcile = "first_reconcile", reconcile
        case capability, eligibility, progress, observation, firstCheckpoint = "first_checkpoint", checkpoint
    }
    private var milestones: [Milestone: Entry] = [:]

    private mutating func observeMilestone(_ entry: Entry) {
        let event = entry.event
        let fields = event.fields
        switch (event.kind, event.stage) {
        case (.eligibility, _): milestones[.eligibility] = entry
        case (.progress, _): milestones[.progress] = entry
        case (.observation, _): milestones[.observation] = entry
        case (.snapshot, .preflight) where fields[.receiptSkippedReason] != nil:
            milestones[.capability] = entry
            if fields[.selectionStart] != nil { milestones[.before] = entry }
        case (.focus, .posting) where fields[.chunkOrdinal] != nil:
            if milestones[.firstCheckpoint] == nil { milestones[.firstCheckpoint] = entry }
            milestones[.checkpoint] = entry
        case (.session, .requested) where fields[.build] != nil:
            milestones[.requested] = entry
        case (.target, .capture) where fields[.app] != nil:
            milestones[.target] = entry
        case (.snapshot, .capture) where fields[.selectionStart] != nil:
            milestones[.captured] = entry
        case (.session, .result) where fields[.recognizedUTF16] != nil:
            milestones[.recognition] = entry
        case (.session, .preflight):
            milestones[.preflight] = entry
        case (.focus, .preflight):
            milestones[.focus] = entry
        case (.snapshot, .preflight) where fields[.selectionStart] != nil:
            milestones[.before] = entry
        case (.payload, .posting) where fields[.modifiers] != nil:
            milestones[.payload] = entry
        case (.payload, .posting) where fields[.eventsPosted] != nil:
            milestones[.posted] = entry
        case (.receipt, .receipt) where fields[.timeoutMS] != nil:
            milestones[.expected] = entry
        case (.snapshot, .receipt) where fields[.selectionStart] != nil:
            if milestones[.firstObserved] == nil { milestones[.firstObserved] = entry }
            milestones[.observed] = entry
        case (.receipt, .receipt) where fields[.textMismatch] != nil:
            milestones[.counts] = entry
        case (.result, _):
            milestones[.result] = entry
        case (.reconcile, .reconcile):
            if milestones[.firstReconcile] == nil { milestones[.firstReconcile] = entry }
            milestones[.reconcile] = entry
        default: break
        }
    }

    public init(takeID: UUID) { self.takeID = takeID }

    public mutating func append(_ event: InputDiagnosticEvent, elapsedMS: Int) {
        if totalCount < Int.max { totalCount += 1 }
        let entry = Entry(sequence: totalCount, elapsedMS: max(0, elapsedMS), event: event)
        observeMilestone(entry)
        entries.append(entry)
        if entries.count > Self.maximumEvents {
            // A fixed number of slots cannot occupy the entire 96-event tail.
            // Retain first capture evidence AND decisions around actual posting.
            let protected = Set(milestones.values.map(\.sequence))
            if let removal = entries.indices.dropFirst(Self.preservedInitialEvents)
                .first(where: { !protected.contains(entries[$0].sequence) }) {
                entries.remove(at: removal)
            }
            if droppedCount < Int.max { droppedCount += 1 }
        }
    }

    public func renderedLines() -> [String] {
        guard !entries.isEmpty else { return [] }
        let metadata = InputDiagnosticEvent(kind: .session, stage: .requested, fields: [
            .retained: .integer(retainedCount), .dropped: .integer(droppedCount), .total: .integer(totalCount)
        ])
        let summary = Entry(sequence: 0, elapsedMS: 0, event: metadata)
        let trace = ([summary] + entries).flatMap { render($0) }
        // Emit summaries last so final outcomes remain near the end of the
        // existing rotated log. The prefix timestamp is still flush time;
        // uptime_ms and t_ms are the original event's times, not wall-clock guesses.
        let summaries = Milestone.allCases.flatMap { section -> [String] in
            guard let entry = milestones[section] else { return [] }
            return render(entry, section: section)
        }
        return trace + summaries
    }

    /// A flush consumes the trace in both cases. Turning diagnostics back on
    /// cannot resurrect evidence invalidated by an earlier OFF or deletion.
    public mutating func drain(consent: InputDiagnosticConsent,
                               token: InputDiagnosticConsent.Token?) -> [String] {
        defer { discard() }
        return consent.allows(token) ? renderedLines() : []
    }

    public mutating func discard() {
        entries.removeAll(keepingCapacity: false)
        droppedCount = 0
        totalCount = 0
        milestones.removeAll(keepingCapacity: false)
    }

    private func render(_ entry: Entry, section: Milestone? = nil) -> [String] {
        let event = entry.event
        let family = section.map { "input_summary v=2 section=\($0.rawValue)" } ?? "input_diag v=1"
        let prefix = "\(family) take=\(takeID.uuidString.lowercased()) event=\(entry.sequence) t_ms=\(entry.elapsedMS) stage=\(event.stage.rawValue) kind=\(event.kind.rawValue)"
        let fields = event.renderedFields.map { field -> String in
            // A snapshot's expected_start is the FIRST of two AX reads, NOT
            // the planned post-input caret. Disambiguate only the new summary;
            // v1 trace fields retain their original wire meaning.
            guard section != nil, event.kind == .snapshot else { return field }
            if field.hasPrefix("expected_start=") {
                return "first_read_start=" + field.dropFirst("expected_start=".count)
            }
            if field.hasPrefix("expected_length=") {
                return "first_read_length=" + field.dropFirst("expected_length=".count)
            }
            return field
        }
        // At most one part per field. Reserve the largest possible part marker
        // before packing, then render the actual count without moving fields.
        let width = String(max(1, fields.count)).count
        let digits = String(repeating: "9", count: width)
        let reserve = " part=\(digits)/\(digits) "
        let capacity = DiagnosticLogPolicy.maximumEventBytes - prefix.utf8.count - reserve.utf8.count
        var parts: [String] = []
        var current = ""
        for field in fields {
            let combined = current.isEmpty ? field : current + " " + field
            if !current.isEmpty && combined.utf8.count > capacity {
                parts.append(current)
                current = field
            } else {
                current = combined
            }
        }
        if !current.isEmpty || parts.isEmpty { parts.append(current) }
        return parts.enumerated().map { index, part in
            prefix + " part=\(index + 1)/\(parts.count)" + (part.isEmpty ? "" : " " + part)
        }
    }
}

/// Permission to retain and flush one opt-in trace. The macOS wrapper changes
/// this value on every toggle and explicit deletion, on its serial owner.
public struct InputDiagnosticConsent: Sendable {
    public struct Token: Equatable, Sendable {
        fileprivate let epoch: UUID
    }

    public private(set) var isEnabled: Bool
    private var epoch = UUID()

    public init(enabled: Bool = false) { isEnabled = enabled }

    public var token: Token? { isEnabled ? Token(epoch: epoch) : nil }

    public mutating func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        invalidate()
    }

    /// Deletion revokes outstanding traces even when logging remains enabled.
    public mutating func invalidate() { epoch = UUID() }

    public func allows(_ token: Token?) -> Bool {
        guard isEnabled, let token else { return false }
        return token.epoch == epoch
    }
}
