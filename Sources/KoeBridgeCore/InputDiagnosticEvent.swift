import Foundation

/// Content-free evidence from the checks that direct input actually performed.
/// No free-form text, field contents, titles, URLs or content hashes are accepted.
public struct InputDiagnosticEvent: Equatable, Sendable {
    public enum Stage: String, CaseIterable, Sendable {
        case requested, capture, preflight, posting, receipt, reconcile, result
    }

    public enum Kind: String, CaseIterable, Sendable {
        case session, target, ax, focus, snapshot, payload, receipt, reconcile, result
        case eligibility, progress, observation
    }

    public enum Field: String, CaseIterable, Hashable, Sendable {
        case operation, scope, error
        case timeoutError = "timeout_error"
        case resetError = "reset_error"
        case timeoutMS = "timeout_ms"
        case elapsedMS = "elapsed_ms"
        case uptimeMS = "uptime_ms"
        case reason
        case priorReason = "prior_reason"
        case outcome, pid
        case frontPID = "front_pid"
        case app, role, subrole
        case selectionKind = "selection_kind"
        case window, element, owner, selection, text
        case valueUTF16 = "value_utf16"
        case selectionStart = "selection_start"
        case selectionLength = "selection_length"
        case expectedStart = "expected_start"
        case expectedLength = "expected_length"
        case originalSelection = "original_selection"
        case requireOriginalSelection = "require_original_selection"
        case selectionComparison = "selection_comparison"
        case chunkOrdinal = "chunk_ordinal"
        case selectionRead = "selection_read"
        case valueReadAttempted = "value_read_attempted"
        case valueReadResult = "value_read_result"
        case exactBaselineAvailable = "exact_baseline_available"
        case receiptSkippedReason = "receipt_skipped_reason"
        case receiverObservation = "receiver_observation"
        case pacingProfile = "pacing_profile"
        case pacingVersion = "pacing_version"
        case pacingGapMS = "pacing_gap_ms"
        case pacingBudgetMS = "pacing_budget_ms"
        case pacingBudgetExceeded = "pacing_budget_exceeded"
        case lastPostedOrdinal = "last_posted_ordinal"
        case gapCount = "gap_count"
        case requestedGapMinUS = "requested_gap_min_us"
        case requestedGapMaxUS = "requested_gap_max_us"
        case requestedGapLastUS = "requested_gap_last_us"
        case actualGapMinUS = "actual_gap_min_us"
        case actualGapMaxUS = "actual_gap_max_us"
        case actualGapLastUS = "actual_gap_last_us"
        case postingStallTotalUS = "posting_stall_total_us"
        case abortPhase = "abort_phase"
        case abortReason = "abort_reason"
        case axTrusted = "ax_trusted"
        case postAllowed = "post_allowed"
        case plannedChunks = "planned_chunks"
        case sentChunks = "sent_chunks"
        case polls
        case remainingMS = "remaining_ms"
        case waitMS = "wait_ms"
        case captureAgeMS = "capture_age_ms"
        case relatedTake = "related_take"
        case eventsPosted = "events_posted"
        case receiptAvailable = "receipt_available"
        case capturedDuring = "captured_during"
        case modifiers
        case hardwareModifiers = "hardware_modifiers"
        case suppressed
        case shouldPaste = "should_paste"
        case requiresReview = "requires_review"
        case pending, unchanged
        case textMismatch = "text_mismatch"
        case selectionMismatch = "selection_mismatch"
        case unavailable
        case deadlineExceeded = "deadline_exceeded"
        case budgetInsufficient = "budget_insufficient"
        case vocabularyCount = "vocabulary_count", registeredTerms = "registered_terms", topicTerms = "topic_terms"
        case recognizedUTF16 = "recognized_utf16"
        case textCheck = "text_check"
        case audioRecheck = "audio_recheck"
        case engine, style, build
        case osMajor = "os_major"
        case osMinor = "os_minor"
        case osPatch = "os_patch"
        case queueWaitMS = "queue_wait_ms"
        case acoustic, audioFrames = "audio_frames", activeFrames = "active_frames"
        case maxRMSPPM = "max_rms_ppm", modulationPct = "modulation_pct", invalidSamples = "invalid_samples"
        case totalMS = "total_ms"
        case retained, dropped, total
    }

