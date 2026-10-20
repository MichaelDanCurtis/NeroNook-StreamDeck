import Foundation

/// Optional conversation adapter. Historical answers are context for resolving
/// follow-ups, never evidence. Only current supplied source IDs may be cited.
public struct PluginEvidenceExchange: Codable, Equatable, Sendable {
    public let question: String
    public let answer: String
    public init(question: String, answer: String) { self.question = question; self.answer = answer }
}
public enum PluginEvidenceChatContract {
    public static let id = "answer_evidence_chat"
    public static var action: PluginRegisteredAction {
        var value = PluginEvidenceAnswerContract.action
        value.id = id; value.title = "Answer from supplied text and conversation with citations"
        value.input.fields.append(.init("history", .string))
        return value
    }
    public static func accepts(_ entry: PluginCatalogEntry) -> Bool {
        guard let a = entry.action else { return false }
        return a.id == id && a.effect == .readOnly && a.cancellable && a.input == action.input && a.output == action.output && a.timeoutSeconds <= 180
    }
    public static func validate(_ history: [PluginEvidenceExchange]) throws {
        guard history.count <= 4, history.allSatisfy({ !$0.question.isEmpty && $0.question.utf8.count <= 1024 && $0.answer.utf8.count <= 1400 }),
              try PluginEvidenceAnswerContract.json(history).utf8.count <= 2048 else { throw ModuleProblem("Conversation context exceeds its limit.") }
    }
    public static func values(_ question: PluginEvidenceQuestion, history: [PluginEvidenceExchange]) throws -> [String: PluginValue] {
        try validate(history); var values = try question.values()
        values["history"] = .string(try PluginEvidenceAnswerContract.json(history)); try action.input.validate(values); return values
    }
    public static func decode(_ values: [String: PluginValue]) throws -> (PluginEvidenceQuestion, [PluginEvidenceExchange]) {
        try action.input.validate(values)
        guard case .string(let text) = values["history"] else { throw ModuleProblem("Missing conversation context.") }
        let history = try JSONDecoder().decode([PluginEvidenceExchange].self, from: Data(text.utf8)); try validate(history)
        var evidence = values; evidence.removeValue(forKey: "history")
        return (try PluginEvidenceQuestion(values: evidence), history)
    }
}
