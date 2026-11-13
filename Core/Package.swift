// swift-tools-version:5.9
// Everything in the app that doesn't need UIKit/AVFoundation: models, the JSON stores, the
// YouTube Music client and the offline rules. Kept as a package so it builds and is tested on
// Linux too (scripts/test-core.sh), against the real YouTube.
import PackageDescription

let package = Package(
    name: "EsputifaiCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EsputifaiCore", targets: ["EsputifaiCore"]),
    ],
    targets: [
        .target(name: "EsputifaiCore"),
        .testTarget(name: "EsputifaiCoreTests", dependencies: ["EsputifaiCore"]),
    ]
)
