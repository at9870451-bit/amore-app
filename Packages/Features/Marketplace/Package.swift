// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Marketplace",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "Marketplace", targets: ["Marketplace"])],
    dependencies: [
        .package(path: "../../../MarketplaceKit"),
        .package(path: "../../../DesignSystem"),
    ],
    targets: [
        .target(name: "Marketplace", dependencies: ["MarketplaceKit", "DesignSystem"]),
        .testTarget(name: "MarketplaceTests", dependencies: ["Marketplace"])
    ]
)
