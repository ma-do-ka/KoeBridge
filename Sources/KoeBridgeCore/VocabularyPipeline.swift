import Foundation

// VocabularyTermType is defined in VocabularyReadingGeneration.swift

/// Outcome of the candidate pipeline for a LearnedTerm.
public enum VocabularyCandidateOutcome: Equatable, Sendable {
    /// Safe to hand to the sync engine as ready_to_sync.
    case ready(VocabularyCandidate)
    /// Plausible but not safe to auto-register; hold queue will display.
    case pendingReview(VocabularyHoldReason, VocabularyCandidate)
    /// Must never be registered (noise, out‑of‑scope, forbidden cases).
    case excluded(VocabularyExclusionReason)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isPendingReview: Bool {
        if case .pendingReview = self { return true }
        return false
    }

    public var isExcluded: Bool {
        if case .excluded = self { return true }
        return false
    }
}

/// Candidate data passed to the sync engine or the hold queue.
public struct VocabularyCandidate: Equatable, Sendable {
    /// The normalized written form (after intake normalization).
    public let written: String
    /// The generated reading for Hybrid engine spoken field.
    public let reading: String
    /// The term's type classification.
    public let type: VocabularyTermType
    /// Original LearnedTerm ID for provenance.
    public let learnedTermID: UUID
    /// Creation timestamp (inherited from LearnedTerm).
    public let createdAt: Date
    /// Source record ID if available.
    public let sourceRecordID: UUID?
}

/// Reasons why a candidate is held for manual review.
public enum VocabularyHoldReason: Equatable, Sendable {
    // Stage 1 (Intake) – normalization yields a form that needs review.
    case writtenContainsForbiddenCharacters
    case writtenEmptyAfterNormalization
    case punctuationOnlyRewrite
    case sameSoundOrthographyChange // e.g., 子供 → 子ども
    case fillerOrParticleInclusion // えーと霧峰 → 霧峰

    // Stage 2 (Type classification) – none; classification is deterministic.

    // Stage 3 (Reading generation) – Phase 1 local rules only.
    case readingGenerationUnavailable
    case invalidWrittenCharacters
    case ambiguousAlphabetReading
    case numericReadingAmbiguous
    case phoneticDivergence // Y_before vs Y_after mismatch

    // Stage 4 (Quality guards)
    case shortReadingGuard // 1–2 mora
    case longReadingGuard // >20 mora
    case duplicateReadingCollision // same reading, different written, same class context
    case readingCharacterInvalid // non‑kana characters in reading
    case capExceededSoft // provisional soft cap (800)
    case capExceededSafety // safety cap (1,000)
}

/// Reasons why a candidate is excluded entirely.
public enum VocabularyExclusionReason: Equatable, Sendable {
    case noiseOnly // punctuation‑only changes, expression rewrites
    case outOfDictionaryScope // same‑sound orthography unification
    case writtenTooLong // exceeds AmiVoice length limit (60 chars)
    case invalidCharactersCannotSanitize // | or : that cannot be safely removed
}

/// The complete pipeline from a LearnedTerm to a candidate outcome.
public struct VocabularyCandidatePipeline {
    /// Configuration for threshold constants (placeholder values per OQ-06).
    public struct Configuration: Sendable {
        public var shortReadingMoraThreshold: Int = 2          // 1–2 mora → hold
        public var longReadingMoraThreshold: Int = 20         // >20 mora → hold
        public var softCap: Int = 800
        public var safetyCap: Int = 1000

        public static let `default` = Configuration()
    }

    private let config: Configuration
    private let candidateSetTracker: CandidateSetTracker?

    /// - Parameters:
    ///   - config: Guard thresholds.
    ///   - candidateSetTracker: Tracker that holds already-processed candidates and their readings.
    ///   - registeredEntries: Words already registered in the target profile, as
    ///     (written, reading) pairs. They make the duplicate-reading guard aware of
    ///     existing words (GD-308 BND-G02) without counting toward the dictionary caps.
    ///     An empty list keeps the previous behaviour exactly.
    public init(
        config: Configuration = .default,
        candidateSetTracker: CandidateSetTracker? = nil,
        registeredEntries: [(written: String, reading: String)] = []
    ) {
        self.config = config
        let tracker: CandidateSetTracker?
        if let candidateSetTracker {
            tracker = candidateSetTracker
        } else if registeredEntries.isEmpty {
            tracker = nil
        } else {
            tracker = CandidateSetTracker()
        }
        self.candidateSetTracker = tracker
        if !registeredEntries.isEmpty {
            tracker?.seedRegisteredEntries(registeredEntries)
        }
    }

