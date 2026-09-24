import AppKit
import Foundation
import NookPluginSDK

@MainActor final class ElgatoClient {
    private struct Slot { var action: String; var settings: [String: Any]; var view: DeckSlot }
    private var devices: [String: DeckDevice] = [:]
    private var pending: [String: (request: UUID, settings: [String: String], expires: Date)] = [:]
    private var menuChoice: [String: PluginCatalogEntry] = [:]
    private var menuOpened: [String: Date] = [:]
    private var menuIndex: [String: Int] = [:]
    private var openedMenus = Set<String>()
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
        if let rawInfo = argument("-info"), let data = rawInfo.data(using: .utf8), let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = info["devices"] as? [[String: Any]] {
            for d in list { if let id = d["id"] as? String { recordDevice(id, d) } }
        }
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
        guard let event = message["event"] as? String else { return }
        if ["deviceDidConnect", "deviceDidChange"].contains(event), let id = message["device"] as? String, let info = message["deviceInfo"] as? [String: Any] { recordDevice(id, info); return }
        if event == "deviceDidDisconnect", let id = message["device"] as? String {
            devices[id] = nil
            for key in Array(slots.keys) where slots[key]?.view.device == id { removeSlot(key) }
            wire(.init(deckEvent: "removeDevice", context: id)); return
        }
        guard let context = message["context"] as? String, context.count <= 200 else { return }
        let payload = message["payload"] as? [String: Any] ?? [:]
        if event == "willDisappear" { removeSlot(context); return }
        let action = message["action"] as? String ?? slots[context]?.action ?? ""
        guard ["cafe.nero.neronook.run", "cafe.nero.neronook.status", "cafe.nero.neronook.menu"].contains(action) else { return }
        if event == "willAppear" || event == "didReceiveSettings" {
            guard slots.count < 128 || slots[context] != nil else { return }
            let settings = payload["settings"] as? [String: Any] ?? [:]
            let safe = settings.compactMapValues { $0 as? String }.filter { ["provider", "name", "arguments", "field", "label"].contains($0.key) }
            guard safe.values.allSatisfy({ $0.utf8.count <= 8192 }) else { return }
            let coordinate = payload["coordinates"] as? [String: Int] ?? [:]
            let old = slots[context]?.view
            let view = DeckSlot(context: context, action: action, device: message["device"] as? String ?? old?.device ?? "unknown", controller: payload["controller"] as? String ?? old?.controller ?? "Keypad", column: coordinate["column"] ?? old?.column ?? 0, row: coordinate["row"] ?? old?.row ?? 0, revision: UUID().uuidString, settings: safe)
            slots[context] = Slot(action: action, settings: settings, view: view)
            if view.controller == "Encoder" { send(["event": "setFeedbackLayout", "context": context, "payload": ["layout": "$A1"]]) }
            if let save = pending.removeValue(forKey: context) { wire(.init(deckEvent: "result", context: context, request: save.request, message: safe == save.settings ? "Mapping saved in Elgato" : "Elgato returned different settings. Check this key.")) }
            publishSlot(context)
            syncSubscriptions(); refresh(context); sendCatalog(context)
        } else if event == "dialRotate", let ticks = payload["ticks"] as? Int, slots[context]?.view.isMenu == true {
            let items = DeckMapping.menuEntries(catalog.entries); guard !items.isEmpty else { return }
            menuIndex[context] = ((menuIndex[context] ?? 0) + max(-100, min(100, ticks)) % items.count + items.count) % items.count
            openedMenus.insert(context); refreshMenu(context, open: true)
        } else if event == "keyDown" || event == "dialDown" || event == "touchTap" || (event == "sendToPlugin" && payload["test"] as? Bool == true), let slot = slots[context] {
            guard local != nil else { title(context, "NeroNook\nOffline"); return }
            if slot.view.isMenu {
                if openedMenus.contains(context), Date().timeIntervalSince(menuOpened[context] ?? .distantPast) < 30 { runMenu(context, selected: nil) }
                else { openedMenus.insert(context); refreshMenu(context, open: true) }
                return
            }
            if slot.action.hasSuffix(".status") { publish(.init(.discover)); return }
            guard !runs.values.contains(context), runs.count < 32 else { return }
            let address = address(slot)
            guard catalog.entries.contains(where: { $0.address == address && $0.action != nil }) else { title(context, "Allow in\nNeroNook"); return }
            do {
                let text = slot.settings["arguments"] as? String ?? "{}"
                guard text.utf8.count <= 8192 else { throw ModuleProblem("Arguments too large") }
                let values = try JSONDecoder().decode([String: PluginValue].self, from: Data(text.utf8))
                if let entry = catalog.entries.first(where: { $0.address == address }), let definition = entry.action { try definition.input.validate(values) }
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
                    do { if let command = try? JSONDecoder().decode(DeckWire.self, from: data) { self.command(command) } else { self.receiveBus(try JSONDecoder().decode(PluginBusMessage.self, from: data)) } } catch { connection.close() }
                } }
                connection.ended = { [weak self] in Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    self.local = nil; self.pending = [:]; self.openedMenus = []; self.catalog.reset(); self.runs = [:]; self.state = [:]; self.subscriptions = []
                    for context in self.slots.keys { self.refresh(context) }
                } }
                connection.start(); publish(.init(.discover)); wire(.init(deckEvent: "reset")); for device in devices.values { wire(.init(deckEvent: "device", device: device)) }; for key in slots.keys { publishSlot(key) }
            }
        }
        for key in Array(pending.keys) where pending[key]!.expires < Date() { let value = pending.removeValue(forKey: key)!; wire(.init(deckEvent: "result", context: key, request: value.request, message: "Elgato has not confirmed this save. Refresh the key before trying again.")) }
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
        if slot.view.isMenu { refreshMenu(context, open: false); return }
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
    private func title(_ context: String, _ value: String) {
        let text = String(value.prefix(70))
        if slots[context]?.view.feedback != text { slots[context]?.view.feedback = text; publishSlot(context) }
        if slots[context]?.view.controller == "Encoder" { send(["event": "setFeedback", "context": context, "payload": ["title": slots[context]?.view.isMenu == true ? "Nero menu" : "NeroNook", "value": text]]) }
        else { send(["event": "setTitle", "context": context, "payload": ["title": text, "target": 0]]) }
    }
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
    private func wire(_ value: DeckWire) { if let data = value.encoded() { local?.send(data) } }
    private func publishSlot(_ context: String) { if let view = slots[context]?.view { wire(.init(deckEvent: "slot", slot: view)) } }
    private func recordDevice(_ id: String, _ info: [String: Any]) {
        guard id.count <= 200, devices.count < 16 || devices[id] != nil, let size = info["size"] as? [String: Int], let columns = size["columns"], let rows = size["rows"], columns > 0, columns <= 12, rows > 0, rows <= 8 else { return }
        let device = DeckDevice(id: id, name: String((info["name"] as? String ?? "Stream Deck").prefix(80)), columns: columns, rows: rows, type: info["type"] as? Int ?? 0)
        devices[id] = device; wire(.init(deckEvent: "device", device: device))
    }
    private func removeSlot(_ context: String) {
        for (id, key) in runs where key == context { publish(.init(.cancel, requestID: id)); runs[id] = nil }
        slots[context] = nil; pending[context] = nil; openedMenus.remove(context); menuIndex[context] = nil
        wire(.init(deckEvent: "remove", context: context)); syncSubscriptions()
    }
    private func refreshMenu(_ context: String, open: Bool) {
        let choices = DeckMapping.menuEntries(catalog.entries)
        let index = min(menuIndex[context] ?? 0, max(0, choices.count - 1)); menuIndex[context] = index
        title(context, choices.isEmpty ? "No allowed\nactions" : choices[index].action!.title)
        if open { if !choices.isEmpty { menuChoice[context] = choices[index] }; menuOpened[context] = Date(); wire(.init(deckEvent: "menu", context: context, selected: choices.isEmpty ? "" : choices[index].address.key)) }
    }
    private func runMenu(_ context: String, selected: String?) {
        guard local != nil, slots[context]?.view.isMenu == true, !runs.values.contains(context), runs.count < 32 else { return }
        let choices = DeckMapping.menuEntries(catalog.entries)
        guard let entry = selected.flatMap({ key in choices.first { $0.address.key == key } }) ?? (selected == nil ? menuChoice[context] : nil), choices.contains(entry) else { title(context, "Action\nunavailable"); return }
        let id = UUID(); runs[id] = context; openedMenus.remove(context)
        publish(.init(.invoke, requestID: id, address: entry.address, values: [:])); title(context, "Running…")
    }
    private func command(_ value: DeckWire) {
        guard value.deckEvent == "command", let context = value.context, let slot = slots[context], value.revision == slot.view.revision, let request = value.request else { wire(.init(deckEvent: "result", request: value.request, message: "The key changed or is no longer visible.")); return }
        do {
            switch value.command {
            case "save":
                guard pending[context] == nil, let settings = value.settings else { throw ModuleProblem("A save is already pending.") }
                try DeckMapping.validate(settings: settings, slot: slot.view, catalog: catalog.entries)
                // Only this Nero action instance is writable. Preserve unknown settings owned by this instance.
                var merged = slot.settings; for key in ["provider", "name", "arguments", "field", "label"] { merged[key] = settings[key] }
                pending[context] = (request, settings, Date().addingTimeInterval(10))
                send(["event": "setSettings", "context": context, "payload": merged]); send(["event": "getSettings", "context": context])
            case "test": receive(["event": "keyDown", "action": slot.action, "context": context, "payload": [:]])
            case "menu_close": openedMenus.remove(context); menuChoice[context] = nil
            case "menu_run": runMenu(context, selected: value.selected)
            default: throw ModuleProblem("Unknown deck operation.")
            }
        } catch { wire(.init(deckEvent: "result", context: context, request: request, message: error.localizedDescription)) }
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
