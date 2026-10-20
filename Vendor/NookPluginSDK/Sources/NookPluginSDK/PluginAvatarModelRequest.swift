import Foundation

/// The isolated web surface may request only its currently selected bundled art.
/// No URLs, paths, accounts or plugin actions are accepted by this presentation bridge.
struct PluginAvatarModelRequest {
    let style: String
    let persona: PluginAvatarPersona
    let url: URL
    init(body: Any, documentID: String, selection: PluginAvatarSelection?) throws {
        guard let fields = body as? [String: Any], Set(fields.keys) == Set(["style", "persona", "document"]),
              let document = fields["document"] as? String, document == documentID,
              let style = fields["style"] as? String, style.utf8.count <= 96,
              let rawPersona = fields["persona"] as? String, let persona = PluginAvatarPersona(rawValue: rawPersona),
              style == (selection?.style(persona) ?? "elemental"),
              let url = PluginAvatarStyles.model(style: style, persona: persona, format: "glb") else {
            throw ModuleProblem("Avatar artwork is unavailable.")
        }
        self.style = style; self.persona = persona; self.url = url
    }
    func data() throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 2 * 1024 * 1024, data.count >= 12,
              data.prefix(4) == Data("glTF".utf8) else { throw ModuleProblem("Invalid avatar artwork.") }
        return try Self.withDataURLImages(data)
    }

    /// Three's GLTF loader otherwise creates blob URLs for embedded image buffer
    /// views. WK's data-only CSP correctly blocks those. Keep texture sources as
    /// bounded data URLs inside this selected, bundled GLB instead of opening CSP.
    static func withDataURLImages(_ data: Data) throws -> Data {
        let limit = 2 * 1024 * 1024
        func invalid() -> ModuleProblem { ModuleProblem("Invalid avatar artwork.") }
        func word(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - 4 else { throw invalid() }
            return (0..<4).reduce(0) { $0 | Int(data[offset+$1]) << ($1*8) }
        }
        guard data.count >= 28, data.count <= limit, data.prefix(4) == Data("glTF".utf8),
              try word(4) == 2, try word(8) == data.count,
              try word(16) == 0x4E4F534A else { throw invalid() }
        let jsonCount = try word(12)
        guard jsonCount <= data.count - 28, jsonCount % 4 == 0 else { throw invalid() }
        let binOffset = 20 + jsonCount, binCount = try word(binOffset)
        guard try word(binOffset+4) == 0x004E4942, binCount == data.count - binOffset - 8,
              var document = try JSONSerialization.jsonObject(with:data.subdata(in:20..<20+jsonCount)) as? [String:Any],
              var images = document["images"] as? [[String:Any]], images.count <= 8,
              let views = document["bufferViews"] as? [[String:Any]] else { throw invalid() }
        let bin = data.subdata(in:binOffset+8..<data.count)
        for index in images.indices {
            guard let viewIndex = images[index]["bufferView"] as? Int, views.indices.contains(viewIndex),
                  let mime = images[index]["mimeType"] as? String, ["image/png","image/jpeg"].contains(mime),
                  let buffer = views[viewIndex]["buffer"] as? Int, buffer == 0,
                  let count = views[viewIndex]["byteLength"] as? Int else { throw invalid() }
            let offset = views[viewIndex]["byteOffset"] as? Int ?? 0
            guard offset >= 0, count > 0, count <= bin.count, offset <= bin.count-count else { throw invalid() }
            images[index].removeValue(forKey:"bufferView")
            images[index]["uri"] = "data:" + mime + ";base64," + bin.subdata(in:offset..<offset+count).base64EncodedString()
        }
        document["images"] = images
        var json = try JSONSerialization.data(withJSONObject:document,options:[.sortedKeys])
        while json.count % 4 != 0 { json.append(0x20) }
        let total = 28 + json.count + bin.count
        guard total <= limit else { throw invalid() }
        var result = Data("glTF".utf8)
        func appendWord(_ value: Int) { for shift in stride(from:0,to:32,by:8) { result.append(UInt8((value >> shift) & 255)) } }
        appendWord(2);appendWord(total);appendWord(json.count);appendWord(0x4E4F534A);result.append(json)
        appendWord(bin.count);appendWord(0x004E4942);result.append(bin)
        return result
    }
}

/// Shared by scheme resources and the selected-avatar message bridge. Count
/// decoded bytes before constructing a larger base64 reply; never overshoot.
struct PluginBundledAssetBudget {
    private(set) var requests = 0
    private(set) var bytes = 0
    mutating func consume(byteCount: Int) throws {
        guard requests < 512, (0...2 * 1024 * 1024).contains(byteCount),
              byteCount <= 32 * 1024 * 1024 - bytes else {
            throw ModuleProblem("View resource budget exceeded.")
        }
        requests += 1; bytes += byteCount
    }
}
