// swift-tools-version:5.9
import PackageDescription

// SwiftPM builds and tests the pure logic only; build.sh compiles the app with swiftc.
let package = Package(
    name: "DuskBar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "DuskCore"),
        .testTarget(name: "DuskCoreTests", dependencies: ["DuskCore"]),
    ]
)
