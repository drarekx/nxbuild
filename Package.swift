// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NXBuild",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "NXBuild", path: "Sources/NXBuild"),
        .testTarget(name: "NXBuildTests", dependencies: ["NXBuild"], path: "Tests/NXBuildTests"),
    ]
)
