#if os(macOS)
import Foundation
import Testing
@testable import KoeBridge

@MainActor struct VoiceCommandPresentationTests {
    @Test func commandGateReasonsUseJapaneseDetail() {
        for token in ["suppressed", "acoustic_review_required", "review_required", "review_incomplete",
                      "review_command_mismatch", "automatic_input_disabled"] {
            let suffix = VoiceController.commandReasonSuffix(token)
            #expect(suffix.hasPrefix("（") && suffix.hasSuffix("）"))
            #expect(!suffix.contains(token))
            #expect(suffix.range(of: "[A-Za-z_]", options: .regularExpression) == nil)
        }
    }

    @Test func commandDeliveryReasonsUseJapaneseDetail() {
        for token in ["delivery_cancelled_before_post", "delivery_cancelled_after_partial_post",
                      "delivery_cancelled_after_post", "accessibility_not_granted", "post_event_permission_missing",
                      "empty_typing_payload", "target_not_captured", "command_baseline_unavailable",
                      "field_value_unavailable_on_recheck", "field_value_or_selection_changed",
                      "event_source_unavailable", "keyboard_event_unavailable", "posted_without_observable_edit",
                      "posted_receipt_timeout", "active_app_changed", "focused_field_changed", "focused_window_changed",
                      "caret_or_selection_changed", "prior_input_unverified", "frontmost_application_unavailable",
                      "focused_element_unavailable_on_recheck", "focused_window_invalid_on_recheck",
                      "focused_window_unavailable_on_recheck", "focused_element_owner_changed",
                      "focused_element_owner_unavailable", "captured_selection_invalid",
                      "selection_value_invalid_on_recheck", "selection_unavailable_on_recheck",
                      "focus_verification_failed", "posted_then_active_app_changed", "posted_then_focused_field_changed"] {
            let suffix = VoiceController.commandReasonSuffix(token)
            #expect(!suffix.isEmpty)
            #expect(!suffix.contains(token))
            #expect(suffix.range(of: "[A-Za-z_]", options: .regularExpression) == nil)
        }
        #expect(VoiceController.commandReasonSuffix("delivery_cancelled_after_post") == "（入力後の確認を取り消しました）")
    }

    @Test func unknownReasonsOmitTheEntireParenthetical() {
        #expect(VoiceController.commandReasonSuffix("future_internal_reason") == "")
        #expect(VoiceController.commandReasonSuffix("posted_then_future_internal_reason") == "")
        #expect(VoiceController.commandReasonSuffix("") == "")
    }
}
#endif
