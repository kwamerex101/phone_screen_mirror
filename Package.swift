// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iMirror",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "iMirror",
            path: "Sources/iMirror",
            // Swift 5 language mode: avoids Swift 6 strict-concurrency churn for the MVP.
            // No third-party dependencies — Apple system frameworks only (AVFoundation,
            // CoreMediaIO, AppKit). Nothing to vendor or scan.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
