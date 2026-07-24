import AppKit

// The background agent runs as a headless LaunchAgent. `.prohibited` gives it
// AppKit's run loop — needed for wake notifications and dispatch timers — with
// no Dock icon, menu bar, or ability to activate.
@MainActor
enum AgentMain {
    static let service = AgentService()

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        service.start()
        application.run()
    }
}

AgentMain.main()
