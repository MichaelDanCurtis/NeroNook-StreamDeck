#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

/// Retain in the plugin process. Window content is entirely plugin-owned SwiftUI.
@MainActor public final class PluginWindows {
    private var windows: [String: NSWindow] = [:]
    public init() {}
    public func show<Content: View>(_ id: String, title: String, size: CGSize = CGSize(width: 800, height: 450), @ViewBuilder content: () -> Content) {
        PluginApplication.configure()
        let window: NSWindow
        if let existing = windows[id] { window = existing }
        else {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.center(); windows[id] = window
        }
        window.title = title; window.contentView = NSHostingView(rootView: PluginThemedRoot { content() })
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    public func close(_ id: String) { windows.removeValue(forKey: id)?.close() }
    public func closeAll() { for window in windows.values { window.close() }; windows = [:] }
}

#endif
