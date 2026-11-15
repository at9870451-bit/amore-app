// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "MemoryKit", targets: ["MemoryKit"])],
    dependencies: [
        .package(path: "../CoreKit"),
        .package(path: "../LLMKit"),
        .package(path: "../NetworkKit"),
    ],
    targets: [
        .target(name: "MemoryKit", dependencies: ["CoreKit", "LLMKit", "NetworkKit"]),
        .testTarget(name: "MemoryKitTests", dependencies: ["MemoryKit"])
    ]
)
