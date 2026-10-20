import Foundation

/// Bounded, passive vector presentation. No URLs, scripts or hardware semantics.
public struct PluginDiagram: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var width: Double
    public var height: Double
    public var summary: String
    public var elements: [PluginDiagramElement]
    public init(id: String, title: String, width: Double, height: Double, summary: String, elements: [PluginDiagramElement]) {
        self.id = id; self.title = title; self.width = width; self.height = height; self.summary = summary; self.elements = elements
    }
    public func validate() throws {
        guard ModulePackage.validKey(id), !title.isEmpty, title.count <= 60, summary.count <= 4000,
              width.isFinite, height.isFinite, (100...2400).contains(width), (100...1600).contains(height), elements.count <= 300 else { throw ModuleProblem("Invalid module diagram.") }
        for element in elements { try element.validate(width: width, height: height) }
    }
}
/// Opt-in chrome colors. Literal fallbacks stay in the payload for older hosts.
/// Do not use these roles for photographic, filament or hardware asset colors.
public enum PluginDiagramColorRole: String, Codable, Sendable {
    case background, surface, elevated, text, secondary, accent, border, success, warning, error
    public func hex(in palette: PluginThemePalette) -> String {
        switch self {
        case .background: palette.background
        case .surface: palette.surface
        case .elevated: palette.elevated
        case .text: palette.text
        case .secondary: palette.secondary
        case .accent: palette.accent
        case .border: palette.border
        case .success: palette.success
        case .warning: palette.warning
        case .error: palette.error
        }
    }
}
public struct PluginDiagramElement: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case box, ellipse, line, text }
    public var kind: Kind
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var fill: String?
    public var stroke: String?
    public var fillRole: PluginDiagramColorRole?
    public var strokeRole: PluginDiagramColorRole?
    public var text: String?
    public var font: Double?
    public var radius: Double?
    public var weight: Double?
    public init(_ kind: Kind, x: Double, y: Double, w: Double, h: Double, fill: String? = nil, stroke: String? = nil, text: String? = nil, font: Double? = nil, radius: Double? = nil, weight: Double? = nil, fillRole: PluginDiagramColorRole? = nil, strokeRole: PluginDiagramColorRole? = nil) {
        self.kind = kind; self.x = x; self.y = y; self.w = w; self.h = h; self.fill = fill; self.stroke = stroke; self.text = text; self.font = font; self.radius = radius; self.weight = weight; self.fillRole = fillRole; self.strokeRole = strokeRole
    }
    private func validateColor(_ value: String?) -> Bool {
        value == nil || value!.range(of: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", options: .regularExpression) != nil
    }
    public func validate(width: Double, height: Double) throws {
        guard [x,y,w,h].allSatisfy(\.isFinite), x >= 0, y >= 0, x <= width, y <= height,
              kind == .line || (w >= 0 && h >= 0), x + w >= 0, y + h >= 0, x + w <= width, y + h <= height,
              validateColor(fill), validateColor(stroke), (text?.count ?? 0) <= 200,
              font.map({ $0.isFinite && (8...64).contains($0) }) ?? true,
              radius.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
              weight.map({ $0.isFinite && (0.5...12).contains($0) }) ?? true else { throw ModuleProblem("Invalid module diagram element.") }
    }
}
