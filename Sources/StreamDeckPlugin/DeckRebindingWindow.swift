import AppKit
import SwiftUI
import NookPluginSDK

@MainActor extension ModuleApp {
    func showRebindingWindow() {
        if rebindWindow == nil {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 840, height: 680),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Reconnect saved keys"
            window.contentMinSize = .init(width: 680, height: 520)
            window.contentView = NSHostingView(rootView: DeckRebindingWindow(model: self).pluginThemed())
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            rebindWindow = window
        }
        rebindWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        submitRebinding("rebind_status", .init())
    }

    func canSubmitRebindingApply(reviewID: UUID?) -> Bool {
        guard let reviewID, rebinding?.reviewID == reviewID else { return false }
        return rebindPresentation.canApply(rebinding, peer: rebindPeerEpoch, catalog: catalog.entries)
    }

    func submitRebinding(_ command: String, _ body: DeckRebindingCommand) {
        if command == "rebind_apply", !canSubmitRebindingApply(reviewID: body.reviewID) {
            rebindFeedback = rebindPresentation.warning ?? "This review is no longer current. Review the keys again before Apply."
            notice = rebindFeedback
            return
        }
        guard let peer else { notice = "Open Elgato before reconnecting saved keys."; return }
        let request = UUID(), epoch = rebindPeerEpoch
        let wire = DeckWire(deckEvent: "command", command: command, request: request, rebindingCommand: body)
        guard let data = wire.encoded(), data.count <= 96 * 1024 else {
            notice = "This review is too large. Select fewer keys."
            return
        }
        let preparing = command == "rebind_prepare"
        if preparing {
            guard let target = body.target, let entry = catalog.entries.first(where: { $0.address == target && $0.action != nil }),
                  rebindPresentation.beginPrepare(request: request, peer: epoch, target: entry) else {
                rebindFeedback = rebindPresentation.warning ?? "The replacement action is unavailable. Read current actions and review the keys again."
                notice = rebindFeedback; return
            }
        }
        guard rebindRequests.begin(id: request, epoch: epoch, command: command) else {
            if preparing { rebindPresentation.abandonPrepare(request: request) }
            return
        }
        if !preparing { rebindPresentation.supersedePendingPrepare() }
        if command == "rebind_close" { rebindPresentation.closeReview() }
        if command == "rebind_apply", let id = body.reviewID { rebindPresentation.applySubmitted(reviewID: id) }
        rebindFeedback = ""
        rebindAckTask?.cancel()
        rebindAckTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.peer === peer, self.rebindPeerEpoch == epoch,
                  self.rebindRequests.timeout(id: request, epoch: epoch) else { return }
            self.rebindPresentation.supersedePendingPrepare()
            self.rebindFeedback = "The companion did not acknowledge this request. Its outcome is unconfirmed. Read current status before changing anything; no request was retried. Update the module and companion together if this persists."
            self.notice = self.rebindFeedback
        }
        peer.send(data)
    }

    func receiveRebinding(_ wire: DeckWire) {
        guard let value = wire.rebinding else { return }
        let acknowledged = rebindRequests.acknowledge(id: wire.request, epoch: rebindPeerEpoch)
        let progress = value.reviewID != nil && value.reviewID == rebinding?.reviewID
        guard acknowledged || progress else { return }
        rebindPresentation.receive(value, request: wire.request, peer: rebindPeerEpoch, acknowledged: acknowledged)
        if acknowledged { rebindAckTask?.cancel(); rebindAckTask = nil; rebindFeedback = "" }
        rebinding = value
        notice = String(value.message.prefix(300))
    }
}

extension ModuleApp: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === rebindWindow,
              let reviewID = rebinding?.reviewID else { return }
        // Closing the UI stops future writes. An already dispatched write still
        // needs its own readback and must never be described as rolled back.
        submitRebinding("rebind_close", .init(reviewID: reviewID))
    }
}

struct DeckRebindingWindow: View {
    @ObservedObject var model: ModuleApp
    @State private var sourceKey = ""
    @State private var targetKey = ""
    @State private var contexts = Set<String>()
    @State private var undoReceipt: UUID?

