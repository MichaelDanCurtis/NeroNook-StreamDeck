import XCTest
import Foundation
import NookPluginSDK
@testable import StreamDeckPlugin

/// Presentation lifecycle tests only. Authored replies are not companion plans,
/// native approval, current provider authority or proof of a settings write.
final class DeckRebindingPresentationTests: XCTestCase {
    private static let target = PluginCatalogEntry(address: .init("authored.provider", "flow_current"),
        action: .init("flow_current", title: "Current authored publication", effect: .readOnly,
                      cancellable: true, timeoutSeconds: 300, completionTimeoutSeconds: 300))
    private struct Harness {
        var presentation = DeckRebindingPresentation()
        var requests = DeckRebindingUIRequests()
        var catalog = PluginCatalogAccumulator()
        var peer = UUID()
        init() throws {
            presentation.peerChanged(to: peer)
            try replaceCatalog([DeckRebindingPresentationTests.target])
        }
        mutating func replaceCatalog(_ entries: [PluginCatalogEntry]) throws {
            presentation.catalogStarted()
            let generation = UUID()
            XCTAssertFalse(try catalog.receive(.init(.catalog, requestID: generation, catalog: [])))
            for entry in entries { XCTAssertFalse(try catalog.receive(.init(.catalog, requestID: generation, catalog: [entry]))) }
            XCTAssertTrue(try catalog.receive(.init(.catalog, requestID: generation, complete: true)))
            presentation.catalogCompleted()
        }
        mutating func begin(_ id: UUID = UUID()) -> UUID? {
            guard presentation.beginPrepare(request: id, peer: peer, target: DeckRebindingPresentationTests.target) else { return nil }
            guard requests.begin(id: id, epoch: peer, command: "rebind_prepare") else {
                presentation.abandonPrepare(request: id); return nil
            }
            return id
        }
        mutating func receive(_ view: DeckRebindingView, request: UUID?, from epoch: UUID? = nil) {
            let incomingPeer = epoch ?? peer
            let acknowledged = requests.acknowledge(id: request, epoch: incomingPeer)
            presentation.receive(view, request: request, peer: incomingPeer, acknowledged: acknowledged)
        }
        func canApply(_ view: DeckRebindingView?) -> Bool {
            presentation.canApply(view, peer: peer, catalog: catalog.entries)
        }
    }
    private func review(id: UUID = UUID(), phase: DeckRebindingView.Phase = .review) -> DeckRebindingView {
        let before = ["provider": "authored.provider", "name": "flow_legacy", "arguments": "{}"]
        let after = ["provider": "authored.provider", "name": "flow_current", "arguments": "{}"]
        let row = DeckRebindingRow(id: UUID(), context: "authored-visible-key", action: "cafe.nero.neronook.run",
            device: "authored-deck", controller: "Keypad", row: 0, column: 2, revision: "authored-settings-revision",
            before: before, after: after, beforeSHA256: String(repeating: "a", count: 64),
            afterSHA256: String(repeating: "b", count: 64), unknownFieldCount: 2)
        return .init(phase: phase, reviewID: id, source: .init("authored.provider", "flow_legacy"),
                     target: Self.target.address, oldAction: .init("flow_legacy", title: "Older authored action"),
                     newAction: Self.target.action, rows: [row], message: "Authored complete comparison")
    }
    private func prepared() throws -> (Harness, DeckRebindingView) {
        var h = try Harness(), value = review()
        let request = try XCTUnwrap(h.begin())
        h.receive(value, request: request)
        XCTAssertTrue(h.canApply(value), "An exact acknowledged fresh Prepare should enable its own review")
        return (h, value)
    }

    func testOnlyExactAcknowledgedPrepareAgainstCompleteCatalogEnablesItsOwnReview() throws {
        var h = try Harness(), value = review()
        XCTAssertTrue(h.presentation.catalogReady); XCTAssertFalse(h.canApply(nil)); XCTAssertFalse(h.canApply(value))
        let request = try XCTUnwrap(h.begin())
        XCTAssertFalse(h.canApply(value), "Sending Prepare is not receiving a review")
        h.receive(value, request: UUID())
        XCTAssertFalse(h.canApply(value)); XCTAssertTrue(h.requests.waiting)
        h.receive(value, request: request)
        XCTAssertTrue(h.canApply(value)); XCTAssertFalse(h.requests.waiting)
        value.reviewID = UUID()
        XCTAssertFalse(h.canApply(value), "Another review ID must not borrow this candidate")
    }

