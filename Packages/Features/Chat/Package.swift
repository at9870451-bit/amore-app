// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chat",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "Chat", targets: ["Chat"])],
    dependencies: [
        .package(path: "../../../AgentKit"),
        .package(path: "../../../MemoryKit"),
        .package(path: "../../../DesignSystem"),
        .package(path: "../../../CoreKit"),
    ],
    targets: [
        .target(name: "Chat", dependencies: ["AgentKit", "MemoryKit", "DesignSystem", "CoreKit"]),
        .testTarget(name: "ChatTests", dependencies: ["Chat"])
    ]
)
