import XCTest
import Foundation
@testable import StreamDeckPlugin

final class RecoveryPresentationTests: XCTestCase {
    private func row(id: UUID = UUID(), kind: DeckRecoveryRecord.Kind = .settings,
                     state: String = "uncertain", unresolved: Bool = true) -> DeckRecoveryRecord {
        .init(id: id, kind: kind, createdAt: "2026-10-30T12:00:00Z", context: "authored-historical-key",
              action: "cafe.nero.neronook.run", device: "authored-deck", controller: "Keypad",
              row: 0, column: 2, state: state, cold: true, unresolved: unresolved,
              message: "Authored retained outcome")
    }
    private func inventory(_ rows: [DeckRecoveryRecord], phase: DeckRecoveryView.Phase = .status,
                           offset: Int = 0, total: Int? = nil, next: Int? = nil) -> DeckRecoveryView {
        var view = DeckRecoveryView(phase: phase, message: "Authored inventory")
        view.records = rows; view.offset = offset; view.totalRecordCount = total ?? rows.count; view.nextOffset = next
        return view
    }

    func testDetailedReviewAndRejectedReplyRetainTheExactAcknowledgedPage() {
        let one = row(), two = row(kind: .run)
        var state = DeckRecoveryPresentation()
        state.receive(inventory([one, two], offset: 16, total: 40, next: 32))
        var detail = DeckRecoveryView(phase: .review, message: "Detailed read; inventory omitted")
        detail.recordID = one.id; detail.reviewID = UUID(); detail.canConfirm = true
        state.receive(detail)
        XCTAssertEqual(state.page?.records.map(\.id), [one.id, two.id])
        XCTAssertEqual(state.page?.offset, 16); XCTAssertEqual(state.page?.totalRecordCount, 40)
        XCTAssertEqual(state.page?.nextOffset, 32); XCTAssertTrue(state.isRetainedInventory)
        state.receive(.init(phase: .rejected, message: "Current key changed; no inventory in this reply"))
        XCTAssertEqual(state.page?.records.map(\.id), [one.id, two.id])
        XCTAssertEqual(state.page?.offset, 16); XCTAssertEqual(state.page?.totalRecordCount, 40)
        XCTAssertEqual(state.page?.nextOffset, 32); XCTAssertTrue(state.isRetainedInventory)
    }

    func testRejectedOrDetailedReplyCannotInventAnEmptyOrSelectableInventory() {
        var state = DeckRecoveryPresentation()
        let unlisted = row()
        var detail = inventory([unlisted], phase: .review)
        detail.recordID = unlisted.id; detail.reviewID = UUID(); detail.canConfirm = true
        state.receive(detail)
        XCTAssertNil(state.page); XCTAssertNil(state.record(id: unlisted.id))
        XCTAssertFalse(state.allowsSettingsReview(id: unlisted.id))
        state.receive(.init(phase: .rejected, message: "Unavailable"))
        XCTAssertNil(state.page); XCTAssertFalse(state.isRetainedInventory)
    }

    func testCompleteReplacesThePageAndResolvedSettingsBecomeReadOnly() {
        let id = UUID(), removed = row()
        var state = DeckRecoveryPresentation()
        state.receive(inventory([row(id: id), removed]))
        XCTAssertTrue(state.allowsSettingsReview(id: id))
        state.receive(inventory([row(id: id, state: "reconciledDifferent", unresolved: false)], phase: .complete))
        XCTAssertEqual(state.page?.records.count, 1); XCTAssertFalse(state.isRetainedInventory)
        XCTAssertEqual(state.record(id: id)?.state, "reconciledDifferent")
        XCTAssertEqual(state.detailMode(id: id), .settingsObservation)
        XCTAssertFalse(state.allowsSettingsReview(id: id))
        XCTAssertNil(state.record(id: removed.id)); XCTAssertFalse(state.allowsSettingsReview(id: removed.id))
    }

