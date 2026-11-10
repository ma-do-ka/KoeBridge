public enum MicWarmPolicy {
    public static func shouldWarm(enabled: Bool, selectedDeviceIsBluetooth: Bool, takeActive: Bool) -> Bool {
        enabled && selectedDeviceIsBluetooth && !takeActive
    }
}
