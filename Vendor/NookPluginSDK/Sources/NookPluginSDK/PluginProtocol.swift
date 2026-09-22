import Foundation

public struct PluginManifest: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var apiVersion: Int
    public var summary: String
    public var capabilities: [String]
    public func validate() throws {
        guard apiVersion == 1 else { throw ModuleProblem("This plugin requires a different plugin interface version.") }
        guard id.range(of: #"^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$"#, options: .regularExpression) != nil,
              id.count <= 100, !name.isEmpty, name.count <= 80, summary.count <= 500,
              version.range(of: #"^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$"#, options: .regularExpression) != nil,
              capabilities.count <= 12, capabilities.allSatisfy({ !$0.isEmpty && $0.count <= 160 }) else {
            throw ModuleProblem("Invalid plugin manifest.")
        }
    }
}

public struct PluginField: Codable, Equatable, Sendable {
    public var label: String
    public var value: String
    public var symbol: String?
    public init(_ label: String, _ value: String, symbol: String? = nil) { self.label = label; self.value = value; self.symbol = symbol }
}
public struct PluginAction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var enabled: Bool
    public var symbol: String?
    public init(_ id: String, _ label: String, enabled: Bool = true, symbol: String? = nil) { self.id = id; self.label = label; self.enabled = enabled; self.symbol = symbol }
}
public struct PluginSection: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var imagePNG: Data?
    public init(_ title: String, _ detail: String, imagePNG: Data? = nil) { self.title = title; self.detail = detail; self.imagePNG = imagePNG }
}
/// A plugin-defined tab for the shared dashboard stage. Content is display-only.
public struct PluginPanel: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var usesMedia: Bool
    public var sections: [PluginSection]
    public var diagrams: [PluginDiagram]?
    public init(_ id: String, _ title: String, usesMedia: Bool = false, sections: [PluginSection] = [], diagrams: [PluginDiagram]? = nil) {
        self.id = id; self.title = title; self.usesMedia = usesMedia; self.sections = sections; self.diagrams = diagrams
    }
}
public struct PluginMedia: Codable, Equatable, Sendable {
    public var label: String
    public var status: String
    public init(label: String, status: String) { self.label = label; self.status = status }
}
public struct PluginFrame: Codable, Sendable {
    public var jpeg: Data
    public init(jpeg: Data) { self.jpeg = jpeg }
}
public struct PluginSnapshot: Codable, Equatable, Sendable {
    public var title: String
    public var status: String
    public var activity: String
    public var progress: Double?
    public var fields: [PluginField]
    public var actions: [PluginAction]
    public var metrics: [PluginField]?
    public var sections: [PluginSection]?
    public var media: PluginMedia?
    public var badge: String?
    public var panels: [PluginPanel]?
    public var iconPNG: Data?
    public init(title: String, status: String, activity: String = "", progress: Double? = nil, fields: [PluginField] = [], actions: [PluginAction] = [], metrics: [PluginField]? = nil, sections: [PluginSection]? = nil, media: PluginMedia? = nil, badge: String? = nil, panels: [PluginPanel]? = nil, iconPNG: Data? = nil) {
        self.title = title; self.status = status; self.activity = activity; self.progress = progress; self.fields = fields; self.actions = actions
        self.metrics = metrics; self.sections = sections; self.media = media; self.badge = badge; self.panels = panels; self.iconPNG = iconPNG
    }
    public func validate() throws {
        let artwork = ([iconPNG] + (sections ?? []).map(\.imagePNG) + (panels ?? []).flatMap { $0.sections.map(\.imagePNG) }).compactMap { $0 }
        guard artwork.allSatisfy({ !$0.isEmpty && $0.count <= 8192 }), artwork.reduce(0, { $0 + $1.count }) <= 81920 else { throw ModuleProblem("Plugin artwork exceeded its limit.") }
        if let panels {
            for panel in panels {
                if let diagrams = panel.diagrams {
                    guard !diagrams.isEmpty, diagrams.count <= 10, Set(diagrams.map(\.id)).count == diagrams.count, !panel.usesMedia else { throw ModuleProblem("Invalid module diagram pages.") }
                    for diagram in diagrams { try diagram.validate() }
                }
            }
            guard !panels.isEmpty, panels.count <= 6, Set(panels.map(\.id)).count == panels.count,
                  panels.allSatisfy({ ModulePackage.validKey($0.id) && !$0.title.isEmpty && $0.title.count <= 40 && $0.sections.count <= 12 && $0.sections.allSatisfy({ $0.title.count <= 80 && $0.detail.count <= 1200 }) }) else { throw ModuleProblem("Invalid dashboard panels.") }
        }
        guard (metrics?.count ?? 0) <= 8, metrics?.allSatisfy({ $0.label.count <= 80 && $0.value.count <= 200 && ($0.symbol?.count ?? 0) <= 80 }) ?? true,
              (sections?.count ?? 0) <= 8, sections?.allSatisfy({ $0.title.count <= 80 && $0.detail.count <= 1200 }) ?? true,
              (media?.label.count ?? 0) <= 120, (media?.status.count ?? 0) <= 300, (badge?.count ?? 0) <= 50 else { throw ModuleProblem("Invalid dashboard data.") }
        guard title.count <= 300, status.count <= 500, activity.count <= 100, fields.count <= 24, actions.count <= 12,
              fields.allSatisfy({ $0.label.count <= 80 && $0.value.utf8.count <= 2048 && ($0.symbol?.count ?? 0) <= 80 }),
              actions.allSatisfy({ ModulePackage.validKey($0.id) && !$0.label.isEmpty && $0.label.count <= 80 && ($0.symbol?.count ?? 0) <= 80 }),
              Set(actions.map(\.id)).count == actions.count,
              progress.map({ $0.isFinite && (0...100).contains($0) }) ?? true else { throw ModuleProblem("Invalid plugin display data.") }
    }
}

