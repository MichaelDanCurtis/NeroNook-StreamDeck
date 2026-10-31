import Foundation
import CryptoKit
import NookPluginSDK

/// Private consumer bridge data, not a shared SDK feature or routing authority.
struct DeckRebindingCommand: Codable {
    var contexts: [String]?
    var source: PluginActionAddress?
    var target: PluginActionAddress?
    var reviewID: UUID?
    var receiptID: UUID?
    init(contexts: [String]? = nil, source: PluginActionAddress? = nil, target: PluginActionAddress? = nil,
         reviewID: UUID? = nil, receiptID: UUID? = nil) {
        self.contexts = contexts; self.source = source; self.target = target
        self.reviewID = reviewID; self.receiptID = receiptID
    }
}
struct DeckRebindingRow: Codable, Identifiable {
    enum Outcome: String, Codable { case pending, notAttempted, applying, confirmed, conflict, unconfirmed, rejected, undone }
    var id: UUID
    var context: String
    var action: String
    var device: String
    var controller: String
    var row: Int
    var column: Int
    var revision: String
    var before: [String: String]
    var after: [String: String]
    var beforeSHA256: String
    var afterSHA256: String
    var unknownFieldCount: Int
    var outcome: Outcome = .pending
    var receiptID: UUID? = nil
    var undoAvailable = false
    var message = ""
    var observed: [String: String]? = nil
    var observedSHA256: String? = nil
}
struct DeckRebindingView: Codable {
    enum Phase: String, Codable { case review, applying, complete, partial, conflict, unconfirmed, rejected, undone, closed }
    var phase: Phase
    var reviewID: UUID? = nil
    var source: PluginActionAddress? = nil
    var target: PluginActionAddress? = nil
    var oldAction: PluginRegisteredAction? = nil
    var newAction: PluginRegisteredAction? = nil
    var rows: [DeckRebindingRow] = []
    var message: String
    var visibleOnly = true
}

enum DeckRebindingLimits {
    static let rows = 16
    static let reviewBytes = 98_304
    static let settingsBytes = 131_072
    static let quarantinedContexts = 128
    /// Never evicts an older unresolved barrier to admit a new mutation.
    static func admits(existing: Set<String>, adding: Set<String>) -> Bool {
        existing.union(adding).count <= quarantinedContexts
    }
}

enum DeckRebindingJSON {
    static let known = Set(["provider", "name", "arguments", "field", "label"])
    static func canonical(_ settings: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(settings) else { throw ModuleProblem("The complete key settings are not valid JSON.") }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        guard data.count <= DeckRebindingLimits.settingsBytes else { throw ModuleProblem("The complete key settings exceed this review's limit.") }
        return data
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= DeckRebindingLimits.settingsBytes,
              let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModuleProblem("The retained key settings cannot be read.")
        }
        return settings
    }
    static func knownSettings(_ settings: [String: Any]) throws -> [String: String] {
        guard Set(settings.keys).intersection(known).allSatisfy({ settings[$0] is String }) else {
            throw ModuleProblem("A known mapping field has an unsupported value.")
        }
        let values = settings.compactMapValues { $0 as? String }.filter { known.contains($0.key) }
        guard values.values.allSatisfy({ $0.utf8.count <= 8192 }) else { throw ModuleProblem("A mapping field exceeds its limit.") }
        return values
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validateWriteEnvelope(_ settings: [String: Any], context: String) throws {
        let envelope: [String: Any] = ["event": "setSettings", "context": context, "payload": settings]
        guard try JSONSerialization.data(withJSONObject: envelope).count <= 131_072 else {
            throw ModuleProblem("The complete setSettings envelope exceeds Elgato's framing limit. Nothing was written.")
        }
    }
}

struct DeckRebindingSlot {
    let slot: DeckSlot
    let settings: [String: Any]
}
struct DeckRebindingCapture {
    let slot: DeckSlot
    let beforeData: Data
    let afterData: Data
    let source: PluginActionAddress
    let target: PluginActionAddress
    let row: DeckRebindingRow

