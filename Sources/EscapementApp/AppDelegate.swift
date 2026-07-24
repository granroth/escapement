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
}
