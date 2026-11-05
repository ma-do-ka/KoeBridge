/// Platform-independent decision for an explicit Launch at Login toggle.
/// The operating system remains the source of truth after each operation.
public enum LoginItemRegistrationState: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

public enum LoginItemRegistrationAction: Equatable, Sendable {
    case register
    case unregister
    case none
}

public enum LoginItemRegistrationPolicy {
    /// In particular, .notFound must NOT disable the user's attempt to
    /// register: it is a discovery error, not proof that registration fails.
    public static func action(requested: Bool,
                              current: LoginItemRegistrationState) -> LoginItemRegistrationAction {
        if requested {
            switch current {
            case .notRegistered, .notFound: return .register
            case .enabled, .requiresApproval, .unknown: return .none
            }
        }
        switch current {
        case .enabled, .requiresApproval: return .unregister
        case .notRegistered, .notFound, .unknown: return .none
        }
    }

    public static func isRequested(_ state: LoginItemRegistrationState) -> Bool {
        state == .enabled || state == .requiresApproval
    }

    public static func isActive(_ state: LoginItemRegistrationState) -> Bool {
        state == .enabled
    }
}
