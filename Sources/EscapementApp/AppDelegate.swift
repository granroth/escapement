import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = AppController()
    private var statusWindowController: StatusWindowController!
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        statusWindowController = StatusWindowController(controller: controller)
        statusWindowController.showWindow(nil)

        controller.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    // A backup scheduler should keep running with its window closed, so closing
    // the last window does not quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { statusWindowController.showWindow(nil) }
        return true
    }

    // MARK: - Menu actions

    @objc func showMain(_ sender: Any?) {
        statusWindowController.showWindow(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(controller: controller)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func refresh(_ sender: Any?) {
        controller.requestRefresh()
    }
}
