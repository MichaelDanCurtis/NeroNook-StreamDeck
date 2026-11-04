import AppKit
import Darwin
@main struct Entry {
    @MainActor static func main() {
        let scope: BridgeScope
        do { scope = try BridgeScope.load(arguments: CommandLine.arguments, resourceDirectory: Bundle.main.resourceURL) }
        catch {
            try? FileHandle.standardError.write(contentsOf: Data(("Stream Deck scope refused: " + error.localizedDescription + "\n").utf8))
            Darwin.exit(EXIT_FAILURE)
        }
        let app = NSApplication.shared
        if CommandLine.arguments.contains("-port") {
            app.setActivationPolicy(.prohibited)
            let elgato = ElgatoClient(scope: scope)
            elgato.start()
            withExtendedLifetime(elgato) { app.run() }
        } else {
            let delegate = ModuleApp(scope: scope)
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
