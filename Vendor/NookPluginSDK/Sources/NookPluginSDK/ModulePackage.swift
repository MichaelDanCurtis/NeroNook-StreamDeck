import Foundation

public struct ModuleProblem: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Preview API 1: a bounded JSON package, with no archive extraction or external assets.
public struct ModulePackage: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var hostAPIVersion: Int
    public var id: String
    public var name: String
    public var version: String
    public var author: String
    public var summary: String
    public var permissions: [String]
    public var initialState: [String: String]
    public var settings: [ModuleSetting]
    public var actions: [ModuleAction]
    public var card: [ModuleComponent]
    public var page: [ModuleComponent]
    public var activity: String?
    public var feeds: [ModuleFeed]?
    public var script: String

    public static let maximumBytes = 256 * 1024
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ModuleProblem("Module exceeds the 256 KB package limit.") }
        let package: Self
        do { package = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ModuleProblem("This is not a valid NeroNook module package: \(error.localizedDescription)") }
        try package.validate()
        return package
    }
    public func validate() throws {
        guard schemaVersion == 1, hostAPIVersion == 1 else { throw ModuleProblem("This module needs a different NeroNook module API. This preview supports version 1.") }
        guard id.range(of: #"^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$"#, options: .regularExpression) != nil,
              id.count <= 100 else { throw ModuleProblem("Module ID must be a namespaced name such as cafe.nero.hello.") }
        guard version.range(of: #"^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$"#, options: .regularExpression) != nil else { throw ModuleProblem("Use a three-part module version, such as 1.0.0.") }
        guard !name.isEmpty, name.count <= 80, !author.isEmpty, author.count <= 100, summary.count <= 500,
              script.utf8.count <= 128 * 1024 else { throw ModuleProblem("Module metadata or code exceeds its limit.") }
        guard Set(permissions).isSubset(of: ["local.mqtt.read"]) else { throw ModuleProblem("This module requests an unsupported permission.") }
        let inputs = feeds ?? []
        guard inputs.count <= 1, Set(inputs.map(\.id)).count == inputs.count,
              inputs.allSatisfy({ Self.validKey($0.id) && !$0.label.isEmpty && $0.label.count <= 80 }),
              inputs.isEmpty == !permissions.contains("local.mqtt.read") else { throw ModuleProblem("Declare one feed with the local.mqtt.read permission, or no feeds and no network permission.") }
        try Self.validateState(initialState)
        guard settings.count <= 12, actions.count <= 20, card.count <= 12, page.count <= 40 else { throw ModuleProblem("Too many settings, actions or view components.") }
        guard Set(settings.map(\.id)).count == settings.count, Set(actions.map(\.id)).count == actions.count else { throw ModuleProblem("Setting and action IDs must be unique.") }
        for setting in settings {
            guard Self.validKey(setting.id), !setting.label.isEmpty, setting.label.count <= 80, setting.defaultValue.count <= 200 else { throw ModuleProblem("Invalid module setting.") }
        }
        for action in actions {
            guard Self.validKey(action.id), !action.label.isEmpty, action.label.count <= 80 else { throw ModuleProblem("Invalid module action.") }
        }
        for components in [card, page] {
            guard Set(components.map(\.id)).count == components.count else { throw ModuleProblem("View component IDs must be unique within each view.") }
            for component in components {
                guard Self.validKey(component.id), component.text.count <= 500 else { throw ModuleProblem("Invalid view component.") }
                if component.kind == .button {
                    guard actions.contains(where: { $0.id == component.action }) else { throw ModuleProblem("A button refers to an undeclared action.") }
                }
                if component.kind == .progress {
                    guard let key = component.valueKey, Self.validKey(key) else { throw ModuleProblem("Progress requires a state key.") }
                }
            }
        }
        guard (activity?.count ?? 0) <= 100 else { throw ModuleProblem("Compact activity text is too long.") }
    }
    public static func validateState(_ state: [String: String]) throws {
        guard state.count <= 64, state.allSatisfy({ validKey($0.key) && $0.value.utf8.count <= 2048 }),
              (try JSONEncoder().encode(state)).count <= 32 * 1024 else { throw ModuleProblem("Module returned invalid or oversized state.") }
    }
    public static func validKey(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil
    }
    public var defaultSettings: [String: String] { Dictionary(uniqueKeysWithValues: settings.map { ($0.id, $0.defaultValue) }) }
    public func text(_ template: String, state: [String: String], configuration: [String: String]) -> String {
        // One pass: state text cannot inject a second template expansion.
        let regex = try! NSRegularExpression(pattern: #"\{([A-Za-z][A-Za-z0-9_]*)\}"#)
        var result = template
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: template), let range = Range(match.range, in: result) else { continue }
            let key = String(template[keyRange])
            result.replaceSubrange(range, with: state[key] ?? configuration[key] ?? "—")
        }
        return String(result.prefix(2048))
    }
}

public struct ModuleSetting: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var defaultValue: String
}
public struct ModuleAction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
}
public struct ModuleComponent: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case text, heading, badge, progress, button }
    public var id: String
    public var kind: Kind
    public var text: String
    public var valueKey: String?
    public var action: String?
}

public struct ModuleFeed: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
}
public struct ModuleFeedEvent: Codable, Sendable {
    public var feedID: String
    public var json: String
    public init(feedID: String, json: String) { self.feedID = feedID; self.json = json }
}
public struct ModuleRequest: Codable, Sendable {
    public var package: ModulePackage
    public var state: [String: String]
    public var configuration: [String: String]
    public var action: String?
    public var event: ModuleFeedEvent?
    public init(package: ModulePackage, state: [String: String], configuration: [String: String], action: String?, event: ModuleFeedEvent? = nil) {
        self.package = package; self.state = state; self.configuration = configuration; self.action = action; self.event = event
    }
}
public struct ModuleResponse: Codable, Sendable {
    public var state: [String: String]?
    public var error: String?
    public init(state: [String: String]? = nil, error: String? = nil) { self.state = state; self.error = error }
}

public struct InstalledModule: Codable, Sendable, Identifiable {
    public var package: ModulePackage
    public var state: [String: String]
    public var configuration: [String: String]
    public var enabled: Bool
    /// Empty overrides means all monitors, including newly connected monitors.
    public var hiddenDisplayIDs: Set<String>
    public var compactActivity: Bool
    public var id: String { package.id }
    public init(package: ModulePackage) {
        self.package = package; state = package.initialState; configuration = package.defaultSettings
        enabled = true; hiddenDisplayIDs = []; compactActivity = false
    }
    public func isVisible(on displayID: String) -> Bool { enabled && !hiddenDisplayIDs.contains(displayID) }
}
