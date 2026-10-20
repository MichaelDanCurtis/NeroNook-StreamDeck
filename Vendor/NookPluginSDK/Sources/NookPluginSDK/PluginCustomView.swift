import Foundation

public struct PluginViewEventDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var input: PluginValueSchema
    public init(_ id: String, input: PluginValueSchema = .init()) { self.id = id; self.input = input }
}
/// Plugin-owned HTML/CSS/JS packaged under Resources/Views, never a remote URL.
public struct PluginCustomView: Codable, Equatable, Sendable {
    public var entry: String
    public var revision: String
    public var state: [String: PluginValue]
    public var events: [PluginViewEventDefinition]
    /// Optional plugin-owned raster resource namespaces. No remote URLs.
    public var resourceNamespaces: [String]?
    /// Exact isolated loopback or HTTPS documents. Never host tools; HTTPS requires separate negotiation.
    public var frames: [PluginViewFrame]?
    /// The view supplies its own title/navigation. Hosts may omit a duplicate header.
    public var ownsChrome: Bool?
    public init(entry: String, revision: String, state: [String: PluginValue] = [:], events: [PluginViewEventDefinition] = [], resourceNamespaces: [String]? = nil, frames: [PluginViewFrame]? = nil, ownsChrome: Bool? = nil) {
        self.entry = entry; self.revision = revision; self.state = state; self.events = events; self.resourceNamespaces = resourceNamespaces; self.frames = frames
        self.ownsChrome = ownsChrome
    }
    public func validate() throws {
        guard PluginViewResources.validPath(entry), entry.hasSuffix(".html"), ModulePackage.validKey(revision),
              state.count <= 64, state.keys.allSatisfy(ModulePackage.validKey),
              events.count <= 16, Set(events.map(\.id)).count == events.count,
              try JSONEncoder().encode(state).count <= 32768 else { throw ModuleProblem("Invalid custom view.") }
        guard (resourceNamespaces?.count ?? 0) <= 4, resourceNamespaces?.allSatisfy({ ModulePackage.validKey($0) && !$0.contains("/") }) ?? true else { throw ModuleProblem("Invalid resource namespaces.") }
        guard (frames?.count ?? 0) <= 2 else { throw ModuleProblem("Too many embedded documents.") }
        for frame in frames ?? [] { try frame.validate() }
        for event in events { guard ModulePackage.validKey(event.id) else { throw ModuleProblem("Invalid view event.") }; try event.input.validate() }
    }
    public func validate(_ resource: PluginViewResourceRequest) throws {
        try validate()
        guard resource.revision == revision, ModulePackage.validKey(resource.panelID),
              PluginViewResources.validPath(resource.path), let namespace = resource.path.split(separator: "/").first,
              resourceNamespaces?.contains(String(namespace)) == true else { throw ModuleProblem("This view resource is unavailable.") }
    }
    public func validate(_ event: PluginViewEvent) throws {
        try validate()
        guard event.revision == revision, ModulePackage.validKey(event.panelID),
              let definition = events.first(where: { $0.id == event.name }) else { throw ModuleProblem("This view changed or the event is unavailable.") }
        try definition.input.validate(event.values)
    }
}

public struct PluginViewFrame: Codable, Equatable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
    public var isRemote: Bool { URLComponents(string: url)?.scheme == "https" }
    public func validate() throws {
        guard url.utf8.count <= 512, let value = URLComponents(string: url),
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.percentEncodedPath == value.path else { throw ModuleProblem("Invalid embedded document.") }
        if value.scheme == "http" {
            guard value.host == "127.0.0.1", let port = value.port, (1024...65535).contains(port),
                  PluginViewResources.validPath(String(value.path.dropFirst())), value.path.hasSuffix(".html") else {
                throw ModuleProblem("Invalid plugin-owned document.")
            }
        } else {
            // HTTPS pages are exact documents; reject literal IP and local-suffix hosts.
            guard value.scheme == "https", value.port == nil, let host = value.host,
                  host == host.lowercased(), host.utf8.count <= 253,
                  host.range(of: #"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$"#, options: .regularExpression) != nil,
                  !["local", "localhost", "internal", "test", "invalid"].contains(String(host.split(separator: ".").last ?? "")),
                  value.path == "/" || PluginViewResources.validPath(String(value.path.dropFirst())) else {
                throw ModuleProblem("Invalid HTTPS document.")
            }
        }
    }
    public var origin: String {
        guard (try? validate()) != nil, let value = URLComponents(string: url), let host = value.host else { return "" }
        return "\(value.scheme!)://\(host)" + (value.port.map { ":\($0)" } ?? "")
    }
    public func allows(_ candidate: URL) -> Bool {
        guard (try? validate()) != nil, var value = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else { return false }
        value.fragment = nil
        return value.string == url
    }
}
public struct PluginViewEvent: Codable, Equatable, Sendable {
    public var panelID: String
    public var revision: String
    public var name: String
    public var values: [String: PluginValue]
    public init(panelID: String, revision: String, name: String, values: [String: PluginValue] = [:]) { self.panelID = panelID; self.revision = revision; self.name = name; self.values = values }
}

/// Resolve only normal, bounded files beneath one reviewed Views directory.
public enum PluginViewResources {
    public static let scheme = "nook-view"
    public static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 240 && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
        }
    }
    public static func file(_ path: String, root: URL) throws -> URL {
        guard validPath(path), root.isFileURL else { throw ModuleProblem("Invalid view asset path.") }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ModuleProblem("View root cannot be a symlink.") }
        var file = base
        for part in path.split(separator: "/") {
            file.appendPathComponent(String(part))
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ModuleProblem("View assets cannot contain symlinks.") }
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard file.resolvingSymlinksInPath().path.hasPrefix(base.path + "/"), values.isRegularFile == true,
              let size = values.fileSize, size <= 2 * 1024 * 1024, mime(file.pathExtension) != nil else { throw ModuleProblem("Unsupported or oversized view asset.") }
        return file
    }
    public static func mime(_ ext: String) -> String? {
        ["html":"text/html", "css":"text/css", "js":"text/javascript", "json":"application/json", "svg":"image/svg+xml", "png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "webp":"image/webp", "woff":"font/woff", "woff2":"font/woff2"][ext.lowercased()]
    }
}
