import Foundation

/// Optional mail-reply capabilities. Providers retain accounts, source references
/// and review UI. No message sending, auth or provider IDs belong to this contract.
public enum PluginMailReplyContract {
    public static let read = PluginRegisteredAction("read_reply_context", title: "Read the selected message for a reply",
        output: .init([.init("reference", .string), .init("task", .string)]), effect: .readOnly, timeoutSeconds: 30)
    public static let review = PluginRegisteredAction("review_reply_draft", title: "Review an editable reply draft",
        input: .init([.init("reference", .string), .init("reply", .string), .init("truncated", .boolean)]),
        output: .init([.init("draft_id", .string), .init("status", .string)]), effect: .localChange, timeoutSeconds: 5)
    public static func matches(_ entry: PluginCatalogEntry, _ expected: PluginRegisteredAction) -> Bool {
        guard let action = entry.action else { return false }
        return action.id == expected.id && action.input == expected.input && action.output == expected.output && action.effect == expected.effect
    }
}

/// Optional batch selection. References belong to the provider/account/selection,
/// not the workflow; no message body, credentials or file path is in this list.
public enum PluginMailReplyBatchContract {
    public static let items: PluginStructuredSchema = .array(.object(["reference": .string, "subject": .string]), maximum: 5)
    public static let list = PluginRegisteredAction("list_reply_selection", title: "Read selected reply items",
        input: .init([.init("selection_id", .string, required: false), .init("count", .number, required: false, minimum: 1, maximum: 5)]),
        output: .init([.init("selection_id", .string), .init("count", .number, minimum: 1, maximum: 5), .init("items", .string, structured: items)]),
        effect: .readOnly, timeoutSeconds: 5)
    public static let read = PluginRegisteredAction("read_reply_item", title: "Read one selected reply item",
        input: .init([.init("reference", .string)]), output: PluginMailReplyContract.read.output,
        effect: .readOnly, timeoutSeconds: 30)
}

/// Generic task handoff used by independent agent systems. Preparing never sends;
/// the provider owns target review, execution, cancellation and original receipts.
public enum PluginAgentTaskContract {
    public static let prepare = PluginRegisteredAction("prepare_handoff", title: "Prepare an agent task for review",
        input: .init([.init("target_id", .string), .init("task", .string)]),
        output: .init([.init("review_id", .string), .init("message", .string)]), effect: .localChange, timeoutSeconds: 5)
    public static let list = PluginRegisteredAction("list_handoff_targets", title: "List available agents",
        output: .init([.init("targets", .string), .init("count", .number, minimum: 0, maximum: 12)]), effect: .readOnly, timeoutSeconds: 5)
    public static let wait = PluginRegisteredAction("wait_for_handoff", title: "Wait for the agent's result",
        input: .init([.init("request_id", .string)]),
        output: .init([.init("request_id", .string), .init("run_id", .string), .init("result", .string), .init("result_truncated", .boolean)]),
        effect: .externalChange, cancellable: true, timeoutSeconds: 30, completionTimeoutSeconds: 3600)
}