    func testChangedCatalogDisablesImmediatelyAndDoesNotAlterTheRetainedComparison() throws {
        var (h, value) = try prepared()
        let rows = value.rows.map(\.id), originalMessage = value.message
        h.presentation.catalogStarted()
        XCTAssertFalse(h.canApply(value)); XCTAssertFalse(h.presentation.catalogReady)
        XCTAssertNotNil(h.presentation.warning)
        try h.replaceCatalog([])
        XCTAssertFalse(h.canApply(value)); XCTAssertTrue(h.presentation.catalogReady)
        XCTAssertEqual(value.rows.map(\.id), rows); XCTAssertEqual(value.message, originalMessage)
        XCTAssertEqual(value.phase, .review, "Historical details may remain visible without an Apply permit")
    }

    func testIdenticalNewCatalogGenerationIsStickyInvalidationUntilNewExplicitPrepare() throws {
        var (h, old) = try prepared()
        try h.replaceCatalog([Self.target])
        XCTAssertFalse(h.canApply(old), "Equal catalog bytes do not prove the old provider generation")
        let status = UUID()
        h.presentation.supersedePendingPrepare()
        XCTAssertTrue(h.requests.begin(id: status, epoch: h.peer, command: "rebind_status"))
        h.receive(old, request: status)
        XCTAssertFalse(h.canApply(old), "Status must not rebase an old review onto the new generation")
        let fresh = review(), prepare = try XCTUnwrap(h.begin())
        h.receive(fresh, request: prepare)
        XCTAssertTrue(h.canApply(fresh)); XCTAssertFalse(h.canApply(old))
    }

    func testPartialCatalogInvalidatesBeforeCompletionAndMalformedCatalogStaysUnavailable() throws {
        var (h, value) = try prepared()
        h.presentation.catalogStarted()
        let generation = UUID()
        XCTAssertFalse(try h.catalog.receive(.init(.catalog, requestID: generation, catalog: [])))
        XCTAssertFalse(h.canApply(value)); XCTAssertFalse(h.presentation.catalogReady)
        XCTAssertFalse(try h.catalog.receive(.init(.catalog, requestID: generation, catalog: [Self.target])))
        XCTAssertThrowsError(try h.catalog.receive(.init(.catalog, requestID: generation, catalog: [Self.target])))
        h.catalog.reset(); h.presentation.catalogFailed()
        XCTAssertFalse(h.canApply(value)); XCTAssertFalse(h.presentation.catalogReady)
        XCTAssertNotNil(h.presentation.warning)
        XCTAssertNil(h.begin(), "A failed/partial catalog cannot issue a new Prepare")
    }

    func testResetDoesNotAllowAnOldStatusOrLatePrepareToResurrectReview() throws {
        var h = try Harness(), old = review()
        let pending = try XCTUnwrap(h.begin())
        h.presentation.reset(); h.catalog.reset()
        h.receive(old, request: pending)
        XCTAssertFalse(h.canApply(old)); XCTAssertFalse(h.presentation.catalogReady)
        h.presentation.receive(old, request: UUID(), peer: h.peer, acknowledged: true)
        XCTAssertFalse(h.canApply(old), "A bare status acknowledgment is not a new captured Prepare")
        XCTAssertFalse(h.presentation.warning?.isEmpty ?? true, "An unowned review returned by status must explain that a fresh Prepare is required")
    }

    func testDelayedPrepareAcknowledgmentCannotCrossAnyCatalogReplacement() throws {
        var h = try Harness(), old = review()
        let request = try XCTUnwrap(h.begin())
        try h.replaceCatalog([Self.target])
        h.receive(old, request: request)
        XCTAssertFalse(h.requests.waiting, "Transport acknowledgment may be real while presentation is stale")
        XCTAssertFalse(h.canApply(old))
        let fresh = review(), next = try XCTUnwrap(h.begin())
        h.receive(fresh, request: next)
        XCTAssertTrue(h.canApply(fresh)); XCTAssertFalse(h.canApply(old))
    }

    func testStatusReplacementAndLateOldAcknowledgmentCannotCreateAnApplyCandidate() throws {
        var h = try Harness(), value = review()
        let prepare = try XCTUnwrap(h.begin()), status = UUID()
        h.presentation.supersedePendingPrepare()
        XCTAssertTrue(h.requests.begin(id: status, epoch: h.peer, command: "rebind_status"))
        h.receive(value, request: prepare)
        XCTAssertFalse(h.canApply(value)); XCTAssertTrue(h.requests.waiting)
        h.receive(value, request: status)
        XCTAssertFalse(h.canApply(value)); XCTAssertFalse(h.requests.waiting)
    }

    func testPrepareTimeoutAndLateAcknowledgmentRemainConservative() throws {
        var h = try Harness(), value = review()
        let request = try XCTUnwrap(h.begin())
        XCTAssertTrue(h.requests.timeout(id: request, epoch: h.peer))
        h.presentation.supersedePendingPrepare()
        XCTAssertTrue(h.requests.uncertain)
        h.receive(value, request: request)
        XCTAssertFalse(h.canApply(value), "Late transport acknowledgment must not revive a timed-out Prepare")
        let fresh = review(), next = try XCTUnwrap(h.begin())
        h.receive(fresh, request: next)
        XCTAssertTrue(h.canApply(fresh))
    }

