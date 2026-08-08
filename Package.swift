// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HeyDebby",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "HeyDebby", path: "Sources/HeyDebby"),
        .testTarget(name: "HeyDebbyTests", dependencies: ["HeyDebby"])
    ]
)
