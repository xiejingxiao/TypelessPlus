// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypelessPlus",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "TypelessUI",
            dependencies: [],
            path: "TypelessUI",
            resources: [
                .copy("../TypelessAI/server.py"),
            ]
        ),
        .testTarget(
            name: "E2ETests",
            dependencies: [],
            path: "Tests",
            sources: ["E2ETestApp.swift"]
        ),
    ]
)