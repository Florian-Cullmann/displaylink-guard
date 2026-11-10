// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DisplayLinkGuard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "displaylink-guard", targets: ["DisplayLinkGuard"]),
        .executable(name: "DisplayLinkGuardApp", targets: ["DisplayLinkGuardApp"]),
    ],
    targets: [
        .target(name: "GuardCore"),
        .executableTarget(name: "DisplayLinkGuard", dependencies: ["GuardCore"]),
        .executableTarget(name: "DisplayLinkGuardApp", dependencies: ["GuardCore"]),
        .testTarget(name: "GuardCoreTests", dependencies: ["GuardCore"]),
    ]
)
