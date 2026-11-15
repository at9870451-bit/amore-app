// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Memory",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "Memory", targets: ["Memory"])],
    dependencies: [
        .package(path: "../../../MemoryKit"),
        .package(path: "../../../DesignSystem"),
    ],
    targets: [
        .target(name: "Memory", dependencies: ["MemoryKit", "DesignSystem"]),
        .testTarget(name: "MemoryTests", dependencies: ["Memory"])
    ]
)
