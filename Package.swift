// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSlapApp",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure signal processing, no AppKit/IOKit — unit tested.
        .target(
            name: "SlapCore",
            path: "Sources/SlapCore"
        ),
        .executableTarget(
            name: "MacSlapApp",
            dependencies: ["SlapCore"],
            path: "Sources/MacSlapApp",
            swiftSettings: [
                // AppKit/IOKit callback code predates strict concurrency; UI types
                // are annotated @MainActor explicitly instead.
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "SlapCoreTests",
            dependencies: ["SlapCore"],
            path: "Tests/SlapCoreTests"
        ),
    ]
)