    init(snapshot: DeckRebindingSlot, source: PluginActionAddress, target: PluginActionAddress,
         catalog: [PluginCatalogEntry]) throws {
        let slot = snapshot.slot
        guard ["cafe.nero.neronook.run", "cafe.nero.neronook.stop"].contains(slot.action),
              slot.controller == "Keypad", slot.address == source else {
            throw ModuleProblem("Select only visible Nero Run or Stop keys using the exact old address.")
        }
        let before = try DeckRebindingJSON.knownSettings(snapshot.settings)
        guard before == slot.settings else { throw ModuleProblem("The key's complete settings and visible snapshot differ. Reload it.") }
        var after = before; after["provider"] = target.plugin; after["name"] = target.name
        try DeckMapping.validate(settings: after, slot: slot, catalog: catalog)
        var completeAfter = snapshot.settings; completeAfter["provider"] = target.plugin; completeAfter["name"] = target.name
        self.slot = slot; self.source = source; self.target = target
        beforeData = try DeckRebindingJSON.canonical(snapshot.settings)
        afterData = try DeckRebindingJSON.canonical(completeAfter)
        try DeckRebindingJSON.validateWriteEnvelope(snapshot.settings, context: slot.context)
        try DeckRebindingJSON.validateWriteEnvelope(completeAfter, context: slot.context)
        row = .init(id: UUID(), context: slot.context, action: slot.action, device: slot.device,
            controller: slot.controller, row: slot.row, column: slot.column, revision: slot.revision,
            before: before, after: after, beforeSHA256: DeckRebindingJSON.sha(beforeData),
            afterSHA256: DeckRebindingJSON.sha(afterData), unknownFieldCount: Set(snapshot.settings.keys).subtracting(DeckRebindingJSON.known).count)
    }
    private init(slot: DeckSlot, beforeData: Data, afterData: Data, source: PluginActionAddress,
                 target: PluginActionAddress, row: DeckRebindingRow) {
        self.slot = slot; self.beforeData = beforeData; self.afterData = afterData
        self.source = source; self.target = target; self.row = row
    }
    func inverse() -> Self {
        var inverted = row
        inverted.before = row.after; inverted.after = row.before
        inverted.beforeSHA256 = row.afterSHA256; inverted.afterSHA256 = row.beforeSHA256
        return .init(slot: slot, beforeData: afterData, afterData: beforeData, source: target, target: source, row: inverted)
    }
    func matchesIdentity(_ other: DeckSlot) -> Bool {
        slot.context == other.context && slot.action == other.action && slot.device == other.device
            && slot.controller == other.controller && slot.row == other.row && slot.column == other.column
    }
}

/// All effects remain in ElgatoClient. Callbacks return on its main actor;
/// persistence may outlive a UI request. No host singleton or profile-file IO.
struct DeckRebindingEnvironment {
    var snapshot: @MainActor (String) -> DeckRebindingSlot?
    var catalog: @MainActor () -> [PluginCatalogEntry]
    var generation: @MainActor () -> UUID?
    var catalogGeneration: @MainActor () -> UUID
    var occupiedContexts: @MainActor () -> Set<String>
    var overlapsSave: @MainActor (Set<String>, Set<PluginActionAddress>) -> Bool
    var hasUnsettledWork: @MainActor (Set<String>, Set<PluginActionAddress>) -> Bool
    var readSettings: @MainActor (String) -> Void
    var writeSettings: @MainActor (String, [String: Any]) -> Void
    var prepareWrite: @MainActor (DeckRebindingCapture, UUID, Bool, @escaping @MainActor (Result<UUID, Error>) -> Void) -> Void
    var finishWrite: @MainActor (UUID, DeckRecoveryLedger.SettingsOutcome, @escaping @MainActor (Result<Void, Error>) -> Void) -> Void
    var quarantine: @MainActor (DeckRebindingCapture, UUID) -> Void
    var emit: @MainActor (DeckRebindingView, UUID?) -> Void
}

