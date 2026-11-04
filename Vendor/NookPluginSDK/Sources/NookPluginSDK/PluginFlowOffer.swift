import Foundation

/// Optional flow-remote-offer-v1 transport. An offer is not a grant or permission
/// to start a provider. The host must separately authenticate and gate its use.
public struct PluginFlowOffer: Codable, Sendable, Equatable {
    public static let feature = "flow-remote-offer-v1"
    public var version: Int = 1
    public var requestID: UUID
    public var address: PluginActionAddress
    public var values: [String: PluginValue]
    /// Canonical UInt64 decimal in the server authorization clock domain.
    /// Representation validation does not establish freshness or trusted time.
    public var consumeBeforeMs: String
    public init(requestID: UUID, address: PluginActionAddress, values: [String: PluginValue] = [:], consumeBeforeMs: String) {
        self.requestID = requestID; self.address = address; self.values = values; self.consumeBeforeMs = consumeBeforeMs
    }
    public func validate() throws {
        guard version == 1, let deadline = UInt64(consumeBeforeMs), String(deadline) == consumeBeforeMs,
              values.count <= 16 else { throw ModuleProblem("Invalid flow offer.") }
        try address.validate()
        for (name, value) in values {
            guard ModulePackage.validKey(name), !["__proto__", "constructor", "prototype"].contains(name) else { throw ModuleProblem("Invalid flow offer argument name.") }
            switch value {
            case .string(let text): guard text.utf8.count <= 2048 else { throw ModuleProblem("Flow offer text exceeds its limit.") }
            case .boolean: break
            case .number(let number):
                guard number.isFinite, number.rounded(.towardZero) == number,
                      abs(number) <= Double(PluginFlowJSON.maximumSafeInteger),
                      !(number == 0 && number.sign == .minus) else { throw ModuleProblem("Invalid flow offer number.") }
            }
        }
    }
}

/// New transport only. Legacy PluginMessage Codable behavior is unchanged.
/// Use PluginMessage.encoded()/PluginLines for validated flowOffer wire messages;
/// a direct generic JSONEncoder/JSONDecoder call is not that transport boundary.
enum PluginFlowOfferCodec {
    private struct WireOffer: Encodable {
        var version: Int
        var requestID: String
        var address: PluginActionAddress
        var values: [String: PluginValue]
        var consumeBeforeMs: String
    }
    private struct WireMessage: Encodable {
        var apiVersion: Int
        var type: String
        var pluginID: String
        var session: String
        var sequence: UInt64
        var flowOffer: WireOffer
    }
    private struct Marker: Decodable {
        var hasOffer: Bool
        private enum CodingKeys: String, CodingKey { case flowOffer }
        init(from decoder: Decoder) throws { hasOffer = try decoder.container(keyedBy: CodingKeys.self).contains(.flowOffer) }
    }
    static func encode(_ message: PluginMessage) throws -> Data {
        try validate(message)
        guard let offer = message.flowOffer else { throw ModuleProblem("Missing flow offer.") }
        let wire = WireMessage(apiVersion: message.apiVersion, type: message.type, pluginID: message.pluginID,
                               session: message.session.uuidString.lowercased(), sequence: message.sequence,
                               flowOffer: .init(version: offer.version, requestID: offer.requestID.uuidString.lowercased(),
                                                address: offer.address, values: offer.values, consumeBeforeMs: offer.consumeBeforeMs))
        return try JSONEncoder().encode(wire)
    }
    static func validateLineIfPresent(_ data: Data, message: PluginMessage) throws {
        let marker = try JSONDecoder().decode(Marker.self, from: data)
        guard message.type == "flowOffer" || marker.hasOffer else { return }
        try validate(message)
        // Reuse the existing strict Unicode/object parser for structural checks.
        // Only numeric tokens OUTSIDE strings are projected; the original bytes
        // above are decoded as typed UInt64/Double, never through this projection.
        let root = try PluginFlowJSON.parse(structuralProjection(data))
        try keys(root, ["apiVersion", "type", "pluginID", "session", "sequence", "flowOffer"])
        guard let offer = root["flowOffer"], let payload = message.flowOffer else { throw ModuleProblem("Missing flow offer.") }
        try keys(offer, ["version", "requestID", "address", "values", "consumeBeforeMs"])
        guard let address = offer["address"], let values = offer["values"]?.members else { throw ModuleProblem("Invalid flow offer shape.") }
        try keys(address, ["plugin", "name"])
        guard root["session"]?.string == message.session.uuidString.lowercased(),
              offer["requestID"]?.string == payload.requestID.uuidString.lowercased(),
              values.count <= 16, values.allSatisfy({ ModulePackage.validKey($0.name) && $0.value.scalarType != nil && $0.value.scalarType != "null" }) else {
            throw ModuleProblem("Invalid flow offer wire identity or values.")
        }
    }
    private static func validate(_ message: PluginMessage) throws {
        guard message.type == "flowOffer", message.apiVersion == 1,
              message.pluginID.count <= 100,
              message.pluginID.range(of: #"^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$"#, options: .regularExpression) != nil,
              let offer = message.flowOffer,
              message.action == nil, message.snapshot == nil, message.features == nil, message.visible == nil,
              message.presented == nil, message.mediaVisible == nil, message.frame == nil, message.bus == nil,
              message.agenda == nil, message.agendaDate == nil, message.viewEvent == nil, message.volumeCommand == nil,
              message.volumeResult == nil, message.viewResource == nil, message.viewResourceResult == nil,
              message.viewResourceCancel == nil, message.appearance == nil, message.caption == nil else {
            throw ModuleProblem("Invalid or mixed flow offer message.")
        }
        try offer.validate()
    }
    private static func keys(_ value: PluginFlowJSON, _ expected: Set<String>) throws {
        guard let members = value.members, members.count == expected.count,
              members.allSatisfy({ expected.contains($0.name) }) else { throw ModuleProblem("Invalid flow offer fields.") }
    }
    private static func structuralProjection(_ data: Data) -> Data {
        let bytes = Array(data)
        var result = Data(); result.reserveCapacity(bytes.count)
        var index = 0, quoted = false, escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                result.append(byte); index += 1
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 {
                quoted = true; result.append(byte); index += 1
            } else if byte == 45 || (48...57).contains(byte) {
                // Original typed JSONDecoder has already established numeric
                // grammar. Invalid original syntax never becomes accepted here.
                repeat { index += 1 } while index < bytes.count && ([43, 45, 46, 69, 101].contains(bytes[index]) || (48...57).contains(bytes[index]))
                result.append(48)
            } else { result.append(byte); index += 1 }
        }
        return result
    }
}