    private enum IntakeResult {
        case candidate(written: String, hold: VocabularyHoldReason?)
        case excluded(VocabularyExclusionReason)
    }

    private static let predicateEndings: [String] = [
        "しました", "しません", "します", "している", "していた",
        "でした", "ました", "ている", "ていた", "になる", "になった",
        "だった", "しない", "した", "する", "して", "です", "ます"
    ]

    /// Process a single LearnedTerm through Stages 1‑4.
    public func process(_ term: LearnedTerm) -> VocabularyCandidateOutcome {
        // Stage 1: Intake & normalization
        let normalizedWritten: String
        let intakeHold: VocabularyHoldReason?
        switch intakeNormalize(term) {
        case .excluded(let reason):
            return .excluded(reason)
        case .candidate(let written, let hold):
            normalizedWritten = written
            intakeHold = hold
        }

        // Stage 2: Type classification
        let type = classifyWrittenForm(normalizedWritten)

        // Stage 3: Reading generation (Phase 1 local rules)
        let generated = VocabularyReadingGeneration.generate(
            written: normalizedWritten,
            evidence: term.originalFragment,
            type: type
        )

        // Stage 4: Quality guards (ordered by design precedence:
        // Stage 1 surface/intake constraints -> Stage 4 structural/safety guards ->
        // phonetic divergence -> Stage 3 Phase-1 ambiguity/generation holds)
        let generatedReasons: [VocabularyHoldReason] = generated.holdReasons.map { $0.toVocabularyHoldReason() }
        var holdReasons: [VocabularyHoldReason] = []
        if let intakeHold {
            holdReasons.append(intakeHold)
        }

        // Reading character validity
        if let reading = generated.output,
           !VocabularyReadingGeneration.isValidHybridReading(reading) {
            holdReasons.append(.readingCharacterInvalid)
        }

        // Short-reading / long-reading guards
        if let reading = generated.canonical ?? generated.output {
            let moraCount = VocabularyReadingGeneration.moraCount(of: reading)
            if moraCount <= config.shortReadingMoraThreshold {
                holdReasons.append(.shortReadingGuard)
            }
            if moraCount > config.longReadingMoraThreshold {
                holdReasons.append(.longReadingGuard)
            }
        }

        // Duplicate-reading collision
        if let candidateSetTracker {
            let candidateReadings = [generated.canonical ?? generated.output, generated.evidenceCanonical]
                .compactMap { $0 }
            if candidateReadings.contains(where: {
                candidateSetTracker.hasCollision(written: normalizedWritten, reading: $0, type: type)
            }) {
                holdReasons.append(.duplicateReadingCollision)
            }
        }

        // Cap awareness (counts against soft/safety caps)
        if let candidateSetTracker {
            let count = candidateSetTracker.candidateCount
            if count >= config.safetyCap {
                holdReasons.append(.capExceededSafety)
            } else if count >= config.softCap {
                holdReasons.append(.capExceededSoft)
            }
        }

        // Phonetic divergence precedes Phase-1 reading ambiguity holds
        if generatedReasons.contains(.phoneticDivergence) {
            holdReasons.append(.phoneticDivergence)
        }
        for reason in generatedReasons where reason != .phoneticDivergence {
            holdReasons.append(reason)
        }

        // Determine final outcome
        if !holdReasons.isEmpty {
            let candidate = VocabularyCandidate(
                written: normalizedWritten,
                reading: generated.recommended ?? generated.canonical ?? generated.output ?? "",
                type: type,
                learnedTermID: term.id,
                createdAt: term.createdAt,
                sourceRecordID: term.sourceRecordID
            )
            return .pendingReview(holdReasons.first!, candidate)
        }

        guard let outputReading = generated.output else {
            return .excluded(.writtenTooLong)
        }

        let candidate = VocabularyCandidate(
            written: normalizedWritten,
            reading: outputReading,
            type: type,
            learnedTermID: term.id,
            createdAt: term.createdAt,
            sourceRecordID: term.sourceRecordID
        )
        return .ready(candidate)
    }

    // MARK: - Stage 1 Implementation

