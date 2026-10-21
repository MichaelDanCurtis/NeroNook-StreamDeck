import Foundation
import Combine

/// Optional controls-v1 metadata carried inside the existing bounded text
/// stream. Older clients ignore it; only advertised providers receive changes.
public struct PluginSpeechConversationControls: Codable, Equatable, Sendable {
    public var version = 1
    public let microphone: String
    public let recognition: String
    public let sensitivity: Int
    public init(microphone: String, recognition: String, sensitivity: Int) {
        self.microphone = microphone; self.recognition = recognition; self.sensitivity = sensitivity
    }
    public func validate() throws {
        guard version == 1, (0...100).contains(sensitivity),
              [microphone, recognition].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
            throw ModuleProblem("Invalid voice controls.")
        }
    }
    public func encoded() throws -> String {
        try validate(); return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
    public static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 1024 else { throw ModuleProblem("Voice controls exceed their limit.") }
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8)); try value.validate(); return value
    }
}

/// Optional text/control convention over generic action-stream-v1. Audio never
/// crosses this transport. Opening requires an explicit caller control and a host-approved connection.
public enum PluginSpeechConversation {
    public static let input = PluginValueSchema([.init("kind", .string), .init("text", .string, required: false), .init("mode", .string, required: false), .init("turn", .number, required: false, minimum: 0, maximum: 10000)])
    public static let output = PluginValueSchema([.init("kind", .string), .init("text", .string, required: false), .init("mode", .string, required: false), .init("turn", .number, required: false, minimum: 0, maximum: 10000), .init("level", .number, required: false, minimum: 0, maximum: 1)])
    public static let action = PluginRegisteredAction("speech_conversation", title: "Start local voice conversation",
        input: .init([.init("mode", .string), .init("settings", .boolean, required: false)]), effect: .readOnly, cancellable: true,
        timeoutSeconds: 30, completionTimeoutSeconds: 7200, streamInput: input, streamOutput: output)
    public static func accepts(_ entry: PluginCatalogEntry) -> Bool { entry.action == action }
    public static func mode(_ value: String) throws -> String {
        guard ["half", "full"].contains(value) else { throw ModuleProblem("Choose full or half duplex.") }; return value
    }
    public static func values(_ kind: String, text: String? = nil, mode: String? = nil, turn: Int? = nil) -> [String: PluginValue] {
        var v: [String: PluginValue] = ["kind": .string(kind)]
        if let text { v["text"] = .string(text) }; if let mode { v["mode"] = .string(mode) }; if let turn { v["turn"] = .number(Double(turn)) }; return v
    }
}

