// swift-tools-version: 6.0
import PackageDescription

var applicationDependencies: [Target.Dependency] = ["KoeBridgeCore", "KoeBridgePOSIX"]
var selfTestDependencies: [Target.Dependency] = ["KoeBridgeTestSupport", "KoeBridgeCore", "KoeBridgePOSIX"]
var coreDependencies: [Target.Dependency] = []
var applicationTestDependencies: [Target.Dependency] = ["KoeBridge", "KoeBridgeCore"]
var additionalTargets: [Target] = []
#if os(macOS)
selfTestDependencies += ["KoeBridgeAudioTap", "KoeBridgeTapFixtures"]
additionalTargets.append(.target(name: "KoeBridgeTapFixtures", path: "Tests/KoeBridgeTapFixtures", publicHeadersPath: "include"))
coreDependencies.append("KoeBridgeAudioTap")
additionalTargets.append(.target(name: "KoeBridgeAudioTap", publicHeadersPath: "include"))
applicationDependencies.append("KoeBridgeEngines")
applicationTestDependencies.append("KoeBridgeEngines")
additionalTargets.append(.target(name: "KoeBridgeEngines", dependencies: ["KoeBridgeCore"],
                                 swiftSettings: [.swiftLanguageMode(.v5)]))
// Exact official release bytes, also pinned by Sparkle's 2.10.1 Package.swift.
applicationDependencies.append("Sparkle")
applicationTestDependencies += ["Sparkle", "KoeBridgeTapFixtures"]
additionalTargets.append(.binaryTarget(name: "Sparkle",
    url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
    checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"))
#endif

let package = Package(
    name: "KoeBridge",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "KoeBridge", targets: ["KoeBridge"])],
    targets: [
        .target(name: "KoeBridgeCore", dependencies: coreDependencies),
        .target(name: "KoeBridgePOSIX", path: "Sources/KoeBridgePOSIX", publicHeadersPath: "include"),
        .executableTarget(name: "KoeBridge", dependencies: applicationDependencies,
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                                          .when(platforms: [.macOS]))]),
        .target(name: "KoeBridgeTestSupport", dependencies: ["KoeBridgeCore"], path: "Tests/KoeBridgeTestSupport"),
        .testTarget(name: "KoeBridgeCoreTests", dependencies: ["KoeBridgeCore", "KoeBridgeTestSupport"]),
        .testTarget(name: "KoeBridgeTests", dependencies: applicationTestDependencies,
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "KoeBridgeSelfTest", dependencies: selfTestDependencies,
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ] + additionalTargets
)
