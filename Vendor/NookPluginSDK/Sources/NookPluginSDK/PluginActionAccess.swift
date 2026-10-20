import Foundation

/// Optional action-access-v1. Requests host review for one exact capability,
/// then continues that same invocation only after the user allows it.
public struct PluginActionAccessRequest: Codable, Equatable, Sendable {
    public var action: PluginRegisteredAction
    public var preferredProvider: String?
    public init(action: PluginRegisteredAction, preferredProvider: String? = nil) {
        self.action = action; self.preferredProvider = preferredProvider
    }
    public func validate() throws {
        try action.validate()
        if let preferredProvider { try PluginActionAddress(preferredProvider, action.id).validate() }
    }
}
