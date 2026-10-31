import Foundation
import CryptoKit

/// A bounded, literal-Unicode JSON domain for the pinned portable Flow contract.
/// Deliberately not Codable/JSONSerialization: those decoders cannot establish
/// duplicate-name rejection, and String-keyed dictionaries normalize identity.
public indirect enum PluginFlowJSON: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public let name: String
        public let value: PluginFlowJSON
        public init(_ name: String, _ value: PluginFlowJSON) { self.name = name; self.value = value }
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.value == rhs.value
        }
    }
    case null, boolean(Bool), integer(Int64), string(String)
    case array([PluginFlowJSON]), object([Member])

    public static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.boolean(a), .boolean(b)): return a == b
        case let (.integer(a), .integer(b)): return a == b
        case let (.string(a), .string(b)): return a.utf8.elementsEqual(b.utf8)
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)): return a == b
        default: return false
        }
    }

    public subscript(_ key: String) -> Self? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.name.utf8.elementsEqual(key.utf8) }?.value
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var integer: Int64? { if case .integer(let v) = self { return v }; return nil }
    public var array: [Self]? { if case .array(let v) = self { return v }; return nil }
    public var members: [Member]? { if case .object(let v) = self { return v }; return nil }
    public var scalarType: String? {
        switch self { case .null: return "null"; case .boolean: return "boolean"
        case .integer: return "integer"; case .string: return "string"; default: return nil }
    }
    public func removing(_ key: String) -> Self {
        guard case .object(let members) = self else { return self }
        return .object(members.filter { !$0.name.utf8.elementsEqual(key.utf8) })
    }
    public func setting(_ key: String, to value: Self) -> Self {
        guard case .object(let members) = removing(key) else { return self }
        return .object(members + [.init(key, value)])
    }

    public static let maximumBytes = 262_144
    public static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    public static func parse(_ data: Data) throws -> Self {
        try flowParse(data, budget: .portableAlpha)
    }
    public func canonicalData() throws -> Data {
        try flowCanonicalData(self, budget: .portableAlpha)
    }
    public func digest() throws -> String { "sha256:" + (try canonicalData()).flowSHA256 }
}


/// Strict JSON representation for the separately reviewed bridge outer frame.
/// Does not validate a bridge schema, authenticate a peer or grant authority.
/// Embedded alpha and SDK messages retain their own independent byte limits.
public enum PluginFlowBridgeJSON {
    public static let maximumBytes = 524_288

    public static func parse(_ data: Data) throws -> PluginFlowJSON {
        try flowParse(data, budget: .bridge)
    }
    public static func canonicalData(_ value: PluginFlowJSON) throws -> Data {
        try flowCanonicalData(value, budget: .bridge)
    }
    public static func digest(_ value: PluginFlowJSON) throws -> String {
        "sha256:" + (try canonicalData(value)).flowSHA256
    }
}

// Only these two fixed representation budgets are selectable, inside this file.
// Grammar, value domain and structural budgets are shared without alteration.
private enum FlowJSONByteBudget {
    case portableAlpha, bridge
    var maximumBytes: Int {
        switch self {
        case .portableAlpha: return PluginFlowJSON.maximumBytes
        case .bridge: return PluginFlowBridgeJSON.maximumBytes
        }
    }
}

private func flowParse(_ data: Data, budget: FlowJSONByteBudget) throws -> PluginFlowJSON {
    guard data.count <= budget.maximumBytes else { throw PluginFlowError("FLOW_LIMIT") }
    guard String(data: data, encoding: .utf8) != nil else { throw PluginFlowError("FLOW_UNICODE") }
    var parser = FlowJSONParser(bytes: Array(data))
    let value = try parser.value(depth: 0)
    parser.whitespace()
    guard parser.position == parser.bytes.count else { throw PluginFlowError("FLOW_JSON") }
    _ = try flowCanonicalData(value, budget: budget) // Also enforce canonical byte and value limits.
    return value
}

private func flowCanonicalData(_ value: PluginFlowJSON, budget: FlowJSONByteBudget) throws -> Data {
    var writer = FlowJSONWriter(budget: budget)
    try writer.value(value, depth: 0)
    return Data(writer.bytes)
}

