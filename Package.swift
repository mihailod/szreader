// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SZReader",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SZKit", targets: ["SZKit"])
    ],
    targets: [
        // Deliberately UIKit-free so the parsers run as fast Mac unit tests
        // against the same fixtures the Python spike was validated on.
        .target(name: "SZKit"),
        .testTarget(name: "SZKitTests", dependencies: ["SZKit"])
    ]
)
