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
    ]
)
