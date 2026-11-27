import Foundation

/// Why a sentence unit was cut. Recorded for diagnostics only; it never
/// changes the resulting text composition.
public enum SentenceBoundarySource: String, Sendable {
    /// 。！？!? run, or a guarded ASCII period.
    case terminator
    /// A close quote/bracket whose interior ended with a terminator and whose
    /// next character does not continue the enclosing sentence (FX-08 rule).
    case quoteClose
    /// Take end: the remaining buffered text flushed as one unit.
    case flush
    /// The per-take unit cap was reached; all remaining text folds into one unit.
    case capacity
}

public struct SentenceUnit: Equatable, Sendable {
    /// 0-based order inside the take.
    public let index: Int
    /// Verbatim slice of the finalized stream, minus any leading whitespace.
    public let text: String
    /// Verbatim whitespace that preceded `text` in the stream (usually "").
    public let separator: String
    public let source: SentenceBoundarySource

    public init(index: Int, text: String, separator: String, source: SentenceBoundarySource) {
        self.index = index
        self.text = text
        self.separator = separator
        self.source = source
    }
}

/// R-03 v1 boundary detector (B-2 Soft Commit). Fed the engine's cumulative
/// finalized prefix; cuts sentence units from finalized text only. Preview /
/// volatile text never enters.
///
/// Boundary rules (design final #2 + GD-729 案C + fixtures):
/// - Engine final events only deliver text; an event edge alone never splits.
/// - 。！？!? at quote depth 0 cut a boundary; consecutive terminators are one.
/// - ASCII '.' cuts only when it is not a decimal/version (digit before), not
///   an abbreviation chain or initial (dotted run, single-letter stem) and not
///   a listed abbreviation (Dr., etc.), and only when the next character is an
///   ASCII letter or whitespace.
/// - Any open quote/bracket state suppresses terminators inside it.
/// - A close that returns depth to 0 after an interior terminator cuts a
///   boundary unless the next character continues the sentence (と/を/が/…)
///   or is itself a terminator (which then cuts the boundary normally).
/// - Unclosed quote state simply carries to flush; the take-end flush emits
///   all remaining text as one unit.
/// - At most `maximumUnits` units split individually; the rest folds into one
///   trailing unit (FX-18/FX-38 degrade).
public struct SentenceSegmenter: Sendable {
    public static let maximumUnits = 128

    public private(set) var emittedCount = 0
    /// The finalized text did not extend the already-consumed prefix. The
    /// context treats this as a degrade and falls back to whole-take text.
    public private(set) var conflicted = false
    public private(set) var sealed = false
    public private(set) var saturated = false

    /// Consumed finalized text (prefix of the engine stream) for validation.
    private var consumed: [Character] = []
    /// Buffered, not yet emitted characters.
    private var pending: [Character] = []
    /// Next unprocessed index into `pending`.
    private var cursor = 0
    /// A close-delimiter boundary deferred until the next character is known.
    private var deferredCloseEnd: Int?
    /// A guarded '.' at buffer end deferred until the next character is known.
    private var deferredDotEnd: Int?

    private var kagiDepth = 0
    private var doubleKagiDepth = 0
    private var parenDepth = 0
    private var asciiParenDepth = 0
    private var curlyDepth = 0
    private var asciiQuoteOpen = false
    private var quoteOpen: Bool {
        kagiDepth > 0 || doubleKagiDepth > 0 || parenDepth > 0
            || asciiParenDepth > 0 || curlyDepth > 0 || asciiQuoteOpen
    }

    public init() {}

    /// Feed the engine's cumulative finalized prefix. Returns newly cut units.
    /// Retried/stale prefixes are ignored once the take seals or conflicts.
    public mutating func ingest(_ finalizedPrefix: String) -> [SentenceUnit] {
        guard !sealed, !conflicted else { return [] }
        let incoming = Array(finalizedPrefix)
        guard incoming.count >= consumed.count,
              incoming[..<consumed.count].elementsEqual(consumed) else {
            conflicted = true
            return []
        }
        guard incoming.count > consumed.count else { return [] }
        pending.append(contentsOf: incoming[consumed.count...])
        consumed = incoming
        return scan()
    }

