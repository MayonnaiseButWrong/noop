// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhoopProtocol",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "WhoopProtocol", targets: ["WhoopProtocol"]),
    ],
    targets: [
        .target(name: "WhoopProtocol", dependencies: []),
        .testTarget(name: "WhoopProtocolTests", dependencies: ["WhoopProtocol"]),
    ]
)
