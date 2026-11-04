import Foundation
import NookPluginSDK

struct DeckDevice: Codable, Equatable {
    var id: String; var name: String; var columns: Int; var rows: Int; var type: Int
}
struct DeckSlot: Codable, Equatable {
    var context: String; var action: String; var device: String; var controller: String
    var column: Int; var row: Int; var revision: String
    var settings: [String: String]; var feedback: String = ""
    var isMenu: Bool { action.hasSuffix(".menu") }
    var isStatus: Bool { action.hasSuffix(".status") }
    var isStop: Bool { action.hasSuffix(".stop") }
    var address: PluginActionAddress { .init(settings["provider"] ?? moduleID, settings["name"] ?? (isStatus ? "connection" : "check_connection")) }
}
enum DeckMapping {
    static func validate(settings: [String: String], slot: DeckSlot, catalog: [PluginCatalogEntry]) throws {
        guard settings.count <= 5, Set(settings.keys).isSubset(of: ["provider", "name", "arguments", "field", "label"]), settings.values.allSatisfy({ $0.utf8.count <= 8192 }) else { throw ModuleProblem("Mapping is too large or contains unknown fields.") }
        let address = PluginActionAddress(settings["provider"] ?? moduleID, settings["name"] ?? (slot.isStatus ? "connection" : "check_connection"))
        guard let entry = catalog.first(where: { $0.address == address }) else { throw ModuleProblem("This action is no longer permitted. Refresh the action list.") }
        guard (settings["label"]?.count ?? 0) <= 32 else { throw ModuleProblem("Keep the key label to 32 characters.") }
        if slot.isStop {
            guard entry.action?.cancellable == true, (settings["arguments"] ?? "{}") == "{}" else { throw ModuleProblem("Choose a cancellable action for Stop. Stop uses the original run, not new arguments.") }
        } else if slot.isStatus {
            guard let channel = entry.channel, channel.kind == .state, channel.schema.fields.contains(where: { $0.name == (settings["field"] ?? "message") }) else { throw ModuleProblem("Choose a field from this live status.") }
        } else {
            guard let action = entry.action else { throw ModuleProblem("Choose an action.") }
            let values = try JSONDecoder().decode([String: PluginValue].self, from: Data((settings["arguments"] ?? "{}").utf8))
            try action.input.validate(values)
        }
    }
    static func menuEntries(_ catalog: [PluginCatalogEntry]) -> [PluginCatalogEntry] {
        catalog.filter { $0.action != nil && (try? $0.action!.input.validate([:])) != nil }.sorted { ($0.action?.title ?? "") < ($1.action?.title ?? "") }
    }
}

import SwiftUI
import AppKit

