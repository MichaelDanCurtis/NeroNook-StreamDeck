// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NookPluginSDK", platforms: [.macOS(.v14), .iOS(.v17), .macCatalyst(.v17)], products: [.library(name: "NookPluginSDK", targets: ["NookPluginSDK"])], targets: [.target(name: "NookPluginSDK", resources: [.process("Resources")])])
