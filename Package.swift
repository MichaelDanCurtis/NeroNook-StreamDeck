// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NeroNookStreamDeck", platforms: [.macOS(.v14)], products: [.executable(name: "deck-audit", targets: ["DeckAudit"])], targets: [
    .target(name: "DeckCore"),
    .executableTarget(name: "DeckAudit", dependencies: ["DeckCore"])
])
