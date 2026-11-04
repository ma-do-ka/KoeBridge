// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KoeBridge",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "KoeBridge", targets: ["KoeBridge"])
    ],
    targets: [
        .target(name: "KoeBridgeCore"),
        .target(name: "KoeBridgePOSIX", path: "Sources/KoeBridgePOSIX", publicHeadersPath: "include"),
        .executableTarget(name: "KoeBridge", dependencies: ["KoeBridgeCore", "KoeBridgePOSIX"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "KoeBridgeCoreTests", dependencies: ["KoeBridgeCore"]),
        .executableTarget(name: "KoeBridgeSelfTest", dependencies: ["KoeBridgeCore", "KoeBridgePOSIX"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
