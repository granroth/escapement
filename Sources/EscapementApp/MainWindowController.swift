import AppKit
import EscapementKit

/// The single main window: a searchable destination list on the left and the
/// schedule inspector on the right, in the Lingon-style two-pane layout. Owns
/// the toolbar, the unsaved-changes prompt, the first-run Full Disk Access
/// dialog, and the conflict banner.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {

    private let controller: AppController
    private let listVC: DestinationListViewController
    private let inspectorVC: InspectorViewController
    private let splitVC = NSSplitViewController()
    private let banner = ConflictBanner()

    private var inspectorItem: NSSplitViewItem!
    private var backupItem: NSToolbarItem!
    private var toggleItem: NSToolbarItem!

    private static let fdaPromptKey = "EscapementHasPromptedFullDiskAccess"

    init(controller: AppController) {
        self.controller = controller
        self.listVC = DestinationListViewController()
        self.inspectorVC = InspectorViewController(controller: controller)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Escapement"
        window.setFrameAutosaveName("EscapementMainWindow")
        window.minSize = NSSize(width: 720, height: 380)
        // Escapement is a single-window utility: full screen and window tabs
        // are meaningless here, so remove them (and their menu items).
        window.collectionBehavior = [.fullScreenNone]
        window.tabbingMode = .disallowed
        super.init(window: window)

        buildSplit()
        buildContainer()
        buildToolbar()
        wireSelection()

        controller.addObserver { [weak self] in self?.refresh() }
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: - Layout

    private func buildSplit() {
        let listItem = NSSplitViewItem(viewController: listVC)
        listItem.minimumThickness = 280
        listItem.canCollapse = false
        listItem.holdingPriority = .init(rawValue: 249)

        inspectorItem = NSSplitViewItem(viewController: inspectorVC)
        inspectorItem.minimumThickness = 340
        inspectorItem.maximumThickness = 420
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = .init(rawValue: 251)

        splitVC.addSplitViewItem(listItem)
        splitVC.addSplitViewItem(inspectorItem)
        splitVC.splitView.dividerStyle = .thin
    }

    private func buildContainer() {
        let container = NSViewController()
        let root = NSView()
        container.view = root

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        banner.onOpenSettings = { [weak controller] in controller?.openTimeMachineSettings() }

        let split = splitVC.view
        split.translatesAutoresizingMaskIntoConstraints = false
        container.addChild(splitVC)

        root.addSubview(banner)
        root.addSubview(split)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: root.topAnchor),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: banner.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentViewController = container
        // Assigning a contentViewController resizes the window to the view's
        // fitting size, clobbering any frame the autosave restored. Re-apply the
        // saved frame if there is one; only fall back to the default size and a
        // centred position on first run, so the user's window placement is not
        // reset on every launch.
        if window?.setFrameUsingName("EscapementMainWindow") != true {
            window?.setContentSize(NSSize(width: 860, height: 500))
            window?.center()
        }
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "EscapementMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private func wireSelection() {
        listVC.onSelect = { [weak self] destination in
            self?.inspectorVC.showDestination(destination)
            self?.refreshToolbar()
        }
        listVC.shouldChangeSelection = { [weak self] in
            self?.confirmDiscardIfNeeded() ?? true
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refresh()
        maybePromptForFullDiskAccess()
    }

    // MARK: - Refresh

    private func refresh() {
        listVC.reload(rows: controller.rows)
        updateBanner()
        refreshToolbar()
    }

    private func updateBanner() {
        // Only a *confirmed* conflict warrants the banner. The unknown case is
        // handled once, by the first-run dialog, not by a standing warning.
        if controller.automaticState == .automatic {
            banner.message =
                "macOS is running its own Time Machine schedule, which conflicts with Escapement. "
                + "Set Time Machine to back up “Manually” to hand scheduling to Escapement."
            banner.isHidden = false
        } else {
            banner.isHidden = true
        }
    }

    private func refreshToolbar() {
        guard let backupItem else { return }
        let selected = selectedRow
        if let selected, selected.isBusy {
            backupItem.label = "Stop"
            backupItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
            backupItem.isEnabled = !selected.statusText.hasPrefix("Stopping")
        } else {
            backupItem.label = "Back Up Now"
            backupItem.image = NSImage(
                systemSymbolName: "arrow.clockwise", accessibilityDescription: "Back Up Now")
            backupItem.isEnabled = selected != nil && !controller.isBackupRunning
        }
    }

    private var selectedRow: DestinationRow? {
        guard let id = listVC.selectedDestinationID else { return nil }
        return controller.rows.first { $0.destination.id == id }
    }

    // MARK: - Toolbar delegate

    private let backupIdentifier = NSToolbarItem.Identifier("backup")
    private let toggleIdentifier = NSToolbarItem.Identifier("toggleInspector")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [backupIdentifier, .flexibleSpace, toggleIdentifier]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [backupIdentifier, toggleIdentifier, .flexibleSpace, .space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case backupIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Back Up Now"
            item.image = NSImage(
                systemSymbolName: "arrow.clockwise", accessibilityDescription: "Back Up Now")
            item.target = self
            item.action = #selector(backupAction)
            item.isBordered = true
            backupItem = item
            return item
        case toggleIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Inspector"
            item.image = NSImage(
                systemSymbolName: "sidebar.right", accessibilityDescription: "Toggle Inspector")
            item.target = self
            item.action = #selector(toggleInspector)
            item.isBordered = true
            toggleItem = item
            return item
        default:
            return nil
        }
    }

    // MARK: - Actions

    @objc private func backupAction() {
        guard let row = selectedRow else { return }
        if row.isBusy {
            controller.stopBackup()
        } else {
            controller.backUpNow(destinationID: row.destination.id)
        }
    }

    /// Menu "Back Up Now": starts a backup for the selected destination if idle.
    func menuBackUpNow() {
        guard let row = selectedRow, !row.isBusy, !controller.isBackupRunning else { return }
        controller.backUpNow(destinationID: row.destination.id)
    }

    @objc func toggleInspector() {
        inspectorItem.animator().isCollapsed.toggle()
    }

    @objc func showLog(_ sender: Any?) {
        LogWindowController.shared(controller: controller).showWindow(sender)
    }

    // MARK: - Unsaved changes

    /// Prompts to save or discard when the inspector has pending edits. Returns
    /// false only if the user cancels, meaning the selection should not move.
    private func confirmDiscardIfNeeded() -> Bool {
        guard inspectorVC.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to this schedule?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return inspectorVC.commit()  // refuse to move if the edit is invalid
        case .alertSecondButtonReturn:
            inspectorVC.revert()
            return true
        default:
            return false
        }
    }

    // MARK: - First-run Full Disk Access

    private func maybePromptForFullDiskAccess() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.fdaPromptKey) else { return }
        // Only prompt once we actually could not read the flag (the signal that
        // Full Disk Access is missing). Give the first refresh a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let window = self.window else { return }
            guard self.controller.automaticState == .unknown else { return }
            defaults.set(true, forKey: Self.fdaPromptKey)

            let alert = NSAlert()
            alert.messageText = "Grant Full Disk Access?"
            alert.informativeText =
                "Escapement works without it, but with Full Disk Access it can confirm whether "
                + "macOS’s own Time Machine schedule is on and warn you of a conflict.\n\n"
                + "You can grant it in System Settings › Privacy & Security › Full Disk Access, "
                + "or skip this and check Time Machine is set to “Manually” yourself."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Not Now")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    if let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing just hides the window; the app keeps scheduling. Still,
        // honour pending edits so they are not silently lost.
        confirmDiscardIfNeeded()
    }
}

/// The conflict warning bar shown only when macOS's own scheduler is confirmed
/// to be running.
@MainActor
final class ConflictBanner: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "Open Time Machine Settings…", target: nil, action: nil)
    var onOpenSettings: (() -> Void)?

    var message: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private func build() {
        label.font = .systemFont(ofSize: 12)
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        icon.contentTintColor = .systemRed
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(open)

        let stack = NSStackView(views: [icon, label, button])
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
    }
    @objc private func open() { onOpenSettings?() }
}
