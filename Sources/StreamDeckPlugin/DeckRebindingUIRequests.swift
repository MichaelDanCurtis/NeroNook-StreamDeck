import Foundation

/// UI acknowledgement bookkeeping only. This never authorizes or retries a
/// write; the companion owns current plans, reservations and settings receipts.
struct DeckRebindingUIRequests {
    struct Request: Equatable {
        let id: UUID
        let epoch: UUID
        let command: String
        var timedOut = false
    }
    private(set) var pending: Request?
    private(set) var uncertain = false
    var waiting: Bool { pending != nil && pending?.timedOut == false }

    mutating func begin(id: UUID, epoch: UUID, command: String) -> Bool {
        let control = command == "rebind_status" || command == "rebind_close"
        guard control || (pending == nil && !uncertain) else { return false }
        pending = .init(id: id, epoch: epoch, command: command)
        return true
    }
    @discardableResult mutating func acknowledge(id: UUID?, epoch: UUID) -> Bool {
        guard let pending, pending.id == id, pending.epoch == epoch else { return false }
        self.pending = nil; uncertain = false
        return true
    }
    @discardableResult mutating func timeout(id: UUID, epoch: UUID) -> Bool {
        guard var pending, pending.id == id, pending.epoch == epoch, !pending.timedOut else { return false }
        pending.timedOut = true
        self.pending = pending; uncertain = true
        return true
    }
    mutating func reset() { pending = nil; uncertain = false }
}
