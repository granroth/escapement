import Foundation
import Testing

@testable import EscapementKit

@Suite("AgentCommand coding")
struct AgentCommandCodingTests {
    private func roundTrip(_ command: AgentCommand) throws -> AgentCommand {
        let data = try JSONEncoder().encode(command)
        return try JSONDecoder().decode(AgentCommand.self, from: data)
    }

    @Test("backUpNow round-trips with its destination")
    func backUpNow() throws {
        #expect(try roundTrip(.backUpNow(destinationID: "ABC")) == .backUpNow(destinationID: "ABC"))
    }

    @Test("stop round-trips")
    func stop() throws {
        #expect(try roundTrip(.stop) == .stop)
    }
}

@Suite("CommandStore")
struct CommandStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("escapement-cmd-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("command.json")
    }

    @Test("take returns nil when no command is posted")
    func emptyIsNil() throws {
        let store = CommandStore(url: tempURL())
        #expect(try store.take() == nil)
    }

    @Test("a posted command is taken exactly once")
    func postThenTakeOnce() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = CommandStore(url: url)
        try store.post(.backUpNow(destinationID: "D1"))
        #expect(try store.take() == .backUpNow(destinationID: "D1"))
        // Consumed: the file is gone, so a second take yields nil.
        #expect(try store.take() == nil)
    }

    @Test("posting again replaces the pending command")
    func postReplaces() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = CommandStore(url: url)
        try store.post(.backUpNow(destinationID: "D1"))
        try store.post(.stop)
        #expect(try store.take() == .stop)
        #expect(try store.take() == nil)
    }

    @Test("clear discards a pending command")
    func clearDiscards() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = CommandStore(url: url)
        try store.post(.stop)
        store.clear()
        #expect(try store.take() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("clear on an empty store is harmless")
    func clearEmpty() {
        CommandStore(url: tempURL()).clear()
    }

    @Test("a corrupt command file is taken as nil and cleared, not thrown")
    func corruptClears() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = CommandStore(url: url)
        // A malformed command must not wedge the agent: it is discarded.
        #expect(try store.take() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