    /// Every string written by a diagnostic is a finite schema code, except a
    /// separately validated application bundle identifier. Add codes here;
    /// never interpolate a platform error description or an AX attribute value.
    public enum Token: String, CaseIterable, Sendable {
        case ok, same, different, unavailable, missing
        case invalidType = "invalid_type"
        case secure
        case tooLarge = "too_large"
        case invalidRange = "invalid_range"
        case selectionMoved = "selection_moved"
        case numericRange = "numeric_range"
        case textMarker = "text_marker"
        case none, unknown, application, system
        case focusedElement = "focused_element"
        case focusedWindow = "focused_window"
        case selectedRange = "selected_range"
        case selectedMarker = "selected_marker"
        case subrole, value, owner, rebased, blocked, unchanged
        case verified, unconfirmed, partial, cancelled, skipped
        case gemini, apple, agent, verbatim, readable
        case nearSilence = "near_silence"
        case uncertain, activity
        case preflight, posting, receipt
        case numericSelectionV1 = "numeric_selection_v1"
        case unobservableSelectionV1 = "unobservable_selection_v1"
        case valueOnly = "value_only"
        case markerNotNumeric = "marker_not_numeric"
        case selectionMissing = "selection_missing"
        case selectionUnavailable = "selection_unavailable"
        case valueUnavailable = "value_unavailable"
        case snapshotInvalid = "snapshot_invalid"
        case noObservableDelta = "no_observable_delta"
        case snapshotAvailable = "snapshot_available"

        // Current capture, preflight, transport and receipt reasons. Unknown
        // future strings deliberately become `unknown` until reviewed here.
        case accessibilityNotGranted = "accessibility_not_granted"
        case noFrontmostApplication = "no_frontmost_application"
        case koebridgeWindowIsFrontmost = "koebridge_window_is_frontmost"
        case focusedTextElementUnavailable = "focused_text_element_unavailable"
        case focusOwnerMismatch = "focus_owner_mismatch"
        case priorInputUnverified = "prior_input_unverified"
        case activeAppChanged = "active_app_changed"
        case focusedElementMissingOnRecheck = "focused_element_missing_on_recheck"
        case focusedFieldChanged = "focused_field_changed"
        case focusedWindowChanged = "focused_window_changed"
        case focusedElementOwnerChanged = "focused_element_owner_changed"
        case caretOrSelectionChanged = "caret_or_selection_changed"
        case focusVerificationFailed = "focus_verification_failed"
        case deliveryCancelledBeforePost = "delivery_cancelled_before_post"
        case emptyTypingPayload = "empty_typing_payload"
        case postEventPermissionMissing = "post_event_permission_missing"
        case targetNotCaptured = "target_not_captured"
        case fieldValueUnavailableOnRecheck = "field_value_unavailable_on_recheck"
        case fieldValueOrSelectionChanged = "field_value_or_selection_changed"
        case eventSourceUnavailable = "event_source_unavailable"
        case deliveryCancelledAfterPartialPost = "delivery_cancelled_after_partial_post"
        case keyboardEventUnavailable = "keyboard_event_unavailable"
        case postedWithoutObservableEdit = "posted_without_observable_edit"
        case deliveryCancelledAfterPost = "delivery_cancelled_after_post"
        case postedReceiptTimeout = "posted_receipt_timeout"
        case verifiedValueAndSelection = "verified_value_and_selection"
        case postedThenPriorInputUnverified = "posted_then_prior_input_unverified"
        case postedThenActiveAppChanged = "posted_then_active_app_changed"
        case postedThenFocusedElementMissingOnRecheck = "posted_then_focused_element_missing_on_recheck"
        case postedThenFocusedFieldChanged = "posted_then_focused_field_changed"
        case postedThenFocusedWindowChanged = "posted_then_focused_window_changed"
        case postedThenFocusedElementOwnerChanged = "posted_then_focused_element_owner_changed"
        case postedThenCaretOrSelectionChanged = "posted_then_caret_or_selection_changed"
        case postedThenFocusVerificationFailed = "posted_then_focus_verification_failed"
        case automaticPasteDisabled = "automatic_paste_disabled"
        case systemInterrupted = "system_interrupted"
        case reviewRequired = "review_required"
        case recognitionFailed = "recognition_failed"
        case noInput = "no_input"
        case acousticReviewRequired = "acoustic_review_required"
        case systemSuppressed = "system_suppressed"
        case automaticInputDisabled = "automatic_input_disabled"
        case notAttempted = "not_attempted"
        case noEventsPosted = "no_events_posted"
        case alreadyBlocked = "already_blocked"
        case unrelatedTarget = "unrelated_target"
        case ambiguousTarget = "ambiguous_target"
        case priorReceiptUnavailable = "prior_receipt_unavailable"
        case candidateSnapshotUnavailable = "candidate_snapshot_unavailable"
        case invalidCandidateSnapshot = "invalid_candidate_snapshot"
        case candidateEditUnmatched = "candidate_edit_unmatched"
        case rebaseFailed = "rebase_failed"
        case verifiedPriorInput = "verified_prior_input"
        case focusOwnerUnavailable = "focus_owner_unavailable"
        case frontmostApplicationUnavailable = "frontmost_application_unavailable"
        case focusedElementUnavailableOnRecheck = "focused_element_unavailable_on_recheck"
        case focusedWindowUnavailableOnRecheck = "focused_window_unavailable_on_recheck"
        case focusedWindowInvalidOnRecheck = "focused_window_invalid_on_recheck"
        case focusedElementOwnerUnavailable = "focused_element_owner_unavailable"
        case selectionUnavailableOnRecheck = "selection_unavailable_on_recheck"
        case capturedSelectionInvalid = "captured_selection_invalid"
        case selectionValueInvalidOnRecheck = "selection_value_invalid_on_recheck"
        case postedThenFrontmostApplicationUnavailable = "posted_then_frontmost_application_unavailable"
        case postedThenFocusedElementUnavailableOnRecheck = "posted_then_focused_element_unavailable_on_recheck"
        case postedThenFocusedWindowUnavailableOnRecheck = "posted_then_focused_window_unavailable_on_recheck"
        case postedThenFocusedWindowInvalidOnRecheck = "posted_then_focused_window_invalid_on_recheck"
        case postedThenFocusedElementOwnerUnavailable = "posted_then_focused_element_owner_unavailable"
        case postedThenSelectionUnavailableOnRecheck = "posted_then_selection_unavailable_on_recheck"
        case postedThenCapturedSelectionInvalid = "posted_then_captured_selection_invalid"
        case postedThenSelectionValueInvalidOnRecheck = "posted_then_selection_value_invalid_on_recheck"
        // These are the fixed raw values of InputReceiptObservation.
        case invalidSnapshot, notComparable, matches, selectionMismatch, textMismatch
    }

