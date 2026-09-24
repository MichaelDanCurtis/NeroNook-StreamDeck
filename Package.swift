// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NeroNookStreamDeck", platforms: [.macOS(.v14)], products: [.executable(name: "deck-audit", targets: ["DeckAudit"]), .executable(name: "StreamDeckPlugin", targets: ["StreamDeckPlugin"])], dependencies: [.package(path: "Vendor/NookPluginSDK")], targets: [
    .target(name: "DeckCore"),
    .executableTarget(name: "StreamDeckPlugin", dependencies: [.product(name: "NookPluginSDK", package: "NookPluginSDK")], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "DeckAudit", dependencies: ["DeckCore"]),
    .testTarget(name: "DeckMappingTests", dependencies: ["StreamDeckPlugin"], path: "Tests/Mapping", swiftSettings: [.swiftLanguageMode(.v5)])
])
