import AppKit
import EscapementKit
import ServiceManagement
import UserNotifications
import os

/// The background scheduler. Owns the `SchedulerRunner`, a timer armed for the
/// next scheduled fire, wake observation, a watch on the support directory for
/// configuration changes and manual commands, and the menu bar extra. It is the
/// single process that fires backups and writes history.
@MainActor
final class AgentService: NSObject, StatusItemActions, UNUserNotificationCenterDelegate {

    private let control = TMUtilController()
    private let configurationStore = ConfigurationStore()
    private let historyStore = HistoryStore()
    private let commandStore = CommandStore()
    private let stateStore = StateStore()
    private var menuBarSuppression = MenuBarSuppression()
    /// When the item was last rebuilt to test whether macOS has started
    /// permitting it again. `nil` until the first attempt.
    private var lastMenuBarRebuild: Date?
    /// How long to leave between rebuild attempts. Long enough that a fresh
    /// item can settle and be judged — a rebuild resets the reading to
    /// `settling`, and confirming suppression again needs two more after it —
    /// and short enough that restoring the permission brings the icon back on
    /// its own within a few minutes.
    private let menuBarRebuildInterval: TimeInterval = 180
    /// What is already in `state.json`, so an unchanged verdict is not
    /// rewritten on every tick. Seeded from the file at startup rather than
    /// left nil: the previous run's conclusion is still the published one, and
    /// a fresh process should not rewrite it just because it has forgotten.
    private lazy var lastPublishedMenuBarSuppression: Bool? =
        (try? stateStore.load())?.menuBarIconSuppressed
    private let runner: SchedulerRunner
    private let log = Logger(subsystem: "com.granroth.Escapement", category: "agent")
    private let summaryBuilder = StatusSummaryBuilder(calendar: .current, locale: .current)
    private let updateChecker = UpdateChecker(source: GitHubReleaseSource())

    private var statusItem: StatusItemController!

    private var timer: DispatchSourceTimer?
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1

    /// Failed-run ids already accounted for. Seeded in `start()` from the
    /// history on disk and thereafter kept to exactly the failures still in
    /// history, so it cannot grow past the store's retention limit.
    private var notifiedFailureIDs: Set<UUID> = []

    /// Longest gap between idle evaluations, so a clock change or an unnoticed
    /// wake is still caught even though a scheduled fire far in the future would
    /// otherwise set a distant timer.
    private let idleCap: TimeInterval = 60
    /// Cadence while a backup runs, to observe completion and close out history.
    private let activePoll: TimeInterval = 5

    /// Serialises evaluations. See `TickCoalescer` for why this matters.
    private let ticks = TickCoalescer()

    override init() {
        runner = SchedulerRunner(
            control: control,
            configuration: configurationStore,
            history: historyStore,
            state: stateStore,
            scheduler: Scheduler(calendar: .current),
            now: { Date() })
        super.init()
        statusItem = StatusItemController(actions: self)
    }

    func start() {
        log.log("agent starting")
        // Seed before the first evaluation, not during it. `evaluate()` closes
        // runs stranded by a crash as failed, and those are discovered *now* —
        // seeding afterwards would file them under "old news" and stay silent
        // about exactly the case the user most wants to hear about.
        seedKnownFailures()
        observeWake()
        watchSupportDirectory()
        UNUserNotificationCenter.current().delegate = self
        // Independent of the scheduling tick below: the network round trip
        // must never delay the very first backup evaluation of the run.
        Task { await self.performStartupUpdateCheckIfNeeded() }
        Task { await self.tick() }
    }

    // MARK: - The tick

    /// Runs one evaluation, coalescing everything asked for while it runs into
    /// a single follow-up.
    ///
    /// The guard is not an optimisation. The support-directory watcher starts a
    /// tick on every file-system event and the agent writes `history.json` and
    /// `state.json` into that same directory, so it triggers itself; without
    /// coalescing, one slow `tmutil` call becomes as many concurrent stalled
    /// ticks as the watcher can fire.
    private func tick() async {
        await ticks.run { await self.runTick() }
    }

    private func runTick() async {
        await processCommands()
        await runner.evaluate()
        await notifyOfNewFailures()
        checkForUpdatesIfDue()
        await refreshStatusItem()
        await rescheduleTimer()
    }

    /// Records the failures already on disk at launch, so starting the agent
    /// never replays a backlog as fresh notifications.
    private func seedKnownFailures() {
        notifiedFailureIDs = Set(failedRuns().map(\.id))
    }

