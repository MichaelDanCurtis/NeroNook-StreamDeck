import Foundation

/// presentation-v1 lets a plugin reveal only its own installed workspace surface.
/// Emit a sequenced PluginMessage(type: "present", ...) only after negotiation and
/// an explicit user gesture (for example, a hardware menu key). No data/action grant.
public struct PluginPresentationGate {
    private var latest: [String: Date] = [:]
    public init() {}
    public mutating func accept(_ plugin: String, now: Date) -> Bool {
        guard now.timeIntervalSince(latest[plugin] ?? .distantPast) >= 1 else { return false }
        latest[plugin] = now
        if latest.count > 64 { latest = latest.filter { now.timeIntervalSince($0.value) < 60 } }
        return true
    }
}
