import Foundation

/// Optional, vendor-neutral actions-v1 adapter. Callers own disclosure and
/// navigation; providers receive only the explicitly supplied text, never paths.
public enum PluginEvidenceAnswerContract {
    public static let id = "answer_evidence"
    public static var action: PluginRegisteredAction {
        .init(id, title: "Answer from supplied text with citations",
              input: .init([.init("question", .string), .init("snapshot", .string)] +
                           (0..<8).map { .init("sources_\($0)", .string, required: $0 == 0) }),
              output: .init([.init("answer", .string)]), cancellable: true, timeoutSeconds: 180)
    }
    public static func accepts(_ entry: PluginCatalogEntry) -> Bool {
        guard let a = entry.action else { return false }
        return a.id == id && a.effect == .readOnly && a.cancellable &&
               a.input == action.input && a.output == action.output && a.timeoutSeconds <= 180
    }
    public static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

public struct PluginEvidenceSource: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let text: String
    public init(id: String, label: String, text: String) { self.id = id; self.label = label; self.text = text }
}

public struct PluginEvidenceQuestion: Codable, Equatable, Sendable {
    public let question: String
    public let snapshot: String
    public let sources: [PluginEvidenceSource]
    public init(question: String, snapshot: String, sources: [PluginEvidenceSource]) {
        self.question = question; self.snapshot = snapshot; self.sources = sources
    }
    public func values() throws -> [String: PluginValue] {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.utf8.count <= 1024,
              snapshot.count == 64, snapshot.allSatisfy({ $0.isHexDigit }),
              (1...48).contains(sources.count), Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ $0.id.range(of: #"^s[1-9][0-9]{0,4}$"#, options: .regularExpression) != nil &&
                  $0.label.utf8.count <= 120 && !$0.text.isEmpty && $0.text.utf8.count <= 1600 })
        else { throw ModuleProblem("Invalid evidence question or source bounds.") }
        var batches: [[PluginEvidenceSource]] = [[]]
        for source in sources {
            let trial = batches[batches.count - 1] + [source]
            if try PluginEvidenceAnswerContract.json(trial).utf8.count > 2048 { batches.append([source]) }
            else { batches[batches.count - 1] = trial }
        }
        guard batches.count <= 8, !batches[0].isEmpty else { throw ModuleProblem("Evidence exceeds eight text pages.") }
        var result: [String: PluginValue] = ["question": .string(question), "snapshot": .string(snapshot)]
        for (i, batch) in batches.enumerated() { result["sources_\(i)"] = .string(try PluginEvidenceAnswerContract.json(batch)) }
        try PluginEvidenceAnswerContract.action.input.validate(result); return result
    }
    public init(values: [String: PluginValue]) throws {
        try PluginEvidenceAnswerContract.action.input.validate(values)
        guard case .string(let question) = values["question"], case .string(let snapshot) = values["snapshot"] else { throw ModuleProblem("Missing evidence question.") }
        var sources: [PluginEvidenceSource] = [], gap = false
        for i in 0..<8 {
            if case .string(let text) = values["sources_\(i)"] {
                guard !gap else { throw ModuleProblem("Evidence pages must be contiguous.") }
                let page = try JSONDecoder().decode([PluginEvidenceSource].self, from: Data(text.utf8))
                guard !page.isEmpty else { throw ModuleProblem("Empty evidence page.") }; sources += page
            } else { gap = true }
        }
        self.init(question: question, snapshot: snapshot, sources: sources); _ = try self.values()
    }
}

public struct PluginEvidenceStatement: Codable, Equatable, Sendable {
    public let text: String
    public let citations: [String]
    public init(text: String, citations: [String]) { self.text = text; self.citations = citations }
}
public struct PluginEvidenceAnswer: Codable, Equatable, Sendable {
    public let snapshot: String
    public let disposition: String
    public let statements: [PluginEvidenceStatement]
    public init(snapshot: String, disposition: String, statements: [PluginEvidenceStatement]) {
        self.snapshot = snapshot; self.disposition = disposition; self.statements = statements
    }
    public func validate(for question: PluginEvidenceQuestion) throws {
        let allowed = Set(question.sources.map(\.id))
        guard snapshot == question.snapshot, ["answered", "insufficient"].contains(disposition),
              disposition == "answered" ? (1...5).contains(statements.count) : statements.isEmpty,
              statements.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.utf8.count <= 650 &&
                  (1...4).contains($0.citations.count) && Set($0.citations).count == $0.citations.count && Set($0.citations).isSubset(of: allowed) }),
              try PluginEvidenceAnswerContract.json(self).utf8.count <= 2048
        else { throw ModuleProblem("The answer has missing, unknown or stale citations.") }
    }
}
