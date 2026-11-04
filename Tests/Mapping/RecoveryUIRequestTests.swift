import XCTest
import Foundation
@testable import StreamDeckPlugin

final class RecoveryUIRequestTests: XCTestCase {
    func testWrongRequestOrPeerCannotAcknowledgeRecoveryReview() {
        var state = DeckRecoveryUIRequests()
        let request = UUID(), peer = UUID()
        XCTAssertTrue(state.begin(id: request, epoch: peer, command: "recovery_prepare"))
        XCTAssertFalse(state.acknowledge(id: UUID(), epoch: peer))
        XCTAssertFalse(state.acknowledge(id: request, epoch: UUID()))
        XCTAssertTrue(state.waiting)
        XCTAssertTrue(state.acknowledge(id: request, epoch: peer))
        XCTAssertFalse(state.waiting)
    }
    func testTimeoutBlocksConfirmationUntilExplicitFreshStatusAcknowledgement() {
        var state = DeckRecoveryUIRequests()
        let request = UUID(), peer = UUID()
        XCTAssertTrue(state.begin(id: request, epoch: peer, command: "recovery_confirm"))
        XCTAssertTrue(state.timeout(id: request, epoch: peer))
        XCTAssertTrue(state.uncertain); XCTAssertFalse(state.waiting)
        XCTAssertFalse(state.begin(id: UUID(), epoch: peer, command: "recovery_confirm"))
        XCTAssertFalse(state.begin(id: UUID(), epoch: peer, command: "recovery_prepare"))
        let read = UUID()
        XCTAssertTrue(state.begin(id: read, epoch: peer, command: "recovery_status"))
        XCTAssertFalse(state.acknowledge(id: request, epoch: peer), "Late prior result cannot replace a newer read")
        XCTAssertTrue(state.uncertain)
        XCTAssertTrue(state.acknowledge(id: read, epoch: peer)); XCTAssertFalse(state.uncertain)
    }
    func testCloseSupersedesReviewAndLatePrepareCannotReopenIt() {
        var state = DeckRecoveryUIRequests()
        let prepare = UUID(), close = UUID(), peer = UUID()
        XCTAssertTrue(state.begin(id: prepare, epoch: peer, command: "recovery_prepare"))
        XCTAssertTrue(state.begin(id: close, epoch: peer, command: "recovery_close"))
        XCTAssertFalse(state.acknowledge(id: prepare, epoch: peer))
        XCTAssertEqual(state.pending?.command, "recovery_close")
        XCTAssertTrue(state.acknowledge(id: close, epoch: peer))
        XCTAssertFalse(state.acknowledge(id: prepare, epoch: peer))
    }
    func testDisconnectResetDoesNotAcceptOldConnectionResponseOrUnknownCommand() {
        var state = DeckRecoveryUIRequests()
        let request = UUID(), oldPeer = UUID(), newPeer = UUID()
        XCTAssertTrue(state.begin(id: request, epoch: oldPeer, command: "recovery_prepare"))
        state.reset()
        XCTAssertFalse(state.acknowledge(id: request, epoch: oldPeer))
        XCTAssertTrue(state.begin(id: request, epoch: newPeer, command: "recovery_status"))
        XCTAssertFalse(state.acknowledge(id: request, epoch: oldPeer))
        XCTAssertTrue(state.acknowledge(id: request, epoch: newPeer))
        XCTAssertFalse(state.begin(id: UUID(), epoch: newPeer, command: "invoke"))
    }
    func testRepeatedControlClicksCannotAccumulateOutstandingStatusOrCloseRequests() {
        var state = DeckRecoveryUIRequests()
        let peer = UUID(), prepare = UUID(), close = UUID(), status = UUID()
        XCTAssertTrue(state.begin(id: prepare, epoch: peer, command: "recovery_prepare"))
        XCTAssertFalse(state.begin(id: UUID(), epoch: peer, command: "recovery_status"))
        XCTAssertTrue(state.begin(id: close, epoch: peer, command: "recovery_close"))
        XCTAssertFalse(state.begin(id: UUID(), epoch: peer, command: "recovery_close"))
        XCTAssertFalse(state.begin(id: UUID(), epoch: peer, command: "recovery_status"))
        XCTAssertTrue(state.acknowledge(id: close, epoch: peer))
        XCTAssertTrue(state.begin(id: status, epoch: peer, command: "recovery_status"))
        XCTAssertFalse(state.begin(id: UUID(), epoch: peer, command: "recovery_status"))
        XCTAssertEqual(state.pending?.id, status)
    }
    func testRecoveryWireRetainsPagedMetadataAndCompleteKnownReviewFields() throws {
        let request = UUID(), review = UUID(), record = UUID()
        let arguments = String(repeating: "café 🌿", count: 400)
        let before = ["provider": "authored.old", "name": "before", "arguments": arguments, "label": "Keep this label"]
        let after = ["provider": "authored.new", "name": "after", "arguments": arguments, "label": "Keep this label"]
        var view = DeckRecoveryView(phase: .review, message: "Read-only current settings comparison")
        view.offset = 16; view.nextOffset = 32; view.totalRecordCount = 40
        view.reviewID = review; view.recordID = record; view.before = before; view.after = after; view.current = after
        view.beforeSHA256 = String(repeating: "a", count: 64); view.afterSHA256 = String(repeating: "b", count: 64)
        view.currentSHA256 = view.afterSHA256; view.match = .after; view.canConfirm = true
        let wire = DeckWire(deckEvent: "recovery", request: request, recovery: view)
        let data = try XCTUnwrap(wire.encoded())
        XCTAssertLessThan(data.count, DeckRecoveryLimits.reviewBytes)
        let decoded = try JSONDecoder().decode(DeckWire.self, from: data)
        XCTAssertEqual(decoded.request, request); XCTAssertEqual(decoded.recovery?.reviewID, review)
        XCTAssertEqual(decoded.recovery?.offset, 16); XCTAssertEqual(decoded.recovery?.nextOffset, 32)
        XCTAssertEqual(decoded.recovery?.totalRecordCount, 40)
        XCTAssertEqual(decoded.recovery?.before, before); XCTAssertEqual(decoded.recovery?.after, after)
        XCTAssertEqual(decoded.recovery?.current?["arguments"], arguments, "Do not trim captured review fields to fit a display")
    }
}
