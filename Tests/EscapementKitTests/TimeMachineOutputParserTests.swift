import Foundation
import Testing

@testable import EscapementKit

private func fixture(_ resource: String, _ ext: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: resource, withExtension: ext, subdirectory: "Fixtures"),
        "missing fixture \(resource).\(ext)")
    return try Data(contentsOf: url)
}

private func fixtureString(_ resource: String, _ ext: String) throws -> String {
    String(decoding: try fixture(resource, ext), as: UTF8.self)
}

@Suite("Destination parsing")
struct DestinationParsingTests {

    @Test("parses a local and a network destination from destinationinfo -X")
    func twoDestinations() throws {
        let data = try fixture("destinationinfo-two-destinations", "plist")
        let destinations = try TimeMachineOutputParser.destinations(fromDestinationInfoPlist: data)

        #expect(destinations.count == 2)

        let network = try #require(destinations.first { $0.name == "Example Network Backup" })
        #expect(network.id == "11111111-1111-1111-1111-111111111111")
        #expect(network.kind == .network(url: "smb://user@example._smb._tcp.local./Backup"))
        #expect(network.isLastUsed == true)

        let local = try #require(destinations.first { $0.name == "Example Local Backup" })
        #expect(local.id == "22222222-2222-2222-2222-222222222222")
        #expect(local.kind == .local)
        #expect(local.isLastUsed == false)
    }

    @Test("returns an empty array when no destination is configured")
    func noDestinations() throws {
        let data = try fixture("destinationinfo-none", "plist")
        let destinations = try TimeMachineOutputParser.destinations(fromDestinationInfoPlist: data)
        #expect(destinations.isEmpty)
    }

