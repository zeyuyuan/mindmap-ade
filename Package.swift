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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3")
    ],
    targets: [
        .target(name: "MindMapCore"),
        .executableTarget(
            name: "MindmapADE",
            dependencies: ["MindMapCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
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
