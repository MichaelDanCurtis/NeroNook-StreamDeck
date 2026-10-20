import Foundation

/// Short-lived display data. Placement, focus, animation and expiry belong to the host.
public struct PluginTransientCaption: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case active, result, dismiss }
    public enum Placement: String, Codable, Sendable { case nook, bottom }
    public enum Activity: String, Codable, Sendable { case recording, processing, complete, error }
    public var phase: Phase
    public var title: String
    public var text: String
    public var detail: String
    public var symbol: String
    public var displayNumber: UInt32?
    /// Optional v2 fields. Their absence preserves the v1 floating caption.
    public var placement: Placement?
    public var activity: Activity?
    public var level: Double?
    public init(_ phase: Phase, title: String = "", text: String = "", detail: String = "", symbol: String = "text.bubble", displayNumber: UInt32? = nil,
                placement: Placement? = nil, activity: Activity? = nil, level: Double? = nil) {
        self.phase = phase; self.title = title; self.text = text; self.detail = detail; self.symbol = symbol; self.displayNumber = displayNumber
        self.placement = placement; self.activity = activity; self.level = level
    }
    public func validate() throws {
        guard title.count <= 80, text.utf8.count <= 1200, detail.count <= 160, symbol.count <= 50,
              (displayNumber == nil || displayNumber! > 0), level.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              phase == .dismiss || !title.isEmpty else { throw ModuleProblem("Invalid transient caption.") }
    }
}
