import Foundation

// Only the two pinned SDK resources may retain a parsed value. This wrapper's
// unchecked Sendable conformance is limited to state guarded by its private lock;
// PluginFlowJSON and Data are returned/stored as immutable Sendable value types.
private final class PluginFlowVerifiedResourceParses: @unchecked Sendable {
    private struct Parsed {
        let bytes: Data
        let value: PluginFlowJSON
    }
    private let lock = NSLock()
    private var schema: Parsed?
    private var capabilities: Parsed?

    func parseVerified(_ data: Data, name: String, sha: String) throws -> PluginFlowJSON {
        lock.lock()
        defer { lock.unlock() }
        if name == "flow-contract-schema", sha == "0273157c6fa7d1282fcfb66cf2a0d48818398b564dc961dbdfaf56c97361beef" {
            if let cached = schema, cached.bytes == data { return cached.value }
            schema = nil
            let value = try PluginFlowJSON.parse(data)
            schema = Parsed(bytes: data, value: value)
            return value
        }
        if name == "flow-contract-capabilities", sha == "7615926c5da16aceffb74a2771b04a99b68a919c747b2738fcefa71190873acd" {
            if let cached = capabilities, cached.bytes == data { return cached.value }
            capabilities = nil
            let value = try PluginFlowJSON.parse(data)
            capabilities = Parsed(bytes: data, value: value)
            return value
        }
        // A future resource call does not grow this cache or acquire a slot.
        return try PluginFlowJSON.parse(data)
    }
}

/// Structural validation only. This codec never authorizes, admits or executes a
/// workflow. It imports the exact jointly reviewed alpha schema, not a schema fork.
public struct PluginFlowContract: Sendable {
    public static let packageName = "@fuego-nero/flow-contract"
    public static let packageVersion = "0.1.0-alpha.1"
    public static let commit = "98acb599d73617802493a4c94567bb21fa43f29c"
    public static let sourceManifestSHA256 = "ef6aaaf8d7cd563b9c780fd1c29d537da12e75b837247a6345236092c56b5dd7"
    public enum Shape: String, Sendable { case envelope, invocation, receipt, command, result, reply }
    public enum ReceiptChange: String, Sendable { case duplicate, advance }
    public struct DefinitionCheck: Sendable {
        public let profile: String
        public let nodeCount: Int
        public let publishedRevision: Bool
        public let grantsTransferred = false
        public let admission = "not-performed"
    }
    public let capabilities: PluginFlowJSON
    private let schema: PluginFlowJSON
    private static let verifiedResourceParses = PluginFlowVerifiedResourceParses()

    public init() throws {
        func resource(_ name: String, sha: String) throws -> PluginFlowJSON {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json") else { throw PluginFlowError("FLOW_PIN_RESOURCE") }
            let data = try Data(contentsOf: url)
            guard data.flowSHA256 == sha else { throw PluginFlowError("FLOW_PIN_RESOURCE") }
            return try Self.verifiedResourceParses.parseVerified(data, name: name, sha: sha)
        }
        schema = try resource("flow-contract-schema", sha: "0273157c6fa7d1282fcfb66cf2a0d48818398b564dc961dbdfaf56c97361beef")
        capabilities = try resource("flow-contract-capabilities", sha: "7615926c5da16aceffb74a2771b04a99b68a919c747b2738fcefa71190873acd")
    }

