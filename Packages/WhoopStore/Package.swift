// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhoopStore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "WhoopStore", targets: ["WhoopStore"]),
    ],
    dependencies: [
        // The fork's own README already lists GRDB.swift as a resolved
        // dependency ("Swift Package Manager resolves the only
        // third-party dependencies automatically: GRDB.swift (SQLite)
        // and ZIPFoundation"), so WhoopStore being GRDB-backed matches
        // that, not a new assumption introduced here.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(name: "WhoopStore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "WhoopStoreTests", dependencies: ["WhoopStore"]),
    ]
)
