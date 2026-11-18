// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TrayStats",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TrayStats",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ServiceManagement")]
        ),
        .testTarget(name: "TrayStatsTests", dependencies: ["TrayStats"]),
    ]
)
