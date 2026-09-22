import AppKit
@main struct Entry {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ModuleApp()
        var elgato: ElgatoClient?
        if CommandLine.arguments.contains("-port") {
            app.setActivationPolicy(.prohibited)
            elgato = ElgatoClient()
            elgato?.start()
        } else { app.delegate = delegate }
        withExtendedLifetime((delegate, elgato)) { app.run() }
    }
}
