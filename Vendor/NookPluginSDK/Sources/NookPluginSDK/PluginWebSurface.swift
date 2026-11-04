#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import SwiftUI
import WebKit
import Combine

private final class PluginVisibleWebView:WKWebView {
    var visibilityChanged:((Bool)->Void)?
    private var interactionEnabled = true
    private var observations:[AnyCancellable]=[]
    private var lastVisible:Bool?
    override var acceptsFirstResponder: Bool { interactionEnabled && super.acceptsFirstResponder }
    override var canBecomeKeyView: Bool { interactionEnabled && super.canBecomeKeyView }
    override func becomeFirstResponder() -> Bool { interactionEnabled && super.becomeFirstResponder() }
    override func hitTest(_ point: NSPoint) -> NSView? { interactionEnabled ? super.hitTest(point) : nil }
    func setInteractionEnabled(_ enabled: Bool) {
        interactionEnabled = enabled
        setAccessibilityHidden(!enabled)
        if !enabled, let window, let responder = window.firstResponder as? NSView,
           responder === self || responder.isDescendant(of: self) {
            // The host selects the review's focus. Re-enabling never steals it.
            window.makeFirstResponder(nil)
        }
    }
    var actuallyVisible:Bool { window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor } ?? false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow();observations.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification] {
                NotificationCenter.default.publisher(for:name,object:window).receive(on:RunLoop.main).sink { [weak self] _ in self?.reportVisibility() }.store(in:&observations)
            }
        }
        reportVisibility()
    }
    override func viewDidHide(){super.viewDidHide();reportVisibility()}
    override func viewDidUnhide(){super.viewDidUnhide();reportVisibility()}
    func reportVisibility(){let value=actuallyVisible;guard lastVisible != value else{return};lastVisible=value;visibilityChanged?(value)}
}

