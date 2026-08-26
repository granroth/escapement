import AppKit
import EscapementKit

/// What the menu bar extra needs to draw itself, captured on the agent's tick
/// so building the menu stays synchronous.
@MainActor
struct StatusMenuModel {
    var summary: StatusSummary = StatusSummary(
        stateLine: "Starting…", latestLine: "", isRunning: false, isPaused: false)
    var destinations: [Destination] = []
    /// Destinations with an enabled schedule, which is what "Back Up Now"
    /// offers; an unscheduled destination is still listed but never implied.
    var scheduledDestinationIDs: Set<String> = []
}

@MainActor
protocol StatusItemActions: AnyObject {
    func statusItemBackUpNow(destinationID: String)
    func statusItemStop()
    func statusItemPause(_ option: PauseOption)
    func statusItemResume()
    func statusItemOpenApp()
    func statusItemTurnOffBackgroundBackups()
}

/// The agent's menu bar extra. Owned by the agent rather than the GUI so that
/// its presence is itself the truth: the agent is the only process that can run
/// a backup, so the icon appears exactly when something is scheduled to happen.
///
/// The menu is rebuilt on open from the last tick's snapshot rather than kept
/// live, so opening it never waits on `tmutil`.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var model = StatusMenuModel()
    private weak var actions: (any StatusItemActions)?

    init(actions: any StatusItemActions) {
        self.actions = actions
        super.init()
    }

    // MARK: - Presence

    /// Shows or hides the item to match the user's preference. Hiding removes
    /// the item entirely, so the agent keeps running silently.
    ///
    /// Showing always re-asserts `isVisible`, not just on first install.
    /// `NSStatusItem`'s visibility is persisted by the system under its
    /// `autosaveName`, independent of whether the item object still exists —
    /// macOS's own Menu Bar settings can flip that persisted bit to hidden
    /// (that is how the user-facing "show in menu bar" toggle there works),
    /// and it stays hidden across relaunches until something explicitly sets
    /// it back to `true`. Without this, `install()`'s
    /// already-installed guard would skip re-showing a system-hidden item for
    /// the rest of the process's life, and a brand new item created after
    /// relaunch would just inherit the same persisted-hidden state. Settings
    /// stays the one owner: this makes it authoritative again instead of a
    /// one-time default.
    func setVisible(_ visible: Bool) {
        if visible {
            install()
            statusItem?.isVisible = true
        } else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
        }
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A stable name rather than the default "automatically chosen" one,
        // so the persisted visibility bit above is keyed on an identity we
        // control and can reason about, not an implementation detail of
        // AppKit's auto-naming.
        item.autosaveName = "MainStatusItem"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshButton()
    }

    // MARK: - Model

    func update(_ model: StatusMenuModel) {
        self.model = model
        refreshButton()
    }

    /// Escapement's own escape-wheel mark, as a menu bar template image.
    ///
    /// Built once — the menu bar redraws often, and the image re-renders itself
    /// at whatever scale the system needs.
    private static let markImage = EscapementMark.statusItemImage()

    /// The icon is the mark in every state — state is carried by the tooltip
    /// and the menu, which can say it in words. The one exception is a pause,
    /// which dims the mark the way macOS dims anything switched off.
    private func refreshButton() {
        guard let button = statusItem?.button else { return }
        button.image = Self.markImage
        button.image?.accessibilityDescription = accessibilityDescription
        button.appearsDisabled = model.summary.isPaused
        button.toolTip = "Escapement — \(model.summary.stateLine)"
    }

    private var accessibilityDescription: String {
        if model.summary.isRunning { return "Escapement — backing up" }
        if model.summary.isPaused { return "Escapement — paused" }
        return "Escapement"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(header(model.summary.stateLine))
        if !model.summary.latestLine.isEmpty {
            menu.addItem(header(model.summary.latestLine))
        }
        menu.addItem(.separator())

        addBackUpItems(to: menu)
        menu.addItem(.separator())
        addPauseItems(to: menu)
        menu.addItem(.separator())

        menu.addItem(
            action("Open Escapement", #selector(openApp), enabled: true))
        menu.addItem(
            action(
                "Turn Off Background Backups…", #selector(turnOff), enabled: true))
    }

    private func addBackUpItems(to menu: NSMenu) {
        if model.summary.isRunning {
            menu.addItem(action("Stop Backup", #selector(stop), enabled: true))
            return
        }

        let candidates = model.destinations
        guard !candidates.isEmpty else {
            menu.addItem(disabled("No destinations"))
            return
        }

        // One destination needs no submenu; several do, and the submenu names
        // them so the user is never guessing which disk is about to spin up.
        if candidates.count == 1, let only = candidates.first {
            let item = action("Back Up Now", #selector(backUpNow(_:)), enabled: true)
            item.representedObject = only.id
            menu.addItem(item)
            return
        }

        let parent = NSMenuItem(title: "Back Up Now", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for destination in candidates {
            let item = action(destination.name, #selector(backUpNow(_:)), enabled: true)
            item.representedObject = destination.id
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addPauseItems(to menu: NSMenu) {
        if model.summary.isPaused {
            menu.addItem(action("Resume Backups", #selector(resume), enabled: true))
            return
        }
        let parent = NSMenuItem(title: "Pause Backups", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for option in PauseOption.allCases {
            let item = action(option.title, #selector(pause(_:)), enabled: true)
            item.representedObject = option
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    // MARK: - Item construction

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        header(title)
    }

    private func action(_ title: String, _ selector: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    // MARK: - Actions

    @objc private func backUpNow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        actions?.statusItemBackUpNow(destinationID: id)
    }

    @objc private func stop() {
        actions?.statusItemStop()
    }

    @objc private func pause(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? PauseOption else { return }
        actions?.statusItemPause(option)
    }

    @objc private func resume() {
        actions?.statusItemResume()
    }

    @objc private func openApp() {
        actions?.statusItemOpenApp()
    }

    @objc private func turnOff() {
        actions?.statusItemTurnOffBackgroundBackups()
    }
}
