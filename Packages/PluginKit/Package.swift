// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PluginKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "PluginKit", targets: ["PluginKit"])],
    dependencies: [
        .package(path: "../CoreKit"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(name: "PluginKit", dependencies: ["CoreKit", .product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .testTarget(name: "PluginKitTests", dependencies: ["PluginKit", .product(name: "ZIPFoundation", package: "ZIPFoundation")])
    ]
)