    public enum Value: Equatable, Sendable {
        case integer(Int)
        case flag(Bool)
        case token(Token)
        case identifier(UUID)
        /// Only use a bundle identifier obtained from the actual target app.
        /// Validation happens before the event retains or renders this value.
        case application(String)

        /// A finite allowlist, not a sanitizer for arbitrary diagnostic prose.
        public static func reason(_ code: String) -> Self {
            .token(Token(rawValue: code) ?? .unknown)
        }

        fileprivate var normalized: Self {
            guard case .application(let identifier) = self else { return self }
            let bytes = identifier.utf8
            guard !bytes.isEmpty, bytes.count <= 96,
                  identifier.contains("."),
                  !identifier.split(separator: ".", omittingEmptySubsequences: false).contains(where: { $0.isEmpty }),
                  bytes.allSatisfy({ byte in
                      (65...90).contains(byte) || (97...122).contains(byte)
                          || (48...57).contains(byte) || byte == 46 || byte == 45 || byte == 95
                  }) else { return .token(.unknown) }
            return self
        }

        fileprivate var rendered: String {
            switch normalized {
            case .integer(let value): return String(value)
            case .flag(let value): return value ? "1" : "0"
            case .token(let value): return value.rawValue
            case .identifier(let value): return value.uuidString.lowercased()
            case .application(let value): return value
            }
        }
    }

    public let kind: Kind
    public let stage: Stage
    public let fields: [Field: Value]

    public init(kind: Kind, stage: Stage, fields: [Field: Value]) {
        self.kind = kind
        self.stage = stage
        self.fields = fields.mapValues(\.normalized)
    }

    /// Values contain no whitespace or delimiter escapes; each field remains
    /// atomic when a long event is split across bounded physical log lines.
    var renderedFields: [String] {
        fields.keys.sorted { $0.rawValue < $1.rawValue }.map {
            "\($0.rawValue)=\(fields[$0]!.rendered)"
        }
    }
}
