// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MindmapADE",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MindmapADE", targets: ["MindmapADE"])
    ],
    targets: [
        .executableTarget(
            name: "MindmapADE",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ],
    swiftLanguageModes: [.v6]
)
