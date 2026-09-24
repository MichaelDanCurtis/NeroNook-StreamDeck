import Foundation
import Network

/// Optional application-launch transport. Credentials are ephemeral process
/// environment values, never command arguments or persistent plugin settings.
public final class PluginApplicationChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "NookPluginSDK.application-channel")
    private let token: String
    private var lines = PluginLines()
    private var stopped = false
    private var queuedBytes = 0
    private var receiver: (@Sendable (PluginMessage?) -> Void)?
    public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let raw = environment["NERONOOK_PLUGIN_PORT"], let number = UInt16(raw), number > 0,
              let token = environment["NERONOOK_PLUGIN_TOKEN"], token.count == 72,
              token.allSatisfy({ $0.isHexDigit || $0 == "-" }), let port = NWEndpoint.Port(rawValue: number) else { return nil }
        self.token = token; connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
    }
    public func start(_ receive: @escaping @Sendable (PluginMessage?) -> Void) {
        receiver = receive
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            if case .ready = state {
                self.connection.send(content: Data((self.token + "\n").utf8), completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil { self.finish() } else { self.read(receive) }
                })
            } else if case .failed = state { self.finish() }
        }
        connection.start(queue: queue)
    }
    private func read(_ receive: @escaping @Sendable (PluginMessage?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, done, error in
            guard let self, !self.stopped else { return }
            do { if let data { for message in try self.lines.append(data) { receive(message) } } }
            catch { self.finish(); return }
            if done || error != nil { self.finish() } else { self.read(receive) }
        }
    }
    private func finish() {
        guard !stopped else { return }
        stopped = true; connection.cancel(); receiver?(nil); receiver = nil
    }
    public func stop() { queue.async { [weak self] in self?.finish() } }
    public func send(_ message: PluginMessage) throws {
        let data = try message.encoded()
        queue.async { [weak self] in
            guard let self, !self.stopped, self.queuedBytes + data.count <= 8 * 1024 * 1024 else { self?.finish(); return }
            self.queuedBytes += data.count
            self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }; self.queuedBytes -= data.count
                if error != nil { self.finish() }
            })
        }
    }
}
