import XCTest
import NookPluginSDK
@testable import StreamDeckPlugin
final class MappingTests: XCTestCase {
    func testMappingRejectsWrongTypesUnknownGrantsAndStatusFields() throws {
        let action = PluginRegisteredAction("volume", title: "Volume", input: .init([.init("value", .number, minimum: 0, maximum: 100)]), effect: .externalChange)
        let entry = PluginCatalogEntry(address: .init("fixture.monitor", "volume"), action: action)
        var slot = DeckSlot(context: "key", action: "cafe.nero.neronook.run", device: "deck", controller: "Keypad", column: 0, row: 0, revision: "revision", settings: [:])
        let good = ["provider": "fixture.monitor", "name": "volume", "arguments": "{\"value\":50}"]
        try DeckMapping.validate(settings: good, slot: slot, catalog: [entry])
        XCTAssertThrowsError(try DeckMapping.validate(settings: good, slot: slot, catalog: []))
        var bad = good; bad["arguments"] = "{\"value\":101}"
        XCTAssertThrowsError(try DeckMapping.validate(settings: bad, slot: slot, catalog: [entry]))
        bad["arguments"] = "{\"value\":\"50\"}"
        XCTAssertThrowsError(try DeckMapping.validate(settings: bad, slot: slot, catalog: [entry]))
        slot.action = "cafe.nero.neronook.status"
        XCTAssertThrowsError(try DeckMapping.validate(settings: good, slot: slot, catalog: [entry]))
    }
    func testMenusExcludeActionsWithRequiredInputsAndChannels() {
        let required = PluginCatalogEntry(address: .init("test.provider", "edit"), action: .init("edit", title: "Edit", input: .init([.init("text", .string)])))
        let empty = PluginCatalogEntry(address: .init("test.provider", "check"), action: .init("check", title: "Check"))
        XCTAssertEqual(DeckMapping.menuEntries([required, empty]), [empty])
    }
}