    /// Take end: emit everything left as one unit, whatever the quote state.
    public mutating func flush() -> SentenceUnit? {
        guard !sealed else { return nil }
        sealed = true
        deferredCloseEnd = nil
        deferredDotEnd = nil
        guard !pending.isEmpty else { return nil }
        let source: SentenceBoundarySource = saturated ? .capacity : .flush
        let unit = makeUnit(pending, source: source)
        pending.removeAll(keepingCapacity: false)
        cursor = 0
        return unit
    }

    // MARK: - scanning

    private mutating func scan() -> [SentenceUnit] {
        var out: [SentenceUnit] = []
        while cursor < pending.count {
            if emittedCount >= Self.maximumUnits {
                saturated = true
                deferredCloseEnd = nil
                deferredDotEnd = nil
                return out
            }
            if deferredCloseEnd != nil || deferredDotEnd != nil {
                resolveDeferred(&out)
                continue
            }
            let c = pending[cursor]
            cursor += 1
            switch classify(c) {
            case .opener(let pair):
                applyOpen(pair)
            case .closer(let pair):
                applyClose(pair)
                if !quoteOpen, cursor >= 2, Self.terminators.contains(pending[cursor - 2]) {
                    deferredCloseEnd = cursor
                }
            case .terminator:
                if quoteOpen { break }
                cursor = consumeTerminatorRun(from: cursor - 1)
                emit(through: cursor, source: .terminator, into: &out)
            case .period:
                if quoteOpen || !isPeriodBoundary() { break }
                if cursor < pending.count {
                    let next = pending[cursor]
                    if (next.isASCII && next.isLetter) || next == " " || next == "\t" {
                        emit(through: cursor, source: .terminator, into: &out)
                    }
                } else {
                    deferredDotEnd = cursor
                }
            case .plain:
                break
            }
        }
        return out
    }

    /// `cursor` sits on the character after a deferred boundary candidate.
    private mutating func resolveDeferred(_ out: inout [SentenceUnit]) {
        let c = pending[cursor]
        if deferredCloseEnd != nil {
            if Self.closingDelimiters.contains(c) || (c == "\"" && asciiQuoteOpen) {
                applyCloseChar(c)
                deferredCloseEnd = cursor + 1
                cursor += 1
            } else if Self.terminators.contains(c) || Self.continuationAfterClose.contains(c) {
                // A terminator cuts its own boundary further along; a
                // continuation particle keeps the quote inside the sentence.
                deferredCloseEnd = nil
            } else {
                emit(through: deferredCloseEnd ?? cursor, source: .quoteClose, into: &out)
            }
            return
        }
        if let end = deferredDotEnd {
            deferredDotEnd = nil
            if (c.isASCII && c.isLetter) || c == " " || c == "\t" {
                emit(through: end, source: .terminator, into: &out)
            }
            // Otherwise the '.' was mid-token; keep scanning normally.
        }
    }

    /// `start` is the first terminator. Consumes the rest of the run plus any
    /// trailing close delimiters (。」 / ！”), so they stay in the unit.
    private mutating func consumeTerminatorRun(from start: Int) -> Int {
        var end = start + 1
        while end < pending.count {
            let c = pending[end]
            if Self.terminators.contains(c) || c == "." { end += 1 } else { break }
        }
        while end < pending.count {
            let c = pending[end]
            guard Self.closingDelimiters.contains(c) || (c == "\"" && asciiQuoteOpen) else { break }
            applyCloseChar(c)
            deferredCloseEnd = nil
            end += 1
        }
        return end
    }

    /// Emit pending[..<end] as one unit and drop it from the buffer.
    private mutating func emit(through end: Int, source: SentenceBoundarySource,
                               into out: inout [SentenceUnit]) {
        guard emittedCount < Self.maximumUnits else { return }
        let slice = Array(pending[..<end])
        pending.removeFirst(end)
        cursor -= end
        deferredCloseEnd = nil
        deferredDotEnd = nil
        if let unit = makeUnit(slice, source: source) { out.append(unit) }
    }

    private mutating func makeUnit(_ slice: [Character],
                                   source: SentenceBoundarySource) -> SentenceUnit? {
        var first = 0
        while first < slice.count, slice[first].isWhitespace { first += 1 }
        guard first < slice.count else { return nil }
        let unit = SentenceUnit(index: emittedCount, text: String(slice[first...]),
                                separator: String(slice[..<first]), source: source)
        emittedCount += 1
        return unit
    }

    // MARK: - character classes

