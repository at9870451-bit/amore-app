// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarketplaceKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "MarketplaceKit", targets: ["MarketplaceKit"])],
    dependencies: [
        .package(path: "../NetworkKit"),
        .package(path: "../SecurityKit"),
        .package(path: "../PluginKit"),
        .package(path: "../CoreKit"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(name: "MarketplaceKit", dependencies: ["NetworkKit", "SecurityKit", "PluginKit", "CoreKit"]),
        .testTarget(name: "MarketplaceKitTests", dependencies: ["MarketplaceKit", "PluginKit", "SecurityKit", .product(name: "ZIPFoundation", package: "ZIPFoundation")])
    ]
)
