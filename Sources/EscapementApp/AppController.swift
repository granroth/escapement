import AppKit
import EscapementKit

/// The app's live state and the loop that keeps it current.
///
/// `@MainActor` because it feeds the UI directly. The heavy lifting lives in
/// `EscapementKit`; this class refreshes state, drives the `SchedulerRunner`,
/// and hands actions to it. The `tmutil` calls are `async` and run off the main
/// actor, so the UI never blocks on a process.
@MainActor
final class AppController {

    private let control = TMUtilController()
    private let configurationStore = ConfigurationStore()
    private let historyStore = HistoryStore()
    private let runner: SchedulerRunner
    let calendar = Calendar.current
    let locale = Locale.current

    // Live state, read by the view controllers after each `onChange`.
    private(set) var destinations: [Destination] = []
    private(set) var activity: BackupActivity = .idle
    private(set) var automaticState: AutomaticBackupState = .unknown
    private(set) var configuration = Configuration()
    private(set) var history: [BackupRun] = []

    private var observers: [() -> Void] = []
    private var loop: Task<Void, Never>?

    init() {
        runner = SchedulerRunner(
            control: control,
            configuration: configurationStore,
            history: historyStore,
            scheduler: Scheduler(calendar: calendar),
            now: { Date() })
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        loop = Task { await runLoop() }
    }

    /// Registers a closure called on the main actor whenever live state
    /// changes. Both the status and settings windows observe.
    func addObserver(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    /// Forces an immediate refresh (menu Refresh, etc.).
    func requestRefresh() {
        refreshSoon()
    }

    private func notify() {
        for observer in observers { observer() }
    }

    // MARK: - Derived view state

    var rows: [DestinationRow] {
        RowBuilder(calendar: calendar, locale: locale)
            .rows(
                destinations: destinations, configuration: configuration,
                history: history, activity: activity, now: Date())
    }

    var isBackupRunning: Bool {
        if case .idle = activity { return false }
        return true
    }

    // MARK: - Actions

    func backUpNow(destinationID: String) {
        Task {
            await runner.backUpNow(destinationID: destinationID)
            await refreshState()
        }
    }

    func stopBackup() {
        Task {
            try? await control.stopBackup()
            await refreshState()
        }
    }

    /// Persists a schedule edit and re-evaluates promptly.
    func apply(_ schedule: DestinationSchedule) {
        var config = configuration
        config.upsert(schedule)
        try? configurationStore.save(config)
        configuration = config
        notify()
        refreshSoon()
    }

    func removeSchedule(destinationID: String) {
        var config = configuration
        config.removeSchedule(for: destinationID)
        try? configurationStore.save(config)
        configuration = config
        notify()
        refreshSoon()
    }

    /// The current schedule for a destination, for the editor to seed itself.
    func schedule(for destinationID: String) -> DestinationSchedule? {
        configuration.schedule(for: destinationID)
    }

    func openTimeMachineSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")
        {
            NSWorkspace.shared.open(url)
        }
    }

    func history(for destinationID: String) -> [BackupRun] {
        history.filter { $0.destinationID == destinationID }
    }

    // MARK: - The loop

    private func runLoop() async {
        while !Task.isCancelled {
            await refreshState()
            await runner.evaluate()
            await refreshState()

            let interval: Duration
            if isBackupRunning {
                interval = .seconds(2)  // poll progress while active
            } else {
                // Sleep until the next scheduled fire, capped so a schedule
                // change or a clock jump is picked up within a minute.
                let next = await runner.nextWakeUp()
                let seconds = next.map { max(1, min(60, $0.timeIntervalSinceNow)) } ?? 60
                interval = .seconds(seconds)
            }
            try? await Task.sleep(for: interval)
        }
    }

    /// Reads everything and publishes it. `tmutil` reads run off the main actor
    /// (they are `nonisolated async`); the small file loads are synchronous.
    private func refreshState() async {
        let destinations = (try? await control.destinations()) ?? self.destinations
        let activity = (try? await control.activity()) ?? .idle
        let automaticState = await control.automaticBackupState()

        self.destinations = destinations
        self.activity = activity
        self.automaticState = automaticState
        self.configuration = (try? configurationStore.load()) ?? configuration
        self.history = (try? historyStore.load()) ?? history
        notify()
    }

    /// Kicks an immediate refresh + evaluation outside the loop's cadence,
    /// used after an edit or on wake. Safe alongside the loop: the runner
    /// serialises itself.
    private func refreshSoon() {
        Task {
            await refreshState()
            await runner.evaluate()
            await refreshState()
        }
    }

    @objc private func didWake() {
        // Give a network share a moment to remount before evaluating.
        Task {
            try? await Task.sleep(for: .seconds(10))
            refreshSoon()
        }
    }
}
