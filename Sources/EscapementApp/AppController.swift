import AppKit
import EscapementKit
import ServiceManagement
import UserNotifications

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
    private let stateStore = StateStore()
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
    /// The agent's own published state. Read-only here: the agent is its sole
    /// writer, so changing it goes through `CommandStore`.
    private(set) var agentState = AgentState()
    /// Registered, but no agent process alive — a registration that has gone
    /// stale. Worth surfacing, because every other signal says backups are on
    /// while nothing is actually scheduled to run.
    private(set) var isAgentStale = false

    private var observers: [() -> Void] = []
    private var loop: Task<Void, Never>?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        reregisterAgentIfStale()
        loop = Task { await runLoop() }
    }

    /// Repairs a registration that has gone stale, and only then.
    ///
    /// Replacing the bundle — an update, or a rebuild during development —
    /// leaves the registration pointing at the old code-signing hash, and
    /// launchd then refuses to start the agent: registered, but not running.
    /// That combination is the signal, and re-registering from the new build
    /// reconciles it.
    ///
    /// Crucially this must NOT run against a healthy agent. Verified on real
    /// hardware: `register()` on an already-registered service re-submits the
    /// job, which terminates the running agent, and does not re-trigger
    /// `RunAtLoad` — so an unconditional re-register silently stopped the
    /// scheduler on every launch and left it stopped. The old `KeepAlive: true`
    /// used to paper over that by restarting it instantly; now that a clean
    /// exit is allowed to stick, nothing does.
    private func reregisterAgentIfStale() {
        guard agent.status == .enabled, !agent.isRunning else { return }
        Task {
            do {
                try await agent.reregister()
            } catch {
                // Not fatal: the banner and Settings still report the real
                // status, and the user can turn it off and on again.
                NSLog("Escapement: could not repair the agent registration: \(error)")
            }
            await refreshState()
        }
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

    /// Whether scheduled backups are currently suppressed.
    var isPaused: Bool { agentState.isPaused(at: Date()) }

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

    /// Asks the agent to suppress scheduled backups. The GUI never writes the
    /// pause itself — the agent is the sole writer of `state.json`.
    func pause(_ option: PauseOption) {
        guard isAgentEnabled else { return }
        try? commandStore.post(.pause(until: option.expiry(from: Date(), calendar: calendar)))
        requestRefresh()
    }

    func resume() {
        guard isAgentEnabled else { return }
        try? commandStore.post(.resume)
        requestRefresh()
    }

    // MARK: - Configuration

    /// Persists a preference change, reporting whether it actually landed.
    ///
    /// The in-memory copy is updated only on a successful write. Assigning it
    /// unconditionally would show the new value, and then the refresh loop —
    /// which re-reads the file every few seconds — would silently revert the
    /// control with no explanation of why.
    @discardableResult
    private func updateConfiguration(_ change: (inout Configuration) -> Void) -> Bool {
        var config = configuration
        change(&config)
        do {
            try configurationStore.save(config)
        } catch {
            notify()  // put the control back where the stored value says
            return false
        }
        configuration = config
        notify()
        return true
    }

    @discardableResult
    func setShowsMenuBarIcon(_ shows: Bool) -> Bool {
        updateConfiguration { $0.showsMenuBarIcon = shows }
    }

    @discardableResult
    func setNotifiesOnFailure(_ notifies: Bool) -> Bool {
        updateConfiguration { $0.notifiesOnFailure = notifies }
    }

    /// Called when the user asked for failure notifications but the system
    /// refused permission, so the UI can explain instead of quietly lying.
    var onNotificationAuthorizationDenied: (() -> Void)?

    /// Asks for notification permission from the GUI, where the user just
    /// clicked, rather than from the agent.
    ///
    /// The result is acted on: if permission is refused, the preference goes
    /// back off. Leaving it on would promise notifications that can never
    /// arrive.
    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            granted, _ in
            guard !granted else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setNotifiesOnFailure(false)
                self.onNotificationAuthorizationDenied?()
            }
        }
    }

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
        self.agentState = (try? stateStore.load()) ?? agentState
        self.isAgentStale = agent.status == .enabled && !agent.isRunning
        notify()
    }

    @objc private func didWake() {
        Task { await refreshState() }
    }
}
