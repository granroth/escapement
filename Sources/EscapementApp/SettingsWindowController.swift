import AppKit
import EscapementKit
import ServiceManagement

/// The Settings window (⌘,). Deliberately small: it holds the things that are
/// *preferences* rather than verbs — the background master switch, whether the
/// menu bar extra is shown, and whether failures are announced.
///
/// The master switch lives here rather than in the Schedule menu, where it used
/// to sit as a pair of items with one always disabled. A persistent on/off is a
/// preference, not a command.
@MainActor
final class SettingsWindowController: NSWindowController {

    private static var shared: SettingsWindowController?

    static func shared(controller: AppController) -> SettingsWindowController {
        if let existing = shared { return existing }
        let created = SettingsWindowController(controller: controller)
        shared = created
        return created
    }

    private let controller: AppController

    private let statusLabel = NSTextField(labelWithString: "")
    private let toggleButton = NSButton(title: "", target: nil, action: nil)
    private let approvalButton = NSButton(title: "Open Login Items", target: nil, action: nil)
    private let menuBarCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let notifyCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let updateIntervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let checkNowButton = NSButton(title: "Check Now", target: nil, action: nil)
    private let updateStatusLabel = NSTextField(labelWithString: "")
    private let viewReleaseButton = NSButton(title: "View Release", target: nil, action: nil)

    /// Pairs each interval with its menu title so the popup's item order and
    /// selection index are always derived from one list rather than two
    /// hand-maintained orderings that could drift apart.
    private let intervalOptions: [(UpdateCheckInterval, String)] = [
        (.never, "Never"), (.onStartup, "On Startup"), (.daily, "Daily"),
        (.weekly, "Weekly"), (.monthly, "Monthly"),
    ]

