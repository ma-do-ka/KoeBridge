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

// VocabularyHoldReason is defined in VocabularyPipeline.swift
// The following cases are used internally and correspond to cases in VocabularyHoldReason
private enum InternalHoldReason {
    case readingGenerationUnavailable
    case invalidWrittenCharacters
    case ambiguousAlphabetReading
    case numericReadingAmbiguous
    case phoneticDivergence
    
    func toVocabularyHoldReason() -> VocabularyHoldReason {
        switch self {
        case .readingGenerationUnavailable: return .readingGenerationUnavailable
        case .invalidWrittenCharacters: return .invalidWrittenCharacters
        case .ambiguousAlphabetReading: return .ambiguousAlphabetReading
        case .numericReadingAmbiguous: return .numericReadingAmbiguous
        case .phoneticDivergence: return .phoneticDivergence
        }
    }
}

/// Local, deterministic reading generation helpers for the vocabulary candidate pipeline.
/// Kanji readings come from the platform Japanese tokenizer and CFStringTransform only;
/// unresolved or ambiguous forms are left to the caller's fail-safe hold path.
public enum VocabularyReadingGeneration {
    struct GeneratedReading {
        let output: String?
        let canonical: String?
        let evidenceCanonical: String?
        let recommended: String?
        let holdReasons: [InternalHoldReason]
    }

    private enum SurfaceTokenKind {
        case japanese
        case letters
        case digits
        case separator
        case other
    }

    private struct SurfaceToken {
        let kind: SurfaceTokenKind
        let text: String
    }

    public static func generate(written: String, evidence: String, type: VocabularyTermType) -> GeneratedReading {
        let evidenceReading = mixedEvidenceReading(evidence)
        switch type {
        case .kana:
            return GeneratedReading(
                output: written,
                canonical: canonicalHiragana(written),
                evidenceCanonical: evidenceReading,
                recommended: nil,
                holdReasons: []
            )
        case .kanjiMixed:
            guard let generated = japaneseKanaReading(written) else {
                return GeneratedReading(
                    output: nil,
                    canonical: nil,
                    evidenceCanonical: evidenceReading,
                    recommended: evidenceReading,
                    holdReasons: [.readingGenerationUnavailable]
                )
            }
            var holds: [InternalHoldReason] = []
            if let evidenceReading {
                if !withinPhase1Tolerance(generated, evidenceReading) {
                    holds.append(.phoneticDivergence)
                }
            } else {
                holds.append(.readingGenerationUnavailable)
            }
            return GeneratedReading(
                output: generated,
                canonical: canonicalHiragana(generated),
                evidenceCanonical: evidenceReading,
                recommended: evidenceReading,
                holdReasons: holds
            )
        case .alphabet:
            return generateAlphabet(written: written, evidenceReading: evidenceReading)
        case .numericMixed:
            return generateMixed(written: written, evidenceReading: evidenceReading)
        }
    }

    private static func generateAlphabet(written: String, evidenceReading: String?) -> GeneratedReading {
        guard let spelled = spellOutLetters(written) else {
            return GeneratedReading(
                output: nil,
                canonical: nil,
                evidenceCanonical: evidenceReading,
                recommended: evidenceReading,
                holdReasons: [.invalidWrittenCharacters]
            )
        }
        let canonicalSpelled = canonicalHiragana(spelled)
        var holds: [InternalHoldReason] = []
        if !isUnambiguousAcronym(written) {
            holds.append(.ambiguousAlphabetReading)
        }
        if let evidenceReading {
            // Phase 1 requires an exact spell-out match for alphabet-only terms. The GD-308
            // conditional ZQDB case is therefore held rather than guessed when the evidence
            // differs by contraction or long-vowel details.
            if evidenceReading != canonicalSpelled {
                holds.append(.phoneticDivergence)
            }
        } else {
            holds.append(.readingGenerationUnavailable)
        }
        return GeneratedReading(
            output: spelled,
            canonical: canonicalSpelled,
            evidenceCanonical: evidenceReading,
            recommended: evidenceReading ?? canonicalSpelled,
            holdReasons: holds
        )
    }

