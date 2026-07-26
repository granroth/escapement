import Foundation
import Testing

@testable import EscapementKit

/// Pause is the *soft* stop: it suppresses scheduled fires without unregistering
/// the agent. It lives in the agent-owned `state.json` — not the GUI's
/// configuration file — so the two processes never write the same file, and it
/// survives a restart and a login.
@Suite("Pause")
struct PauseTests {

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Phoenix")!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: - State

    @Test("a fresh configuration is not paused")
    func freshIsNotPaused() {
        let config = AgentState()
        #expect(config.pausedUntil == nil)
        #expect(!config.isPaused(at: date(2026, 3, 10, 12, 0)))
    }

    @Test("paused until a future instant reads as paused before it and not after")
    func pausedWindow() {
        var config = AgentState()
        config.pause(until: date(2026, 3, 10, 14, 0))

        #expect(config.isPaused(at: date(2026, 3, 10, 13, 59)))
        // The boundary instant is already resumed: the pause is a half-open
        // window, so "pause for an hour" ends exactly an hour later.
        #expect(!config.isPaused(at: date(2026, 3, 10, 14, 0)))
        #expect(!config.isPaused(at: date(2026, 3, 10, 14, 1)))
    }

    @Test("pausing indefinitely stays paused arbitrarily far out")
    func indefinitePause() {
        var config = AgentState()
        config.pauseIndefinitely()

        #expect(config.isPaused(at: date(2099, 1, 1)))
        #expect(config.isPausedIndefinitely)
    }

    @Test("resuming clears the pause")
    func resumeClears() {
        var config = AgentState()
        config.pause(until: date(2026, 3, 10, 14, 0))
        config.resume()

        #expect(config.pausedUntil == nil)
        #expect(!config.isPaused(at: date(2026, 3, 10, 13, 0)))
    }

    @Test("a pause already in the past is not treated as paused")
    func expiredPause() {
        var config = AgentState()
        config.pause(until: date(2026, 3, 10, 9, 0))
        #expect(!config.isPaused(at: date(2026, 3, 10, 12, 0)))
    }

    // MARK: - Coding

    @Test("a state file predating pause decodes as not paused")
    func decodesWithoutPauseKey() throws {
        let json = #"{}"#
        let config = try JSONDecoder().decode(AgentState.self, from: Data(json.utf8))
        #expect(config.pausedUntil == nil)
    }

    /// Goes through `StateStore` itself rather than a hand-built coder. An
    /// earlier version of this test configured `.iso8601` strategies, which
    /// `JSONFileStore` does not use — so it proved nothing about the file the
    /// agent actually writes.
    @Test("a pause survives a round trip through the real store")
    func pauseRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("escapement-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StateStore(url: url)

        var state = AgentState()
        state.pause(until: date(2026, 3, 10, 14, 0))
        try store.save(state)

        #expect(try store.load().pausedUntil == state.pausedUntil)
    }

    /// The indefinite pause is a sentinel compared with `==`, so it has to come
    /// back from JSON bit-for-bit. It encodes as the integer 63113904000, which
    /// a Double represents exactly — but that is worth pinning, because if it
    /// ever drifted the UI would silently stop saying "Paused" and start
    /// promising to resume in the year 4001.
    @Test("an indefinite pause survives the store exactly")
    func indefinitePauseRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("escapement-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StateStore(url: url)

        var state = AgentState()
        state.pauseIndefinitely()
        try store.save(state)

        let loaded = try store.load()
        #expect(loaded.isPausedIndefinitely)
        #expect(loaded.isPaused(at: date(2099, 1, 1)))
    }

    @Test("a null pause decodes as not paused rather than failing")
    func nullPauseDecodes() throws {
        let json = #"{"pausedUntil":null}"#
        let config = try JSONDecoder().decode(AgentState.self, from: Data(json.utf8))
        #expect(config.pausedUntil == nil)
    }
}
