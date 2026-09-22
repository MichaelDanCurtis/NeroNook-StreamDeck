import Foundation

@main struct Acceptance {
    static func main() throws {
        let secret = "DO_NOT_EXPORT_SETTINGS_OR_TITLES"
        let fixture: [String: Any] = ["Controllers": [
            ["Type": "Keypad", "Actions": ["0,0": ["UUID": "com.elgato.streamdeck.system.text", "Name": secret, "Settings": ["text": secret], "States": [["Title": secret]]], "1,0": ["UUID": "third.party.action", "Settings": ["token": secret]]]],
            ["Type": "Encoder", "Actions": NSNull()]
        ]]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        var inventory = ProfileInventory()
        try inventory.includePage(data)
        precondition(inventory.pages == 1 && inventory.actionCount == 2 && inventory.nativeCandidateCount == 1)
        precondition(inventory.controllers["Encoder"] == 1)
        let encoded = try JSONEncoder().encode(inventory)
        precondition(!String(decoding: encoded, as: UTF8.self).contains(secret))
        func rejected(_ input: Data) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let before = try encoder.encode(inventory)
            do { try inventory.includePage(input); fatalError("Invalid page accepted") } catch is InventoryError {} catch is DecodingError {} catch { }
            let after = try encoder.encode(inventory)
            precondition(after == before)
        }
        try rejected(Data("{}".utf8))
        try rejected(Data(repeating: 32, count: 2_097_153))
        for actions: Any in [[], ["../0": ["UUID": "a.b"]], ["0,0": ["UUID": "https://secret"]], ["0,0": ["UUID": true]]] {
            try rejected(JSONSerialization.data(withJSONObject: ["Controllers": [["Type": "Keypad", "Actions": actions]]]))
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("deck-inventory-tests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let profile = root.appendingPathComponent("test.sdProfile")
        let page = profile.appendingPathComponent("Profiles/page")
        try fm.createDirectory(at: page, withIntermediateDirectories: true)
        let manifest = try JSONSerialization.data(withJSONObject: ["Name": secret, "Device": ["Model": "20GBD9901", "UUID": secret], "Pages": ["Current": "page"]])
        try manifest.write(to: profile.appendingPathComponent("manifest.json"))
        try data.write(to: page.appendingPathComponent("manifest.json"))
        let live = try ProfileInventory.read(directory: root)
        precondition(live.profiles == 1 && live.pages == 1 && live.issues.isEmpty)
        let liveEncoded = try JSONEncoder().encode(live)
        precondition(!String(decoding: liveEncoded, as: UTF8.self).contains(secret))
        try fm.createSymbolicLink(at: profile.appendingPathComponent("Profiles/linked"), withDestinationURL: page)
        let withLink = try ProfileInventory.read(directory: root)
        precondition(withLink.pages == 1 && withLink.issues.count == 1)
        print("PASS: profile/page inventory, null encoder actions, unknown action retention, settings exclusion, bounded parsing, atomic rejection and symlink rejection")
    }
}
