#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI
import Combine

/// One negotiated host session. A stale or malformed update never replaces the
/// current palette. Appearance is independent of business-state revisions.
@MainActor public final class PluginAppearanceStore: ObservableObject {
    public static let shared = PluginAppearanceStore()
    @Published public private(set) var delivery: PluginAppearanceDelivery?
    private var identity: (String, UUID)?
    private var observations: [AnyCancellable] = []
    public init() {
        for name in [NSColor.systemColorsDidChangeNotification, NSApplication.didChangeScreenParametersNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification).receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification")).receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
    }
    public func beginSession(pluginID: String, session: UUID) {
        guard identity?.0 != pluginID || identity?.1 != session else { return }
        identity = (pluginID, session); delivery = nil
    }
    @discardableResult public func receive(_ message: PluginMessage) -> Bool {
        guard message.apiVersion == 1, message.type == "appearance", message.pluginID == identity?.0,
              message.session == identity?.1, let value = message.appearance else { return false }
        return update(value)
    }
    @discardableResult public func update(_ value: PluginAppearanceDelivery) -> Bool {
        guard (try? value.validate()) != nil, delivery.map({ value.revision > $0.revision }) ?? true else { return false }
        delivery = value; return true
    }
    public func context(screenNumber: UInt32?, fallback: ColorScheme) -> PluginAppearanceContext {
        var value = delivery?.displays.first(where: { $0.screenNumber == screenNumber }) ?? delivery?.shared ?? .init()
        // System mode follows the actual surface, even when a standalone plugin
        // is running without the host or a display has just been connected.
        if value.mode == .system { value.scheme = fallback == .dark ? .dark : .light }
        value.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        value.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        value.increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return value
    }
}
private struct PluginAppearanceKey: EnvironmentKey { static let defaultValue = PluginAppearanceContext() }
extension EnvironmentValues {
    public var pluginAppearance: PluginAppearanceContext {
        get { self[PluginAppearanceKey.self] }
        set { self[PluginAppearanceKey.self] = newValue }
    }
}
extension Color {
    public init(pluginHex: String) {
        let n = UInt32(pluginHex.dropFirst(), radix: 16) ?? 0
        self.init(.sRGB, red: Double((n >> 16) & 255)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255, opacity: 1)
    }
}

/// Wrap an independently owned native window once. Moving the window between
/// displays changes its context without recreating content or losing drafts.
public struct PluginThemedRoot<Content: View>: View {
    @ObservedObject private var store: PluginAppearanceStore
    @Environment(\.colorScheme) private var systemScheme
    @State private var screenNumber: UInt32?
    private let content: Content
    private let fillsBackground: Bool
    public init(store: PluginAppearanceStore = .shared, background: Bool = true, @ViewBuilder content: () -> Content) { self.store=store; self.fillsBackground=background; self.content=content() }
    public var body: some View {
        let appearance = store.context(screenNumber: screenNumber, fallback: systemScheme)
        content
            .buttonStyle(PluginGlassButtonStyle())
            .environment(\.pluginAppearance, appearance)
            .preferredColorScheme(appearance.mode == .system ? nil : appearance.scheme == .dark ? .dark : .light)
            .tint(Color(pluginHex: appearance.palette.accent))
            .accentColor(Color(pluginHex: appearance.palette.accent))
            .foregroundStyle(Color(pluginHex: appearance.palette.text))
            .background { if fillsBackground { PluginGlassSurface(radius:0).environment(\.pluginAppearance,appearance) } }
            .background(PluginScreenProbe(screenNumber: $screenNumber))
    }
}
private struct PluginScreenProbe: NSViewRepresentable {
    @Binding var screenNumber: UInt32?
    func makeNSView(context: Context) -> Probe { let v=Probe(); v.changed={ value in if screenNumber != value { screenNumber=value } }; return v }
    func updateNSView(_ view: Probe, context: Context) { view.changed={ value in if screenNumber != value { screenNumber=value } } }
    final class Probe: NSView {
        var changed: ((UInt32?) -> Void)?
        private var observation: AnyCancellable?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification, object: window).receive(on: RunLoop.main).sink { [weak self] _ in self?.report() }
            report()
        }
        func report() { let number=(window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value; DispatchQueue.main.async { [weak self] in self?.changed?(number) } }
    }
}

public struct PluginThemeCard<Content: View>: View {
    @Environment(\.pluginAppearance) private var appearance
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content=content() }
    public var body: some View {
        content.padding(16 * appearance.theme.style.spacingScale)
            .background(PluginGlassSurface(radius:appearance.theme.style.cornerRadius))

    }
}

extension View {
    public func pluginThemed(background: Bool = true) -> some View { PluginThemedRoot(background:background) { self } }
}

#endif
