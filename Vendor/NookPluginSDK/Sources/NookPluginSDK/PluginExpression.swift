import Foundation
import CryptoKit

/// Optional assistant delivery, never an interpretation of the user's feelings.
/// No prompts, assets, actions, audio or social/relationship permissions cross this contract.
public struct PluginExpressionCue: Codable, Equatable, Sendable {
    public enum Delivery: String, Codable, CaseIterable, Sendable { case natural, gentle, bright, reflective, playful }
    public enum Movement: String, Codable, Sendable { case none, tilt, lift, nod }
    public var version: Int = 1
    public var delivery: Delivery
    public var movement: Movement
    public var intensity: Double
    public var durationMs: Int
    public init(delivery: Delivery = .natural, movement: Movement = .none, intensity: Double = 0.35, durationMs: Int = 2200) {
        self.delivery = delivery; self.movement = movement; self.intensity = intensity; self.durationMs = durationMs
    }
    public func validate() throws {
        guard version == 1, intensity.isFinite, (0...0.75).contains(intensity), (120...3000).contains(durationMs) else { throw ModuleProblem("Invalid expression cue.") }
    }
    public static func named(_ value: String?) -> Self? {
        guard let value, let delivery = Delivery(rawValue: value) else { return nil }
        switch delivery {
        case .natural: return .init()
        case .gentle: return .init(delivery: delivery, movement: .tilt, intensity: 0.35)
        case .bright: return .init(delivery: delivery, movement: .lift, intensity: 0.6)
        case .reflective: return .init(delivery: delivery, movement: .nod, intensity: 0.3)
        case .playful: return .init(delivery: delivery, movement: .tilt, intensity: 0.4)
        }
    }
    /// Invalid optional metadata leaves independently validated speech intact.
    public static func decode(_ data: Data) -> Self? {
        guard PluginExpressionJSON.bounded(data, limit: 512), let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(fields.keys) == ["version", "delivery", "movement", "intensity", "durationMs"],
              let cue = try? JSONDecoder().decode(Self.self, from: data), (try? cue.validate()) != nil else { return nil }
        return cue
    }
    public var pose: PluginExpressionPose {
        guard (try? validate()) != nil else { return .init() }
        switch movement {
        case .none: return .init()
        case .tilt: return .init(pitch: 2 * intensity, roll: -7 * intensity, lift: 0)
        case .lift: return .init(pitch: -4 * intensity, roll: 2 * intensity, lift: 0.035 * intensity)
        case .nod: return .init(pitch: 5 * intensity, roll: 0, lift: 0)
        }
    }
}

/// A separate body layer: it never writes mouth, eyes, pointer gaze or voice identity.
public struct PluginExpressionPose: Codable, Equatable, Sendable {
    public var pitch: Double, roll: Double, lift: Double
    public init(pitch: Double = 0, roll: Double = 0, lift: Double = 0) {
        self.pitch = pitch.isFinite ? min(5, max(-5, pitch)) : 0
        self.roll = roll.isFinite ? min(6, max(-6, roll)) : 0
        self.lift = lift.isFinite ? min(0.03, max(-0.03, lift)) : 0
    }
    public func validate() throws {
        guard pitch.isFinite, roll.isFinite, lift.isFinite, abs(pitch) <= 5, abs(roll) <= 6, abs(lift) <= 0.03 else { throw ModuleProblem("Invalid expression posture.") }
    }
}

/// Metadata uses existing kind/text fields. Exact registered actions/grants stay unchanged.
public struct PluginExpressionCapability: Codable, Equatable, Sendable {
    public var version = 1
    public var timing = "segment-output-start"
    public var maxTextBytes = 1200
    public var maxEnvelopeBytes = 2048
    public init() {}
    public func encoded() -> String { String(decoding: try! JSONEncoder().encode(self), as: UTF8.self) }
    public static func decode(_ text: String) -> Self? {
        guard text.utf8.count <= 256, let fields = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              Set(fields.keys) == ["version", "timing", "maxTextBytes", "maxEnvelopeBytes"],
              let value = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)), value == Self() else { return nil }
        return value
    }
}

