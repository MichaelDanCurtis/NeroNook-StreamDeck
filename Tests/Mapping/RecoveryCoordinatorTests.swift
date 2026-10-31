import XCTest
import Foundation
import NookPluginSDK
@testable import StreamDeckPlugin
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Actual cold ledger + coordinator, with authored visible readbacks only.
/// The injected environment has no settings-write, invoke or cancel capability.
@MainActor final class RecoveryCoordinatorTests: XCTestCase {
    private typealias Ledger = DeckRecoveryLedger
    private let beforeAddress = PluginActionAddress("local.neronook.automations", "before")

    @MainActor private final class Rig {
        var generation: UUID? = UUID()
        var visible: [String: DeckRebindingSlot] = [:]
        var reads: [String] = []
        var emitted: [(DeckRecoveryView, UUID)] = []
        var onEmit: ((DeckRecoveryView, UUID) -> Void)?
        lazy var coordinator = DeckRecoveryCoordinator(environment: .init(
            snapshot: { [unowned self] in visible[$0] },
            generation: { [unowned self] in generation },
            readSettings: { [unowned self] in reads.append($0) },
            emit: { [unowned self] value, request in
                emitted.append((value, request)); onEmit?(value, request)
            }))
    }
    private struct Fixture {
        let rig: Rig
        let directory: URL
        let recordID: UUID
        let runID: UUID?
        let historicalSlot: Ledger.Slot
        let beforeData: Data
        let afterData: Data
        let originalBytes: Data
    }
    private func settings(_ name: String) -> [String: Any] {
        ["provider": "local.neronook.automations", "name": name, "arguments": "{}",
         "unknown": ["nested": [1.25, NSNull(), true], "authored": "café 🌿"]]
    }
    private func visible(context: String, raw: [String: Any]) throws -> DeckRebindingSlot {
        .init(slot: .init(context: context, action: "cafe.nero.neronook.run",
            device: "authored-visible-device", controller: "Keypad", column: 2, row: 1,
            revision: "authored-visible-revision", settings: try DeckRebindingJSON.knownSettings(raw)), settings: raw)
    }
    private func disk(_ fixture: Fixture) throws -> Data {
        try Data(contentsOf: fixture.directory.appendingPathComponent(Ledger.filename))
    }
    private func fixture(withRun: Bool = false) async throws -> Fixture {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let parent = URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("nero-deck-coordinator-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("authored-recovery")
        let ledger = try await Ledger.open(directory: directory)
        let historical = Ledger.Slot(context: "historical-context", action: "cafe.nero.neronook.run",
            device: "authored-historical-device", controller: "Keypad", row: 0, column: 0,
            revision: "authored-historical-revision")
        let before = try DeckRebindingJSON.canonical(settings("before"))
        let after = try DeckRebindingJSON.canonical(settings("after"))
        let record = try await ledger.prepareSettings(.init(id: UUID(), requestID: UUID(), kind: .rebind,
            slot: historical, oldAddress: beforeAddress,
            newAddress: .init("local.neronook.automations", "after"), beforeData: before, afterData: after, parentID: nil))
        let runID: UUID? = withRun ? UUID() : nil
        if let runID {
            _ = try await ledger.prepareRun(.init(id: runID, slot: historical, address: beforeAddress,
                descriptorSHA256: String(repeating: "a", count: 64)))
        }
        let warm = try await ledger.listRecords()
        await ledger.close() // cold coordinator must acquire the real exclusive ledger lock
        let bytes = try Data(contentsOf: directory.appendingPathComponent(Ledger.filename))
        let rig = Rig()
        await rig.coordinator.load(directory: directory)
        XCTAssertTrue(rig.coordinator.ready)
        XCTAssertNotEqual(rig.coordinator.snapshot?.sessionID, warm.sessionID)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(Ledger.filename)), bytes)
        return .init(rig: rig, directory: directory, recordID: record.id, runID: runID,
            historicalSlot: historical, beforeData: before, afterData: after, originalBytes: bytes)
    }
    private func review(_ fixture: Fixture, key: DeckRebindingSlot) throws -> DeckRecoveryView {
        let rig = fixture.rig, request = UUID()
        rig.visible[key.slot.context] = key
        rig.coordinator.handle("recovery_prepare", payload: .init(recordID: fixture.recordID,
            context: key.slot.context, revision: key.slot.revision), request: request)
        XCTAssertEqual(rig.reads.last, key.slot.context)
        rig.coordinator.readback(slot: key.slot, settings: key.settings)
        let response = try XCTUnwrap(rig.emitted.last { $0.1 == request }?.0)
        XCTAssertEqual(response.phase, .review); XCTAssertTrue(response.canConfirm)
        XCTAssertNotNil(response.reviewID)
        return response
    }
    private func beginConfirmation(_ fixture: Fixture, reviewID: UUID, key: DeckRebindingSlot,
                                   request: UUID) {
        fixture.rig.coordinator.handle("recovery_confirm", payload: .init(reviewID: reviewID), request: request)
        fixture.rig.coordinator.readback(slot: key.slot, settings: key.settings)
    }

    func testStatusBeforeLoadRejectsThenReportsActualColdRecordsAfterLoad() async throws {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let parent = URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("nero-deck-status-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("authored-recovery")
        let seed = try await Ledger.open(directory: directory)
        let slot = Ledger.Slot(context: "authored-history", action: "cafe.nero.neronook.run",
            device: "authored-device", controller: "Keypad", row: 0, column: 0, revision: "authored-revision")
        let record = try await seed.prepareSettings(.init(id: UUID(), requestID: UUID(), kind: .save,
            slot: slot, oldAddress: beforeAddress, newAddress: .init("local.neronook.automations", "after"),
            beforeData: try DeckRebindingJSON.canonical(settings("before")),
            afterData: try DeckRebindingJSON.canonical(settings("after")), parentID: nil))
        await seed.close()
        let original = try Data(contentsOf: directory.appendingPathComponent(Ledger.filename))
        let rig = Rig(), before = UUID()
        rig.coordinator.handle("recovery_status", payload: .init(), request: before)
        XCTAssertFalse(rig.coordinator.ready); XCTAssertNil(rig.coordinator.snapshot)
        let loading = try XCTUnwrap(rig.emitted.last { $0.1 == before }?.0)
        XCTAssertEqual(loading.phase, .rejected)
        XCTAssertTrue(loading.message.contains("Loading"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(Ledger.filename)), original)
        await rig.coordinator.load(directory: directory)
        let after = UUID()
        rig.coordinator.handle("recovery_status", payload: .init(), request: after)
        XCTAssertTrue(rig.coordinator.ready)
        let loaded = try XCTUnwrap(rig.emitted.last { $0.1 == after }?.0)
        XCTAssertEqual(loaded.phase, .status); XCTAssertEqual(loaded.totalRecordCount, 1)
        XCTAssertEqual(loaded.records.first?.id, record.id)
        XCTAssertEqual(loaded.records.first?.unresolved, true)
        XCTAssertEqual(loaded.records.first?.cold, true)
        XCTAssertTrue(rig.reads.isEmpty)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(Ledger.filename)), original)
    }

    func testColdContextAndUnsolicitedReadbackCannotClearUnknownEvidence() async throws {
        let fixture = try await fixture(withRun: true), rig = fixture.rig
        let key = try visible(context: fixture.historicalSlot.context, raw: settings("after"))
        rig.visible[key.slot.context] = key
        rig.coordinator.readback(slot: key.slot, settings: key.settings)
        XCTAssertTrue(rig.reads.isEmpty); XCTAssertTrue(rig.emitted.isEmpty)
        XCTAssertTrue(rig.coordinator.blocks(context: key.slot.context, addresses: [beforeAddress]))
        XCTAssertTrue(rig.coordinator.blocksRun(context: key.slot.context, address: beforeAddress))
        XCTAssertTrue(try XCTUnwrap(rig.coordinator.snapshot?.settings.first).unresolved)
        XCTAssertTrue(try XCTUnwrap(rig.coordinator.snapshot?.runs.first).unresolved)
        XCTAssertEqual(try disk(fixture), fixture.originalBytes)
    }

    func testQueuedCloseDisconnectGenerationAndFullSettingsChangesKeepIntentUnresolved() async throws {
        for interruption in ["close", "disconnect", "generation", "manual-unknown-field"] {
            let fixture = try await fixture(), rig = fixture.rig
            let key = try visible(context: "explicit-visible-context", raw: settings("after"))
            let disclosure = try review(fixture, key: key), id = try XCTUnwrap(disclosure.reviewID)
            let request = UUID(), done = expectation(description: "correlated rejection: " + interruption)
            var final: DeckRecoveryView?
            rig.onEmit = { value, reply in
                if reply == request { final = value; done.fulfill() }
            }
            beginConfirmation(fixture, reviewID: id, key: key, request: request)
            // No await: perturb the genuine owner before its queued Task can acquire storage.
            switch interruption {
            case "close": rig.coordinator.handle("recovery_close", payload: .init(reviewID: id), request: UUID())
            case "disconnect": rig.coordinator.disconnected()
            case "generation": rig.generation = UUID()
            default:
                var raw = key.settings; raw["unknown"] = ["external": "manual edit"]
                rig.visible[key.slot.context] = .init(slot: key.slot, settings: raw)
            }
            await fulfillment(of: [done], timeout: 5)
            rig.onEmit = nil
            XCTAssertEqual(final?.phase, .rejected, interruption)
            let record = try XCTUnwrap(rig.coordinator.snapshot?.settings.first)
            XCTAssertTrue(record.unresolved, interruption); XCTAssertEqual(record.state, .intent)
            XCTAssertNil(record.reassociatedSlot); XCTAssertNil(record.observedData)
            XCTAssertEqual(try disk(fixture), fixture.originalBytes, interruption)
        }
    }

    func testChangedConfirmationReadbackRefusesBeforeMetadataMutation() async throws {
        let fixture = try await fixture(), rig = fixture.rig
        let key = try visible(context: "explicit-visible-context", raw: settings("after"))
        let disclosure = try review(fixture, key: key), request = UUID()
        let current = try visible(context: key.slot.context, raw: settings("manual-later"))
        rig.visible[current.slot.context] = current
        beginConfirmation(fixture, reviewID: try XCTUnwrap(disclosure.reviewID), key: current, request: request)
        XCTAssertEqual(rig.emitted.last { $0.1 == request }?.0.phase, .rejected)
        XCTAssertTrue(try XCTUnwrap(rig.coordinator.snapshot?.settings.first).unresolved)
        XCTAssertEqual(try disk(fixture), fixture.originalBytes)
    }

    func testExplicitDifferentReassociationKeepsManualSettingsAndUnknownRunSeparate() async throws {
        let fixture = try await fixture(withRun: true), rig = fixture.rig
        let key = try visible(context: "explicit-new-context", raw: settings("manual-current"))
        let current = try DeckRebindingJSON.canonical(key.settings)
        let disclosure = try review(fixture, key: key)
        XCTAssertEqual(disclosure.match, .different)
        XCTAssertEqual(disclosure.currentSHA256, DeckRebindingJSON.sha(current))
        XCTAssertEqual(disclosure.beforeSHA256, DeckRebindingJSON.sha(fixture.beforeData))
        XCTAssertEqual(disclosure.afterSHA256, DeckRebindingJSON.sha(fixture.afterData))
        let request = UUID(), done = expectation(description: "explicit read-only reconciliation")
        var final: DeckRecoveryView?
        rig.onEmit = { value, reply in
            if reply == request { final = value; done.fulfill() }
        }
        beginConfirmation(fixture, reviewID: try XCTUnwrap(disclosure.reviewID), key: key, request: request)
        await fulfillment(of: [done], timeout: 5)
        rig.onEmit = nil
        XCTAssertEqual(final?.phase, .complete)
        let snapshot = try XCTUnwrap(rig.coordinator.snapshot)
        let record = try XCTUnwrap(snapshot.settings.first)
        XCTAssertEqual(record.state, .reconciledDifferent); XCTAssertFalse(record.unresolved)
        XCTAssertEqual(record.slot, fixture.historicalSlot)
        XCTAssertEqual(record.reassociatedSlot, DeckRecoveryCoordinator.slot(key.slot))
        XCTAssertEqual(record.observedData, current)
        XCTAssertEqual(record.beforeData, fixture.beforeData); XCTAssertEqual(record.afterData, fixture.afterData)
        XCTAssertEqual(try DeckRebindingJSON.canonical(try XCTUnwrap(rig.visible[key.slot.context]).settings), current)
        let run = try XCTUnwrap(snapshot.runs.first)
        XCTAssertEqual(run.id, fixture.runID); XCTAssertEqual(run.phase, .running)
        XCTAssertTrue(run.unresolved); XCTAssertTrue(run.cancelIDs.isEmpty)
        XCTAssertTrue(rig.coordinator.blocksRun(context: fixture.historicalSlot.context, address: beforeAddress))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: disk(fixture)) as? [String: Any])
        let rows = try XCTUnwrap(raw["settings"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["state"] as? String, "reconciledDifferent")
        XCTAssertEqual(rows.first?["observedData"] as? String, current.base64EncodedString())
        XCTAssertEqual(rig.reads, [key.slot.context, key.slot.context])
    }
}
