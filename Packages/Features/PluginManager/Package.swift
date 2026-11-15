// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PluginManager",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PluginManager", targets: ["PluginManager"])],
    dependencies: [
        .package(path: "../../../PluginKit"),
        .package(path: "../../../DesignSystem"),
    ],
    targets: [
        .target(name: "PluginManager", dependencies: ["PluginKit", "DesignSystem"]),
        .testTarget(name: "PluginManagerTests", dependencies: ["PluginManager"])
    ]
)
