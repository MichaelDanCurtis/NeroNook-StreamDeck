import Foundation

/// Selected-voice playback presentation only. No audio or private voice profile
/// crosses the plugin boundary; the speech provider owns synthesis and output.
public struct PluginSpeechPlayback: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case preparing, speaking }
    public var phase: Phase
    public var level: Double
    public init(_ phase: Phase, level: Double = 0) { self.phase=phase; self.level=level }
    public func validate() throws {
        guard level.isFinite, (0...1).contains(level), phase != .preparing || level == 0 else { throw ModuleProblem("Invalid speech playback meter.") }
    }
}
public struct PluginAvatarPlayback: Codable, Equatable, Sendable {
    public static let event = "sdk_avatar_reaction"
    public var id: UUID
    public var kind: PluginAvatarReaction
    public var speech: PluginSpeechPlayback
    public init(id: UUID, kind: PluginAvatarReaction, speech: PluginSpeechPlayback = .init(.preparing)) { self.id=id; self.kind=kind; self.speech=speech }
    public func validate() throws { guard kind.hasAudio else { throw ModuleProblem("Silent gestures do not request speech.") }; try speech.validate() }
    public static func validate(_ values: [String:PluginValue]) throws {
        guard Set(values.keys)==Set(["id","kind"]), case .string(let id)=values["id"], UUID(uuidString:id) != nil,
              case .string(let kind)=values["kind"], ["giggle","zoom","stop"].contains(kind) else { throw ModuleProblem("Invalid avatar gesture.") }
    }
}
