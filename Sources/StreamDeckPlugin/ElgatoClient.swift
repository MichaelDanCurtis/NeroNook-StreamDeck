import AppKit
import Foundation
import NookPluginSDK

@MainActor final class ElgatoClient {
    private struct Slot { var action: String; var settings: [String: Any] }
    private var socket: URLSessionWebSocketTask?
    private var local: LocalConnection?
    private var catalog = PluginCatalogAccumulator()
    private var slots: [String: Slot] = [:]
    private var runs: [UUID: String] = [:]
    private var subscriptions = Set<PluginActionAddress>()
    private var state: [PluginActionAddress: ([String: PluginValue], Date)] = [:]
    private var timer: Timer?
    private var generation = UUID()
    private var sending = false
    private var outbound: [String] = []
    private var outboundBytes = 0
    func start() {
        func argument(_ key: String) -> String? { guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { return nil }; return CommandLine.arguments[i + 1] }
        guard let raw = argument("-port"), let port = UInt16(raw), port > 0,
              let uuid = argument("-pluginUUID"), uuid.count <= 200,
              let event = argument("-registerEvent"), event == "registerPlugin" else { NSApp.terminate(nil); return }
        let session = URLSession(configuration: .ephemeral)
        let ws = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!); ws.maximumMessageSize = 131072; socket = ws; ws.resume()
        send(["event": event, "uuid": uuid])
        Task { [weak self] in
            do {
                while let self, let socket = self.socket {
                    let frame = try await socket.receive()
                    let data: Data
                    switch frame { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] { self.receive(object) }
                }
            } catch { NSApp.terminate(nil) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        tick()
    }
    private func receive(_ message: [String: Any]) {
        guard let event = message["event"] as? String, let context = message["context"] as? String, context.count <= 200 else { return }
        let payload = message["payload"] as? [String: Any] ?? [:]
        if event == "willDisappear" { slots[context] = nil; syncSubscriptions(); return }
        let action = message["action"] as? String ?? slots[context]?.action ?? ""
        guard ["cafe.nero.neronook.run", "cafe.nero.neronook.status"].contains(action) else { return }
        if event == "willAppear" || event == "didReceiveSettings" {
            guard slots.count < 128 || slots[context] != nil else { return }
            slots[context] = Slot(action: action, settings: payload["settings"] as? [String: Any] ?? [:])
            syncSubscriptions(); refresh(context); sendCatalog(context)
        } else if event == "keyDown" || (event == "sendToPlugin" && payload["test"] as? Bool == true), let slot = slots[context] {
            guard local != nil else { title(context, "NeroNook\nOffline"); return }
            if slot.action.hasSuffix(".status") { publish(.init(.discover)); return }
            guard !runs.values.contains(context), runs.count < 32 else { return }
            let address = address(slot)
            guard catalog.entries.contains(where: { $0.address == address && $0.action != nil }) else { title(context, "Allow in\nNeroNook"); return }
            do {
                let text = slot.settings["arguments"] as? String ?? "{}"
                guard text.utf8.count <= 8192 else { throw ModuleProblem("Arguments too large") }
                let values = try JSONDecoder().decode([String: PluginValue].self, from: Data(text.utf8))
                let request = UUID(); runs[request] = context
                publish(.init(.invoke, requestID: request, address: address, values: values)); title(context, "Running…")
            } catch { title(context, "Check\narguments") }
        } else if event == "propertyInspectorDidAppear" || event == "sendToPlugin" { sendCatalog(context) }
    }
    private func address(_ slot: Slot) -> PluginActionAddress {
        .init(slot.settings["provider"] as? String ?? moduleID, slot.settings["name"] as? String ?? (slot.action.hasSuffix(".status") ? "connection" : "check_connection"))
    }
    private func tick() {
        if local == nil {
            if let connection = try? LocalBridge.connect() {
                local = connection; let id = UUID(); generation = id
                connection.received = { [weak self] data in Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    do { self.receiveBus(try JSONDecoder().decode(PluginBusMessage.self, from: data)) } catch { connection.close() }
                } }
                connection.ended = { [weak self] in Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    self.local = nil; self.catalog.reset(); self.runs = [:]; self.state = [:]; self.subscriptions = []
                    for context in self.slots.keys { self.refresh(context) }
                } }
                connection.start(); publish(.init(.discover))
            }
        }
        for (context, slot) in slots where slot.action.hasSuffix(".status") || local == nil { refresh(context) }
    }
    private func receiveBus(_ message: PluginBusMessage) {
        if message.operation == .catalog {
            do { if try catalog.receive(message) {
                state = state.filter { address, _ in catalog.entries.contains { $0.address == address && $0.channel != nil } }
                syncSubscriptions(); for context in slots.keys { if !runs.values.contains(context) { refresh(context) }; sendCatalog(context) }
            } } catch { catalog.reset(); state = [:]; subscriptions = [] }
        } else if message.operation == .update, let context = runs[message.requestID], let update = message.update {
            switch update.phase {
            case .waitingReview: title(context, "Review\nin Nook")
            case .running: title(context, update.progress.map { "\(Int($0 * 100))%" } ?? "Running…")
            case .succeeded: title(context, "Done"); send(["event": "showOk", "context": context])
            case .cancelling: title(context, "Cancelling")
            case .cancelled: title(context, "Cancelled")
            case .failed: title(context, "Failed"); send(["event": "showAlert", "context": context])
            case .interrupted: title(context, "Check\noutcome")
            }
            if update.phase.terminal { runs[message.requestID] = nil }
        } else if message.operation == .failure, let context = runs.removeValue(forKey: message.requestID) { title(context, "Check\nNeroNook"); send(["event": "showAlert", "context": context]) }
        else if message.operation == .event, let address = message.address, let values = message.values, let ttl = message.lifetime {
            state[address] = (values, Date().addingTimeInterval(ttl)); for (context, slot) in slots where self.address(slot) == address { refresh(context) }
        }
    }
    private func syncSubscriptions() {
        guard local != nil else { return }
        let desired = Set(slots.values.filter { $0.action.hasSuffix(".status") }.map(address).filter { address in catalog.entries.contains { $0.address == address && $0.channel?.kind == .state } })
        for address in subscriptions.subtracting(desired) { publish(.init(.unsubscribe, address: address)); state[address] = nil }
        for address in desired.subtracting(subscriptions) { publish(.init(.subscribe, address: address)) }
        subscriptions = desired
    }
    private func refresh(_ context: String) {
        guard let slot = slots[context] else { return }
        guard local != nil else { title(context, "NeroNook\nOffline"); return }
        let target = address(slot)
        if slot.action.hasSuffix(".status") {
            guard let entry = catalog.entries.first(where: { $0.address == target && $0.channel?.kind == .state }) else { title(context, "Allow in\nNeroNook"); return }
            guard let (values, expiry) = state[target], expiry > Date() else { title(context, "Waiting /\nstale"); return }
            let field = slot.settings["field"] as? String ?? "message"
            title(context, values[field]?.display ?? entry.channel?.title ?? "No value")
        } else {
            let entry = catalog.entries.first { $0.address == target && $0.action != nil }
            title(context, entry?.action?.title ?? "Allow in\nNeroNook")
        }
    }
    private func publish(_ message: PluginBusMessage) { if let data = try? JSONEncoder().encode(message) { local?.send(data) } }
    private func title(_ context: String, _ value: String) { send(["event": "setTitle", "context": context, "payload": ["title": String(value.prefix(70)), "target": 0]]) }
    private func sendCatalog(_ context: String) {
        guard let slot = slots[context] else { return }
        let generation = UUID().uuidString
        send(["event": "sendToPropertyInspector", "action": slot.action, "context": context, "payload": ["catalogGeneration": generation, "catalog": [], "online": local != nil]])
        // Preserve framing bounds even when many other modules export actions.
        for entry in catalog.entries {
            guard let data = try? JSONEncoder().encode(entry), let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            send(["event": "sendToPropertyInspector", "action": slot.action, "context": context, "payload": ["catalogGeneration": generation, "catalog": [object]]])
        }
        send(["event": "sendToPropertyInspector", "action": slot.action, "context": context, "payload": ["catalogGeneration": generation, "complete": true, "online": local != nil]])
    }
    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 131072, let text = String(data: data, encoding: .utf8) else { return }
        guard outbound.count < 4096, outboundBytes + data.count <= 8 * 1024 * 1024 else { socket?.cancel(with: .goingAway, reason: nil); return }
        outbound.append(text); outboundBytes += data.count
        guard !sending else { return }; sending = true
        Task { [weak self] in
            guard let self else { return }
            while !self.outbound.isEmpty {
                let next = self.outbound.removeFirst(); self.outboundBytes -= next.utf8.count
                do { try await self.socket?.send(.string(next)) }
                catch { self.outbound = []; self.outboundBytes = 0; NSApp.terminate(nil); break }
            }
            self.sending = false
        }
    }
}
