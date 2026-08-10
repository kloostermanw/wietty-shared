// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "wietty-shared",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "WiettyShared", targets: ["WiettyShared"])
    ],
    targets: [
        .target(name: "WiettyShared"),
        .testTarget(name: "WiettySharedTests", dependencies: ["WiettyShared"])
    ]
)
