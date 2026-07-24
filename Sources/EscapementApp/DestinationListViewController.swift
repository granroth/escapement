import AppKit
import EscapementKit

/// The main list pane: a search field, a sort control, and a card per
/// destination. Selection drives the inspector; the window controller can veto
/// a selection change when the inspector has unsaved edits.
@MainActor
final class DestinationListViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    enum Sort: Int {
        case name, nextBackup, status
    }

    /// Reports the newly selected destination (or nil).
    var onSelect: ((Destination?) -> Void)?
    /// Consulted before a selection change; return false to keep the current
    /// selection (e.g. the user cancelled a discard prompt).
    var shouldChangeSelection: (() -> Bool)?

    private let searchField = NSSearchField()
    private let sortPopUp = NSPopUpButton()
    private let tableView = NSTableView()

    private var allRows: [DestinationRow] = []
    private var visibleRows: [DestinationRow] = []

    /// The destination last reported to `onSelect`. `onSelect` fires only when
    /// the selected destination genuinely changes, so the periodic refresh —
    /// which must reload and re-select the same row — does not re-notify and
    /// wipe the inspector's in-progress edits.
    private var lastReportedID: String?
    /// Suppresses selection callbacks while the list is being programmatically
    /// reloaded (reloadData clears then restores the selection, which would
    /// otherwise fire spurious change notifications).
    private var suppressCallback = false

    override func loadView() {
        view = NSView()
        build()
    }

    private func build() {
        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        sortPopUp.addItems(withTitles: ["Name", "Next backup", "Status"])
        sortPopUp.target = self
        sortPopUp.action = #selector(sortChanged)
        sortPopUp.translatesAutoresizingMaskIntoConstraints = false
        let sortLabel = NSTextField(labelWithString: "Sort:")
        sortLabel.font = .systemFont(ofSize: 11)
        sortLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [sortLabel, sortPopUp, searchField])
        header.orientation = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setHuggingPriority(.defaultLow, for: .horizontal)

        let column = NSTableColumn(identifier: .init("destination"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 62
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Data

    func reload(rows: [DestinationRow]) {
        let keepID = selectedDestinationID
        allRows = rows
        applyListChanges(preferring: keepID)
    }

    var selectedDestinationID: String? {
        let row = tableView.selectedRow
        guard row >= 0, row < visibleRows.count else { return nil }
        return visibleRows[row].destination.id
    }

    /// Reloads and re-selects under callback suppression, then reports the
    /// selection only if it actually changed. This is the single path through
    /// which the list mutates, so a refresh that keeps the same selection never
    /// re-notifies the inspector.
    private func applyListChanges(preferring id: String?) {
        suppressCallback = true
        applyFilterAndSort()
        restoreSelection(preferring: id)
        suppressCallback = false
        reconcileSelection()
    }

    private func reconcileSelection() {
        let id = selectedDestinationID
        guard id != lastReportedID else { return }
        lastReportedID = id
        onSelect?(id.flatMap { key in visibleRows.first { $0.destination.id == key }?.destination })
    }

    private func applyFilterAndSort() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var rows = allRows
        if !query.isEmpty {
            rows = rows.filter {
                $0.destination.name.lowercased().contains(query)
                    || $0.scheduleSummary.lowercased().contains(query)
            }
        }
        switch Sort(rawValue: sortPopUp.indexOfSelectedItem) ?? .name {
        case .name:
            rows.sort { $0.destination.name.localizedCaseInsensitiveCompare($1.destination.name) == .orderedAscending }
        case .nextBackup:
            // Scheduled destinations first, unscheduled ("—") last.
            rows.sort { ($0.nextRunText == "—" ? 1 : 0, $0.nextRunText) < ($1.nextRunText == "—" ? 1 : 0, $1.nextRunText) }
        case .status:
            rows.sort { ($0.isBusy ? 0 : 1, $0.destination.name) < ($1.isBusy ? 0 : 1, $1.destination.name) }
        }
        visibleRows = rows
        tableView.reloadData()
    }

    private func restoreSelection(preferring id: String?) {
        guard let id, let index = visibleRows.firstIndex(where: { $0.destination.id == id }) else {
            return
        }
        tableView.selectRowIndexes([index], byExtendingSelection: false)
    }

    @objc private func searchChanged() { applyListChanges(preferring: selectedDestinationID) }
    @objc private func sortChanged() { applyListChanges(preferring: selectedDestinationID) }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    {
        let id = NSUserInterfaceItemIdentifier("card")
        let cell =
            (tableView.makeView(withIdentifier: id, owner: self) as? DestinationCardView)
            ?? DestinationCardView()
        cell.identifier = id
        cell.configure(with: visibleRows[row])
        return cell
    }

    func selectionShouldChange(in tableView: NSTableView) -> Bool {
        shouldChangeSelection?() ?? true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressCallback else { return }
        reconcileSelection()
    }
}

/// A destination card: icon, name, schedule summary, and live status with a
/// progress bar while backing up.
@MainActor
final class DestinationCardView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let nextLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private func build() {
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.alignment = .right
        nextLabel.font = .systemFont(ofSize: 10)
        nextLabel.textColor = .secondaryLabelColor
        nextLabel.alignment = .right
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true

        let text = NSStackView(views: [nameLabel, summaryLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let right = NSStackView(views: [statusLabel, progress, nextLabel])
        right.orientation = .vertical
        right.alignment = .trailing
        right.spacing = 2

        for v in [iconView, text, right] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),

            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 10),
            progress.widthAnchor.constraint(equalToConstant: 110),
        ])
    }

    func configure(with row: DestinationRow) {
        iconView.image = DestinationIcons.image(for: row.destination.kind)
        nameLabel.stringValue = row.destination.name
        summaryLabel.stringValue = row.scheduleSummary
        statusLabel.stringValue = row.statusText
        statusLabel.textColor = row.isBusy ? .controlAccentColor : .secondaryLabelColor
        nextLabel.stringValue = row.hasSchedule ? "Next: \(row.nextRunText)" : ""

        if let value = row.progress {
            progress.stopAnimation(nil)
            progress.isHidden = false
            progress.isIndeterminate = false
            progress.doubleValue = value
        } else if row.isBusy {
            progress.isHidden = false
            progress.isIndeterminate = true
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
            progress.isHidden = true
        }
    }
}
