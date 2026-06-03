// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Heartecho",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Heartecho", targets: ["HeartechoApp"]),
        .executable(name: "HeartechoDiagnostics", targets: ["HeartechoDiagnostics"]),
        .executable(name: "HeartechoHelper", targets: ["HeartechoHelper"]),
        .library(name: "HeartechoCore", targets: ["HeartechoCore"]),
        .library(name: "HeartechoAudio", targets: ["HeartechoAudio"]),
        .library(name: "HALDriverStub", targets: ["HALDriverStub"]),
        .library(name: "HALDriverC", targets: ["HALDriverC"])
    ],
    targets: [
        .executableTarget(
            name: "HeartechoApp",
            dependencies: [
                "HeartechoCore",
                "HeartechoAudio",
                "HALDriverStub"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .target(
            name: "HeartechoCore",
            dependencies: []
        ),
        .target(
            name: "HeartechoAudio",
            dependencies: [
                "HeartechoCore",
                "HALDriverStub",
                "HALDriverC"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .target(
            name: "HALDriverStub",
            dependencies: [
                "HeartechoCore",
                "HALDriverC"
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .target(
            name: "HALDriverC",
            dependencies: [],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "HeartechoDiagnostics",
            dependencies: [
                "HeartechoCore",
                "HeartechoAudio",
                "HALDriverStub",
                "HALDriverC"
            ]
        ),
        .executableTarget(
            name: "HeartechoHelper",
            dependencies: [
                "HeartechoCore",
                "HeartechoAudio",
                "HALDriverStub",
                "HALDriverC"
            ]
        ),
        .testTarget(
            name: "HeartechoCoreTests",
            dependencies: ["HeartechoCore"]
        )
    ]
)
