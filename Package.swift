// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SFCast",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "SFCast",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/SFCast",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