/// Same custom view renderer for a host stage or a plugin-owned standalone window.
public struct PluginWebSurface: NSViewRepresentable {
    @Environment(\.pluginAppearance) private var appearance
    @Environment(\.isEnabled) private var isEnabled
    public let root: URL
    public let panelID: String
    public let definition: PluginCustomView
    public let onResource: ((PluginViewResourceRequest) async throws -> PluginViewResourceResult)?
    public let onEvent: (PluginViewEvent) throws -> Void
    public init(root: URL, panelID: String, definition: PluginCustomView, onResource: ((PluginViewResourceRequest) async throws -> PluginViewResourceResult)? = nil, onEvent: @escaping (PluginViewEvent) throws -> Void) {
        self.root = root; self.panelID = panelID; self.definition = definition; self.onEvent = onEvent; self.onResource = onResource
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func makeNSView(context: Context) -> WKWebView {
        context.coordinator.owner = self
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: PluginViewResources.scheme)
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "neroView")
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "neroAvatarPresence")
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "neroAvatarModel")
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "neroAvatarReaction")
        configuration.userContentController.addUserScript(.init(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = PluginVisibleWebView(frame: .zero, configuration: configuration)
        web.visibilityChanged={ [weak coordinator=context.coordinator,weak web] visible in
            guard let web else{return};coordinator?.seasonalVisibility(web,visible:visible)
        }
        web.navigationDelegate = context.coordinator; web.uiDelegate = context.coordinator
        web.underPageBackgroundColor = .clear
        context.coordinator.updateInteraction(web)
        context.coordinator.load(web)
        return web
    }
    public func updateNSView(_ web: WKWebView, context: Context) {
        let previous = context.coordinator.owner
        context.coordinator.owner = self
        context.coordinator.updateInteraction(web)
        if previous.root != root || previous.panelID != panelID || previous.definition.entry != definition.entry || previous.definition.revision != definition.revision || previous.definition.frames != definition.frames {
            context.coordinator.load(web)
        } else if previous.definition.state != definition.state || previous.definition.avatarPlayback != definition.avatarPlayback { context.coordinator.update(web) }
        context.coordinator.updateAppearance(web)
    }
    public static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.evaluateJavaScript("window.NookSeasonal?.dispose()",completionHandler:nil)
        (web as? PluginVisibleWebView)?.visibilityChanged=nil
        coordinator.active = false; coordinator.cancelResources(); web.stopLoading()
        coordinator.stopPointer()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.navigationDelegate = nil; web.uiDelegate = nil
    }
    private static let bridge = """
    (() => {
      let state = Object.freeze({}); const listeners = new Set();
      Object.defineProperty(window, '__neroReceive', { value: value => { state = Object.freeze(value); for (const f of listeners) { try { f(state); } catch (_) {} } } });
      Object.defineProperty(window, 'nero', { value: Object.freeze({
        get state() { return state; },
        get appearance() { return window.__neroAppearanceAPI.current; },
        onAppearance(callback) { return window.__neroAppearanceAPI.onChange(callback); },
        onState(callback) { listeners.add(callback); callback(state); return () => listeners.delete(callback); },
        emit(name, values = {}) { return window.webkit.messageHandlers.neroView.postMessage({name, values}); }
      }) });
    })();
    """
    /// This receiver lives only in WebKit's isolated client world. The page
    /// cannot call it to re-enable input; native admission remains synchronous.
    private static func interactionBootstrap(documentID: String, enabled: Bool) throws -> String {
        let document = String(decoding: try JSONEncoder().encode(documentID), as: UTF8.self)
        return """
        (() => {
          const documentID = \(document);
          let serial = 0, enabled = \(enabled ? "true" : "false"), blocked = false, previousInert = false;
          const apply = () => {
            const root = document.documentElement;
            if (!root) return;
            if (!enabled) {
              if (!blocked) { previousInert = root.inert; blocked = true; }
              root.inert = true;
              const focused = document.activeElement;
              if (focused && typeof focused.blur === 'function') focused.blur();
            } else if (blocked) { root.inert = previousInert; blocked = false; }
          };
          Object.defineProperty(window, '__nookInteractionReceive', { value: (nextEnabled, nextSerial, nextDocument) => {
            if (nextDocument !== documentID || typeof nextEnabled !== 'boolean' || !Number.isSafeInteger(nextSerial) || nextSerial <= serial) return false;
            serial = nextSerial; enabled = nextEnabled; apply(); return true;
          }});
          apply();
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', apply, {once: true});
        })();
        """
    }
    @MainActor public final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
        var owner: PluginWebSurface
        var active = true
        private var loaded = false
        private var appearanceDocument = UUID().uuidString
        private var appearanceSerial = 0
        private var lastAppearance: PluginAppearanceContext?
        private var interactionSerial = 0
        private var lastInteractionEnabled: Bool?
        private var eventsAt = Date.distantPast
        private var eventCount = 0
        private var assetBudget = PluginBundledAssetBudget()
        private let resourceSlots = ViewResourceSlots()
        private var resourceTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var resourceWindow = Date()
        private var resourceCount = 0
        private var resourceBytes = 0
        private let pointer = PluginAvatarPointerSource()
        private var pointerBusy=false, pointerPending=false
        private var pointerSample: PluginAvatarPointerSource.Sample?
        private var pointerEpoch=0
        private var pointerRequested = false
        private let reactionAudioOwner=UUID()
        private var delegatedReaction:UUID?
        private var reactionAt=Date.distantPast
        func stopPointer() { PluginAvatarReactionAudio.shared.stop(owner:reactionAudioOwner); pointer.stop(); pointerEpoch += 1; pointerBusy=false; pointerPending=false; pointerSample=nil }
        private func trackPointer(_ web: WKWebView, enabled: Bool) {
            pointerRequested = enabled
            guard active, loaded else { return }
            if enabled && owner.isEnabled && !owner.appearance.reduceMotion {
                pointer.start(view:web) { [weak self,weak web] sample in
                    guard let self,let web,self.active,self.loaded else { return }
                    self.pointerSample=sample;self.pointerPending=true;self.flushPointer(web)
                }
            } else {
                pointer.stop();pointerSample=nil;pointerPending=true;flushPointer(web)
            }
        }
        private func flushPointer(_ web: WKWebView) {
            guard active,loaded,!pointerBusy,pointerPending else { return }
            let sample:Any=pointerSample.map { $0.values as Any } ?? NSNull()
            pointerPending=false;pointerBusy=true;let epoch=pointerEpoch
            Task { @MainActor [weak self,weak web] in
                guard let self,let web,self.active,self.loaded,self.pointerEpoch==epoch else { return }
                _ = try? await web.callAsyncJavaScript("window.NookAvatar?.pointer(sample)",arguments:["sample":sample],in:nil,contentWorld:.page)
                guard self.active,self.pointerEpoch==epoch else { return }
                self.pointerBusy=false;self.flushPointer(web)
            }
        }
        private func stopDelegatedReaction() {
            guard let id=delegatedReaction else{return};delegatedReaction=nil
            let event=PluginViewEvent(panelID:owner.panelID,revision:owner.definition.revision,name:PluginAvatarPlayback.event,values:["kind":.string("stop"),"id":.string(id.uuidString)])
            if (try? owner.definition.validate(event)) != nil {try? owner.onEvent(event)}
        }
        func cancelResources() { stopDelegatedReaction(); let tasks = resourceTasks.values; resourceTasks.removeAll(); for task in tasks { task.cancel() } }
        init(_ owner: PluginWebSurface) { self.owner = owner }
        func updateInteraction(_ web: WKWebView, force: Bool = false) {
            let enabled = owner.isEnabled
            (web as? PluginVisibleWebView)?.setInteractionEnabled(enabled)
            guard active, owner.isEnabled == enabled, force || lastInteractionEnabled != enabled else { return }
            let previous = lastInteractionEnabled
            lastInteractionEnabled = enabled; interactionSerial += 1
            let serial = interactionSerial, document = appearanceDocument
            if !enabled {
                // Only native-owned avatar reactions/pointer tracking stop.
                // This does not cancel speech, a provider action or a job.
                stopDelegatedReaction(); stopPointer()
            } else if previous == false && pointerRequested { trackPointer(web, enabled: true) }
            guard loaded, active, appearanceDocument == document,
                  interactionSerial == serial, owner.isEnabled == enabled else { return }
            Task { @MainActor [weak self, weak web] in
                guard let self, let web, self.active, self.loaded,
                      self.appearanceDocument == document, self.interactionSerial == serial,
                      self.owner.isEnabled == enabled else { return }
                _ = try? await web.callAsyncJavaScript("return window.__nookInteractionReceive(enabled, serial, document)",
                    arguments: ["enabled": enabled, "serial": serial, "document": document], in: nil, contentWorld: .defaultClient)
            }
        }
        func seasonalVisibility(_ web:WKWebView,visible:Bool) {
            guard active,loaded else{return};if !visible {stopDelegatedReaction()};let document=appearanceDocument
            Task { @MainActor [weak self,weak web] in
                guard let self,let web,self.active,self.loaded,self.appearanceDocument==document else{return}
                _ = try? await web.callAsyncJavaScript("window.NookSeasonal?.setVisible(visible); if(!visible) window.NookAvatar?.stop()",arguments:["visible":visible],in:nil,contentWorld:.page)
            }
        }
        func load(_ web: WKWebView) {
            cancelResources(); stopPointer(); loaded = false; active = true; assetBudget = PluginBundledAssetBudget()
            appearanceDocument=UUID().uuidString; appearanceSerial=0; lastAppearance=nil
            interactionSerial = 0; lastInteractionEnabled = nil; pointerRequested = false
            do {
                try owner.definition.validate()
                let scripts = web.configuration.userContentController
                scripts.removeAllUserScripts()
                scripts.addUserScript(.init(source: try PluginWebSurface.interactionBootstrap(documentID: appearanceDocument, enabled: owner.isEnabled),
                    injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
                scripts.addUserScript(.init(source: try PluginThemeWeb.bootstrap(owner.appearance, documentID:appearanceDocument), injectionTime: .atDocumentStart, forMainFrameOnly: true))
                scripts.addUserScript(.init(source: "Object.defineProperty(window, '__nookAvatarDocument', {value: \(String(decoding: try JSONEncoder().encode(appearanceDocument), as: UTF8.self))});", injectionTime: .atDocumentStart, forMainFrameOnly: true))
                scripts.addUserScript(.init(source: PluginWebSurface.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                scripts.addUserScript(.init(source: PluginInterfaceWeb.bootstrap, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
                _ = try PluginViewResources.file(owner.definition.entry, root: owner.root)
                web.load(URLRequest(url: URL(string: "\(PluginViewResources.scheme)://surface/\(owner.definition.entry)")!))
            } catch { showError(web) }
        }
        private func showError(_ web: WKWebView) {
            stopPointer(); loaded = false
            web.loadHTMLString("<html><body style='background:#19191f;color:#ddd;font:14px system-ui;padding:24px'>This plugin view could not load. Open its settings or restart the module.</body></html>", baseURL: nil)
        }
        func update(_ web: WKWebView) {
            guard loaded, active, let data = try? JSONEncoder().encode(owner.definition.state), let values = try? JSONSerialization.jsonObject(with: data) else { return }
            let playback:Any = owner.definition.avatarPlayback.flatMap { try? JSONSerialization.jsonObject(with:JSONEncoder().encode($0)) } ?? NSNull()
            Task { @MainActor in _ = try? await web.callAsyncJavaScript("window.__neroReceive(state); window.NookAvatar?.playback(playback)", arguments: ["state": values,"playback":playback], in: nil, contentWorld: .page) }
        }
        func updateAppearance(_ web: WKWebView) {
            guard loaded, active, lastAppearance != owner.appearance, let data = try? JSONEncoder().encode(owner.appearance), let value = try? JSONSerialization.jsonObject(with: data) else { return }
            lastAppearance=owner.appearance; appearanceSerial += 1
            if owner.appearance.avatarReactionsSuppressed == true { PluginAvatarReactionAudio.shared.stop(owner:reactionAudioOwner) }
            if owner.appearance.reduceMotion { trackPointer(web,enabled:false) }
            let serial=appearanceSerial, document=appearanceDocument
            Task { @MainActor [weak self] in
                guard let self, self.active, self.appearanceDocument == document else { return }
                _ = try? await web.callAsyncJavaScript("window.__neroAppearanceReceive(appearance, serial, document)", arguments: ["appearance": value,"serial":serial,"document":document], in: nil, contentWorld: .page)
            }
        }
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = webView.url?.scheme == PluginViewResources.scheme; updateAppearance(webView); update(webView)
            updateInteraction(webView, force: true)
            seasonalVisibility(webView,visible:(webView as? PluginVisibleWebView)?.actuallyVisible == true)
            let epoch=pointerEpoch
            Task { @MainActor [weak self,weak webView] in
                guard let self,let webView,self.active,self.loaded else { return }
                let wants = try? await webView.callAsyncJavaScript("return window.NookAvatar?.wantsPointer === true",arguments:[:],in:nil,contentWorld:.page)
                guard self.active,self.loaded,self.pointerEpoch==epoch else { return }
                self.trackPointer(webView,enabled:(wants as? Bool)==true)
            }
        }
        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { showError(webView) }
        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if webView.url?.scheme != "about" { showError(webView) } }
        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            // Only this document (and fragment links) can navigate. Never open a browser automatically.
            let allowed = !navigationAction.shouldPerformDownload && url?.scheme == PluginViewResources.scheme && url?.host == "surface" && url?.path == "/" + owner.definition.entry && navigationAction.targetFrame?.isMainFrame == true
            let embedded = !navigationAction.shouldPerformDownload && navigationAction.targetFrame?.isMainFrame == false && url.map { target in (owner.definition.frames ?? []).contains { $0.allows(target) } } == true
            decisionHandler(allowed || embedded || url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
        public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
        public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) { completionHandler(nil) }
        public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            do {
                guard active, let url = urlSchemeTask.request.url, url.scheme == PluginViewResources.scheme, url.host == "surface", url.user == nil, url.password == nil,
                      urlSchemeTask.request.httpMethod == "GET" else { throw ModuleProblem("Invalid resource request.") }
                guard url.query == nil, url.fragment == nil, url.port == nil else { throw ModuleProblem("Invalid resource URL.") }
                if url.path.hasPrefix("/__nook_sdk__/") {
                    guard let data = PluginVisualAssets.data(path: url.path) else { throw ModuleProblem("Unknown SDK asset.") }
                    try assetBudget.consume(byteCount: data.count)
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": PluginVisualAssets.mime(path:url.path), "X-Content-Type-Options": "nosniff", "Cache-Control": "max-age=86400"])!
                    urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                    return
                }
                if url.path.hasPrefix("/_plugin/") {
                    let request = PluginViewResourceRequest(panelID: owner.panelID, revision: owner.definition.revision, path: String(url.path.dropFirst(9)))
                    try owner.definition.validate(request)
                    guard let provider = owner.onResource else { throw ModuleProblem("Plugin resources are unavailable.") }
                    if Date().timeIntervalSince(resourceWindow) >= 60 { resourceWindow = Date(); resourceCount = 0; resourceBytes = 0 }
                    guard resourceTasks.count < 512, resourceCount < 1200, resourceBytes < 32 * 1024 * 1024 else { throw ModuleProblem("Resource budget exceeded.") }
                    resourceCount += 1
                    let key = ObjectIdentifier(urlSchemeTask)
                    resourceTasks[key] = Task { @MainActor [weak self] in
                        guard let self else { return }
                        do {
                            try await self.resourceSlots.acquire(key)
                            defer { self.resourceSlots.release() }
                            try Task.checkCancellation()
                            let result = try await provider(request)
                            guard self.active, self.resourceTasks[key] != nil else { return }
                            try self.owner.definition.validate(request); try result.validate()
                            guard result.id == request.id, let bytes = result.data, let mime = result.mime else { throw ModuleProblem("Resource unavailable.") }
                            self.resourceBytes += bytes.count
                            guard self.resourceBytes <= 32 * 1024 * 1024 else { throw ModuleProblem("Resource budget exceeded.") }
                            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store"])!
                            self.resourceTasks[key] = nil
                            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(bytes); urlSchemeTask.didFinish()
                        } catch {
                            guard self.active, self.resourceTasks.removeValue(forKey: key) != nil else { return }
                            urlSchemeTask.didFailWithError(ModuleProblem("Plugin imagery unavailable."))
                        }
                    }
                    return
                }
                let file = try PluginViewResources.file(String(url.path.dropFirst()), root: owner.root)
                let data = try Data(contentsOf: file)
                guard data.count <= 2 * 1024 * 1024 else { throw ModuleProblem("Asset exceeded its limit.") }
                try assetBudget.consume(byteCount: data.count)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": PluginViewResources.mime(file.pathExtension)! + (file.pathExtension == "html" ? "; charset=utf-8" : ""),
                    "Content-Security-Policy": "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src data:; frame-src \((owner.definition.frames ?? []).isEmpty ? "'none'" : (owner.definition.frames ?? []).map(\.origin).joined(separator: " ")); object-src 'none'; base-uri 'none'; form-action 'none'; worker-src 'none'",
                    "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store"
                ])!
                urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch { urlSchemeTask.didFailWithError(ModuleProblem("Plugin asset unavailable.")) }
        }
        public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { resourceTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel() }
        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            if message.name == "neroAvatarReaction" {
                guard active,message.frameInfo.isMainFrame,
                      let url=message.frameInfo.request.url,url.scheme==PluginViewResources.scheme,url.host=="surface",url.path=="/"+owner.definition.entry,
                      url.query==nil,url.fragment==nil,url.user==nil,url.password==nil,url.port==nil,
                      let body=message.body as? [String:Any],Set(body.keys)==Set(["kind","document"]),body["document"] as? String==appearanceDocument,
                      let kind=body["kind"] as? String,(["stop"]+PluginAvatarReaction.allCases.map(\.rawValue)).contains(kind) else { replyHandler(nil,"Character reaction unavailable.");return }
                if kind=="stop" { stopDelegatedReaction();PluginAvatarReactionAudio.shared.stop(owner:reactionAudioOwner);replyHandler(["stopped":true],nil);return}
                guard owner.isEnabled else { replyHandler(nil, "Character reaction unavailable."); return }
                guard let reaction=PluginAvatarReaction(rawValue:kind),owner.appearance.avatars?.characterReactions != false,owner.appearance.avatarReactionsSuppressed != true,!owner.appearance.reduceMotion,
                      Date().timeIntervalSince(reactionAt)>=1 else {replyHandler(["duration":1.3],nil);return}
                reactionAt=Date()
                if owner.definition.avatarReactions == true, reaction.hasAudio, owner.appearance.avatars?.reactionSounds != false {
                    stopDelegatedReaction()
                    let id=UUID();delegatedReaction=id
                    let event=PluginViewEvent(panelID:owner.panelID,revision:owner.definition.revision,name:PluginAvatarPlayback.event,values:["kind":.string(kind),"id":.string(id.uuidString)])
                    do {try owner.definition.validate(event);try owner.onEvent(event);replyHandler(["delegated":true,"id":id.uuidString],nil)}
                    catch {delegatedReaction=nil;replyHandler(nil,"Selected voice is unavailable.")}
                } else {replyHandler(["duration":reaction.duration],nil)}
                return
            }
            if message.name == "neroAvatarModel" {
                do {
                    // Scripts can attach before didFinish. The exact main-frame
                    // entry and per-load document token qualify that loading document.
                    guard active, message.frameInfo.isMainFrame,
                          let url = message.frameInfo.request.url,
                          url.scheme == PluginViewResources.scheme, url.host == "surface",
                          url.path == "/" + owner.definition.entry,
                          url.query == nil, url.fragment == nil, url.port == nil,
                          url.user == nil, url.password == nil else {
                        throw ModuleProblem("Avatar surface is unavailable.")
                    }
                    let request = try PluginAvatarModelRequest(body: message.body, documentID: appearanceDocument, selection: owner.appearance.avatars)
                    let data = try request.data()
                    try assetBudget.consume(byteCount: data.count)
                    replyHandler(["style": request.style, "persona": request.persona.rawValue,
                                  "source": "data:model/gltf-binary;base64," + data.base64EncodedString()], nil)
                } catch { replyHandler(nil, "Avatar artwork is unavailable.") }
                return
            }
            if message.name == "neroAvatarPresence" {
                guard active,loaded,message.frameInfo.isMainFrame,
                      message.frameInfo.request.url?.scheme == PluginViewResources.scheme,
                      message.frameInfo.request.url?.host == "surface",
                      let body=message.body as? [String:Any],Set(body.keys)==Set(["active"]),
                      let enabled=body["active"] as? Bool,let web=message.webView else {
                    replyHandler(nil,"Avatar surface is unavailable.");return
                }
                trackPointer(web,enabled:enabled);replyHandler(["accepted":true],nil);return
            }
            do {
                guard active, loaded, owner.isEnabled, message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == PluginViewResources.scheme,
                      message.frameInfo.request.url?.host == "surface", let body = message.body as? [String: Any],
                      Set(body.keys) == Set(["name", "values"]), let name = body["name"] as? String,
                      let values = body["values"] as? [String: Any], values.count <= 16,
                      JSONSerialization.isValidJSONObject(values) else { throw ModuleProblem("Invalid view event.") }
                if Date().timeIntervalSince(eventsAt) >= 1 { eventsAt = Date(); eventCount = 0 }
                guard eventCount < 30 else { throw ModuleProblem("View event rate exceeded.") }; eventCount += 1
                let data = try JSONSerialization.data(withJSONObject: values)
                guard data.count <= 32768 else { throw ModuleProblem("View event is too large.") }
                let event = PluginViewEvent(panelID: owner.panelID, revision: owner.definition.revision, name: name, values: try JSONDecoder().decode([String: PluginValue].self, from: data))
                try owner.definition.validate(event); try owner.onEvent(event)
                replyHandler(["accepted": true], nil)
            } catch { replyHandler(nil, "The plugin did not accept this view event.") }
        }
    }
}

/// Limit concurrent transport without dropping tiles during an ordinary resize.
@MainActor private final class ViewResourceSlots {
    private var available = 12
    private var order: [ObjectIdentifier] = []
    private var waiting: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
    func acquire(_ id: ObjectIdentifier) async throws {
        try Task.checkCancellation()
        if available > 0 { available -= 1; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                order.append(id); waiting[id] = continuation
            }
        } onCancel: { Task { @MainActor [weak self] in
            guard let self, let continuation = self.waiting.removeValue(forKey: id) else { return }
            self.order.removeAll { $0 == id }; continuation.resume(throwing: CancellationError())
        } }
    }
    func release() {
        if let id = order.first {
            order.removeFirst(); waiting.removeValue(forKey: id)?.resume()
        } else { available += 1 }
    }
}

#endif
