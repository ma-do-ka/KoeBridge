// swift-tools-version: 6.0
import PackageDescription

var applicationDependencies: [Target.Dependency] = ["KoeBridgeCore", "KoeBridgePOSIX"]
var applicationTestDependencies: [Target.Dependency] = ["KoeBridge", "KoeBridgeCore"]
var additionalTargets: [Target] = []
#if os(macOS)
// Exact official release bytes, also pinned by Sparkle's 2.10.1 Package.swift.
applicationDependencies.append("Sparkle")
applicationTestDependencies.append("Sparkle")
additionalTargets.append(.binaryTarget(name: "Sparkle",
    url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
    checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"))
#endif

let package = Package(
    name: "KoeBridge",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "KoeBridge", targets: ["KoeBridge"])],
    targets: [
        .target(name: "KoeBridgeCore"),
        .target(name: "KoeBridgePOSIX", path: "Sources/KoeBridgePOSIX", publicHeadersPath: "include"),
        .executableTarget(name: "KoeBridge", dependencies: applicationDependencies,
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                                          .when(platforms: [.macOS]))]),
        .testTarget(name: "KoeBridgeCoreTests", dependencies: ["KoeBridgeCore"]),
        .testTarget(name: "KoeBridgeTests", dependencies: applicationTestDependencies,
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "KoeBridgeSelfTest", dependencies: ["KoeBridgeCore", "KoeBridgePOSIX"],
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ] + additionalTargets
)
