import Foundation
import Testing

@testable import EscapementKit

/// `AgentState`'s update-check fields: a successful check always overwrites
/// `availableUpdate` (including clearing it), while a failed check only
/// stamps the timestamp so a transient outage can't erase a real result. See
/// spec 014.
@Suite("AgentState update-check fields")
struct AgentStateUpdateCheckTests {

    private let checkedAt = Date(timeIntervalSince1970: 1_000_000)
    private let update = AvailableUpdate(
        version: "1.1.0", releaseURL: URL(string: "https://example.com/v1.1.0")!)

    @Test("a fresh state has never checked")
    func freshHasNeverChecked() {
        let state = AgentState()
        #expect(state.lastUpdateCheck == nil)
        #expect(state.availableUpdate == nil)
    }

    @Test("recordUpdateCheck stores the timestamp and an available update")
    func recordsAvailableUpdate() {
        var state = AgentState()
        state.recordUpdateCheck(at: checkedAt, availableUpdate: update)
        #expect(state.lastUpdateCheck == checkedAt)
        #expect(state.availableUpdate == update)
    }

    @Test("recordUpdateCheck with nil clears a previously known update")
    func clearsAvailableUpdate() {
        var state = AgentState()
        state.recordUpdateCheck(at: checkedAt, availableUpdate: update)
        let later = checkedAt.addingTimeInterval(86_400)
        state.recordUpdateCheck(at: later, availableUpdate: nil)
        #expect(state.lastUpdateCheck == later)
        #expect(state.availableUpdate == nil)
    }

    @Test("recordFailedUpdateCheck stamps the timestamp without touching a known update")
    func failedCheckPreservesKnownUpdate() {
        var state = AgentState()
        state.recordUpdateCheck(at: checkedAt, availableUpdate: update)
        let later = checkedAt.addingTimeInterval(3_600)
        state.recordFailedUpdateCheck(at: later)
        #expect(state.lastUpdateCheck == later)
        #expect(state.availableUpdate == update)
    }

    @Test("a state file predating these fields decodes with no check recorded")
    func decodesWithoutKeys() throws {
        let state = try JSONDecoder().decode(AgentState.self, from: Data(#"{}"#.utf8))
        #expect(state.lastUpdateCheck == nil)
        #expect(state.availableUpdate == nil)
    }

    @Test("an available update survives a round trip through the real store")
    func roundTripsThroughStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("escapement-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StateStore(url: url)

        var state = AgentState()
        state.recordUpdateCheck(at: checkedAt, availableUpdate: update)
        try store.save(state)

        let loaded = try store.load()
        #expect(loaded.lastUpdateCheck == checkedAt)
        #expect(loaded.availableUpdate == update)
    }
}

/// `Configuration.updateCheckInterval` follows the same backward-compatible
/// decoding as `notifiesOnFailure`: a file predating the key decodes as the
/// default rather than failing, so an existing install upgrades cleanly.
@Suite("Configuration update-check interval")
struct ConfigurationUpdateCheckIntervalTests {

    @Test("a fresh configuration defaults to onStartup")
    func defaultsToOnStartup() {
        #expect(Configuration().updateCheckInterval == .onStartup)
    }

    @Test("a configuration file predating the key decodes as onStartup")
    func decodesMissingKeyAsOnStartup() throws {
        let json = #"{"schemaVersion":1,"schedules":[]}"#
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
        #expect(configuration.updateCheckInterval == .onStartup)
    }

    @Test("an explicit interval round-trips")
    func explicitIntervalRoundTrips() throws {
        var configuration = Configuration()
        configuration.updateCheckInterval = .weekly
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(Configuration.self, from: data)
        #expect(decoded.updateCheckInterval == .weekly)
    }
}

/// `AgentCommand.checkForUpdatesNow` follows the existing one-shot command
/// pattern (`backUpNow`, `stop`, `pause`, `resume`).
@Suite("AgentCommand checkForUpdatesNow coding")
struct AgentCommandCheckForUpdatesNowTests {
    @Test("round-trips")
    func roundTrips() throws {
        let data = try JSONEncoder().encode(AgentCommand.checkForUpdatesNow)
        let decoded = try JSONDecoder().decode(AgentCommand.self, from: data)
        #expect(decoded == .checkForUpdatesNow)
    }
}
