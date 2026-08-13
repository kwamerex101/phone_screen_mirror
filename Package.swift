// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iMirror",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure, framework-light logic (geometry + WDA response parsing) so it can
        // be unit-tested without AppKit/AVFoundation.
        .target(
            name: "iMirrorCore",
            path: "Sources/iMirrorCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "iMirror",
            dependencies: ["iMirrorCore"],
            path: "Sources/iMirror",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "iMirrorCoreTests",
            dependencies: ["iMirrorCore"],
            path: "Tests/iMirrorCoreTests"
        ),
        .testTarget(
            name: "iMirrorTests",
            dependencies: ["iMirror", "iMirrorCore"],
            path: "Tests/iMirrorTests"
        ),
    ]
)
