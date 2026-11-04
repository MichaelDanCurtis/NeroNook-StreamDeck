import Foundation
import NookPluginSDK

/// Companion-owned persistence and explicit, read-only cold-key reconciliation.
/// Stored context IDs are historical data, never proof of a current key owner.
@MainActor final class DeckRecoveryCoordinator {
    struct Environment {
        var snapshot: (String) -> DeckRebindingSlot?
        var generation: () -> UUID?
        var readSettings: (String) -> Void
        var emit: (DeckRecoveryView, UUID) -> Void
    }
    private struct Read {
        let request: UUID
        let recordID: UUID
        let slot: DeckSlot
        let generation: UUID
        let deadline: Date
        let confirming: UUID?
    }
    private struct Review {
        let id: UUID
        let recordID: UUID
        let recordRevision: UInt64
        let slot: DeckSlot
        let generation: UUID
        let data: Data
        let expires: Date
    }
    private let environment: Environment
    private var ledger: DeckRecoveryLedger?
    private(set) var snapshot: DeckRecoveryLedger.Snapshot?
    private(set) var problem = "Loading saved outcomes…"
    private var read: Read?
    private var review: Review?
    private var epoch = UUID()
    private var resolving = false
    private var liveSettings = Set<UUID>()
    private var busySettings = Set<UUID>()
    private var liveRuns = Set<UUID>()
    private var rebindRecordIDs: [UUID: UUID] = [:]
    private var pendingRunIDs = Set<UUID>()
    private var storageBusy = false
    private var storageWaiters: [CheckedContinuation<Void, Never>] = []
    var ready: Bool { ledger != nil && snapshot != nil && problem.isEmpty }

    init(environment: Environment) { self.environment = environment }

    static func directory(scope: BridgeScope) -> URL { scope.recoveryDirectory }

