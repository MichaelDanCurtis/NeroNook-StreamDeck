import Foundation
import NookPluginSDK

/// Private same-user companion UI data. Not SDK authority or an Elgato writer.
struct DeckRecoveryCommand: Codable {
    var recordID: UUID?
    var context: String?
    var revision: String?
    var reviewID: UUID?
    var offset: Int?
    init(recordID: UUID? = nil, context: String? = nil, revision: String? = nil,
         reviewID: UUID? = nil, offset: Int? = nil) {
        self.recordID = recordID; self.context = context; self.revision = revision
        self.reviewID = reviewID; self.offset = offset
    }
}
struct DeckRecoveryRecord: Codable, Identifiable {
    enum Kind: String, Codable { case settings, run, cancel }
    var id: UUID
    var kind: Kind
    var createdAt: String
    /// Historical context is disclosure, never a cold placement identity.
    var context: String
    var action: String
    var device: String
    var controller: String
    var row: Int
    var column: Int
    var oldAddress: PluginActionAddress? = nil
    var newAddress: PluginActionAddress? = nil
    var beforeSHA256: String? = nil
    var afterSHA256: String? = nil
    var state: String
    var cold: Bool
    var unresolved: Bool
    var message: String
}
struct DeckRecoveryView: Codable {
    enum Phase: String, Codable { case status, review, complete, rejected }
    enum Match: String, Codable { case before, after, different, notApplicable }
    var phase: Phase
    var records: [DeckRecoveryRecord] = []
    var totalRecordCount = 0
    var offset = 0
    var nextOffset: Int? = nil
    var reviewID: UUID? = nil
    var recordID: UUID? = nil
    var slot: DeckSlot? = nil
    var before: [String: String]? = nil
    var after: [String: String]? = nil
    var current: [String: String]? = nil
    var beforeSHA256: String? = nil
    var afterSHA256: String? = nil
    var currentSHA256: String? = nil
    var match: Match? = nil
    var canConfirm = false
    var message: String
}
enum DeckRecoveryLimits {
    static let pageSize = 16
    static let reviewBytes = 98_304
    ///128 settings +128 run records; Stop evidence is aggregated per run.
    static let reportedRecords = 256
}

/// Acknowledgements only. No retry, durable settlement, run ownership or device
/// action can be manufactured by these in-memory presentation flags.
struct DeckRecoveryUIRequests {
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
        guard ["recovery_status", "recovery_prepare", "recovery_confirm", "recovery_close"].contains(command) else { return false }
        if command == "recovery_status" {
            guard !waiting else { return false }
        } else if command == "recovery_close" {
            guard pending?.command != "recovery_close" || !waiting else { return false }
        } else {
            guard pending == nil && !uncertain else { return false }
        }
        pending = .init(id: id, epoch: epoch, command: command)
        return true
    }
    @discardableResult mutating func acknowledge(id: UUID?, epoch: UUID) -> Bool {
        guard let pending, pending.id == id, pending.epoch == epoch else { return false }
        self.pending = nil; uncertain = false; return true
    }
    @discardableResult mutating func timeout(id: UUID, epoch: UUID) -> Bool {
        guard var pending, pending.id == id, pending.epoch == epoch, !pending.timedOut else { return false }
        pending.timedOut = true; self.pending = pending; uncertain = true; return true
    }
    mutating func reset() { pending = nil; uncertain = false }
}

/// Last acknowledged metadata inventory for presentation only. A detailed
/// comparison omits the page; that omission does not mean an empty inventory.
/// No review nonce, placement witness or command authority is retained here.
struct DeckRecoveryPresentation {
    struct Page {
        let records: [DeckRecoveryRecord]
        let totalRecordCount: Int
        let offset: Int
        let nextOffset: Int?
    }
    enum DetailMode: Equatable { case unresolvedSettings, settingsObservation, executionEvidence }
    private(set) var page: Page?
    private(set) var isRetainedInventory = false

    /// Called only after the actual receiver validates shape and acknowledges
    /// the exact request in its current peer epoch.
    mutating func receive(_ view: DeckRecoveryView) {
        switch view.phase {
        case .status, .complete:
            page = .init(records: view.records, totalRecordCount: view.totalRecordCount,
                         offset: view.offset, nextOffset: view.nextOffset)
            isRetainedInventory = false
        case .review, .rejected:
            isRetainedInventory = page != nil
        }
    }
    func record(id: UUID?) -> DeckRecoveryRecord? {
        guard let id else { return nil }
        return page?.records.first { $0.id == id }
    }
    func detailMode(id: UUID?) -> DetailMode? {
        guard let row = record(id: id) else { return nil }
        if row.kind != .settings { return .executionEvidence }
        return row.unresolved ? .unresolvedSettings : .settingsObservation
    }
    /// UI eligibility only; this never supplies confirmation or effect authority.
    func allowsSettingsReview(id: UUID?) -> Bool { detailMode(id: id) == .unresolvedSettings }
    mutating func reset() { page = nil; isRetainedInventory = false }
}
