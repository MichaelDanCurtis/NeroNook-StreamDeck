import Foundation

public enum PluginAppearanceMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark
    public var title: String { self == .system ? "Follow System" : self == .light ? "Light" : "Dark" }
}
public enum PluginColorScheme: String, Codable, CaseIterable, Sendable { case light, dark }

/// Declarative semantic colors. Images, video and integration branding are not
/// recolored. A theme cannot contain executable CSS, URLs or shader programs.
public struct PluginThemePalette: Codable, Equatable, Sendable {
    public var background: String
    public var surface: String
    public var elevated: String
    public var text: String
    public var secondary: String
    public var accent: String
    public var onAccent: String
    public var border: String
    public var focus: String
    public var success: String
    public var warning: String
    public var error: String
    public init(background: String, surface: String, elevated: String, text: String, secondary: String, accent: String, onAccent: String, border: String, focus: String, success: String, warning: String, error: String) {
        self.background=background; self.surface=surface; self.elevated=elevated; self.text=text; self.secondary=secondary; self.accent=accent; self.onAccent=onAccent; self.border=border; self.focus=focus; self.success=success; self.warning=warning; self.error=error
    }
    public var colors: [String: String] {
        ["background": background, "surface": surface, "elevated": elevated,
         "text": text, "secondary": secondary, "accent": accent, "on-accent": onAccent,
         "border": border, "focus": focus, "success": success, "warning": warning, "error": error]
    }
    public func validate() throws {
        guard colors.values.allSatisfy(PluginThemeColor.valid) else { throw ModuleProblem("Use six-digit hex colors, such as #B93827.") }
        for value in [background, surface, elevated] {
            guard PluginThemeColor.contrast(text, value) >= 4.5, PluginThemeColor.contrast(secondary, value) >= 4.5 else {
                throw ModuleProblem("Text and secondary text need more contrast against the background and cards. Choose darker text for light surfaces, or lighter text for dark surfaces.")
            }
        }
        guard PluginThemeColor.contrast(onAccent, accent) >= 4.5 else { throw ModuleProblem("Button text needs more contrast against the accent color.") }
        guard PluginThemeColor.contrast(focus, surface) >= 3 else { throw ModuleProblem("The keyboard focus color needs more contrast against cards.") }
    }
}

public enum PluginThemeTreatment: String, Codable, Sendable { case circuit }

public struct PluginThemeStyle: Codable, Equatable, Sendable {
    /// Optional: older theme files keep their existing soft glass treatment.
    public var treatment: PluginThemeTreatment?
    public var cornerRadius: Double = 20
    public var controlRadius: Double = 12
    public var shellOpacity: Double = 0.9
    public var cardOpacity: Double = 0.98
    public var spacingScale: Double = 1
    public var borderWidth: Double = 1
    public init() {}
    public func validate() throws {
        let pairs: [(Double, ClosedRange<Double>)] = [(cornerRadius, 8...32), (controlRadius, 6...24), (shellOpacity, 0.65...1), (cardOpacity, 0.92...1), (spacingScale, 0.9...1.2), (borderWidth, 0.5...2)]
        guard pairs.allSatisfy({ $0.0.isFinite && $0.1.contains($0.0) }) else { throw ModuleProblem("Theme shape, spacing or transparency is outside the supported range.") }
    }
}

