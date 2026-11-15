// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PluginRuntimeJS",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PluginRuntimeJS", targets: ["PluginRuntimeJS"])],
    dependencies: [
        .package(path: "../PluginKit"),
        .package(path: "../CoreKit"),
    ],
    targets: [
        .target(name: "PluginRuntimeJS", dependencies: ["PluginKit", "CoreKit"]),
        .testTarget(name: "PluginRuntimeJSTests", dependencies: ["PluginRuntimeJS"])
    ]
)
