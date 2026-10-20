import Foundation
import Combine

/// Optional, local, ephemeral speech output. No microphone, recording, cloud
/// delivery, persistent mutation or automatic speech is authorized by this contract.
public enum PluginSpeechContract {
    public static let speak = PluginRegisteredAction("speak_text", title: "Read text aloud on this Mac",
        input: .init([.init("text", .string)]), output: .init([.init("spoken", .boolean)]),
        effect: .readOnly, cancellable: true, timeoutSeconds: 180)
    public static func accepts(_ entry: PluginCatalogEntry) -> Bool { entry.action == speak }
    public static func validate(_ values: [String: PluginValue]) throws -> String {
        try speak.input.validate(values)
        guard case .string(let text) = values["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !["\n", "\r", "\t"].contains($0) })
        else { throw ModuleProblem("No readable speech text.") }; return text
    }
    public static func segments(_ text: String) throws -> [String] {
        guard text.utf8.count <= 32_768 else { throw ModuleProblem("Read up to 32 KB at a time.") }
        var result: [String] = [], current = ""
        for character in text {
            if current.utf8.count + String(character).utf8.count > 2048 {
                guard !current.isEmpty else { throw ModuleProblem("A text character exceeds the speech limit.") }
                result.append(current); current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        guard !result.isEmpty, result.count <= 32 else { throw ModuleProblem("No readable speech text.") }
        for segment in result { _ = try validate(["text": .string(segment)]) }
        return result
    }
}

/// Human-initiated playback shared by independent consumers. One text at a time,
/// no replay after reconnect or grant changes. A cancel retires all unsent segments.
@MainActor public final class PluginSpeechClient: ObservableObject {
    public var send: ((PluginBusMessage) -> Void)?
    @Published public private(set) var providers: [PluginCatalogEntry] = []
    @Published public private(set) var selectedKey = ""
    @Published public private(set) var status = "Allow a speech provider in Modules → Actions and connections."
    @Published public private(set) var active = false
    private var request: UUID?
    private var selected: PluginCatalogEntry?
    private var pending: [String] = []
    public init() {}
    public func select(_ key: String) {
        stop(); selectedKey = key; selected = providers.first { $0.address.key == key }
        status = selected == nil ? "Choose an allowed speech provider." : "Ready to read aloud"
    }
    public func catalog(_ entries: [PluginCatalogEntry]) {
        let available = entries.filter(PluginSpeechContract.accepts)
        // Each complete catalog is a fresh host epoch, even for identical bytes.
        // An in-flight request is never continued through a provider restart.
        if active { stop(); status = "Speech access changed. Press Read to try again." }
        providers = available; selected = available.first { $0.address.key == selectedKey }
        if selected == nil && !active { status = "Choose an allowed speech provider." }
    }
    public func read(_ text: String) throws {
        guard !active, let selected, providers.contains(selected), send != nil else { throw ModuleProblem("Choose an allowed speech provider first.") }
        pending = try PluginSpeechContract.segments(text); active = true; next()
    }
    private func next() {
        guard active, let selected, !pending.isEmpty else { return }
        let text = pending.removeFirst(), id = UUID(); request = id
        status = "Preparing local speech…"
        send?(.init(.invoke, requestID: id, address: selected.address, values: ["text": .string(text)]))
    }
    public func receive(_ message: PluginBusMessage) {
        guard message.requestID == request else { return }
        if message.operation == .failure { retire(message.error ?? "Speech provider unavailable."); return }
        guard let update = message.update else { return }
        status = update.message.isEmpty ? update.phase.rawValue : update.message
        guard update.phase.terminal else { return }
        request = nil
        if update.phase == .succeeded, update.values["spoken"] == .boolean(true), !pending.isEmpty { next() }
        else { retire(update.phase == .succeeded ? "Reading finished" : status) }
    }
    private func retire(_ text: String) { request = nil; pending = []; active = false; status = text }
    public func stop() {
        let id = request; retire("Reading stopped")
        if let id { send?(.init(.cancel, requestID: id)) }
    }
}