public struct PluginFlowError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var description: String { code }
}

extension Data {
    var flowSHA256: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

private func flowForbidden(_ key: String) -> Bool {
    ["__proto__", "prototype", "constructor"].contains { $0.utf8.elementsEqual(key.utf8) }
}

private struct FlowJSONWriter {
    let budget: FlowJSONByteBudget
    var bytes = [UInt8]()
    var visits = 0
    mutating func append(_ b: [UInt8]) throws {
        guard bytes.count + b.count <= budget.maximumBytes else { throw PluginFlowError("FLOW_LIMIT") }
        bytes.append(contentsOf: b)
    }
    mutating func value(_ v: PluginFlowJSON, depth: Int) throws {
        visits += 1
        guard visits <= 12_000, depth <= 32 else { throw PluginFlowError("FLOW_LIMIT") }
        switch v {
        case .null: try append(Array("null".utf8))
        case .boolean(let b): try append(Array((b ? "true" : "false").utf8))
        case .integer(let n):
            guard n >= -PluginFlowJSON.maximumSafeInteger, n <= PluginFlowJSON.maximumSafeInteger else { throw PluginFlowError("FLOW_NUMBER") }
            try append(Array(String(n).utf8))
        case .string(let s):
            try append([34])
            for b in s.utf8 {
                switch b {
                case 34, 92: try append([92, b])
                case 8: try append([92, 98])
                case 9: try append([92, 116])
                case 10: try append([92, 110])
                case 12: try append([92, 102])
                case 13: try append([92, 114])
                case 0..<32: try append(Array(String(format: "\\u%04x", b).utf8))
                default: try append([b])
                }
            }
            try append([34])
        case .array(let values):
            guard values.count <= 1024 else { throw PluginFlowError("FLOW_JSON") }
            try append([91])
            for (index, child) in values.enumerated() { if index > 0 { try append([44]) }; try value(child, depth: depth + 1) }
            try append([93])
        case .object(let members):
            var names = Set<Data>()
            for m in members {
                guard !flowForbidden(m.name), names.insert(Data(m.name.utf8)).inserted else { throw PluginFlowError("FLOW_JSON") }
            }
            try append([123])
            for (index, m) in members.sorted(by: { $0.name.utf16.lexicographicallyPrecedes($1.name.utf16) }).enumerated() {
                if index > 0 { try append([44]) }
                try value(.string(m.name), depth: depth + 1); try append([58]); try value(m.value, depth: depth + 1)
            }
            try append([125])
        }
    }
}

private struct FlowJSONParser {
    let bytes: [UInt8]
    var position = 0
    var visits = 0
    mutating func whitespace() { while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
    mutating func take(_ byte: UInt8) -> Bool {
        if position < bytes.count, bytes[position] == byte { position += 1; return true }; return false
    }
    mutating func literal(_ text: String, _ value: PluginFlowJSON) throws -> PluginFlowJSON {
        let token = Array(text.utf8)
        guard bytes.count - position >= token.count, bytes[position..<(position + token.count)].elementsEqual(token) else { throw PluginFlowError("FLOW_JSON") }
        position += token.count; return value
    }
    mutating func value(depth: Int) throws -> PluginFlowJSON {
        visits += 1
        guard depth <= 32, visits <= 12_000 else { throw PluginFlowError("FLOW_LIMIT") }
        whitespace()
        guard position < bytes.count else { throw PluginFlowError("FLOW_JSON") }
        switch bytes[position] {
        case 110: return try literal("null", .null)
        case 116: return try literal("true", .boolean(true))
        case 102: return try literal("false", .boolean(false))
        case 34: return .string(try string())
        case 91:
            position += 1; whitespace(); var values = [PluginFlowJSON]()
            if take(93) { return .array(values) }
            while true {
                guard values.count < 1024 else { throw PluginFlowError("FLOW_JSON") }
                values.append(try value(depth: depth + 1)); whitespace()
                if take(93) { return .array(values) }
                guard take(44) else { throw PluginFlowError("FLOW_JSON") }
            }
        case 123:
            position += 1; whitespace(); var members = [PluginFlowJSON.Member](), names = Set<Data>()
            if take(125) { return .object(members) }
            while true {
                whitespace(); visits += 1
                guard visits <= 12_000, depth < 32 else { throw PluginFlowError("FLOW_LIMIT") }
                let name = try string()
                guard !flowForbidden(name), names.insert(Data(name.utf8)).inserted else { throw PluginFlowError("FLOW_JSON") }
                whitespace(); guard take(58) else { throw PluginFlowError("FLOW_JSON") }
                members.append(.init(name, try value(depth: depth + 1))); whitespace()
                if take(125) { return .object(members) }
                guard take(44) else { throw PluginFlowError("FLOW_JSON") }
            }
        case 45, 48...57: return try number()
        default: throw PluginFlowError("FLOW_JSON")
        }
    }
    mutating func hex() throws -> UInt32 {
        var n: UInt32 = 0
        for _ in 0..<4 {
            guard position < bytes.count else { throw PluginFlowError("FLOW_UNICODE") }
            let b = bytes[position]; position += 1
            let v: UInt32
            switch b { case 48...57: v = UInt32(b - 48); case 65...70: v = UInt32(b - 55); case 97...102: v = UInt32(b - 87); default: throw PluginFlowError("FLOW_UNICODE") }
            n = n * 16 + v
        }
        return n
    }
    mutating func string() throws -> String {
        guard take(34) else { throw PluginFlowError("FLOW_JSON") }
        var output = [UInt8]()
        while position < bytes.count {
            let b = bytes[position]; position += 1
            if b == 34 {
                guard let s = String(bytes: output, encoding: .utf8) else { throw PluginFlowError("FLOW_UNICODE") }; return s
            }
            guard b >= 32 else { throw PluginFlowError("FLOW_JSON") }
            if b != 92 { output.append(b); continue }
            guard position < bytes.count else { throw PluginFlowError("FLOW_JSON") }
            let escaped = bytes[position]; position += 1
            switch escaped {
            case 34, 47, 92: output.append(escaped)
            case 98: output.append(8)
            case 102: output.append(12)
            case 110: output.append(10)
            case 114: output.append(13)
            case 116: output.append(9)
            case 117:
                var n = try hex()
                if (0xD800...0xDBFF).contains(n) {
                    guard take(92), take(117) else { throw PluginFlowError("FLOW_UNICODE") }
                    let low = try hex()
                    guard (0xDC00...0xDFFF).contains(low) else { throw PluginFlowError("FLOW_UNICODE") }
                    n = 0x10000 + ((n - 0xD800) << 10) + low - 0xDC00
                }
                guard let scalar = UnicodeScalar(n) else { throw PluginFlowError("FLOW_UNICODE") }
                output.append(contentsOf: String(scalar).utf8)
            default: throw PluginFlowError("FLOW_JSON")
            }
        }
        throw PluginFlowError("FLOW_JSON")
    }
    mutating func number() throws -> PluginFlowJSON {
        let start = position
        _ = take(45)
        if !take(48) {
            guard position < bytes.count, (49...57).contains(bytes[position]) else { throw PluginFlowError("FLOW_JSON") }
            repeat { position += 1 } while position < bytes.count && (48...57).contains(bytes[position])
        }
        if take(46) { try digits() }
        if take(101) || take(69) { if !take(43) { _ = take(45) }; try digits() }
        // Match JSON.parse's IEEE-754 value domain, including 1.0 and 1e0.
        // Never convert through NSNumber (which conflates booleans and numbers).
        guard let n = Double(String(decoding: bytes[start..<position], as: UTF8.self)), n.isFinite,
              n.rounded(.towardZero) == n, abs(n) <= Double(PluginFlowJSON.maximumSafeInteger),
              !(n == 0 && n.sign == .minus) else { throw PluginFlowError("FLOW_NUMBER") }
        return .integer(Int64(n))
    }
    mutating func digits() throws {
        let start = position
        while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
        guard position > start else { throw PluginFlowError("FLOW_JSON") }
    }
}
