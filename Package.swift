// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RinkanUMIS",
    defaultLocalization: "ja",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "UMISCore", targets: ["UMISCore"]),
        .library(name: "UMISMedia", targets: ["UMISMedia"]),
        .library(name: "UMISNetwork", targets: ["UMISNetwork"]),
        .executable(name: "RinkanUMIS", targets: ["RinkanUMIS"]),
    ],
    targets: [
        .binaryTarget(
            name: "AdobeXMPBridge",
            path: "Vendor/AdobeXMP/AdobeXMPBridge.xcframework"
        ),
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "UMISCore",
            dependencies: ["CSQLite", "AdobeXMPBridge"],
            path: "Sources/UMISCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("DiskArbitration"),
            ]
        ),
        .target(
            name: "UMISMedia",
            dependencies: ["UMISCore"],
            path: "Sources/UMISMedia",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("QuickLookThumbnailing"),
            ]
        ),
        .target(
            name: "UMISNetwork",
            dependencies: ["UMISCore"],
            path: "Sources/UMISNetwork",
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "RinkanUMIS",
            dependencies: ["UMISCore", "UMISMedia", "UMISNetwork"],
            path: "Sources/RinkanUMIS",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "UMISCoreTests",
            dependencies: ["UMISCore"],
            path: "Tests/UMISCoreTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "UMISMediaTests",
            dependencies: ["UMISMedia", "UMISCore"],
            path: "Tests/UMISMediaTests"
        ),
        .testTarget(
            name: "UMISNetworkTests",
            dependencies: ["UMISNetwork", "UMISCore"],
            path: "Tests/UMISNetworkTests"
        ),
        .testTarget(
            name: "RinkanUMISTests",
            dependencies: ["RinkanUMIS", "UMISCore", "UMISMedia"],
            path: "Tests/RinkanUMISTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
