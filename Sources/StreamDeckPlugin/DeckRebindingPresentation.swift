import Foundation
import NookPluginSDK

/// Presentation eligibility only. The companion still owns plans, currentness,
/// writes and receipts. Received status or matching descriptor text cannot mint
/// a review against a different catalog/connection generation.
struct DeckRebindingPresentation {
    private struct Prepare {
        let request, peer, catalog: UUID
        let target: PluginCatalogEntry
    }
    private struct Candidate {
        let reviewID: UUID
        let prepare: Prepare
    }
    private var peerEpoch: UUID?
    private var catalogGeneration: UUID?
    private var pending: Prepare?
    private var candidate: Candidate?
    private(set) var warning: String?
    var catalogReady: Bool { peerEpoch != nil && catalogGeneration != nil }

    private mutating func invalidateCatalog(_ message: String, alwaysWarn: Bool = false) {
        let hadReview = pending != nil || candidate != nil
        catalogGeneration = nil; pending = nil; candidate = nil
        if alwaysWarn || hadReview || warning != nil { warning = message }
    }
    mutating func peerChanged(to peer: UUID?) {
        invalidateCatalog("The connection changed. Read current actions and review the keys again.")
        peerEpoch = peer
    }
    mutating func catalogStarted() {
        invalidateCatalog("The permitted action list changed. This review cannot start Apply; review the keys again.")
    }
    mutating func catalogCompleted() {
        // Even identical completed bytes are a new companion catalog generation.
        catalogStarted()
        if peerEpoch != nil { catalogGeneration = UUID() }
    }
    mutating func catalogFailed() {
        invalidateCatalog("The action list is unavailable. Wait for a complete current list and review the keys again.", alwaysWarn: true)
    }
    mutating func reset() {
        invalidateCatalog("The key inventory reset. Read current actions and review the keys again.")
    }
    @discardableResult mutating func beginPrepare(request: UUID, peer: UUID, target: PluginCatalogEntry) -> Bool {
        pending = nil; candidate = nil
        guard peerEpoch == peer, let catalogGeneration, let action = target.action,
              target.channel == nil, target.address.name == action.id else {
            warning = "Wait for a complete current action list before reviewing the keys."
            return false
        }
        pending = .init(request: request, peer: peer, catalog: catalogGeneration, target: target)
        warning = nil
        return true
    }
    mutating func abandonPrepare(request: UUID) {
        guard pending?.request == request else { return }
        pending = nil
        warning = "The review request was not sent. Review the keys again before Apply."
    }
    mutating func supersedePendingPrepare() {
        guard pending != nil else { return }
        pending = nil
        warning = "The pending review is no longer current. Read status, then review the keys again."
    }
    mutating func closeReview() {
        pending = nil; candidate = nil
    }
    mutating func applySubmitted(reviewID: UUID) {
        guard candidate?.reviewID == reviewID else { return }
        candidate = nil; pending = nil
    }
    mutating func receive(_ view: DeckRebindingView, request: UUID?, peer: UUID, acknowledged: Bool) {
        guard acknowledged else {
            // Progress can remove presentation eligibility, never create it.
            if let candidate, view.reviewID == candidate.reviewID, view.phase != .review {
                self.candidate = nil
            }
            return
        }
        if let prepared = pending, prepared.request == request {
            pending = nil
            guard peerEpoch == peer, prepared.peer == peer, prepared.catalog == catalogGeneration,
                  view.phase == .review, let id = view.reviewID,
                  view.target == prepared.target.address, view.newAction == prepared.target.action else {
                candidate = nil
                warning = "The prepared actions or connection changed. Review the keys again before Apply."
                return
            }
            candidate = .init(reviewID: id, prepare: prepared)
            warning = nil
        } else if let candidate {
            // Status may retain the same still-current review. It cannot rebase
            // one, replace its identity or recover a previously consumed pin.
            if view.phase != .review { self.candidate = nil; return }
            if peerEpoch != peer || candidate.prepare.peer != peer ||
                candidate.prepare.catalog != catalogGeneration ||
                view.reviewID != candidate.reviewID || view.target != candidate.prepare.target.address ||
                view.newAction != candidate.prepare.target.action {
                self.candidate = nil
                warning = "This saved review cannot start Apply. Review the keys again."
            }
        } else if view.phase == .review {
            warning = warning ?? "This saved review cannot start Apply. Review the keys again."
        }
    }
    func canApply(_ view: DeckRebindingView?, peer: UUID, catalog: [PluginCatalogEntry]) -> Bool {
        guard let candidate, let view, view.phase == .review,
              view.reviewID == candidate.reviewID, peerEpoch == peer, candidate.prepare.peer == peer,
              candidate.prepare.catalog == catalogGeneration,
              view.target == candidate.prepare.target.address,
              view.newAction == candidate.prepare.target.action,
              catalog.contains(candidate.prepare.target) else { return false }
        return true
    }
}