    func testPeerReplacementAndDisconnectRetireTheOriginalReviewAndPendingRequest() throws {
        var (h, old) = try prepared()
        let oldPeer = h.peer
        h.peer = UUID(); h.presentation.peerChanged(to: h.peer); h.requests.reset()
        XCTAssertFalse(h.canApply(old)); XCTAssertFalse(h.presentation.catalogReady)
        h.presentation.receive(old, request: UUID(), peer: oldPeer, acknowledged: true)
        XCTAssertFalse(h.canApply(old))
        try h.replaceCatalog([Self.target])
        let fresh = review(), request = try XCTUnwrap(h.begin())
        h.receive(fresh, request: request)
        XCTAssertTrue(h.canApply(fresh))
        h.presentation.peerChanged(to: nil); h.requests.reset()
        XCTAssertFalse(h.canApply(fresh)); XCTAssertFalse(h.presentation.catalogReady)
        h.presentation.receive(fresh, request: request, peer: h.peer, acknowledged: true)
        XCTAssertFalse(h.canApply(fresh))
    }

    func testCapturedTargetDescriptorAndPeerCannotBeSubstitutedByReviewOrCaller() throws {
        var h = try Harness(), wrong = review()
        let request = try XCTUnwrap(h.begin())
        wrong.newAction?.title = "Different descriptor at same address"
        h.receive(wrong, request: request)
        XCTAssertFalse(h.canApply(wrong))
        let fresh = review(), next = try XCTUnwrap(h.begin())
        h.receive(fresh, request: next)
        XCTAssertTrue(h.canApply(fresh))
        XCTAssertFalse(h.presentation.canApply(fresh, peer: UUID(), catalog: h.catalog.entries))
        var substituted = Self.target; substituted.action?.title = "Changed granted contract"
        XCTAssertFalse(h.presentation.canApply(fresh, peer: h.peer, catalog: [substituted]))
    }

    @MainActor func testActualModuleApplyGuardRejectsStaleReviewBeforeCreatingRequestOrOfflineFallback() throws {
        let model = ModuleApp(), peer = model.rebindPeerEpoch, generation = UUID(), request = UUID(), value = review()
        model.rebindPresentation.peerChanged(to: peer)
        model.rebindPresentation.catalogStarted()
        XCTAssertFalse(try model.catalog.receive(.init(.catalog, requestID: generation, catalog: [])))
        XCTAssertFalse(try model.catalog.receive(.init(.catalog, requestID: generation, catalog: [Self.target])))
        XCTAssertTrue(try model.catalog.receive(.init(.catalog, requestID: generation, complete: true)))
        model.rebindPresentation.catalogCompleted()
        XCTAssertTrue(model.rebindPresentation.beginPrepare(request: request, peer: peer, target: Self.target))
        XCTAssertTrue(model.rebindRequests.begin(id: request, epoch: peer, command: "rebind_prepare"))
        model.receiveRebinding(.init(deckEvent: "rebinding", request: request, rebinding: value))
        XCTAssertTrue(model.canSubmitRebindingApply(reviewID: value.reviewID))
        XCTAssertNil(model.rebindRequests.pending)
        model.rebindPresentation.catalogStarted()
        XCTAssertFalse(model.canSubmitRebindingApply(reviewID: value.reviewID))
        model.rebindFeedback = ""; model.notice = ""
        model.submitRebinding("rebind_apply", .init(reviewID: value.reviewID))
        XCTAssertNil(model.rebindRequests.pending, "Stale Apply cannot even create a private command request")
        XCTAssertNil(model.rebindAckTask)
        XCTAssertFalse(model.rebindFeedback.isEmpty, "The common stale-review guard must run before the absent-peer fallback")
        XCTAssertEqual(model.notice, model.rebindFeedback)
    }

    func testAbandonedPrepareAndConsumedApplyNeverPermitLateAcknowledgmentOrDoubleSubmit() throws {
        var h = try Harness(), abandoned = review()
        let request = try XCTUnwrap(h.begin())
        h.presentation.abandonPrepare(request: request)
        h.receive(abandoned, request: request)
        XCTAssertFalse(h.canApply(abandoned))
        let fresh = review(), next = try XCTUnwrap(h.begin())
        h.receive(fresh, request: next)
        XCTAssertTrue(h.canApply(fresh))
        h.presentation.applySubmitted(reviewID: try XCTUnwrap(fresh.reviewID))
        XCTAssertFalse(h.canApply(fresh))
        h.presentation.receive(fresh, request: next, peer: h.peer, acknowledged: true)
        XCTAssertFalse(h.canApply(fresh), "A spent Prepare acknowledgment cannot restore an Apply candidate")
        h.presentation.closeReview()
        XCTAssertFalse(h.canApply(fresh))
    }
}
