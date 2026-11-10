import Foundation
import KoeBridgeCore

struct VoiceCommandTests {
    func matching() {
        let all = Set(VoiceCommandID.allCases)
        for command in VoiceCommandID.allCases {
            check(VoiceCommandMatcher.match(text: command.phrase, enabled: all) == command)
            check(VoiceCommandMatcher.match(text: " \t" + command.phrase + "。\n", enabled: all) == command)
            check(VoiceCommandMatcher.match(text: command.phrase + ".", enabled: all) == command)
            check(VoiceCommandMatcher.match(text: command.phrase + "。。", enabled: all) == nil)
            check(VoiceCommandMatcher.match(text: command.phrase + "!", enabled: all) == nil)
            check(VoiceCommandMatcher.match(text: command.phrase, enabled: []) == nil)
        }
        check(VoiceCommandMatcher.match(text: "ここで改行してと言いました", enabled: all) == nil)
        check(VoiceCommandMatcher.match(text: "改行 して", enabled: all) == nil)
        check(VoiceCommandMatcher.match(text: "改行して 。", enabled: all) == nil)
        check(VoiceCommandMatcher.match(text: "段落を変えて".decomposedStringWithCanonicalMapping, enabled: all) == .paragraph)
        check(VoiceCommandMatcher.match(text: "", enabled: all) == nil)
        check(VoiceCommandID.newline.insertionText == "\n")
        check(VoiceCommandID.paragraph.insertionText == "\n\n")
        check(VoiceCommandID.cancelTake.insertionText == nil)
        check(UnicodeTypingPlan.safeText("\n\n") == " ")
    }
    func gates() {
        check(VoiceCommandGate.blockedReason(acousticReviewRequired: false, reviewStatus: nil, suppressed: false, shouldPaste: true, sameCommand: true) == nil)
        check(VoiceCommandGate.blockedReason(acousticReviewRequired: true, reviewStatus: nil, suppressed: false, shouldPaste: true, sameCommand: true) == "acoustic_review_required")
        check(VoiceCommandGate.blockedReason(acousticReviewRequired: false, reviewStatus: .needsReview, suppressed: false, shouldPaste: true, sameCommand: true) == "review_required")
        check(VoiceCommandGate.blockedReason(acousticReviewRequired: false, reviewStatus: .incomplete, suppressed: false, shouldPaste: true, sameCommand: true) == "review_incomplete")
        check(VoiceCommandGate.blockedReason(acousticReviewRequired: false, reviewStatus: .checked, suppressed: true, shouldPaste: true, sameCommand: true) == "suppressed")
        check(VoiceCommandGate.blockedReason(acousticReviewRequired: false, reviewStatus: .checked, suppressed: false, shouldPaste: false, sameCommand: true) == "automatic_input_disabled")
        check(VoiceCommandGate.blockedReason(acousticReviewRequired: false, reviewStatus: .checked, suppressed: false, shouldPaste: true, sameCommand: false) == "review_command_mismatch")
    }
}