    func load(directory: URL) async {
        guard ledger == nil else { return }
        do {
            try await acquireStorage()
            defer { releaseStorage() }
            try await Task.detached(priority: .utility) {
                let parent = directory.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parent.path) {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                }
            }.value
            let value = try await DeckRecoveryLedger.open(directory: directory)
            ledger = value
            snapshot = try await value.listRecords()
            problem = ""
        } catch { problem = "Saved outcomes could not be opened. New writes and actions are blocked; nothing was reset." }
    }
    private func requireLedger() throws -> DeckRecoveryLedger {
        guard ready, let ledger else { throw ModuleProblem(problem.isEmpty ? "Saved outcomes are not available." : problem) }
        return ledger
    }
    private func reload(_ ledger: DeckRecoveryLedger) async throws {
        snapshot = try await ledger.listRecords()
    }
    private func failedStorage() {
        problem = "Saved outcome storage is unavailable. New writes and actions remain blocked. Existing evidence was retained."
    }
    private func acquireStorage() async throws {
        if !storageBusy { storageBusy = true; return }
        guard storageWaiters.count < 256 else { throw ModuleProblem("Too many pending local receipt operations.") }
        await withCheckedContinuation { storageWaiters.append($0) }
    }
    private func releaseStorage() {
        if storageWaiters.isEmpty { storageBusy = false }
        else { storageWaiters.removeFirst().resume() }
    }
    static func slot(_ value: DeckSlot) -> DeckRecoveryLedger.Slot {
        .init(context: value.context, action: value.action, device: value.device, controller: value.controller,
              row: value.row, column: value.column, revision: value.revision)
    }
    static func sameVisibleKey(_ a: DeckSlot, _ b: DeckSlot) -> Bool {
        a.context == b.context && a.action == b.action && a.device == b.device
            && a.controller == b.controller && a.row == b.row && a.column == b.column
    }
    func blocks(context: String, addresses: Set<PluginActionAddress>, coldSettingsOnly: Bool = false) -> Bool {
        guard ready, let snapshot else { return true }
        if let read, read.slot.context == context { return true }
        if let review, review.slot.context == context { return true }
        return snapshot.settings.contains { record in
            record.unresolved && (!coldSettingsOnly || record.sessionID != snapshot.sessionID)
                && (record.slot.context == context || addresses.contains(record.oldAddress) || addresses.contains(record.newAddress))
        } || snapshot.runs.contains { record in
            record.unresolved && (record.slot.context == context || addresses.contains(record.address))
        }
    }
    func blocksRun(context: String, address: PluginActionAddress, except runID: UUID? = nil) -> Bool {
        guard ready, let snapshot else { return true }
        if read?.slot.context == context || review?.slot.context == context { return true }
        return snapshot.settings.contains {
            $0.unresolved && ($0.slot.context == context || $0.oldAddress == address || $0.newAddress == address)
        } || snapshot.runs.contains {
            $0.id != runID && $0.unresolved && ($0.slot.context == context || $0.address == address)
        }
    }
    func prepareSettings(capture: DeckRebindingCapture, request: UUID, undo: Bool) async throws -> UUID {
        let parent = undo ? rebindRecordIDs[capture.row.id] : nil
        if undo && parent == nil { throw ModuleProblem("The original confirmed receipt is not retained in this companion session.") }
        let id = try await prepareSettings(slot: capture.slot, before: capture.beforeData, after: capture.afterData,
            oldAddress: capture.source, newAddress: capture.target, request: request, kind: undo ? .undo : .rebind,
            parentID: parent)
        if !undo { rebindRecordIDs[capture.row.id] = id }
        return id
    }
    func prepareSettings(slot: DeckSlot, before: Data, after: Data, oldAddress: PluginActionAddress,
                         newAddress: PluginActionAddress, request: UUID,
                         kind: DeckRecoveryLedger.SettingsKind, parentID: UUID? = nil) async throws -> UUID {
        try await acquireStorage()
        defer { releaseStorage() }
        let ledger = try requireLedger()
        do {
            let record = try await ledger.prepareSettings(.init(id: UUID(), requestID: request, kind: kind,
                slot: Self.slot(slot), oldAddress: oldAddress, newAddress: newAddress,
                beforeData: before, afterData: after, parentID: parentID))
            liveSettings.insert(record.id)
            busySettings.insert(record.id)
            try await reload(ledger)
            return record.id
        } catch { failedStorage(); throw error }
    }
    func finishSettings(_ id: UUID, _ outcome: DeckRecoveryLedger.SettingsOutcome) async throws {
        try await acquireStorage()
        defer { releaseStorage() }
        let ledger = try requireLedger()
        guard let record = snapshot?.settings.first(where: { $0.id == id }), liveSettings.contains(id) else {
            throw ModuleProblem("The saved-settings intent is not owned by this companion session.")
        }
        do {
            _ = try await ledger.finishSettings(id: id, expectedRevision: record.revision, outcome: outcome)
            try await reload(ledger)
            busySettings.remove(id)
            if snapshot?.settings.first(where: { $0.id == id })?.unresolved == false { liveSettings.remove(id) }
        } catch { failedStorage(); throw error }
    }
    func prepareRun(id: UUID, slot: DeckSlot, entry: PluginCatalogEntry) async throws {
        try await acquireStorage()
        defer { releaseStorage() }
        let ledger = try requireLedger()
        guard let action = entry.action else { throw ModuleProblem("The action is unavailable.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let hash = DeckRebindingJSON.sha(try encoder.encode(action))
        pendingRunIDs.insert(id)
        defer { pendingRunIDs.remove(id) }
        do {
            _ = try await ledger.prepareRun(.init(id: id, slot: Self.slot(slot), address: entry.address, descriptorSHA256: hash))
            liveRuns.insert(id)
            try await reload(ledger)
        } catch { failedStorage(); throw error }
    }
    func finishRun(_ id: UUID, phase: PluginRunPhase) async {
        do { try await acquireStorage() } catch { failedStorage(); return }
        defer { releaseStorage() }
        guard let ledger, liveRuns.contains(id), let record = snapshot?.runs.first(where: { $0.id == id }) else { return }
        do {
            _ = try await ledger.finishRun(id: id, expectedRevision: record.revision, phase: phase)
            try await reload(ledger)
            if snapshot?.runs.first(where: { $0.id == id })?.unresolved == false { liveRuns.remove(id) }
        } catch { failedStorage() }
    }
    func prepareCancel(_ id: UUID) async {
        do { try await acquireStorage() } catch { failedStorage(); return }
        defer { releaseStorage() }
        guard let ledger, liveRuns.contains(id), let record = snapshot?.runs.first(where: { $0.id == id }) else { return }
        do {
            _ = try await ledger.prepareCancel(runID: id, expectedRevision: record.revision, cancelID: UUID())
            try await reload(ledger)
        } catch { failedStorage() }
    }
    func isRunPreparing(_ id: UUID) -> Bool { pendingRunIDs.contains(id) }
    func settingsID(_ capture: DeckRebindingCapture) -> UUID? {
        snapshot?.settings.last { liveSettings.contains($0.id) && $0.slot.context == capture.slot.context
            && $0.beforeData == capture.beforeData && $0.afterData == capture.afterData }?.id
    }

    func handle(_ command: String, payload: DeckRecoveryCommand, request: UUID?) {
        guard let request else { return }
        do {
            switch command {
            case "recovery_status":
                guard payload.recordID == nil, payload.context == nil, payload.revision == nil, payload.reviewID == nil else {
                    throw ModuleProblem("Status takes only a page offset.")
                }
                publishStatus(request: request, offset: payload.offset ?? 0)
            case "recovery_close":
                guard payload.recordID == nil, payload.context == nil, payload.revision == nil, payload.offset == nil else {
                    throw ModuleProblem("Close takes only the current review ID.")
                }
                if let id = payload.reviewID, review?.id != id { throw ModuleProblem("This recovery review is no longer current.") }
                epoch = UUID(); read = nil; review = nil
                publishStatus(request: request, message: "Review closed. No settings or actions were replayed.")
            case "recovery_prepare":
                guard ready, read == nil, !resolving, payload.offset == nil, payload.reviewID == nil,
                      let id = payload.recordID, let context = payload.context, let revision = payload.revision,
                      let record = snapshot?.settings.first(where: { $0.id == id }), record.unresolved,
                      !busySettings.contains(id), let slot = environment.snapshot(context)?.slot,
                      slot.revision == revision, slot.action == record.slot.action,
                      slot.controller == record.slot.controller, let generation = environment.generation() else {
                    throw ModuleProblem("Select an unresolved saved-settings record and its currently visible key. Live writes and old run outcomes cannot be cleared here.")
                }
                review = nil; epoch = UUID()
                read = .init(request: request, recordID: id, slot: slot, generation: generation,
                    deadline: Date().addingTimeInterval(10), confirming: nil)
                environment.readSettings(context)
            case "recovery_confirm":
                guard read == nil, !resolving, payload.offset == nil, payload.context == nil,
                      payload.revision == nil, payload.recordID == nil, let id = payload.reviewID,
                      let review, id == review.id, Date() < review.expires,
                      environment.generation() == review.generation,
                      let current = environment.snapshot(review.slot.context)?.slot,
                      Self.sameVisibleKey(current, review.slot) else {
                    throw ModuleProblem("That recovery review changed or expired. Read the visible key again.")
                }
                read = .init(request: request, recordID: review.recordID, slot: current,
                    generation: review.generation, deadline: Date().addingTimeInterval(10), confirming: id)
                environment.readSettings(current.context)
            default: throw ModuleProblem("Unknown recovery command.")
            }
        } catch { reject(error.localizedDescription, request: request) }
    }
    func readback(slot: DeckSlot, settings: [String: Any]) {
        guard let pending = read, pending.slot.context == slot.context else { return }
        read = nil
        do {
            guard Date() < pending.deadline, environment.generation() == pending.generation,
                  Self.sameVisibleKey(slot, pending.slot), let record = snapshot?.settings.first(where: { $0.id == pending.recordID }),
                  record.unresolved, !busySettings.contains(record.id) else {
                throw ModuleProblem("The key, connection or saved outcome changed before readback.")
            }
            let data = try DeckRebindingJSON.canonical(settings)
            if let id = pending.confirming {
                guard let review, review.id == id, review.recordID == record.id,
                      review.recordRevision == record.revision, review.data == data else {
                    self.review = nil
                    throw ModuleProblem("The key changed since review. Its current settings were preserved; read and review it again.")
                }
                let token = epoch
                resolving = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.resolving = false }
                    do {
                        try await self.acquireStorage()
                        defer { self.releaseStorage() }
                        let ledger = try self.requireLedger()
                        guard token == self.epoch, self.review?.id == id,
                              self.review?.recordRevision == record.revision,
                              self.environment.generation() == pending.generation,
                              let current = self.environment.snapshot(slot.context),
                              Self.sameVisibleKey(current.slot, slot),
                              try DeckRebindingJSON.canonical(current.settings) == data else {
                            self.review = nil
                            self.reject("The review, key or connection changed before reconciliation. The saved outcome remains unresolved.", request: pending.request)
                            return
                        }
                        self.review = nil // consume this exact native decision before disk work
                        _ = try await ledger.reconcileSettings(id: record.id, expectedRevision: record.revision,
                            observedData: data, selectedSlot: Self.slot(slot))
                        try await self.reload(ledger)
                        self.review = nil
                        self.publishStatus(request: pending.request,
                            message: token == self.epoch ? "Current settings kept and the selected key reassociated. No write, action or old run was replayed." : "The read-only reconciliation completed after this review closed. Nothing was replayed.",
                            phase: .complete)
                    } catch {
                        self.failedStorage(); self.review = nil
                        self.reject("Reconciliation was not confirmed. Keep the saved evidence and inspect its current status.", request: pending.request)
                    }
                }
            } else {
                let value = Review(id: UUID(), recordID: record.id, recordRevision: record.revision,
                    slot: slot, generation: pending.generation, data: data, expires: Date().addingTimeInterval(300))
                review = value
                let knownBefore = try DeckRebindingJSON.knownSettings(DeckRebindingJSON.object(record.beforeData))
                let knownAfter = try DeckRebindingJSON.knownSettings(DeckRebindingJSON.object(record.afterData))
                let knownCurrent = try DeckRebindingJSON.knownSettings(settings)
                let match: DeckRecoveryView.Match = data == record.beforeData ? .before : data == record.afterData ? .after : .different
                var view = DeckRecoveryView(phase: .review, message: "Confirm that this visible key is the one you changed. Its current settings will be kept, including any later manual edit. This resolves only this settings record; old work remains separate.")
                view.reviewID = value.id; view.recordID = record.id; view.slot = slot
                view.before = knownBefore; view.after = knownAfter; view.current = knownCurrent
                view.beforeSHA256 = DeckRebindingJSON.sha(record.beforeData)
                view.afterSHA256 = DeckRebindingJSON.sha(record.afterData); view.currentSHA256 = DeckRebindingJSON.sha(data)
                view.match = match; view.canConfirm = true
                emit(view, request: pending.request)
            }
        } catch { reject(error.localizedDescription, request: pending.request) }
    }
    func tick(now: Date = Date()) {
        if let read, now >= read.deadline {
            self.read = nil; review = nil
            reject("Fresh settings did not arrive. The saved outcome remains unresolved; nothing was replayed.", request: read.request)
        }
    }
    func disconnected() {
        epoch = UUID(); review = nil
        if let read {
            self.read = nil
            reject("The connection ended before fresh readback. The saved outcome remains unresolved.", request: read.request)
        }
    }
    private func records() -> [DeckRecoveryRecord] {
        guard let snapshot else { return [] }
        let settings = snapshot.settings.map { value in
            DeckRecoveryRecord(id: value.id, kind: .settings, createdAt: value.createdAt,
                context: value.slot.context, action: value.slot.action, device: value.slot.device,
                controller: value.slot.controller, row: value.slot.row, column: value.slot.column,
                oldAddress: value.oldAddress, newAddress: value.newAddress,
                beforeSHA256: DeckRebindingJSON.sha(value.beforeData), afterSHA256: DeckRebindingJSON.sha(value.afterData),
                state: value.state.rawValue, cold: value.sessionID != snapshot.sessionID,
                unresolved: value.unresolved, message: value.unresolved ? "Read the selected visible key. Nothing will resume automatically." : "Settings observation retained; no action receipt or grant.")
        }
        let runs = snapshot.runs.map { value in
            DeckRecoveryRecord(id: value.id, kind: value.cancelIDs.isEmpty ? .run : .cancel, createdAt: value.createdAt,
                context: value.slot.context, action: value.slot.action, device: value.slot.device,
                controller: value.slot.controller, row: value.slot.row, column: value.slot.column,
                oldAddress: value.address, newAddress: nil, beforeSHA256: nil, afterSHA256: nil,
                state: value.phase.rawValue, cold: value.sessionID != snapshot.sessionID,
                unresolved: value.unresolved, message: value.unresolved ? "Inspect the original run in NeroNook or its provider. This view cannot prove it stopped, replay it, or cancel a guessed run." : "Original session outcome retained; no run continuation.")
        }
        return (settings + runs).sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }
    private func publishStatus(request: UUID, offset: Int = 0, message: String? = nil,
                               phase: DeckRecoveryView.Phase = .status) {
        let all = records()
        guard offset >= 0, offset % DeckRecoveryLimits.pageSize == 0,
              offset == 0 || offset < all.count else { reject("That recovery page is unavailable.", request: request); return }
        let end = min(all.count, offset + DeckRecoveryLimits.pageSize)
        var value = DeckRecoveryView(phase: ready ? phase : .rejected,
            message: message ?? (problem.isEmpty ? "Saved outcomes only. Hidden profiles are not assessed; no write or work resumes here." : problem))
        value.records = Array(all[offset..<end]); value.totalRecordCount = all.count
        value.offset = offset; value.nextOffset = end < all.count ? end : nil
        emit(value, request: request)
    }
    private func reject(_ message: String, request: UUID) {
        emit(.init(phase: .rejected, message: String(message.prefix(300))), request: request)
    }
    private func emit(_ value: DeckRecoveryView, request: UUID) {
        let wire = DeckWire(deckEvent: "recovery", request: request, message: value.message, recovery: value)
        guard let data = wire.encoded(), data.count <= DeckRecoveryLimits.reviewBytes else {
            review = nil
            environment.emit(.init(phase: .rejected, message: "The complete recovery view exceeds its limit. No captured settings were truncated or changed."), request)
            return
        }
        environment.emit(value, request)
    }
}