    private func failedRuns() -> [BackupRun] {
        ((try? historyStore.load()) ?? []).filter {
            if case .failed = $0.outcome { return true }
            return false
        }
    }

    /// Announces runs that have failed since the last check, if the user asked
    /// to be told.
    private func notifyOfNewFailures() async {
        let configuration = (try? configurationStore.load()) ?? Configuration()
        let failed = failedRuns()

        let fresh = failed.filter { !notifiedFailureIDs.contains($0.id) }
        // Track exactly what history still holds. History is capped and trims
        // its oldest entries, so carrying ids forever would grow without bound
        // for no benefit — a trimmed id can never return, ids being unique.
        notifiedFailureIDs = Set(failed.map(\.id))
        guard configuration.notifiesOnFailure, !fresh.isEmpty else { return }

        let destinations = (try? await control.destinations()) ?? []
        for run in fresh {
            let name =
                destinations.first { $0.id == run.destinationID }?.name ?? run.destinationID
            postFailureNotification(destinationName: name, run: run)
        }
    }

    private func postFailureNotification(destinationName: String, run: BackupRun) {
        let content = UNMutableNotificationContent()
        content.title = "Backup failed"
        if case .failed(let reason) = run.outcome, let reason, !reason.isEmpty {
            content.body = "\(destinationName): \(reason)"
        } else {
            content.body = "Escapement could not back up to \(destinationName)."
        }
        let request = UNNotificationRequest(
            identifier: run.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [log] error in
            if let error {
                log.error(
                    "could not post failure notification: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func processCommands() async {
        // Drain any pending manual command. `take` removes it, so it runs once.
        while let command = try? commandStore.take() {
            switch command {
            case .backUpNow(let destinationID):
                log.log("manual back-up requested for \(destinationID, privacy: .public)")
                await runner.backUpNow(destinationID: destinationID)
            case .stop:
                log.log("manual stop requested")
                try? await control.stopBackup()
            case .pause(let until):
                log.log("pause requested")
                await runner.pause(until: until)
            case .resume:
                log.log("resume requested")
                await runner.resume()
            case .showMenuBarIcon:
                log.log("menu bar icon requested")
                statusItem.assertVisible()
            case .checkForUpdatesNow:
                log.log("update check requested")
                // Spawned, not awaited, like the due-check below: this command
                // is drained inside the same `tick()` that evaluates schedules,
                // and a slow or hung network request must never delay that.
                Task { await self.performUpdateCheck() }
            }
        }
    }

    /// Watches for macOS suppressing the menu bar item and publishes the
    /// verdict for the GUI, so a ticked "Show Escapement in the menu bar" box
    /// with no icon beside it can be explained rather than left a mystery.
    ///
    /// Written only when the verdict changes. `state.json` is read by the GUI
    /// on every change notification, and a tick that rewrites it unchanged
    /// would wake that up as often as once every five seconds for nothing.
    private func observeMenuBarSuppression(wanted: Bool) {
        // Only meaningful when the icon is supposed to be showing. With the
        // preference off there is no item, and its absence is the user's doing.
        menuBarSuppression.observe(wanted ? statusItem.placement : .absent)

        // While the item is believed suppressed, rebuild it periodically. That
        // is the only way to find out whether the user has allowed Escapement
        // again, because the permission is read when the item is created and
        // never revisited for an existing one.
        if wanted, menuBarSuppression.verdict == true {
            let now = Date()
            if now.timeIntervalSince(lastMenuBarRebuild ?? .distantPast)
                >= menuBarRebuildInterval
            {
                lastMenuBarRebuild = now
                log.log("rebuilding the menu bar item to retest the system's permission")
                statusItem.reinstall()
            }
        } else {
            lastMenuBarRebuild = nil
        }

        // An unknown verdict publishes nothing, so whatever the previous run
        // concluded stands until this one has grounds to disagree.
        guard let verdict = menuBarSuppression.verdict,
            verdict != lastPublishedMenuBarSuppression
        else { return }
        lastPublishedMenuBarSuppression = verdict
        log.log("menu bar icon suppressed by the system: \(verdict, privacy: .public)")
        try? stateStore.mutate { $0.setMenuBarIconSuppressed(verdict) }
    }

    // MARK: - Update check

    /// The one network call in the whole app (see spec 014). Runs once per
    /// process launch when the interval is `.onStartup` specifically — NOT
    /// for every non-`.never` interval. Daily/weekly/monthly are driven
    /// entirely by `checkForUpdatesIfDue()`'s elapsed-time math below; firing
    /// them here too would let both paths decide independently that a check
    /// is due (e.g. whenever `lastUpdateCheck` is stale at launch, the common
    /// case) and run concurrently.
    private func performStartupUpdateCheckIfNeeded() async {
        let configuration = (try? configurationStore.load()) ?? Configuration()
        guard configuration.updateCheckInterval == .onStartup else { return }
        await performUpdateCheck()
    }

    /// Checked on every tick, not just at startup, so daily/weekly/monthly
    /// intervals fire without requiring a restart. Spawned rather than
    /// awaited so a slow or hung network request can never delay backup
    /// scheduling, which `tick()` also does every pass.
    private func checkForUpdatesIfDue() {
        Task {
            let configuration = (try? configurationStore.load()) ?? Configuration()
            let lastChecked = (try? stateStore.load())?.lastUpdateCheck
            guard
                UpdateCheckScheduling.isDue(
                    interval: configuration.updateCheckInterval, lastCheckedAt: lastChecked,
                    now: Date())
            else { return }
            await performUpdateCheck()
        }
    }

    /// Guards against two `performUpdateCheck()` calls overlapping — e.g. a
    /// Check Now command landing while the startup or a scheduled check is
    /// still awaiting its network round trip. Both would otherwise read the
    /// same stale `availableUpdate` before either writes back, and could
    /// both notify. Safe as a plain `Bool` because every caller runs on the
    /// main actor and the check happens before this function's own first
    /// `await`, so nothing can interleave between the check and the set.
    private var updateCheckInFlight = false

    /// Runs a check right now, records the outcome, and — only when the
    /// found version differs from the one already on record — announces it.
    /// A failed check stamps the timestamp so it doesn't retry every tick,
    /// but leaves a previously known update in place; a transient outage
    /// must not erase a real result.
    private func performUpdateCheck() async {
        guard !updateCheckInFlight else { return }
        updateCheckInFlight = true
        defer { updateCheckInFlight = false }

        let currentVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let previous = (try? stateStore.load())?.availableUpdate
        do {
            let result = try await updateChecker.checkForUpdate(currentVersion: currentVersion)
            try? stateStore.mutate { $0.recordUpdateCheck(at: Date(), availableUpdate: result) }
            if let result, result.version != previous?.version {
                postUpdateNotification(result)
            }
        } catch {
            log.error("update check failed: \(error.localizedDescription, privacy: .public)")
            try? stateStore.mutate { $0.recordFailedUpdateCheck(at: Date()) }
        }
    }

    private func postUpdateNotification(_ update: AvailableUpdate) {
        let content = UNMutableNotificationContent()
        content.title = "Escapement \(update.version) is available"
        content.body = "Tap to view the release on GitHub."
        content.userInfo = ["releaseURL": update.releaseURL.absoluteString]
        let request = UNNotificationRequest(
            identifier: "update-\(update.version)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [log] error in
            if let error {
                log.error(
                    "could not post update notification: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Clicking the update notification opens the release page in the
    /// default browser, not the app — there's nothing in the app to show for
    /// it, the release page is the whole point.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let urlString = response.notification.request.content.userInfo["releaseURL"] as? String,
            let url = URL(string: urlString)
        else { return }
        Task { @MainActor in
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Menu bar extra

    /// Rebuilds the snapshot the menu draws from. Everything here is a
    /// read-only `tmutil` call the agent already makes, so the menu adds no
    /// write authority.
    private func refreshStatusItem() async {
        let configuration = (try? configurationStore.load()) ?? Configuration()
        statusItem.setVisible(configuration.showsMenuBarIcon)
        observeMenuBarSuppression(wanted: configuration.showsMenuBarIcon)
        guard configuration.showsMenuBarIcon else { return }

        let destinations = (try? await control.destinations()) ?? []
        let activity = (try? await control.activity()) ?? .idle
        let history = (try? historyStore.load()) ?? []
        let state = await runner.currentState()

        let summary = summaryBuilder.summary(
            destinations: destinations, configuration: configuration, state: state,
            history: history, activity: activity, now: Date())

        statusItem.update(
            StatusMenuModel(
                summary: summary,
                destinations: destinations,
                scheduledDestinationIDs: Set(
                    configuration.schedules.filter(\.isEnabled).map(\.destinationID))))
    }

    // MARK: - StatusItemActions

    func statusItemBackUpNow(destinationID: String) {
        Task {
            await runner.backUpNow(destinationID: destinationID)
            await tick()
        }
    }

    func statusItemStop() {
        Task {
            try? await control.stopBackup()
            await tick()
        }
    }

    // Pause and resume go through the same `command.json` the GUI posts to,
    // rather than being applied here directly. That single slot is
    // last-writer-wins, which is the semantics we want; applying the change
    // in-process instead would let a GUI request still sitting unread in the
    // file land afterwards and silently undo a fresher click — in either
    // direction, including un-pausing a window the user just paused.
    func statusItemPause(_ option: PauseOption) {
        try? commandStore.post(.pause(until: option.expiry(from: Date(), calendar: .current)))
        Task { await tick() }
    }

    func statusItemResume() {
        try? commandStore.post(.resume)
        Task { await tick() }
    }

    func statusItemOpenApp() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: AgentPlist.containingAppURL, configuration: configuration)
    }

    func statusItemTurnOffBackgroundBackups() {
        // Confirm first: this is the one item in the menu that stops everything,
        // and it ends the very process showing the menu, so there is no room to
        // report back afterwards.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Turn off background backups?"
        alert.informativeText =
            "Escapement will stop running your schedules, and its menu bar icon will disappear. "
            + "You can turn it back on in Escapement’s settings."
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            do {
                // Unregistering ends this process, which is the intended effect:
                // the icon disappearing is how the user sees that it worked.
                try await SMAppService.agent(plistName: AgentPlist.name).unregister()
                log.log("background backups turned off by the user")
            } catch {
                // The user confirmed and was promised the icon would disappear.
                // Staying silent would leave them unable to tell whether it
                // worked, so say so rather than only writing to the log.
                log.error("could not unregister: \(error.localizedDescription, privacy: .public)")
                let failure = NSAlert()
                failure.messageText = "Couldn’t turn off background backups"
                failure.informativeText = error.localizedDescription
                failure.addButton(withTitle: "OK")
                failure.runModal()
            }
        }
    }

    // MARK: - Timer

    private func rescheduleTimer() async {
        // Logged rather than swallowed: a `tmutil` that stops answering is the
        // one fault that silently stops the agent scheduling anything, and it
        // is otherwise invisible from outside the process.
        let activity: BackupActivity
        do {
            activity = try await control.activity()
        } catch {
            log.error("tmutil status failed: \(String(describing: error), privacy: .public)")
            activity = .idle
        }
        let interval: TimeInterval
        if activity == .idle {
            let next = await runner.nextWakeUp()
            let seconds = next.map { max(1, $0.timeIntervalSinceNow) } ?? idleCap
            interval = min(seconds, idleCap)
        } else {
            interval = activePoll
        }
        scheduleTimer(after: interval)
    }

    private func scheduleTimer(after interval: TimeInterval) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, leeway: .milliseconds(500))
        source.setEventHandler { [weak self] in
            Task { await self?.tick() }
        }
        timer = source
        source.resume()
    }

    // MARK: - Wake

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.log.log("woke from sleep; re-evaluating after debounce")
            // Give a network share a moment to remount before firing.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                await self.tick()
            }
        }
    }

