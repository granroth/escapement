import AppKit

/// Builds the app's menu bar in code. Every user action has a menu path, not
/// only a button — a baseline expectation of a Mac app.
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
            withTitle: "About Escapement", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(
            withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Escapement", action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Escapement", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        // File-ish / View menu with Refresh
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let refresh = viewMenu.addItem(
            withTitle: "Refresh", action: #selector(AppDelegate.refresh(_:)), keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = .command

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
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
