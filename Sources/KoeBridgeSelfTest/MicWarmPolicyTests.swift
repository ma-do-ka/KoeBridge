import KoeBridgeCore

struct MicWarmPolicyTests {
    func allInputCombinations() {
        let cases: [(Bool, Bool, Bool, Bool)] = [
            (false, false, false, false), (false, false, true, false),
            (false, true, false, false), (false, true, true, false),
            (true, false, false, false), (true, false, true, false),
            (true, true, false, true), (true, true, true, false)
        ]
        for (enabled, bluetooth, takeActive, expected) in cases {
            let result = MicWarmPolicy.shouldWarm(enabled: enabled,
                selectedDeviceIsBluetooth: bluetooth, takeActive: takeActive)
            check(result == expected)
        }
    }
}
