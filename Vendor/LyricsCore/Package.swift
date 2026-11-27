// swift-tools-version: 6.0
// Vendored copy of the author's LyricsCore package (MIT, see LICENSE).
import PackageDescription

let package = Package(
    name: "LyricsCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "LyricsCore", targets: ["LyricsCore"]),
        .executable(name: "lyricsctl", targets: ["lyricsctl"]),
    ],
    targets: [
        .target(name: "LyricsCore", swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]),
        .executableTarget(name: "lyricsctl", dependencies: ["LyricsCore"]),
        .testTarget(name: "LyricsCoreTests", dependencies: ["LyricsCore"], swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]),
    ],
    swiftLanguageModes: [.v5]
)