    public func validateShape(_ value: PluginFlowJSON, kind: Shape) throws {
        _ = try value.canonicalData()
        try check(value, rule: schema.need("$defs").need(kind.rawValue), depth: 0)
    }
    public func semanticProjection(_ definition: PluginFlowJSON) throws -> PluginFlowJSON {
        .object(try ["schemaVersion", "contractRevision", "profile", "interface", "graph", "dependencies", "bindingSlots", "policy"].map { .init($0, try definition.need($0)) })
    }
    public func sealDefinition(_ definition: PluginFlowJSON) throws -> PluginFlowJSON {
        let unsigned = definition.removing("digests")
        let digests = PluginFlowJSON.object([.init("content", .string(try unsigned.digest())), .init("semantic", .string(try semanticProjection(unsigned).digest()))])
        return unsigned.setting("digests", to: digests)
    }
    public func seal(_ value: PluginFlowJSON, kind: Shape) throws -> PluginFlowJSON {
        if kind == .envelope { return try sealDefinition(value) }
        let field = try digestField(kind)
        let unsigned = value.removing(field)
        return unsigned.setting(field, to: .string(try unsigned.digest()))
    }
    private func digestField(_ kind: Shape) throws -> String {
        switch kind { case .invocation: return "executionDigest"; case .command: return "commandDigest"
        case .result: return "resultDigest"; case .reply: return "replyDigest"
        default: throw PluginFlowError("FLOW_MESSAGE_DIGEST") }
    }
    private func validateDigest(_ value: PluginFlowJSON, kind: Shape) throws {
        let field = try digestField(kind)
        guard try value.need(field) == seal(value, kind: kind).need(field) else { throw PluginFlowError(kind == .invocation ? "FLOW_EXECUTION_DIGEST" : "FLOW_MESSAGE_DIGEST") }
    }

    private func check(_ value: PluginFlowJSON, rule: PluginFlowJSON, depth: Int) throws {
        guard depth <= 64 else { throw PluginFlowError("FLOW_SCHEMA_DEPTH") }
        let keywords = ["$ref", "oneOf", "const", "enum", "type", "properties", "required", "additionalProperties", "items", "minItems", "maxItems", "minLength", "maxLength", "pattern", "minimum", "maximum"]
        guard let fields = rule.members, fields.allSatisfy({ keywords.contains($0.name) }) else { throw PluginFlowError("FLOW_SCHEMA_KEYWORD") }
        if let reference = rule["$ref"]?.string {
            guard reference.hasPrefix("#/$defs/") else { throw PluginFlowError("FLOW_SCHEMA_REF") }
            try check(value, rule: schema.need("$defs").need(String(reference.dropFirst(8))), depth: depth + 1); return
        }
        if let branches = rule["oneOf"]?.array {
            var matches = 0
            for branch in branches { do { try check(value, rule: branch, depth: depth + 1); matches += 1 } catch {} }
            guard matches == 1 else { throw PluginFlowError("FLOW_SHAPE") }; return
        }
        if let constant = rule["const"], value != constant { throw PluginFlowError("FLOW_SHAPE") }
        if let choices = rule["enum"]?.array, !choices.contains(value) { throw PluginFlowError("FLOW_SHAPE") }
        guard let type = rule["type"]?.string else { return }
        switch (type, value) {
        case ("object", .object(let fields)):
            let properties = try rule.need("properties")
            for key in rule["required"]?.array ?? [] { guard let key = key.string, value[key] != nil else { throw PluginFlowError("FLOW_SHAPE") } }
            for field in fields {
                guard let child = properties[field.name] else { throw PluginFlowError("FLOW_SHAPE") }
                try check(field.value, rule: child, depth: depth + 1)
            }
        case ("array", .array(let items)):
            guard items.count >= Int(rule["minItems"]?.integer ?? 0), items.count <= Int(rule["maxItems"]?.integer ?? 0) else { throw PluginFlowError("FLOW_SHAPE") }
            for item in items { try check(item, rule: rule.need("items"), depth: depth + 1) }
        case ("string", .string(let text)):
            let length = Int64(text.unicodeScalars.count)
            guard length >= (rule["minLength"]?.integer ?? 0), length <= (rule["maxLength"]?.integer ?? Int64.max) else { throw PluginFlowError("FLOW_SHAPE") }
            if let pattern = rule["pattern"]?.string {
                // The pinned vocabulary uses JavaScript's ASCII \d, unlike ICU's.
                let regex = try NSRegularExpression(pattern: pattern.replacingOccurrences(of: "\\d", with: "[0-9]"))
                guard regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { throw PluginFlowError("FLOW_SHAPE") }
            }
            if rule["maxLength"]?.integer == 2048, text.utf8.count > 2048 { throw PluginFlowError("FLOW_TEXT_BYTES") }
        case ("integer", .integer(let n)):
            guard n >= (rule["minimum"]?.integer ?? Int64.min), n <= (rule["maximum"]?.integer ?? Int64.max) else { throw PluginFlowError("FLOW_SHAPE") }
        case ("boolean", .boolean), ("null", .null): break
        default: throw PluginFlowError("FLOW_SHAPE")
        }
    }

