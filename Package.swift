// swift-tools-version:6.0
// SimpleIsland — a Dynamic Island for the Mac notch. SwiftPM only, no Xcode project needed.
import Foundation
import PackageDescription

/// Optional "Meetings" widget (records a meeting and sends audio to a self-hosted Sten server for minutes).
/// Off by default: a normal build does not contain it. Enable with `SIMPLEISLAND_MEETINGS=1 swift build ...`
/// (build.sh / install.sh: `--with-meetings`). Use a separate `--scratch-path` per variant.
let withMeetings = ProcessInfo.processInfo.environment["SIMPLEISLAND_MEETINGS"] == "1"

/// Island modules: one target each, every module depends only on IslandCore (Media also on LyricsCore).
/// New module: add its name here, a folder Sources/<Name>/ and a line in Sources/SimpleIsland/ModuleRegistry.swift.
let islandModules = ["MediaModule", "HUDModule", "ShelfModule", "AgentsModule", "TodayModule",
                     "VafaModule", "MenuBarModule"] + (withMeetings ? ["MeetingsModule"] : [])

let package = Package(
    name: "SimpleIsland",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SimpleIsland", targets: ["SimpleIsland"]),
        .library(name: "IslandCore", targets: ["IslandCore"]),
    ],
    dependencies: [
        // Lyrics engine — the author's own LyricsCore package, vendored (see THIRD_PARTY.md).
        .package(path: "Vendor/LyricsCore"),
    ],
    targets: [
        .target(name: "IslandCore", path: "Sources/IslandCore"),
    ] + islandModules.map { name in
        .target(name: name, dependencies: name == "MediaModule"
                    ? ["IslandCore", .product(name: "LyricsCore", package: "LyricsCore")] : ["IslandCore"],
                path: "Sources/\(name)")
    } + [
        .executableTarget(
            name: "SimpleIsland",
            dependencies: ["IslandCore"] + islandModules.map { .target(name: $0) },
            path: "Sources/SimpleIsland",
            swiftSettings: withMeetings ? [.define("SIMPLEISLAND_MEETINGS")] : []
        ),
    ],
    swiftLanguageModes: [.v5]
)
