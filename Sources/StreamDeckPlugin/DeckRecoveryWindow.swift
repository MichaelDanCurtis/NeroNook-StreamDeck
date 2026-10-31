import AppKit
import SwiftUI
import NookPluginSDK

@MainActor extension ModuleApp {
    func showRecoveryWindow() {
        if recoveryWindowController == nil { recoveryWindowController = DeckRecoveryWindowController(model: self) }
        recoveryWindowController?.showWindow(nil)
        recoveryWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        submitRecovery("recovery_status", .init(offset: recoveryPresentation.page?.offset ?? 0))
    }
    func submitRecovery(_ command: String, _ body: DeckRecoveryCommand) {
        guard let peer else { recoveryFeedback = "Open Elgato to read recovery information. Last information is historical."; return }
        if command == "recovery_prepare" {
            guard recoveryPresentation.allowsSettingsReview(id: body.recordID),
                  let context = body.context, let slot = slots[context], slot.revision == body.revision else {
                recoveryFeedback = "Select a saved settings record and a currently visible key. Historical contexts are not placement proof."; return
            }
        }
        if command == "recovery_confirm" {
            guard let view = recovery, view.phase == .review, view.canConfirm,
                  let id = view.reviewID, id == body.reviewID,
                  let slot = view.slot, slots[slot.context]?.revision == slot.revision else {
                recoveryFeedback = "The visible key or review changed. Read it again; nothing was reconciled."; return
            }
        }
        let request = UUID(), epoch = rebindPeerEpoch
        let wire = DeckWire(deckEvent: "command", command: command, request: request, recoveryCommand: body)
        guard let data = wire.encoded(), data.count <= DeckRecoveryLimits.reviewBytes else {
            recoveryFeedback = "This recovery request exceeds its private bridge limit. Nothing was sent."; return
        }
        guard recoveryRequests.begin(id: request, epoch: epoch, command: command) else { return }
        recoveryFeedback = ""; recoveryAckTask?.cancel()
        recoveryAckTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.peer === peer, self.rebindPeerEpoch == epoch,
                  self.recoveryRequests.timeout(id: request, epoch: epoch) else { return }
            self.recoveryFeedback = "The companion did not confirm this request. Its result is uncertain. Read current status; no command was retried and no outcome was cleared. Update the module and Elgato companion together if this persists."
        }
        peer.send(data)
    }
    func receiveRecovery(_ wire: DeckWire) {
        guard let value = wire.recovery, let data = wire.encoded(),
              data.count <= DeckRecoveryLimits.reviewBytes, value.records.count <= DeckRecoveryLimits.pageSize,
              value.totalRecordCount >= 0, value.totalRecordCount <= DeckRecoveryLimits.reportedRecords,
              value.offset >= 0, value.offset <= value.totalRecordCount,
              value.nextOffset.map({ $0 > value.offset && $0 <= value.totalRecordCount }) ?? true,
              Self.recoveryFieldsWithinBounds(value) else {
            recoveryFeedback = "The companion's recovery reply is unavailable or too large. Read status again; captured fields were not truncated."; return
        }
        // Final replies only: an old nonce or another connection cannot revive
        // a closed review, including a late response to an earlier status read.
        guard recoveryRequests.acknowledge(id: wire.request, epoch: rebindPeerEpoch) else { return }
        recoveryAckTask?.cancel(); recoveryAckTask = nil; recoveryFeedback = ""
        recoveryPresentation.receive(value)
        recovery = value
    }
    private static func recoveryFieldsWithinBounds(_ view: DeckRecoveryView) -> Bool {
        let known = Set(["provider", "name", "arguments", "field", "label"])
        for settings in [view.before, view.after, view.current, view.slot?.settings] {
            if let settings, (!Set(settings.keys).isSubset(of: known) || settings.values.contains(where: { $0.utf8.count > 8192 })) { return false }
        }
        return view.message.utf8.count <= 8192 && view.records.allSatisfy { row in
            row.context.utf8.count <= 200 && row.action.utf8.count <= 200 && row.device.utf8.count <= 200 &&
            row.controller.utf8.count <= 80 && row.state.utf8.count <= 100 && row.createdAt.utf8.count <= 100 && row.message.utf8.count <= 8192
        }
    }
    func closeRecoveryReview() {
        if peer != nil { submitRecovery("recovery_close", .init(reviewID: recovery?.reviewID)) }
        else { recoveryRequests.reset(); recoveryAckTask?.cancel(); recoveryAckTask = nil }
    }
}

