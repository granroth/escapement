import AppKit
import EscapementKit

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

    // Scheduling belongs to the background agent, which outlives this process
    // and keeps its own menu bar presence, so quitting the GUI when its window
    // closes costs nothing: the agent goes on running the schedules and the
    // menu bar icon is still there to prove it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { mainWindowController.showWindow(nil) }
        return true
    }

    // MARK: - Menu actions

    // The standard About panel resolves the *bundle* icon, which is the
    // full-bleed one drawn to survive the system's rounded-rect clip. The
    // panel does no clipping of its own, so hand it the free-form mark and
    // the wheel appears as drawn.
    @objc func showAbout(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let icon = AppIcon.freeform { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

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

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared(controller: controller).showWindow(sender)
    }

    @objc func pauseBackups(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? PauseOption else { return }
        controller.pause(option)
    }

    @objc func resumeBackups(_ sender: Any?) {
        controller.resume()
    }

    // Gate the verbs that only make sense when the agent can act on them.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(backUpNow(_:)):
            return controller.isAgentEnabled && !controller.isBackupRunning
        case #selector(stopBackup(_:)):
            return controller.isAgentEnabled && controller.isBackupRunning
        case #selector(pauseBackups(_:)):
            return controller.isAgentEnabled && !controller.isPaused
        case #selector(resumeBackups(_:)):
            return controller.isAgentEnabled && controller.isPaused
        default:
            return true
        }
    }
}