/// Both variants are required Codable fields: incomplete imports fail before
/// replacing a saved theme or changing any active surface.
public struct PluginTheme: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var revision: Int = 1
    public var light: PluginThemePalette
    public var dark: PluginThemePalette
    public var style: PluginThemeStyle = .init()
    public init(id: String, name: String, revision: Int = 1, light: PluginThemePalette, dark: PluginThemePalette, style: PluginThemeStyle = .init()) {
        self.id=id; self.name=name; self.revision=revision; self.light=light; self.dark=dark; self.style=style
    }
    public func palette(_ scheme: PluginColorScheme) -> PluginThemePalette { scheme == .light ? light : dark }
    public func validate() throws {
        guard id.range(of: "^[a-z][a-z0-9.-]{0,95}$", options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), (1...1_000_000).contains(revision) else {
            throw ModuleProblem("Choose a theme name of 1–64 characters and a valid theme identity.")
        }
        guard [light.background,light.surface,light.elevated].allSatisfy({ PluginThemeColor.luminance($0) >= 0.45 }),
              [dark.background,dark.surface,dark.elevated].allSatisfy({ PluginThemeColor.luminance($0) <= 0.18 }) else {
            throw ModuleProblem("A theme needs light surfaces in its Light palette and dark surfaces in its Dark palette.")
        }
        do { try light.validate() } catch { throw ModuleProblem("Light palette: " + error.localizedDescription) }
        do { try dark.validate() } catch { throw ModuleProblem("Dark palette: " + error.localizedDescription) }
        try style.validate()
    }
    public static var nearlyNothing: Self {
        .init(id: "nearly-nothing", name: "Nearly Nothing",
              light: .init(background: "#EDE9E2", surface: "#F8F6F2", elevated: "#FFFFFF", text: "#242321", secondary: "#66615B", accent: "#B93827", onAccent: "#FFFFFF", border: "#C8C1B7", focus: "#A72E20", success: "#2B6747", warning: "#815815", error: "#A72E20"),
              dark: .init(background: "#1E1D1B", surface: "#292724", elevated: "#34312D", text: "#F3EFE8", secondary: "#C1B9AE", accent: "#F2806C", onAccent: "#241A17", border: "#625C54", focus: "#F2A18E", success: "#9BCDAD", warning: "#EBC486", error: "#F5A697"))
    }
    public static var quietSlate: Self {
        var theme = nearlyNothing
        theme.id = "quiet-slate"; theme.name = "Quiet Slate"
        theme.light = .init(background: "#E7ECF1", surface: "#F5F7FA", elevated: "#FFFFFF", text: "#1C2935", secondary: "#526271", accent: "#215A8A", onAccent: "#FFFFFF", border: "#B5C4D0", focus: "#215A8A", success: "#286549", warning: "#805912", error: "#A33436")
        theme.dark = .init(background: "#19232D", surface: "#222F3B", elevated: "#2C3B48", text: "#EDF4F9", secondary: "#B4C8D8", accent: "#8CC4ED", onAccent: "#13212D", border: "#546B7D", focus: "#9CD4FF", success: "#9BCDAD", warning: "#EBC486", error: "#F5A697")
        return theme
    }
    public static var circuit: Self {
        var style = PluginThemeStyle()
        style.treatment = .circuit; style.cornerRadius = 12; style.controlRadius = 8
        style.shellOpacity = 0.94; style.cardOpacity = 0.98
        return .init(id:"nero-circuit",name:"Nero Circuit",
            light:.init(background:"#E9F3F8",surface:"#F5FAFD",elevated:"#FFFFFF",text:"#102D3E",secondary:"#426274",accent:"#006D87",onAccent:"#FFFFFF",border:"#80ADBF",focus:"#006D87",success:"#246B53",warning:"#805512",error:"#A62D48"),
            dark:.init(background:"#040D17",surface:"#091A29",elevated:"#102638",text:"#E4F7FF",secondary:"#A1C6D8",accent:"#64E5FF",onAccent:"#032131",border:"#285E76",focus:"#8DF0FF",success:"#79E3BD",warning:"#F4CB7A",error:"#FFA3BA"),style:style)
    }
    public static var builtins: [Self] { [.nearlyNothing, .quietSlate, .circuit] + PluginAvatarCatalog.additionalThemes }
    public static func importing(_ data: Data) throws -> Self {
        guard data.count <= 32768 else { throw ModuleProblem("A theme file must be smaller than 32 KB.") }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
}