    // MARK: - Directory watch

    /// Watches the support directory so a configuration change or a posted
    /// command triggers an evaluation promptly, without polling.
    private func watchSupportDirectory() {
        let directory = EscapementPaths.supportDirectory()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        directoryFD = open(directory.path, O_EVTONLY)
        guard directoryFD >= 0 else {
            log.error("could not watch support directory")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD, eventMask: [.write, .rename, .delete, .extend],
            queue: .main)
        source.setEventHandler { [weak self] in
            Task { await self?.tick() }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.directoryFD, fd >= 0 { close(fd) }
        }
        directorySource = source
        source.resume()
    }
}

/// The bundled LaunchAgent's plist name, shared by the app and the agent so the
/// two cannot drift apart.
enum AgentPlist {
    static let name = "com.granroth.Escapement.Agent.plist"

    /// The `Escapement.app` this agent is nested inside.
    ///
    /// `Bundle.main` is now the agent's *own* bundle at
    /// `Escapement.app/Contents/Library/LoginItems/EscapementAgent.app`, so the
    /// containing app is four levels up. Derived rather than hard-coded, so the
    /// app keeps working wherever it is installed.
    static var containingAppURL: URL {
        Bundle.main.bundleURL  // …/LoginItems/EscapementAgent.app
            .deletingLastPathComponent()  // …/LoginItems
            .deletingLastPathComponent()  // …/Library
            .deletingLastPathComponent()  // …/Contents
            .deletingLastPathComponent()  // …/Escapement.app
    }
}
