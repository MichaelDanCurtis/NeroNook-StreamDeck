import XCTest
import Foundation
import NookPluginSDK
@testable import StreamDeckPlugin

@MainActor final class RebindingTests: XCTestCase {
    @MainActor private final class Rig {
        let source = PluginActionAddress("fixture.flows", "old")
        let target = PluginActionAddress("fixture.flows", "new")
        var catalog: [PluginCatalogEntry] = []
        var generation: UUID? = UUID()
        var catalogGeneration = UUID()
        var slots: [String: DeckRebindingSlot] = [:]
        var occupied = Set<String>()
        var overlaps = false
        var unsettled = false
        var reads: [String] = []
        var writes: [(String, Data)] = []
        var quarantines: [DeckRebindingCapture] = []
        var emitted: [(DeckRebindingView, UUID?)] = []
        var onEmit: ((DeckRebindingView) -> Void)?
        var delayPrepare = false
        var delayFinish = false
        var failPrepare = false
        var failFinish = false
        var autoPostIntentRead = true
        private var autoReadNext = false
        var prepared: [(capture: DeckRebindingCapture, request: UUID, undo: Bool)] = []
        var outcomes: [(id: UUID, outcome: DeckRecoveryLedger.SettingsOutcome)] = []
        private var prepares: [@MainActor (Result<UUID, Error>) -> Void] = []
        private var finishes: [@MainActor (Result<Void, Error>) -> Void] = []
        private var completedPrepare: (@MainActor (Result<UUID, Error>) -> Void)?
        private var completedFinish: (@MainActor (Result<Void, Error>) -> Void)?
        let epoch = Date(timeIntervalSince1970: 1_600_000_000)
        lazy var engine: DeckRebinding = DeckRebinding(environment: .init(
            snapshot: { [unowned self] in slots[$0] }, catalog: { [unowned self] in catalog },
            generation: { [unowned self] in generation }, catalogGeneration: { [unowned self] in catalogGeneration },
            occupiedContexts: { [unowned self] in occupied }, overlapsSave: { [unowned self] _, _ in overlaps },
            hasUnsettledWork: { [unowned self] _, _ in unsettled },
            readSettings: { [unowned self] context in
                reads.append(context)
                if autoReadNext && autoPostIntentRead, let snapshot = slots[context] {
                    autoReadNext = false
                    engine.readback(slot: snapshot.slot, settings: snapshot.settings, now: epoch)
                }
            },
            writeSettings: { [unowned self] context, value in writes.append((context, try! DeckRebindingJSON.canonical(value))) },
            prepareWrite: { [unowned self] capture, request, undo, callback in
                prepared.append((capture, request, undo)); prepares.append(callback)
                if !delayPrepare { completePrepare(failPrepare ? .failure(ModuleProblem("Authored intent failure")) : .success(UUID())) }
            },
            finishWrite: { [unowned self] id, outcome, callback in
                autoReadNext = false
                outcomes.append((id, outcome)); finishes.append(callback)
                if !delayFinish { completeFinish(failFinish ? .failure(ModuleProblem("Authored outcome failure")) : .success(())) }
            },
            quarantine: { [unowned self] capture, _ in quarantines.append(capture); occupied.insert(capture.slot.context); overlaps = true },
            emit: { [unowned self] value, request in emitted.append((value, request)); onEmit?(value) }))
        func completePrepare(_ result: Result<UUID, Error> = .success(UUID())) {
            let callback = prepares.removeFirst()
            completedPrepare = callback
            if case .success = result { autoReadNext = true }
            callback(result)
        }
        func completeFinish(_ result: Result<Void, Error> = .success(())) {
            let callback = finishes.removeFirst(); completedFinish = callback; callback(result)
        }
        func repeatPrepare(_ result: Result<UUID, Error>) { completedPrepare?(result) }
        func repeatFinish() { completedFinish?(.success(())) }
        init(oldAvailable: Bool = true) {
            let old = PluginRegisteredAction("old", title: "Same title", effect: .localChange,
                cancellable: true, timeoutSeconds: 300, completionTimeoutSeconds: 86400)
            let new = PluginRegisteredAction("new", title: "Same title", effect: .readOnly,
                cancellable: true, timeoutSeconds: 300, completionTimeoutSeconds: 300)
            catalog = [.init(address: target, action: new)]
            if oldAvailable { catalog.insert(.init(address: source, action: old), at: 0) }
            add("run", action: "cafe.nero.neronook.run", column: 0)
            add("stop", action: "cafe.nero.neronook.stop", column: 1)
        }
        func add(_ context: String, action: String = "cafe.nero.neronook.run", column: Int = 0, arguments: String = "{}") {
            let known = ["provider": source.plugin, "name": source.name, "arguments": arguments, "label": " Keep label "]
            var complete: [String: Any] = known
            complete["future"] = ["null": NSNull(), "nested": [true, 7, "café 🌿"]] as [String: Any]
            complete["futureNumber"] = 2.25
            let slot = DeckSlot(context: context, action: action, device: "authored-deck", controller: "Keypad",
                column: column, row: 0, revision: UUID().uuidString, settings: known)
            slots[context] = .init(slot: slot, settings: complete)
        }
        @discardableResult func command(_ name: String, _ payload: DeckRebindingCommand = .init(), at date: Date? = nil) -> UUID {
            let request = UUID(); engine.handle(name, payload: payload, request: request, now: date ?? epoch); return request
        }
        @discardableResult func prepare(_ contexts: [String] = ["run", "stop"]) throws -> UUID {
            command("rebind_prepare", .init(contexts: contexts, source: source, target: target))
            return try XCTUnwrap(emitted.last?.0.reviewID)
        }
        func submit(_ context: String, settings: [String: Any]? = nil, at date: Date? = nil) throws {
            let previous = try XCTUnwrap(slots[context])
            let raw = settings ?? previous.settings
            var slot = previous.slot; slot.revision = UUID().uuidString; slot.settings = try DeckRebindingJSON.knownSettings(raw)
            slots[context] = .init(slot: slot, settings: raw)
            engine.readback(slot: slot, settings: raw, now: date ?? epoch)
        }
        func confirmLatestWrite() throws {
            let written = try XCTUnwrap(writes.last)
            try submit(written.0, settings: DeckRebindingJSON.object(written.1))
        }
        func finishBoth() throws {
            let id = try prepare(); command("rebind_apply", .init(reviewID: id))
            try submit("run"); try confirmLatestWrite(); try submit("stop"); try confirmLatestWrite()
        }
    }

