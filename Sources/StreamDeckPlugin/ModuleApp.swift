import AppKit
import SwiftUI
import NookPluginSDK

let moduleID = "cafe.nero.plugin.streamdeck"

@MainActor final class ModuleApp: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var connection = "Waiting for the Elgato plugin"
    @Published var lastResult = "No actions run yet"
    @Published var actionCount = 0
    @Published var runCount = 0
    private var window: NSWindow?
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var timer: Timer?
    private var listener = LocalBridge()
    private var peer: LocalConnection?
    private var peerID = UUID()
    private let inputReader = ModuleInputReader()
    private var catalog = PluginCatalogAccumulator()
    private var requests = Set<UUID>()
    private var channels = Set<PluginActionAddress>()
    private let hosted = CommandLine.arguments.contains("--neronook-plugin")
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard hosted else { showWindow(); return }
        inputReader.start { [weak self] message in Task { @MainActor in
            guard let message else { NSApp.terminate(nil); return }
            self?.receive(message)
        } }
    }

    func applicationWillTerminate(_ notification: Notification) { peer?.close(); listener.stop() }
    private func receive(_ message: PluginMessage) {
        guard message.pluginID == moduleID else { NSApp.terminate(nil); return }
        if session == nil {
            guard message.type == "hello", message.features?.contains("actions-v1") == true else { NSApp.terminate(nil); return }
            session = message.session
            emit("ready", features: ["actions-v1", "dashboard-v1", "panels-v1"])
            send(.init(.register, registration: .init(actions: [
                .init("check_connection", title: "Check Stream Deck connection", output: .init([.init("connected", .boolean), .init("message", .string)]))
            ], channels: [.init("connection", title: "Stream Deck connection", kind: .state, schema: .init([.init("connected", .boolean), .init("message", .string)]))])))
            do { try listener.listen { [weak self] peer in Task { @MainActor in self?.accept(peer) } } }
            catch { connection = "Local bridge unavailable: \(error.localizedDescription)" }
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            tick(); return
        }
        guard session == message.session else { NSApp.terminate(nil); return }
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
            do { if try catalog.receive(bus) { actionCount = catalog.entries.filter { $0.action != nil }.count } }
            catch { catalog.reset(); actionCount = 0 }
            forward(bus); return
        }
        if bus.operation == .update, let update = bus.update {
            lastResult = update.message.isEmpty ? update.phase.rawValue : update.message
            if update.phase == .succeeded { runCount += 1; lastResult = update.values["message"]?.display ?? "Action completed" }
            if requests.contains(bus.requestID) { forward(bus); if update.phase.terminal { requests.remove(bus.requestID) } }
        } else if bus.operation == .event { forward(bus) }
        else if bus.operation == .failure {
            lastResult = bus.error ?? "Action rejected"
            forward(bus); requests.remove(bus.requestID)
        }
    }
    private func accept(_ client: LocalConnection) {
        guard peer == nil else { client.close(); return }
        peer = client; let id = UUID(); peerID = id; connection = "Connected to Elgato Stream Deck"
        client.received = { [weak self] data in Task { @MainActor in
            guard let self, self.peerID == id else { return }
            do {
                let bus = try JSONDecoder().decode(PluginBusMessage.self, from: data)
                guard [.discover, .invoke, .cancel, .subscribe, .unsubscribe].contains(bus.operation) else { client.close(); return }
                if bus.operation == .invoke { guard self.requests.count < 32 else { self.forward(.init(.failure, requestID: bus.requestID, error: "Too many pending actions")); return }; self.requests.insert(bus.requestID) }
                if bus.operation == .subscribe, let address = bus.address { guard self.channels.count < 32 || self.channels.contains(address) else { return }; self.channels.insert(address) }
                if bus.operation == .unsubscribe, let address = bus.address { self.channels.remove(address) }
                self.send(bus)
            } catch { client.close() }
        } }
        client.ended = { [weak self] in Task { @MainActor in
            guard let self, self.peerID == id else { return }
            for request in self.requests { self.send(.init(.cancel, requestID: request)) }
            for address in self.channels { self.send(.init(.unsubscribe, address: address)) }
            self.requests = []; self.channels = []; self.peer = nil; self.connection = "Waiting for the Elgato plugin"
        } }
        client.start(); send(.init(.discover)); tick()
    }
    private func forward(_ bus: PluginBusMessage) { if let data = try? JSONEncoder().encode(bus) { peer?.send(data) } }
    func check() { send(.init(.invoke, address: .init(moduleID, "check_connection"))) }
    private func send(_ bus: PluginBusMessage) { emit("bus", bus: bus) }
    private func emit(_ type: String, features: [String]? = nil, snapshot: PluginSnapshot? = nil, bus: PluginBusMessage? = nil) {
        guard let session else { return }; if type != "ready" { sequence += 1 }
        do { try FileHandle.standardOutput.write(contentsOf: PluginMessage(type: type, pluginID: moduleID, session: session, sequence: sequence, snapshot: snapshot, features: features, bus: bus).encoded()) }
        catch { NSApp.terminate(nil) }
    }
    private func tick() {
        emit("snapshot", snapshot: .init(title: "Stream Deck", status: connection, activity: peer == nil ? "Stream Deck · waiting" : "Stream Deck · connected", fields: [.init("Available actions", "\(actionCount)"), .init("Completed runs", "\(runCount)")], actions: [.init("check", "Check connection", symbol: "checkmark.circle")], badge: peer == nil ? "Waiting" : "Connected", panels: [.init("bridge", "Connection", sections: [.init("Elgato bridge", connection), .init("Last action", lastResult), .init("Automation ready", "Assign NeroNook Run Action or Show Status in Elgato. Shared actions and access are managed in NeroNook → Settings → Modules.")])]))
        send(.init(.publish, address: .init(moduleID, "connection"), values: ["connected": .boolean(peer != nil), "message": .string(peer == nil ? "Waiting" : "Connected")], lifetime: 6))
    }
    func showWindow() {
        if window == nil {
            let view = ModuleSettings(model: self, hosted: hosted)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Stream Deck module"; w.contentView = NSHostingView(rootView: view); w.isReleasedWhenClosed = false; w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
struct ModuleSettings: View {
    @ObservedObject var model: ModuleApp
    let hosted: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Stream Deck", systemImage: "square.grid.2x2").font(.largeTitle.bold())
            Text(hosted ? model.connection : "Install this independent module in NeroNook Settings → Modules.")
            Text("Elgato continues to manage your hardware, profiles and existing plugins. Add the NeroNook companion plugin to Elgato, then assign Run Action or Show Status to a key.").foregroundStyle(.secondary)
            Divider()
            LabeledContent("Available actions", value: "\(model.actionCount)")
            Text(model.lastResult).font(.caption).foregroundStyle(.secondary)
            Button("Check core connection") { model.check() }.disabled(!hosted)
            Text("Access to other modules is granted in NeroNook Settings → Modules. Device-changing actions require review there.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 520, height: 350)
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
