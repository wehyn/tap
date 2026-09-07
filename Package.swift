// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TapProbe",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "TapProbe", targets: ["TapProbe"]),
        .executable(name: "Tap", targets: ["Tap"]),
    ],
    targets: [
        .target(
            name: "TapProbeCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "TapProbe",
            dependencies: ["TapProbeCore"]
        ),
        .executableTarget(
            name: "Tap",
            dependencies: ["TapProbeCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "TapReaderCheck",
            dependencies: ["TapProbeCore"]
        ),
        .executableTarget(
            name: "TapProbeCoreCheck",
            dependencies: ["TapProbeCore"]
        ),
        .executableTarget(
            name: "TapReplay",
            dependencies: ["TapProbeCore"]
        ),
        .executableTarget(
            name: "TapTrain",
            dependencies: ["TapProbeCore"]
        ),
    ]
)
