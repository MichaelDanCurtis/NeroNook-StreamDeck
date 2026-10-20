import Foundation

/// Visual identity only. Selecting an avatar never selects an account or grants a tool.
public enum PluginAvatarPersona: String, Codable, Sendable { case nero, ember }

/// Actual local speech-output envelope, not microphone input or model activity.
public struct PluginAvatarSpeech: Codable, Equatable, Sendable {
    public var speaking: Bool
    public var level: Double
    public init(speaking: Bool = false, level: Double = 0) {
        self.speaking = speaking
        self.level = Self.weight(level, speaking: speaking)
    }
    public static func weight(_ value: Double, speaking: Bool, reducedMotion: Bool = false) -> Double {
        guard speaking, !reducedMotion, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
    /// Quiet speech is still visibly articulated at compact sizes. Compress the
    /// measured output range; zero remains exactly closed with no idle fallback.
    public static func mouthWeight(_ value: Double, speaking: Bool, reducedMotion: Bool = false) -> Double {
        sqrt(min(1, weight(value, speaking: speaking, reducedMotion: reducedMotion) * 8))
    }
    public func validate() throws {
        guard level.isFinite, (0...1).contains(level), speaking || level == 0 else { throw ModuleProblem("Invalid avatar speech state.") }
    }
    /// Exact inverse of the bundled GLB Speak clip's two rising segments.
    /// Seeking a paused clip applies its morph without looping fabricated speech.
    public static func clipTime(_ value: Double) -> Double {
        let w = weight(value, speaking: true)
        return w <= 0.7 ? w / 7 : 0.2 + (w - 0.3) / 7
    }
}

public enum PluginAvatarCatalog {
    public struct Palette: Decodable, Sendable {
        public let index: Int
        public let id: String
        public let theme: PluginTheme
        public let avatars: [String: [String: String]]
    }
    private struct Catalog: Decodable { let themes: [Palette] }
    public static let palettes: [Palette] = {
        guard let url = Bundle.module.url(forResource: "elemental-palettes-v1", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count < 256 * 1024,
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              catalog.themes.count == 20, Set(catalog.themes.map(\.id)).count == 20,
              catalog.themes.allSatisfy({ (try? $0.theme.validate()) != nil && $0.id == $0.theme.id && $0.avatars.values.allSatisfy { $0.values.allSatisfy(PluginThemeColor.valid) } }) else { return [] }
        return catalog.themes
    }()
    public static var additionalThemes: [PluginTheme] { palettes.dropFirst(3).map(\.theme) }
    public static func palette(theme: String) -> Palette? { palettes.first { $0.id == theme } ?? palettes.first }
    public static func thumbnail(persona: PluginAvatarPersona, theme: String) -> URL? {
        let index = palette(theme: theme)?.index ?? 1
        return Bundle.module.url(forResource: String(format: "elemental-%02d-%@", index, persona.rawValue), withExtension: "png")
    }
    public static func model(persona: PluginAvatarPersona) -> URL? {
        Bundle.module.url(forResource: "elemental-" + persona.rawValue, withExtension: "usdz")
    }
}