    @Test("rejects data that is not a property list")
    func garbageInput() {
        #expect(throws: (any Error).self) {
            try TimeMachineOutputParser.destinations(
                fromDestinationInfoPlist: Data("not a plist".utf8))
        }
    }

    @Test("skips a destination entry with no ID rather than inventing one")
    func entryWithoutID() throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>Destinations</key><array>
            <dict><key>Name</key><string>Nameless</string><key>Kind</key><string>Local</string></dict>
            <dict><key>ID</key><string>KEEP</string><key>Name</key><string>Good</string><key>Kind</key><string>Local</string></dict>
            </array></dict></plist>
            """
        let destinations = try TimeMachineOutputParser.destinations(
            fromDestinationInfoPlist: Data(plist.utf8))
        #expect(destinations.map(\.id) == ["KEEP"])
    }
}

@Suite("Status parsing")
struct StatusParsingTests {

    @Test("idle when no backup is running")
    func idle() throws {
        let activity = try TimeMachineOutputParser.activity(
            fromStatusOutput: try fixtureString("status-idle", "txt"))
        #expect(activity == .idle)
    }

    @Test("running with indeterminate progress while mounting")
    func mounting() throws {
        let activity = try TimeMachineOutputParser.activity(
            fromStatusOutput: try fixtureString("status-mounting", "txt"))
        #expect(
            activity
                == .running(
                    destinationID: "11111111-1111-1111-1111-111111111111",
                    phase: .mountingDiskImage, progress: nil))
    }

    @Test("running with a real progress fraction while copying")
    func copying() throws {
        let activity = try TimeMachineOutputParser.activity(
            fromStatusOutput: try fixtureString("status-copying", "txt"))
        guard case .running(let id, let phase, let parsedProgress) = activity else {
            Issue.record("expected .running, got \(activity)")
            return
        }
        #expect(id == "22222222-2222-2222-2222-222222222222")
        #expect(phase == .copying)
        let progress = try #require(parsedProgress)
        #expect(progress.fractionCompleted == 0.25)
        #expect(progress.bytesCopied == 250_000_000_000)
        #expect(progress.totalBytes == 1_000_000_000_000)
        #expect(progress.filesCopied == 250)
        #expect(progress.totalFiles == 1_000)
        #expect(progress.timeRemaining == 432_000)
    }

    @Test("the Stopping phase is its own state, not running")
    func stopping() throws {
        let activity = try TimeMachineOutputParser.activity(
            fromStatusOutput: try fixtureString("status-stopping", "txt"))
        #expect(
            activity
                == .stopping(destinationID: "11111111-1111-1111-1111-111111111111"))
    }

    @Test("a Percent of -1 is indeterminate, never zero")
    func negativePercentIsNil() throws {
        // Guards the specific rendering bug the spec calls out: -1 must not
        // surface as 0%.
        let activity = try TimeMachineOutputParser.activity(
            fromStatusOutput: try fixtureString("status-mounting", "txt"))
        guard case .running(_, _, let progress) = activity else {
            Issue.record("expected .running")
            return
        }
        #expect(progress == nil)
    }

    @Test("an unrecognised phase is preserved verbatim")
    func unknownPhase() throws {
        let output = """
            Backup session status:
            {
                BackupPhase = SomeFuturePhase;
                DestinationID = "ABC";
                Percent = "-1";
                Running = 1;
            }
            """
        let activity = try TimeMachineOutputParser.activity(fromStatusOutput: output)
        #expect(activity == .running(destinationID: "ABC", phase: .other("SomeFuturePhase"), progress: nil))
    }

    @Test("a running backup with no phase yet reads as preparing, not blank")
    func missingPhaseIsPreparing() throws {
        let output = """
            Backup session status:
            { DestinationID = "ABC"; Percent = "-1"; Running = 1; }
            """
        let activity = try TimeMachineOutputParser.activity(fromStatusOutput: output)
        #expect(activity == .running(destinationID: "ABC", phase: .preparing, progress: nil))
    }

    @Test("progress is clamped into 0...1")
    func progressClamped() throws {
        let output = """
            Backup session status:
            { BackupPhase = Copying; DestinationID = "ABC"; Percent = "1.5"; Running = 1; }
            """
        let activity = try TimeMachineOutputParser.activity(fromStatusOutput: output)
        guard case .running(_, _, let progress) = activity else {
            Issue.record("expected .running")
            return
        }
        #expect(progress?.fractionCompleted == 1.0)
    }

    @Test("an invalid nested fraction falls back to a valid legacy fraction")
    func invalidNestedFractionFallsBack() throws {
        let output = """
            Backup session status:
            {
                BackupPhase = Copying;
                DestinationID = "ABC";
                Percent = "0.25";
                Progress = {
                    Percent = nan;
                    TimeRemaining = "-1";
                    bytes = "-20";
                    files = nope;
                };
                Running = 1;
            }
            """
        let activity = try TimeMachineOutputParser.activity(fromStatusOutput: output)
        guard case .running(_, _, let progress) = activity else {
            Issue.record("expected .running")
            return
        }
        #expect(progress?.fractionCompleted == 0.25)
        #expect(progress?.bytesCopied == nil)
        #expect(progress?.filesCopied == nil)
        #expect(progress?.timeRemaining == nil)
    }

    @Test("a valid nested fraction takes precedence over the legacy top-level value")
    func nestedFractionTakesPrecedence() throws {
        let output = """
            Backup session status:
            {
                BackupPhase = Copying;
                DestinationID = "ABC";
                Percent = "0.9";
                Progress = { Percent = "0.2"; };
                Running = 1;
            }
            """
        let activity = try TimeMachineOutputParser.activity(fromStatusOutput: output)
        guard case .running(_, _, let progress) = activity else {
            Issue.record("expected .running")
            return
        }
        #expect(progress?.fractionCompleted == 0.2)
    }

    @Test("a wholly invalid nested progress dictionary is indeterminate")
    func invalidNestedProgressIsNil() throws {
        let output = """
            Backup session status:
            {
                BackupPhase = Copying;
                DestinationID = "ABC";
                Progress = {
                    Percent = "-1";
                    TimeRemaining = infinity;
                    bytes = "-20";
                    totalBytes = nope;
                    files = "-1";
                    totalFiles = nope;
                };
                Running = 1;
            }
            """
        let activity = try TimeMachineOutputParser.activity(fromStatusOutput: output)
        #expect(
            activity
                == .running(destinationID: "ABC", phase: .copying, progress: nil))
    }

    @Test("output without a dictionary is rejected")
    func noDictionary() {
        #expect(throws: (any Error).self) {
            try TimeMachineOutputParser.activity(fromStatusOutput: "totally unexpected")
        }
    }
}
