import Foundation

public struct InventoryError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A migration inventory, not an executable profile. User settings never enter it.
public struct ProfileInventory: Codable, Sendable {
    public var profiles = 0
    public var pages = 0
    public var controllers: [String: Int] = [:]
    public var actionTypes: [String: Int] = [:]
    public var deviceModels: [String: Int] = [:]
    public var issues: [String] = []

    public var actionCount: Int { actionTypes.values.reduce(0, +) }
    public var nativeCandidateCount: Int {
        actionTypes.filter { Self.nativeCandidates.contains($0.key) }.values.reduce(0, +)
    }
    /// These are implementation targets, never a declaration of runtime support.
    public static let nativeCandidates: Set<String> = [
        "com.elgato.streamdeck.system.text", "com.elgato.streamdeck.system.hotkey",
        "com.elgato.streamdeck.system.website", "com.elgato.streamdeck.system.open",
        "com.elgato.streamdeck.system.multimedia", "com.elgato.streamdeck.system.keybrightness",
        "com.elgato.streamdeck.profile.backtoparent", "com.elgato.streamdeck.profile.openchild"
    ]

    /// Reads an explicitly selected ProfilesV2/ProfilesV3 directory without modifying it.
    /// Folders and page manifests are bounded and symbolic links are rejected.
    public static func read(directory: URL) throws -> ProfileInventory {
        let fm = FileManager.default
        let root = directory.standardizedFileURL
        guard root.isFileURL, root.path == root.resolvingSymlinksInPath().path else {
            throw InventoryError("Select a local profile folder without symbolic links.")
        }
        let urls = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        let profiles = urls.filter { $0.pathExtension == "sdProfile" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard profiles.count <= 128 else { throw InventoryError("Too many profiles for one import review.") }
        var result = ProfileInventory()
        for (profileIndex, profile) in profiles.enumerated() {
            do {
                try verifyDirectory(profile)
                let manifest = try object(profile.appendingPathComponent("manifest.json"))
                guard manifest["Name"] is String, manifest["Device"] is [String: Any], manifest["Pages"] is [String: Any] else {
                    throw InventoryError("Unsupported profile manifest.")
                }
                result.profiles += 1
                if let device = manifest["Device"] as? [String: Any], let model = device["Model"] as? String, validIdentifier(model) {
                    result.deviceModels[model, default: 0] += 1
                }
                let pageRoot = profile.appendingPathComponent("Profiles")
                try verifyDirectory(pageRoot)
                let pages = try fm.contentsOfDirectory(at: pageRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard pages.count <= 256 else { throw InventoryError("Too many pages in profile.") }
                for (pageIndex, page) in pages.enumerated() {
                    do {
                        try verifyDirectory(page)
                        let data = try boundedData(page.appendingPathComponent("manifest.json"))
                        try result.includePage(data)
                    } catch {
                        result.issues.append("Profile \(profileIndex + 1), page \(pageIndex + 1): unsupported or unreadable page.")
                    }
                }
            } catch {
                result.issues.append("Profile \(profileIndex + 1): unsupported or unreadable profile.")
            }
        }
        return result
    }

    /// Parses only action identities and controller kinds. Settings, images, URLs,
    /// titles, device serials and nested action payloads are deliberately excluded.
    public mutating func includePage(_ data: Data) throws {
        guard data.count <= 2_097_152,
              let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controls = page["Controllers"] as? [[String: Any]], controls.count <= 8 else {
            throw InventoryError("Unsupported page schema or size.")
        }
        var stagedControllers: [String: Int] = [:]
        var stagedActions: [String: Int] = [:]
        for controller in controls {
            guard let kind = controller["Type"] as? String, validIdentifier(kind) else {
                throw InventoryError("Invalid controller type.")
            }
            stagedControllers[kind, default: 0] += 1
            if controller["Actions"] == nil || controller["Actions"] is NSNull { continue }
            guard let actions = controller["Actions"] as? [String: Any], actions.count <= 128 else {
                throw InventoryError("Invalid action collection.")
            }
            for (position, value) in actions {
                guard position.range(of: #"^[0-9]{1,2},[0-9]{1,2}$"#, options: .regularExpression) != nil,
                      let action = value as? [String: Any], let uuid = action["UUID"] as? String, validIdentifier(uuid) else {
                    throw InventoryError("Invalid action identity or position.")
                }
                stagedActions[uuid, default: 0] += 1
            }
        }
        // Commit only completely parsed pages, so a malformed action never creates
        // a misleading partial count that looks like a successful import.
        for (key, count) in stagedControllers { controllers[key, default: 0] += count }
        for (key, count) in stagedActions { actionTypes[key, default: 0] += count }
        pages += 1
    }

    private static func verifyDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw InventoryError("Invalid profile directory.") }
    }
    private static func boundedData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 2_097_152 else { throw InventoryError("Invalid manifest file.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 2_097_153) ?? Data()
        guard data.count <= 2_097_152 else { throw InventoryError("Manifest exceeds size limit.") }
        return data
    }
    private static func object(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: boundedData(url)) as? [String: Any] else { throw InventoryError("Invalid manifest.") }
        return value
    }
}

private func validIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 160 && value.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
}
