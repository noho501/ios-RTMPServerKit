// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RTMPServerKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "RTMPServerKit",
            targets: ["RTMPServerKit"]
        )
    ],
    targets: [
        .target(
            name: "RTMPServerKit",
            dependencies: [],
            path: "Sources/RTMPServerKit"
        )
    ]
)
