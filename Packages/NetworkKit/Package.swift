// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetworkKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "NetworkKit", targets: ["NetworkKit"])],
    dependencies: [
        .package(path: "../CoreKit"),
    ],
    targets: [
        .target(name: "NetworkKit", dependencies: ["CoreKit"]),
        .testTarget(name: "NetworkKitTests", dependencies: ["NetworkKit", "CoreKit"])
    ]
)
