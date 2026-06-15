// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "apple-tools",
    platforms: [.macOS(.v13)],
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
