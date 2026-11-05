import KoeBridgeCore

struct LoginItemRegistrationPolicyTests {
    func registrationFromNotFoundDoesNotPretendApproval() {
        check(LoginItemRegistrationPolicy.action(requested: true, current: .notFound) == .register)
        check(LoginItemRegistrationPolicy.action(requested: true, current: .notRegistered) == .register)
        check(!LoginItemRegistrationPolicy.isRequested(.notFound))
        check(!LoginItemRegistrationPolicy.isActive(.requiresApproval))
        check(LoginItemRegistrationPolicy.isRequested(.requiresApproval))
        check(LoginItemRegistrationPolicy.isActive(.enabled))
    }

    func unregisterOnlyWhenActuallyRegistered() {
        check(LoginItemRegistrationPolicy.action(requested: false, current: .enabled) == .unregister)
        check(LoginItemRegistrationPolicy.action(requested: false, current: .requiresApproval) == .unregister)
        check(LoginItemRegistrationPolicy.action(requested: false, current: .notRegistered) == .none)
        check(LoginItemRegistrationPolicy.action(requested: false, current: .notFound) == .none)
        check(LoginItemRegistrationPolicy.action(requested: true, current: .unknown) == .none)
    }
}