    private var sources: [PluginActionAddress] {
        Array(Set(model.slots.values.filter { !$0.isMenu && !$0.isStatus && $0.controller == "Keypad" }.map(\.address)))
            .sorted { $0.key < $1.key }
    }
    private var source: PluginActionAddress? { sources.first { $0.key == sourceKey } }
    private var targets: [PluginCatalogEntry] {
        model.catalog.entries.filter { $0.action != nil }.sorted { $0.address.key < $1.address.key }
    }
    private var target: PluginActionAddress? { targets.first { $0.address.key == targetKey }?.address }
    private var visible: [DeckSlot] {
        model.slots.values.filter { !$0.isMenu && !$0.isStatus && $0.controller == "Keypad" && $0.address == source }
            .sorted { ($0.device, $0.row, $0.column, $0.context) < ($1.device, $1.row, $1.column, $1.context) }
    }
    private var phase: String { model.rebinding?.phase.rawValue ?? "" }
    private var applying: Bool { phase == "applying" }
    private var reviewing: Bool { phase == "review" }
    private var configuring: Bool { model.rebinding == nil || phase == "closed" || phase == "rejected" }
    private var busy: Bool { model.rebindRequestPending || model.rebindRequests.uncertain || applying }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "arrow.triangle.branch").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reconnect saved keys").font(.title2.weight(.semibold))
                    Text("Review each change. No action will run.").pluginSecondaryText()
                }
                Spacer()
                Text(model.peer == nil ? "Offline" : "Elgato connected").pluginSecondaryText()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.rebindFeedback.isEmpty {
                        Text(model.rebindFeedback).textSelection(.enabled)
                    }
                    if let warning = model.rebindPresentation.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if configuring { configuration }
                    if let review = model.rebinding, phase != "closed" || !review.rows.isEmpty {
                        Text(review.message).textSelection(.enabled)
                        if let old = review.source, let new = review.target {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Current: \(old.plugin) / \(old.name)")
                                Text("Replacement: \(new.plugin) / \(new.name)")
                            }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if let action = review.newAction {
                            Text("\(action.title) · \(effect(action.effect)) · \(Int(action.timeoutSeconds))s request limit")
                            Text(action.input.fields.isEmpty ? "No input parameters." : "Inputs: " + action.input.fields.map {
                                "\($0.name) (\($0.kind.rawValue), \($0.required ? "required" : "optional"))"
                            }.joined(separator: ", ")).font(.caption).textSelection(.enabled)
                            if let limit = action.completionTimeoutSeconds {
                                Text("Completion limit: \(Int(limit))s").pluginSecondaryText()
                            }
                            DisclosureGroup("Complete replacement action contract") {
                                rawText(action)
                            }
                        }
                        if let old = review.oldAction {
                            DisclosureGroup("Available current-action contract") { rawText(old) }
                        } else if review.source != nil {
                            Text("The old action contract is unavailable. Matching titles do not establish equivalent behavior.")
                                .pluginSecondaryText()
                        }
                        ForEach(review.rows, id: \.id) { row in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.before["label"].flatMap { $0.isEmpty ? nil : $0 }
                                             ?? (row.action.hasSuffix(".stop") ? "Stop key" : "Run key")).font(.headline)
                                        Text("\(row.controller == "Encoder" ? "Dial" : "Key") \(row.row + 1), \(row.column + 1) · \(row.device)")
                                            .font(.caption).pluginSecondaryText()
                                    }
                                    Spacer()
                                    Text(outcome(row.outcome.rawValue)).font(.caption.weight(.medium))
                                }
                                if !row.message.isEmpty { Text(row.message).font(.callout).textSelection(.enabled) }
                                if let observed = row.observed, !observed.isEmpty {
                                    DisclosureGroup("Returned settings details") { rawText(observed) }
                                }
                                if let hash = row.observedSHA256 {
                                    Text("Returned complete-settings SHA-256: \(hash)")
                                        .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                                }
                                DisclosureGroup("Preserved arguments and settings details") {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text("Arguments").font(.caption.weight(.semibold))
                                        Text(row.before["arguments"] ?? "{}").font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        Text("\(row.unknownFieldCount) additional Elgato setting\(row.unknownFieldCount == 1 ? "" : "s") retained locally.").pluginSecondaryText()
                                        Text("Before: \(row.beforeSHA256)\nAfter: \(row.afterSHA256)")
                                            .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                                    }.padding(.top, 6)
                                }
                                if row.undoAvailable, let receipt = row.receiptID {
                                    Button("Restore this key’s previous settings…") {
                                        undoReceipt = receipt
                                    }.disabled(busy || model.peer == nil)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    Text("Only the selected, currently visible Nero Run and Stop keys are covered. Hidden pages, status keys and action menus are not changed. Permissions stay separate.")
                        .pluginSecondaryText()
                    Text("Changes are confirmed one key at a time. Elgato cannot make this an atomic transaction. Undo is conditional, retained only for this review in this companion session, and may restore an unavailable old target as an inactive assignment. A new review replaces these Undo receipts.")
                        .pluginSecondaryText()
                }
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text(model.rebindRequestPending ? "Waiting for companion…" : applying ? "Confirming settings…" : "Nothing is run by reconnecting keys.")
                    .font(.caption).pluginSecondaryText()
                Spacer()
                if model.rebindRequests.uncertain {
                    Button("Read current status") { model.submitRebinding("rebind_status", .init()) }
                        .disabled(model.rebindRequestPending || model.peer == nil)
                }
                if configuring {
                    Button("Review selected keys") {
                        guard let source, let target else { return }
                        model.submitRebinding("rebind_prepare", .init(contexts: contexts.sorted(), source: source, target: target))
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || model.peer == nil || !model.rebindPresentation.catalogReady || contexts.isEmpty || contexts.count > 16 || source == nil || target == nil)
                } else if let id = model.rebinding?.reviewID {
                    Button(applying ? "Stop reconnecting" : "Close review") {
                        model.submitRebinding("rebind_close", .init(reviewID: id))
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.peer == nil)
                    if reviewing {
                        Button("Apply reviewed changes") {
                            model.submitRebinding("rebind_apply", .init(reviewID: id))
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || model.peer == nil || !model.canSubmitRebindingApply(reviewID: id))
                    }
                }
            }
        }
        .padding(22)
        .onChange(of: sourceKey) { _ in contexts = [] }
        .confirmationDialog("Restore this key’s previous settings?", isPresented: Binding(
            get: { undoReceipt != nil }, set: { if !$0 { undoReceipt = nil } }), titleVisibility: .visible) {
            if let receipt = undoReceipt {
                Button("Restore previous settings") {
                    model.submitRebinding("rebind_undo", .init(receiptID: receipt))
                    undoReceipt = nil
                }
            }
            Button("Cancel", role: .cancel) { undoReceipt = nil }
        } message: {
            Text("Restores only the exact captured settings when the current key still matches this review’s result. An unavailable old action stays inactive. Completed actions are not undone.")
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Saved action", selection: $sourceKey) {
                Text("Choose the exact saved target").tag("")
                ForEach(sources, id: \.key) { address in
                    Text("\(address.plugin) / \(address.name)").tag(address.key)
                }
            }
            Picker("Replacement action", selection: $targetKey) {
                Text("Choose a currently permitted action").tag("")
                ForEach(targets, id: \.address.key) { entry in
                    Text("\(entry.action?.title ?? "Action") · \(entry.address.plugin) / \(entry.address.name)")
                        .tag(entry.address.key)
                }
            }
            if !visible.isEmpty {
                HStack {
                    Text("Select up to 16 visible keys").font(.headline)
                    Spacer()
                    Button("Select visible group") { contexts = Set(visible.map(\.context)) }
                        .disabled(visible.count > 16)
                    Button("Clear") { contexts = [] }
                }
                ForEach(visible, id: \.context) { slot in
                    Toggle(isOn: Binding(get: { contexts.contains(slot.context) }, set: { selected in
                        if selected { contexts.insert(slot.context) } else { contexts.remove(slot.context) }
                    })) {
                        Text("\(slot.isStop ? "Stop" : "Run") · \(slot.row + 1), \(slot.column + 1) · \(slot.settings["label"] ?? slot.device)")
                    }
                }
            } else {
                Text("Choose a saved target, or show its Nero keys on the Elgato page first.").pluginSecondaryText()
            }
            Text("Arguments, labels and other settings are preserved. Incompatible arguments or a Stop target that cannot be cancelled will refuse the review.")
                .pluginSecondaryText()
        }.disabled(model.rebindRequestPending || model.rebindRequests.uncertain || model.peer == nil)
    }

    private func outcome(_ raw: String) -> String {
        switch raw {
        case "pending", "notAttempted": return "Not changed"
        case "applying": return "Awaiting readback"
        case "confirmed": return "Confirmed"
        case "undone": return "Restored"
        case "unconfirmed": return "Check settings"
        default: return raw.capitalized
        }
    }

    private func effect(_ value: PluginRegisteredAction.Effect) -> String {
        switch value {
        case .readOnly: return "Read only"
        case .localChange: return "Changes this Mac"
        case .externalChange: return "Changes connected services or devices"
        }
    }

    private func rawText<T: Encodable>(_ value: T) -> some View {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "Unavailable"
        return Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }
}
