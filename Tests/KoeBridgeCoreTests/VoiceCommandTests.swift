import Foundation
import KoeBridgeCore
import Testing

struct VoiceCommandTests {
    @Test func matching() {
        let all = Set(VoiceCommandID.allCases)
        for command in VoiceCommandID.allCases {
            #expect(VoiceCommandMatcher.match(text: command.phrase, enabled: all) == command)
            #expect(VoiceCommandMatcher.match(text: " \t" + command.phrase + "。\n", enabled: all) == command)
            #expect(VoiceCommandMatcher.match(text: command.phrase + ".", enabled: all) == command)
            #expect(VoiceCommandMatcher.match(text: command.phrase + "。。", enabled: all) == nil)
            #expect(VoiceCommandMatcher.match(text: command.phrase + "!", enabled: all) == nil)
            #expect(VoiceCommandMatcher.match(text: command.phrase, enabled: []) == nil)
        }
        #expect(VoiceCommandMatcher.match(text: "ここで改行してと言いました", enabled: all) == nil)
        #expect(VoiceCommandMatcher.match(text: "改行 して", enabled: all) == nil)
        #expect(VoiceCommandMatcher.match(text: "改行して 。", enabled: all) == nil)
        #expect(VoiceCommandMatcher.match(text: "段落を変えて".decomposedStringWithCanonicalMapping, enabled: all) == .paragraph)
        #expect(VoiceCommandMatcher.match(text: "", enabled: all) == nil)
        #expect(VoiceCommandID.newline.insertionText == "\n")
        #expect(VoiceCommandID.paragraph.insertionText == "\n\n")
        #expect(VoiceCommandID.cancelTake.insertionText == nil)
        #expect(UnicodeTypingPlan.safeText("\n\n") == " ")
    }
    @Test func gates() {
        #expect(VoiceCommandGate.blockedReason(acousticReviewRequired: false, reviewStatus: nil, suppressed: false, shouldPaste: true, sameCommand: true) == nil)
        #expect(VoiceCommandGate.blockedReason(acousticReviewRequired: true, reviewStatus: nil, suppressed: false, shouldPaste: true, sameCommand: true) == "acoustic_review_required")
        #expect(VoiceCommandGate.blockedReason(acousticReviewRequired: false, reviewStatus: .needsReview, suppressed: false, shouldPaste: true, sameCommand: true) == "review_required")
        #expect(VoiceCommandGate.blockedReason(acousticReviewRequired: false, reviewStatus: .incomplete, suppressed: false, shouldPaste: true, sameCommand: true) == "review_incomplete")
        #expect(VoiceCommandGate.blockedReason(acousticReviewRequired: false, reviewStatus: .checked, suppressed: true, shouldPaste: true, sameCommand: true) == "suppressed")
        #expect(VoiceCommandGate.blockedReason(acousticReviewRequired: false, reviewStatus: .checked, suppressed: false, shouldPaste: false, sameCommand: true) == "automatic_input_disabled")
        #expect(VoiceCommandGate.blockedReason(acousticReviewRequired: false, reviewStatus: .checked, suppressed: false, shouldPaste: true, sameCommand: false) == "review_command_mismatch")
    }
}
