#if os(macOS)
/// Diagnostics sink for engine transports; wired once at app launch to `DiagnosticLog.record`.
public enum EngineDiagnostics {
    @MainActor public static var record: (String) -> Void = { _ in }
}
#endif