    fileprivate enum Pair { case kagi, doubleKagi, paren, asciiParen, curly, asciiQuote }
    fileprivate enum Kind { case opener(Pair), closer(Pair), terminator, period, plain }

    private static let terminators: Set<Character> = ["。", "！", "？", "!", "?"]
    /// Closes folded into a unit tail after a terminator run or a deferred
    /// quote-close boundary. ASCII '"' is handled separately via the toggle.
    private static let closingDelimiters: Set<Character> = ["」", "』", "）", ")", "”"]
    /// Characters that may continue a sentence after a close quote. The costly
    /// direction is a wrong split, so this set errs toward not splitting.
    private static let continuationAfterClose: Set<Character> = [
        "と", "を", "が", "は", "も", "に", "へ", "で", "の", "や", "か", "ね",
        "よ", "さ", "ぞ", "っ", "だ", "す", "ま", "し", "な", "け", "く", "り",
        "、", "."
    ]
    private static let asciiAbbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "st", "jr", "sr", "vs", "etc", "no", "fig",
        "inc", "ltd", "corp", "prof", "al", "ca", "cf", "ed", "vol", "rev",
        "approx", "dept", "est", "min", "max"
    ]

    private func classify(_ c: Character) -> Kind {
        switch c {
        case "「": return .opener(.kagi)
        case "」": return .closer(.kagi)
        case "『": return .opener(.doubleKagi)
        case "』": return .closer(.doubleKagi)
        case "（": return .opener(.paren)
        case "）": return .closer(.paren)
        case "(": return .opener(.asciiParen)
        case ")": return .closer(.asciiParen)
        case "“": return .opener(.curly)
        case "”": return .closer(.curly)
        case "\"": return asciiQuoteOpen ? .closer(.asciiQuote) : .opener(.asciiQuote)
        case "。", "！", "？", "!", "?": return .terminator
        case ".": return .period
        default: return .plain
        }
    }

    private mutating func applyOpen(_ pair: Pair) {
        switch pair {
        case .kagi: kagiDepth += 1
        case .doubleKagi: doubleKagiDepth += 1
        case .paren: parenDepth += 1
        case .asciiParen: asciiParenDepth += 1
        case .curly: curlyDepth += 1
        case .asciiQuote: asciiQuoteOpen = true
        }
    }

    private mutating func applyClose(_ pair: Pair) {
        switch pair {
        case .kagi: kagiDepth = max(0, kagiDepth - 1)
        case .doubleKagi: doubleKagiDepth = max(0, doubleKagiDepth - 1)
        case .paren: parenDepth = max(0, parenDepth - 1)
        case .asciiParen: asciiParenDepth = max(0, asciiParenDepth - 1)
        case .curly: curlyDepth = max(0, curlyDepth - 1)
        case .asciiQuote: asciiQuoteOpen = false
        }
    }

    /// Close handling for run-tail / deferred-boundary consumption, where the
    /// arriving character is already known to be a close delimiter.
    private mutating func applyCloseChar(_ c: Character) {
        applyClose(classify(c).pair ?? .kagi)
    }

    /// Guards for '.': reject decimals/versions (digit before), dotted chains
    /// (K.R.S.), single-letter initials, and known abbreviations (Dr., etc.).
    /// `cursor` sits just past the '.'.
    private func isPeriodBoundary() -> Bool {
        let dot = cursor - 1
        guard dot > 0 else { return false }
        if pending[dot - 1].isNumber { return false }
        var stemStart = dot - 1
        while stemStart > 0, pending[stemStart - 1].isASCII, pending[stemStart - 1].isLetter {
            stemStart -= 1
        }
        let stem = String(pending[stemStart..<dot])
        if !stem.isEmpty {
            // A '.' earlier in the dotted run means a chain like K.R.S.
            var look = stemStart
            while look > 0, pending[look - 1].isASCII,
                  pending[look - 1].isLetter || pending[look - 1] == "." {
                look -= 1
            }
            if look < stemStart { return false }
            if stem.count == 1 { return false }
            if Self.asciiAbbreviations.contains(stem.lowercased()) { return false }
        }
        return true
    }
}

private extension SentenceSegmenter.Kind {
    var pair: SentenceSegmenter.Pair? {
        switch self {
        case .opener(let pair), .closer(let pair): return pair
        default: return nil
        }
    }
}
