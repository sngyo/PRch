// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRch",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PRch", targets: ["PRch"])],
    targets: [
        .target(name: "ReviewCore"),
        .executableTarget(name: "PRch", dependencies: ["ReviewCore"], resources: [.process("Resources")]),
        .testTarget(name: "ReviewCoreTests", dependencies: ["ReviewCore"]),
        .testTarget(name: "PRchTests", dependencies: ["PRch", "ReviewCore"])
    ]
)
