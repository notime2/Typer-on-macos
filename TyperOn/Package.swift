// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev
import PackageDescription

let package = Package(
    name: "TyperOn",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "TyperOn",
            dependencies: [],
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