public struct PluginExpressionSegment: Codable, Equatable, Sendable {
    public let version: Int
    public let session: UUID
    public let segment: UUID
    public let sequence: Int
    public let turn: Int
    public let text: String
    public let digest: String
    public let cue: PluginExpressionCue?
    public init(session: UUID, sequence: Int, turn: Int, text: String, cue: PluginExpressionCue?) {
        version = 1; self.session = session; segment = UUID(); self.sequence = sequence; self.turn = turn; self.text = text
        digest = Self.digest(text); self.cue = cue.flatMap { (try? $0.validate()) != nil ? $0 : nil }
    }
    public static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    public func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 2048 else { throw ModuleProblem("Expression segment is too large.") }
        return String(decoding: data, as: UTF8.self)
    }
    public static func decode(_ text: String) throws -> Self {
        guard PluginExpressionJSON.bounded(Data(text.utf8), limit: 2048), let fields = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(fields.keys).isSubset(of: ["version", "session", "segment", "sequence", "turn", "text", "digest", "cue"]) else { throw ModuleProblem("Invalid expression segment.") }
        // Decode optional cue separately; unknown/malformed cues cannot erase valid words.
        var clean = fields; clean.removeValue(forKey: "cue")
        let base = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: clean))
        guard base.version == 1, (0..<200000).contains(base.sequence), (0...10000).contains(base.turn),
              !base.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, base.text.utf8.count <= 1200,
              base.digest == Self.digest(base.text) else { throw ModuleProblem("Invalid expression segment binding.") }
        let cue = fields["cue"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }.flatMap(PluginExpressionCue.decode)
        return Self(version: base.version, session: base.session, segment: base.segment, sequence: base.sequence, turn: base.turn, text: base.text, digest: base.digest, cue: cue)
    }
    private init(version: Int, session: UUID, segment: UUID, sequence: Int, turn: Int, text: String, digest: String, cue: PluginExpressionCue?) {
        self.version = version; self.session = session; self.segment = segment; self.sequence = sequence; self.turn = turn; self.text = text; self.digest = digest; self.cue = cue
    }
    public var receipt: PluginExpressionReceipt { .init(session: session, segment: segment, sequence: sequence, turn: turn) }
}

public struct PluginExpressionReceipt: Codable, Equatable, Sendable {
    public let session: UUID, segment: UUID
    public let sequence: Int, turn: Int
    public func encoded() -> String { String(decoding: try! JSONEncoder().encode(self), as: UTF8.self) }
    public static func decode(_ text: String) -> Self? {
        guard text.utf8.count <= 256 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }
}

/// Per-run replay/turn limits. The action-run UUID supplies the session identity.
public struct PluginExpressionAdmission: Sendable {
    private var lastSequence = -1, currentTurn = -1, count = 0, bytes = 0
    public init() {}
    public mutating func admit(_ segment: PluginExpressionSegment, session: UUID, turn: Int) throws {
        guard segment.version == 1, (0..<200000).contains(segment.sequence), (0...10000).contains(segment.turn),
              !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, segment.text.utf8.count <= 1200,
              segment.digest == PluginExpressionSegment.digest(segment.text),
              segment.session == session, segment.turn == turn, segment.sequence > lastSequence else { throw ModuleProblem("Stale expression segment.") }
        let nextCount = currentTurn == turn ? count + 1 : 1, nextBytes = currentTurn == turn ? bytes + segment.text.utf8.count : segment.text.utf8.count
        guard turn >= currentTurn, nextCount <= 32, nextBytes <= 32768 else { throw ModuleProblem("Expression turn exceeds its limit.") }
        currentTurn = turn; count = nextCount; bytes = nextBytes; lastSequence = segment.sequence
    }
}

/// One cancellable timer while a bounded cue is visible; no expression timer at idle.
@MainActor public final class PluginExpressionPlayback {
    public private(set) var pose = PluginExpressionPose()
    public var changed: (() -> Void)?
    private var pending: PluginExpressionSegment?
    private var timer: Task<Void, Never>?
    private var epoch = UUID()
    public init() {}
    public func stage(_ segment: PluginExpressionSegment?) { clear(); pending = segment }
    @discardableResult public func started(_ receipt: String) -> Bool {
        guard let pending, PluginExpressionReceipt.decode(receipt) == pending.receipt, let cue = pending.cue else { return false }
        self.pending = nil; pose = cue.pose; changed?()
        let token = epoch
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(cue.durationMs)) } catch { return }
            guard let self, self.epoch == token else { return }; self.clear()
        }
        return true
    }
    public func clear() { epoch = UUID(); timer?.cancel(); timer = nil; pending = nil; pose = .init(); changed?() }
}

/// A cheap preflight bounds nesting before Foundation allocates a JSON tree.
private enum PluginExpressionJSON {
    static func bounded(_ data: Data, limit: Int) -> Bool {
        guard data.count <= limit else { return false }
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 8 { return false } }
            else if byte == 125 || byte == 93 { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0 && !quoted
    }
}
