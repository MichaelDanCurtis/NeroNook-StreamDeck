import XCTest
import NookPluginSDK
@testable import StreamDeckPlugin

final class RunTests: XCTestCase {
    let entry = PluginCatalogEntry(address: .init("fixture.workflows", "run"), action: .init("run", title: "Run workflow", effect: .localChange, cancellable: true, completionTimeoutSeconds: 3600))
    func testStopTargetsOnlyOriginalRunAndWaitsForConfirmation() throws {
        var runs = DeckRuns(); let now = Date(), id = try runs.begin(context: "start-key", entry: entry, now: now)
        XCTAssertEqual(try runs.cancel(entry.address), id)
        XCTAssertNil(try runs.cancel(entry.address))
        XCTAssertTrue(runs.latest(entry.address)!.active)
        XCTAssertEqual(runs.latest(entry.address)?.status, "Stopping")
        XCTAssertTrue(runs.receive(.init(.update, requestID: id, update: .init(.running, message: "Waiting for remote stop"))))
        XCTAssertEqual(runs.latest(entry.address)?.update.phase, .cancelling)
        XCTAssertTrue(runs.receive(.init(.update, requestID: id, update: .init(.cancelled, message: "Remote stop confirmed")), now: now.addingTimeInterval(12)))
        XCTAssertEqual(runs.latest(entry.address)?.status, "Stopped")
        XCTAssertFalse(runs.latest(entry.address)!.active)
        XCTAssertEqual(runs.latest(entry.address)?.elapsed(now.addingTimeInterval(80)), "0:12")
        XCTAssertFalse(runs.receive(.init(.update, requestID: id, update: .init(.running))))
    }
    func testDuplicateKeysAndForeignUpdatesCannotStartOrStopAnotherRun() throws {
        var runs = DeckRuns(); let id = try runs.begin(context: "first", entry: entry)
        XCTAssertThrowsError(try runs.begin(context: "second", entry: entry))
        XCTAssertNil(try runs.cancel(.init("fixture.workflows", "other")))
        XCTAssertFalse(runs.receive(.init(.update, requestID: UUID(), update: .init(.cancelled))))
        XCTAssertFalse(runs.receive(.init(.update, requestID: id, address: .init("fixture.other", "run"), update: .init(.succeeded))))
        XCTAssertEqual(runs.latest(entry.address)?.id, id)
    }
    func testDisplayReviewAndMeasuredStepsAndUnknownSurviveConnectionLossWithoutReplay() throws {
        var runs = DeckRuns(); let id = try runs.begin(context: "key", entry: entry)
        let display = PluginRunDisplay(title: "Workflow", step: "Review target", completedSteps: 2, totalSteps: 4, needsReview: true)
        XCTAssertTrue(runs.receive(.init(.update, requestID: id, update: .init(.running, display: display))))
        XCTAssertEqual(runs.latest(entry.address)?.status, "Review in Nook")
        runs.disconnected()
        XCTAssertEqual(runs.latest(entry.address)?.status, "Check outcome")
        XCTAssertNil(try runs.cancel(entry.address))
        XCTAssertFalse(runs.receive(.init(.update, requestID: id, update: .init(.succeeded))))
    }
    func testMalformedProgressAndOutputAreNotAcceptedAndSuccessCanWinStopRace() throws {
        var runs = DeckRuns(); let id = try runs.begin(context: "key", entry: entry)
        XCTAssertFalse(runs.receive(.init(.update, requestID: id, update: .init(.running, display: .init(title: "Bad", completedSteps: 5, totalSteps: 4)))))
        XCTAssertFalse(runs.receive(.init(.update, requestID: id, update: .init(.succeeded, values: ["unexpected": .string("data")]))))
        XCTAssertEqual(try runs.cancel(entry.address), id)
        XCTAssertTrue(runs.receive(.init(.update, requestID: id, update: .init(.succeeded))))
        XCTAssertEqual(runs.latest(entry.address)?.status, "Done")
    }
    func testStopMappingRequiresCancellableExactDescriptorWithoutNewArguments() throws {
        let stop = DeckSlot(context: "stop", action: "cafe.nero.neronook.stop", device: "deck", controller: "Keypad", column: 1, row: 0, revision: "version", settings: [:])
        let settings = ["provider":entry.address.plugin, "name":entry.address.name, "arguments":"{}", "label":"Stop Fuego"]
        try DeckMapping.validate(settings: settings, slot: stop, catalog: [entry])
        var uncancellable = entry; uncancellable.action!.cancellable = false
        XCTAssertThrowsError(try DeckMapping.validate(settings: settings, slot: stop, catalog: [uncancellable]))
        var invalid = settings; invalid["arguments"] = "{\"id\":\"other\"}"
        XCTAssertThrowsError(try DeckMapping.validate(settings: invalid, slot: stop, catalog: [entry]))
    }
}
