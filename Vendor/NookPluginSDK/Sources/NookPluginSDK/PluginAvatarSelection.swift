import Foundation

/// Optional visual choices; identity, accounts and actions remain independent.
/// Unknown style IDs resolve to the original animated elemental rig.
public struct PluginAvatarSelection: Codable, Equatable, Sendable {
    public var neroStyle: String = "elemental"
    public var emberStyle: String = "elemental"
    public var neroPalette: String?
    public var emberPalette: String?
    public init() {}
    public func style(_ persona: PluginAvatarPersona) -> String { persona == .nero ? neroStyle : emberStyle }
    public func palette(_ persona: PluginAvatarPersona, fallback: String) -> String { (persona == .nero ? neroPalette : emberPalette) ?? fallback }
    public func validate() throws {
        for id in [neroStyle, emberStyle] + [neroPalette, emberPalette].compactMap({ $0 }) {
            guard id.utf8.count <= 96, id.range(of: "^[a-z][a-z0-9.-]*$", options: .regularExpression) != nil else { throw ModuleProblem("Invalid avatar choice.") }
        }
    }
}
public enum PluginAvatarStyles {
    public struct Style: Codable, Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let kind: String
        public let animatedFace: Bool
    }
    public static let illustrations: [Style] = {
        guard let url = Bundle.module.url(forResource: "avatar-illustrations-v1", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count < 32768,
              let values = try? JSONDecoder().decode([Style].self, from: data), values.count <= 32,
              Set(values.map(\.id)).count == values.count else { return [] }
        return values
    }()
    public static func model(style: String, persona: PluginAvatarPersona, format: String = "usdz") -> URL? {
        guard illustrations.contains(where: { $0.id == style && $0.animatedFace }), ["usdz", "glb"].contains(format) else { return nil }
        return Bundle.module.url(forResource: "avatar-" + style.dropFirst("illustration.".count) + "-" + persona.rawValue, withExtension: format)
    }
    public static func illustration(style: String, persona: PluginAvatarPersona) -> URL? {
        guard illustrations.contains(where: { $0.id == style }) else { return nil }
        return Bundle.module.url(forResource: "avatar-" + style.dropFirst("illustration.".count) + "-" + persona.rawValue, withExtension: "png")
    }
}
