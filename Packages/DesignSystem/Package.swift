// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "DesignSystem", targets: ["DesignSystem"])],
    dependencies: [
        .package(path: "../CoreKit"),
    ],
    targets: [
        .target(name: "DesignSystem", dependencies: ["CoreKit"]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"])
    ]
)
