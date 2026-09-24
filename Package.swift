// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PixbarTiles",
    platforms: [.macOS(.v26)],
    targets: [
        // The resources are icon art for skies the LaMetric catalogue has
        // nothing for. They ship here rather than being fetched, so a clock
        // that has never run this app still draws them.
        .target(name: "PixbarKit", exclude: ["Ulanzi/CLAUDE.md", "Weather/CLAUDE.md"], resources: [.process("Resources")]),
        .testTarget(
            name: "PixbarKitTests",
            dependencies: ["PixbarKit"],
            resources: [.process("Fixtures")]
        ),
        // The app is a target of its own so the composition root can be tested
        // like anything else: the wiring it owns — the clip root the reaper is
        // contained by, the interval an unsaved connector falls back to, the
        // order of a scheduled tick, the quit budget — is behaviour, not layout.
        .executableTarget(name: "PixbarTilesApp", dependencies: ["PixbarKit"]),
        .testTarget(
            name: "PixbarTilesAppTests",
            dependencies: ["PixbarTilesApp", "PixbarKit"]
        ),
    ]
)