    private func intakeNormalize(_ term: LearnedTerm) -> IntakeResult {
        var written = term.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty else {
            return .excluded(.noiseOnly)
        }

        var intakeHold: VocabularyHoldReason?

        // Half-width / full-width spaces are forbidden in AmiVoice written forms;
        // normalize consecutive spaces to a single underscore and hold for review.
        if written.contains(" ") || written.contains("　") {
            written = normalizeInternalSpaces(written)
            intakeHold = .writtenContainsForbiddenCharacters
        }

        // Forbidden characters | and : – strip for display and hold; exclude if nothing remains.
        if written.contains("|") || written.contains(":") {
            let sanitized = written
                .replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: ":", with: "")
            if sanitized.isEmpty {
                return .excluded(.invalidCharactersCannotSanitize)
            }
            written = sanitized
            intakeHold = .writtenContainsForbiddenCharacters
        }

        // Length limit (AmiVoice: 60 characters)
        if written.count > 60 {
            return .excluded(.writtenTooLong)
        }

        let original = term.originalFragment.trimmingCharacters(in: .whitespacesAndNewlines)

        // Punctuation-only changes (e.g., 「アストラ同期、」 → 「アストラ同期」)
        let punctuationSet = CharacterSet(charactersIn: "、。,.")
        let originalNormalized = original.trimmingCharacters(in: punctuationSet)
        let writtenNormalized = written.trimmingCharacters(in: punctuationSet)
        if originalNormalized == writtenNormalized,
           original != written {
            return .excluded(.noiseOnly)
        }

        // Full-rewrite / sentence-expression rephrase noise (e.g., 「機能を追加した」 → 「仕様を変更した」)
        if isFullRewriteNoise(written: writtenNormalized, original: originalNormalized) {
            return .excluded(.noiseOnly)
        }

        // Same-sound orthography unification (e.g., 子供 → 子ども, 受付 → 受け付け)
        if isSameSoundOrthographyUnification(written: written, original: original) {
            return .excluded(.outOfDictionaryScope)
        }

        // Filler or particle inclusion (e.g., 「えーと霧峰」 → 「霧峰」, 「アストラ同期を」 → 「アストラ同期」)
        if intakeHold == nil,
           original.hasPrefix(written) || original.hasSuffix(written),
           written.count < original.count {
            intakeHold = .fillerOrParticleInclusion
        }

