import Foundation
import Testing

@testable import EscapementKit

/// Only the file-reading path is unit-tested here: the process-launching paths
/// need a live `tmutil` and are exercised by the parser tests plus a manual
/// smoke test. Manual-mode detection, by contrast, is pure file reading and is
/// pinned against fixtures.
@Suite("TMUtilController manual-mode detection")
struct TMUtilControllerTests {

    private func fixtureURL(_ resource: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: resource, withExtension: "plist", subdirectory: "Fixtures"))
    }

    private func controller(preferences resource: String) throws -> TMUtilController {
        TMUtilController(preferencesURL: try fixtureURL(resource))
    }

    @Test("reports automatic when AutoBackup is set")
    func automatic() async throws {
        let controller = try controller(preferences: "timemachine-prefs-auto-on")
        #expect(await controller.automaticBackupState() == .automatic)
    }

    @Test("reports manual when AutoBackup is cleared")
    func manual() async throws {
        let controller = try controller(preferences: "timemachine-prefs-auto-off")
        #expect(await controller.automaticBackupState() == .manual)
    }

    @Test("reports unknown when the preferences file cannot be read")
    func unknownWhenUnreadable() async {
        let controller = TMUtilController(
            preferencesURL: URL(fileURLWithPath: "/nonexistent/does-not-exist.plist"))
        let state = await controller.automaticBackupState()
        #expect(state == .unknown)
    }

    @Test("reports unknown when the file exists but lacks the flag")
    func unknownWhenFlagAbsent() async throws {
        // destinationinfo-none is a valid plist without an AutoBackup key.
        let url = try #require(
            Bundle.module.url(
                forResource: "destinationinfo-none", withExtension: "plist", subdirectory: "Fixtures"))
        let state = await TMUtilController(preferencesURL: url).automaticBackupState()
        #expect(state == .unknown)
    }

    @Test("startBackup surfaces a failure to launch the tool")
    func startBackupThrowsOnLaunchFailure() async {
        // A missing binary is a different problem from backupd declining the
        // work, and must not be swallowed into a silent no-op.
        let controller = TMUtilController(
            toolURL: URL(fileURLWithPath: "/nonexistent/tmutil"))
        await #expect(throws: (any Error).self) {
            try await controller.startBackup(destinationID: "ABC")
        }
    }
}
