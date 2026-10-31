import Foundation

/// Optional action-policy-v1 declaration. This is not a sandbox or an authority grant.
public struct PluginActionExecutionPolicy: Codable, Equatable, Sendable {
    public var version: Int
    public var profile: String
    public var maxModelCalls: Int
    public var maxNestedInvocations: Int

    public init(version: Int = 1, profile: String = "programmatic", maxModelCalls: Int = 0, maxNestedInvocations: Int = 0) {
        self.version = version; self.profile = profile
        self.maxModelCalls = maxModelCalls; self.maxNestedInvocations = maxNestedInvocations
    }

    public func validate() throws {
        guard version == 1, profile.utf8.elementsEqual("programmatic".utf8),
              maxModelCalls == 0, maxNestedInvocations == 0 else {
            throw ModuleProblem("Invalid action execution policy.")
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, profile, maxModelCalls, maxNestedInvocations
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw ModuleProblem("Invalid action execution policy.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        profile = try values.decode(String.self, forKey: .profile)
        maxModelCalls = try values.decode(Int.self, forKey: .maxModelCalls)
        maxNestedInvocations = try values.decode(Int.self, forKey: .maxNestedInvocations)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(profile, forKey: .profile)
        try values.encode(maxModelCalls, forKey: .maxModelCalls)
        try values.encode(maxNestedInvocations, forKey: .maxNestedInvocations)
    }
}
