import Foundation
import Testing

@testable import EscapementKit

/// Regression tests for the storage findings from adversarial review: a
/// read-modify-write race that dropped history entries, and a load path that
/// masked an unreadable file as an empty one.
@Suite("Store robustness")
struct StoreRobustnessTests {

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("escapement-conc-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func run(_ i: Int) -> BackupRun {
        BackupRun(
            destinationID: "D", trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: Double(i)), outcome: .completed)
    }

    @Test("concurrent appends do not lose entries")
    func concurrentAppends() async throws {
        let url = tempURL("history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = HistoryStore(url: url, retentionLimit: 10_000)

        // Many stores, many tasks, one file: before the fix this lost the
        // large majority of entries to interleaved read-modify-writes.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    try? HistoryStore(url: url, retentionLimit: 10_000).append(self.run(i))
                }
            }
        }

        #expect(try store.load().count == 200)
    }

    @Test("an unreadable file throws rather than masquerading as empty")
    func unreadableFileThrows() throws {
        let url = tempURL("configuration.json")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let store = ConfigurationStore(url: url)

        var config = Configuration()
        config.upsert(
            DestinationSchedule(
                destinationID: "A", recurrence: .daily(times: [TimeOfDay(hour: 3, minute: 0)!])!,
                isEnabled: true, effectiveFrom: Date(timeIntervalSince1970: 0)))
        try store.save(config)

        // Make it present-but-unreadable. If run as root, chmod is ignored and
        // the read still succeeds, so only assert when the denial actually took.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        let stillReadable = (try? Data(contentsOf: url)) != nil
        try #require(!stillReadable, "cannot simulate an unreadable file (running as root?)")

        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test("a genuinely missing file still loads as the default")
    func missingStillDefaults() throws {
        let url = tempURL("configuration.json")
        #expect(try ConfigurationStore(url: url).load().schedules.isEmpty)
    }
}