    private static func generateMixed(written: String, evidenceReading: String?) -> GeneratedReading {
        let tokens = tokenize(written)
        if tokens.contains(where: { $0.kind == .other }) {
            return GeneratedReading(
                output: nil,
                canonical: nil,
                evidenceCanonical: evidenceReading,
                recommended: evidenceReading,
                holdReasons: [.invalidWrittenCharacters]
            )
        }
        let ambiguousLetters = tokens.contains { token in
            token.kind == .letters && token.text.count > 1 && !isUnambiguousAcronym(token.text)
        }
        if ambiguousLetters {
            return GeneratedReading(
                output: nil,
                canonical: nil,
                evidenceCanonical: evidenceReading,
                recommended: evidenceReading,
                holdReasons: [.ambiguousAlphabetReading]
            )
        }

        var combinations: [(output: String, canonical: String)] = [("", "")]
        var containsDigits = false
        for token in tokens {
            switch token.kind {
            case .separator:
                continue
            case .japanese:
                guard let reading = japaneseKanaReading(token.text) else {
                    return GeneratedReading(
                        output: nil,
                        canonical: nil,
                        evidenceCanonical: evidenceReading,
                        recommended: evidenceReading,
                        holdReasons: [.readingGenerationUnavailable]
                    )
                }
                combinations = combinations.map { ($0.output + reading, $0.canonical + canonicalHiragana(reading)) }
            case .letters:
                guard let spelled = spellOutLetters(token.text) else {
                    return GeneratedReading(
                        output: nil,
                        canonical: nil,
                        evidenceCanonical: evidenceReading,
                        recommended: evidenceReading,
                        holdReasons: [.invalidWrittenCharacters]
                    )
                }
                combinations = combinations.map { ($0.output + spelled, $0.canonical + canonicalHiragana(spelled)) }
            case .digits:
                containsDigits = true
                let variants = digitSequenceVariants(token.text)
                guard !variants.isEmpty, combinations.count * variants.count <= 512 else {
                    return GeneratedReading(
                        output: nil,
                        canonical: nil,
                        evidenceCanonical: evidenceReading,
                        recommended: evidenceReading,
                        holdReasons: [.numericReadingAmbiguous]
                    )
                }
                var expanded: [(output: String, canonical: String)] = []
                for combination in combinations {
                    for variant in variants {
                        expanded.append((combination.output + variant, combination.canonical + canonicalHiragana(variant)))
                    }
                }
                combinations = expanded
            case .other:
                continue
            }
        }
        guard let evidenceReading, !combinations.isEmpty else {
            return GeneratedReading(
                output: combinations.first?.output,
                canonical: combinations.first?.canonical,
                evidenceCanonical: evidenceReading,
                recommended: evidenceReading,
                holdReasons: [.readingGenerationUnavailable]
            )
        }
        let best = combinations
            .map { (output: $0.output, canonical: $0.canonical, distance: editDistance($0.canonical, evidenceReading)) }
            .min { $0.distance < $1.distance }
        guard let best else {
            return GeneratedReading(
                output: nil,
                canonical: nil,
                evidenceCanonical: evidenceReading,
                recommended: evidenceReading,
                holdReasons: [.readingGenerationUnavailable]
            )
        }
        var holds: [InternalHoldReason] = []
        if containsDigits {
            // Numeric readings vary too much for a merely-close match. A digit-bearing
            // candidate is automatic only when the speaker evidence selects one variant exactly.
            if best.distance != 0 { holds.append(.numericReadingAmbiguous) }
        } else if !withinPhase1Tolerance(best.canonical, evidenceReading) {
            holds.append(.phoneticDivergence)
        }
        return GeneratedReading(
            output: best.output,
            canonical: best.canonical,
            evidenceCanonical: evidenceReading,
            recommended: evidenceReading,
            holdReasons: holds
        )
    }

