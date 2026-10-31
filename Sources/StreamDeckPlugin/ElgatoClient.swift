import AppKit
import Foundation
import NookPluginSDK

@MainActor final class ElgatoClient {
    private let scope: BridgeScope
    init(scope: BridgeScope) { self.scope = scope }
    private struct Slot { var action: String; var settings: [String: Any]; var view: DeckSlot }
    private var devices: [String: DeckDevice] = [:]
    private struct PendingSave {
        let request: UUID
        let settings: [String: String]
        let action: String
        let barrier: DeckMappingSaveBarrier
        var expires: Date
        var recordID: UUID? = nil
        var beforeData = Data()
        var afterData = Data()
        var sent = false
        var finishing = false
        var capturedSlot: DeckSlot? = nil
    }
    private var pending: [String: PendingSave] = [:]
    // Session-local quarantine: a missing acknowledgement is not a rollback.
    // Keep the old/new run barriers until this exact visible context supplies
    // fresh Elgato settings. Hidden profiles and companion restarts are not
    // covered by a durable reconciliation mechanism.
    private var unresolved: [String: PendingSave] = [:]
    private var menuChoice: [String: PluginCatalogEntry] = [:]
    private var menuOpened: [String: Date] = [:]
    private var menuIndex: [String: Int] = [:]
    private var openedMenus = Set<String>()
    private var socket: URLSessionWebSocketTask?
    private var local: LocalConnection?
    private var catalog = PluginCatalogAccumulator()
    private var catalogRevision = UUID()
    private var slots: [String: Slot] = [:]
    private var runs = DeckRuns()
    private var keyImages: [String: String] = [:]
    private var subscriptions = Set<PluginActionAddress>()
    private var state: [PluginActionAddress: ([String: PluginValue], Date)] = [:]
    private var timer: Timer?
    private var generation = UUID()
    private var sending = false
    private var outbound: [String] = []
    private var outboundBytes = 0
    private var submittedRuns = Set<UUID>()
    private lazy var recovery = DeckRecoveryCoordinator(environment: .init(
        snapshot: { [weak self] context in
            guard let slot = self?.slots[context] else { return nil }
            return .init(slot: slot.view, settings: slot.settings)
        }, generation: { [weak self] in guard let self, self.local != nil else { return nil }; return self.generation },
        readSettings: { [weak self] in self?.send(["event": "getSettings", "context": $0]) },
        emit: { [weak self] view, request in self?.wire(.init(deckEvent: "recovery", request: request, message: view.message, recovery: view)) }))
    private lazy var rebinding = DeckRebinding(environment: .init(
        snapshot: { [weak self] context in
            guard let slot = self?.slots[context] else { return nil }
            return .init(slot: slot.view, settings: slot.settings)
        },
        catalog: { [weak self] in self?.catalog.entries ?? [] },
        generation: { [weak self] in guard let self, self.local != nil else { return nil }; return self.generation },
        catalogGeneration: { [weak self] in self?.catalogRevision ?? UUID() },
        occupiedContexts: { [weak self] in guard let self else { return [] }; return Set(self.pending.keys).union(self.unresolved.keys) },
        overlapsSave: { [weak self] contexts, addresses in
            guard let self else { return true }
            return (Array(self.pending.values) + Array(self.unresolved.values)).contains {
                contexts.contains($0.barrier.context) || !$0.barrier.addresses.isDisjoint(with: addresses)
            }
        },
        hasUnsettledWork: { [weak self] contexts, addresses in
            guard let self else { return true }
            return self.runs.hasUnsettled(contexts: contexts, addresses: addresses)
                || contexts.contains { self.recovery.blocks(context: $0, addresses: addresses, coldSettingsOnly: true) }
        },
        readSettings: { [weak self] context in self?.send(["event": "getSettings", "context": context]) },
        writeSettings: { [weak self] context, settings in self?.send(["event": "setSettings", "context": context, "payload": settings]) },
        prepareWrite: { [weak self] capture, request, undo, completion in
            Task { @MainActor in
                guard let self else { completion(.failure(ModuleProblem("The companion ended."))); return }
                do { completion(.success(try await self.recovery.prepareSettings(capture: capture, request: request, undo: undo))) }
                catch { completion(.failure(error)) }
            }
        },
        finishWrite: { [weak self] id, outcome, completion in
            Task { @MainActor in
                guard let self else { completion(.failure(ModuleProblem("The companion ended."))); return }
                do { try await self.recovery.finishSettings(id, outcome); completion(.success(())) }
                catch { completion(.failure(error)) }
            }
        },
        quarantine: { [weak self] capture, request in
            guard let self else { return }
            self.unresolved[capture.slot.context] = .init(request: request, settings: capture.row.after,
                action: capture.slot.action, barrier: .init(context: capture.slot.context,
                    oldAddress: capture.source, newAddress: capture.target), expires: Date(),
                recordID: self.recovery.settingsID(capture), beforeData: capture.beforeData,
                afterData: capture.afterData, sent: true, capturedSlot: capture.slot)
        },
        emit: { [weak self] value, request in
            self?.wire(.init(deckEvent: "rebinding", request: request, message: value.message, rebinding: value))
        }))
    func start() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.recovery.load(directory: DeckRecoveryCoordinator.directory(scope: self.scope))
            self.startConnections()
        }
    }
    private func startConnections() {
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
            } catch {
                self?.rebinding.disconnected("Elgato disconnected during the saved-key operation. Its current outcome needs review.")
                self?.endPendingSaves(message: "Elgato disconnected before confirming the save. Reload the original key's settings before making another change.", inspectorAvailable: false)
                NSApp.terminate(nil)
            }
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
        guard ["cafe.nero.neronook.run", "cafe.nero.neronook.status", "cafe.nero.neronook.menu", "cafe.nero.neronook.stop"].contains(action) else { return }
        if event == "sendToPlugin", payload["saveMapping"] as? Bool == true {
            guard let rawRequest = payload["request"] as? String, let request = UUID(uuidString: rawRequest) else { return }
            guard let revision = payload["revision"] as? String, let settings = payload["settings"] as? [String: String] else {
                mappingResult(context, action: action, request: request, outcome: "rejected", message: "The mapping request is incomplete. Reload this key before saving.")
                return
            }
            guard slots[context] != nil else {
                mappingResult(context, action: action, request: request, outcome: "conflict", message: "The key changed or is no longer visible.")
                return
            }
            command(.init(deckEvent: "command", context: context, command: "save", revision: revision, settings: settings, request: request))
            return
        }
        // A late settings callback must not resurrect a page/context that Elgato
        // has already hidden. Its pending save was classified unconfirmed.
        if event == "didReceiveSettings", slots[context] == nil { return }
        if event == "willAppear" || event == "didReceiveSettings" {
            guard slots.count < 128 || slots[context] != nil else { return }
            guard let settings = payload["settings"] as? [String: Any] else { return }
            let known = Set(["provider", "name", "arguments", "field", "label"])
            guard Set(settings.keys).intersection(known).allSatisfy({ settings[$0] is String }) else { return }
            let safe = settings.compactMapValues { $0 as? String }.filter { ["provider", "name", "arguments", "field", "label"].contains($0.key) }
            guard safe.values.allSatisfy({ $0.utf8.count <= 8192 }) else { return }
            let coordinate = payload["coordinates"] as? [String: Int] ?? [:]
            let old = slots[context]?.view
            let view = DeckSlot(context: context, action: action, device: message["device"] as? String ?? old?.device ?? "unknown", controller: payload["controller"] as? String ?? old?.controller ?? "Keypad", column: coordinate["column"] ?? old?.column ?? 0, row: coordinate["row"] ?? old?.row ?? 0, revision: UUID().uuidString, settings: safe)
            slots[context] = Slot(action: action, settings: settings, view: view)
            recovery.readback(slot: view, settings: settings)
            if let save = unresolved[context], !save.finishing { settleSave(context, save: save, observed: settings, unresolvedSave: true) }
            rebinding.readback(slot: view, settings: settings)
            if view.controller == "Encoder" { send(["event": "setFeedbackLayout", "context": context, "payload": ["layout": "$A1"]]) }
            if let save = pending[context], save.sent && !save.finishing { settleSave(context, save: save, observed: settings, unresolvedSave: false) }
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
            let address = address(slot)
            guard let entry = catalog.entries.first(where: { $0.address == address && $0.action != nil }) else { title(context, "Allow in\nNeroNook"); return }
            if slot.view.isStop {
                do {
                    guard entry.action?.cancellable == true else { throw ModuleProblem("Choose a cancellable action for Stop.") }
                    if let request = try runs.cancel(address) {
                        if submittedRuns.contains(request) {
                            // Stop stays available for this exact live-owned run
                            // even if the local ledger later becomes unwritable.
                            publish(.init(.cancel, requestID: request))
                            Task { @MainActor [weak self] in await self?.recovery.prepareCancel(request) }
                        }
                        wire(.init(deckEvent: "result", message: "Stop requested. Waiting for the original run's confirmed outcome."))
                    } else {
                        wire(.init(deckEvent: "result", message: runs.latest(address)?.active == true
                            ? "Stop was already requested. Still waiting for confirmation."
                            : "No active run for this key. Nothing was sent."))
                    }
                    refreshRuns()
                } catch { title(context, "Check Stop\nin Nook"); send(["event": "showAlert", "context": context]) }
                return
            }
            guard runs.latest(address)?.active != true else { refresh(context); return }
            guard allowNewRun(context: context, address: address) else { return }
            do {
                let text = slot.settings["arguments"] as? String ?? "{}"
                guard text.utf8.count <= 8192 else { throw ModuleProblem("Arguments too large") }
                let values = try JSONDecoder().decode([String: PluginValue].self, from: Data(text.utf8))
                try entry.action!.input.validate(values)
                try beginInvocation(context: context, entry: entry, values: values)
            } catch { title(context, "Check\narguments") }
        } else if event == "propertyInspectorDidAppear" || event == "sendToPlugin" {
            if event == "sendToPlugin", payload["refresh"] as? Bool == true, payload["readSettings"] as? Bool == true,
               slots[context] != nil { send(["event": "getSettings", "context": context]) }
            let refreshRequest = (payload["refreshRequest"] as? String).flatMap(UUID.init(uuidString:))
            sendCatalog(context, refreshRequest: refreshRequest)
        }
    }
    private func address(_ slot: Slot) -> PluginActionAddress {
        .init(slot.settings["provider"] as? String ?? moduleID, slot.settings["name"] as? String ?? (slot.action.hasSuffix(".status") ? "connection" : "check_connection"))
    }
    private func tick() {
        if local == nil {
            if let connection = try? LocalBridge.connect(scope: scope) {
                local = connection; let id = UUID(); generation = id
                connection.received = { [weak self] data in DispatchQueue.main.async {
                    guard let self, self.generation == id else { return }
                    do { if let command = try? JSONDecoder().decode(DeckWire.self, from: data) { self.command(command) } else { self.receiveBus(try JSONDecoder().decode(PluginBusMessage.self, from: data)) } } catch { connection.close() }
                } }
                connection.ended = { [weak self] in DispatchQueue.main.async {
                    guard let self, self.generation == id else { return }
                    self.rebinding.disconnected("NeroNook disconnected during the saved-key operation. No future changes will resume automatically.")
                    self.recovery.disconnected()
                    self.submittedRuns = []
                    self.local = nil
                    self.endPendingSaves(message: "NeroNook disconnected before confirming the save. Reload the original key's settings before making another change.")
                    self.openedMenus = []; self.catalog.reset(); self.runs.disconnected(); self.state = [:]; self.subscriptions = []
                    for context in self.slots.keys { self.refresh(context); self.sendCatalog(context) }
                } }
                connection.start(); publish(.init(.discover)); publishInventory()
                // Read only. Reconnecting does not clear uncertainty, replay a
                // save or infer that a hidden key/profile has been reconciled.
                for context in unresolved.keys.sorted() where slots[context] != nil {
                    send(["event": "getSettings", "context": context])
                }
            }
        }
        for key in Array(pending.keys) where pending[key]!.expires < Date() {
            let value = pending.removeValue(forKey: key)!
            unresolved[key] = value
            retainUncertainSave(value)
            mappingResult(key, action: value.action, request: value.request, outcome: "unconfirmed",
                message: "Elgato has not confirmed this save. Reload the original key's settings before trying again; new runs from affected keys remain blocked.")
            sendCatalog(key)
        }
        rebinding.tick()
        recovery.tick()
        for (context, slot) in slots where slot.action.hasSuffix(".status") || slot.view.isStop || runs.latest(address(slot)) != nil || runs.latest(context: context)?.active == true || local == nil { refresh(context) }
    }
    private func receiveBus(_ message: PluginBusMessage) {
        if message.operation == .catalog {
            do { if try catalog.receive(message) {
                catalogRevision = UUID()
                state = state.filter { address, _ in catalog.entries.contains { $0.address == address && $0.channel != nil } }
                syncSubscriptions(); for context in slots.keys { refresh(context); sendCatalog(context) }
            } } catch { catalog.reset(); state = [:]; subscriptions = [] }
        } else if message.operation == .update || message.operation == .failure {
            guard runs.receive(message) else { return }
            if let run = runs.records.first(where: { $0.id == message.requestID }), !run.active {
                submittedRuns.remove(run.id)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.recovery.finishRun(run.id, phase: run.update.phase)
                    // Terminal UI and durable receipt completion are separate.
                    // Publish readiness only after the ledger/cache join returns.
                    self.sendRecoveryReadiness()
                }
            }
            refreshRuns()
            if let run = runs.records.first(where: { $0.id == message.requestID }), slots[run.context] != nil {
                if run.update.phase == .succeeded { send(["event": "showOk", "context": run.context]) }
                else if [.failed, .interrupted].contains(run.update.phase) { send(["event": "showAlert", "context": run.context]) }
            }
        } else if message.operation == .event, let address = message.address, let values = message.values, let ttl = message.lifetime {
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
        guard local != nil else { title(context, runs.latest(address(slot))?.update.phase == .interrupted ? "Nook offline\nCheck outcome" : "NeroNook\nOffline"); return }
        if slot.view.isMenu, openedMenus.contains(context) { refreshMenu(context, open: false); return }
        let target = address(slot)
        if let run = slot.view.isMenu ? runs.latest(context: context) : runs.latest(target) { render(context, run: run); return }
        if slot.view.isStop { title(context, catalog.entries.contains(where: { $0.address == target && $0.action?.cancellable == true }) ? "Stop\nNo active run" : "Choose Stop\nassignment"); image(context, stop: true, phase: nil, review: false, progress: nil, frame: 0); return }
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
    private func refreshRuns() { for context in slots.keys { refresh(context) } }
    private func render(_ context: String, run: DeckRuns.Run) {
        guard let slot = slots[context] else { return }
        let now = Date(), display = run.update.display
        let label = slot.view.settings["label"].flatMap { $0.isEmpty ? nil : $0 } ?? display?.title ?? run.action.title
        let short = String(label.prefix(12))
        let steps = display.flatMap { $0.totalSteps > 0 ? "\($0.completedSteps)/\($0.totalSteps) · " : nil } ?? ""
        let status = run.status == "Review in Nook" ? "Review" : run.status == "Check outcome" ? "Unknown" : run.status
        title(context, short + "\n" + status + "\n" + steps + run.elapsed(now))
        let progress = display.flatMap { $0.totalSteps > 0 ? Double($0.completedSteps) / Double($0.totalSteps) : nil } ?? run.update.progress
        image(context, stop: slot.view.isStop, phase: run.update.phase, review: run.update.phase == .waitingReview || display?.needsReview == true, progress: progress, frame: Int(now.timeIntervalSince1970))
    }
    private func image(_ context: String, stop: Bool, phase: PluginRunPhase?, review: Bool, progress: Double?, frame: Int) {
        guard slots[context]?.view.controller != "Encoder" else { return }
        let key = "\(stop)-\(phase?.rawValue ?? "idle")-\(review)-\(progress ?? -1)-\(progress == nil && [.running, .cancelling].contains(phase) ? frame % 12 : 0)"
        guard keyImages[context] != key else { return }; keyImages[context] = key
        send(["event": "setImage", "context": context, "payload": ["image": DeckKeyImage.data(stop: stop, phase: phase, review: review, progress: progress, frame: frame), "target": 0]])
    }
    private func title(_ context: String, _ value: String) {
        let text = String(value.prefix(70))
        if slots[context]?.view.feedback != text { slots[context]?.view.feedback = text; publishSlot(context) }
        if slots[context]?.view.controller == "Encoder" { send(["event": "setFeedback", "context": context, "payload": ["title": slots[context]?.view.isMenu == true ? "Nero menu" : "NeroNook", "value": text]]) }
        else { send(["event": "setTitle", "context": context, "payload": ["title": text, "target": 0]]) }
    }
    private func sendCatalog(_ context: String, refreshRequest: UUID? = nil) {
        guard let slot = slots[context] else { return }
        let generation = UUID().uuidString
        send(["event": "sendToPropertyInspector", "action": slot.action, "context": context, "payload": ["catalogGeneration": generation, "catalog": [], "online": local != nil]])
        // Preserve framing bounds even when many other modules export actions.
        for entry in catalog.entries {
            guard let data = try? JSONEncoder().encode(entry), let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            send(["event": "sendToPropertyInspector", "action": slot.action, "context": context, "payload": ["catalogGeneration": generation, "catalog": [object]]])
        }
        var payload: [String: Any] = ["catalogGeneration": generation, "complete": true, "online": local != nil,
                "revision": slot.view.revision, "settings": slot.view.settings,
                "savePending": pending[context] != nil, "saveUnresolved": unresolved[context] != nil,
                "recoveryBlocked": recovery.blocks(context: context, addresses: [address(slot)])]
        if let refreshRequest { payload["refreshRequest"] = refreshRequest.uuidString }
        send(["event": "sendToPropertyInspector", "action": slot.action, "context": context, "payload": payload])
    }
    private func sendRecoveryReadiness() {
        // One small metadata frame per visible control. Re-sending every full
        // catalog after each receipt could overflow the bounded output queue.
        for (context, slot) in slots {
            send(["event": "sendToPropertyInspector", "action": slot.action, "context": context,
                  "payload": ["recoveryReadiness": true,
                              "recoveryBlocked": recovery.blocks(context: context, addresses: [address(slot)])]])
        }
    }
    private func wire(_ value: DeckWire) { if let data = value.encoded() { local?.send(data) } }
    private func publishInventory() {
        wire(.init(deckEvent: "reset"))
        for device in devices.values.sorted(by: { $0.id < $1.id }) { wire(.init(deckEvent: "device", device: device)) }
        for key in slots.keys.sorted() { publishSlot(key) }
    }
    private func publishSlot(_ context: String) { if let view = slots[context]?.view { wire(.init(deckEvent: "slot", slot: view)) } }
    private func recordDevice(_ id: String, _ info: [String: Any]) {
        guard id.count <= 200, devices.count < 16 || devices[id] != nil, let size = info["size"] as? [String: Int], let columns = size["columns"], let rows = size["rows"], columns > 0, columns <= 12, rows > 0, rows <= 8 else { return }
        let device = DeckDevice(id: id, name: String((info["name"] as? String ?? "Stream Deck").prefix(80)), columns: columns, rows: rows, type: info["type"] as? Int ?? 0)
        devices[id] = device; wire(.init(deckEvent: "device", device: device))
    }
    private func removeSlot(_ context: String) {
        // Page changes and hardware disconnects hide presentation, not the job.
        // Keep its exact request so a matching key on another page can Stop it.
        rebinding.disappeared(context)
        if let save = pending.removeValue(forKey: context) {
            unresolved[context] = save
            retainUncertainSave(save)
            mappingResult(context, action: save.action, request: save.request, outcome: "unconfirmed",
                message: "The key disappeared before confirming the save. Show this key in Elgato and reload its settings; new runs from affected keys remain blocked.")
        }
        slots[context] = nil; openedMenus.remove(context); menuIndex[context] = nil
        keyImages[context] = nil
        wire(.init(deckEvent: "remove", context: context)); syncSubscriptions()
    }
    private func refreshMenu(_ context: String, open: Bool) {
        let choices = DeckMapping.menuEntries(catalog.entries)
        let index = min(menuIndex[context] ?? 0, max(0, choices.count - 1)); menuIndex[context] = index
        title(context, choices.isEmpty ? "No allowed\nactions" : choices[index].action!.title)
        if open { if !choices.isEmpty { menuChoice[context] = choices[index] }; menuOpened[context] = Date(); wire(.init(deckEvent: "menu", context: context, selected: choices.isEmpty ? "" : choices[index].address.key)) }
    }
    private func runMenu(_ context: String, selected: String?) {
        guard local != nil, slots[context]?.view.isMenu == true, runs.latest(context: context)?.active != true else { return }
        let choices = DeckMapping.menuEntries(catalog.entries)
        guard let entry = selected.flatMap({ key in choices.first { $0.address.key == key } }) ?? (selected == nil ? menuChoice[context] : nil), choices.contains(entry) else { title(context, "Action\nunavailable"); return }
        guard allowNewRun(context: context, address: entry.address) else { return }
        do { try beginInvocation(context: context, entry: entry, values: [:]); closeMenu(context) }
        catch { title(context, "Check\naction") }
    }
    private func closeMenu(_ context: String) {
        openedMenus.remove(context); menuChoice[context] = nil; menuOpened[context] = nil
        wire(.init(deckEvent: "menuClosed", context: context))
    }
    private func command(_ value: DeckWire) {
        if value.deckEvent == "command", let name = value.command, name.hasPrefix("recovery_") {
            recovery.handle(name, payload: value.recoveryCommand ?? .init(), request: value.request)
            return
        }
        if value.deckEvent == "command", let name = value.command, name.hasPrefix("rebind_") {
            rebinding.handle(name, payload: value.rebindingCommand ?? .init(), request: value.request)
            return
        }
        if value.deckEvent == "command", value.command == "refresh", value.context == nil, value.request != nil {
            publishInventory()
            // Readback only: never run an assignment or change its settings.
            for context in slots.keys.sorted() { send(["event": "getSettings", "context": context]) }
            wire(.init(deckEvent: "result", request: value.request, message: "Deck refreshed · \(devices.count) device(s), \(slots.count) Nero assignment(s)."))
            return
        }
        guard value.deckEvent == "command", let context = value.context, let slot = slots[context], value.revision == slot.view.revision, let request = value.request else {
            if value.command == "save", let context = value.context, let request = value.request {
                mappingResult(context, action: slots[context]?.action, request: request, outcome: "conflict",
                    message: "The key changed or is no longer visible. Reload it before saving.", revision: slots[context]?.view.revision)
            } else { wire(.init(deckEvent: "result", request: value.request, message: "The key changed or is no longer visible.")) }
            return
        }
        do {
            switch value.command {
            case "save":
                guard recovery.ready else { throw ModuleProblem(recovery.problem) }
                guard pending[context] == nil, let settings = value.settings else { throw ModuleProblem("A save is already pending.") }
                guard unresolved[context] == nil else {
                    throw ModuleProblem("This mapping's outcome is unconfirmed. Reload this key's current Elgato settings before saving again; new runs from affected keys remain blocked.")
                }
                try DeckMapping.validate(settings: settings, slot: slot.view, catalog: catalog.entries)
                let nextAddress = PluginActionAddress(settings["provider"] ?? moduleID,
                    settings["name"] ?? (slot.view.isStatus ? "connection" : "check_connection"))
                let barrier = DeckMappingSaveBarrier(context: context, oldAddress: address(slot), newAddress: nextAddress)
                guard !runs.hasActive(context: context, addresses: barrier.addresses) else {
                    throw ModuleProblem("An affected Run or Stop assignment has active work. Keep its mapping until the original outcome is confirmed.")
                }
                guard !recovery.blocks(context: context, addresses: barrier.addresses) else {
                    throw ModuleProblem("A saved outcome needs review. Open Recovery & pending outcomes before changing this key.")
                }
                guard !rebinding.blocks(context: context, address: barrier.oldAddress),
                      !rebinding.blocks(context: context, address: barrier.newAddress) else {
                    throw ModuleProblem("A saved-key transition reserves this key or action. Wait for its outcome before saving another mapping.")
                }
                let occupied = Set(pending.keys).union(unresolved.keys).union(rebinding.reservedContexts)
                guard DeckRebindingLimits.admits(existing: occupied, adding: [context]) else {
                    throw ModuleProblem("The 128-context pending/unconfirmed limit is full. Reload existing keys; no older barrier was removed.")
                }
                // Only this Nero action instance is writable. Preserve unknown settings owned by this instance.
                var merged = slot.settings; for key in ["provider", "name", "arguments", "field", "label"] { merged[key] = settings[key] }
                try DeckRebindingJSON.validateWriteEnvelope(merged, context: context)
                let before = try DeckRebindingJSON.canonical(slot.settings), after = try DeckRebindingJSON.canonical(merged)
                pending[context] = .init(request: request, settings: settings, action: slot.action, barrier: barrier,
                    expires: Date().addingTimeInterval(30), beforeData: before, afterData: after)
                prepareSave(context, captured: slot, merged: merged, request: request)
                sendCatalog(context)
            case "test": receive(["event": "keyDown", "action": slot.action, "context": context, "payload": [:]])
            case "menu_close": closeMenu(context)
            case "menu_run": runMenu(context, selected: value.selected)
            default: throw ModuleProblem("Unknown deck operation.")
            }
        } catch {
            if value.command == "save" {
                mappingResult(context, action: slot.action, request: request, outcome: "rejected",
                    message: error.localizedDescription, revision: slot.view.revision)
                sendCatalog(context)
            } else { wire(.init(deckEvent: "result", context: context, request: request, message: error.localizedDescription)) }
        }
    }

    private func allowNewRun(context: String, address: PluginActionAddress) -> Bool {
        if rebinding.blocks(context: context, address: address) {
            title(context, "Updating\nkeys")
            wire(.init(deckEvent: "result", context: context,
                message: "A saved-key transition reserves this key or action. No new action was started; Stop remains available."))
            return false
        }
        if unresolved.values.contains(where: { $0.barrier.blocksRun(context: context, address: address) }) {
            title(context, "Reload\nmapping")
            wire(.init(deckEvent: "result", context: context,
                message: "A mapping change is unconfirmed. Show the affected key in Elgato and reload its settings before starting this action."))
            return false
        }
        if pending.values.contains(where: { $0.barrier.blocksRun(context: context, address: address) }) {
            title(context, "Saving\nmapping")
            wire(.init(deckEvent: "result", context: context,
                message: "Waiting for Elgato to confirm an affected mapping. No new action was started."))
            return false
        }
        if recovery.blocksRun(context: context, address: address) {
            title(context, "Review\noutcome")
            wire(.init(deckEvent: "result", context: context,
                message: recovery.ready ? "A saved mapping or old run needs review. Open Recovery & pending outcomes; nothing was replayed." : recovery.problem))
            return false
        }
        return true
    }

    private func prepareSave(_ context: String, captured: Slot, merged: [String: Any], request: UUID) {
        let owner = generation, catalogOwner = catalogRevision
        Task { @MainActor [weak self] in
            guard let self, let preparing = self.pending[context], preparing.request == request else { return }
            var recordID: UUID?
            do {
                let id = try await self.recovery.prepareSettings(slot: captured.view, before: preparing.beforeData,
                    after: preparing.afterData, oldAddress: preparing.barrier.oldAddress,
                    newAddress: preparing.barrier.newAddress, request: request, kind: .save)
                recordID = id
                guard var current = self.pending[context], current.request == request,
                      !current.sent, !current.finishing, self.local != nil, self.generation == owner,
                      self.catalogRevision == catalogOwner,
                      let visible = self.slots[context], visible.view.revision == captured.view.revision,
                      DeckRecoveryCoordinator.sameVisibleKey(visible.view, captured.view),
                      try DeckRebindingJSON.canonical(visible.settings) == preparing.beforeData,
                      !self.runs.hasActive(context: context, addresses: preparing.barrier.addresses),
                      !self.rebinding.blocks(context: context, address: preparing.barrier.oldAddress),
                      !self.rebinding.blocks(context: context, address: preparing.barrier.newAddress) else {
                    try await self.recovery.finishSettings(id, .notSent)
                    if self.pending[context]?.request == request { self.pending[context] = nil }
                    if self.unresolved[context]?.request == request { self.unresolved[context] = nil }
                    self.mappingResult(context, action: captured.action, request: request, outcome: "conflict",
                        message: "The key or connection changed before dispatch. No settings write was sent.")
                    return
                }
                try DeckMapping.validate(settings: current.settings, slot: visible.view, catalog: self.catalog.entries)
                current.recordID = id; current.sent = true; current.capturedSlot = captured.view
                current.expires = Date().addingTimeInterval(10)
                self.pending[context] = current
                self.send(["event": "setSettings", "context": context, "payload": merged])
                self.send(["event": "getSettings", "context": context])
            } catch {
                if let id = recordID { try? await self.recovery.finishSettings(id, .notSent) }
                if self.pending[context]?.request == request { self.pending[context] = nil }
                self.mappingResult(context, action: captured.action, request: request, outcome: "rejected",
                    message: "The save was not dispatched. Check saved-outcome storage and review this key again.")
            }
            self.sendRecoveryReadiness()
            self.sendCatalog(context)
        }
    }

    private func settleSave(_ context: String, save: PendingSave, observed: [String: Any], unresolvedSave: Bool) {
        guard save.sent, let id = save.recordID, let captured = save.capturedSlot,
              let slot = slots[context]?.view, DeckRecoveryCoordinator.sameVisibleKey(captured, slot),
              let data = try? DeckRebindingJSON.canonical(observed) else { return }
        var held = save; held.finishing = true
        if unresolvedSave { unresolved[context] = held } else { pending[context] = held }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let matches = data == save.afterData
                try await self.recovery.finishSettings(id, matches ? .confirmed(observedData: data) : .conflict(observedData: data))
                if self.pending[context]?.request == save.request { self.pending[context] = nil }
                if self.unresolved[context]?.request == save.request { self.unresolved[context] = nil }
                let stillCurrent = self.slots[context].map {
                    DeckRecoveryCoordinator.sameVisibleKey($0.view, slot)
                        && (try? DeckRebindingJSON.canonical($0.settings)) == data
                } == true
                if unresolvedSave {
                    self.wire(.init(deckEvent: "result", context: context,
                        message: stillCurrent ? "Current Elgato settings read back. Mapping controls are available again; reading settings did not start an action." : "An earlier settings observation was saved. Reload this key's later current edit; nothing was replayed."))
                } else {
                    self.mappingResult(context, action: save.action, request: save.request,
                        outcome: matches && stillCurrent ? "confirmed" : "conflict",
                        message: !stillCurrent ? "An earlier settings observation was saved, but this key changed meanwhile. Keep the current edit and reload; no retry or rollback was sent." : matches ? "Mapping saved in Elgato · readback confirmed · local receipt saved" : "Elgato returned different settings. The observed settings were preserved; no retry or rollback was sent.",
                        revision: stillCurrent ? slot.revision : nil)
                }
            } catch {
                var unknown = held; unknown.finishing = false
                if self.pending[context]?.request == save.request { self.pending[context] = nil }
                self.unresolved[context] = unknown
                if unresolvedSave {
                    self.wire(.init(deckEvent: "result", context: context,
                        message: "The write's receipt could not be saved. New affected actions remain blocked; nothing was retried."))
                } else {
                    self.mappingResult(context, action: save.action, request: save.request, outcome: "unconfirmed",
                        message: "The write's receipt could not be saved. New affected actions remain blocked; nothing was retried.")
                }
            }
            self.sendRecoveryReadiness()
            self.sendCatalog(context)
        }
    }

    private func beginInvocation(context: String, entry: PluginCatalogEntry, values: [String: PluginValue]) throws {
        guard let captured = slots[context], allowNewRun(context: context, address: entry.address) else { return }
        let id = try runs.begin(context: context, entry: entry), owner = generation, catalogOwner = catalogRevision
        refreshRuns()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.recovery.prepareRun(id: id, slot: captured.view, entry: entry)
                guard let run = self.runs.records.first(where: { $0.id == id }), run.active, !run.cancelSent,
                      self.local != nil, self.generation == owner, self.catalogRevision == catalogOwner,
                      let slot = self.slots[context], slot.view.revision == captured.view.revision,
                      DeckRecoveryCoordinator.sameVisibleKey(slot.view, captured.view),
                      self.catalog.entries.contains(entry),
                      !self.recovery.blocksRun(context: context, address: entry.address, except: id),
                      !self.rebinding.blocks(context: context, address: entry.address),
                      !(Array(self.pending.values) + Array(self.unresolved.values)).contains(where: { $0.barrier.blocksRun(context: context, address: entry.address) }) else {
                    let phase: PluginRunPhase = self.runs.records.first(where: { $0.id == id })?.cancelSent == true ? .cancelled : .failed
                    _ = self.runs.receive(.init(.update, requestID: id, address: entry.address,
                        update: .init(phase, message: "No action submitted: the key, connection or review changed before dispatch.")))
                    await self.recovery.finishRun(id, phase: phase); self.refreshRuns(); return
                }
                self.submittedRuns.insert(id)
                self.publish(.init(.invoke, requestID: id, address: entry.address, values: values))
            } catch {
                _ = self.runs.receive(.init(.update, requestID: id, address: entry.address,
                    update: .init(.failed, message: "No action submitted: the local intent could not be saved.")))
                self.title(context, "Check\nstorage")
            }
            self.refreshRuns()
        }
    }
    private func mappingResult(_ context: String, action: String?, request: UUID, outcome: String, message: String,
                               revision: String? = nil, inspectorAvailable: Bool = true) {
        wire(.init(deckEvent: "result", context: context, request: request, message: message))
        guard inspectorAvailable, let action else { return }
        var result: [String: Any] = ["request": request.uuidString, "outcome": outcome, "message": message]
        if let revision { result["revision"] = revision }
        send(["event": "sendToPropertyInspector", "action": action, "context": context, "payload": ["mappingResult": result]])
    }
    private func endPendingSaves(message: String, inspectorAvailable: Bool = true) {
        let saves = pending; pending = [:]
        for (context, save) in saves {
            unresolved[context] = save
            retainUncertainSave(save)
            mappingResult(context, action: save.action, request: save.request, outcome: "unconfirmed",
                message: message + " New runs from affected keys stay blocked until fresh settings are read back.", inspectorAvailable: inspectorAvailable)
        }
    }

    private func retainUncertainSave(_ save: PendingSave) {
        guard save.sent, !save.finishing, let id = save.recordID else { return }
        Task { @MainActor [weak self] in try? await self?.recovery.finishSettings(id, .uncertain) }
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
                catch {
                    self.outbound = []; self.outboundBytes = 0
                    self.rebinding.disconnected("Elgato disconnected during the saved-key operation. Its current outcome needs review.")
                    self.endPendingSaves(message: "Elgato disconnected before confirming the save. Reload the original key's settings before making another change.", inspectorAvailable: false)
                    NSApp.terminate(nil); break
                }
            }
            self.sending = false
        }
    }
}