    @discardableResult public func validateDefinition(_ d: PluginFlowJSON) throws -> DefinitionCheck {
        try validateShape(d, kind: .envelope)
        guard try equal(d.need("digests"), sealDefinition(d).need("digests")) else { throw PluginFlowError("FLOW_DIGEST") }
        let graph = try d.need("graph"), nodes = try graph.list("nodes"), edges = try graph.list("edges")
        let dependencies = try d.list("dependencies"), slots = try d.list("bindingSlots")
        try unique(nodes, key: "id", code: "FLOW_NODE_DUPLICATE")
        try unique(dependencies, key: "id", code: "FLOW_DEPENDENCY_DUPLICATE")
        try unique(slots, key: "id", code: "FLOW_SLOT_DUPLICATE")
        var byID = [Data: PluginFlowJSON](), incoming = [Data: [PluginFlowJSON]](), outgoing = [Data: [PluginFlowJSON]]()
        var inputs = [Data: [Data: String]](), outputs = [Data: [Data: String]]()
        for node in nodes {
            let id = try node.key("id")
            byID[id] = node; incoming[id] = []; outgoing[id] = []
            inputs[id] = try ports(node.list("inputs")); outputs[id] = try ports(node.list("outputs"))
        }
        let roots = nodes.filter { $0["kind"]?.string == "input" }
        guard roots.count == 1 else { throw PluginFlowError("FLOW_ROOT") }
        let root = roots[0], rootID = try root.key("id")
        for edge in edges {
            let source = try edge.key("source"), target = try edge.key("target")
            guard byID[source] != nil, byID[target] != nil, source != target else { throw PluginFlowError("FLOW_EDGE") }
            incoming[target, default: []].append(edge); outgoing[source, default: []].append(edge)
        }
        for node in nodes {
            let id = try node.key("id"), kind = try node.text("kind"), children = outgoing[id] ?? []
            guard incoming[id]?.count == (id == rootID ? 0 : 1) else { throw PluginFlowError("FLOW_JOIN") }
            guard children.count == (kind == "result" ? 0 : kind == "condition" ? 2 : 1) else { throw PluginFlowError("FLOW_BRANCH") }
            let branches = try children.map { try $0.text("branch") }.sorted()
            guard kind == "condition" ? branches == ["no", "yes"] : branches.allSatisfy({ $0 == "next" }) else { throw PluginFlowError("FLOW_BRANCH") }
        }
        var visited = Set<Data>()
        func visit(_ id: Data) throws {
            guard visited.insert(id).inserted else { throw PluginFlowError("FLOW_CYCLE") }
            for edge in outgoing[id] ?? [] { try visit(edge.key("target")) }
        }
        try visit(rootID)
        guard visited.count == nodes.count else { throw PluginFlowError("FLOW_UNREACHABLE") }
        guard try d.need("policy").number("maxSteps") >= nodes.count else { throw PluginFlowError("FLOW_STEP_BUDGET") }
        let interface = try d.need("interface")
        _ = try ports(interface.list("inputs")); _ = try ports(interface.list("outputs"))
        guard try root.list("inputs").isEmpty, try root.list("arguments").isEmpty, try equal(root.need("outputs"), interface.need("inputs")) else { throw PluginFlowError("FLOW_INTERFACE") }
        for node in nodes {
            let id = try node.key("id"), kind = try node.text("kind"), arguments = try node.list("arguments")
            let input = inputs[id] ?? [:], output = outputs[id] ?? [:]
            try unique(arguments, key: "port", code: "FLOW_ARGUMENT_DUPLICATE")
            guard arguments.count == input.count else { throw PluginFlowError("FLOW_ARGUMENT") }
            var ancestors = Set<Data>(), current = id
            while let parent = incoming[current]?.first { current = try parent.key("source"); ancestors.insert(current) }
            for argument in arguments {
                let binding = try argument.need("binding"), port = try argument.key("port")
                let type: String?
                if let literal = binding["literal"] { type = literal.scalarType }
                else {
                    let source = try binding.key("node"), sourcePort = try binding.key("port")
                    guard ancestors.contains(source), let sourceType = outputs[source]?[sourcePort] else { throw PluginFlowError("FLOW_MAPPING_SOURCE") }
                    type = sourceType
                }
                guard let expected = input[port], type == expected else { throw PluginFlowError("FLOW_MAPPING_TYPE") }
            }
            if kind == "capability" {
                guard let dep = node["dependency"], dependencies.contains(where: { $0["id"] == dep }),
                      let slot = node["bindingSlot"], slots.contains(where: { $0["id"] == slot && $0["kind"]?.string == "device" }), node["effect"] != nil else { throw PluginFlowError("FLOW_CAPABILITY") }
            } else if ["dependency", "bindingSlot", "effect"].contains(where: { node[$0] != nil }) { throw PluginFlowError("FLOW_NODE_CONFIG") }
            let conditionPorts = PluginFlowJSON.array([.object([.init("name", .string("test")), .init("type", .string("boolean"))])])
            if kind == "condition", try !equal(node.need("inputs"), conditionPorts) || !output.isEmpty { throw PluginFlowError("FLOW_CONDITION") }
            if ["map", "review", "result"].contains(kind), try !equal(node.need("inputs"), node.need("outputs")) { throw PluginFlowError("FLOW_PASSTHROUGH") }
            if kind == "result", try !equal(node.need("outputs"), interface.need("outputs")) { throw PluginFlowError("FLOW_INTERFACE") }
        }
        let presentation = try d.need("presentation").list("nodes")
        try unique(presentation, key: "id", code: "FLOW_PRESENTATION")
        guard presentation.count == nodes.count, try presentation.allSatisfy({ byID[try $0.key("id")] != nil }) else { throw PluginFlowError("FLOW_PRESENTATION") }
        return DefinitionCheck(profile: try d.text("profile"), nodeCount: nodes.count, publishedRevision: try d.need("metadata").text("lifecycle") == "published")
    }

