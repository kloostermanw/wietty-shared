// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "itermplex-shared",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "ItermplexShared", targets: ["ItermplexShared"])
    ],
    targets: [
        .target(name: "ItermplexShared"),
        .testTarget(name: "ItermplexSharedTests", dependencies: ["ItermplexShared"])
    ]
)
