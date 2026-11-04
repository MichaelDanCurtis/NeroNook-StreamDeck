import Foundation
import NookPluginSDK

struct DeckWire: Codable {
    var deckEvent: String
    var device: DeckDevice? = nil; var slot: DeckSlot? = nil
    var context: String? = nil; var command: String? = nil; var revision: String? = nil
    var settings: [String: String]? = nil; var request: UUID? = nil
    var message: String? = nil; var selected: String? = nil
    var rebindingCommand: DeckRebindingCommand? = nil
    var rebinding: DeckRebindingView? = nil
    var recoveryCommand: DeckRecoveryCommand? = nil
    var recovery: DeckRecoveryView? = nil
    func encoded() -> Data? { try? JSONEncoder().encode(self) }
}
