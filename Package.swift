// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "apple-tools",
    platforms: [.macOS(.v13)],
    products: [
        // The shared library, consumed by the apple-tools CLI here and by
        // server-backed hosts (e.g. Shannon's probe-macos) that inject their
        // own FileSink / Confirmer. See README "Architecture".
        .library(name: "AppleToolsLib", targets: ["AppleToolsLib"]),
        .executable(name: "apple-tools", targets: ["apple-tools"]),
    ],
    targets: [
        .target(
            name: "AppleToolsObjC",
            path: "Sources/AppleToolsObjC"
        ),
        .target(
            name: "AppleToolsLib",
            dependencies: ["AppleToolsObjC"],
            path: "Sources/AppleToolsLib"
        ),
        .executableTarget(
            name: "apple-tools",
            dependencies: ["AppleToolsLib"],
            path: "Sources/apple-tools"
        ),
        .testTarget(
            name: "AppleToolsTests",
            dependencies: ["AppleToolsLib"],
            path: "Tests/AppleToolsTests"
        ),
    ]
)
