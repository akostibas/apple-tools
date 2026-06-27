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
    dependencies: [
        // Phone-number parsing / E.164 canonicalization (see ADR-0001).
        // Tracks the maintained line at the canonical org. The project split on
        // 2026-05-25: the original repo (marmelroy/PhoneNumberKit) shipped a
        // final 4.3.0 and is now deprecated/unmaintained, while development
        // continues at PhoneNumberKit/PhoneNumberKit from 5.0. We take 5.x —
        // an abandoned "previous major" gets no security patches, so maintained
        // beats merely-older here. The 5.x API is source-identical to 4.x.
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "AppleToolsObjC",
            path: "Sources/AppleToolsObjC"
        ),
        .target(
            name: "AppleToolsLib",
            dependencies: [
                "AppleToolsObjC",
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ],
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
