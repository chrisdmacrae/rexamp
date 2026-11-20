// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RexNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RexNotch", path: "Sources/RexNotch"),
        .testTarget(name: "RexNotchTests", dependencies: ["RexNotch"]),
    ]
)
