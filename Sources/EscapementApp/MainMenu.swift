import AppKit

/// Builds the app's menu bar in code. Every user action has a menu path, not
/// only a toolbar button. Menu items that make no sense for a single-window
/// utility — Enter Full Screen, the window-tab commands — are intentionally
/// absent, and the window disables the system features that would re-add them.
enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About Escapement",
            action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Escapement", action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Escapement", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        // Schedule menu — the app's own verbs.
        let scheduleItem = NSMenuItem()
        mainMenu.addItem(scheduleItem)
        let scheduleMenu = NSMenu(title: "Schedule")
        scheduleItem.submenu = scheduleMenu
        let backup = scheduleMenu.addItem(
            withTitle: "Back Up Now", action: #selector(AppDelegate.backUpNow(_:)),
            keyEquivalent: "b")
        backup.keyEquivalentModifierMask = .command
        scheduleMenu.addItem(
            withTitle: "Stop Backup", action: #selector(AppDelegate.stopBackup(_:)),
            keyEquivalent: ".")
        scheduleMenu.addItem(.separator())
        scheduleMenu.addItem(
            withTitle: "Enable Background Backups",
            action: #selector(AppDelegate.enableBackground(_:)), keyEquivalent: "")
        scheduleMenu.addItem(
            withTitle: "Disable Background Backups",
            action: #selector(AppDelegate.disableBackground(_:)), keyEquivalent: "")
        scheduleMenu.addItem(.separator())
        let refresh = scheduleMenu.addItem(
            withTitle: "Refresh", action: #selector(AppDelegate.refresh(_:)), keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = .command

        // View menu — inspector toggle and the log.
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(
            withTitle: "Hide/Show Inspector",
            action: #selector(MainWindowController.toggleInspector), keyEquivalent: "i")
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "Activity Log", action: #selector(AppDelegate.showLog(_:)), keyEquivalent: "l")

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Escapement", action: #selector(AppDelegate.showMain(_:)),
            keyEquivalent: "0")
        NSApp.windowsMenu = windowMenu

        // Help menu
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        return mainMenu
    }
}