    public static func mixedEvidenceReading(_ text: String) -> String? {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return nil }
        var result = ""
        for token in tokens {
            switch token.kind {
            case .japanese:
                guard let reading = japaneseKanaReading(token.text) else { return nil }
                result += canonicalHiragana(reading)
            case .letters:
                guard token.text.uppercased() == token.text,
                      let spelled = spellOutLetters(token.text) else { return nil }
                result += canonicalHiragana(spelled)
            case .digits:
                for digit in token.text {
                    guard let reading = digitReadings(digit).first else { return nil }
                    result += canonicalHiragana(reading)
                }
            case .separator:
                continue
            case .other:
                return nil
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Uses CoreFoundation's Japanese tokenizer for kanji Latin transcription, then
    /// Foundation/CFStringTransform-compatible Latin-to-hiragana transformation. Tokens that
    /// are already kana are kept as kana rather than round-tripped through romaji.
    public static func japaneseKanaReading(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if text.allSatisfy(isKanaCharacter) {
            return canonicalHiragana(text)
        }
        let cfText = text as CFString
        let fullRange = CFRange(location: 0, length: CFStringGetLength(cfText))
        guard let tokenizer = CFStringTokenizerCreate(
            nil,
            cfText,
            fullRange,
            kCFStringTokenizerUnitWord,
            Locale(identifier: "ja_JP") as CFLocale
        ) else { return nil }

        var result = ""
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType.rawValue != 0 {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = CFStringCreateWithSubstring(nil, cfText, tokenRange) as String
            if token.allSatisfy(isKanaCharacter) {
                result += canonicalHiragana(token)
            } else {
                guard let latinObject = CFStringTokenizerCopyCurrentTokenAttribute(
                    tokenizer,
                    kCFStringTokenizerAttributeLatinTranscription
                ) else { return nil }
                let latin = latinObject as! String
                guard let piece = latinToHiragana(latin), !piece.isEmpty else { return nil }
                result += piece
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return result.isEmpty ? nil : result
    }

    private static func latinToHiragana(_ latin: String) -> String? {
        latin.applyingTransform(.latinToHiragana, reverse: false)
    }

    public static func canonicalHiragana(_ text: String) -> String {
        var converted = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value >= 0x30A1 && value <= 0x30F6,
               let hiragana = Unicode.Scalar(value - 0x60) {
                converted.append(hiragana)
            } else {
                converted.append(scalar)
            }
        }
        return String(converted)
    }

    static func spellOutLetters(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var result = ""
        for character in text.uppercased() {
            guard let reading = letterReading(character) else { return nil }
            result += reading
        }
        return result
    }

    /// Only consonant-heavy all-uppercase acronyms of three or more letters are treated as
    /// unambiguous spell-out forms in Phase 1. Vowel-final forms such as MIRA/NOA/NORA can be
    /// word readings, and one/two-letter forms stay in the hold queue by design.
    static func isUnambiguousAcronym(_ text: String) -> Bool {
        guard text.count >= 3,
              text.uppercased() == text,
              text.allSatisfy(isASCIILetterCharacter),
              let last = text.last else { return false }
        return !["A", "E", "I", "O", "U"].contains(last)
    }

    static func digitSequenceVariants(_ digits: String, limit: Int = 512) -> [String] {
        var variants = [""]
        for digit in digits {
            let readings = digitReadings(digit)
            guard !readings.isEmpty, variants.count * readings.count <= limit else { return [] }
            var expanded: [String] = []
            for prefix in variants {
                for reading in readings {
                    expanded.append(prefix + reading)
                }
            }
            variants = expanded
        }
        return variants
    }

    static func digitReadings(_ digit: Character) -> [String] {
        switch digit {
        case "0": return ["ぜろ", "れい", "まる"]
        case "1": return ["いち", "わん"]
        case "2": return ["に", "つー", "ふた"]
        case "3": return ["さん", "すりー", "み"]
        case "4": return ["よん", "し", "ふぉー"]
        case "5": return ["ご", "ふぁいぶ"]
        case "6": return ["ろく", "しっくす"]
        case "7": return ["なな", "しち", "せぶん"]
        case "8": return ["はち", "えいと"]
        case "9": return ["きゅう", "く", "ないん"]
        default: return []
        }
    }

    private static func letterReading(_ letter: Character) -> String? {
        switch letter {
        case "A": return "えー"
        case "B": return "びー"
        case "C": return "しー"
        case "D": return "でぃー"
        case "E": return "いー"
        case "F": return "えふ"
        case "G": return "じー"
        case "H": return "えいち"
        case "I": return "あい"
        case "J": return "じぇー"
        case "K": return "けー"
        case "L": return "える"
        case "M": return "えむ"
        case "N": return "えぬ"
        case "O": return "おー"
        case "P": return "ぴー"
        case "Q": return "きゅー"
        case "R": return "あーる"
        case "S": return "えす"
        case "T": return "てぃー"
        case "U": return "ゆー"
        case "V": return "ぶい"
        case "W": return "だぶりゅー"
        case "X": return "えっくす"
        case "Y": return "わい"
        case "Z": return "ぜっと"
        default: return nil
        }
    }

    static func isValidHybridReading(_ reading: String) -> Bool {
        guard !reading.isEmpty else { return false }
        return reading.unicodeScalars.allSatisfy { scalar in
            isKanaScalar(scalar) || scalar == "." || scalar == "_"
        }
    }

    static func moraCount(of reading: String) -> Int {
        let canonical = canonicalHiragana(reading)
        let smallKana: Set<Character> = ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゃ", "ゅ", "ょ", "ゎ", "ゕ", "ゖ"]
        var count = 0
        var previousWasBaseKana = false
        for character in canonical {
            if character == "." || character == "_" {
                previousWasBaseKana = false
                continue
            }
            if smallKana.contains(character), previousWasBaseKana {
                continue
            }
            count += 1
            previousWasBaseKana = true
        }
        return count
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for rightIndex in 1...right.count {
                let substitution = previous[rightIndex - 1] + (leftCharacter == right[rightIndex - 1] ? 0 : 1)
                current[rightIndex] = min(
                    current[rightIndex - 1] + 1,
                    previous[rightIndex] + 1,
                    substitution
                )
            }
            previous = current
        }
        return previous[right.count]
    }

    static func withinPhase1Tolerance(_ generated: String, _ evidence: String) -> Bool {
        editDistance(generated, evidence) <= 1
    }

    static func tokenize(_ text: String) -> [SurfaceToken] {
        var tokens: [SurfaceToken] = []
        var currentKind: SurfaceTokenKind?
        var current = ""
        for character in text {
            let kind = surfaceKind(of: character)
            if kind == currentKind {
                current.append(character)
            } else {
                if let currentKind, !current.isEmpty {
                    tokens.append(SurfaceToken(kind: currentKind, text: current))
                }
                currentKind = kind
                current = String(character)
            }
        }
        if let currentKind, !current.isEmpty {
            tokens.append(SurfaceToken(kind: currentKind, text: current))
        }
        return tokens
    }

    private static func surfaceKind(of character: Character) -> SurfaceTokenKind {
        if character == "_" { return .separator }
        if isASCIILetterCharacter(character) { return .letters }
        if isASCIIDigitCharacter(character) { return .digits }
        if isJapaneseCharacter(character) { return .japanese }
        return .other
    }

    static func isASCIILetterCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    static func isASCIIDigitCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return scalar.value >= 0x30 && scalar.value <= 0x39
    }

    static func isJapaneseCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            isKanaScalar(scalar) || isKanjiScalar(scalar)
        }
    }

    static func isKanaCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(isKanaScalar)
    }

    static func isKanjiCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains(where: isKanjiScalar)
    }

    static func containsKanji(_ text: String) -> Bool {
        text.contains { isKanjiCharacter($0) }
    }

    static func containsKana(_ text: String) -> Bool {
        text.contains { isKanaCharacter($0) }
    }

    private static func isKanaScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (value >= 0x3040 && value <= 0x309F)
            || (value >= 0x30A0 && value <= 0x30FF)
            || value == 0x3005
    }

    private static func isKanjiScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value == 0x3007
            || (value >= 0x3400 && value <= 0x4DBF)
            || (value >= 0x4E00 && value <= 0x9FFF)
            || (value >= 0xF900 && value <= 0xFAFF)
            || (value >= 0x20000 && value <= 0x2A6DF)
    }
}
