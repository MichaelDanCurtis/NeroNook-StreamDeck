import Foundation
import DeckCore

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: deck-audit <explicit ProfilesV2 or ProfilesV3 folder>\n".utf8))
    exit(2)
}
do {
    let inventory = try ProfileInventory.read(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(inventory), as: UTF8.self))
    if !inventory.issues.isEmpty { exit(1) }
} catch {
    FileHandle.standardError.write(Data("Could not read the selected profile folder. No files were changed.\n".utf8))
    exit(1)
}
