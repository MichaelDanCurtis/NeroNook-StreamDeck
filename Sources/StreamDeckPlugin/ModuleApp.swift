import AppKit
import SwiftUI
import NookPluginSDK

let moduleID = "cafe.nero.plugin.streamdeck"

@MainActor final class ModuleApp: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var connection = "Waiting for the Elgato plugin"
    @Published var lastResult = "No actions run yet"
    @Published var actionCount = 0
    @Published var runCount = 0
    var window: NSWindow?
    @Published var showHelp = false
    @Published var schemaRevision = 0
    @Published var selectedSchema: PluginCatalogEntry?
    @Published var devices: [String: DeckDevice] = [:]
    @Published var slots: [String: DeckSlot] = [:]
    @Published var selectedSlot = ""
    @Published var selectedDevice = ""
    @Published var menuContext = ""
    @Published var menuSelected = ""
    @Published var notice = ""
    @Published var rebinding: DeckRebindingView?
    @Published var rebindRequests = DeckRebindingUIRequests()
    @Published var rebindPresentation = DeckRebindingPresentation()
    @Published var rebindFeedback = ""
    var rebindRequestPending: Bool { rebindRequests.waiting }
    var rebindAckTask: Task<Void, Never>?
    var rebindWindow: NSWindow?
    @Published var recovery: DeckRecoveryView?
    @Published var recoveryPresentation = DeckRecoveryPresentation()
    @Published var recoveryRequests = DeckRecoveryUIRequests()
    @Published var recoveryFeedback = ""
    var recoveryAckTask: Task<Void, Never>?
    var recoveryWindowController: DeckRecoveryWindowController?
    var recoveryRequestPending: Bool { recoveryRequests.waiting }
    var customViews = false
    var presentation = false
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var timer: Timer?
    private let listener: LocalBridge
    var peer: LocalConnection?
    private var peerID = UUID()
    var rebindPeerEpoch: UUID { peerID }
    private let inputReader = ModuleInputReader()
    var catalog = PluginCatalogAccumulator()
    private var requests = Set<UUID>()
    private var channels = Set<PluginActionAddress>()
    let hosted = CommandLine.arguments.contains("--neronook-plugin")
    init(scope: BridgeScope = .live) {
        listener = LocalBridge(scope: scope)
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard hosted else { showWindow(); return }
        inputReader.start { [weak self] message in DispatchQueue.main.async {
            guard let message else { NSApp.terminate(nil); return }
            self?.receive(message)
        } }
    }

    func applicationWillTerminate(_ notification: Notification) { recoveryAckTask?.cancel(); rebindAckTask?.cancel(); peer?.close(); listener.stop() }
    private func receive(_ message: PluginMessage) {
        guard message.pluginID == moduleID else { NSApp.terminate(nil); return }
        if session == nil {
            guard message.type == "hello", message.features?.contains("actions-v1") == true else { NSApp.terminate(nil); return }
            session = message.session; PluginAppearanceStore.shared.beginSession(pluginID:moduleID,session:message.session)
            presentation = message.features?.contains("presentation-v1") == true
            customViews = message.features?.contains("custom-views-v1") == true
            emit("ready", features: ["appearance-v1", "actions-v1", "dashboard-v1", "panels-v1"] + (customViews ? ["custom-views-v1"] : []) + (presentation ? ["presentation-v1"] : []) + (message.features?.contains("run-display-v1") == true ? ["run-display-v1"] : []))
            send(.init(.register, registration: .init(actions: [
                .init("check_connection", title: "Check Stream Deck connection", output: .init([.init("connected", .boolean), .init("message", .string)]))
            ], channels: [.init("connection", title: "Stream Deck connection", kind: .state, schema: .init([.init("connected", .boolean), .init("message", .string)]))])))
            do { try listener.listen { [weak self] peer in DispatchQueue.main.async { self?.accept(peer) } } }
            catch { connection = "Local bridge unavailable: \(error.localizedDescription)" }
            timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }; RunLoop.main.add(timer!, forMode: .common)
            tick(); return
        }
        guard session == message.session else { NSApp.terminate(nil); return }; if message.type == "appearance" { _ = PluginAppearanceStore.shared.receive(message); return }
        if message.type == "viewEvent", let event = message.viewEvent { do { try handleView(event) } catch { notice = error.localizedDescription }; tick(); return }
        if message.type == "bus", let bus = message.bus { receiveBus(bus) }
        else if message.type == "action" {
            if message.action == "configure" { showWindow() }
            else if message.action == "check" { check() }
        }
    }
    private func receiveBus(_ bus: PluginBusMessage) {
        if bus.operation == .execute, bus.address == .init(moduleID, "check_connection") {
            send(.init(.update, requestID: bus.requestID, update: .init(.succeeded, values: ["connected": .boolean(peer != nil), "message": .string(peer == nil ? "Core connected; Elgato plugin not connected yet" : "Core and Elgato plugin connected")]))); return
        }
        if bus.operation == .catalog {
            // Invalidate before parsing/forwarding any fragment. The companion
            // advances its generation even for an identical complete catalog.
            rebindPresentation.catalogStarted()
            defer { objectWillChange.send(); tick() }
            do { if try catalog.receive(bus) {
                actionCount = catalog.entries.filter { $0.action != nil }.count
                rebindPresentation.catalogCompleted()
            } }
            catch { catalog.reset(); actionCount = 0; rebindPresentation.catalogFailed() }
            forward(bus); return
        }
        if bus.operation == .update, let update = bus.update {
            guard requests.contains(bus.requestID) else { return }
            notice = ""
            lastResult = update.message.isEmpty ? update.phase.rawValue : update.message
            if update.phase == .succeeded { runCount += 1; lastResult = update.values["message"]?.display ?? (update.message.isEmpty ? "Action completed" : update.message) }
            if requests.contains(bus.requestID) { forward(bus); if update.phase.terminal { requests.remove(bus.requestID) } }
        } else if bus.operation == .event { forward(bus) }
        else if bus.operation == .failure {
            guard requests.contains(bus.requestID) else { return }
            notice = ""; lastResult = bus.error ?? "Action rejected"
            forward(bus); requests.remove(bus.requestID)
        }
    }
    private func accept(_ client: LocalConnection) {
        guard peer == nil else { client.close(); return }
        peer = client; let id = UUID(); peerID = id; connection = "Connected to Elgato Stream Deck"
        rebindPresentation.peerChanged(to: id)
        recovery = nil; recoveryPresentation.reset(); recoveryRequests.reset(); recoveryAckTask?.cancel(); recoveryAckTask = nil
        recoveryFeedback = "Reading durable recovery status…"
        // The reset/device/key stream is ordered. Independent Tasks may apply a
        // reset after its keys; the serial main queue preserves wire order.
        client.received = { [weak self] data in DispatchQueue.main.async {
            guard let self, self.peerID == id else { return }
            do {
                if let wire = try? JSONDecoder().decode(DeckWire.self, from: data) {
                    let inventoryReset = wire.deckEvent == "reset"
                    if inventoryReset { self.rebindPresentation.reset() }
                    self.receiveDeck(wire)
                    // Inventory reset may follow an earlier discovery response.
                    // Request a real fresh catalog; this cannot revive an old review.
                    if inventoryReset { self.send(.init(.discover)) }
                    return
                }
                let bus = try JSONDecoder().decode(PluginBusMessage.self, from: data)
                guard [.discover, .invoke, .cancel, .subscribe, .unsubscribe].contains(bus.operation) else { client.close(); return }
                if bus.operation == .invoke { guard self.requests.count < 32 else { self.forward(.init(.failure, requestID: bus.requestID, error: "Too many pending actions")); return }; self.requests.insert(bus.requestID) }
                if bus.operation == .cancel { guard self.requests.contains(bus.requestID) else { return } }
                if bus.operation == .subscribe, let address = bus.address { guard self.channels.count < 32 || self.channels.contains(address) else { return }; self.channels.insert(address) }
                if bus.operation == .unsubscribe, let address = bus.address { self.channels.remove(address) }
                self.send(bus)
                if bus.operation == .invoke, self.presentation,
                   let entry = self.catalog.entries.first(where: { $0.address == bus.address }),
                   entry.action?.effect != .readOnly { self.emit("present") }
            } catch { client.close() }
        } }
        client.ended = { [weak self] in DispatchQueue.main.async {
            guard let self, self.peerID == id else { return }
            for request in self.requests { self.send(.init(.cancel, requestID: request)) }
            for address in self.channels { self.send(.init(.unsubscribe, address: address)) }
            self.requests = []; self.channels = []; self.devices = [:]; self.slots = [:]; self.menuContext = ""; self.notice = "Elgato disconnected. Nothing was replayed."; self.peer = nil; self.connection = "Waiting for the Elgato plugin"
            self.rebindPresentation.peerChanged(to: nil)
            self.rebinding = nil; self.rebindRequests.reset(); self.rebindAckTask?.cancel()
            self.rebindAckTask = nil; self.rebindFeedback = "Elgato disconnected. Previous reconnection results are not automatically restored."
            self.recoveryPresentation.reset()
            self.recoveryRequests.reset(); self.recoveryAckTask?.cancel(); self.recoveryAckTask = nil
            self.recoveryFeedback = "Elgato disconnected. Last recovery information is historical; nothing was retried or cleared."
        } }
        client.start(); send(.init(.discover)); tick()
        submitRecovery("recovery_status", .init(offset: 0)) // read-only, never opens UI or replays work
    }
    private func forward(_ bus: PluginBusMessage) { if let data = try? JSONEncoder().encode(bus) { peer?.send(data) } }
    func check() { let id = UUID(); requests.insert(id); send(.init(.invoke, requestID: id, address: .init(moduleID, "check_connection"))) }
    private func send(_ bus: PluginBusMessage) { emit("bus", bus: bus) }
    func emit(_ type: String, features: [String]? = nil, snapshot: PluginSnapshot? = nil, bus: PluginBusMessage? = nil) {
        guard let session else { return }; if type != "ready" { sequence += 1 }
        do { try FileHandle.standardOutput.write(contentsOf: PluginMessage(type: type, pluginID: moduleID, session: session, sequence: sequence, snapshot: snapshot, features: features, bus: bus).encoded()) }
        catch { NSApp.terminate(nil) }
    }
    func tick() {
        emit("snapshot", snapshot: .init(title: "Stream Deck", status: notice.isEmpty ? connection : notice, activity: peer == nil ? "Stream Deck · waiting" : "Stream Deck · connected", fields: [], actions: customViews ? [] : [.init("configure", "Open deck", symbol: "square.grid.3x3")], badge: peer == nil ? "Offline" : "Connected", panels: customViews ? [.init("deck", "Deck", customView: surface)] : [.init("deck", "Deck", sections: [.init("Stream Deck", connection), .init("Latest activity", lastResult)])]))
        send(.init(.publish, address: .init(moduleID, "connection"), values: ["connected": .boolean(peer != nil), "message": .string(peer == nil ? "Waiting" : "Connected")], lifetime: 6))
    }
    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Stream Deck"; w.contentMinSize = NSSize(width: 720, height: 430)
            w.contentView = NSHostingView(rootView: DeckWindow(model: self).pluginThemed()); w.isReleasedWhenClosed = false; w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
private final class ModuleInputReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "StreamDeckModule.input")
    private var lines = PluginLines()
    // All decoder access is confined to queue; callbacks cross to the main actor.
    func start(_ receive: @escaping @Sendable (PluginMessage?) -> Void) {
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { receive(nil); return }
            self?.queue.async { [weak self] in
                guard let self else { return }
                do { for message in try self.lines.append(data) { receive(message) } }
                catch { receive(nil) }
            }
        }
    }
}