/// Independent delegate so closing this read-only review cannot change the
/// established Reconnect window's cancellation/Undo path.
@MainActor final class DeckRecoveryWindowController: NSWindowController, NSWindowDelegate {
    private weak var model: ModuleApp?
    init(model: ModuleApp) {
        self.model = model
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 920, height: 710),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Recovery & pending outcomes"
        window.contentMinSize = .init(width: 760, height: 560); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: DeckRecoveryWindow(model: model).pluginThemed())
        window.center()
    }
    required init?(coder: NSCoder) { return nil }
    func windowWillClose(_ notification: Notification) { model?.closeRecoveryReview() }
}

struct DeckRecoveryWindow: View {
    @ObservedObject var model: ModuleApp
    @State private var selectedRecordID: UUID?
    @State private var selectedContext = ""
    @State private var confirmCurrent = false
    private var view: DeckRecoveryView? { model.recovery }
    private var inventory: DeckRecoveryPresentation.Page? { model.recoveryPresentation.page }
    private var selectedRecord: DeckRecoveryRecord? { model.recoveryPresentation.record(id: selectedRecordID) }
    private var detailMode: DeckRecoveryPresentation.DetailMode? { model.recoveryPresentation.detailMode(id: selectedRecordID) }
    private var controls: [DeckSlot] { model.slots.values.sorted { ($0.device, $0.row, $0.column, $0.context) < ($1.device, $1.row, $1.column, $1.context) } }
    private var selectedSlot: DeckSlot? { model.slots[selectedContext] }
    private var busy: Bool { model.recoveryRequestPending || model.recoveryRequests.uncertain }
    private var currentReview: Bool {
        view?.phase == .review && view?.recordID == selectedRecordID && view?.slot?.context == selectedContext &&
        view?.slot?.revision == selectedSlot?.revision
    }
    private var canKeepCurrent: Bool {
        currentReview && view?.canConfirm == true && model.recoveryPresentation.allowsSettingsReview(id: selectedRecordID) && !busy && model.peer != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: "clock.arrow.circlepath").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recovery & pending outcomes").font(.title2.weight(.semibold))
                    Text("Inspect saved evidence. Nothing is replayed or run.").pluginSecondaryText()
                }
                Spacer()
                Text(model.peer == nil ? "Offline · historical information" : "Elgato connected").pluginSecondaryText()
            }
            if !model.recoveryFeedback.isEmpty { Text(model.recoveryFeedback).foregroundStyle(.orange).textSelection(.enabled) }
            if let view { Text(view.message).textSelection(.enabled) }
            else { Text("Recovery information has not been read. Use Read current status.").pluginSecondaryText() }
            Divider()
            HStack(alignment: .top, spacing: 18) {
                recordList
                Divider()
                recordDetail
            }
            Divider()
            HStack {
                if model.recoveryRequestPending { ProgressView().controlSize(.small) }
                Text(model.recoveryRequestPending ? "Waiting for the companion…" : "Settings reconciliation never settles an old run or Stop request.").font(.caption).pluginSecondaryText()
                Spacer()
                Button("Read current status") { page(inventory?.offset ?? 0) }.disabled(model.peer == nil || model.recoveryRequestPending)
                Button("Close review") { model.closeRecoveryReview() }.disabled(model.peer == nil)
            }
        }
        .padding(20)
        .onChange(of: model.recovery?.phase) { phase in if phase != .review { confirmCurrent = false } }
        .onChange(of: model.rebindPeerEpoch) { _ in
            selectedRecordID = nil; selectedContext = ""; confirmCurrent = false
        }
        .confirmationDialog("Keep the selected control’s current settings?", isPresented: $confirmCurrent, titleVisibility: .visible) {
            Button("Keep current settings") {
                guard canKeepCurrent, let id = view?.reviewID else { return }
                model.submitRecovery("recovery_confirm", .init(reviewID: id))
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The companion rereads the complete settings first. If they are unchanged, it records this explicit association and observation. It does not write to Elgato, replace manual edits, run an action or resolve an earlier run outcome.")
        }
    }
    private var recordList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.recoveryPresentation.isRetainedInventory ? "Last read inventory" : "Saved records").font(.headline)
            Text("Recent outcomes · unresolved records are retained").font(.caption2).pluginSecondaryText()
            if let inventory {
                if inventory.records.isEmpty {
                    Text(inventory.totalRecordCount == 0 ? "No retained records reported by the companion." : "No records on this inventory page.")
                        .pluginSecondaryText()
                }
            } else {
                Text("Read status to load the saved inventory.").pluginSecondaryText()
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(inventory?.records ?? []) { row in
                        Button {
                            if selectedRecordID != row.id {
                                if view?.phase == .review || model.recoveryRequests.pending?.command == "recovery_prepare" { model.closeRecoveryReview() }
                                selectedRecordID = row.id; selectedContext = ""; confirmCurrent = false
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(kind(row.kind)).font(.headline); Spacer(); if row.unresolved { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) } }
                                Text(row.state + (row.cold ? " · earlier session" : " · current session")).font(.caption)
                                Text(row.createdAt).font(.caption2).pluginSecondaryText()
                                if let address = row.newAddress ?? row.oldAddress { Text(address.plugin + " / " + address.name).font(.caption2.monospaced()).lineLimit(2) }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedRecordID == row.id ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Button("Previous") { page(max(0, (inventory?.offset ?? 0) - DeckRecoveryLimits.pageSize)) }
                    .disabled(busy || model.peer == nil || (inventory?.offset ?? 0) == 0)
                Spacer()
                Button("Next") { if let offset = inventory?.nextOffset { page(offset) } }
                    .disabled(busy || model.peer == nil || inventory?.nextOffset == nil)
            }
            if let inventory { Text("Showing \(inventory.records.count) from offset \(inventory.offset) · \(inventory.totalRecordCount) total records").font(.caption2).pluginSecondaryText() }
        }.frame(width: 265)
    }
    private var recordDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                if let row = selectedRecord {
                    Text(kind(row.kind)).font(.headline)
                    Text("Record ID: " + row.id.uuidString.lowercased()).font(.caption2.monospaced()).textSelection(.enabled)
                    Text(row.message).textSelection(.enabled)
                    if let address = row.oldAddress { Text("Recorded original: " + address.plugin + " / " + address.name).font(.caption.monospaced()).textSelection(.enabled) }
                    if let address = row.newAddress { Text("Recorded proposed: " + address.plugin + " / " + address.name).font(.caption.monospaced()).textSelection(.enabled) }
                    Text("Recorded control: \(row.controller) · \(row.row + 1), \(row.column + 1) · \(row.device)").font(.caption).textSelection(.enabled)
                    Text("Earlier context: \(row.context)").font(.caption2.monospaced()).textSelection(.enabled)
                    if detailMode == .executionEvidence {
                        Label(row.unresolved ? "Execution outcome is not confirmed" : "Recorded execution evidence · read-only", systemImage: "lock").font(.headline)
                        Text("The shared action API cannot query or regain an old request. Any terminal status shown is retained evidence. Inspect the original provider; this review cannot mark work finished, resume it or send another Stop.").pluginSecondaryText()
                    } else if detailMode == .settingsObservation {
                        Label("Recorded settings outcome · read-only", systemImage: "lock").font(.headline)
                        Text("This record no longer needs settings reconciliation. Its saved outcome is an observation, not proof of an earlier execution result.").pluginSecondaryText()
                        if let hash = row.beforeSHA256 { Text("Saved before SHA-256: " + hash).font(.caption2.monospaced()).textSelection(.enabled) }
                        if let hash = row.afterSHA256 { Text("Saved proposed after SHA-256: " + hash).font(.caption2.monospaced()).textSelection(.enabled) }
                    } else if detailMode == .unresolvedSettings {
                        Text("Choose the current visible key you intend to associate with this record. An earlier context, title or location does not identify a key after restart.").pluginSecondaryText()
                        Picker("Current visible control", selection: Binding(get: { selectedContext }, set: { value in
                            if value != selectedContext, view?.phase == .review { model.closeRecoveryReview() }
                            selectedContext = value
                        })) {
                            Text("Select a key or dial…").tag("")
                            ForEach(controls, id: \.context) { slot in
                                Text("\(slot.controller == "Encoder" ? "Dial" : "Key") \(slot.row + 1), \(slot.column + 1) · \(slot.device) · \(slot.settings["label"] ?? slot.action)").tag(slot.context)
                            }
                        }.disabled(busy || model.peer == nil)
                        Button("Read this key’s current settings") {
                            guard let slot = selectedSlot else { return }
                            model.submitRecovery("recovery_prepare", .init(recordID: row.id, context: slot.context, revision: slot.revision))
                        }.disabled(busy || model.peer == nil || selectedSlot == nil)
                        if currentReview, let view {
                            Text(comparison(view.match)).font(.callout).textSelection(.enabled)
                            fields("Saved before", view.before, hash: view.beforeSHA256)
                            fields("Saved proposed after", view.after, hash: view.afterSHA256)
                            fields("Currently read from your selected control", view.current, hash: view.currentSHA256)
                            Text("These are all captured known mapping fields. Complete logical settings, including other Elgato fields, are compared and retained by the companion. No setSettings command is sent.").pluginSecondaryText()
                            Button("Keep these current settings…") { confirmCurrent = true }.disabled(!canKeepCurrent)
                        }
                    }
                } else {
                    Text("Select a saved record to inspect it.").pluginSecondaryText()
                    Text("Only explicitly selected, currently visible controls can be reviewed. Hidden profiles and pages remain unassessed.").pluginSecondaryText()
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
        }
    }
    private func page(_ offset: Int) {
        selectedRecordID = nil; selectedContext = ""; confirmCurrent = false
        model.submitRecovery("recovery_status", .init(offset: offset))
    }
    private func fields(_ title: String, _ values: [String: String]?, hash: String?) -> some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 6) {
                if let values {
                    if values.isEmpty { Text("No known mapping fields in this captured object.").pluginSecondaryText() }
                    ForEach(values.keys.sorted(), id: \.self) { key in
                        Text(key).font(.caption.weight(.semibold))
                        Text(verbatim: values[key] ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                } else { Text("Not available for this record.").pluginSecondaryText() }
                if let hash { Text("Complete settings SHA-256: " + hash).font(.caption2.monospaced()).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }
    }
    private func kind(_ value: DeckRecoveryRecord.Kind) -> String {
        switch value { case .settings: return "Settings change"; case .run: return "Run outcome"; case .cancel: return "Run & Stop outcome" }
    }
    private func comparison(_ value: DeckRecoveryView.Match?) -> String {
        switch value {
        case .before: return "This control currently matches the saved before image. That does not prove an earlier write never happened."
        case .after: return "This control currently matches the saved after image. This is a settings observation, not an execution outcome."
        case .different: return "Current settings differ. Your manual or external changes will be kept."
        case .notApplicable: return "This record cannot be reconciled through current key settings."
        case nil: return "Readback comparison is unavailable."
        }
    }
}
