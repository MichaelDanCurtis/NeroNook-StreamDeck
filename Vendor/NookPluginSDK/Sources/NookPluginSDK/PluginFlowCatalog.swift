import Foundation

/// Optional flow-catalog-v1 action convention over existing transports. These
/// descriptors grant no access, owner identity, source read or execution right.
/// Native finiteDouble authoring is distinct from portable Flow interchange.
public enum PluginFlowCatalog {
    public static let convention = "flow-catalog-v1"
    public static let version = 1
    public static let nativeProfile = "nero-native-finiteDouble-v3"
    public static let requiredFeatures: Set<String> = ["actions-v1", "action-stream-v1", "actions-long-running-v1"]
    public static let bodyBytes = 262_144
    public static let chunkBytes = 1_536

    public static let frame = PluginValueSchema([
        .init("kind", .string), .init("index", .number, required: false, minimum: 0, maximum: 170),
        .init("data", .string, required: false), .init("bytes", .number, required: false, minimum: 0, maximum: 262144),
        .init("sha256", .string, required: false), .init("meta", .string, required: false)
    ])
    public static let actions: [PluginRegisteredAction] = [
        .init("flow_catalog_discover", title: "Discover local flows", input: .init([
            .init("version", .number, minimum: 1, maximum: 1), .init("kind", .string),
            .init("query", .string, required: false), .init("cursor", .string, required: false),
            .init("limit", .number, required: false, minimum: 1, maximum: 8)
        ]), output: result, cancellable: true),
        .init("flow_catalog_inspect", title: "Inspect local flow source", input: .init([
            .init("version", .number, minimum: 1, maximum: 1), .init("kind", .string),
            .init("flow", .string, required: false), .init("revision", .string, required: false),
            .init("storage", .string, required: false), .init("capability", .string, required: false)
        ]), output: result, cancellable: true, completionTimeoutSeconds: 120, streamInput: frame, streamOutput: frame),
        .init("flow_catalog_author", title: "Author a local flow draft", input: .init([
            .init("version", .number, minimum: 1, maximum: 1), .init("profile", .string), .init("mode", .string), .init("flow", .string),
            .init("base", .string, required: false), .init("base_storage", .string, required: false),
            .init("bytes", .number, minimum: 1, maximum: 262144), .init("sha256", .string)
        ]), output: result, effect: .localChange, cancellable: true, completionTimeoutSeconds: 600, streamInput: frame, streamOutput: frame),
        .init("flow_catalog_test", title: "Test a flow with fixtures", input: .init([
            .init("version", .number, minimum: 1, maximum: 1), .init("profile", .string), .init("mode", .string),
            .init("flow", .string), .init("revision", .string), .init("storage", .string),
            .init("bytes", .number, minimum: 1, maximum: 262144), .init("sha256", .string)
        ]), output: result, cancellable: true, completionTimeoutSeconds: 300, streamInput: frame, streamOutput: frame),
        .init("flow_catalog_publish", title: "Publish a local flow", input: .init([
            .init("version", .number, minimum: 1, maximum: 1), .init("profile", .string),
            .init("flow", .string), .init("base", .string), .init("base_storage", .string)
        ]), output: result, effect: .localChange, cancellable: true, completionTimeoutSeconds: 300),
        .init("flow_catalog_observe", title: "Observe an owned flow request", input: .init([
            .init("version", .number, minimum: 1, maximum: 1), .init("request", .string)
        ]), output: result, cancellable: true)
    ]
    private static let result = PluginValueSchema([.init("result", .string)])
    public static var registration: PluginRegistration { .init(actions: actions) }

    /// Match exact complete descriptor bytes, not names/titles, product bundle
    /// IDs or language-normalized Unicode equality. Unknown feature strings do
    /// not activate a convention; no non-stream fallback is implied.
    public static func matches(_ registration: PluginRegistration, features: Set<String>) -> Bool {
        guard requiredFeatures.isSubset(of: features), (try? registration.validate()) != nil else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return actions.allSatisfy { expected in
            guard let actual = registration.actions.first(where: { $0.id == expected.id }),
                  let a = try? encoder.encode(actual), let b = try? encoder.encode(expected) else { return false }
            return a == b
        }
    }
}