/// One line of UTF-8 JSON per message. No URLs, credentials or executable code in snapshots.
public struct PluginMessage: Codable, Sendable {
    public var apiVersion: Int = 1
    public var type: String
    public var pluginID: String
    public var session: UUID
    public var sequence: UInt64
    public var action: String?
    public var snapshot: PluginSnapshot?
    public var features: [String]?
    public var visible: Bool?
    public var frame: PluginFrame?
    public var bus: PluginBusMessage?
    public init(type: String, pluginID: String, session: UUID, sequence: UInt64 = 0, action: String? = nil, snapshot: PluginSnapshot? = nil, features: [String]? = nil, visible: Bool? = nil, frame: PluginFrame? = nil, bus: PluginBusMessage? = nil) {
        self.type = type; self.pluginID = pluginID; self.session = session; self.sequence = sequence; self.action = action; self.snapshot = snapshot; self.features = features; self.visible = visible; self.frame = frame; self.bus = bus
    }
    public func encoded() throws -> Data {
        var data = try JSONEncoder().encode(self)
        guard data.count <= PluginLines.maximumBytes else { throw ModuleProblem("Plugin message exceeds its limit.") }
        data.append(10); return data
    }
}

public struct PluginLines: Sendable {
    public static let maximumBytes = 128 * 1024
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [PluginMessage] {
        guard buffer.count + data.count <= Self.maximumBytes * 2 else { throw ModuleProblem("Plugin output exceeded its limit.") }
        buffer.append(data)
        var messages: [PluginMessage] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            guard !line.isEmpty, line.count <= Self.maximumBytes else { throw ModuleProblem("Invalid plugin message size.") }
            let message = try JSONDecoder().decode(PluginMessage.self, from: line)
            guard message.apiVersion == 1 else { throw ModuleProblem("Incompatible plugin interface.") }
            messages.append(message)
            buffer.removeSubrange(...end)
        }
        guard buffer.count <= Self.maximumBytes else { throw ModuleProblem("Unterminated plugin message exceeded its limit.") }
        return messages
    }
}
