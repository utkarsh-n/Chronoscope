// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChronoscopeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ChronoscopeCore", targets: ["ChronoscopeCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "ChronoscopeCore", dependencies: ["CSQLite"]),
        .testTarget(name: "ChronoscopeCoreTests", dependencies: ["ChronoscopeCore"])
    ]
)
