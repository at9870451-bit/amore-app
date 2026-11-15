// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PluginRuntimeMCP",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PluginRuntimeMCP", targets: ["PluginRuntimeMCP"])],
    dependencies: [
        .package(path: "../PluginKit"),
        .package(path: "../NetworkKit"),
        .package(path: "../CoreKit"),
    ],
    targets: [
        .target(name: "PluginRuntimeMCP", dependencies: ["PluginKit", "NetworkKit", "CoreKit"]),
        .testTarget(name: "PluginRuntimeMCPTests", dependencies: ["PluginRuntimeMCP", "NetworkKit"])
    ]
)