public enum PluginThemeColor {
    public static func valid(_ value: String) -> Bool { value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }
    public static func luminance(_ value: String) -> Double {
        guard valid(value), let rgb = UInt32(value.dropFirst(), radix: 16) else { return 0 }
        func channel(_ byte: UInt32) -> Double { let x = Double(byte)/255; return x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) }
        return 0.2126*channel((rgb>>16)&255) + 0.7152*channel((rgb>>8)&255) + 0.0722*channel(rgb&255)
    }
    public static func contrast(_ a: String, _ b: String) -> Double {
        let x = luminance(a), y = luminance(b); return (max(x,y)+0.05)/(min(x,y)+0.05)
    }
}

public struct PluginAppearanceContext: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var surfaceID: String
    public var screenNumber: UInt32?
    public var revision: UInt64
    public var mode: PluginAppearanceMode
    public var scheme: PluginColorScheme
    public var theme: PluginTheme
    public var reduceTransparency = false
    public var reduceMotion = false
    public var increasedContrast = false
    /// Transient presentation guard; never changes permissions or saved preferences.
    public var avatarReactionsSuppressed: Bool? = nil
    public var avatars: PluginAvatarSelection?
    public var seasonalScene: PluginSeasonalScene?
    /// Expanded calendar travels in a new optional key. The legacy seasonalScene
    /// key is restricted to the original three holidays for older SDK clients.
    public var seasonalSurface: PluginSeasonalScene?
    /// New calendar values must not enter the earlier optional fields.
    public var seasonalStory: PluginSeasonalScene?
    public var activeSeasonalScene: PluginSeasonalScene? { seasonalStory ?? seasonalSurface ?? seasonalScene }
    public var palette: PluginThemePalette { theme.palette(scheme) }
    public init(surfaceID: String = "system", screenNumber: UInt32? = nil, revision: UInt64 = 0, mode: PluginAppearanceMode = .system, scheme: PluginColorScheme = .light, theme: PluginTheme = .nearlyNothing, reduceTransparency: Bool = false, reduceMotion: Bool = false, increasedContrast: Bool = false) {
        self.surfaceID=surfaceID; self.screenNumber=screenNumber; self.revision=revision; self.mode=mode; self.scheme=scheme; self.theme=theme
        self.reduceTransparency=reduceTransparency; self.reduceMotion=reduceMotion; self.increasedContrast=increasedContrast
    }
    public func validate() throws {
        guard version == 1, revision <= 9_007_199_254_740_991, !surfaceID.isEmpty, surfaceID.utf8.count <= 128 else { throw ModuleProblem("Invalid appearance context.") }
        try theme.validate()
        try avatars?.validate()
        try seasonalScene?.validate()
        try seasonalSurface?.validate()
        try seasonalStory?.validate()
    }
}

public struct PluginAppearanceDelivery: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var revision: UInt64
    public var shared: PluginAppearanceContext
    public var displays: [PluginAppearanceContext]
    public init(revision: UInt64, shared: PluginAppearanceContext, displays: [PluginAppearanceContext] = []) { self.revision=revision; self.shared=shared; self.displays=displays }
    private enum CodingKeys: String, CodingKey { case version,revision,shared,displays }
    /// A malformed optional presentation extension is rejected by validate(),
    /// without tearing down a valid recording/action transport while decoding.
    public init(from decoder: Decoder) throws {
        do {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            version=try c.decode(Int.self,forKey:.version)
            revision=try c.decode(UInt64.self,forKey:.revision)
            shared=try c.decode(PluginAppearanceContext.self,forKey:.shared)
            displays=try c.decode([PluginAppearanceContext].self,forKey:.displays)
        } catch { version=0; revision=0; shared = .init(); displays=[] }
    }
    public func validate() throws {
        guard version == 1, displays.count <= 16, shared.revision == revision,
              Set(displays.map(\.surfaceID)).count == displays.count,
              Set(displays.compactMap(\.screenNumber)).count == displays.count,
              displays.allSatisfy({ $0.screenNumber != nil && $0.revision == revision }),
              (try JSONEncoder().encode(self)).count <= 96*1024 else { throw ModuleProblem("Invalid appearance delivery.") }
        try shared.validate(); try displays.forEach { try $0.validate() }
    }
}
