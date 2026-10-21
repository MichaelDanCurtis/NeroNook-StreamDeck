import Foundation

public struct PluginManifest: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var apiVersion: Int
    public var summary: String
    public var capabilities: [String]
    public var launchMode: String? = nil
    public var icon: PluginIcon? = nil
    public var assistant: PluginAssistantIdentity? = nil
    public func validate() throws {
        try icon?.validate()
        try assistant?.validate()
        guard launchMode == nil || launchMode == "application" else { throw ModuleProblem("Unsupported plugin launch mode.") }
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
    public enum Placement: String, Codable, Sendable { case primary, menu }
    public var id: String
    public var label: String
    public var enabled: Bool
    public var symbol: String?
    public var confirmation: String?
    public var placement: Placement?
    public init(_ id: String, _ label: String, enabled: Bool = true, symbol: String? = nil, confirmation: String? = nil, placement: Placement? = nil) { self.id = id; self.label = label; self.enabled = enabled; self.symbol = symbol; self.confirmation = confirmation; self.placement = placement }
}
public struct PluginSection: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var imagePNG: Data?
    public init(_ title: String, _ detail: String, imagePNG: Data? = nil) { self.title = title; self.detail = detail; self.imagePNG = imagePNG }
}
/// Bounded native cards. Action IDs are opaque and interpreted only by the plugin.
public struct PluginControlCard: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var value: String
    public var detail: String
    public var symbol: String?
    public var highlighted: Bool
    public var actions: [PluginAction]
    public init(_ id: String, title: String, subtitle: String = "", value: String = "", detail: String = "", symbol: String? = nil, highlighted: Bool = false, actions: [PluginAction] = []) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.value = value; self.detail = detail; self.symbol = symbol; self.highlighted = highlighted; self.actions = actions
    }
}
/// A plugin-defined tab for the shared dashboard stage.
public struct PluginPanel: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var usesMedia: Bool
    public var sections: [PluginSection]
    public var diagrams: [PluginDiagram]?
    public var cards: [PluginControlCard]?
    public var forms: [PluginForm]?
    public var collection: PluginCollection?
    public var customView: PluginCustomView?
    public init(_ id: String, _ title: String, usesMedia: Bool = false, sections: [PluginSection] = [], diagrams: [PluginDiagram]? = nil, cards: [PluginControlCard]? = nil, forms: [PluginForm]? = nil, collection: PluginCollection? = nil, customView: PluginCustomView? = nil) {
        self.id = id; self.title = title; self.usesMedia = usesMedia; self.sections = sections; self.diagrams = diagrams; self.cards = cards; self.forms = forms; self.collection = collection; self.customView = customView
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
    public var volumeEndpoints: [PluginVolumeEndpoint]?
    public var attention: PluginAttention?
    /// Ephemeral capture/playback occupancy; host aggregates without interpreting provider state.
    public var avatarInteractionBusy: Bool? = nil
    public var assistantSpeech: PluginAvatarSpeech? = nil
    public init(title: String, status: String, activity: String = "", progress: Double? = nil, fields: [PluginField] = [], actions: [PluginAction] = [], metrics: [PluginField]? = nil, sections: [PluginSection]? = nil, media: PluginMedia? = nil, badge: String? = nil, panels: [PluginPanel]? = nil, iconPNG: Data? = nil, volumeEndpoints: [PluginVolumeEndpoint]? = nil, attention: PluginAttention? = nil) {
        self.title = title; self.status = status; self.activity = activity; self.progress = progress; self.fields = fields; self.actions = actions
        self.metrics = metrics; self.sections = sections; self.media = media; self.badge = badge; self.panels = panels; self.iconPNG = iconPNG; self.volumeEndpoints = volumeEndpoints; self.attention = attention
    }
    public var displayActions: [PluginAction] { actions + (panels ?? []).flatMap { ($0.cards ?? []).flatMap(\.actions) + ($0.collection?.displayActions ?? []) } }
    public func enabledDisplayAction(_ id: String) -> PluginAction? { displayActions.first { $0.id == id && $0.enabled } }
    public func validate() throws {
        try attention?.validate()
        try assistantSpeech?.validate()
        if let endpoints = volumeEndpoints {
            guard endpoints.count <= 8, Set(endpoints.map(\.id)).count == endpoints.count else { throw ModuleProblem("Invalid volume endpoint list.") }
            for endpoint in endpoints { try endpoint.validate() }
        }
        var known: [String: PluginAction] = [:]
        for action in displayActions {
            guard ModulePackage.validKey(action.id), !action.label.isEmpty, action.label.count <= 80,
                  (action.symbol?.count ?? 0) <= 80, (action.confirmation?.count ?? 0) <= 400,
                  known[action.id].map({ $0 == action }) ?? true else { throw ModuleProblem("Invalid or conflicting card action.") }
            known[action.id] = action
        }
        let allCards = (panels ?? []).flatMap { $0.cards ?? [] }
        guard allCards.count <= 192 else { throw ModuleProblem("Too many control cards.") }
        guard (panels ?? []).reduce(0, { $0 + ($1.collection?.items.count ?? 0) }) <= 192 else { throw ModuleProblem("Too many collection items.") }
        for panel in panels ?? [] {
            if let customView = panel.customView {
                guard panel.cards == nil, panel.forms == nil, panel.diagrams == nil, panel.collection == nil, !panel.usesMedia else { throw ModuleProblem("Conflicting custom view panel.") }
                try customView.validate()
            }
            if let collection = panel.collection {
                guard panel.cards == nil, panel.forms == nil, panel.diagrams == nil, !panel.usesMedia else { throw ModuleProblem("Conflicting collection panel.") }
                try collection.validate()
            }
            if let forms = panel.forms {
                guard (1...4).contains(forms.count), panel.cards == nil, panel.diagrams == nil, !panel.usesMedia,
                      Set(forms.map(\.id)).count == forms.count else { throw ModuleProblem("Invalid form panel.") }
                for form in forms { try form.validate() }
            }
            if let cards = panel.cards {
                guard cards.count <= 96, panel.diagrams == nil, !panel.usesMedia,
                      Set(cards.map(\.id)).count == cards.count else { throw ModuleProblem("Invalid control card panel.") }
                for card in cards {
                    guard ModulePackage.validKey(card.id), !card.title.isEmpty, card.title.count <= 80,
                          card.subtitle.count <= 100, card.value.count <= 100, card.detail.count <= 300,
                          (card.symbol?.count ?? 0) <= 80, card.actions.count <= 3,
                          Set(card.actions.map(\.id)).count == card.actions.count else { throw ModuleProblem("Invalid control card.") }
                }
            }
        }
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
    /// Optional visibility-v2: presentation is distinct from inline camera demand.
    public var presented: Bool?
    public var mediaVisible: Bool?
    public var frame: PluginFrame?
    public var bus: PluginBusMessage?
    public var agenda: PluginAgenda?
    public var agendaDate: Date?
    public var viewEvent: PluginViewEvent?
    public var volumeCommand: PluginVolumeCommand?
    public var volumeResult: PluginVolumeResult?
    public var viewResource: PluginViewResourceRequest?
    public var viewResourceResult: PluginViewResourceResult?
    public var viewResourceCancel: UUID?
    public var appearance: PluginAppearanceDelivery?
    public var caption: PluginTransientCaption?
    public init(type: String, pluginID: String, session: UUID, sequence: UInt64 = 0, action: String? = nil, snapshot: PluginSnapshot? = nil, features: [String]? = nil, visible: Bool? = nil, presented: Bool? = nil, mediaVisible: Bool? = nil, frame: PluginFrame? = nil, bus: PluginBusMessage? = nil, agenda: PluginAgenda? = nil, agendaDate: Date? = nil, viewEvent: PluginViewEvent? = nil, volumeCommand: PluginVolumeCommand? = nil, volumeResult: PluginVolumeResult? = nil, viewResource: PluginViewResourceRequest? = nil, viewResourceResult: PluginViewResourceResult? = nil, viewResourceCancel: UUID? = nil, caption: PluginTransientCaption? = nil, appearance: PluginAppearanceDelivery? = nil) {
        self.type = type; self.pluginID = pluginID; self.session = session; self.sequence = sequence; self.action = action; self.snapshot = snapshot; self.features = features; self.visible = visible; self.presented = presented; self.mediaVisible = mediaVisible; self.frame = frame; self.bus = bus; self.agenda = agenda; self.agendaDate = agendaDate; self.viewEvent = viewEvent; self.volumeCommand = volumeCommand; self.volumeResult = volumeResult; self.viewResource = viewResource; self.viewResourceResult = viewResourceResult; self.viewResourceCancel = viewResourceCancel; self.caption = caption; self.appearance = appearance
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
