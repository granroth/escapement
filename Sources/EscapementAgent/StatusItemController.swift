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
    /// Deliberately *not* an assertion of visibility on an item that already
    /// exists. `AgentService.refreshStatusItem` calls this on every tick, as
    /// often as once every five seconds during a backup, and re-asserting
    /// `isVisible` there achieves nothing: it cannot overrule a system-side
    /// suppression, and an item that is already showing does not need telling.
    /// Visibility is asserted on an act instead — `install()` at creation,
    /// `assertVisible()` when the user asks. See
    /// `docs/specs/019-menu-bar-visibility-sync.md`.
    func setVisible(_ visible: Bool) {
        if visible {
            install()
        } else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
        }
    }

    /// Where the item's window ended up, which is the only reading found that
    /// distinguishes an item macOS is showing from one it is suppressing.
    ///
    /// `isVisible` cannot answer this: when Escapement is denied in System
    /// Settings → Menu Bar it still reads `true`, still accepts being set to
    /// `true`, and the button and its window still exist. Only the window's
    /// screen membership moves.
    ///
    /// A zero-height window is the item mid-placement, reported for about a
    /// tick after creation and observed in both the permitted and the
    /// suppressed case, so it is `settling` rather than evidence. See
    /// `docs/specs/019-menu-bar-visibility-sync.md` for the measurements.
    var placement: MenuBarItemPlacement {
        guard let window = statusItem?.button?.window else { return .absent }
        guard window.frame.height > 0 else { return .settling }
        return window.screen != nil ? .placed : .unplaced
    }

    /// Forces the item visible in response to the user asking for it, which
    /// reaches here as `AgentCommand.showMenuBarIcon` when the Settings
    /// checkbox is ticked.
    ///
    /// What this fixes: an item that exists but is not showing. On macOS 27 a
    /// created item does not reliably appear, and setting `isVisible`
    /// explicitly is what puts it in the menu bar.
    ///
    /// What it cannot fix: an item macOS is suppressing because Escapement is
    /// denied under Menu Bar in System Settings. That is enforced above the
    /// application — `isVisible` reads `true` throughout and setting it again
    /// changes nothing. `MenuBarSuppression` recognises that case instead, so
    /// the GUI can explain it rather than the agent fighting it.
    func assertVisible() {
        install()
        statusItem?.isVisible = true
    }

    /// Tears the item down and builds a fresh one.
    ///
    /// macOS decides whether Escapement may have a menu bar item when the item
    /// is *created*. Restoring the permission in System Settings does not
    /// revive an item that was refused — it stays dead for the life of the
    /// process, which is why turning the agent off and on again used to be the
    /// only way to get the icon back. Rebuilding is the part of that restart
    /// that actually matters, and the agent can do it without being restarted.
    ///
    /// Only called while the item is believed suppressed, so nothing is on
    /// screen to flicker.
    func reinstall() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        install()
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Deliberately NOT `.removalAllowed`. A ⌘-drag removal only sets
        // `isVisible = false` without telling us, so the item would stay
        // non-nil, `install()`'s guard would skip rebuilding it, and the icon
        // would be gone for the life of the process while Settings still
        // claimed it was shown. Nothing re-asserts visibility on a timer to
        // undo that, by design. The agent also cannot write the preference
        // back — `configuration.json` is the GUI's file. One owner: Settings.
        //
        // A stable name rather than AppKit's positional default (`Item-0`,
        // renumbered by creation order). Whatever AppKit chooses to persist for
        // this item is keyed on the name, so it should not be a number that
        // shifts when the set of status items changes.
        item.autosaveName = "MainStatusItem"
        // Asserted once, at creation, and the only place visibility is set
        // without the user having just asked for it. A created item does not
        // reliably show on macOS 27 — the icon did not appear at all until
        // something set this explicitly, which is the whole reason the line is
        // here. It is not a way to overrule anyone: an item the system is
        // suppressing stays suppressed regardless, which is why nothing
        // re-asserts it on a timer.
        item.isVisible = true
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
