import Foundation
import Testing

@testable import EscapementKit

/// The two lines at the top of the menu bar extra. They are the only thing a
/// user sees without opening the app, so the priority order between them —
/// running beats paused beats scheduled — is the whole behaviour worth pinning.
@Suite("StatusSummary")
struct StatusSummaryTests {

    private func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Phoenix")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar().date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private var builder: StatusSummaryBuilder {
        StatusSummaryBuilder(calendar: calendar(), locale: Locale(identifier: "en_US_POSIX"))
    }

    /// ICU puts a narrow no-break space before AM/PM, which no one can see in a
    /// test literal. Normalising it keeps the expectations readable without
    /// making the production strings non-standard.
    private func plain(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private let backups = Destination(
        id: "D1", name: "Backups", kind: .network(url: "smb://nas/Backups"), isLastUsed: true)

    private func dailyConfig(hour: Int) -> Configuration {
        var config = Configuration()
        config.upsert(
            DestinationSchedule(
                destinationID: "D1",
                recurrence: .daily(times: [TimeOfDay(hour: hour, minute: 0)!])!,
                isEnabled: true, effectiveFrom: date(2026, 3, 1)))
        return config
    }

    private func pausedState(_ until: Date) -> AgentState {
        var state = AgentState()
        state.pause(until: until)
        return state
    }

    private func summary(
        configuration: Configuration = Configuration(),
        state: AgentState = AgentState(),
        history: [BackupRun] = [],
        activity: BackupActivity = .idle,
        now: Date? = nil
    ) -> StatusSummary {
        builder.summary(
            destinations: [backups], configuration: configuration, state: state,
            history: history, activity: activity, now: now ?? date(2026, 3, 10, 12, 0))
    }

    // MARK: - State line priority

    @Test("a running backup outranks everything else and shows its progress")
    func runningWins() {
        let s = summary(
            configuration: dailyConfig(hour: 3), state: pausedState(date(2026, 3, 10, 18, 0)),
            activity: .running(
                destinationID: "D1", phase: .copying,
                progress: BackupProgress(fractionCompleted: 0.42)))

        #expect(plain(s.stateLine) == "Copying — 42%")
        #expect(s.isRunning)
    }

    @Test("a running backup with no progress figure still names its phase")
    func runningWithoutProgress() {
        let s = summary(activity: .running(destinationID: "D1", phase: .preparing, progress: nil))
        #expect(plain(s.stateLine) == "Preparing")
        #expect(s.isRunning)
    }

    @Test("a cancellation in flight reads as stopping")
    func stopping() {
        let s = summary(activity: .stopping(destinationID: "D1"))
        #expect(plain(s.stateLine) == "Stopping…")
        #expect(s.isRunning)
    }

    @Test("a pause outranks the next scheduled backup and names its end")
    func pausedUntilWins() {
        let s = summary(
            configuration: dailyConfig(hour: 3), state: pausedState(date(2026, 3, 10, 18, 0)))

        #expect(plain(s.stateLine) == "Paused until 6:00 PM")
        #expect(s.isPaused)
        #expect(!s.isRunning)
    }

    @Test("an indefinite pause has no end to name")
    func pausedIndefinitely() {
        var state = AgentState()
        state.pauseIndefinitely()
        let s = summary(configuration: dailyConfig(hour: 3), state: state)

        #expect(plain(s.stateLine) == "Paused")
        #expect(s.isPaused)
    }

    @Test("an expired pause does not colour the summary")
    func expiredPauseIgnored() {
        let s = summary(
            configuration: dailyConfig(hour: 3), state: pausedState(date(2026, 3, 10, 9, 0)))
        #expect(!s.isPaused)
        #expect(s.stateLine.hasPrefix("Next backup:"))
    }

    @Test("an idle scheduled destination shows when it next runs, by name")
    func nextScheduled() {
        let s = summary(configuration: dailyConfig(hour: 15))
        #expect(plain(s.stateLine) == "Next backup: Backups at 3:00 PM")
    }

    @Test("with nothing scheduled the summary says so rather than showing a dash")
    func nothingScheduled() {
        let s = summary()
        #expect(plain(s.stateLine) == "No backups scheduled")
        #expect(!s.isPaused)
        #expect(!s.isRunning)
    }

    @Test("a disabled schedule does not count as scheduled")
    func disabledScheduleIgnored() {
        var config = Configuration()
        config.upsert(
            DestinationSchedule(
                destinationID: "D1",
                recurrence: .daily(times: [TimeOfDay(hour: 15, minute: 0)!])!,
                isEnabled: false, effectiveFrom: date(2026, 3, 1)))
        #expect(plain(summary(configuration: config).stateLine) == "No backups scheduled")
    }

    @Test("the soonest destination wins when several are scheduled")
    func soonestWins() {
        var config = dailyConfig(hour: 20)
        config.upsert(
            DestinationSchedule(
                destinationID: "D2",
                recurrence: .daily(times: [TimeOfDay(hour: 14, minute: 0)!])!,
                isEnabled: true, effectiveFrom: date(2026, 3, 1)))
        let other = Destination(
            id: "D2", name: "Example Local Backup", kind: .local, isLastUsed: false)

        let s = builder.summary(
            destinations: [backups, other], configuration: config, state: AgentState(),
            history: [], activity: .idle, now: date(2026, 3, 10, 12, 0))

        #expect(plain(s.stateLine) == "Next backup: Example Local Backup at 2:00 PM")
    }

    @Test("a schedule for a destination that is no longer attached falls back to its id")
    func unknownDestinationFallsBack() {
        var config = Configuration()
        config.upsert(
            DestinationSchedule(
                destinationID: "GONE",
                recurrence: .daily(times: [TimeOfDay(hour: 15, minute: 0)!])!,
                isEnabled: true, effectiveFrom: date(2026, 3, 1)))
        // Better to name the unknown id than to silently claim nothing is due.
        #expect(plain(summary(configuration: config).stateLine) == "Next backup: GONE at 3:00 PM")
    }

    // MARK: - Latest line

    @Test("with no history the latest line says never")
    func latestNever() {
        #expect(plain(summary().latestLine) == "Latest backup: never")
    }

    @Test("the most recent finished run is reported, not an open one")
    func latestIgnoresOpenRuns() {
        var finished = BackupRun(
            destinationID: "D1", trigger: .scheduled, startedAt: date(2026, 3, 10, 9, 0))
        finished.finishedAt = date(2026, 3, 10, 9, 30)
        finished.outcome = .completed
        let open = BackupRun(
            destinationID: "D1", trigger: .manual, startedAt: date(2026, 3, 10, 11, 55))

        let s = summary(history: [open, finished])
        #expect(plain(s.latestLine) == "Latest backup: Today at 9:30 AM")
    }

    @Test("a failed latest run is labelled as failed rather than passed off as a backup")
    func latestFailed() {
        var failed = BackupRun(
            destinationID: "D1", trigger: .scheduled, startedAt: date(2026, 3, 10, 9, 0))
        failed.finishedAt = date(2026, 3, 10, 9, 5)
        failed.outcome = .failed(reason: "destination unreachable")

        #expect(plain(summary(history: [failed]).latestLine) == "Latest backup: failed Today at 9:05 AM")
    }
}
