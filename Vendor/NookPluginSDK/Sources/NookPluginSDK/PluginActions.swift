import Foundation

/// Versioned, vendor-neutral action and event messages carried inside PluginMessage.
public enum PluginValue: Codable, Equatable, Sendable {
    case string(String), number(Double), boolean(Bool)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .boolean(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .boolean(let v): try c.encode(v) }
    }
    public var display: String { switch self { case .string(let v): return v; case .number(let v): return String(v); case .boolean(let v): return v ? "Yes" : "No" } }
}
public struct PluginParameter: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case string, number, boolean }
    public var name: String
    public var kind: Kind
    public var required: Bool
    public var minimum: Double?
    public var maximum: Double?
    public var structured: PluginStructuredSchema?
    public init(_ name: String, _ kind: Kind, required: Bool = true, minimum: Double? = nil, maximum: Double? = nil, structured: PluginStructuredSchema? = nil) {
        self.name = name; self.kind = kind; self.required = required; self.minimum = minimum; self.maximum = maximum; self.structured = structured
    }
}
public struct PluginValueSchema: Codable, Equatable, Sendable {
    public var fields: [PluginParameter]
    public init(_ fields: [PluginParameter] = []) { self.fields = fields }
    public func validate() throws {
        guard fields.count <= 16, Set(fields.map(\.name)).count == fields.count else { throw ModuleProblem("Invalid value schema.") }
        for f in fields {
            if let structured = f.structured { guard f.kind == .string else { throw ModuleProblem("Structured JSON requires an explicit text transport field.") }; try structured.validate() }
            guard ModulePackage.validKey(f.name), f.minimum?.isFinite ?? true, f.maximum?.isFinite ?? true,
                  f.kind == .number || (f.minimum == nil && f.maximum == nil),
                  f.minimum == nil || f.maximum == nil || f.minimum! <= f.maximum! else { throw ModuleProblem("Invalid parameter constraint.") }
        }
    }
    public func validate(_ values: [String: PluginValue]) throws {
        try validate()
        guard values.count <= 16, Set(values.keys).isSubset(of: Set(fields.map(\.name))) else { throw ModuleProblem("Unexpected action arguments.") }
        for f in fields {
            guard let value = values[f.name] else { if f.required { throw ModuleProblem("Missing argument: \(f.name)") }; continue }
            switch (f.kind, value) {
            case (.string, .string(let v)):
                guard v.utf8.count <= 2048 else { throw ModuleProblem("Text argument is too long.") }
                if let schema = f.structured { try schema.validate(PluginStructuredValue.parse(v)) }
            case (.number, .number(let v)): guard v.isFinite, f.minimum.map({ v >= $0 }) ?? true, f.maximum.map({ v <= $0 }) ?? true else { throw ModuleProblem("Number is outside its limits.") }
            case (.boolean, .boolean): break
            default: throw ModuleProblem("Argument type does not match its schema.")
            }
        }
    }
}
public struct PluginActionAddress: Codable, Equatable, Hashable, Sendable {
    public var plugin: String
    public var name: String
    public init(_ plugin: String, _ name: String) { self.plugin = plugin; self.name = name }
    public var key: String { plugin + "/" + name }
    public func validate() throws {
        guard plugin.count <= 100, plugin.range(of: #"^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$"#, options: .regularExpression) != nil, ModulePackage.validKey(name) else { throw ModuleProblem("Invalid action address.") }
    }
}
public struct PluginRegisteredAction: Codable, Equatable, Sendable, Identifiable {
    public enum Effect: String, Codable, Sendable { case readOnly, localChange, externalChange }
    public var id: String
    public var title: String
    public var input: PluginValueSchema
    public var output: PluginValueSchema
    public var effect: Effect
    public var cancellable: Bool
    public var timeoutSeconds: Double
    /// Optional actions-long-running-v1: absolute completion limit. Valid progress
    /// renews the ordinary inactivity timeout, never this limit or a Stop deadline.
    public var completionTimeoutSeconds: Double?
    /// Optional action-stream-v1, scoped to this reviewed live run. Never replayed.
    public var streamInput: PluginValueSchema?
    public var streamOutput: PluginValueSchema?
    /// Negotiated action-policy-v1; nil is unknown. Declaration only, never a grant or sandbox.
    public var executionPolicy: PluginActionExecutionPolicy?
    public init(_ id: String, title: String, input: PluginValueSchema = .init(), output: PluginValueSchema = .init(), effect: Effect = .readOnly, cancellable: Bool = false, timeoutSeconds: Double = 30, completionTimeoutSeconds: Double? = nil, streamInput: PluginValueSchema? = nil, streamOutput: PluginValueSchema? = nil, executionPolicy: PluginActionExecutionPolicy? = nil) {
        self.id = id; self.title = title; self.input = input; self.output = output; self.effect = effect; self.cancellable = cancellable; self.timeoutSeconds = timeoutSeconds; self.completionTimeoutSeconds = completionTimeoutSeconds; self.streamInput = streamInput; self.streamOutput = streamOutput; self.executionPolicy = executionPolicy
    }
    public func validate() throws {
        guard ModulePackage.validKey(id), !title.isEmpty, title.count <= 80, timeoutSeconds.isFinite, (1...300).contains(timeoutSeconds) else { throw ModuleProblem("Invalid registered action.") }
        if let limit = completionTimeoutSeconds { guard limit.isFinite, limit >= timeoutSeconds, limit <= 86400 else { throw ModuleProblem("Invalid completion limit.") } }
        if streamInput != nil || streamOutput != nil {
            guard streamInput != nil, streamOutput != nil, cancellable, completionTimeoutSeconds != nil else { throw ModuleProblem("Invalid streaming action.") }
            try streamInput?.validate(); try streamOutput?.validate()
        }
        try executionPolicy?.validate()
        try input.validate(); try output.validate()
    }
}
public struct PluginChannel: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case event, state }
    public var id: String
    public var title: String
    public var kind: Kind
    public var schema: PluginValueSchema
    public init(_ id: String, title: String, kind: Kind, schema: PluginValueSchema = .init()) { self.id = id; self.title = title; self.kind = kind; self.schema = schema }
    public func validate() throws {
        guard ModulePackage.validKey(id), !title.isEmpty, title.count <= 80 else { throw ModuleProblem("Invalid channel.") }; try schema.validate()
    }
}
public struct PluginRegistration: Codable, Equatable, Sendable {
    public var actions: [PluginRegisteredAction]
    public var channels: [PluginChannel]
    public init(actions: [PluginRegisteredAction] = [], channels: [PluginChannel] = []) { self.actions = actions; self.channels = channels }
    public func validate() throws {
        guard actions.count <= 32, channels.count <= 32, Set(actions.map(\.id)).count == actions.count, Set(channels.map(\.id)).count == channels.count else { throw ModuleProblem("Duplicate or excessive registration.") }
        for a in actions { try a.validate() }; for c in channels { try c.validate() }
    }
}
public struct PluginCatalogEntry: Codable, Equatable, Sendable {
    public var address: PluginActionAddress
    public var action: PluginRegisteredAction?
    public var channel: PluginChannel?
    public init(address: PluginActionAddress, action: PluginRegisteredAction? = nil, channel: PluginChannel? = nil) { self.address = address; self.action = action; self.channel = channel }
}
public enum PluginRunPhase: String, Codable, Sendable {
    case waitingReview, running, cancelling, succeeded, failed, cancelled, interrupted
    public var terminal: Bool { [.succeeded, .failed, .cancelled, .interrupted].contains(self) }
}
/// Optional run-display-v1. Display only: never grants approval or authority.
/// Step counts describe workflow progress, not a remote job's percentage.
public struct PluginRunDisplay: Codable, Equatable, Sendable {
    public var title: String
    public var step: String
    public var detail: String
    public var completedSteps: Int
    public var totalSteps: Int
    public var needsReview: Bool
    public init(title: String, step: String = "", detail: String = "", completedSteps: Int = 0, totalSteps: Int = 0, needsReview: Bool = false) {
        self.title = title; self.step = step; self.detail = detail; self.completedSteps = completedSteps; self.totalSteps = totalSteps; self.needsReview = needsReview
    }
    public func validate() throws {
        guard title.count <= 80, step.count <= 80, detail.count <= 300,
              (0...64).contains(totalSteps), (0...totalSteps).contains(completedSteps) else { throw ModuleProblem("Invalid run display.") }
    }
}
public struct PluginRunUpdate: Codable, Equatable, Sendable {
    public var phase: PluginRunPhase
    public var progress: Double?
    public var message: String
    public var values: [String: PluginValue]
    public var display: PluginRunDisplay?
    /// Optional ephemeral output meter. Carries no audio, voice identity or input data.
    public var speech: PluginSpeechPlayback?
    public init(_ phase: PluginRunPhase, progress: Double? = nil, message: String = "", values: [String: PluginValue] = [:], display: PluginRunDisplay? = nil, speech: PluginSpeechPlayback? = nil) { self.phase = phase; self.progress = progress; self.message = message; self.values = values; self.display = display; self.speech = speech }
    public func validate() throws {
        guard progress.map({ $0.isFinite && (0...1).contains($0) }) ?? true, message.count <= 300, values.count <= 16 else { throw ModuleProblem("Invalid execution update.") }
        try display?.validate()
        try speech?.validate()
        guard speech == nil || phase == .running else { throw ModuleProblem("Speech meters are transient running updates.") }
    }
}
public struct PluginBusMessage: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case register, discover, catalog, invoke, execute, cancel, update, subscribe, unsubscribe, publish, event, failure, stream, requestAccess, accessGranted }
    public var access: PluginActionAccessRequest?
    public var operation: Operation
    public var frame: PluginRunFrame?
    public var requestID: UUID
    public var address: PluginActionAddress?
    public var registration: PluginRegistration?
    public var catalog: [PluginCatalogEntry]?
    public var values: [String: PluginValue]?
    public var update: PluginRunUpdate?
    /// State lifetime in seconds. Events are never replayed.
    public var lifetime: Double?
    public var error: String?
    public var complete: Bool?
    public init(_ operation: Operation, requestID: UUID = UUID(), address: PluginActionAddress? = nil, registration: PluginRegistration? = nil, catalog: [PluginCatalogEntry]? = nil, values: [String: PluginValue]? = nil, update: PluginRunUpdate? = nil, lifetime: Double? = nil, error: String? = nil, complete: Bool? = nil, frame: PluginRunFrame? = nil, access: PluginActionAccessRequest? = nil) {
        self.access = access; self.frame = frame; self.operation = operation; self.requestID = requestID; self.address = address; self.registration = registration; self.catalog = catalog; self.values = values; self.update = update; self.lifetime = lifetime; self.error = error; self.complete = complete
    }
}

