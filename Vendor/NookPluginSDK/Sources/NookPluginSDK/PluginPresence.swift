import Foundation

/// Presentation metadata only. This never grants tools or connects an account.
public struct PluginAssistantIdentity: Codable, Equatable, Sendable {
    public var name: String
    public var summary: String
    public var avatar: PluginAvatarPersona?
    public init(name: String, summary: String, avatar: PluginAvatarPersona? = nil) { self.name = name; self.summary = summary; self.avatar = avatar }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 40,
              summary.count <= 160 else { throw ModuleProblem("Invalid assistant identity.") }
    }
}

/// The provider owns acknowledgement and deduplication. Remove this value when
/// attention is cleared. It carries a short label, never message bodies.
public struct PluginAttention: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case message, completed, needsYou }
    public var id: String
    public var kind: Kind
    public var title: String
    public var count: Int
    public init(id: String, kind: Kind, title: String, count: Int = 1) {
        self.id=id; self.kind=kind; self.title=title; self.count=count
    }
    public func validate() throws {
        guard !id.isEmpty, id.count <= 80, !title.isEmpty, title.count <= 100,
              (1...9999).contains(count) else { throw ModuleProblem("Invalid attention state.") }
    }
}

/// Fixed, bundled imagery. This is not a general file-serving API.
public enum PluginVisualAssets {
    public static func url(path: String) -> URL? {
        if path == "/__nook_sdk__/elemental-model-viewer.js" {
            return Bundle.module.url(forResource:"elemental-model-viewer",withExtension:"js")
        }
        for style in PluginAvatarStyles.illustrations {
            for persona in [PluginAvatarPersona.nero, .ember] {
                let name = "/__nook_sdk__/avatar-" + style.id.dropFirst("illustration.".count) + "-" + persona.rawValue
                if path == name + ".png" { return PluginAvatarStyles.illustration(style: style.id, persona: persona) }
                if path == name + ".glb" { return PluginAvatarStyles.model(style: style.id, persona: persona, format: "glb") }
            }
        }
        if let match = path.range(of: "^/__nook_sdk__/elemental-(0[1-9]|1[0-9]|20)-(nero|ember)\\.png$", options:.regularExpression) {
            let name=String(path[match]).components(separatedBy:"/").last!.dropLast(4)
            return Bundle.module.url(forResource:String(name),withExtension:"png")
        }
        let name: String
        switch path {
        case "/__nook_sdk__/presence.png": name = "elemental-01-nero"
        case "/__nook_sdk__/particles.png": name = "latent-particles-v1"
        default: return nil
        }
        return Bundle.module.url(forResource: name, withExtension: "png")
    }
    public static func data(path: String) -> Data? {
        guard let url = url(path: path), let bytes = try? Data(contentsOf: url),
              bytes.count <= 2 * 1024 * 1024 else { return nil }
        return bytes
    }
    public static func mime(path: String) -> String { path.hasSuffix(".glb") ? "model/gltf-binary" : path == "/__nook_sdk__/elemental-model-viewer.js" ? "text/javascript" : "image/png" }
}
