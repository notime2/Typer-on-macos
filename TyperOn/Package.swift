// swift-tools-version: 6.2
// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev
import PackageDescription

let package = Package(
    name: "TyperOn",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "TyperOn",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources",
            resources: [
                .process("../Resources/Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "TyperOnTests",
            dependencies: ["TyperOn"],
            path: "Tests"
        )
    ]
)
