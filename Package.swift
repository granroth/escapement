// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Escapement",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EscapementKit", targets: ["EscapementKit"]),
        .executable(name: "Escapement", targets: ["EscapementApp"]),
        .executable(name: "EscapementAgent", targets: ["EscapementAgent"]),
    ],
    targets: [
        .target(name: "EscapementKit"),
        .executableTarget(
            name: "EscapementApp",
            dependencies: ["EscapementKit"]
        ),
        .executableTarget(
            name: "EscapementAgent",
            dependencies: ["EscapementKit"]
        ),
        .testTarget(
            name: "EscapementKitTests",
            dependencies: ["EscapementKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