/// One explicit, reviewed session. Revocation/reconnect always stops it; never
/// opens a microphone on discovery, launch, provider selection or a mode change.
@MainActor public final class PluginSpeechConversationClient: ObservableObject {
    public var send: ((PluginBusMessage) -> Void)?
    public var event: (([String: PluginValue]) -> Void)?
    public var ended: (() -> Void)?
    @Published public private(set) var providers: [PluginCatalogEntry] = []
    @Published public private(set) var selectedKey = ""
    public var accessRequestsAvailable = false
    @Published public private(set) var status = "Press Talk to connect a voice provider."
    @Published public private(set) var active = false
    @Published public private(set) var ready = false
    @Published public private(set) var controls: PluginSpeechConversationControls?
    @Published public private(set) var expressionCapability: PluginExpressionCapability?
    private var expressionSequence = 0
    private var request: UUID?
    private var entry: PluginCatalogEntry?
    private var awaitingAccess = false
    public var awaitingPermission: Bool { awaitingAccess }
    private var inputSequence: UInt64 = 0, outputSequence: UInt64 = 0
    public init() {}
    public func select(_ key: String) { if selectedKey != key { stop() }; selectedKey = key }
    public func catalog(_ entries: [PluginCatalogEntry]) {
        let wasActive = active
        if active && !awaitingAccess { stop(); status = "Speech connection changed. Press Talk again." }
        providers = entries.filter(PluginSpeechConversation.accepts)
        if !providers.contains(where: { $0.address.key == selectedKey }) { selectedKey = providers.count == 1 ? providers[0].address.key : "" }
        if !wasActive { status = selectedKey.isEmpty ? (accessRequestsAvailable ? "Press Talk to connect a voice provider." : "Allow a shared conversation provider in Modules → Shared Actions.") : "Press Talk to start" }
    }
    public func start(mode: String) throws {
        guard !active, send != nil else { throw ModuleProblem("A voice connection is already starting or unavailable.") }
        let mode = try PluginSpeechConversation.mode(mode), id = UUID()
        let chosen = providers.first(where: { $0.address.key == selectedKey })
        guard chosen != nil || accessRequestsAvailable else { throw ModuleProblem("Allow and choose a shared conversation provider first.") }
        if chosen == nil {
            awaitingAccess = true; entry = nil; request = id; active = true; ready = false; inputSequence = 0; outputSequence = 0
            status = "Waiting for voice permission…"
            send?(.init(.requestAccess, requestID: id, values: ["mode": .string(mode)], access: .init(action: PluginSpeechConversation.action)))
            return
        }
        let entry = chosen!
        self.entry = entry; request = id; active = true; ready = false; inputSequence = 0; outputSequence = 0
        status = "Starting local voice conversation…"
        send?(.init(.invoke, requestID: id, address: entry.address, values: ["mode": .string(mode)]))
    }
    /// Opens the provider's own settings; no audio capture is requested.
    public func openSettings(mode: String) throws {
        guard send != nil else { throw ModuleProblem("Voice connection is unavailable.") }
        let mode = try PluginSpeechConversation.mode(mode)
        stop()
        if let entry = providers.first(where: { $0.address.key == selectedKey }) {
            send?(.init(.invoke, requestID: UUID(), address: entry.address, values: ["mode": .string(mode), "settings": .boolean(true)]))
        } else {
            guard accessRequestsAvailable else { throw ModuleProblem("Choose a speech provider first.") }
            awaitingAccess = true; entry = nil; request = UUID(); active = true; ready = false; inputSequence = 0; outputSequence = 0
            status = "Waiting for voice permission…"
            send?(.init(.requestAccess, requestID: request!, values: ["mode": .string(mode), "settings": .boolean(true)], access: .init(action: PluginSpeechConversation.action)))
        }
    }
    public func input(_ values: [String: PluginValue]) throws {
        guard active, ready, let request, let entry else { throw ModuleProblem("Voice conversation is not ready.") }
        let frame = PluginRunFrame(sequence: inputSequence, values: values); try frame.validate(PluginSpeechConversation.input)
        inputSequence += 1; send?(.init(.stream, requestID: request, address: entry.address, frame: frame))
    }
    /// Use only after this exact run advertises support. Oversized segments retain
    /// their unchanged plain speech path rather than losing text to metadata.
    public func speak(_ text: String, cue: PluginExpressionCue? = nil, turn: Int) throws -> PluginExpressionSegment? {
        guard cue != nil, expressionCapability != nil, let request, text.utf8.count <= 1200 else {
            try input(PluginSpeechConversation.values("speak", text: text, turn: turn)); return nil
        }
        let segment = PluginExpressionSegment(session: request, sequence: expressionSequence, turn: turn, text: text, cue: cue)
        guard let encoded = try? segment.encoded() else {
            try input(PluginSpeechConversation.values("speak", text: text, turn: turn)); return nil
        }
        try input(PluginSpeechConversation.values("speakExpression", text: encoded, turn: turn)); expressionSequence += 1
        return segment
    }
    public func setInterruptionSensitivity(_ value: Int) throws {
        guard controls != nil, (0...100).contains(value) else { throw ModuleProblem("Open Voice settings or wait for a compatible Talk session.") }
        try input(PluginSpeechConversation.values("sensitivity", text: String(value)))
    }
    public func receive(_ message: PluginBusMessage) {
        guard active, message.requestID == request else { return }
        if message.operation == .accessGranted {
            guard awaitingAccess, let candidate = message.catalog?.first, message.catalog?.count == 1,
                  candidate.channel == nil, candidate.action == PluginSpeechConversation.action,
                  candidate.address.name == PluginSpeechConversation.action.id, (try? candidate.address.validate()) != nil else {
                stop(); status = "The voice permission response was invalid. Press Talk to try again."; return
            }
            awaitingAccess = false; entry = candidate; selectedKey = candidate.address.key
            if !providers.contains(candidate) { providers.append(candidate) }
            status = "Starting local voice conversation…"
        } else if message.operation == .stream, let frame = message.frame {
            do {
                guard !awaitingAccess, entry != nil else { throw ModuleProblem("Voice permission has not been granted.") }
                guard frame.sequence == outputSequence else { throw ModuleProblem("Voice stream was interrupted.") }
                try frame.validate(PluginSpeechConversation.output); outputSequence += 1
                if case .string("expressionCapabilities") = frame.values["kind"], case .string(let text) = frame.values["text"] {
                    expressionCapability = PluginExpressionCapability.decode(text)
                }
                if case .string("controls") = frame.values["kind"], case .string(let text) = frame.values["text"] {
                    controls = try PluginSpeechConversationControls.decode(text)
                }
                if case .string("ready") = frame.values["kind"] { ready = true; status = "Listening" }
                event?(frame.values)
            } catch { stop(); status = error.localizedDescription }
        } else if message.operation == .failure || message.update?.phase.terminal == true {
            let text = message.error ?? message.update?.message ?? "Voice conversation ended"
            if message.operation == .failure { stop() } else { retire() }; status = text
        } else if let update = message.update { status = update.message.isEmpty ? "Starting conversation…" : update.message }
    }
    public func stop() {
        let old = request; retire(); status = "Conversation stopped"
        if let old { send?(.init(.cancel, requestID: old)) }
    }
    private func retire() { let wasActive = active; active = false; ready = false; controls = nil; expressionCapability = nil; expressionSequence = 0; awaitingAccess = false; request = nil; entry = nil; if wasActive { ended?() } }
}
