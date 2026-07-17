// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TokenMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenMonitorCore", targets: ["TokenMonitorCore"]),
        .executable(name: "TokenMonitor", targets: ["TokenMonitorApp"]),
    ],
    targets: [
        .target(name: "TokenMonitorCore"),
        .executableTarget(
            name: "TokenMonitorApp",
            dependencies: ["TokenMonitorCore"]
        ),
        .testTarget(
            name: "TokenMonitorCoreTests",
            dependencies: ["TokenMonitorCore"]
        ),
    ]
)