    public func validateInvocation(_ v: PluginFlowJSON, definition: PluginFlowJSON) throws {
        try validateDefinition(definition); try validateShape(v, kind: .invocation); try validateDigest(v, kind: .invocation)
        for key in ["definitionId", "revisionId"] { guard v[key] == definition[key] else { throw PluginFlowError("FLOW_REVISION") } }
        guard try v.need("semanticDigest") == definition.need("digests").need("semantic") else { throw PluginFlowError("FLOW_REVISION") }
        let metadata = try definition.need("metadata"), owner = try metadata.need("owner"), scope = try v.need("scope")
        guard try metadata.text("lifecycle") == "published" else { throw PluginFlowError("FLOW_NOT_PUBLISHED") }
        guard scope["kind"] == owner["scope"], scope["id"] == owner["id"] else { throw PluginFlowError("FLOW_SCOPE") }
        let values = try v.list("inputs"), required = try ports(definition.need("interface").list("inputs"))
        try unique(values, key: "port", code: "FLOW_INPUT_DUPLICATE")
        guard values.count == required.count else { throw PluginFlowError("FLOW_INPUT_TYPE") }
        for value in values { guard let expected = required[try value.key("port")], value["value"]?.scalarType == expected else { throw PluginFlowError("FLOW_INPUT_TYPE") } }
        try timestamp(v.text("deadline"))
    }
    public func validateCommand(_ v: PluginFlowJSON) throws {
        try validateShape(v, kind: .command); try validateDigest(v, kind: .command); try timestamp(v.text("deadline"))
    }
    public func validateResult(_ v: PluginFlowJSON, invocation: PluginFlowJSON, definition: PluginFlowJSON) throws {
        try validateInvocation(invocation, definition: definition); try validateShape(v, kind: .result); try validateDigest(v, kind: .result)
        try join(v, invocation, keys: ["scope", "callerId", "invocationId", "executionDigest", "definitionId", "revisionId", "semanticDigest", "target", "mode"], code: "FLOW_RESULT_JOIN")
        let outcome = try v.text("outcome")
        let reasons = ["completed": "none", "failed": "execution-failed", "interrupted": "interrupted", "uncertain": "effect-unknown", "cancelled": "stop-confirmed"]
        guard try v.text("reason") == reasons[outcome] else { throw PluginFlowError("FLOW_RESULT_REASON") }
        let values = try v.list("outputs"), expected = try ports(definition.need("interface").list("outputs"))
        try unique(values, key: "port", code: "FLOW_RESULT_OUTPUT")
        if outcome != "completed" { guard values.isEmpty else { throw PluginFlowError("FLOW_RESULT_OUTPUT") }; return }
        guard values.count == expected.count else { throw PluginFlowError("FLOW_RESULT_OUTPUT") }
        for value in values { guard let type = expected[try value.key("port")], value["value"]?.scalarType == type else { throw PluginFlowError("FLOW_RESULT_OUTPUT") } }
    }
    public func validateReply(_ v: PluginFlowJSON, command: PluginFlowJSON, invocation: PluginFlowJSON, definition: PluginFlowJSON) throws {
        try validateCommand(command); try validateShape(invocation, kind: .invocation); try validateDigest(invocation, kind: .invocation)
        try join(command, invocation, keys: ["scope", "callerId", "invocationId", "idempotencyKey", "executionDigest", "target", "mode"], code: "FLOW_REPLY_INVOCATION")
        try validateShape(v, kind: .reply); try validateDigest(v, kind: .reply)
        try join(v, command, keys: ["commandId", "commandDigest", "operation", "scope", "callerId", "invocationId", "executionDigest", "target", "mode"], code: "FLOW_REPLY_JOIN")
        if try v.text("observation") == "not-found" {
            guard try v.text("operation") != "cancel", v["receipt"] == nil, v["result"] == nil else { throw PluginFlowError("FLOW_REPLY_STATE") }; return
        }
        guard let receipt = v["receipt"] else { throw PluginFlowError("FLOW_REPLY_STATE") }
        try join(receipt, v, keys: ["invocationId", "executionDigest"], code: "FLOW_REPLY_JOIN")
        _ = try compareReceipts(receipt, receipt)
        if let result = v["result"] {
            try validateResult(result, invocation: invocation, definition: definition)
            try join(result, receipt, keys: ["sequence", "outcome", "reason"], code: "FLOW_REPLY_STATE")
        } else if ["completed", "failed", "interrupted", "uncertain"].contains(try receipt.text("outcome")) { throw PluginFlowError("FLOW_REPLY_STATE") }
    }
    public func compareReceipts(_ previous: PluginFlowJSON, _ next: PluginFlowJSON) throws -> ReceiptChange {
        try validateShape(previous, kind: .receipt); try validateShape(next, kind: .receipt)
        for receipt in [previous, next] { if receipt["outcome"]?.string == "cancelled", receipt["reason"]?.string != "stop-confirmed" { throw PluginFlowError("FLOW_STOP_UNCONFIRMED") } }
        try join(previous, next, keys: ["invocationId", "executionDigest"], code: "FLOW_RECEIPT_IDENTITY")
        let oldSequence = try previous.number("sequence"), newSequence = try next.number("sequence")
        if newSequence == oldSequence, try equal(previous, next) { return .duplicate }
        guard newSequence > oldSequence else { throw PluginFlowError("FLOW_RECEIPT_SEQUENCE") }
        let allowed = ["accepted": ["started", "failed", "interrupted", "uncertain", "cancel-pending", "cancelled"], "started": ["completed", "failed", "interrupted", "uncertain", "cancel-pending"], "cancel-pending": ["cancelled", "uncertain", "completed", "failed", "interrupted"], "uncertain": ["completed", "failed", "cancelled", "interrupted"], "interrupted": ["completed", "failed", "cancelled", "uncertain"]]
        guard try allowed[previous.text("outcome")]?.contains(next.text("outcome")) == true else { throw PluginFlowError("FLOW_RECEIPT_TRANSITION") }
        return .advance
    }