/// Collects an atomic, bounded catalog replacement across framed messages.
public struct PluginCatalogAccumulator: Sendable {
    public private(set) var entries: [PluginCatalogEntry] = []
    private var pending: [PluginCatalogEntry] = []
    private var generation: UUID?
    public init() {}
    @discardableResult public mutating func receive(_ message: PluginBusMessage) throws -> Bool {
        guard message.operation == .catalog else { return false }
        if generation != message.requestID { generation = message.requestID; pending = [] }
        for entry in message.catalog ?? [] {
            try entry.address.validate()
            guard (entry.action == nil) != (entry.channel == nil) else { throw ModuleProblem("Invalid catalog entry.") }
            try entry.action?.validate(); try entry.channel?.validate()
            guard entry.address.name == (entry.action?.id ?? entry.channel?.id) else { throw ModuleProblem("Catalog identity mismatch.") }
            guard !pending.contains(where: { $0.address == entry.address && ($0.channel != nil) == (entry.channel != nil) }) else { throw ModuleProblem("Duplicate catalog entry.") }
            pending.append(entry)
        }
        guard pending.count <= 1280 else { throw ModuleProblem("Catalog exceeds its limit.") }
        if message.complete == true { entries = pending; pending = []; generation = nil; return true }
        return false
    }
    public mutating func reset() { entries = []; pending = []; generation = nil }
}

/// Ordered, bounded, point-to-point action data. Contains no routing authority.
public struct PluginRunFrame: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var values: [String: PluginValue]
    public init(sequence: UInt64, values: [String: PluginValue]) { self.sequence = sequence; self.values = values }
    public func validate(_ schema: PluginValueSchema) throws {
        guard sequence < 200000, try JSONEncoder().encode(values).count <= 8192 else { throw ModuleProblem("Action frame exceeds its limit.") }
        try schema.validate(values)
    }
}
