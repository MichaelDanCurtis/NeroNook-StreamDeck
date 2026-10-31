import Foundation

/// Optional structured-json-v1: typed records/lists carried in an explicitly
/// described string field. Legacy scalar types and their 2 KiB bound are unchanged.
public indirect enum PluginStructuredValue: Codable, Equatable, Sendable {
    case string(String), number(Double), boolean(Bool), null
    case object([String: PluginStructuredValue]), array([PluginStructuredValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .boolean(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .boolean(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
    public static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 2048 else { throw ModuleProblem("Structured data exceeds the scalar transport limit.") }
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        var budget = 512; try value.check(depth: 0, budget: &budget); return value
    }
    private func check(depth: Int, budget: inout Int) throws {
        budget -= 1
        guard depth <= 8, budget >= 0 else { throw ModuleProblem("Structured data is too deeply nested or too large.") }
        switch self {
        case .number(let v): guard v.isFinite else { throw ModuleProblem("Invalid structured number.") }
        case .object(let values):
            guard values.count <= 16, values.keys.allSatisfy(PluginDataPath.validKey) else { throw ModuleProblem("Invalid structured record keys.") }
            for v in values.values { try v.check(depth: depth + 1, budget: &budget) }
        case .array(let values):
            guard values.count <= 100 else { throw ModuleProblem("Too many structured items.") }
            for v in values { try v.check(depth: depth + 1, budget: &budget) }
        default: break
        }
    }
    public func json() throws -> String {
        var budget = 512; try check(depth: 0, budget: &budget)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= 2048 else { throw ModuleProblem("Structured data exceeds the scalar transport limit.") }
        return String(decoding: bytes, as: UTF8.self)
    }
    public func value(at path: String) throws -> Self {
        var value = self
        for part in try PluginDataPath.parse(path) {
            switch (value, part) {
            case (.object(let fields), .key(let key)):
                guard let next = fields[key] else { throw ModuleProblem("Mapped field is missing: \(path)") }; value = next
            case (.array(let values), .index(let index)):
                guard values.indices.contains(index) else { throw ModuleProblem("Mapped item is missing: \(path)") }; value = values[index]
            default: throw ModuleProblem("Mapped field does not match its record/list: \(path)")
            }
        }
        return value
    }
    public func scalar() throws -> PluginValue {
        switch self { case .string(let v): return .string(v); case .number(let v): return .number(v); case .boolean(let v): return .boolean(v)
        default: throw ModuleProblem("Choose a scalar field. Null, records and lists cannot be pasted into a scalar input.") }
    }
}

public enum PluginDataPath {
    public enum Part: Equatable, Sendable { case key(String), index(Int) }
    public static func validKey(_ key: String) -> Bool {
        ModulePackage.validKey(key) && !["__proto__", "prototype", "constructor"].contains(key)
    }
    public static func parse(_ path: String) throws -> [Part] {
        guard !path.isEmpty, path.utf8.count <= 256,
              path.range(of: #"^(?:[A-Za-z_][A-Za-z0-9_-]*|\[[0-9]{1,2}\])(?:\.[A-Za-z_][A-Za-z0-9_-]*|\[[0-9]{1,2}\])*$"#, options: .regularExpression) != nil else { throw ModuleProblem("Use a field path, not an expression.") }
        let regex = try NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_-]*|\[([0-9]{1,2})\]"#)
        let parts: [Part] = try regex.matches(in: path, range: NSRange(path.startIndex..., in: path)).map { match in
            if match.range(at: 1).location != NSNotFound, let range = Range(match.range(at: 1), in: path), let index = Int(path[range]) { return .index(index) }
            let key = String(path[Range(match.range, in: path)!])
            guard validKey(key) else { throw ModuleProblem("This field path is not allowed.") }; return .key(key)
        }
        guard parts.count <= 8 else { throw ModuleProblem("Field path is too deep.") }; return parts
    }
}

public indirect enum PluginStructuredSchema: Codable, Equatable, Sendable {
    case string, number, boolean, null
    case object([String: PluginStructuredSchema]), array(PluginStructuredSchema, maximum: Int)
    private enum Keys: String, CodingKey { case kind, fields, items, maximum }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "string": self = .string; case "number": self = .number; case "boolean": self = .boolean; case "null": self = .null
        case "object": self = .object(try c.decode([String: Self].self, forKey: .fields))
        case "array": self = .array(try c.decode(Self.self, forKey: .items), maximum: try c.decode(Int.self, forKey: .maximum))
        default: throw ModuleProblem("Unknown structured schema.")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .string: try c.encode("string", forKey: .kind)
        case .number: try c.encode("number", forKey: .kind)
        case .boolean: try c.encode("boolean", forKey: .kind)
        case .null: try c.encode("null", forKey: .kind)
        case .object(let fields): try c.encode("object", forKey: .kind); try c.encode(fields, forKey: .fields)
        case .array(let item, let maximum): try c.encode("array", forKey: .kind); try c.encode(item, forKey: .items); try c.encode(maximum, forKey: .maximum)
        }
    }
    public func validate(depth: Int = 0) throws {
        guard depth <= 8 else { throw ModuleProblem("Structured schema is too deep.") }
        switch self {
        case .object(let fields):
            guard fields.count <= 16, fields.keys.allSatisfy(PluginDataPath.validKey) else { throw ModuleProblem("Invalid structured schema fields.") }
            for schema in fields.values { try schema.validate(depth: depth + 1) }
        case .array(let item, let maximum): guard (1...100).contains(maximum) else { throw ModuleProblem("Invalid list bound.") }; try item.validate(depth: depth + 1)
        default: break
        }
    }
    public func validate(_ value: PluginStructuredValue) throws {
        try validate()
        switch (self, value) {
        case (.string, .string), (.number, .number), (.boolean, .boolean), (.null, .null): break
        case (.object(let fields), .object(let values)):
            guard Set(fields.keys) == Set(values.keys) else { throw ModuleProblem("Structured record has missing or unexpected fields.") }
            for (key, schema) in fields { try schema.validate(values[key]!) }
        case (.array(let item, let maximum), .array(let values)):
            guard values.count <= maximum else { throw ModuleProblem("Structured list exceeds its bound.") }
            for value in values { try item.validate(value) }
        default: throw ModuleProblem("Structured value has the wrong type.")
        }
    }
    public func scalarKind(at path: String) throws -> PluginParameter.Kind {
        var schema = self
        for part in try PluginDataPath.parse(path) {
            switch (schema, part) {
            case (.object(let fields), .key(let key)): guard let next = fields[key] else { throw ModuleProblem("Unknown mapped field.") }; schema = next
            case (.array(let item, let maximum), .index(let index)): guard index < maximum else { throw ModuleProblem("Mapped index exceeds the declared list bound.") }; schema = item
            default: throw ModuleProblem("Mapped path does not match its schema.")
            }
        }
        switch schema { case .string: return .string; case .number: return .number; case .boolean: return .boolean
        default: throw ModuleProblem("Choose a scalar leaf field.") }
    }
}