        return .candidate(written: written, hold: intakeHold)
    }

    private func normalizeInternalSpaces(_ text: String) -> String {
        var result = ""
        var previousWasSpace = false
        for character in text {
            if character == " " || character == "　" {
                if !previousWasSpace {
                    result.append("_")
                    previousWasSpace = true
                }
            } else {
                result.append(character)
                previousWasSpace = false
            }
        }
        return result
    }

    private func isFullRewriteNoise(written: String, original: String) -> Bool {
        guard written != original,
              !written.isEmpty,
              !original.isEmpty,
              hasClauseExpressionStructure(written),
              hasClauseExpressionStructure(original),
              let writtenKana = VocabularyReadingGeneration.japaneseKanaReading(written),
              let originalKana = VocabularyReadingGeneration.japaneseKanaReading(original) else {
            return false
        }
        let distance = VocabularyReadingGeneration.editDistance(writtenKana, originalKana)
        let maxLength = max(writtenKana.count, originalKana.count)
        return maxLength > 0 && distance * 2 > maxLength
    }

    private func hasClauseExpressionStructure(_ text: String) -> Bool {
        guard text.allSatisfy(VocabularyReadingGeneration.isJapaneseCharacter),
              VocabularyReadingGeneration.containsKanji(text) else {
            return false
        }
        for ending in Self.predicateEndings {
            if text.hasSuffix(ending), text.count > ending.count {
                let stem = text.dropLast(ending.count)
                if stem.contains(where: { VocabularyReadingGeneration.isKanjiCharacter($0) }) {
                    return true
                }
            }
        }
        return false
    }

    private func isSameSoundOrthographyUnification(written: String, original: String) -> Bool {
        guard written != original,
              written.allSatisfy(VocabularyReadingGeneration.isJapaneseCharacter),
              original.allSatisfy(VocabularyReadingGeneration.isJapaneseCharacter),
              VocabularyReadingGeneration.containsKanji(written),
              VocabularyReadingGeneration.containsKanji(original),
              let writtenKana = VocabularyReadingGeneration.japaneseKanaReading(written),
              let originalKana = VocabularyReadingGeneration.japaneseKanaReading(original),
              writtenKana == originalKana else {
            return false
        }
        // Only treat as out-of-scope orthography unification (e.g., 子供 → 子ども, 受付 → 受け付け)
        // when `written` introduces no new kanji relative to `original` (kanji-to-hiragana opening
        // or okurigana changes). Homophone kanji substitutions (e.g., 稼働監視基板 → 稼働監視基盤)
        // introduce a different kanji and remain eligible for dictionary registration.
        let writtenKanji = written.filter(VocabularyReadingGeneration.isKanjiCharacter)
        let originalKanji = original.filter(VocabularyReadingGeneration.isKanjiCharacter)
        return isSubsequence(writtenKanji, of: originalKanji)
    }

    private func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var needleIterator = needle.makeIterator()
        guard var current = needleIterator.next() else { return true }
        for character in haystack {
            if character == current {
                guard let next = needleIterator.next() else { return true }
                current = next
            }
        }
        return false
    }

    // MARK: - Stage 2 Implementation

    internal func classifyWrittenForm(_ written: String) -> VocabularyTermType {
        let tokens = VocabularyReadingGeneration.tokenize(written)
        let hasJapanese = tokens.contains { $0.kind == .japanese }
        let hasLetters = tokens.contains { $0.kind == .letters }
        let hasDigits = tokens.contains { $0.kind == .digits }
        let hasSeparator = tokens.contains { $0.kind == .separator }
        let hasOther = tokens.contains { $0.kind == .other }

        guard !hasOther else {
            // Contains unsupported characters → treat as mixed for safety.
            return .numericMixed
        }

        if hasSeparator {
            return .numericMixed
        }

        if !hasJapanese && !hasDigits && hasLetters {
            return .alphabet
        } else if !hasJapanese && !hasLetters && hasDigits {
            return .numericMixed
        } else if !hasLetters && !hasDigits && hasJapanese {
            // Check if it contains kanji.
            if VocabularyReadingGeneration.containsKanji(written) {
                return .kanjiMixed
            } else {
                return .kana
            }
        } else {
            // Any mixture → numericMixed (covers letters+digits, Japanese+letters, etc.)
            return .numericMixed
        }
    }
}

/// Tracks candidates already processed to detect collisions and count caps.
public final class CandidateSetTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var candidates: [VocabularyCandidate] = []
    private var readingToWritten: [String: [String]] = [:]
    /// Words already registered in the target profile, keyed by canonical reading.
    /// Kept apart from `candidates` so seeding never consumes the soft/safety caps.
    private var registeredReadingToWritten: [String: [String]] = [:]

    public init() {}

    public var candidateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return candidates.count
    }

    public func addCandidate(_ candidate: VocabularyCandidate) {
        lock.lock()
        defer { lock.unlock() }
        candidates.append(candidate)
        let normalizedReading = VocabularyReadingGeneration.canonicalHiragana(candidate.reading)
        readingToWritten[normalizedReading, default: []].append(candidate.written)
    }

    /// Seeds one word that is already registered in the target profile so the
    /// duplicate-reading guard can see it (GD-308 BND-G01/G02/G03).
    public func seedRegisteredEntry(written: String, reading: String) {
        lock.lock()
        defer { lock.unlock() }
        seedRegisteredEntryLocked(written: written, reading: reading)
    }

    /// Seeds the words already registered in the target profile.
    public func seedRegisteredEntries(_ entries: [(written: String, reading: String)]) {
        lock.lock()
        defer { lock.unlock() }
        for entry in entries {
            seedRegisteredEntryLocked(written: entry.written, reading: entry.reading)
        }
    }

    private func seedRegisteredEntryLocked(written: String, reading: String) {
        let normalizedReading = VocabularyReadingGeneration.canonicalHiragana(reading)
        registeredReadingToWritten[normalizedReading, default: []].append(written)
    }

    public func hasCollision(written: String, reading: String, type: VocabularyTermType) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let normalizedReading = VocabularyReadingGeneration.canonicalHiragana(reading)
        let existingWrittens = (readingToWritten[normalizedReading] ?? [])
            + (registeredReadingToWritten[normalizedReading] ?? [])
        guard !existingWrittens.isEmpty else { return false }
        // Collision if same reading but different written form in same type context.
        // (We don't track class context; treat all as same class per OQ‑04.)
        return existingWrittens.contains { $0 != written }
    }
}
