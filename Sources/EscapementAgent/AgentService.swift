import AppKit
import EscapementKit
import os

/// The background scheduler. Owns the `SchedulerRunner`, a timer armed for the
/// next scheduled fire, wake observation, and a watch on the support directory
/// for configuration changes and manual commands. It is the single process
/// that fires backups and writes history.
@MainActor
final class AgentService {

    private let control = TMUtilController()
    private let configurationStore = ConfigurationStore()
    private let historyStore = HistoryStore()
    private let commandStore = CommandStore()
    private let runner: SchedulerRunner
    private let log = Logger(subsystem: "com.granroth.Escapement", category: "agent")

    private var timer: DispatchSourceTimer?
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1

    /// Longest gap between idle evaluations, so a clock change or an unnoticed
    /// wake is still caught even though a scheduled fire far in the future would
    /// otherwise set a distant timer.
    private let idleCap: TimeInterval = 60
    /// Cadence while a backup runs, to observe completion and close out history.
    private let activePoll: TimeInterval = 5

    init() {
        runner = SchedulerRunner(
            control: control,
            configuration: configurationStore,
            history: historyStore,
            scheduler: Scheduler(calendar: .current),
            now: { Date() })
    }

    func start() {
        log.log("agent starting")
        observeWake()
        watchSupportDirectory()
        Task { await self.tick() }
    }

    // MARK: - The tick

    private func tick() async {
        await processCommands()
        await runner.evaluate()
        await rescheduleTimer()
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
            }
        }
    }

    private func rescheduleTimer() async {
        let activity = (try? await control.activity()) ?? .idle
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