@MainActor final class DeckRebinding {
    private struct Review {
        let id: UUID
        let source, target: PluginActionAddress
        let oldAction: PluginRegisteredAction?
        let newAction: PluginRegisteredAction
        let captures: [DeckRebindingCapture]
        let generation, catalogGeneration: UUID
        let expires: Date
    }
    private struct Receipt {
        let capture: DeckRebindingCapture
        let review: Review
        var undone = false
    }
    private struct Operation {
        enum Stage: Equatable { case before, persistIntent, after, persistOutcome }
        let id = UUID()
        let request: UUID
        let review: Review
        let captures: [DeckRebindingCapture]
        let undoReceipt: UUID?
        var index = 0
        var stage = Stage.before
        var deadline: Date
        var stopReason: String?
        var recordID: UUID?
        var sent = false
        var current: DeckRebindingCapture { captures[index] }
    }
    private let environment: DeckRebindingEnvironment
    private var review: Review?
    private var operation: Operation?
    private var receipts: [UUID: Receipt] = [:]
    private var observations: [UUID: Data] = [:]
    private(set) var view: DeckRebindingView?
    var reservedContexts: Set<String> { Set(operation?.captures.map { $0.slot.context } ?? []) }
    init(environment: DeckRebindingEnvironment) { self.environment = environment }
    func blocks(context: String, address: PluginActionAddress) -> Bool {
        guard let operation else { return false }
        return reservedContexts.contains(context) || address == operation.review.source || address == operation.review.target
    }

    func handle(_ command: String, payload: DeckRebindingCommand, request: UUID?, now: Date = Date()) {
        guard let request else { reject("The reconnection request has no correlation ID.", request: nil); return }
        do {
            switch command {
            case "rebind_status":
                guard empty(payload) else { throw ModuleProblem("Status takes no mutation arguments.") }
                publish(request: request)
            case "rebind_prepare": try prepare(payload, request: request, now: now)
            case "rebind_apply": try apply(payload, request: request, now: now)
            case "rebind_undo": try undo(payload, request: request, now: now)
            case "rebind_close":
                guard payload.contexts == nil, payload.source == nil, payload.target == nil,
                      payload.receiptID == nil, let id = payload.reviewID, id == view?.reviewID else {
                    throw ModuleProblem("That reconnection review is no longer current.")
                }
                if operation != nil {
                    operation?.stopReason = "Stopped by you. No further keys will be changed."
                    if operation?.stage == .before {
                        if operation?.recordID != nil {
                            stopBeforeDispatch(operation!.stopReason!); publish(request: request)
                        }
                        else { finish(phase: .partial, message: operation!.stopReason!, request: request) }
                    }
                    else { view?.message = "Stopping future changes; waiting for the actual settings or persistence worker to finish."; publish(request: request) }
                } else {
                    review = nil; view?.phase = .closed
                    view?.message = "Review closed. Confirmed settings receipts remain available in this companion session."
                    publish(request: request)
                }
            default: throw ModuleProblem("Unknown saved-key reconnection operation.")
            }
        } catch { reject(error.localizedDescription, request: request) }
    }

