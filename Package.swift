// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MindmapADE",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MindmapADE", targets: ["MindmapADE"])
    ],
    dependencies: [
        .package(path: "Vendor/libghostty-spm")
    ],
    targets: [
        .target(name: "MindMapCore"),
        .target(name: "AgentPTYSystem"),
        .executableTarget(name: "AgentPTYLaunch"),
        .executableTarget(
            name: "MindmapADE",
            dependencies: [
                "MindMapCore", "AgentPTYSystem", "AgentPTYLaunch",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "MindMapCoreTests", dependencies: ["MindMapCore"]),
        .testTarget(
            name: "MindmapADETests", dependencies: ["MindmapADE", "MindMapCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
