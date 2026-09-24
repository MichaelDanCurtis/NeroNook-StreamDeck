import Foundation

/// Optional `forms-v1` presentation for a registered actions-v1 action.
/// Secrets belong in plugin-owned settings, never in display snapshots.
public struct PluginFormInput: Codable, Equatable, Sendable, Identifiable {
    public enum Style: String, Codable, Sendable { case text, number, slider, toggle, choice }
    public var id: String
    public var label: String
    public var style: Style
    public var value: PluginValue
    public var choices: [String]?
    public init(_ id: String, label: String, style: Style, value: PluginValue, choices: [String]? = nil) {
        self.id = id; self.label = label; self.style = style; self.value = value; self.choices = choices
    }
}

public struct PluginForm: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Change when the target or resource state changes to invalidate an open draft/review.
    public var revision: String
    public var action: PluginRegisteredAction
    public var inputs: [PluginFormInput]
    public var enabled: Bool
    public init(_ id: String, title: String, revision: String, action: PluginRegisteredAction, inputs: [PluginFormInput], enabled: Bool = true) {
        self.id = id; self.title = title; self.revision = revision; self.action = action; self.inputs = inputs; self.enabled = enabled
    }
    public var defaults: [String: PluginValue] { Dictionary(inputs.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first }) }
    public func validate() throws {
        try action.validate()
        guard ModulePackage.validKey(id), !title.isEmpty, title.count <= 80,
              !revision.isEmpty, revision.count <= 128, (1...6).contains(inputs.count),
              Set(inputs.map(\.id)).count == inputs.count,
              Set(inputs.map(\.id)) == Set(action.input.fields.map(\.name)) else { throw ModuleProblem("Invalid form identity or fields.") }
        for input in inputs {
            guard !input.label.isEmpty, input.label.count <= 80,
                  let field = action.input.fields.first(where: { $0.name == input.id }) else { throw ModuleProblem("Invalid form input.") }
            switch (input.style, field.kind) {
            case (.text, .string), (.number, .number), (.toggle, .boolean):
                guard input.choices == nil else { throw ModuleProblem("Unexpected choices.") }
            case (.slider, .number):
                guard input.choices == nil, let lo = field.minimum, let hi = field.maximum, lo < hi, (hi - lo).isFinite else { throw ModuleProblem("Sliders require finite bounds.") }
            case (.choice, .string):
                guard let choices = input.choices, (1...24).contains(choices.count),
                      choices.allSatisfy({ !$0.isEmpty && $0.count <= 80 }), Set(choices).count == choices.count else { throw ModuleProblem("Invalid choices.") }
            default: throw ModuleProblem("Input style does not match the action schema.")
            }
        }
        try validateValues(defaults)
    }
    public func validateValues(_ values: [String: PluginValue]) throws {
        try action.input.validate(values)
        guard Set(values.keys) == Set(inputs.map(\.id)) else { throw ModuleProblem("Every displayed input needs a value.") }
        for input in inputs where input.style == .choice {
            guard case .string(let choice) = values[input.id], input.choices?.contains(choice) == true else { throw ModuleProblem("Choose an available value.") }
        }
    }
}
