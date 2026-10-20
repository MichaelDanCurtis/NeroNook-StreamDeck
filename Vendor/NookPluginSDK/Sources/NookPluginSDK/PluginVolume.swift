import Foundation

/// An optional, user-selected volume control. IDs identify physical targets and
/// must change when the target changes. Values are normalized, confirmed readings.
public struct PluginVolumeEndpoint: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var available: Bool
    public var volume: Double?
    public var muted: Bool?
    public var canSetVolume: Bool
    public var canMute: Bool
    /// Unix time of the device reading, not the snapshot publication.
    public var observedAt: Double
    public init(id: String, name: String, available: Bool, volume: Double?, muted: Bool?, canSetVolume: Bool, canMute: Bool, observedAt: Double) {
        self.id = id; self.name = name; self.available = available; self.volume = volume; self.muted = muted
        self.canSetVolume = canSetVolume; self.canMute = canMute; self.observedAt = observedAt
    }
    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 200, !name.isEmpty, name.count <= 80,
              observedAt.isFinite, observedAt >= 0,
              volume.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              !canSetVolume || volume != nil, !canMute || muted != nil else { throw ModuleProblem("Invalid volume endpoint.") }
    }
    public func isFresh(at now: Double) -> Bool { available && observedAt <= now + 5 && now - observedAt <= 45 }
}

/// Commands are immediate gestures; providers must never queue or retry them.
/// Relative volume and mute toggle resolve against a fresh device reading.
/// Volume changes preserve mute; muting is a separate explicit operation.
public enum PluginVolumeOperation: Codable, Equatable, Sendable {
    case setVolume(Double)
    case adjustVolume(Double)
    case setMuted(Bool)
    case toggleMute
    public var isMute: Bool { switch self { case .setMuted, .toggleMute: true; default: false } }
    public func validate() throws {
        switch self {
        case .setVolume(let n): guard n.isFinite, (0...1).contains(n) else { throw ModuleProblem("Invalid volume.") }
        case .adjustVolume(let n): guard n.isFinite, n != 0, (-0.25...0.25).contains(n) else { throw ModuleProblem("Invalid volume step.") }
        default: break
        }
    }
}
public struct PluginVolumeCommand: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var endpointID: String
    public var operation: PluginVolumeOperation
    /// Reject before starting a write after this Unix time. No deferred execution.
    public var expiresAt: Double
    public init(requestID: UUID = UUID(), endpointID: String, operation: PluginVolumeOperation, expiresAt: Double) {
        self.requestID = requestID; self.endpointID = endpointID; self.operation = operation; self.expiresAt = expiresAt
    }
    public func validate(now: Double = Date().timeIntervalSince1970) throws {
        try operation.validate()
        guard !endpointID.isEmpty, endpointID.utf8.count <= 200, expiresAt.isFinite,
              expiresAt > now, expiresAt <= now + 15 else { throw ModuleProblem("Volume gesture expired or has an invalid target.") }
    }
}
public struct PluginVolumeResult: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var endpointID: String
    public var state: PluginVolumeEndpoint?
    public var error: String?
    public init(requestID: UUID, endpointID: String, state: PluginVolumeEndpoint? = nil, error: String? = nil) {
        self.requestID = requestID; self.endpointID = endpointID; self.state = state; self.error = error
    }
    public func validate() throws {
        guard (state != nil) != (error != nil), (error?.count ?? 0) <= 350,
              state == nil || state?.id == endpointID else { throw ModuleProblem("Invalid volume result.") }
        try state?.validate()
    }
}