    private func equal(_ a: PluginFlowJSON, _ b: PluginFlowJSON) throws -> Bool { try a.canonicalData() == b.canonicalData() }
    private func join(_ a: PluginFlowJSON, _ b: PluginFlowJSON, keys: [String], code: String) throws {
        for key in keys { guard try equal(a.need(key), b.need(key)) else { throw PluginFlowError(code) } }
    }
    private func unique(_ rows: [PluginFlowJSON], key: String, code: String) throws {
        var keys = Set<Data>()
        for row in rows { guard keys.insert(try row.key(key)).inserted else { throw PluginFlowError(code) } }
    }
    private func ports(_ rows: [PluginFlowJSON]) throws -> [Data: String] {
        try unique(rows, key: "name", code: "FLOW_PORT_DUPLICATE")
        return try Dictionary(uniqueKeysWithValues: rows.map { (try $0.key("name"), try $0.text("type")) })
    }
    private func timestamp(_ text: String) throws {
        // ECMAScript uses proleptic Gregorian years, including 0000. A locale
        // formatter can introduce an era/calendar cutover and is unnecessary here.
        let bytes = Array(text.utf8), separators: [Int: UInt8] = [4:45, 7:45, 10:84, 13:58, 16:58, 19:46, 23:90]
        guard bytes.count == 24 else { throw PluginFlowError("FLOW_DEADLINE") }
        for i in bytes.indices {
            guard separators[i].map({ bytes[i] == $0 }) ?? (48...57).contains(bytes[i]) else { throw PluginFlowError("FLOW_DEADLINE") }
        }
        func number(_ start: Int, _ count: Int) -> Int { bytes[start..<(start + count)].reduce(0) { $0 * 10 + Int($1 - 48) } }
        let year = number(0, 4), month = number(5, 2), day = number(8, 2)
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), day >= 1, day <= days[month - 1], number(11, 2) <= 23,
              number(14, 2) <= 59, number(17, 2) <= 59 else { throw PluginFlowError("FLOW_DEADLINE") }
    }
}

private extension PluginFlowJSON {
    func need(_ key: String) throws -> Self { guard let v = self[key] else { throw PluginFlowError("FLOW_SHAPE") }; return v }
    func text(_ key: String) throws -> String { guard let v = try need(key).string else { throw PluginFlowError("FLOW_SHAPE") }; return v }
    func number(_ key: String) throws -> Int64 { guard let v = try need(key).integer else { throw PluginFlowError("FLOW_SHAPE") }; return v }
    func list(_ key: String) throws -> [Self] { guard let v = try need(key).array else { throw PluginFlowError("FLOW_SHAPE") }; return v }
    func key(_ key: String) throws -> Data { Data(try text(key).utf8) }
}
