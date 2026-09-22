import Foundation
import Security

/// Shared storage helpers. A native plugin supplies its own bundle identity.
/// Namespaces prevent accidental collisions; they are not a sandbox for trusted native code.
public enum PluginStorage {
    public static func directory(id: String) throws -> URL {
        guard id.range(of: #"^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$"#, options: .regularExpression) != nil, id.count <= 100 else { throw ModuleProblem("Invalid plugin storage identity.") }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeroNookPlugins/" + id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

public struct PluginCredentials: Sendable {
    private let service: String
    public init(pluginID: String) { service = "NeroNook.plugin." + pluginID }
    private func query(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    public func save(_ value: String, account: String) throws {
        let data = Data(value.utf8), base = query(account)
        guard !data.isEmpty, data.count <= 8192 else { throw ModuleProblem("Credential exceeds its limit.") }
        let result = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = base; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ModuleProblem("Could not save the plugin credential.") }
        } else if result != errSecSuccess { throw ModuleProblem("Could not update the plugin credential.") }
    }
    public func read(account: String) throws -> String {
        var item = query(account); item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count <= 8192,
              let value = String(data: data, encoding: .utf8) else { throw ModuleProblem("Plugin credential unavailable. Open Plugin Settings to reconnect.") }
        return value
    }
    public func remove(account: String) throws {
        let result = SecItemDelete(query(account) as CFDictionary)
        guard [errSecSuccess, errSecItemNotFound].contains(result) else { throw ModuleProblem("Could not remove the plugin credential.") }
    }
}
