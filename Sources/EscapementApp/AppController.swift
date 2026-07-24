import AppKit
import EscapementKit
import ServiceManagement

/// The app's live state and the loop that keeps it current.
///
/// The GUI is a viewer and configurator: it edits the configuration, shows
/// status, and asks the background agent to run manual backups. It never fires
/// a scheduled backup and never writes history — the agent owns both. The
/// `tmutil` reads it does (destinations, status) are read-only and run off the
/// main actor, so the UI never blocks on a process.
@MainActor
final class AppController {

    private let control = TMUtilController()
    private let configurationStore = ConfigurationStore()
    private let historyStore = HistoryStore()
    private let commandStore = CommandStore()
    private let agent = AgentManager()
    let calendar = Calendar.current
    let locale = Locale.current

    // Live state, read by the view controllers after each change notification.
    private(set) var destinations: [Destination] = []
    private(set) var activity: BackupActivity = .idle
    private(set) var automaticState: AutomaticBackupState = .unknown
    private(set) var configuration = Configuration()
    private(set) var history: [BackupRun] = []
    private(set) var agentStatus: SMAppService.Status = .notRegistered

    private var observers: [() -> Void] = []
    private var loop: Task<Void, Never>?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        loop = Task { await runLoop() }
    }

    /// Registers a closure called on the main actor whenever live state changes.
    func addObserver(_ block: @escaping () -> Void) {
        observers.append(block)
    }

    /// Forces an immediate refresh (menu Refresh, after an edit, etc.).
    func requestRefresh() {
        Task { await refreshState() }
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

    /// Whether the background agent is enabled and running.
    var isAgentEnabled: Bool { agentStatus == .enabled }

    // MARK: - Manual actions (routed to the agent)

    func backUpNow(destinationID: String) {
        // Only post when the agent is there to run it. A command posted while
        // the agent is off would sit in the file and fire whenever the agent is
        // next enabled — possibly against an unrelated backup.
        guard isAgentEnabled else { return }
        try? commandStore.post(.backUpNow(destinationID: destinationID))
        requestRefresh()
    }

    func stopBackup() {
        guard isAgentEnabled else { return }
        try? commandStore.post(.stop)
        requestRefresh()
    }

    // MARK: - Configuration

    func apply(_ schedule: DestinationSchedule) {
        var config = configuration
        config.upsert(schedule)
        try? configurationStore.save(config)
        configuration = config
        notify()
    }

    func removeSchedule(destinationID: String) {
        var config = configuration
        config.removeSchedule(for: destinationID)
        try? configurationStore.save(config)
        configuration = config
        notify()
    }

    func schedule(for destinationID: String) -> DestinationSchedule? {
        configuration.schedule(for: destinationID)
    }

    func history(for destinationID: String) -> [BackupRun] {
        history.filter { $0.destinationID == destinationID }
    }

    // MARK: - Agent management

    /// Enables background backups by registering the LaunchAgent. Returns the
    /// resulting status (which may be `.requiresApproval`), or throws on
    /// failure.
    @discardableResult
    func enableAgent() throws -> SMAppService.Status {
        // Drop any command left over from before, so enabling the agent never
        // replays a stale request.
        commandStore.clear()
        try agent.enable()
        agentStatus = agent.status
        notify()
        return agentStatus
    }

    func disableAgent() async throws {
        try await agent.disable()
        commandStore.clear()
        await refreshState()
    }

    func openLoginItemsSettings() {
        agent.openLoginItemsSettings()
    }

    func openTimeMachineSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")
        {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - The display loop

    private func runLoop() async {
        while !Task.isCancelled {
            await refreshState()
            // Poll faster while a backup is running so progress stays live;
            // otherwise refresh gently to pick up the agent's history writes and
            // any change in destinations.
            let interval: Duration = isBackupRunning ? .seconds(2) : .seconds(5)
            try? await Task.sleep(for: interval)
        }
    }

    /// Reads everything for display. No firing, no history writes.
    private func refreshState() async {
        let destinations = (try? await control.destinations()) ?? self.destinations
        let activity = (try? await control.activity()) ?? .idle
        let automaticState = await control.automaticBackupState()

        self.destinations = destinations
        self.activity = activity
        self.automaticState = automaticState
        self.configuration = (try? configurationStore.load()) ?? configuration
        self.history = (try? historyStore.load()) ?? history
        self.agentStatus = agent.status
        notify()
    }

    @objc private func didWake() {
        Task { await refreshState() }
    }
}
