#if os(macOS)
import SwiftUI
import KoeBridgeCore

private enum AmiVoiceVocabularyUI {
    static let copy = AmiVoiceVocabularyManagementCopy.self

    static func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.year(.defaultDigits).month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "ja_JP")))
    }

    static func tint(for state: AmiVoiceDictionaryEntryState?) -> Color {
        switch state {
        case .autoSynced: return .green
        case .pendingReview, .candidate: return .orange
        case .readyToSync: return .blue
        case .autoDisabled: return .purple
        case .syncFailed: return .red
        case .archived, .ignored: return .gray
        case nil: return .gray
        }
    }
}

/// Short status badge: label text plus a shape icon — never color alone (LST-07).
struct AmiVoiceVocabularyStatusBadge: View {
    let state: AmiVoiceDictionaryEntryState?
    var protected: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let state {
                Label(copy.statusLabel(for: state), systemImage: copy.statusSymbol(for: state))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AmiVoiceVocabularyUI.tint(for: state))
                    .help(copy.statusTooltip(for: state))
            }
            if protected {
                Label(copy.statusLabelProtected, systemImage: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
                    .help(copy.statusTooltipProtected)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private var copy: AmiVoiceVocabularyManagementCopy.Type { AmiVoiceVocabularyManagementCopy.self }
}

/// Compact sync-state line for the settings page: last result, the review
/// badge, quarantined count, the failed-reflection warning and its retry.
struct AmiVoiceSyncStatusSection: View {
    @ObservedObject var controller: VoiceController
    var onOpenManagement: () -> Void = {}
    var onOpenApiKey: () -> Void = {}
    @State private var syncInFlight = false

    private var key: AmiVoiceDictionaryProfileKey { controller.amiVoiceDictionaryProfileKey }
    private var status: AmiVoiceDictionarySyncStatus { controller.currentAmiVoiceDictionarySyncStatus }
    private var copy: AmiVoiceVocabularyManagementCopy.Type { AmiVoiceVocabularyManagementCopy.self }

    var body: some View {
        let summary = controller.amiVoiceVocabularyManagement.summary(for: key)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                statusLine
                Spacer(minLength: 0)
                if status.pendingReviewCount > 0 {
                    Label("\(copy.statusLabelPendingReview) \(status.pendingReviewCount)", systemImage: "questionmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                if status.quarantinedCount > 0 {
                    Label("\(copy.statusLabelSyncFailed) \(status.quarantinedCount)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                }
                if summary.autoDisabledCount > 0 {
                    Label("\(copy.statusLabelAutoDisabled) \(summary.autoDisabledCount)", systemImage: "pause.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.purple)
                }
            }
            syncErrorBanner
            if controller.amiVoiceVocabularyManagement.unreflectedSnapshot(for: key) != nil {
                HStack(spacing: 8) {
                    Label(copy.rollbackReflectionPending, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Button(copy.rollbackReflectionRetry) {
                        Task {
                            _ = await controller.amiVoiceVocabularyManagement.retryPendingReflection(for: key)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                syncInFlight = await controller.amiVoiceDictionarySyncInFlight()
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if syncInFlight {
            Label(copy.syncBarSyncing, systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            switch status.lastResult {
            case .temporaryFailure, .alreadyInFlight, .storeFailure:
                Label(copy.syncBarPending(status.pendingCount), systemImage: "wifi.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            case .success, .noChanges:
                if let lastSyncAt = status.lastSyncAt {
                    Label(copy.syncBarSynced(AmiVoiceVocabularyUI.timestamp(lastSyncAt)), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Label(copy.syncBarPending(status.pendingCount), systemImage: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            default:
                Label(copy.syncBarPending(status.pendingCount), systemImage: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// GD-469 03 §4 error classes surfaced as an in-page banner rather than a
    /// modal so dictation is never interrupted.
    @ViewBuilder private var syncErrorBanner: some View {
        switch status.lastErrorClass {
        case .authenticationMissing, .authenticationRejected:
            errorBanner(copy.syncErrorAuth, actionTitle: copy.syncErrorAuthButton, action: onOpenApiKey)
        case .capExceeded:
            errorBanner(copy.syncErrorCap, actionTitle: copy.syncErrorCapButton, action: onOpenManagement)
        case .validation:
            errorBanner(copy.syncErrorValidation(status.quarantinedCount), actionTitle: copy.syncErrorValidationButton, action: onOpenManagement)
        case .network, .timeout, .server, .profileMissing, .store, .unknown:
            if status.lastResult == .temporaryFailure {
                errorBanner(copy.syncErrorTemporary, actionTitle: copy.syncErrorTemporaryButton) {
                    Task { _ = await controller.amiVoiceVocabularyManagement.syncNow(for: key) }
                }
            }
        case nil:
            EmptyView()
        }
    }

    private func errorBanner(_ text: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
    }
}

/// First-run consent panel (GD-369 §1, verbatim). Agreement persists the
/// consent record and enables the feature; cancel leaves it OFF.
struct AmiVoiceSyncConsentPanel: View {
    let onAgree: () -> Void
    let onCancel: () -> Void
    let onShowDetails: () -> Void

    private var copy: AmiVoiceVocabularyManagementCopy.Type { AmiVoiceVocabularyManagementCopy.self }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(copy.consentTitle)
                .font(.system(size: 15, weight: .semibold))
            Text(copy.consentIntro)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                consentItem(title: copy.consentItemSentTitle, body: copy.consentItemSentBody)
                consentItem(title: copy.consentItemDestinationTitle, body: copy.consentItemDestinationBody)
                consentItem(title: copy.consentItemControlTitle, body: copy.consentItemControlBody)
            }
            Divider()
            HStack(spacing: 12) {
                Button(copy.consentAgreeButton, action: onAgree)
                    .buttonStyle(.borderedProminent)
                Button(copy.consentCancelButton, action: onCancel)
                Spacer()
                Button(copy.consentDetailsLink, action: onShowDetails)
                    .buttonStyle(.link)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 640)
    }

    private func consentItem(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 13, weight: .semibold))
            Text(LocalizedStringKey(body))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// The delete-all confirm sheet (GD-469 02 §3.4): scope choice plus the
/// local-only notice when sync is OFF.
struct AmiVoiceDeleteAllSheet: View {
    @ObservedObject var controller: VoiceController
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scope: AmiVoiceVocabularyDeleteAllScope = .serverOnly
    @State private var running = false

    private var copy: AmiVoiceVocabularyManagementCopy.Type { AmiVoiceVocabularyManagementCopy.self }

    var body: some View {
        let key = controller.amiVoiceDictionaryProfileKey
        let summary = controller.amiVoiceVocabularyManagement.summary(for: key)
        let syncEnabled = controller.amiVoiceDictionarySyncEnabled
        VStack(alignment: .leading, spacing: 14) {
            Text(copy.deleteAllTitle)
                .font(.system(size: 15, weight: .semibold))
            Text(copy.deleteAllBody(syncedCount: summary.syncedCount))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !syncEnabled {
                Label(copy.deleteAllSyncOffNotice, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Picker("", selection: $scope) {
                Text(copy.deleteAllOptionServerOnly).tag(AmiVoiceVocabularyDeleteAllScope.serverOnly)
                Text(copy.deleteAllOptionBoth).tag(AmiVoiceVocabularyDeleteAllScope.localAndServer)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(!syncEnabled)
            Divider()
            HStack {
                Spacer()
                Button(copy.consentCancelButton, role: .cancel) { dismiss() }
                Button(copy.deleteAllConfirmButton, role: .destructive) {
                    running = true
                    // With sync OFF the only meaningful operation is clearing
                    // the local list (the OFF notice says exactly that), so the
                    // scope choice collapses to `.localAndServer`.
                    let effectiveScope = syncEnabled ? scope : AmiVoiceVocabularyDeleteAllScope.localAndServer
                    Task {
                        let enabled = controller.amiVoiceDictionarySyncEnabled
                        let before = summary.totalCount
                        _ = await controller.amiVoiceVocabularyManagement.deleteAll(scope: effectiveScope, currentKey: key)
                        await MainActor.run {
                            running = false
                            onDone(enabled ? copy.deleteAllToast
                                    : (effectiveScope == .localAndServer ? copy.deleteAllOutcomeLocalOnly(before) : copy.deleteAllOutcomeLocalOnly(0)))
                            dismiss()
                        }
                    }
                }
                .disabled(running)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 620)
    }
}

/// Snapshot history + rollback (B-3). Rows older than the newest offer the
/// restore action; the confirm step uses the GD-469 02 §3.5 copy.
struct AmiVoiceSyncHistorySheet: View {
    @ObservedObject var controller: VoiceController
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmTarget: AmiVoiceDictionarySyncSnapshot?
    @State private var outcomeNotice = ""

    private var key: AmiVoiceDictionaryProfileKey { controller.amiVoiceDictionaryProfileKey }
    private var copy: AmiVoiceVocabularyManagementCopy.Type { AmiVoiceVocabularyManagementCopy.self }

    private var snapshots: [AmiVoiceDictionarySyncSnapshot] {
        controller.amiVoiceVocabularyManagement.snapshotHistory(for: key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(copy.rollbackHistoryTitle)
                .font(.system(size: 15, weight: .semibold))
            if controller.amiVoiceVocabularyManagement.unreflectedSnapshot(for: key) != nil {
                HStack(spacing: 8) {
                    Label(copy.rollbackReflectionPending, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Button(copy.rollbackReflectionRetry) {
                        Task { _ = await controller.amiVoiceVocabularyManagement.retryPendingReflection(for: key) }
                    }
                    .controlSize(.small)
                }
            }
            if !outcomeNotice.isEmpty {
                Text(outcomeNotice).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if snapshots.isEmpty {
                Text(copy.rollbackListEmpty)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(AmiVoiceVocabularyUI.timestamp(snapshot.createdAt))
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(copy.snapshotTriggerLabel(snapshot.trigger))・\(copy.snapshotStatusLabel(snapshot.status))・\(copy.snapshotWordCount(snapshot.entries.count))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if index > 0 {
                                Button(copy.rollbackToSnapshotButton(AmiVoiceVocabularyUI.timestamp(snapshot.createdAt))) {
                                    confirmTarget = snapshot
                                }
                                .controlSize(.small)
                                .disabled(!controller.amiVoiceDictionarySyncEnabled)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .frame(minHeight: 180)
            }
            if !controller.amiVoiceDictionarySyncEnabled {
                Text(copy.rollbackDisabledNotice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(copy.managementCloseButton) { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 320)
        .alert(item: $confirmTarget) { target in
            let list = snapshots
            let newer = list.first { $0.createdAt > target.createdAt && $0.id != target.id } ?? list.first
            let (addedCount, updatedCount, removedCount) = newer
                .map { AmiVoiceVocabularyManagement.snapshotDiff(newer: $0, older: target) } ?? (0, 0, 0)
            return Alert(
                title: Text(copy.rollbackTitle),
                message: Text(copy.rollbackBody(
                    lastSyncAt: newer.map { AmiVoiceVocabularyUI.timestamp($0.createdAt) } ?? "",
                    added: addedCount, updated: updatedCount, removed: removedCount
                )),
                primaryButton: .destructive(Text(copy.rollbackConfirmButton)) {
                    Task {
                        let outcome = await controller.amiVoiceVocabularyManagement.rollback(for: key, toSnapshotID: target.id)
                        await MainActor.run {
                            switch outcome.kind {
                            case .applied:
                                onDone(copy.rollbackToast)
                            case .appliedReflectionPending:
                                outcomeNotice = copy.rollbackReflectionPending
                            case .disabled:
                                outcomeNotice = copy.rollbackDisabledNotice
                            case .snapshotNotFound, .storeFailure:
                                outcomeNotice = copy.saveFailure
                            }
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }
}

/// Add/edit form (GD-469 02 §1). Saving is explicit; cancelling with dirty
/// fields asks first (§3.1). Issues render inline per GD-469 03 §3.
struct AmiVoiceVocabularyEntryForm: View {
    enum Mode {
        case add
        case edit(AmiVoiceDictionaryEntry)
    }

    @ObservedObject var controller: VoiceController
    let mode: Mode
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var written = ""
    @State private var spoken = ""
    @State private var alternativeSpoken = ""
    @State private var className = ""
    @State private var syncMode: AmiVoiceVocabularySaveMode = .sync
    @State private var issues: [AmiVoiceVocabularyFormIssue] = []
    @State private var confirmDiscard = false
    @State private var saving = false

    private var key: AmiVoiceDictionaryProfileKey { controller.amiVoiceDictionaryProfileKey }
    private var copy: AmiVoiceVocabularyManagementCopy.Type { AmiVoiceVocabularyManagementCopy.self }
    private var family: AmiVoiceDictionaryEngineFamily { AmiVoiceDictionaryEngineFamily(engine: key.engine) }
    private var existing: AmiVoiceDictionaryEntry? {
        if case .edit(let entry) = mode { return entry }
        return nil
    }
    private var initialSyncMode: AmiVoiceVocabularySaveMode {
        existing?.engineState(for: key)?.state == .ignored ? .excluded : .sync
    }
    private var dirty: Bool {
        written != (existing?.written ?? "")
            || spoken != (existing?.spoken ?? "")
            || className != (existing?.className ?? "")
            || alternativeSpoken != ""
            || syncMode != initialSyncMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? copy.formTitleAdd : copy.formTitleEdit)
                .font(.system(size: 15, weight: .semibold))
            formField(label: copy.formWrittenLabel, note: copy.formWrittenNote,
                      placeholder: copy.formWrittenPlaceholder, text: $written)
            if family == .hybrid {
                formField(label: copy.formReadingLabel, note: copy.formReadingNote,
                          placeholder: copy.formReadingPlaceholder, text: $spoken)
                formField(label: copy.formAlternativeReadingLabel, note: copy.formAlternativeReadingNote,
                          placeholder: copy.formAlternativeReadingPlaceholder, text: $alternativeSpoken)
            } else {
                Text(copy.columnReadingE2E)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            formField(label: copy.formClassLabel, note: copy.formClassNote,
                      placeholder: copy.formClassPlaceholder, text: $className)
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.formSyncModeLabel)
                    .font(.system(size: 13, weight: .medium))
                Picker("", selection: $syncMode) {
                    Text(copy.formSyncModeSync).tag(AmiVoiceVocabularySaveMode.sync)
                    Text(copy.formSyncModeExclude).tag(AmiVoiceVocabularySaveMode.excluded)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(copy.formSyncModeNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let existing,
               let source = controller.amiVoiceVocabularyManagement.learningSource(for: existing, learnedTerms: controller.learnedTerms) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.formLearningSourceLabel)
                        .font(.system(size: 12, weight: .medium))
                    Text(copy.learningSourceFallback(fragment: source.originalFragment, term: source.term))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(issues, id: \.self) { issue in
                Label(issue.message, systemImage: issue.isBlocking ? "exclamationmark.circle.fill" : "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(issue.isBlocking ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button(copy.formCancelButton) {
                    if dirty { confirmDiscard = true } else { dismiss() }
                }
                Spacer()
                Button(saving ? copy.formSaving : saveButtonTitle) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(minWidth: 500, idealWidth: 560, maxWidth: 640)
        .onAppear {
            if let existing {
                written = existing.written
                spoken = existing.spoken ?? ""
                className = existing.className ?? ""
                syncMode = initialSyncMode
            }
            revalidate()
        }
        .alert(copy.unsavedTitle, isPresented: $confirmDiscard) {
            Button(copy.unsavedSaveAndClose) { save() }
            Button(copy.unsavedContinueEditing, role: .cancel) {}
            Button(copy.unsavedDiscard, role: .destructive) { dismiss() }
        } message: {
            Text(copy.unsavedBody)
        }
        .onChange(of: written) { _ in revalidate() }
        .onChange(of: spoken) { _ in revalidate() }
        .onChange(of: alternativeSpoken) { _ in revalidate() }
    }

    private var saveButtonTitle: String {
        if existing != nil { return copy.formSaveEditButton }
        return controller.amiVoiceDictionarySyncEnabled ? copy.formSaveAddButton : copy.formSaveAddButtonSyncOff
    }

    private func formField(label: String, note: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 13, weight: .medium))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func revalidate() {
        let management = controller.amiVoiceVocabularyManagement
        var computed = management.validateForm(
            written: written,
            spoken: spoken,
            family: family,
            excluding: existing?.id
        )
        // Same alternative-reading branch `saveManualEntry` validates, so a
        // bad 別の読み surfaces inline instead of only on Save.
        let trimmedAlt = alternativeSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if family == .hybrid,
           !trimmedAlt.isEmpty,
           LearnedTermPolicy.normalized(trimmedAlt)
               != LearnedTermPolicy.normalized(spoken.trimmingCharacters(in: .whitespacesAndNewlines)) {
            computed += management.validateForm(
                written: written,
                spoken: trimmedAlt,
                family: family,
                excluding: existing?.id
            )
        }
        var seen = Set<AmiVoiceVocabularyFormIssue>()
        issues = computed.filter { seen.insert($0).inserted }
    }

    private func save() {
        saving = true
        Task {
            let outcome = await controller.amiVoiceVocabularyManagement.saveManualEntry(
                id: existing?.id,
                written: written,
                spoken: spoken,
                className: className,
                mode: syncMode,
                alternativeSpoken: alternativeSpoken,
                for: key
            )
            await MainActor.run {
                saving = false
                if outcome.saved {
                    let surface = AmiVoiceVocabularyManagement.normalizedWrittenForm(written)
                    onDone(controller.amiVoiceDictionarySyncEnabled
                           ? copy.savedToast(surface: surface)
                           : copy.savedToastSyncOff(surface: surface))
                    dismiss()
                } else {
                    issues = outcome.issues.isEmpty ? issues : outcome.issues
                    if issues.isEmpty {
                        issues = [.duplicatePair]
                    }
                }
            }
        }
    }
}

/// Review queue panel (GD-469 02 §2): hold reason + suggested reading chip +
/// approve (with optional reading edit) / exclude / later.
struct AmiVoiceReviewPanel: View {
    @ObservedObject var controller: VoiceController
    let row: AmiVoiceVocabularyRow
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reading: String
    @State private var info: AmiVoiceVocabularyReviewInfo
    @State private var issues: [AmiVoiceVocabularyFormIssue] = []

    private var key: AmiVoiceDictionaryProfileKey { controller.amiVoiceDictionaryProfileKey }
    private var copy: AmiVoiceVocabularyManagementCopy.Type { AmiVoiceVocabularyManagementCopy.self }
    private var family: AmiVoiceDictionaryEngineFamily { AmiVoiceDictionaryEngineFamily(engine: key.engine) }

    init(controller: VoiceController, row: AmiVoiceVocabularyRow, onDone: @escaping (String) -> Void) {
        self.controller = controller
        self.row = row
        self.onDone = onDone
        let management = controller.amiVoiceVocabularyManagement
        let derived = management.reviewInfo(
            for: row.entry, for: controller.amiVoiceDictionaryProfileKey,
            learnedTerms: controller.learnedTerms
        )
        _info = State(initialValue: derived)
        _reading = State(initialValue: derived.suggestedReading ?? row.entry.spoken ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(copy.reviewPanelTitle)
                .font(.system(size: 15, weight: .semibold))
            Text(row.entry.written)
                .font(.system(size: 14, weight: .medium))
            Text(info.reasonText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let suggested = info.suggestedReading, !suggested.isEmpty {
                Button(copy.reviewSuggestedChip(suggested)) {
                    reading = suggested
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text(copy.reviewNoSuggestion)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.formReadingLabel).font(.system(size: 13, weight: .medium))
                TextField(copy.formReadingPlaceholder, text: $reading)
                    .textFieldStyle(.roundedBorder)
            }
            ForEach(issues, id: \.self) { issue in
                Label(issue.message, systemImage: issue.isBlocking ? "exclamationmark.circle.fill" : "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(issue.isBlocking ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(spacing: 12) {
                Button(copy.reviewApproveButton) {
                    revalidate()
                    // The same validateForm gate as the entry form: a blocking
                    // issue keeps the panel open with inline issues and never
                    // fires the success toast.
                    guard !issues.contains(where: \.isBlocking) else { return }
                    Task {
                        _ = await controller.amiVoiceVocabularyManagement.approveReviewEntry(
                            id: row.entry.id, reading: reading, for: key
                        )
                        await MainActor.run {
                            onDone(copy.approveToast(surface: row.entry.written))
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                Button(copy.reviewExcludeButton) {
                    Task {
                        _ = await controller.amiVoiceVocabularyManagement.rejectReviewEntry(id: row.entry.id, for: key)
                        await MainActor.run {
                            onDone(copy.excludeToast(surface: row.entry.written))
                            dismiss()
                        }
                    }
                }
                Spacer()
                Button(copy.reviewLaterButton) { dismiss() }
                    .buttonStyle(.link)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 600)
        .onChange(of: reading) { _ in revalidate() }
    }

    private func revalidate() {
        issues = controller.amiVoiceVocabularyManagement.validateForm(
            written: row.entry.written,
            spoken: reading,
            family: family,
            excluding: row.entry.id
        )
    }
}

/// The vocabulary management surface (GD-469 01/02). All actions funnel into
/// `AmiVoiceVocabularyManagement`; no store access beyond its display surface.
struct AmiVoiceVocabularyManagementSheet: View {
    @ObservedObject var controller: VoiceController
    var onOpenApiKey: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var filter: AmiVoiceVocabularyListFilter = .all
    @State private var searchText = ""
    @State private var toastMessage = ""
    @State private var showConsent = false
    @State private var showDeleteAll = false
    @State private var showHistory = false
    @State private var confirmExclude: AmiVoiceVocabularyRow?
    @State private var confirmDelete: AmiVoiceVocabularyRow?
    @State private var confirmRollback = false
    @State private var editor: EditorTarget?

    enum EditorTarget: Identifiable {
        case add
        case edit(AmiVoiceDictionaryEntry)
        case review(AmiVoiceVocabularyRow)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let e): return "edit-" + e.id.uuidString
            case .review(let r): return "review-" + r.id.uuidString
            }
        }
    }

    private var key: AmiVoiceDictionaryProfileKey { controller.amiVoiceDictionaryProfileKey }
    private var copy: AmiVoiceVocabularyManagementCopy.Type { AmiVoiceVocabularyManagementCopy.self }
    private var management: AmiVoiceVocabularyManagement { controller.amiVoiceVocabularyManagement }
    private var family: AmiVoiceDictionaryEngineFamily { AmiVoiceDictionaryEngineFamily(engine: key.engine) }

    var body: some View {
        let summary = management.summary(for: key)
        let syncEnabled = controller.amiVoiceDictionarySyncEnabled
        let listRows = management.rows(for: key, filter: filter, query: searchText)
        VStack(alignment: .leading, spacing: 0) {
            header(summary: summary)
            Divider().padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 8) {
                guidanceBar(syncEnabled: syncEnabled)
                AmiVoiceSyncStatusSection(
                    controller: controller,
                    onOpenManagement: { filter = .syncFailed },
                    onOpenApiKey: onOpenApiKey
                )
                if summary.attentionCount > 0 {
                    attentionBanner(summary: summary)
                }
                capBanners(summary: summary)
            }
            .padding(.bottom, 8)
            if summary.totalCount == 0 {
                initialEmptyState(syncEnabled: syncEnabled)
            } else {
                searchAndTabs(summary: summary, filteredCount: listRows.count)
                if listRows.isEmpty {
                    filteredEmptyState
                } else {
                    entryList(listRows)
                }
            }
            if !toastMessage.isEmpty {
                Divider().padding(.vertical, 6)
                Text(toastMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560)
        .sheet(item: $editor) { target in
            switch target {
            case .add:
                AmiVoiceVocabularyEntryForm(controller: controller, mode: .add) { toastMessage = $0 }
            case .edit(let entry):
                AmiVoiceVocabularyEntryForm(controller: controller, mode: .edit(entry)) { toastMessage = $0 }
            case .review(let row):
                AmiVoiceReviewPanel(controller: controller, row: row) { toastMessage = $0 }
            }
        }
        .sheet(isPresented: $showConsent) {
            AmiVoiceSyncConsentPanel(
                onAgree: {
                    controller.agreeAmiVoiceDictionarySyncConsentAndEnable()
                    showConsent = false
                },
                onCancel: { showConsent = false },
                onShowDetails: {
                    showConsent = false
                    SettingsDestination.pending = "amivoice-privacy"
                    NotificationCenter.default.post(name: .settingsDestinationRequested, object: "amivoice-privacy")
                    dismiss()
                }
            )
        }
        .sheet(isPresented: $showDeleteAll) {
            AmiVoiceDeleteAllSheet(controller: controller) { toastMessage = $0 }
        }
        .sheet(isPresented: $showHistory) {
            AmiVoiceSyncHistorySheet(controller: controller) { toastMessage = $0 }
        }
        .alert(item: $confirmExclude) { row in
            Alert(
                title: Text(copy.excludeConfirmTitle(surface: row.entry.written)),
                message: Text(copy.excludeConfirmBody),
                primaryButton: .default(Text(copy.excludeConfirmButton)) {
                    Task {
                        _ = await management.excludeEntry(id: row.entry.id, for: key)
                        await MainActor.run { toastMessage = copy.excludeToast(surface: row.entry.written) }
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $confirmDelete) { row in
            Alert(
                title: Text(copy.deleteConfirmTitle(surface: row.entry.written)),
                message: Text(copy.deleteConfirmBody),
                primaryButton: .destructive(Text(copy.deleteConfirmButton)) {
                    Task {
                        _ = await controller.deleteAmiVoiceDictionaryEntry(row.entry.id)
                        await MainActor.run {
                            toastMessage = controller.amiVoiceDictionarySyncEnabled
                                ? copy.deleteToast(surface: row.entry.written)
                                : copy.deleteToastSyncOff(surface: row.entry.written)
                        }
                    }
                },
                secondaryButton: .cancel(Text(copy.deleteConfirmExcludeInstead)) {
                    Task {
                        _ = await management.excludeEntry(id: row.entry.id, for: key)
                        await MainActor.run { toastMessage = copy.excludeToast(surface: row.entry.written) }
                    }
                }
            )
        }
        .alert(copy.rollbackTitle, isPresented: $confirmRollback) {
            Button(copy.rollbackConfirmButton, role: .destructive) { performOneStepRollback() }
            Button(copy.consentCancelButton, role: .cancel) {}
        } message: {
            let snaps = management.snapshotHistory(for: key)
            if snaps.count >= 2 {
                let counts = AmiVoiceVocabularyManagement.snapshotDiff(newer: snaps[0], older: snaps[1])
                Text(copy.rollbackBody(
                    lastSyncAt: AmiVoiceVocabularyUI.timestamp(snaps[0].createdAt),
                    added: counts.added, updated: counts.updated, removed: counts.removed
                ))
            } else {
                Text(copy.rollbackListEmpty)
            }
        }
    }

    // MARK: - Header (GD-469 01 §1)

    private func header(summary: AmiVoiceVocabularyListSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text(copy.managementTitle)
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button(copy.addEntryButton) { editor = .add }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                Menu {
                    Button(copy.menuSyncNow) {
                        Task { _ = await management.syncNow(for: key) }
                    }
                    .disabled(!controller.amiVoiceDictionarySyncEnabled)
                    Button(copy.menuRollback) { confirmRollback = true }
                        .disabled(!controller.amiVoiceDictionarySyncEnabled
                                  || management.snapshotHistory(for: key).count < 2)
                    Button(copy.rollbackHistoryTitle) { showHistory = true }
                    Divider()
                    Button(copy.menuDeleteAll, role: .destructive) { showDeleteAll = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
            Text(copy.managementSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(copy.countSummary(active: summary.activeCount))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Guidance bar (GD-469 01 §2)

    @ViewBuilder private func guidanceBar(syncEnabled: Bool) -> some View {
        if !controller.hasAmiVoiceKey {
            guidanceRow(copy.engineBarAuthMissing, action: copy.engineBarAuthAction) {
                onOpenApiKey()
                dismiss()
            }
        } else if !syncEnabled {
            guidanceRow(copy.engineBarSyncOff, action: copy.engineBarSyncOffAction) {
                if controller.hasAmiVoiceDictionarySyncConsent {
                    controller.amiVoiceDictionarySyncEnabled = true
                } else {
                    showConsent = true
                }
            }
        } else if family == .hybrid {
            guidanceRow(copy.engineBarHybrid, action: copy.engineBarHybridAction) {
                SettingsDestination.pending = "amivoice-apikey"
                NotificationCenter.default.post(name: .settingsDestinationRequested, object: "amivoice-apikey")
                dismiss()
            }
        } else {
            guidanceRow(copy.engineBarE2E, action: copy.engineBarE2EAction) {
                SettingsDestination.pending = "amivoice-engine"
                NotificationCenter.default.post(name: .settingsDestinationRequested, object: "amivoice-engine")
                dismiss()
            }
        }
    }

    private func guidanceRow(_ text: String, action: String, actionHandler: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action, action: actionHandler)
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Banners (GD-469 01 §3/§5)

    private func attentionBanner(summary: AmiVoiceVocabularyListSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(.orange)
            Text(copy.attentionBanner(summary.attentionCount))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(copy.attentionBannerButton) { filter = .pendingReview }
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func capBanners(summary: AmiVoiceVocabularyListSummary) -> some View {
        if summary.hardCapReached {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.hardCapTitle).font(.system(size: 12, weight: .semibold))
                    Text(copy.hardCapBody).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button(copy.hardCapButton) { filter = .all }
                    .controlSize(.small)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        } else if summary.softCapExceeded {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.softCapTitle(active: summary.activeCount)).font(.system(size: 12, weight: .semibold))
                    Text(copy.softCapBody).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button(copy.softCapButton) { filter = .archived }
                    .controlSize(.small)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Search + tabs (GD-469 01 §4)

    private func searchAndTabs(summary: AmiVoiceVocabularyListSummary, filteredCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(copy.searchPlaceholder, text: $searchText)
                    .textFieldStyle(.roundedBorder)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copy.searchClearLabel)
                }
            }
            Picker("", selection: $filter) {
                ForEach(AmiVoiceVocabularyListFilter.allCases, id: \.self) { option in
                    Text(option == .pendingReview
                         ? copy.filterTabPendingReview(summary.pendingReviewCount)
                         : option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if filter != .all || !searchText.isEmpty {
                HStack {
                    Text(copy.filteredSummary(total: summary.totalCount, filtered: filteredCount))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(copy.resetFilterButton) { filter = .all; searchText = "" }
                        .controlSize(.small)
                }
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - List (GD-469 01 §4/§3)

    private func entryList(_ rows: [AmiVoiceVocabularyRow]) -> some View {
        List {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.entry.written)
                                .font(.system(size: 13, weight: .medium))
                            if family == .hybrid {
                                Text(row.entry.spoken ?? "—")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Text(copy.lastUpdatedLabel(AmiVoiceVocabularyUI.timestamp(row.entry.updatedAt)))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                        AmiVoiceVocabularyStatusBadge(state: row.state, protected: row.entry.isProtected)
                        rowActions(row)
                    }
                    if row.state == .autoDisabled {
                        quarantineNotice(row)
                    }
                    if row.state == .pendingReview || row.state == .candidate {
                        reviewHint(row)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder private func rowActions(_ row: AmiVoiceVocabularyRow) -> some View {
        HStack(spacing: 6) {
            switch row.state {
            case .pendingReview, .candidate:
                Button(copy.rowActionReview) { editor = .review(row) }.controlSize(.small)
            case .autoDisabled:
                Button(copy.quarantineRestoreButton) {
                    Task {
                        _ = await management.restoreEntry(id: row.entry.id, for: key)
                        await MainActor.run { toastMessage = copy.quarantineRestoredToast(surface: row.entry.written) }
                    }
                }.controlSize(.small)
                Button(copy.quarantineEditButton) { editor = .edit(row.entry) }.controlSize(.small)
            case .ignored:
                Button(copy.restoreExcludedButton) {
                    Task {
                        _ = await management.restoreEntry(id: row.entry.id, for: key)
                        await MainActor.run { toastMessage = copy.undoExcludedToast(surface: row.entry.written) }
                    }
                }.controlSize(.small)
            case .syncFailed:
                Button(copy.rowActionEdit) { editor = .edit(row.entry) }.controlSize(.small)
            default:
                Button(copy.rowActionEdit) { editor = .edit(row.entry) }.controlSize(.small)
            }
            if row.state != .ignored && row.state != .archived {
                Button(copy.rowActionExclude) { confirmExclude = row }.controlSize(.small)
            }
            Button(copy.rowActionDelete) { confirmDelete = row }
                .controlSize(.small)
                .foregroundStyle(.red)
        }
    }

    private func quarantineNotice(_ row: AmiVoiceVocabularyRow) -> some View {
        let info = management.quarantineInfo(for: row)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "pause.circle").foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.quarantineNotice(surface: row.entry.written))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let info, info.occurrenceCount > 0 {
                    Text(info.detail ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private func reviewHint(_ row: AmiVoiceVocabularyRow) -> some View {
        let info = management.reviewInfo(
            for: row.entry, for: key, learnedTerms: controller.learnedTerms
        )
        return Text(info.reasonText)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Empty states (GD-469 01 §7)

    private func initialEmptyState(syncEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(syncEnabled ? copy.emptyOnTitle : copy.emptyOffTitle)
                .font(.system(size: 14, weight: .semibold))
            Text(syncEnabled ? copy.emptyOnBody : copy.emptyOffBody)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(syncEnabled ? copy.emptyOnAssurance : copy.emptyOffAssurance)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if syncEnabled {
                Text(copy.emptyOnHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button(copy.emptyPrimaryButton) { editor = .add }
                    .buttonStyle(.borderedProminent)
                if !syncEnabled {
                    Button(copy.emptyOffSecondaryLink) { dismiss() }
                        .buttonStyle(.link)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var filteredEmptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.emptyFilteredTitle)
                .font(.system(size: 14, weight: .semibold))
            Text(copy.emptyFilteredBody)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(copy.resetFilterButton) { filter = .all; searchText = "" }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Rollback quick action

    private func performOneStepRollback() {
        let snaps = management.snapshotHistory(for: key)
        guard snaps.count >= 2 else { return }
        let target = snaps[1]
        Task {
            let outcome = await management.rollback(for: key, toSnapshotID: target.id)
            await MainActor.run {
                switch outcome.kind {
                case .applied:
                    toastMessage = copy.rollbackToast
                case .appliedReflectionPending:
                    toastMessage = copy.rollbackReflectionPending
                case .disabled:
                    toastMessage = copy.rollbackDisabledNotice
                case .snapshotNotFound, .storeFailure:
                    toastMessage = copy.saveFailure
                }
            }
        }
    }
}
#endif
