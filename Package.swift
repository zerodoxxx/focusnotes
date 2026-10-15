// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CaptureApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "OverlayKit", targets: ["OverlayKit"]),
        .executable(name: "App", targets: ["App"]),
        .library(name: "EmbedKit", targets: ["EmbedKit"]),
        .executable(name: "EmbedHelper", targets: ["EmbedHelper"]),
        .executable(name: "EmbedChecks", targets: ["EmbedChecks"]),
        .library(name: "ModelInstall", targets: ["ModelInstall"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "CORT", publicHeadersPath: "include"),
        .target(name: "EmbedKit", dependencies: ["CORT"],
                linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Accelerate"), .linkedFramework("CoreGraphics"),
                                 .linkedFramework("ImageIO")]),
        .executableTarget(name: "EmbedHelper", dependencies: ["EmbedKit"]),
        .executableTarget(name: "EmbedChecks", dependencies: ["EmbedKit"],
                          exclude: ["generate-reference.py", "requirements-reference.txt"], resources: [.copy("Fixtures")],
                          linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "ModelInstall", dependencies: ["EmbedKit"]),
        .executableTarget(name: "ModelInstallChecks", dependencies: ["ModelInstall", "EmbedKit"]),
        .target(name: "Core", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(
            name: "CaptureKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .target(
            name: "OverlayKit",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("QuartzCore")]
        ),
        .executableTarget(name: "OverlayGallery", dependencies: ["OverlayKit"]),
        .executableTarget(name: "App", dependencies: ["Core", "CaptureKit", "OverlayKit", "EmbedKit", "ModelInstall",
                                                      .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "CaptureChecks", dependencies: ["CaptureKit"]),
        .executableTarget(name: "CoreChecks", dependencies: ["Core"], linkerSettings: [.linkedLibrary("sqlite3")])
    ],
    swiftLanguageModes: [.v6]
)
