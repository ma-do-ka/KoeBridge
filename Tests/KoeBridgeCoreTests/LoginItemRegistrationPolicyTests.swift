import Testing
@testable import KoeBridgeCore

struct LoginItemRegistrationPolicyTests {
    @Test func turningOnAttemptsRegistrationEvenWhenServiceIsNotFound() {
        #expect(LoginItemRegistrationPolicy.action(requested: true, current: .notFound) == .register)
        #expect(LoginItemRegistrationPolicy.action(requested: true, current: .notRegistered) == .register)
        #expect(!LoginItemRegistrationPolicy.isRequested(.notFound))
        #expect(!LoginItemRegistrationPolicy.isActive(.notFound))
    }

    @Test func registeredAndAwaitingApprovalMustNotReregister() {
        #expect(LoginItemRegistrationPolicy.action(requested: true, current: .enabled) == .none)
        #expect(LoginItemRegistrationPolicy.action(requested: true, current: .requiresApproval) == .none)
        #expect(LoginItemRegistrationPolicy.isRequested(.requiresApproval))
        #expect(!LoginItemRegistrationPolicy.isActive(.requiresApproval))
        #expect(LoginItemRegistrationPolicy.isActive(.enabled))
    }

    @Test func turningOffOnlyUnregistersActiveOrPendingRegistration() {
        #expect(LoginItemRegistrationPolicy.action(requested: false, current: .enabled) == .unregister)
        #expect(LoginItemRegistrationPolicy.action(requested: false, current: .requiresApproval) == .unregister)
        #expect(LoginItemRegistrationPolicy.action(requested: false, current: .notRegistered) == .none)
        #expect(LoginItemRegistrationPolicy.action(requested: false, current: .notFound) == .none)
    }

    @Test func unknownOSStateCannotTriggerDestructiveAction() {
        #expect(LoginItemRegistrationPolicy.action(requested: true, current: .unknown) == .none)
        #expect(LoginItemRegistrationPolicy.action(requested: false, current: .unknown) == .none)
    }
}