@MainActor extension ModuleApp {
    func receiveDeck(_ wire: DeckWire) {
        switch wire.deckEvent {
        case "reset": devices = [:]; slots = [:]; menuContext = ""; notice = ""
        case "device": if let d = wire.device, d.id.count <= 200, d.columns > 0, d.columns <= 12, d.rows > 0, d.rows <= 8, devices.count < 16 || devices[d.id] != nil { devices[d.id] = d; if devices[selectedDevice] == nil { selectedDevice = d.id } }
        case "removeDevice": if let id = wire.context { devices[id] = nil; slots = slots.filter { $0.value.device != id }; if devices[selectedDevice] == nil { selectedDevice = devices.keys.sorted().first ?? "" } }
        case "slot": if let s = wire.slot, s.context.count <= 200, s.settings.values.allSatisfy({ $0.utf8.count <= 8192 }), slots.count < 128 || slots[s.context] != nil { slots[s.context] = s }
        case "remove": if let c = wire.context { slots[c] = nil; if menuContext == c { menuContext = "" } }
        case "menu": if let c = wire.context, slots[c]?.isMenu == true { menuContext = c; menuSelected = wire.selected ?? ""; selectedSlot = c; selectedDevice = slots[c]!.device; tick(); if presentation { emit("present") } else { showWindow() } }
        case "menuClosed": if wire.context == menuContext { menuContext = ""; menuSelected = "" }
        case "result": notice = String((wire.message ?? "").prefix(300))
        case "rebinding":
            receiveRebinding(wire)
        case "recovery":
            receiveRecovery(wire)
        default: break
        }
        tick()
    }
    var surface: PluginCustomView {
        func json<T: Encodable>(_ value: T) -> String { (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "[]" }
        let selected = slots[selectedSlot]
        let keySlots = slots.values.filter { $0.device == selectedDevice }.sorted { ($0.row, $0.column, $0.context) < ($1.row, $1.column, $1.context) }.prefix(64).map { slot -> DeckSlot in var copy = slot; copy.settings = [:]; return copy }
        let entries = catalog.entries.filter { selected?.isStop == true ? $0.action?.cancellable == true : selected?.isStatus == true ? $0.channel?.kind == .state : $0.action != nil }.sorted { ($0.action?.title ?? $0.channel?.title ?? "") < ($1.action?.title ?? $1.channel?.title ?? "") }
        let choices = entries.prefix(80).map { ["key": $0.address.key, "title": $0.action?.title ?? $0.channel?.title ?? "", "kind": $0.action?.effect.rawValue ?? "status"] }
        var state: [String: PluginValue] = ["schema_revision": .number(Double(schemaRevision)), "online": .boolean(peer != nil), "devices": .string(json(Array(devices.values).sorted { $0.name < $1.name })), "slots": .string(json(Array(keySlots))), "device": .string(selectedDevice), "selected": .string(json(selected)), "choices": .string(json(choices)), "choice_total": .number(Double(entries.count)), "notice": .string(notice), "activity": .string(lastResult), "menu": .string(menuContext), "menu_selected": .string(menuSelected), "menu_choices": .string(json(DeckMapping.menuEntries(catalog.entries).prefix(80).map { ["key": $0.address.key, "title": $0.action!.title] }))]
        state["recovery_notice"] = .string(String((recovery?.message ?? "Read recovery and pending outcomes").prefix(300)))
        state["recovery_attention"] = .boolean(recovery?.phase == .rejected || recovery?.records.contains(where: { $0.unresolved }) == true)
        // The selected schema is obtained separately so large catalogs do not crowd the view budget.
        if let entry = selectedSchema ?? entries.first(where: { $0.address == selected?.address }) { state["schema"] = .string(json(entry)) }
        for key in ["menu_choices", "choices", "slots", "devices"] {
            guard let data = try? JSONEncoder().encode(state), data.count > 30000 else { break }
            guard case .string(let raw) = state[key], var array = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [Any] else { continue }
            while !array.isEmpty, (try? JSONEncoder().encode(state).count) ?? 0 > 30000 {
                array.removeLast(); state[key] = .string(String(decoding: (try? JSONSerialization.data(withJSONObject: array)) ?? Data("[]".utf8), as: UTF8.self))
            }
            state["notice"] = .string("Some items were omitted to fit this view. Reduce the visible assignments or granted actions.")
        }
        return .init(entry: "deck/index.html", revision: "deck2", state: state, events: [
            .init("select", input: .init([.init("context", .string)])), .init("device", input: .init([.init("id", .string)])),
            .init("save", input: .init([.init("context", .string), .init("revision", .string), .init("settings", .string)])),
            .init("test", input: .init([.init("context", .string), .init("revision", .string)])),
            .init("schema", input: .init([.init("address", .string)])), .init("settings"), .init("open"), .init("refresh"), .init("reconnect"), .init("recovery"),
            .init("menu_run", input: .init([.init("address", .string)])), .init("menu_close")
        ])
    }
    func handleView(_ event: PluginViewEvent) throws {
        guard event.panelID == "deck" else { throw ModuleProblem("Unknown deck view.") }; try surface.validate(event)
        func text(_ key: String) -> String { if case .string(let s) = event.values[key] { return s }; return "" }
        switch event.name {
        case "refresh":
            guard let peer else { throw ModuleProblem("Open Elgato to reconnect your deck.") }
            peer.send(DeckWire(deckEvent: "command", command: "refresh", request: UUID()).encoded()!)
            notice = "Refreshing device and keys…"
        case "select": guard let s = slots[text("context")] else { throw ModuleProblem("That key is no longer visible in Elgato.") }; selectedSlot = s.context; selectedSchema = nil; notice = ""
        case "device": guard devices[text("id")] != nil else { return }; selectedDevice = text("id"); selectedSlot = ""; selectedSchema = nil
        case "schema":
            // Send the chosen schema without modifying the saved mapping.
            guard let entry = catalog.entries.first(where: { $0.address.key == text("address") }) else { throw ModuleProblem("This action is no longer available.") }
            selectedSchema = entry; schemaRevision += 1
        case "save", "test":
            guard peer != nil, let slot = slots[text("context")], slot.revision == text("revision") else { throw ModuleProblem("The key changed or disconnected. Select it again.") }
            var settings: [String: String]? = nil
            if event.name == "save" { settings = try JSONDecoder().decode([String: String].self, from: Data(text("settings").utf8)); try DeckMapping.validate(settings: settings!, slot: slot, catalog: catalog.entries) }
            let wire = DeckWire(deckEvent: "command", context: slot.context, command: event.name, revision: slot.revision, settings: settings, request: UUID())
            peer?.send(wire.encoded()!); notice = event.name == "save" ? "Waiting for Elgato to confirm the mapping…" : "Starting saved assignment…"
        case "open": showWindow()
        case "reconnect": showRebindingWindow()
        case "recovery": showRecoveryWindow()
        case "settings": showHelp = true; showWindow()
        case "menu_close":
            if let slot = slots[menuContext] { peer?.send(DeckWire(deckEvent: "command", context: slot.context, command: "menu_close", revision: slot.revision, request: UUID()).encoded()!) }
            menuContext = ""
        case "menu_run":
            guard let slot = slots[menuContext], slot.isMenu, DeckMapping.menuEntries(catalog.entries).contains(where: { $0.address.key == text("address") }) else { throw ModuleProblem("This menu action is unavailable.") }
            peer?.send(DeckWire(deckEvent: "command", context: slot.context, command: "menu_run", revision: slot.revision, request: UUID(), selected: text("address")).encoded()!); menuContext = ""
        default: break
        }
        tick()
    }
}
struct DeckWindow: View {
    @ObservedObject var model: ModuleApp
    var body: some View {
        PluginWebSurface(root: Bundle.main.resourceURL!.appendingPathComponent("Views"), panelID: "deck", definition: model.surface) { event in do { try model.handleView(event) } catch { model.notice = error.localizedDescription } }
            .sheet(isPresented: $model.showHelp) {
                PluginSettingsPage("Stream Deck", subtitle: "Bring Nero actions, status and menus to your keys and dials.", symbol: "square.grid.3x3", width: 650, height: 600, done: { model.showHelp = false }) {
                PluginSettingsSection("Set up your keys") {
                Text("Elgato keeps your devices and profiles. Add Run Action, Show Status or Action Menu from NeroNook to an empty key or supported dial in Elgato. Then select that key here to edit its Nero mapping.")
                Button("Open Elgato") { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Elgato Stream Deck.app"), configuration: .init()) }
                Text(model.connection).pluginSecondaryText()
                Button("Reconnect saved keys…") { model.showRebindingWindow() }
                Button("Recovery & pending outcomes…") { model.showRecoveryWindow() }
                Text("Read durable settings and execution evidence after a restart. An old run cannot be resumed or cleared here.").pluginSecondaryText()
                Text("Review visible Nero Run and Stop keys before choosing a replacement action. Saving never runs the action or transfers its permissions.").pluginSecondaryText()
                }
                PluginSettingsSection("Permissions") {
                    Text("Allow individual actions in NeroNook Settings → Modules. Changes still require review in NeroNook. Saving a mapping does not run it.").font(.callout).pluginSecondaryText()
                }
                PluginAdvancedSection(detail: "How the companion works with Elgato profiles and action menus.") {
                Text("Only NeroNook assignments on the currently visible Elgato page appear here. Other keys are left to Elgato. Action Menu opens this module in NeroNook; turn a dial to choose, then press to run. Actions with required inputs use an individually configured Run Action key.")
                }
            } }
    }
}