    private init(controller: AppController) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Escapement Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        build()
        controller.addObserver { [weak self] in self?.refresh() }
        controller.onNotificationAuthorizationDenied = { [weak self] in
            self?.present(
                "Notifications are turned off for Escapement",
                "macOS refused permission, so failure notifications can’t be delivered. You can "
                    + "allow them in System Settings › Notifications › Escapement, then switch "
                    + "this back on.")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: - Layout

    private func build() {
        let heading = NSTextField(labelWithString: "Background Backups")
        heading.font = .boldSystemFont(ofSize: 13)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 420

        toggleButton.bezelStyle = .rounded
        toggleButton.target = self
        toggleButton.action = #selector(toggleAgent)

        approvalButton.bezelStyle = .rounded
        approvalButton.target = self
        approvalButton.action = #selector(openLoginItems)

        menuBarCheckbox.title = "Show Escapement in the menu bar"
        menuBarCheckbox.target = self
        menuBarCheckbox.action = #selector(toggleMenuBarIcon)

        notifyCheckbox.title = "Notify me when a backup fails"
        notifyCheckbox.target = self
        notifyCheckbox.action = #selector(toggleNotifications)

        let updateHeading = NSTextField(labelWithString: "Check for Updates")
        updateHeading.font = .boldSystemFont(ofSize: 13)

        let updateLabel = NSTextField(labelWithString: "Frequency:")

        updateIntervalPopup.addItems(withTitles: intervalOptions.map(\.1))
        updateIntervalPopup.target = self
        updateIntervalPopup.action = #selector(updateCheckIntervalChanged)

        checkNowButton.bezelStyle = .rounded
        checkNowButton.target = self
        checkNowButton.action = #selector(checkForUpdatesNow)

        updateStatusLabel.font = .systemFont(ofSize: 11)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.lineBreakMode = .byWordWrapping
        updateStatusLabel.maximumNumberOfLines = 3
        updateStatusLabel.preferredMaxLayoutWidth = 420

        viewReleaseButton.bezelStyle = .rounded
        viewReleaseButton.target = self
        viewReleaseButton.action = #selector(viewRelease)
        viewReleaseButton.isHidden = true

        let buttons = NSStackView(views: [toggleButton, approvalButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let updateControls = NSStackView(views: [updateLabel, updateIntervalPopup, checkNowButton])
        updateControls.orientation = .horizontal
        updateControls.spacing = 10

        let updateStatusRow = NSStackView(views: [updateStatusLabel, viewReleaseButton])
        updateStatusRow.orientation = .horizontal
        updateStatusRow.spacing = 10

        let stack = NSStackView(views: [
            heading, statusLabel, buttons,
            separator(),
            menuBarCheckbox, notifyCheckbox,
            separator(),
            updateHeading, updateControls, updateStatusRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(6, after: heading)
        stack.setCustomSpacing(18, after: buttons)
        stack.setCustomSpacing(6, after: updateHeading)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window?.contentView = content
        // Settings has no resizable content, so the window is sized to exactly
        // what it holds rather than left with dead space below the checkboxes.
        window?.setContentSize(content.fittingSize)
        window?.center()
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return line
    }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Refresh

    private func refresh() {
        // The status text names what is actually true rather than a bare
        // on/off, because "waiting for approval" is a state the user has to act
        // on somewhere else entirely.
        switch controller.agentStatus {
        case .enabled:
            statusLabel.stringValue =
                "Escapement is running your schedules in the background."
            toggleButton.title = "Turn Off"
            approvalButton.isHidden = true
        case .requiresApproval:
            statusLabel.stringValue =
                "Waiting for your approval. Turn Escapement on in Login Items to let it run "
                + "your schedules."
            toggleButton.title = "Turn Off"
            approvalButton.isHidden = false
        default:
            statusLabel.stringValue =
                "Off. Your schedules are saved but nothing will run until background backups "
                + "are turned on."
            toggleButton.title = "Turn On"
            approvalButton.isHidden = true
        }

        menuBarCheckbox.state = controller.configuration.showsMenuBarIcon ? .on : .off
        notifyCheckbox.state = controller.configuration.notifiesOnFailure ? .on : .off

        if let index = intervalOptions.firstIndex(where: {
            $0.0 == controller.configuration.updateCheckInterval
        }) {
            updateIntervalPopup.selectItem(at: index)
        }
        // Unlike the interval, which is a preference that takes effect once
        // the agent is next enabled, Check Now is a verb that needs a
        // running agent to act on — same reasoning as the toolbar's Back Up
        // Now item.
        checkNowButton.isEnabled = controller.isAgentEnabled
        if let available = controller.agentState.availableUpdate {
            updateStatusLabel.stringValue = "Escapement \(available.version) is available."
            viewReleaseButton.isHidden = false
        } else {
            updateStatusLabel.stringValue = statusText(forLastCheckedAt: controller.agentState.lastUpdateCheck)
            viewReleaseButton.isHidden = true
        }
    }

    private func statusText(forLastCheckedAt date: Date?) -> String {
        guard let date else { return "Never checked" }
        let relative = RelativeDateTimeFormatter()
        relative.locale = controller.locale
        return "Last check: \(relative.localizedString(for: date, relativeTo: Date()))"
    }

    // MARK: - Actions

    @objc private func toggleAgent() {
        if controller.agentStatus == .enabled || controller.agentStatus == .requiresApproval {
            Task {
                do {
                    try await controller.disableAgent()
                } catch {
                    present("Couldn’t turn off background backups", error.localizedDescription)
                }
            }
        } else {
            do {
                try controller.enableAgent()
            } catch {
                present(
                    "Couldn’t turn on background backups",
                    "\(error.localizedDescription)\n\nEscapement must be in your Applications "
                        + "folder to run in the background.")
            }
        }
    }

    @objc private func openLoginItems() {
        controller.openLoginItemsSettings()
    }

    @objc private func toggleMenuBarIcon(_ sender: NSButton) {
        guard controller.setShowsMenuBarIcon(sender.state == .on) else {
            present(
                "Couldn’t save that setting",
                "Escapement could not write its configuration file, so the change was not kept.")
            return
        }
    }

    @objc private func toggleNotifications(_ sender: NSButton) {
        let enabled = sender.state == .on
        guard controller.setNotifiesOnFailure(enabled) else {
            present(
                "Couldn’t save that setting",
                "Escapement could not write its configuration file, so the change was not kept.")
            return
        }
        // Ask for permission from the GUI, where the user just clicked, rather
        // than from the agent — a background process raising an authorisation
        // prompt out of nowhere is exactly the behaviour this milestone is
        // trying to remove.
        if enabled { controller.requestNotificationAuthorization() }
    }

    @objc private func updateCheckIntervalChanged(_ sender: NSPopUpButton) {
        let interval = intervalOptions[sender.indexOfSelectedItem].0
        guard controller.setUpdateCheckInterval(interval) else {
            present(
                "Couldn’t save that setting",
                "Escapement could not write its configuration file, so the change was not kept.")
            return
        }
        // Ask for permission from the GUI, where the user just clicked, rather
        // than from the agent, mirroring `toggleNotifications`.
        if interval != .never { controller.requestUpdateNotificationAuthorization() }
    }

    @objc private func checkForUpdatesNow() {
        controller.checkForUpdatesNow()
    }

    @objc private func viewRelease() {
        if let url = controller.agentState.availableUpdate?.releaseURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func present(_ message: String, _ informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
    }
}