    func testValidEmptyStatusAndNewPageDoNotResurrectStaleSelection() {
        let original = row(), replacement = row()
        var state = DeckRecoveryPresentation()
        state.receive(inventory([original], offset: 0, total: 17, next: 16))
        state.receive(inventory([replacement], offset: 16, total: 17))
        XCTAssertNil(state.record(id: original.id)); XCTAssertEqual(state.page?.offset, 16)
        XCTAssertEqual(state.page?.totalRecordCount, 17); XCTAssertNil(state.page?.nextOffset)
        XCTAssertEqual(state.record(id: replacement.id)?.id, replacement.id)
        state.receive(inventory([]))
        XCTAssertNotNil(state.page); XCTAssertEqual(state.page?.totalRecordCount, 0)
        XCTAssertEqual(state.page?.records.count, 0); XCTAssertFalse(state.isRetainedInventory)
        XCTAssertNil(state.record(id: replacement.id)); XCTAssertFalse(state.allowsSettingsReview(id: replacement.id))
    }

    func testPeerResetDropsRetainedMetadataAndCannotBeRebuiltByAnOldDetail() {
        let original = row()
        var state = DeckRecoveryPresentation()
        state.receive(inventory([original]))
        state.reset()
        var oldDetail = DeckRecoveryView(phase: .review, message: "Historical metadata is not a page")
        oldDetail.recordID = original.id; oldDetail.reviewID = UUID(); oldDetail.canConfirm = true
        state.receive(oldDetail)
        XCTAssertNil(state.page); XCTAssertNil(state.record(id: original.id))
        XCTAssertFalse(state.isRetainedInventory); XCTAssertFalse(state.allowsSettingsReview(id: original.id))
    }

    func testEveryResolvedSettingsOutcomeAndExecutionRecordIsReadOnly() {
        var state = DeckRecoveryPresentation()
        let settled = ["confirmed", "conflict", "notSent", "reconciledBefore", "reconciledAfter", "reconciledDifferent"]
            .map { row(state: $0, unresolved: false) }
        let run = row(kind: .run, state: "running"), cancel = row(kind: .cancel, state: "interrupted")
        state.receive(inventory(settled + [run, cancel]))
        for record in settled {
            XCTAssertEqual(state.detailMode(id: record.id), .settingsObservation)
            XCTAssertFalse(state.allowsSettingsReview(id: record.id))
        }
        for record in [run, cancel] {
            XCTAssertEqual(state.detailMode(id: record.id), .executionEvidence)
            XCTAssertFalse(state.allowsSettingsReview(id: record.id))
        }
        XCTAssertNil(state.detailMode(id: UUID())); XCTAssertFalse(state.allowsSettingsReview(id: nil))
    }

    @MainActor func testActualReceiverRejectsWrongNonceOrPeerBeforeMutatingPresentation() {
        let model = ModuleApp(), original = row(), replacement = row()
        let first = UUID()
        XCTAssertTrue(model.recoveryRequests.begin(id: first, epoch: model.rebindPeerEpoch, command: "recovery_status"))
        model.receiveRecovery(.init(deckEvent: "recovery", request: first, recovery: inventory([original])))
        XCTAssertEqual(model.recoveryPresentation.page?.records.map(\.id), [original.id])
        let next = UUID()
        XCTAssertTrue(model.recoveryRequests.begin(id: next, epoch: model.rebindPeerEpoch, command: "recovery_status"))
        model.receiveRecovery(.init(deckEvent: "recovery", request: UUID(), recovery: inventory([replacement])))
        XCTAssertEqual(model.recoveryPresentation.page?.records.map(\.id), [original.id])
        XCTAssertTrue(model.recoveryRequestPending)
        model.recoveryRequests.reset()
        XCTAssertTrue(model.recoveryRequests.begin(id: next, epoch: UUID(), command: "recovery_status"))
        model.receiveRecovery(.init(deckEvent: "recovery", request: next, recovery: inventory([replacement])))
        XCTAssertEqual(model.recoveryPresentation.page?.records.map(\.id), [original.id])
        XCTAssertTrue(model.recoveryRequestPending)
        model.recoveryRequests.reset()
        XCTAssertTrue(model.recoveryRequests.begin(id: next, epoch: model.rebindPeerEpoch, command: "recovery_status"))
        model.receiveRecovery(.init(deckEvent: "recovery", request: next, recovery: inventory([replacement])))
        XCTAssertEqual(model.recoveryPresentation.page?.records.map(\.id), [replacement.id])
        XCTAssertFalse(model.recoveryRequestPending)
    }
}
