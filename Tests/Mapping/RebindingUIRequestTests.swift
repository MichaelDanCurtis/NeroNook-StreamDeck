import XCTest
@testable import StreamDeckPlugin

final class RebindingUIRequestTests: XCTestCase {
    func testOnlyExactRequestAndPeerEpochAcknowledgeWhileProgressCannotClearPending() {
        var state = DeckRebindingUIRequests()
        let request = UUID(), epoch = UUID()
        XCTAssertTrue(state.begin(id: request, epoch: epoch, command: "rebind_apply"))
        XCTAssertTrue(state.waiting)
        XCTAssertFalse(state.acknowledge(id: nil, epoch: epoch))
        XCTAssertFalse(state.acknowledge(id: UUID(), epoch: epoch))
        XCTAssertFalse(state.acknowledge(id: request, epoch: UUID()))
        XCTAssertTrue(state.waiting)
        XCTAssertFalse(state.begin(id: UUID(), epoch: epoch, command: "rebind_undo"))
        XCTAssertTrue(state.acknowledge(id: request, epoch: epoch))
        XCTAssertFalse(state.waiting)
        XCTAssertFalse(state.uncertain)
    }
    func testTimeoutKeepsUncertaintyAndOnlyReadStatusOrCloseCanReplaceItWithoutRetry() {
        var state = DeckRebindingUIRequests()
        let request = UUID(), epoch = UUID(), status = UUID()
        XCTAssertTrue(state.begin(id: request, epoch: epoch, command: "rebind_apply"))
        XCTAssertFalse(state.timeout(id: request, epoch: UUID()))
        XCTAssertTrue(state.timeout(id: request, epoch: epoch))
        XCTAssertFalse(state.waiting)
        XCTAssertTrue(state.uncertain)
        XCTAssertEqual(state.pending?.id, request)
        for command in ["rebind_prepare", "rebind_apply", "rebind_undo"] {
            XCTAssertFalse(state.begin(id: UUID(), epoch: epoch, command: command))
        }
        XCTAssertTrue(state.begin(id: status, epoch: epoch, command: "rebind_status"))
        XCTAssertTrue(state.uncertain)
        XCTAssertFalse(state.acknowledge(id: request, epoch: epoch))
        XCTAssertTrue(state.acknowledge(id: status, epoch: epoch))
        XCTAssertFalse(state.uncertain)
    }
    func testLateExactAcknowledgementResolvesTimeoutButDisconnectRetiresOldSession() {
        var state = DeckRebindingUIRequests()
        let request = UUID(), epoch = UUID()
        XCTAssertTrue(state.begin(id: request, epoch: epoch, command: "rebind_prepare"))
        XCTAssertTrue(state.timeout(id: request, epoch: epoch))
        XCTAssertTrue(state.acknowledge(id: request, epoch: epoch))
        XCTAssertFalse(state.uncertain)
        XCTAssertTrue(state.begin(id: UUID(), epoch: epoch, command: "rebind_apply"))
        XCTAssertTrue(state.begin(id: UUID(), epoch: epoch, command: "rebind_close"))
        state.reset()
        XCTAssertNil(state.pending)
        XCTAssertFalse(state.waiting)
        XCTAssertFalse(state.uncertain)
        XCTAssertFalse(state.acknowledge(id: request, epoch: epoch))
    }

    @MainActor func testActualModuleReceiverDoesNotAcknowledgeUnrelatedFrames() {
        let model = ModuleApp(), request = UUID(), review = UUID()
        XCTAssertTrue(model.rebindRequests.begin(id: request, epoch: model.rebindPeerEpoch, command: "rebind_prepare"))
        let view = DeckRebindingView(phase: .review, reviewID: review, message: "Review authored keys")
        model.receiveDeck(.init(deckEvent: "rebinding", request: UUID(), rebinding: view))
        XCTAssertNil(model.rebinding)
        XCTAssertTrue(model.rebindRequestPending)
        model.receiveDeck(.init(deckEvent: "rebinding", request: request, rebinding: view))
        XCTAssertEqual(model.rebinding?.reviewID, review)
        XCTAssertFalse(model.rebindRequestPending)
    }

    @MainActor func testActualModuleProgressKeepsApplyAcknowledgementAndRejectsOtherReviews() {
        let model = ModuleApp(), request = UUID(), review = UUID()
        model.rebinding = .init(phase: .review, reviewID: review, message: "Reviewed authored keys")
        XCTAssertTrue(model.rebindRequests.begin(id: request, epoch: model.rebindPeerEpoch, command: "rebind_apply"))
        model.receiveDeck(.init(deckEvent: "rebinding", rebinding: .init(phase: .applying, reviewID: review, message: "Reading current settings")))
        XCTAssertEqual(model.rebinding?.phase, .applying)
        XCTAssertTrue(model.rebindRequestPending)
        model.receiveDeck(.init(deckEvent: "rebinding", rebinding: .init(phase: .complete, reviewID: UUID(), message: "Unrelated result")))
        XCTAssertEqual(model.rebinding?.phase, .applying)
        XCTAssertTrue(model.rebindRequestPending)
        model.receiveDeck(.init(deckEvent: "rebinding", request: request, rebinding: .init(phase: .applying, reviewID: review, message: "Apply acknowledged")))
        XCTAssertFalse(model.rebindRequestPending)
    }
}
