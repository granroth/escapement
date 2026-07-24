import AppKit
import EscapementKit

/// The activity log: the run history in a plain table, opened from the menu.
/// Not prominent by design — a place to look when something seems off.
@MainActor
final class LogWindowController: NSWindowController, NSTableViewDataSource {

    private static var instance: LogWindowController?
    static func shared(controller: AppController) -> LogWindowController {
        if let instance { return instance }
        let created = LogWindowController(controller: controller)
        instance = created
        return created
    }

    private let controller: AppController
    private let tableView = NSTableView()
    private var runs: [BackupRun] = []

    private init(controller: AppController) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Activity Log"
        window.setFrameAutosaveName("EscapementLogWindow")
        window.collectionBehavior = [.fullScreenNone]
        window.tabbingMode = .disallowed
        super.init(window: window)
        build()
        controller.addObserver { [weak self] in self?.reload() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private func build() {
        let columns: [(String, String, CGFloat)] = [
            ("destination", "Destination", 160),
            ("started", "Started", 150),
            ("trigger", "Trigger", 90),
            ("result", "Result", 140),
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        window?.contentView = scrollView
        reload()
    }

    private func reload() {
        runs = controller.history
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { runs.count }

    func tableView(
        _ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int
    ) -> Any? {
        let run = runs[row]
        switch tableColumn?.identifier.rawValue {
        case "destination":
            return controller.destinations.first { $0.id == run.destinationID }?.name
                ?? run.destinationID
        case "started":
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: run.startedAt)
        case "trigger":
            switch run.trigger {
            case .scheduled: return "Scheduled"
            case .manual: return "Manual"
            case .missed: return "Catch-up"
            }
        case "result":
            switch run.outcome {
            case .running: return "Running…"
            case .completed: return "Completed"
            case .cancelled: return "Cancelled"
            case .failed(let reason): return reason.map { "Failed: \($0)" } ?? "Failed"
            }
        default:
            return nil
        }
    }
}
