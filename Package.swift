// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyMan",
    // 14.2 floor: CoreAudio process-tap APIs (meeting recording) require it.
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "8.36.0"),
        .package(url: "https://github.com/amplitude/Amplitude-Swift.git", from: "1.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyMan",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "AmplitudeSwift", package: "Amplitude-Swift"),
            ],
            path: "src",
            resources: [
                .copy("Resources/Fonts"),
            ]
        ),
        .testTarget(
            name: "MyManTests",
            dependencies: ["MyMan"],
            path: "Tests/MyManTests"
        ),
    ]
)
