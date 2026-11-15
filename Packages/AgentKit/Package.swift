// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "AgentKit", targets: ["AgentKit"])],
    dependencies: [
        .package(path: "../LLMKit"),
        .package(path: "../PluginKit"),
        .package(path: "../CoreKit"),
    ],
    targets: [
        .target(name: "AgentKit", dependencies: ["LLMKit", "PluginKit", "CoreKit"]),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit", "LLMKit"])
    ]
)