    private func empty(_ payload: DeckRebindingCommand) -> Bool {
        payload.contexts == nil && payload.source == nil && payload.target == nil && payload.reviewID == nil && payload.receiptID == nil
    }
    private func prepare(_ payload: DeckRebindingCommand, request: UUID, now: Date) throws {
        guard operation == nil else { throw ModuleProblem("A saved-key change is still in progress. Read its status or stop future changes.") }
        guard let contexts = payload.contexts, (1...DeckRebindingLimits.rows).contains(contexts.count),
              Set(contexts).count == contexts.count, contexts.allSatisfy({ !$0.isEmpty && $0.count <= 200 }),
              let source = payload.source, let target = payload.target, source != target,
              payload.reviewID == nil, payload.receiptID == nil else {
            throw ModuleProblem("Choose one to sixteen distinct visible keys and different exact old and new addresses.")
        }
        try source.validate(); try target.validate()
        guard let generation = environment.generation() else { throw ModuleProblem("Reconnect NeroNook before reviewing saved keys.") }
        let catalog = environment.catalog()
        guard let newAction = catalog.first(where: { $0.address == target })?.action else {
            throw ModuleProblem("The replacement action is not currently permitted. Allow it normally before preparing this review.")
        }
        let selected = Set(contexts), addresses = Set([source, target])
        try requireAvailable(contexts: selected, addresses: addresses)
        let captures = try contexts.map { context -> DeckRebindingCapture in
            guard let snapshot = environment.snapshot(context) else { throw ModuleProblem("A selected key is no longer visible. Nothing was omitted or changed.") }
            return try .init(snapshot: snapshot, source: source, target: target, catalog: catalog)
        }
        let candidate = Review(id: UUID(), source: source, target: target,
            oldAction: catalog.first(where: { $0.address == source })?.action, newAction: newAction,
            captures: captures, generation: generation, catalogGeneration: environment.catalogGeneration(),
            expires: now.addingTimeInterval(300))
        let candidateView = DeckRebindingView(phase: .review, reviewID: candidate.id, source: source, target: target,
            oldAction: candidate.oldAction, newAction: newAction, rows: captures.map(\.row),
            message: "Review only these visible keys. No action will run. Starting this review ends Undo from the previous review; this session's new receipts last until another review or companion exit.")
        var largest = candidateView
        largest.phase = .unconfirmed
        largest.message = String(repeating: "x", count: 300)
        largest.rows = largest.rows.map { row in
            var row = row; row.message = String(repeating: "x", count: 300); row.receiptID = UUID(); row.undoAvailable = false
            row.observedSHA256 = String(repeating: "a", count: 64)
            row.outcome = .notAttempted; return row
        }
        guard try JSONEncoder().encode(DeckWire(deckEvent: "rebinding", request: UUID(), message: largest.message, rebinding: largest)).count <= DeckRebindingLimits.reviewBytes else {
            throw ModuleProblem("The complete contracts and selected key details exceed the 96 KiB review limit. Select fewer keys; nothing was truncated or changed.")
        }
        review = candidate; receipts = [:]; observations = [:]; view = candidateView
        publish(request: request)
    }
    private func apply(_ payload: DeckRebindingCommand, request: UUID, now: Date) throws {
        guard operation == nil, payload.contexts == nil, payload.source == nil, payload.target == nil,
              payload.receiptID == nil, let id = payload.reviewID, let candidate = review, candidate.id == id else {
            throw ModuleProblem("That reconnection review is not available for Apply.")
        }
        review = nil // A real Apply attempt consumes this exact review once.
        guard now < candidate.expires else { throw ModuleProblem("This review expired. Prepare a new review; nothing was changed.") }
        try validateCurrent(candidate)
        try requireAvailable(contexts: Set(candidate.captures.map { $0.slot.context }), addresses: [candidate.source, candidate.target])
        for capture in candidate.captures {
            guard let current = environment.snapshot(capture.slot.context), current.slot.revision == capture.slot.revision,
                  capture.matchesIdentity(current.slot), try DeckRebindingJSON.canonical(current.settings) == capture.beforeData else {
                throw ModuleProblem("A selected key changed after review. Prepare a fresh review; nothing was changed.")
            }
        }
        operation = .init(request: request, review: candidate, captures: candidate.captures, undoReceipt: nil, deadline: now.addingTimeInterval(10))
        view?.phase = .applying; view?.message = "Reading each key before its change. Stop ends future changes; it cannot retract an already sent write."
        publish(request: request); beginCurrent(now: now)
    }
    private func undo(_ payload: DeckRebindingCommand, request: UUID, now: Date) throws {
        guard operation == nil, payload.contexts == nil, payload.source == nil, payload.target == nil, payload.reviewID == nil,
              let receiptID = payload.receiptID, let receipt = receipts[receiptID], !receipt.undone else {
            throw ModuleProblem("That confirmed settings receipt is not available for Undo in this companion session.")
        }
        guard view?.rows.first(where: { $0.receiptID == receiptID })?.undoAvailable == true else {
            throw ModuleProblem("Undo the most recent confirmed row first; earlier receipts are retained in reverse order.")
        }
        try validateCurrent(receipt.review)
        let selected = Set([receipt.capture.slot.context]), addresses = Set([receipt.review.source, receipt.review.target])
        try requireAvailable(contexts: selected, addresses: addresses)
        if let currentOld = environment.catalog().first(where: { $0.address == receipt.review.source })?.action {
            guard let old = receipt.review.oldAction, try descriptor(currentOld) == descriptor(old) else {
                throw ModuleProblem("The original action's contract cannot be verified. Undo did not change the key.")
            }
        }
        let inverse = receipt.capture.inverse()
        guard let current = environment.snapshot(inverse.slot.context), inverse.matchesIdentity(current.slot),
              try DeckRebindingJSON.canonical(current.settings) == inverse.beforeData else {
            throw ModuleProblem("The key no longer has this receipt's complete after-settings. Undo will not overwrite another edit.")
        }
        operation = .init(request: request, review: receipt.review, captures: [inverse], undoReceipt: receiptID, deadline: now.addingTimeInterval(10))
        view?.phase = .applying
        view?.message = "Reading the exact current settings before restoring the prior object. An unavailable old action stays unavailable; no permission or action execution is restored."
        publish(request: request); beginCurrent(now: now)
    }
    private func requireAvailable(contexts: Set<String>, addresses: Set<PluginActionAddress>) throws {
        guard DeckRebindingLimits.admits(existing: environment.occupiedContexts(), adding: contexts) else {
            throw ModuleProblem("The 128-context pending/unconfirmed limit is full. Read back existing keys; no older barrier was removed.")
        }
        guard !environment.overlapsSave(contexts, addresses) else {
            throw ModuleProblem("An affected key has a pending or unconfirmed settings change. Reload it first.")
        }
        guard !environment.hasUnsettledWork(contexts, addresses) else {
            throw ModuleProblem("An affected request is active or has an interrupted, unknown outcome. Inspect that original work before reconnecting keys.")
        }
    }
    private func descriptor(_ action: PluginRegisteredAction) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(action)
    }
    private func validateCurrent(_ candidate: Review) throws {
        guard environment.generation() == candidate.generation,
              environment.catalogGeneration() == candidate.catalogGeneration,
              let current = environment.catalog().first(where: { $0.address == candidate.target })?.action,
              try descriptor(current) == descriptor(candidate.newAction) else {
            throw ModuleProblem("The connection or permitted action catalog changed. No further write is allowed from this review.")
        }
    }
    private func beginCurrent(now: Date) {
        guard var current = operation else { return }
        do {
            try validateCurrent(current.review)
            guard current.stopReason == nil else { finish(phase: .partial, message: current.stopReason!); return }
            guard !environment.hasUnsettledWork(reservedContexts, [current.review.source, current.review.target]),
                  let snapshot = environment.snapshot(current.current.slot.context), current.current.matchesIdentity(snapshot.slot) else {
                throw ModuleProblem("A selected key disappeared or affected work became unsettled. No further write was started.")
            }
            current.stage = .before; current.deadline = now.addingTimeInterval(10); operation = current
            updateRow(current.current.row.id, outcome: .applying, message: "Waiting for fresh complete before-settings.")
            publish()
            guard operation?.id == current.id, operation?.stopReason == nil else { return }
            environment.readSettings(current.current.slot.context)
        } catch { finish(phase: .conflict, message: error.localizedDescription) }
    }

    func readback(slot: DeckSlot, settings: [String: Any], now: Date = Date()) {
        guard let current = operation, slot.context == current.current.slot.context,
              current.stage == .before || current.stage == .after else { return }
        do {
            let capture = current.current
            guard capture.matchesIdentity(slot) else { throw ModuleProblem("The selected key's identity changed during the operation.") }
            let data = try DeckRebindingJSON.canonical(settings)
            if current.stage == .before {
                try validateCurrent(current.review)
                guard current.stopReason == nil else { stopBeforeDispatch(current.stopReason!); return }
                guard !environment.hasUnsettledWork(reservedContexts, [current.review.source, current.review.target]),
                      data == capture.beforeData else {
                    recordObserved(capture.row.id, data: data, settings: settings)
                    throw ModuleProblem("Fresh settings or work state differ from the reviewed before-snapshot. Nothing further was written.")
                }
                updateRow(capture.row.id, outcome: .applying, message: "Checking again before sending the complete settings write.")
                publish()
                guard let live = operation, live.id == current.id, live.index == current.index,
                      live.stage == .before, live.stopReason == nil else { return }
                try validateBeforeDispatch(live)
                if live.recordID == nil { persistIntent(live, now: now) }
                else { try dispatchPersisted(live, now: now) }
            } else {
                if data != capture.afterData {
                    recordObserved(capture.row.id, data: data, settings: settings)
                    persistOutcome(.conflict(observedData: data), now: now)
                } else { persistOutcome(.confirmed(observedData: data), now: now) }
            }
        } catch {
            if current.sent { uncertain(message: error.localizedDescription, now: now) }
            else { stopBeforeDispatch(error.localizedDescription) }
        }
    }
    private func validateBeforeDispatch(_ expected: Operation) throws {
        try validateCurrent(expected.review)
        let capture = expected.current
        guard !environment.hasUnsettledWork(reservedContexts, [expected.review.source, expected.review.target]),
              let fresh = environment.snapshot(capture.slot.context), capture.matchesIdentity(fresh.slot),
              try DeckRebindingJSON.canonical(fresh.settings) == capture.beforeData,
              let live = operation, live.id == expected.id, live.index == expected.index,
              live.stage == .before, live.stopReason == nil, !live.sent else {
            throw ModuleProblem("The final before-write snapshot or owner changed. Nothing further was written.")
        }
    }
    private func persistIntent(_ expected: Operation, now: Date) {
        guard var live = operation, live.id == expected.id, live.index == expected.index,
              live.stage == .before, live.recordID == nil, live.stopReason == nil else { return }
        live.stage = .persistIntent; operation = live
        environment.prepareWrite(live.current, live.request, live.undoReceipt != nil) { [weak self] result in
            guard let self, var current = self.operation, current.id == live.id,
                  current.index == live.index, current.stage == .persistIntent else { return }
            switch result {
            case .failure(let error):
                self.finish(phase: .conflict, message: "No settings write was sent because its durable intent could not be confirmed: " + error.localizedDescription)
            case .success(let id):
                current.recordID = id; self.operation = current
                if let reason = current.stopReason { self.stopBeforeDispatch(reason); return }
                do {
                    try self.validateCurrent(current.review)
                    guard let snapshot = self.environment.snapshot(current.current.slot.context),
                          current.current.matchesIdentity(snapshot.slot),
                          try DeckRebindingJSON.canonical(snapshot.settings) == current.current.beforeData,
                          !self.environment.hasUnsettledWork(self.reservedContexts, [current.review.source, current.review.target]) else {
                        throw ModuleProblem("The key, owner or work state changed while saving the intent. No write was sent.")
                    }
                    guard var next = self.operation, next.id == current.id, next.index == current.index,
                          next.stage == .persistIntent, next.recordID == id else { return }
                    if let reason = next.stopReason { self.stopBeforeDispatch(reason); return }
                    next.stage = .before; next.deadline = now.addingTimeInterval(10); self.operation = next
                    self.updateRow(current.current.row.id, outcome: .applying, message: "Intent saved. Reading fresh complete settings before dispatch.")
                    self.publish()
                    guard let fresh = self.operation, fresh.id == current.id, fresh.index == current.index,
                          fresh.stage == .before, fresh.stopReason == nil, fresh.recordID == id else { return }
                    // A pre-persistence or cached readback cannot authorize this
                    // write. Elgato must answer a newly requested before-read.
                    self.environment.readSettings(current.current.slot.context)
                } catch { self.stopBeforeDispatch(error.localizedDescription) }
            }
        }
    }
    private func dispatchPersisted(_ expected: Operation, now: Date) throws {
        try validateBeforeDispatch(expected)
        guard var live = operation, live.id == expected.id, live.index == expected.index,
              live.stage == .before, live.recordID != nil, live.stopReason == nil else { return }
        let object = try DeckRebindingJSON.object(live.current.afterData)
        try DeckRebindingJSON.validateWriteEnvelope(object, context: live.current.slot.context)
        live.stage = .after; live.sent = true; live.deadline = now.addingTimeInterval(10); operation = live
        environment.writeSettings(live.current.slot.context, object)
        guard let fresh = operation, fresh.id == live.id, fresh.index == live.index,
              fresh.stage == .after else { return }
        environment.readSettings(live.current.slot.context)
    }
    private func stopBeforeDispatch(_ message: String) {
        guard var current = operation else { return }
        guard !current.sent else { uncertain(message: message); return }
        current.stopReason = message; operation = current
        if current.recordID != nil { persistOutcome(.notSent) }
        else { finish(phase: .conflict, message: message) }
    }
    private func persistOutcome(_ outcome: DeckRecoveryLedger.SettingsOutcome, now: Date = Date()) {
        guard var current = operation, let recordID = current.recordID,
              current.stage != .persistOutcome else { return }
        current.stage = .persistOutcome; operation = current
        environment.finishWrite(recordID, outcome) { [weak self] result in
            guard let self, let live = self.operation, live.id == current.id,
                  live.index == current.index, live.recordID == recordID, live.stage == .persistOutcome else { return }
            switch result {
            case .failure(let error):
                self.environment.quarantine(live.current, live.request)
                self.updateRow(live.current.row.id, outcome: .unconfirmed,
                    message: "The settings outcome could not be durably saved: " + error.localizedDescription, undoAvailable: false)
                self.finish(phase: .unconfirmed, message: "Outcome persistence is unconfirmed. No further key or conditional Undo was started.")
            case .success:
                switch outcome {
                case .confirmed:
                    self.completeConfirmed(live, now: now)
                case .conflict:
                    self.updateRow(live.current.row.id, outcome: .conflict,
                        message: "Elgato returned a different complete settings object. Its observed hash and current values are retained; no automatic retry or rollback was sent.")
                    self.finish(phase: .partial, message: "Stopped at a settings conflict. Earlier confirmed rows remain changed; remaining rows were not attempted.")
                case .uncertain:
                    self.environment.quarantine(live.current, live.request)
                    self.updateRow(live.current.row.id, outcome: .unconfirmed, message: live.stopReason ?? "The sent write has no confirmed complete readback.", undoAvailable: false)
                    self.finish(phase: .unconfirmed, message: (live.stopReason ?? "Write outcome is uncertain.") + " New affected runs remain blocked until fresh settings; other rows were not attempted.")
                case .notSent:
                    self.finish(phase: .partial, message: live.stopReason ?? "No settings write was sent.")
                }
            }
        }
    }
    private func completeConfirmed(_ completed: Operation, now: Date) {
        var current = completed; let capture = current.current
        if let receiptID = current.undoReceipt {
            receipts[receiptID]?.undone = true
            updateRow(capture.row.id, outcome: .undone, message: "Exact previous settings object read back and durably recorded. This does not restore action availability or permissions.", undoAvailable: false)
        } else {
            let receiptID = UUID()
            receipts[receiptID] = .init(capture: capture, review: current.review)
            updateRow(capture.row.id, outcome: .confirmed, message: "Complete settings readback durably recorded, including unknown fields. This is not an atomic Elgato commit.", receiptID: receiptID, undoAvailable: true)
        }
        refreshUndoAvailability()
        do { try validateCurrent(current.review) } catch { current.stopReason = error.localizedDescription }
        if let reason = current.stopReason {
            operation = current; finish(phase: .partial, message: reason + " Confirmed rows retain separate receipts.")
        } else if current.index + 1 < current.captures.count {
            current.index += 1; current.recordID = nil; current.sent = false
            operation = current; beginCurrent(now: now)
        } else {
            operation = current
            finish(phase: current.undoReceipt == nil ? .complete : .undone,
                message: current.undoReceipt == nil ? "Selected visible keys individually read back and durably recorded. Hidden profiles were not assessed; conditional Undo remains session-only." : "Previous settings restored, read back and durably recorded. Nothing was invoked or granted.")
        }
    }
    func tick(now: Date = Date()) {
        guard let current = operation, now >= current.deadline else { return }
        switch current.stage {
        case .persistIntent, .persistOutcome:
            operation?.stopReason = current.stopReason ?? "Persistence exceeded the deadline. No future write will start; waiting for the actual callback."
        case .after: uncertain(message: "Elgato did not confirm the complete write before its deadline. Reload the original key; no retry was sent.", now: now)
        case .before: stopBeforeDispatch("Fresh before-settings did not arrive before the deadline. No further key was written.")
        }
    }
    func disconnected(_ message: String) {
        review = nil
        guard let current = operation else { return }
        switch current.stage {
        case .persistIntent, .persistOutcome: operation?.stopReason = message
        case .after: uncertain(message: message)
        case .before: stopBeforeDispatch(message + " No in-flight settings write was assumed or resumed.")
        }
    }
    func disappeared(_ context: String) {
        guard let current = operation, current.captures.contains(where: { $0.slot.context == context }) else { return }
        let reason = "A selected key disappeared. No further keys will be changed."
        if current.stage == .persistIntent || current.stage == .persistOutcome {
            operation?.stopReason = reason; return
        }
        if current.current.slot.context == context {
            if current.sent { uncertain(message: "The current key disappeared after its write. Show it and reload; its outcome is unconfirmed.") }
            else { stopBeforeDispatch("The selected key disappeared before its write. No further key was changed.") }
        } else {
            operation?.stopReason = reason
            if current.stage == .before { stopBeforeDispatch(reason) }
            else { view?.message = "A selected key disappeared; waiting for the current write before stopping future changes."; publish() }
        }
    }
    private func uncertain(message: String, now: Date = Date()) {
        guard var current = operation else { return }
        current.stopReason = message; operation = current
        persistOutcome(.uncertain, now: now)
    }
    private func updateRow(_ id: UUID, outcome: DeckRebindingRow.Outcome, message: String,
                           receiptID: UUID? = nil, undoAvailable: Bool? = nil) {
        guard let index = view?.rows.firstIndex(where: { $0.id == id }) else { return }
        view?.rows[index].outcome = outcome; view?.rows[index].message = boundedMessage(message)
        if let receiptID { view?.rows[index].receiptID = receiptID }
        if let undoAvailable { view?.rows[index].undoAvailable = undoAvailable }
    }
    private func recordObserved(_ id: UUID, data: Data, settings: [String: Any]) {
        guard let index = view?.rows.firstIndex(where: { $0.id == id }) else { return }
        observations[id] = data
        view?.rows[index].observedSHA256 = DeckRebindingJSON.sha(data)
        view?.rows[index].observed = try? DeckRebindingJSON.knownSettings(settings)
    }
    private func refreshUndoAvailability() {
        guard var value = view else { return }
        for index in value.rows.indices { value.rows[index].undoAvailable = false }
        if let index = value.rows.indices.reversed().first(where: { index in
            guard let receiptID = value.rows[index].receiptID, let receipt = receipts[receiptID] else { return false }
            return !receipt.undone
        }) { value.rows[index].undoAvailable = true }
        view = value
    }
    private func finish(phase: DeckRebindingView.Phase, message: String, request: UUID? = nil) {
        let originalRequest = operation?.request
        if let operation {
            for capture in operation.captures {
                if let row = view?.rows.first(where: { $0.id == capture.row.id }), [.pending, .applying].contains(row.outcome) {
                    updateRow(capture.row.id, outcome: .notAttempted, message: "No settings write was confirmed for this row; nothing will resume automatically.")
                }
            }
        }
        operation = nil; view?.phase = phase; view?.message = boundedMessage(message)
        publish(request: request ?? originalRequest)
    }
    private func reject(_ message: String, request: UUID?) {
        var failed = view ?? .init(phase: .rejected, message: "")
        if operation == nil {
            failed.phase = .rejected
            failed.message = boundedMessage(message + (receipts.isEmpty ? "" : " Previous confirmed results and session Undo are retained."))
            view = failed
        } else {
            failed.message = boundedMessage("Request rejected: " + message + " The current operation remains active; Stop is still available.")
        }
        emitBounded(failed, request: request)
    }
    private func publish(request: UUID? = nil) {
        let value = view ?? .init(phase: .closed, message: "No reconnection review is retained. Status read did not start or resume anything.")
        emitBounded(value, request: request ?? operation?.request)
    }
    private func boundedMessage(_ message: String) -> String {
        var result = String(message.prefix(300))
        while result.utf8.count > 300 { result.removeLast() }
        return result
    }
    private func emitBounded(_ input: DeckRebindingView, request: UUID?) {
        var value = input; value.message = boundedMessage(value.message)
        for index in value.rows.indices { value.rows[index].message = boundedMessage(value.rows[index].message) }
        func fits(_ view: DeckRebindingView) -> Bool {
            guard let data = DeckWire(deckEvent: "rebinding", request: request, message: view.message, rebinding: view).encoded() else { return false }
            return data.count <= DeckRebindingLimits.reviewBytes
        }
        if !fits(value) {
            // Never truncate captured contracts or original/proposed settings.
            // Optional observed current details can be withheld explicitly; the
            // complete canonical hash and companion-local object remain intact.
            for index in value.rows.indices where value.rows[index].observed != nil {
                value.rows[index].observed = nil
                value.rows[index].message = boundedMessage("Current values exceed this view's budget; the complete observed hash is shown and full settings remain in the companion. " + value.rows[index].message)
            }
        }
        if !fits(value) {
            // An unexpected reporting overflow must still carry outcomes and
            // receipt identities. This is a clearly incomplete fallback, never
            // another mutation, authorization or optimistic completion.
            value.oldAction = nil; value.newAction = nil
            for index in value.rows.indices { value.rows[index].before = [:]; value.rows[index].after = [:] }
            value.message = "Detailed reporting exceeded its size limit. Outcomes, receipts and hashes follow; complete settings remain companion-local. No retry or rollback was started."
        }
        assert(fits(value), "Bounded reconnection outcome must fit the private bridge")
        environment.emit(value, request)
    }
}
