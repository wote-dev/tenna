// swift-tools-version: 6.0
import PackageDescription

// Built with Swift Package Manager rather than an .xcodeproj: this machine has the
// Command Line Tools but not full Xcode, and SwiftPM + `make-app.sh` produces a
// perfectly good signed .app bundle without it.
let package = Package(
    name: "TennaNova",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TennaNova",
            path: "Sources/TennaNova",
            // Swift 5 language mode: Network.framework's callback-based API fights
            // strict concurrency hard, and the ceremony buys nothing here.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TennaNovaTests",
            dependencies: ["TennaNova"],
            path: "Tests/TennaNovaTests",
            // Matches the target under test. Without it the tests build in Swift 6 mode,
            // which is fine while they only touch plain structs and stops compiling the
            // moment one touches a @MainActor @Observable type.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
