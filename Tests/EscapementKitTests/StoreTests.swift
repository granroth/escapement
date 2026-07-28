import Foundation
import Testing

@testable import EscapementKit

/// A scratch directory removed at the end of each test instance.
private final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("escapement-tests-\(UUID().uuidString)", isDirectory: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

private func time(_ h: Int) -> TimeOfDay { TimeOfDay(hour: h, minute: 0)! }

@Suite("Configuration store")
struct ConfigurationStoreTests {

    @Test("a missing file loads as empty configuration")
    func missingLoadsEmpty() throws {
        let tmp = TempDir()
        let store = ConfigurationStore(url: tmp.file("configuration.json"))
        #expect(try store.load().schedules.isEmpty)
    }

    @Test("configuration round-trips through disk")
    func roundTrip() throws {
        let tmp = TempDir()
        let store = ConfigurationStore(url: tmp.file("configuration.json"))
        var config = Configuration()
        config.upsert(
            DestinationSchedule(
                destinationID: "A",
                recurrence: .daily(times: [time(3)])!,
                isEnabled: true,
                effectiveFrom: Date(timeIntervalSince1970: 1_000_000)))
        try store.save(config)

        let loaded = try store.load()
        #expect(loaded == config)
        #expect(loaded.schemaVersion == Configuration.currentSchemaVersion)
    }

    @Test("a corrupt file surfaces as an error, not a crash")
    func corruptFileThrows() throws {
        let tmp = TempDir()
        let url = tmp.file("configuration.json")
        try FileManager.default.createDirectory(at: tmp.url, withIntermediateDirectories: true)
        // A schedule carrying an out-of-range recurrence: valid JSON, invalid
        // domain value, which the validating decode must reject rather than
        // load into a value that would later crash the scheduler.
        let bad = #"""
            {"schemaVersion":1,"schedules":[{"destinationID":"A","isEnabled":true,
            "effectiveFrom":0,"recurrence":{"kind":{"hourly":{"everyHours":0,"minute":0}},"times":[]}}]}
            """#
        try Data(bad.utf8).write(to: url)
        #expect(throws: (any Error).self) { try ConfigurationStore(url: url).load() }
    }
}

@Suite("History store")
struct HistoryStoreTests {

    private func run(_ id: String, _ startedAt: Date, outcome: BackupRun.Outcome) -> BackupRun {
        BackupRun(
            destinationID: id, trigger: .scheduled, startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(60), outcome: outcome)
    }

    @Test("a missing file loads as empty history")
    func missingLoadsEmpty() throws {
        let tmp = TempDir()
        #expect(try HistoryStore(url: tmp.file("history.json")).load().isEmpty)
    }

    @Test("appends newest first")
    func appendsNewestFirst() throws {
        let tmp = TempDir()
        let store = HistoryStore(url: tmp.file("history.json"))
        let first = run("A", Date(timeIntervalSince1970: 100), outcome: .completed)
        let second = run("B", Date(timeIntervalSince1970: 200), outcome: .completed)
        try store.append(first)
        try store.append(second)
        #expect(try store.load().map(\.destinationID) == ["B", "A"])
    }

    @Test("retention trims the oldest beyond the limit")
    func retentionTrims() throws {
        let tmp = TempDir()
        let store = HistoryStore(url: tmp.file("history.json"), retentionLimit: 3)
        for i in 0..<5 {
            try store.append(
                run("D", Date(timeIntervalSince1970: Double(i)), outcome: .completed))
        }
        let loaded = try store.load()
        #expect(loaded.count == 3)
        // Newest three retained: t=4, 3, 2.
        #expect(loaded.map(\.startedAt.timeIntervalSince1970) == [4, 3, 2])
    }

    @Test("update moves a run to its final outcome in place")
    func updateInPlace() throws {
        let tmp = TempDir()
        let store = HistoryStore(url: tmp.file("history.json"))
        var r = BackupRun(
            destinationID: "A", trigger: .manual,
            startedAt: Date(timeIntervalSince1970: 100))
        try store.append(r)
        r.outcome = .completed
        r.finishedAt = Date(timeIntervalSince1970: 160)
        try store.update(r)

        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].outcome == .completed)
    }

    @Test("only completed runs count toward the last-run reference")
    func lastCompletedIgnoresFailures() throws {
        let tmp = TempDir()
        let store = HistoryStore(url: tmp.file("history.json"))
        // A failed run at t=300 is more recent than a completed one at t=100,
        // but a failure backed nothing up, so the reference stays at t=100.
        try store.append(run("A", Date(timeIntervalSince1970: 100), outcome: .completed))
        try store.append(
            run("A", Date(timeIntervalSince1970: 300), outcome: .failed(reason: "unreachable")))
        let last = try store.lastCompletedRuns()
        #expect(last["A"]?.timeIntervalSince1970 == 160)  // finishedAt of the completed run
    }

    @Test("last-run reference keeps the most recent completion per destination")
    func lastCompletedPerDestination() throws {
        let tmp = TempDir()
        let store = HistoryStore(url: tmp.file("history.json"))
        try store.append(run("A", Date(timeIntervalSince1970: 100), outcome: .completed))
        try store.append(run("A", Date(timeIntervalSince1970: 500), outcome: .completed))
        try store.append(run("B", Date(timeIntervalSince1970: 300), outcome: .completed))
        let last = try store.lastCompletedRuns()
        #expect(last["A"]?.timeIntervalSince1970 == 560)
        #expect(last["B"]?.timeIntervalSince1970 == 360)
    }

    @Test("mostRecentAttempts keeps the latest start per destination regardless of outcome")
    func mostRecentAttemptsAcrossOutcomes() throws {
        let tmp = TempDir()
        let store = HistoryStore(url: tmp.file("history.json"))
        try store.append(run("A", Date(timeIntervalSince1970: 100), outcome: .completed))
        try store.append(
            run("A", Date(timeIntervalSince1970: 300), outcome: .failed(reason: "unreachable")))
        let attempts = try store.mostRecentAttempts()
        // Unlike lastCompletedRuns, a later *failed* attempt still counts: a
        // destination that just failed should not look like it hasn't been
        // tried in a while.
        #expect(attempts["A"]?.timeIntervalSince1970 == 300)
    }

    @Test("mostRecentAttempts ignores skipped occurrences — no attempt was made")
    func mostRecentAttemptsIgnoresSkipped() throws {
        let tmp = TempDir()
        let store = HistoryStore(url: tmp.file("history.json"))
        try store.append(run("A", Date(timeIntervalSince1970: 100), outcome: .completed))
        try store.append(run("A", Date(timeIntervalSince1970: 900), outcome: .skipped(reason: nil)))
        let attempts = try store.mostRecentAttempts()
        #expect(attempts["A"]?.timeIntervalSince1970 == 100)
    }

    @Test("lastCompletedRuns ignores skipped occurrences")
    func lastCompletedIgnoresSkipped() throws {
        let tmp = TempDir()
        let store = HistoryStore(url: tmp.file("history.json"))
        try store.append(run("A", Date(timeIntervalSince1970: 900), outcome: .skipped(reason: nil)))
        let last = try store.lastCompletedRuns()
        #expect(last["A"] == nil)
    }
}
