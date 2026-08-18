// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AwtrixConnectors",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AwtrixKit"),
        .testTarget(
            name: "AwtrixKitTests",
            dependencies: ["AwtrixKit"],
            resources: [.process("Fixtures")]
        ),
        // The app is a target of its own so the composition root can be tested
        // like anything else: the wiring it owns — the clip root the reaper is
        // contained by, the interval an unsaved connector falls back to, the
        // order of a scheduled tick, the quit budget — is behaviour, not layout.
        .executableTarget(name: "AwtrixConnectorsApp", dependencies: ["AwtrixKit"]),
        .testTarget(
            name: "AwtrixConnectorsAppTests",
            dependencies: ["AwtrixConnectorsApp", "AwtrixKit"]
        ),
    ]
)