    func testStatusAndEveryImmediateFailureEchoRequestWithoutReadsWritesOrResume() throws {
        let rig = Rig()
        let emptyRequest = rig.command("rebind_status")
        XCTAssertEqual(rig.emitted.last?.1, emptyRequest); XCTAssertEqual(rig.emitted.last?.0.phase, .closed)
        let rejected = rig.command("rebind_prepare", .init(contexts: [], source: rig.source, target: rig.target))
        XCTAssertEqual(rig.emitted.last?.1, rejected); XCTAssertEqual(rig.emitted.last?.0.phase, .rejected)
        let review = try rig.prepare(["run"])
        let statusRequest = rig.command("rebind_status")
        XCTAssertEqual(rig.emitted.last?.1, statusRequest); XCTAssertEqual(rig.emitted.last?.0.reviewID, review)
        let closeRequest = rig.command("rebind_close", .init(reviewID: review))
        XCTAssertEqual(rig.emitted.last?.1, closeRequest); XCTAssertEqual(rig.emitted.last?.0.phase, .closed)
        XCTAssertTrue(rig.reads.isEmpty); XCTAssertTrue(rig.writes.isEmpty)
    }
    func testPrepareUsesExactAddressesAndDisclosesUnknownOldContractWithoutPublication() throws {
        let rig = Rig(oldAvailable: false); _ = try rig.prepare()
        let value = try XCTUnwrap(rig.engine.view)
        XCTAssertEqual(value.phase, .review); XCTAssertNil(value.oldAction)
        XCTAssertEqual(value.newAction?.id, "new"); XCTAssertEqual(value.rows.count, 2)
        XCTAssertTrue(value.rows.allSatisfy { $0.before["name"] == "old" && $0.after["name"] == "new" && $0.receiptID == nil })
        XCTAssertTrue(value.rows.allSatisfy { $0.before["label"] == $0.after["label"] && $0.before["arguments"] == $0.after["arguments"] })
        XCTAssertTrue(rig.reads.isEmpty); XCTAssertTrue(rig.writes.isEmpty)
        let wrong = Rig(); wrong.command("rebind_prepare", .init(contexts: ["run"], source: .init("fixture.flows", "same-title-but-different"), target: wrong.target))
        XCTAssertEqual(wrong.emitted.last?.0.phase, .rejected); XCTAssertTrue(wrong.writes.isEmpty)
    }
    func testApplyIsSerialReadsBeforeEveryWriteAndConfirmsCompleteUnknownSettings() throws {
        let rig = Rig(); let originalRun = try DeckRebindingJSON.canonical(rig.slots["run"]!.settings)
        let review = try rig.prepare(); rig.command("rebind_apply", .init(reviewID: review))
        XCTAssertEqual(rig.reads, ["run"]); XCTAssertTrue(rig.writes.isEmpty)
        XCTAssertTrue(rig.engine.blocks(context: "unselected", address: rig.source))
        XCTAssertTrue(rig.engine.blocks(context: "unselected", address: rig.target))
        XCTAssertTrue(rig.engine.blocks(context: "stop", address: .init("fixture.other", "action")))
        try rig.submit("run"); XCTAssertEqual(rig.writes.count, 1); XCTAssertEqual(rig.writes.first?.0, "run")
        try rig.confirmLatestWrite(); XCTAssertEqual(rig.reads.last, "stop"); XCTAssertEqual(rig.writes.count, 1)
        try rig.submit("stop"); try rig.confirmLatestWrite()
        XCTAssertEqual(rig.engine.view?.phase, .complete)
        XCTAssertEqual(rig.engine.view?.rows.map(\.outcome), [.confirmed, .confirmed])
        let after = try DeckRebindingJSON.object(rig.writes[0].1)
        var inverse = after; inverse["provider"] = rig.source.plugin; inverse["name"] = rig.source.name
        XCTAssertEqual(try DeckRebindingJSON.canonical(inverse), originalRun)
        XCTAssertFalse(rig.engine.blocks(context: "run", address: rig.target))
        XCTAssertEqual(rig.engine.view?.rows.map(\.undoAvailable), [false, true])
    }
    func testStaleSnapshotConsumesApplyAndCatalogChangeBeforeWriteDoesNotMutate() throws {
        let rig = Rig(), review = try rig.prepare(["run"])
        try rig.submit("run") // Fresh same-value readback still changes review revision.
        let failed = rig.command("rebind_apply", .init(reviewID: review))
        XCTAssertEqual(rig.emitted.last?.1, failed); XCTAssertEqual(rig.emitted.last?.0.phase, .rejected)
        XCTAssertTrue(rig.writes.isEmpty)
        rig.command("rebind_apply", .init(reviewID: review)); XCTAssertEqual(rig.emitted.last?.0.phase, .rejected)
        let other = Rig(), otherID = try other.prepare(["run"])
        other.command("rebind_apply", .init(reviewID: otherID)); other.catalogGeneration = UUID()
        try other.submit("run")
        XCTAssertEqual(other.engine.view?.phase, .conflict); XCTAssertTrue(other.writes.isEmpty)
    }
    func testFreshBeforeMismatchDoesNotWriteAndCompleteAfterMismatchStopsFollowingRows() throws {
        let before = Rig(), id = try before.prepare(); before.command("rebind_apply", .init(reviewID: id))
        var changed = before.slots["run"]!.settings; changed["label"] = "Someone edited"
        try before.submit("run", settings: changed)
        XCTAssertTrue(before.writes.isEmpty); XCTAssertEqual(before.engine.view?.phase, .conflict)
        let after = Rig(), afterID = try after.prepare(); after.command("rebind_apply", .init(reviewID: afterID))
        try after.submit("run")
        var returned = try DeckRebindingJSON.object(after.writes[0].1); returned["futureNumber"] = 99
        try after.submit("run", settings: returned)
        XCTAssertEqual(after.writes.count, 1); XCTAssertEqual(after.engine.view?.phase, .partial)
        XCTAssertEqual(after.engine.view?.rows.map(\.outcome), [.conflict, .notAttempted])
        XCTAssertTrue(after.engine.view?.rows.allSatisfy { $0.receiptID == nil } == true)
    }
    func testStopWaitsForInflightOutcomeAndNeverAutomaticallyUndoesConfirmedRow() throws {
        let rig = Rig(), id = try rig.prepare(); rig.command("rebind_apply", .init(reviewID: id))
        try rig.submit("run"); let close = rig.command("rebind_close", .init(reviewID: id))
        XCTAssertEqual(rig.emitted.last?.1, close); XCTAssertEqual(rig.writes.count, 1)
        XCTAssertTrue(rig.engine.blocks(context: "stop", address: rig.target))
        try rig.confirmLatestWrite()
        XCTAssertEqual(rig.writes.count, 1); XCTAssertEqual(rig.engine.view?.phase, .partial)
        XCTAssertEqual(rig.engine.view?.rows.map(\.outcome), [.confirmed, .notAttempted])
        XCTAssertTrue(rig.engine.view?.rows[0].undoAvailable == true)
    }
    func testWriteTimeoutQuarantinesOriginalAndReplacementWithoutRetryButBeforeTimeoutDoesNot() throws {
        let rig = Rig(), id = try rig.prepare(); rig.command("rebind_apply", .init(reviewID: id))
        try rig.submit("run"); rig.engine.tick(now: rig.epoch.addingTimeInterval(11))
        XCTAssertEqual(rig.writes.count, 1); XCTAssertEqual(rig.quarantines.count, 1)
        XCTAssertEqual(rig.quarantines[0].source, rig.source); XCTAssertEqual(rig.quarantines[0].target, rig.target)
        XCTAssertEqual(rig.engine.view?.rows.map(\.outcome), [.unconfirmed, .notAttempted])
        rig.command("rebind_status"); XCTAssertEqual(rig.writes.count, 1)
        let fresh = Rig(), freshID = try fresh.prepare(); fresh.command("rebind_apply", .init(reviewID: freshID))
        fresh.engine.tick(now: fresh.epoch.addingTimeInterval(11))
        XCTAssertTrue(fresh.writes.isEmpty); XCTAssertTrue(fresh.quarantines.isEmpty)
    }
    func testDisconnectAndDisappearanceAfterWriteRemainUnconfirmedAndNeverResume() throws {
        for disconnect in [true, false] {
            let rig = Rig(), id = try rig.prepare(); rig.command("rebind_apply", .init(reviewID: id))
            try rig.submit("run")
            if disconnect { rig.engine.disconnected("Authored disconnect") } else { rig.engine.disappeared("run") }
            XCTAssertEqual(rig.quarantines.count, 1); XCTAssertEqual(rig.engine.view?.phase, .unconfirmed)
            try rig.confirmLatestWrite() // A late callback is data, not old-operation continuation.
            XCTAssertEqual(rig.writes.count, 1); XCTAssertEqual(rig.engine.view?.phase, .unconfirmed)
        }
    }
    func testUndoUsesReverseConfirmedOrderAndRestoresExactCanonicalObjectsIncludingInertOldAddress() throws {
        let rig = Rig(oldAvailable: false)
        let originalRun = try DeckRebindingJSON.canonical(rig.slots["run"]!.settings)
        let originalStop = try DeckRebindingJSON.canonical(rig.slots["stop"]!.settings)
        try rig.finishBoth()
        let first = try XCTUnwrap(rig.engine.view?.rows[0].receiptID), second = try XCTUnwrap(rig.engine.view?.rows[1].receiptID)
        rig.command("rebind_undo", .init(receiptID: first))
        XCTAssertEqual(rig.emitted.last?.0.phase, .rejected); XCTAssertEqual(rig.writes.count, 2)
        rig.command("rebind_undo", .init(receiptID: second)); try rig.submit("stop")
        XCTAssertEqual(rig.writes.last?.1, originalStop); try rig.confirmLatestWrite()
        XCTAssertEqual(rig.engine.view?.rows[1].outcome, .undone)
        XCTAssertTrue(rig.engine.view?.rows[0].undoAvailable == true)
        rig.command("rebind_undo", .init(receiptID: first)); try rig.submit("run")
        XCTAssertEqual(rig.writes.last?.1, originalRun); try rig.confirmLatestWrite()
        XCTAssertEqual(rig.engine.view?.phase, .undone)
        XCTAssertFalse(rig.catalog.contains { $0.address == rig.source })
    }
    func testUndoRefusesExternalPostimageEditAndNewReviewEndsOldReceiptsOnlyAfterValidPreparation() throws {
        let rig = Rig(); try rig.finishBoth()
        let receipt = try XCTUnwrap(rig.engine.view?.rows.last?.receiptID)
        var edited = rig.slots["stop"]!.settings; edited["futureNumber"] = 42
        try rig.submit("stop", settings: edited)
        rig.command("rebind_undo", .init(receiptID: receipt)); XCTAssertEqual(rig.writes.count, 2)
        XCTAssertEqual(rig.emitted.last?.0.phase, .rejected)
        let another = Rig(); try another.finishBoth()
        let oldReceipt = try XCTUnwrap(another.engine.view?.rows.last?.receiptID)
        another.add("next")
        _ = try another.prepare(["next"])
        another.command("rebind_undo", .init(receiptID: oldReceipt))
        XCTAssertEqual(another.emitted.last?.0.phase, .rejected); XCTAssertEqual(another.writes.count, 2)
    }
    func testActiveInterruptedAndReservationAdmissionBoundRefuseWithoutEviction() throws {
        let rig = Rig(); rig.unsettled = true
        rig.command("rebind_prepare", .init(contexts: ["run"], source: rig.source, target: rig.target))
        XCTAssertEqual(rig.emitted.last?.0.phase, .rejected); XCTAssertTrue(rig.writes.isEmpty)
        let full = Rig(); full.occupied = Set((0..<128).map { "unresolved-\($0)" })
        let before = full.occupied
        full.command("rebind_prepare", .init(contexts: ["run"], source: full.source, target: full.target))
        XCTAssertEqual(full.emitted.last?.0.phase, .rejected); XCTAssertEqual(full.occupied, before)
        XCTAssertFalse(DeckRebindingLimits.admits(existing: before, adding: ["129th"]))
        XCTAssertTrue(DeckRebindingLimits.admits(existing: before, adding: ["unresolved-0"]))
        var runs = DeckRuns()
        let entry = rig.catalog.first(where: { $0.address == rig.source })!
        _ = try runs.begin(context: "authored-run", entry: entry)
        XCTAssertTrue(runs.hasUnsettled(contexts: [], addresses: [rig.source]))
        runs.disconnected()
        XCTAssertTrue(runs.hasUnsettled(contexts: ["authored-run"], addresses: []))
        XCTAssertFalse(runs.hasActive(context: "authored-run", addresses: [rig.source]))
    }
    func testAllSelectedRowsMustFitAndValidateWithoutSilentArgumentOrLabelChanges() throws {
        let invalid = Rig(); var action = invalid.catalog.first(where: { $0.address == invalid.target })!
        action.action!.input = .init([.init("required", .string)])
        invalid.catalog[invalid.catalog.firstIndex(where: { $0.address == invalid.target })!] = action
        invalid.command("rebind_prepare", .init(contexts: ["run"], source: invalid.source, target: invalid.target))
        XCTAssertEqual(invalid.emitted.last?.0.phase, .rejected); XCTAssertTrue(invalid.writes.isEmpty)
        let large = Rig(); let arguments = "{}" + String(repeating: " ", count: 8000)
        for index in 0..<16 { large.add("large-\(index)", column: index % 4, arguments: arguments) }
        large.command("rebind_prepare", .init(contexts: (0..<16).map { "large-\($0)" }, source: large.source, target: large.target))
        XCTAssertEqual(large.emitted.last?.0.phase, .rejected); XCTAssertTrue(large.reads.isEmpty); XCTAssertTrue(large.writes.isEmpty)
        XCTAssertTrue(large.emitted.last?.0.message.contains("96 KiB") == true)
    }
    func testReentrantCloseDisconnectCatalogOrSnapshotChangeBeforeDispatchSendsNoWrite() throws {
        for change in ["close", "disconnect", "catalog", "snapshot", "work"] {
            let rig = Rig(), id = try rig.prepare(["run"])
            rig.command("rebind_apply", .init(reviewID: id))
            rig.onEmit = { value in
                guard value.rows.contains(where: { $0.message.contains("Checking again before sending") }) else { return }
                rig.onEmit = nil
                switch change {
                case "close": rig.command("rebind_close", .init(reviewID: id))
                case "disconnect": rig.engine.disconnected("Authored synchronous disconnect before dispatch")
                case "catalog": rig.catalogGeneration = UUID()
                case "work": rig.unsettled = true
                default:
                    let previous = rig.slots["run"]!
                    var raw = previous.settings; raw["label"] = "Reentrant edit"
                    var slot = previous.slot; slot.settings["label"] = "Reentrant edit"
                    rig.slots["run"] = .init(slot: slot, settings: raw)
                }
            }
            try rig.submit("run")
            XCTAssertTrue(rig.writes.isEmpty, change)
            XCTAssertTrue(rig.quarantines.isEmpty, change)
            XCTAssertFalse(rig.engine.blocks(context: "run", address: rig.target), change)
        }
    }
    func testRejectedConcurrentCommandKeepsActivePhaseStopAndStatusCorrelation() throws {
        let rig = Rig(), id = try rig.prepare(["run"])
        rig.command("rebind_apply", .init(reviewID: id))
        let rejected = rig.command("rebind_prepare", .init(contexts: ["run"], source: rig.source, target: rig.target))
        XCTAssertEqual(rig.emitted.last?.1, rejected)
        XCTAssertEqual(rig.emitted.last?.0.phase, .applying)
        XCTAssertTrue(rig.emitted.last?.0.message.contains("Stop is still available") == true)
        XCTAssertTrue(rig.engine.blocks(context: "run", address: rig.target))
        let status = rig.command("rebind_status")
        XCTAssertEqual(rig.emitted.last?.1, status); XCTAssertEqual(rig.emitted.last?.0.phase, .applying)
        rig.command("rebind_close", .init(reviewID: id)); XCTAssertTrue(rig.writes.isEmpty)
    }
    func testInterruptedWorkFenceSurvivesDisplayHistoryTrimAndOverflowIsConservative() throws {
        let rig = Rig(), original = rig.catalog.first(where: { $0.address == rig.source })!
        var runs = DeckRuns(); let interrupted = try runs.begin(context: "old-context", entry: original)
        runs.disconnected()
        for index in 0..<100 {
            let name = "completed_\(index)"
            let entry = PluginCatalogEntry(address: .init("fixture.completed", name), action: .init(name, title: "Authored completed"))
            let id = try runs.begin(context: "completed-context-\(index)", entry: entry)
            XCTAssertTrue(runs.receive(.init(.update, requestID: id, update: .init(.succeeded))))
        }
        XCTAssertFalse(runs.records.contains { $0.id == interrupted })
        XCTAssertTrue(runs.hasUnsettled(contexts: ["old-context"], addresses: []))
        XCTAssertTrue(runs.hasUnsettled(contexts: [], addresses: [rig.source]))
        XCTAssertFalse(runs.hasUnsettled(contexts: ["unrelated"], addresses: [.init("fixture.unrelated", "action")]))
        var overflow = DeckRuns()
        for index in 0..<129 {
            let name = "unknown_\(index)"
            let entry = PluginCatalogEntry(address: .init("fixture.unknown", name), action: .init(name, title: "Authored unknown"))
            _ = try overflow.begin(context: "unknown-context-\(index)", entry: entry); overflow.disconnected()
        }
        XCTAssertTrue(overflow.hasUnsettled(contexts: ["never-seen"], addresses: [.init("fixture.unrelated", "action")]))
        // Existing ordinary run admission is deliberately unchanged.
        XCTAssertNoThrow(try overflow.begin(context: "ordinary-context", entry: original))
    }
    func testFullWriteEnvelopeIncludingFramingIsRejectedBeforeAnyEffect() throws {
        let rig = Rig(); let previous = rig.slots["run"]!
        var raw = previous.settings; raw["padding"] = ""
        let base = try DeckRebindingJSON.canonical(raw).count
        raw["padding"] = String(repeating: "x", count: 131_040 - base)
        XCTAssertLessThanOrEqual(try DeckRebindingJSON.canonical(raw).count, 131_072)
        XCTAssertGreaterThan(try JSONSerialization.data(withJSONObject: ["event": "setSettings", "context": "run", "payload": raw]).count, 131_072)
        rig.slots["run"] = .init(slot: previous.slot, settings: raw)
        rig.command("rebind_prepare", .init(contexts: ["run"], source: rig.source, target: rig.target))
        XCTAssertEqual(rig.emitted.last?.0.phase, .rejected)
        XCTAssertTrue(rig.emitted.last?.0.message.contains("framing limit") == true)
        XCTAssertTrue(rig.reads.isEmpty); XCTAssertTrue(rig.writes.isEmpty)
    }
    func testLargeObservedConflictReportsCompleteHashAndExplicitDetailOmissionWithinWireBudget() throws {
        let rig = Rig(); let args = "{}" + String(repeating: " ", count: 1800)
        for index in 0..<16 { rig.add("row-\(index)", column: index % 4, arguments: args) }
        let id = try rig.prepare((0..<16).map { "row-\($0)" })
        rig.command("rebind_apply", .init(reviewID: id)); try rig.submit("row-0")
        var observed = try DeckRebindingJSON.object(rig.writes[0].1)
        for name in ["provider", "name", "arguments", "field", "label"] { observed[name] = String(repeating: "x", count: 8192) }
        try rig.submit("row-0", settings: observed)
        let emitted = try XCTUnwrap(rig.emitted.last)
        XCTAssertEqual(emitted.0.phase, .partial)
        XCTAssertEqual(emitted.0.rows[0].observedSHA256, DeckRebindingJSON.sha(try DeckRebindingJSON.canonical(observed)))
        XCTAssertNil(emitted.0.rows[0].observed)
        XCTAssertTrue(emitted.0.rows[0].message.contains("exceed this view's budget"))
        let wire = DeckWire(deckEvent: "rebinding", request: emitted.1, message: emitted.0.message, rebinding: emitted.0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(wire.encoded()).count, DeckRebindingLimits.reviewBytes)
        XCTAssertEqual(rig.writes.count, 1); XCTAssertTrue(rig.quarantines.isEmpty)
    }
    func testDelayedDurableIntentRequiresANewBeforeReadAndNeverDispatchesFromCachedSnapshot() throws {
        let rig = Rig(); rig.delayPrepare = true; rig.autoPostIntentRead = false
        let id = try rig.prepare(["run"]), request = rig.command("rebind_apply", .init(reviewID: id))
        try rig.submit("run")
        XCTAssertEqual(rig.prepared.count, 1); XCTAssertEqual(rig.prepared[0].request, request)
        XCTAssertFalse(rig.prepared[0].undo); XCTAssertTrue(rig.writes.isEmpty)
        XCTAssertTrue(rig.engine.blocks(context: "run", address: rig.target))
        rig.completePrepare()
        XCTAssertEqual(rig.reads, ["run", "run"]); XCTAssertTrue(rig.writes.isEmpty)
        try rig.submit("run")
        XCTAssertEqual(rig.writes.count, 1)
        try rig.confirmLatestWrite()
        XCTAssertEqual(rig.engine.view?.phase, .complete)
        XCTAssertEqual(rig.outcomes.count, 1)
        if case .confirmed(let observed) = rig.outcomes[0].outcome { XCTAssertEqual(observed, rig.writes[0].1) }
        else { XCTFail("Matching readback must be durably confirmed") }
        let changed = Rig(); changed.autoPostIntentRead = false
        let changedID = try changed.prepare(["run"]); changed.command("rebind_apply", .init(reviewID: changedID)); try changed.submit("run")
        XCTAssertTrue(changed.writes.isEmpty)
        var raw = changed.slots["run"]!.settings; raw["futureNumber"] = 987
        try changed.submit("run", settings: raw)
        XCTAssertTrue(changed.writes.isEmpty)
        XCTAssertEqual(changed.engine.view?.rows[0].observedSHA256, DeckRebindingJSON.sha(try DeckRebindingJSON.canonical(raw)))
        if case .notSent = changed.outcomes[0].outcome {} else { XCTFail("Fresh post-intent conflict must never dispatch") }
    }
    func testCloseDisconnectAndDisappearanceHoldReservationsUntilIntentAndNotSentCallbacksReturn() throws {
        for reason in ["close", "disconnect", "disappear"] {
            let rig = Rig(); rig.delayPrepare = true; rig.delayFinish = true
            let id = try rig.prepare(), request = rig.command("rebind_apply", .init(reviewID: id))
            try rig.submit("run")
            if reason == "close" { rig.command("rebind_close", .init(reviewID: id)) }
            else if reason == "disconnect" { rig.engine.disconnected("Authored disconnect during persistence") }
            else { rig.engine.disappeared("stop") }
            XCTAssertTrue(rig.engine.blocks(context: "stop", address: rig.target), reason)
            XCTAssertTrue(rig.writes.isEmpty, reason)
            rig.completePrepare()
            XCTAssertEqual(rig.prepared.first?.request, request)
            XCTAssertEqual(rig.outcomes.count, 1, reason)
            if case .notSent = rig.outcomes[0].outcome {} else { XCTFail(reason) }
            XCTAssertTrue(rig.engine.blocks(context: "stop", address: rig.target), reason)
            rig.completeFinish()
            XCTAssertTrue(rig.writes.isEmpty, reason); XCTAssertTrue(rig.quarantines.isEmpty, reason)
            XCTAssertFalse(rig.engine.blocks(context: "stop", address: rig.target), reason)
            XCTAssertEqual(rig.engine.view?.rows.map(\.outcome), [.notAttempted, .notAttempted], reason)
        }
    }
    func testIntentFailureAndPostIntentOwnerOrCompleteSettingsDriftNeverSendSettings() throws {
        let failed = Rig(); failed.failPrepare = true
        let failedID = try failed.prepare(["run"]); failed.command("rebind_apply", .init(reviewID: failedID)); try failed.submit("run")
        XCTAssertTrue(failed.writes.isEmpty); XCTAssertTrue(failed.outcomes.isEmpty)
        XCTAssertEqual(failed.engine.view?.phase, .conflict)
        for change in ["generation", "catalog", "settings", "work"] {
            let rig = Rig(); rig.delayPrepare = true
            let id = try rig.prepare(["run"]); rig.command("rebind_apply", .init(reviewID: id)); try rig.submit("run")
            switch change {
            case "generation": rig.generation = UUID()
            case "catalog": rig.catalogGeneration = UUID()
            case "work": rig.unsettled = true
            default:
                let snapshot = rig.slots["run"]!; var raw = snapshot.settings; raw["futureNumber"] = 123
                rig.slots["run"] = .init(slot: snapshot.slot, settings: raw)
            }
            rig.completePrepare()
            XCTAssertTrue(rig.writes.isEmpty, change); XCTAssertEqual(rig.outcomes.count, 1, change)
            if case .notSent = rig.outcomes[0].outcome {} else { XCTFail(change) }
        }
    }
    func testOutcomeMustPersistBeforeConfirmationNextRowOrConditionalUndoAndFailureQuarantines() throws {
        let rig = Rig(); rig.delayFinish = true
        let id = try rig.prepare(); rig.command("rebind_apply", .init(reviewID: id)); try rig.submit("run")
        try rig.confirmLatestWrite(); try rig.confirmLatestWrite()
        XCTAssertEqual(rig.outcomes.count, 1); XCTAssertEqual(rig.writes.count, 1)
        XCTAssertEqual(rig.engine.view?.rows[0].outcome, .applying)
        XCTAssertNil(rig.engine.view?.rows[0].receiptID)
        XCTAssertTrue(rig.engine.blocks(context: "stop", address: rig.target))
        rig.completeFinish()
        XCTAssertEqual(rig.engine.view?.rows[0].outcome, .confirmed)
        XCTAssertEqual(rig.reads.last, "stop"); XCTAssertEqual(rig.writes.count, 1)
        let failed = Rig(); failed.failFinish = true
        let failedID = try failed.prepare(); failed.command("rebind_apply", .init(reviewID: failedID)); try failed.submit("run"); try failed.confirmLatestWrite()
        XCTAssertEqual(failed.writes.count, 1); XCTAssertEqual(failed.quarantines.count, 1)
        XCTAssertEqual(failed.engine.view?.phase, .unconfirmed)
        XCTAssertNil(failed.engine.view?.rows[0].receiptID)
        XCTAssertTrue(failed.engine.view?.rows.allSatisfy { !$0.undoAvailable } == true)
    }
    func testUndoHasItsOwnDurableInverseIntentAndWaitsForPersistedReadbackOutcome() throws {
        let rig = Rig(); let original = try DeckRebindingJSON.canonical(rig.slots["run"]!.settings)
        let id = try rig.prepare(["run"]); rig.command("rebind_apply", .init(reviewID: id)); try rig.submit("run"); try rig.confirmLatestWrite()
        let receipt = try XCTUnwrap(rig.engine.view?.rows[0].receiptID)
        rig.delayPrepare = true; rig.delayFinish = true
        let request = rig.command("rebind_undo", .init(receiptID: receipt)); try rig.submit("run")
        XCTAssertEqual(rig.writes.count, 1); XCTAssertTrue(rig.prepared[1].undo)
        XCTAssertEqual(rig.prepared[1].request, request); XCTAssertEqual(rig.prepared[1].capture.afterData, original)
        rig.completePrepare(); XCTAssertEqual(rig.writes.count, 2); XCTAssertEqual(rig.writes[1].1, original)
        try rig.confirmLatestWrite()
        XCTAssertEqual(rig.engine.view?.rows[0].outcome, .applying)
        rig.completeFinish()
        XCTAssertEqual(rig.engine.view?.rows[0].outcome, .undone)
        XCTAssertEqual(rig.engine.view?.phase, .undone)
    }
    func testPersistenceTimeoutRetainsOperationUntilRealCallbackAndAfterWriteDisconnectCannotBecomeNotSent() throws {
        let before = Rig(); before.delayPrepare = true
        let id = try before.prepare(["run"]); before.command("rebind_apply", .init(reviewID: id)); try before.submit("run")
        before.engine.tick(now: before.epoch.addingTimeInterval(11))
        XCTAssertTrue(before.engine.blocks(context: "run", address: before.target)); XCTAssertTrue(before.writes.isEmpty)
        before.completePrepare()
        XCTAssertTrue(before.writes.isEmpty)
        if case .notSent = before.outcomes[0].outcome {} else { XCTFail("Unsent intent must not be dispatched after timeout") }
        let after = Rig(); after.delayFinish = true
        let afterID = try after.prepare(["run"]); after.command("rebind_apply", .init(reviewID: afterID)); try after.submit("run")
        after.engine.disconnected("Authored after-send disconnect")
        XCTAssertTrue(after.engine.blocks(context: "run", address: after.target))
        if case .uncertain = after.outcomes[0].outcome {} else { XCTFail("Sent write cannot become notSent") }
        after.completeFinish()
        XCTAssertEqual(after.quarantines.count, 1); XCTAssertEqual(after.engine.view?.phase, .unconfirmed)
    }
    func testDuplicateAndLatePersistenceCallbacksCannotDispatchTwiceOrAdvanceAnotherOperation() throws {
        let rig = Rig(); rig.delayPrepare = true; rig.delayFinish = true
        let id = try rig.prepare(["run"]); rig.command("rebind_apply", .init(reviewID: id)); try rig.submit("run")
        let record = UUID(); rig.completePrepare(.success(record)); rig.repeatPrepare(.success(record))
        XCTAssertEqual(rig.writes.count, 1)
        try rig.confirmLatestWrite(); XCTAssertEqual(rig.outcomes.count, 1)
        rig.completeFinish(); rig.repeatFinish()
        XCTAssertEqual(rig.engine.view?.phase, .complete); XCTAssertEqual(rig.writes.count, 1)
        rig.add("next"); let next = try rig.prepare(["next"]); rig.command("rebind_apply", .init(reviewID: next))
        rig.repeatPrepare(.success(record)); rig.repeatFinish()
        XCTAssertEqual(rig.writes.count, 1); XCTAssertEqual(rig.outcomes.count, 1)
        XCTAssertTrue(rig.engine.blocks(context: "next", address: rig.target))
    }
}
