import AppKit
import EscapementKit

/// The primary window: a banner when macOS's own scheduler conflicts, and a
/// list of destinations with their schedule, live status, and last/next run.
@MainActor
final class StatusWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let controller: AppController
    private let tableView = NSTableView()
    private let banner = BannerView()
    private var rows: [DestinationRow] = []
    private let emptyLabel = NSTextField(labelWithString: "")

    init(controller: AppController) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Escapement"
        window.setFrameAutosaveName("EscapementStatusWindow")
        window.minSize = NSSize(width: 560, height: 320)
        super.init(window: window)
        buildContent()
        controller.addObserver { [weak self] in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }

        let column = NSTableColumn(identifier: .init("destination"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 76
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .inset
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        banner.onOpenSettings = { [weak controller] in controller?.openTimeMachineSettings() }

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.isHidden = true
        emptyLabel.maximumNumberOfLines = 0

        let content = NSView()
        content.addSubview(banner)
        content.addSubview(scrollView)
        content.addSubview(emptyLabel)
        window.contentView = content

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: content.topAnchor),
            banner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: banner.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -80),
        ])
    }

    // MARK: - Data

    private func reload() {
        rows = controller.rows
        updateBanner()
        updateEmptyState()
        tableView.reloadData()
    }

    private func updateBanner() {
        switch controller.automaticState {
        case .automatic:
            banner.configure(
                level: .warning,
                message:
                    "macOS is running its own Time Machine schedule, which conflicts with "
                    + "Escapement. Set Time Machine to back up “Manually”, then Escapement takes over.",
                showButton: true)
            banner.isHidden = false
        case .unknown:
            banner.configure(
                level: .caution,
                message:
                    "Escapement can’t confirm whether macOS’s own backup schedule is on. If your "
                    + "backups run twice, set Time Machine to back up “Manually”.",
                showButton: true)
            banner.isHidden = false
        case .manual:
            banner.isHidden = true
        }
    }

    private func updateEmptyState() {
        if rows.isEmpty {
            emptyLabel.stringValue =
                "No Time Machine destinations found.\n\nAdd a backup disk in System Settings › "
                + "General › Time Machine. Escapement will list it here."
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let identifier = NSUserInterfaceItemIdentifier("row")
        let cell =
            (tableView.makeView(withIdentifier: identifier, owner: self) as? DestinationCellView)
            ?? DestinationCellView()
        cell.identifier = identifier
        let model = rows[row]
        cell.configure(
            with: model,
            globalBusy: controller.isBackupRunning,
            onPrimaryAction: { [weak controller] in
                guard let controller else { return }
                if model.isBusy {
                    controller.stopBackup()
                } else {
                    controller.backUpNow(destinationID: model.destination.id)
                }
            })
        return cell
    }
}
