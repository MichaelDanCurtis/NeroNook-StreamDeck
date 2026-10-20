import Foundation
import ImageIO

/// Raster bytes supplied by the owning plugin. The host never interprets a path as a URL.
public struct PluginViewResourceRequest: Codable, Equatable, Sendable {
    public var id: UUID
    public var panelID: String
    public var revision: String
    public var path: String
    public init(id: UUID = UUID(), panelID: String, revision: String, path: String) {
        self.id = id; self.panelID = panelID; self.revision = revision; self.path = path
    }
}
public struct PluginViewResourceResult: Codable, Sendable {
    public var id: UUID
    public var mime: String?
    public var data: Data?
    public var error: String?
    public init(id: UUID, mime: String? = nil, data: Data? = nil, error: String? = nil) {
        self.id = id; self.mime = mime; self.data = data; self.error = error
    }
    public func validate() throws {
        if let error {
            guard data == nil, mime == nil, !error.isEmpty, error.count <= 200 else { throw ModuleProblem("Invalid resource error.") }
            return
        }
        guard let data, !data.isEmpty, data.count <= 65536, let mime,
              let expected = ["image/png":"public.png", "image/jpeg":"public.jpeg", "image/webp":"org.webmproject.webp"][mime],
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == expected, CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...2048).contains(width), (1...2048).contains(height) else { throw ModuleProblem("Invalid raster resource.") }
    }
}

/// Session-bound requests, bounded waiting, and cancellation on view or process teardown.
@MainActor public final class PluginViewResourceBroker {
    private struct Pending {
        let plugin: String
        let session: UUID
        let continuation: CheckedContinuation<PluginViewResourceResult, Error>
        let timeout: Task<Void, Never>
        let cancel: () -> Void
    }
    private var pending: [UUID: Pending] = [:]
    public init() {}
    public var count: Int { pending.count }
    public func request(_ request: PluginViewResourceRequest, plugin: String, session: UUID,
                        send: () throws -> Void, cancel: @escaping () -> Void) async throws -> PluginViewResourceResult {
        guard pending.count < 128, pending.values.filter({ $0.plugin == plugin }).count < 48, pending[request.id] == nil else { throw ModuleProblem("Resource queue is full.") }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    self?.cancel(request.id)
                }
                pending[request.id] = Pending(plugin: plugin, session: session, continuation: continuation, timeout: timeout, cancel: cancel)
                do { try send() } catch { finish(request.id, .failure(error)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(request.id) } }
    }
    public func receive(_ result: PluginViewResourceResult, plugin: String, session: UUID) throws {
        guard let item = pending[result.id] else { return } // A canceled/expired request cannot reappear.
        guard item.plugin == plugin, item.session == session else { throw ModuleProblem("Resource session mismatch.") }
        do {
            try result.validate()
            if let error = result.error { finish(result.id, .failure(ModuleProblem(error))) }
            else { finish(result.id, .success(result)) }
        } catch { finish(result.id, .failure(error)); throw error }
    }
    public func disconnect(_ plugin: String) {
        for id in pending.filter({ $0.value.plugin == plugin }).map(\.key) { cancel(id) }
    }
    private func cancel(_ id: UUID) {
        guard let item = pending[id] else { return }
        item.cancel(); finish(id, .failure(CancellationError()))
    }
    private func finish(_ id: UUID, _ result: Result<PluginViewResourceResult, Error>) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timeout.cancel(); item.continuation.resume(with: result)
    }
}
