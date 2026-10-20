import Foundation
import Combine

/// Optional, local-only Nook tools. Catalog discovery never grants access.
public enum PluginWorkspace {
    public static func read(_ name: String) -> PluginRegisteredAction {
        let titles = ["read_modules": "List installed Nook modules", "read_attention": "Read module notification indicators"]
        return .init(name, title: titles[name] ?? name,
                     input: .init([.init("offset", .number, required: false, minimum: 0, maximum: 10000)]),
                     output: .init([.init("items", .string), .init("next", .number, minimum: -1), .init("total", .number), .init("observed_at", .string)]))
    }
    public static let open = PluginRegisteredAction("open_module", title: "Show a module in the Nook",
        input: .init([.init("module_id", .string)]), output: .init([.init("shown", .boolean)]), effect: .localChange, timeoutSeconds: 5)
}

/// One read/open at a time. Watches are explicit and session-only. This client
/// never sends workspace data to a reasoning provider, and never retries writes.
@MainActor public final class PluginWorkspaceClient: ObservableObject {
    public var send: ((PluginBusMessage) -> Void)?
    public var accessRequestsAvailable = false
    /// Completion is correlated to the active request; cancellation completes false.
    public var didComplete: ((String, Bool) -> Void)?
    @Published public private(set) var modules: [[String:String]] = []
    @Published public private(set) var attention: [[String:String]] = []
    @Published public private(set) var status = "Connect Nook to choose a module."
    @Published public private(set) var busy = false
    @Published public private(set) var watching = false
    private var entries: [PluginCatalogEntry] = []
    private var pending: (id: UUID, action: PluginRegisteredAction, address: PluginActionAddress?, offset: Int, deadline: Date)?
    private var rows: [[String:String]] = []
    private var lastAttention: Date?
    private var nextWatch = Date.distantPast
    public init() {}
    public func catalog(_ entries: [PluginCatalogEntry]) {
        self.entries = entries.filter { $0.action == PluginWorkspace.read("read_modules") || $0.action == PluginWorkspace.read("read_attention") || $0.action == PluginWorkspace.open }
        if !self.entries.contains(where: { $0.action == PluginWorkspace.read("read_modules") }) { modules = [] }
        if !self.entries.contains(where: { $0.action == PluginWorkspace.read("read_attention") }) {
            attention = []; watching = false; lastAttention = nil
        }
        if let p = pending, let address = p.address, !self.entries.contains(where: { $0.address == address && $0.action == p.action }) {
            stop(); status = "Nook access changed. Connect again when ready."
        }
    }
    public func refreshModules() throws { try begin(PluginWorkspace.read("read_modules")) }
    public func refreshAttention() throws { try begin(PluginWorkspace.read("read_attention")) }
    public func watch() throws { watching = true; do { try begin(PluginWorkspace.read("read_attention")) } catch { watching = false; throw error } }
    public func open(_ id: String) throws {
        guard modules.contains(where: { $0["id"] == id && $0["enabled"] == "true" }) else { throw ModuleProblem("Refresh the available modules before opening one.") }
        try begin(PluginWorkspace.open, values: ["module_id": .string(id)])
    }
    public func stopWatching() { watching = false; attention = []; lastAttention = nil; if pending?.action.id == "read_attention" { stop() } }
    public func stop() {
        let id = pending?.id, action = pending?.action.id; pending = nil; busy = false; rows = []
        if let id { send?(.init(.cancel, requestID: id)) }; status = "Nook request stopped."
        if let action { didComplete?(action, false) }
    }
    public func disconnect() { stop(); watching = false; modules = []; attention = []; entries = []; lastAttention = nil }
    public func tick(now: Date = Date()) {
        if let p = pending, now >= p.deadline { fail("Nook request timed out. Nothing was retried."); return }
        if let lastAttention, now.timeIntervalSince(lastAttention) > 30 { attention = []; self.lastAttention = nil }
        if watching && pending == nil && now >= nextWatch {
            guard entries.contains(where: { $0.action == PluginWorkspace.read("read_attention") }) else { watching = false; attention = []; return }
            do { try begin(PluginWorkspace.read("read_attention")) } catch { fail(error.localizedDescription) }
        }
    }
    private func begin(_ action: PluginRegisteredAction, values: [String:PluginValue] = [:]) throws {
        guard pending == nil, send != nil else { throw ModuleProblem("Finish or cancel the current Nook request first.") }
        let matches = entries.filter { $0.action == action }
        guard matches.count <= 1 else { throw ModuleProblem("More than one workspace provider is connected. Choose one in Shared Actions.") }
        guard matches.count == 1 || accessRequestsAvailable else { throw ModuleProblem("Connect this Nook capability through Shared Actions.") }
        let id = UUID(), address = matches.first?.address
        pending = (id, action, address, 0, Date().addingTimeInterval(address == nil ? 125 : 30)); rows = []; busy = true
        status = address == nil ? "Allow this Nook connection in the popup." : action.id == "open_module" ? "Review opening this module in the Nook." : "Reading Nook…"
        if let address { send?(.init(.invoke, requestID: id, address: address, values: values)) }
        else { send?(.init(.requestAccess, requestID: id, values: values, access: .init(action: action))) }
    }
    public func receive(_ message: PluginBusMessage) {
        guard var p = pending, message.requestID == p.id else { return }
        if message.operation == .accessGranted {
            guard p.address == nil, message.catalog?.count == 1, let entry = message.catalog?.first, entry.action == p.action, entry.channel == nil,
                  entry.address.name == p.action.id, (try? entry.address.validate()) != nil else { fail("Invalid Nook permission response."); return }
            p.address = entry.address; p.deadline = Date().addingTimeInterval(30); pending = p
            if !entries.contains(entry) { entries.append(entry) }; return
        }
        if message.operation == .failure { fail(message.error ?? "Nook access is unavailable."); return }
        guard message.operation == .update, let update = message.update else { return }
        guard update.phase.terminal else { status = update.message; return }
        guard update.phase == .succeeded, p.address != nil else { fail(update.message.isEmpty ? "Nook request ended." : update.message); return }
        do {
            try p.action.output.validate(update.values)
            if p.action.id == "open_module" {
                guard update.values["shown"] == .boolean(true) else { throw ModuleProblem("The module could not be shown.") }
                pending = nil; busy = false; status = "Module opened. No action was run."; didComplete?(p.action.id, true); return
            }
            guard case .string(let raw) = update.values["items"], raw.utf8.count <= 2048,
                  case .number(let next) = update.values["next"], next.isFinite, next.rounded() == next,
                  case .number(let total) = update.values["total"], total.isFinite, total >= 0, total <= 512,
                  case .string(let observed) = update.values["observed_at"], let date = ISO8601DateFormatter().date(from: observed), abs(date.timeIntervalSinceNow) <= 30 else { throw ModuleProblem("Nook data is stale or invalid.") }
            let page = try JSONDecoder().decode([[String:String]].self, from: Data(raw.utf8))
            guard page.count <= 8, page.allSatisfy({ $0.count <= 10 && $0.allSatisfy({ $0.key.count <= 40 && $0.value.count <= 120 }) }), rows.count + page.count <= 512,
                  next == -1 || (!page.isEmpty && next == Double(p.offset + page.count) && next <= total) else { throw ModuleProblem("Nook page limits were exceeded.") }
            rows += page
            if next != -1 {
                guard let address = p.address else { throw ModuleProblem("Nook provider is unavailable.") }
                p.id = UUID(); p.offset = Int(next); p.deadline = Date().addingTimeInterval(30); pending = p
                send?(.init(.invoke, requestID: p.id, address: address, values: ["offset": .number(next)])); return
            }
            if p.action.id == "read_modules" {
                let selected = rows.filter { $0["enabled"] == "true" && $0["kind"] == nil }
                guard selected.allSatisfy({ row in guard let id = row["id"], let name = row["name"], !name.isEmpty else { return false }; return (try? PluginActionAddress(id,"open_module").validate()) != nil }), Set(selected.compactMap { $0["id"] }).count == selected.count else { throw ModuleProblem("The module list is invalid.") }
                modules = selected; status = modules.isEmpty ? "No enabled modules." : "Choose a module."
            } else {
                guard rows.allSatisfy({ $0["module_id"] != nil && $0["name"] != nil && $0["title"] != nil }) else { throw ModuleProblem("The activity list is invalid.") }
                attention = rows; lastAttention = Date(); nextWatch = Date().addingTimeInterval(10); status = attention.isEmpty ? "You're all caught up." : "Current Nook activity."
            }
            pending = nil; busy = false; rows = []; didComplete?(p.action.id, true)
        } catch { fail(error.localizedDescription) }
    }
    private func fail(_ text: String) {
        let action = pending?.action.id; stop()
        if action == "read_modules" { modules = [] }
        if action == "read_attention" { attention = []; watching = false; lastAttention = nil }
        status = String(text.prefix(300))
    }
}
