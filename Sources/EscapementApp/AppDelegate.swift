import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = AppController()
    private var mainWindowController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        mainWindowController = MainWindowController(controller: controller)
        mainWindowController.showWindow(nil)

        controller.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    // Escapement is a single-window app, and for now scheduling only runs while
    // it is open, so closing the one window quits it rather than leaving an
    // invisible process behind. (Revisit if a background agent is added that
    // should outlive the window.)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { mainWindowController.showWindow(nil) }
        return true
    }

    // MARK: - Menu actions

    @objc func showMain(_ sender: Any?) {
        mainWindowController.showWindow(nil)
    }

    @objc func showLog(_ sender: Any?) {
        mainWindowController.showLog(sender)
    }

    @objc func backUpNow(_ sender: Any?) {
        mainWindowController.menuBackUpNow()
    }

    @objc func stopBackup(_ sender: Any?) {
        controller.stopBackup()
    }

    @objc func refresh(_ sender: Any?) {
        controller.requestRefresh()
    }

    @objc func enableBackground(_ sender: Any?) {
        mainWindowController.enableAgent()
    }

    @objc func disableBackground(_ sender: Any?) {
        mainWindowController.disableAgent()
    }

    // Show only the applicable enable/disable item, and gate the manual verbs.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(enableBackground(_:)):
            // Offer enable only when nothing is registered.
            return controller.agentStatus == .notRegistered || controller.agentStatus == .notFound
        case #selector(disableBackground(_:)):
            // Offer disable for anything registered, including a registration
            // still awaiting approval — otherwise there is no way to cancel it.
            return controller.agentStatus == .enabled
                || controller.agentStatus == .requiresApproval
        case #selector(backUpNow(_:)):
            return controller.isAgentEnabled && !controller.isBackupRunning
        case #selector(stopBackup(_:)):
            return controller.isAgentEnabled && controller.isBackupRunning
        default:
            return true
        }
    }
}
