import AppKit

// The background agent runs as a LaunchAgent. `.accessory` gives it AppKit's
// run loop — needed for wake notifications and dispatch timers — plus a menu
// bar extra, with no Dock icon and no ability to activate. The agent owns the
// status item so that the icon's presence is itself the indicator that
// scheduling is live.
@MainActor
enum AgentMain {
    static let service = AgentService()

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        service.start()
        application.run()
    }
}

AgentMain.main()
