#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Call before creating native UI. A hosted module can show windows without
/// becoming a separate Dock or Command-Tab application.
@MainActor public enum PluginApplication {
    public static func configure(arguments: [String] = CommandLine.arguments) {
        if arguments.contains("--neronook-plugin") {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}
#endif
