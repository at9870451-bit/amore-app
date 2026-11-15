// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Settings",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "Settings", targets: ["Settings"])],
    dependencies: [
        .package(path: "../../../CoreKit"),
        .package(path: "../../../SecurityKit"),
        .package(path: "../../../DesignSystem"),
    ],
    targets: [
        .target(name: "Settings", dependencies: ["CoreKit", "SecurityKit", "DesignSystem"]),
        .testTarget(name: "SettingsTests", dependencies: ["Settings"])
    ]
)
