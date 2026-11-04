import Foundation
import NookPluginSDK

/// Session-local ownership. A Stop key selects a descriptor, never a guessed
/// "latest" run; it can cancel only the exact request this companion started.
struct DeckRuns {
    struct Run {
        let id: UUID
        let context: String
        let address: PluginActionAddress
        let action: PluginRegisteredAction
        let started: Date
        var update = PluginRunUpdate(.running, message: "Requesting action")
        var cancelSent = false
        var ended: Date?
        var active: Bool { !update.phase.terminal }
        func elapsed(_ now: Date) -> String { let s = max(0, Int((ended ?? now).timeIntervalSince(started))); return String(format: "%d:%02d", s / 60, s % 60) }
        var status: String {
            switch update.phase {
            case .waitingReview: return "Review in Nook"
            case .running: return update.display?.needsReview == true ? "Review in Nook" : "Running"
            case .cancelling: return "Stopping"
            case .succeeded: return "Done"
            case .cancelled: return "Stopped"
            case .failed: return "Failed"
            case .interrupted: return "Check outcome"
            }
        }
    }
    private(set) var records: [Run] = []
    private var interruptedContexts = Set<String>()
    private var interruptedAddresses = Set<PluginActionAddress>()
    private var interruptedOverflow = false
    func latest(_ address: PluginActionAddress) -> Run? { records.last { $0.address == address } }
    func latest(context: String) -> Run? { records.last { $0.context == context } }
    /// A mapping change must not detach the original Run/Stop pair while any
    /// affected local request is active. Interrupted records retain their prior
    /// unknown-outcome meaning; this is not remote-stop reconciliation.
    func hasActive(context: String, addresses: Set<PluginActionAddress>) -> Bool {
        records.contains { $0.active && ($0.context == context || addresses.contains($0.address)) }
    }
    /// Reconnection/Undo is more conservative than ordinary key operation.
    /// A session's interrupted request has not proved its external outcome.
    func hasUnsettled(contexts: Set<String>, addresses: Set<PluginActionAddress>) -> Bool {
        interruptedOverflow || !interruptedContexts.isDisjoint(with: contexts)
            || !interruptedAddresses.isDisjoint(with: addresses)
            || records.contains { $0.active && (contexts.contains($0.context) || addresses.contains($0.address)) }
    }
    private mutating func rememberInterrupted(_ run: Run) {
        guard interruptedContexts.contains(run.context) || interruptedContexts.count < 128,
              interruptedAddresses.contains(run.address) || interruptedAddresses.count < 128 else {
            interruptedOverflow = true; return
        }
        interruptedContexts.insert(run.context); interruptedAddresses.insert(run.address)
    }
    mutating func begin(context: String, entry: PluginCatalogEntry, now: Date = Date()) throws -> UUID {
        guard let action = entry.action, records.filter(\.active).count < 32,
              !records.contains(where: { $0.active && ($0.context == context || $0.address == entry.address) }) else { throw ModuleProblem("This action already has an active run. Nothing was repeated.") }
        try entry.address.validate(); try action.validate()
        let id = UUID(); records.append(.init(id: id, context: context, address: entry.address, action: action, started: now)); trim(); return id
    }
    @discardableResult mutating func receive(_ message: PluginBusMessage, now: Date = Date()) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == message.requestID && $0.active }),
              message.address == nil || message.address == records[index].address else { return false }
        if message.operation == .update, var update = message.update {
            guard (try? update.validate()) != nil else { return false }
            if update.phase == .succeeded, (try? records[index].action.output.validate(update.values)) == nil { return false }
            if records[index].cancelSent && !update.phase.terminal { update.phase = .cancelling }
            records[index].update = update
        } else if message.operation == .failure {
            records[index].update = .init(.interrupted, message: String((message.error ?? "Action access or result unavailable. Inspect NeroNook.").prefix(300)))
        } else { return false }
        if !records[index].active { records[index].ended = now }
        if records[index].update.phase == .interrupted { let value = records[index]; rememberInterrupted(value) }
        return true
    }
    mutating func cancel(_ address: PluginActionAddress) throws -> UUID? {
        let matches = records.indices.filter { records[$0].address == address && records[$0].active }
        guard matches.count <= 1 else { throw ModuleProblem("More than one run matches. Inspect NeroNook; no Stop was sent.") }
        guard let index = matches.first else { return nil }
        guard records[index].action.cancellable else { throw ModuleProblem("This action does not support Stop.") }
        guard !records[index].cancelSent else { return nil }
        records[index].cancelSent = true; records[index].update.phase = .cancelling
        records[index].update.message = "Stop requested. Waiting for the provider's confirmed outcome."
        return records[index].id
    }
    mutating func disconnected(now: Date = Date()) {
        for index in records.indices where records[index].active {
            records[index].update = .init(.interrupted, message: "Connection ended. Inspect the original run in NeroNook; nothing was replayed.")
            records[index].ended = now
            let value = records[index]; rememberInterrupted(value)
        }
    }
    private mutating func trim() {
        if records.count > 64 { records = Array(records.filter { !$0.active }.suffix(32)) + records.filter(\.active) }
    }
}

/// Session-local exclusion while Elgato confirms one settings change. It does
/// not make Elgato's external settings API atomic or confer action authority.
struct DeckMappingSaveBarrier {
    let context: String
    let oldAddress: PluginActionAddress
    let newAddress: PluginActionAddress
    var addresses: Set<PluginActionAddress> { [oldAddress, newAddress] }
    func blocksRun(context candidateContext: String, address: PluginActionAddress) -> Bool {
        candidateContext == context || addresses.contains(address)
    }
}
