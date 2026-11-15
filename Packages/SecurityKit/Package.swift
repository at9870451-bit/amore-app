// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SecurityKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "SecurityKit", targets: ["SecurityKit"])],
    dependencies: [
        .package(path: "../CoreKit"),
    ],
    targets: [
        .target(name: "SecurityKit", dependencies: ["CoreKit"]),
        .testTarget(name: "SecurityKitTests", dependencies: ["SecurityKit"])
    ]
)
