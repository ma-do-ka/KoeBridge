import Foundation

/// VocabularyTermType classifies the written form of a term for rule selection.
public enum VocabularyTermType: Equatable, Sendable {
    /// Kana-only (hiragana, katakana) words.
    case kana
    /// Kanji with or without kana mixture.
    case kanjiMixed
    /// Latin alphabet letters only.
    case alphabet
    /// Mixed letters, digits, Japanese characters, and separators.
    case numericMixed
}

/// Outcome of the candidate pipeline for a LearnedTerm.
public enum VocabularyCandidateOutcome: Equatable, Sendable {
    /// Safe to hand to the sync engine as ready_to_sync.
    case ready(VocabularyCandidate)
    /// Plausible but not safe to auto-register; hold queue will display.
    case pendingReview(VocabularyHoldReason, VocabularyCandidate)
    /// Must never be registered (noise, out‑of‑scope, forbidden cases).
    case excluded(VocabularyExclusionReason)
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
        public var phoneticDistanceTolerance: Int = 1          // edit distance ≤ 1

        public static let `default` = Configuration()
    }

    private let config: Configuration
    private let candidateSetTracker: CandidateSetTracker?

    public init(config: Configuration = .default, candidateSetTracker: CandidateSetTracker? = nil) {
        self.config = config
        self.candidateSetTracker = candidateSetTracker
    }

    /// Process a single LearnedTerm through Stages 1‑4.
    public func process(_ term: LearnedTerm) -> VocabularyCandidateOutcome {
        // Stage 1: Intake & normalization
        guard let (normalizedWritten, intakeHold) = intakeNormalize(term) else {
            return .excluded(.noiseOnly)
        }

        // Stage 2: Type classification
        let type = classifyWrittenForm(normalizedWritten)

        // Stage 3: Reading generation (Phase 1 local rules)
        let evidenceReading = VocabularyReadingGeneration.mixedEvidenceReading(term.originalFragment)
        let generated = VocabularyReadingGeneration.generate(
            written: normalizedWritten,
            evidence: term.originalFragment,
            type: type
        )

        // Stage 4: Quality guards
        var holdReasons: [VocabularyHoldReason] = generated.holdReasons.map { internalReason in
            switch internalReason {
            case .readingGenerationUnavailable: return .readingGenerationUnavailable
            case .invalidWrittenCharacters: return .invalidWrittenCharacters
            case .ambiguousAlphabetReading: return .ambiguousAlphabetReading
            case .numericReadingAmbiguous: return .numericReadingAmbiguous
            case .phoneticDivergence: return .phoneticDivergence
            }
        }
        if let intakeHold { holdReasons.append(intakeHold) }

        // Short‑reading guard
        if let reading = generated.canonical ?? generated.output {
            let moraCount = VocabularyReadingGeneration.moraCount(of: reading)
            if moraCount <= config.shortReadingMoraThreshold {
                holdReasons.append(.shortReadingGuard)
            }
            if moraCount > config.longReadingMoraThreshold {
                holdReasons.append(.longReadingGuard)
            }
        }

        // Reading character validity
        if let reading = generated.output,
           !VocabularyReadingGeneration.isValidHybridReading(reading) {
            holdReasons.append(.readingCharacterInvalid)
        }

        // Duplicate‑reading collision
        if let candidateSetTracker,
           let reading = generated.canonical ?? generated.output,
           candidateSetTracker.hasCollision(written: normalizedWritten, reading: reading, type: type) {
            holdReasons.append(.duplicateReadingCollision)
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

    private func intakeNormalize(_ term: LearnedTerm) -> (String, VocabularyHoldReason?)? {
        var written = term.term

        // Remove leading/trailing whitespace
        written = written.trimmingCharacters(in: .whitespacesAndNewlines)

        // Half-width space → underscore (AmiVoice requirement)
        written = written.replacingOccurrences(of: " ", with: "_")
        written = written.replacingOccurrences(of: "　", with: "_")

        // Forbidden characters | and : – we cannot safely sanitize, so hold
        if written.contains("|") || written.contains(":") {
            // Attempt to remove them; if the result is non‑empty, hold; otherwise exclude.
            let sanitized = written.replacingOccurrences(of: "|", with: "")
                .replacingOccurrences(of: ":", with: "")
            if sanitized.isEmpty {
                return nil // would become empty → exclude
            }
            return (sanitized, .writtenContainsForbiddenCharacters)
        }

        // Punctuation‑only changes (e.g., 「アストラ同期、」 → 「アストラ同期」)
        let originalNormalized = term.originalFragment.trimmingCharacters(in: .characterSet(
            charactersIn: "、。,."
        ))
        let writtenNormalized = written.trimmingCharacters(in: .characterSet(
            charactersIn: "、。,."
        ))
        if originalNormalized == writtenNormalized,
           term.originalFragment != written {
            // Only punctuation difference → exclude as noise.
            return nil
        }

        // Full‑rewrite noise (e.g., 「機能を追加した」 → 「仕様を変更した」)
        // Check if the edit is a whole‑sentence rephrase with no substring match.
        if !written.contains(where: { term.originalFragment.contains($0) }),
           !term.originalFragment.contains(where: { written.contains($0) }) {
            return nil
        }

        // Same‑sound orthography unification (e.g., 子供 → 子ども)
        // This is out of dictionary scope → exclude.
        // In a real implementation we would need a dictionary of unification pairs;
        // for MVP we treat any kanji‑to‑kanji change with identical kana reading as out‑of‑scope.
        // Simplified: if the term is purely Japanese characters and changed, hold for now.
        if written.allSatisfy(VocabularyReadingGeneration.isJapaneseCharacter),
           term.originalFragment.allSatisfy(VocabularyReadingGeneration.isJapaneseCharacter),
           written != term.originalFragment,
           let writtenKana = VocabularyReadingGeneration.japaneseKanaReading(written),
           let originalKana = VocabularyReadingGeneration.japaneseKanaReading(term.originalFragment),
           writtenKana == originalKana {
            return nil // same‑sound orthography change → excluded
        }

        // Filler or particle inclusion (e.g., 「えーと霧峰」 → 「霧峰」)
        // Detect if the difference is a common filler or particle at edges.
        // Simplified: if written is a suffix/prefix substring of originalFragment, hold.
        if term.originalFragment.hasPrefix(written) || term.originalFragment.hasSuffix(written),
           written.count < term.originalFragment.count {
            return (written, .fillerOrParticleInclusion)
        }

        // Length limit (AmiVoice: 60 characters)
        if written.count > 60 {
            return nil // excluded
        }

        return (written, nil)
    }

    // MARK: - Stage 2 Implementation

    internal func classifyWrittenForm(_ written: String) -> VocabularyTermType {
        let tokens = VocabularyReadingGeneration.tokenize(written)
        let hasJapanese = tokens.contains { $0.kind == .japanese }
        let hasLetters = tokens.contains { $0.kind == .letters }
        let hasDigits = tokens.contains { $0.kind == .digits }
        let hasOther = tokens.contains { $0.kind == .other }

        guard !hasOther else {
            // Contains unsupported characters → treat as mixed for safety.
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
public final class CandidateSetTracker: Sendable {
    private let lock = NSLock()
    private var candidates: [VocabularyCandidate] = []
    private var readingToWritten: [String: [String]] = [:]

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
        readingToWritten[candidate.reading, default: []].append(candidate.written)
    }

    public func hasCollision(written: String, reading: String, type: VocabularyTermType) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let existingWrittens = readingToWritten[reading] else { return false }
        // Collision if same reading but different written form in same type context.
        // (We don't track class context; treat all as same class per OQ‑04.)
        return existingWrittens.contains { $0 != written }
    }
}