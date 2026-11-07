import Foundation

/// Acoustic energy is diagnostic information, never proof that somebody spoke.
/// Admission requires an independent speech classifier. Failures never open the gate.
public struct SpeechVerification: Equatable, Sendable {
    public enum State: String, Sendable { case pending, running, completed, failed, timedOut }
    public private(set) var state: State = .pending
    public private(set) var windows = 0
    public private(set) var positiveWindows = 0
    public private(set) var maximumConfidence: Double = 0
    public private(set) var confirmed = false
    public private(set) var firstSpeechStart: Double?
    private var consecutivePositive = 0
    private var candidateStart: Double?
    private var lastWindowStart: Double = -1
    public init() {}

    public var allowsTranscript: Bool {
        confirmed && (state == .running || state == .completed)
    }
    public mutating func started() {
        guard state == .pending else { return }
        state = .running
    }
    public mutating func observe(confidence: Double, start: Double, duration: Double) {
        guard state == .running else { return }
        guard confidence.isFinite, (0...1).contains(confidence), start.isFinite,
              start >= 0, duration.isFinite, duration > 0 else { fail(); return }
        guard start > lastWindowStart else { return }
        lastWindowStart = start
        windows += 1
        maximumConfidence = max(maximumConfidence, confidence)
        if confidence >= 0.65 {
            if consecutivePositive == 0 { candidateStart = start }
            consecutivePositive += 1
            positiveWindows += 1
            if !confirmed, confidence >= 0.85 || consecutivePositive >= 2 {
                confirmed = true
                firstSpeechStart = candidateStart ?? start
            }
        } else {
            consecutivePositive = 0
            candidateStart = nil
        }
    }
    public mutating func complete() {
        guard state == .running else { return }
        state = .completed
    }
    public mutating func fail() {
        guard state == .pending || state == .running else { return }
        state = .failed
    }
    public mutating func timeOut() {
        guard state == .pending || state == .running else { return }
        state = .timedOut
    }
}
