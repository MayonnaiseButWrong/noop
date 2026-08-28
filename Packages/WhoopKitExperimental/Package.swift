// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhoopKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "WhoopKit", targets: ["WhoopKit"]),
    ],
    targets: [
        .target(name: "WhoopKit", dependencies: []),
        .testTarget(name: "WhoopKitTests", dependencies: ["WhoopKit"]),
    ]
)
