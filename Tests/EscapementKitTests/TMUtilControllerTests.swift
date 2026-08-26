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

/// The process-launching half of the controller, exercised against fake tools
/// rather than a live `tmutil`. These pin the bounding guarantees from
/// `docs/specs/018-tmutil-call-bounding.md`: a call never blocks a cooperative
/// thread, and it always finishes even when the child will not.
@Suite("TMUtilController process bounding")
struct TMUtilControllerProcessTests {

    /// A scratch directory for one test's fake tools. Callers remove it.
    private func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("escapement-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// An executable shell script standing in for `tmutil`.
    private func tool(_ body: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("faketool")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("returns the tool's standard output")
    func returnsStandardOutput() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = TMUtilController(toolURL: try tool("printf 'hello world'", in: directory))
        #expect(try await controller.run([]) == "hello world")
    }

    @Test("passes its arguments through")
    func passesArguments() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = TMUtilController(
            toolURL: try tool("printf '%s' \"$1-$2\"", in: directory))
        #expect(try await controller.run(["one", "two"]) == "one-two")
    }

    @Test("returns output a slow tool produces after a pause")
    func returnsLateOutput() async throws {
        // Guards the ordering in `finishIfReady`: resuming on exit alone, or on
        // EOF alone, would truncate this.
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = TMUtilController(
            toolURL: try tool("printf 'early'; sleep 0.3; printf '%s' '-late'", in: directory),
            timeout: 30)
        #expect(try await controller.run([]) == "early-late")
    }

    @Test("completes when the tool floods standard error")
    func drainsLargeStandardError() async throws {
        // 512 KiB of stderr, far past the pipe buffer. An undrained stderr
        // would block the tool's own write and wedge the call.
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = TMUtilController(
            toolURL: try tool(
                """
                i=0
                while [ $i -lt 512 ]; do
                  printf '%1024s' '' >&2
                  i=$((i+1))
                done
                printf 'done'
                """, in: directory),
            timeout: 30)
        #expect(try await controller.run([]) == "done")
    }

    @Test("fails a hanging tool rather than waiting on it")
    func timesOutOnHang() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = TMUtilController(
            toolURL: try tool("sleep 600", in: directory), timeout: 0.25)
        let start = ContinuousClock.now
        await #expect(throws: TMUtilController.ToolError.self) {
            _ = try await controller.run([])
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test("kills a child that ignores termination")
    func escalatesToKill() async throws {
        // The call fails as soon as the clock runs out, so its timing proves
        // nothing about escalation. What must be checked is the child: a tool
        // that discards SIGTERM has to be killed rather than left running.
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let controller = TMUtilController(
            toolURL: try tool(
                """
                echo $$ > "$1"
                trap '' TERM
                sleep 5
                """, in: directory),
            // A second, not a quarter of one: the whole suite runs in parallel,
            // and the child has to be scheduled and reach its first line before
            // the escalation is allowed to kill it, or the test proves nothing.
            timeout: 1)

        await #expect(throws: TMUtilController.ToolError.self) {
            _ = try await controller.run([pidFile.path])
        }

        // Polled, not read straight away: the call fails on its own clock, and
        // under a loaded machine the child may not have reached its first line
        // by then.
        let pid = try #require(await Self.eventually { pid_t(readPID(pidFile)) })
        let died = await Self.eventually { kill(pid, 0) != 0 ? true : nil } ?? false
        #expect(died, "a child that traps SIGTERM must still be killed")
    }

    private func readPID(_ url: URL) -> String {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Retries `probe` until it yields a value or the budget runs out.
    private static func eventually<T>(_ probe: () -> T?) async -> T? {
        for _ in 0..<100 {
            if let value = probe() { return value }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    // A hard limit, because the regression this pins is a deadlock: without it
    // a reintroduced bug hangs the whole suite instead of failing legibly.
    @Test("many simultaneous hangs all complete", .timeLimit(.minutes(1)))
    func concurrentHangsDoNotStarveTheCooperativePool() async throws {
        // The regression bar. The original defect blocked a cooperative-pool
        // thread per call, so once the count passed the pool's width nothing in
        // the process ever ran again. Four times the width must still resolve.
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = TMUtilController(
            toolURL: try tool("sleep 600", in: directory), timeout: 0.25)
        let count = ProcessInfo.processInfo.activeProcessorCount * 4
        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<count {
                group.addTask {
                    do {
                        _ = try await controller.run([])
                        return false
                    } catch {
                        return true
                    }
                }
            }
            var total = 0
            for await failed in group where failed { total += 1 }
            return total
        }
        #expect(failures == count)
    }

    @Test("surfaces a failure to launch the tool")
    func launchFailureThrows() async {
        let controller = TMUtilController(
            toolURL: URL(fileURLWithPath: "/nonexistent/tmutil"))
        await #expect(throws: TMUtilController.ToolError.self) {
            _ = try await controller.run([])
        }
    }
}

/// The error text reaches `history.json` and the user, and the dispatch
/// classification decides whether a run is closed as failed.
@Suite("TMUtilController errors")
struct TMUtilControllerErrorTests {

    @Test("describes a launch failure readably")
    func describesLaunchFailure() {
        let error = TMUtilController.ToolError.launchFailed(underlying: "no such file")
        #expect(String(describing: error) == "could not run tmutil: no such file")
    }

    @Test("describes a timeout readably")
    func describesTimeout() {
        let error = TMUtilController.ToolError.timedOut(arguments: ["status"])
        #expect(String(describing: error) == "tmutil stopped responding")
    }

    @Test("a launch failure dispatched nothing")
    func launchFailureIsFinal() {
        let error = TMUtilController.ToolError.launchFailed(underlying: "x")
        #expect(error.mayHaveDispatched == false)
    }

    @Test("a timeout may already have dispatched")
    func timeoutIsIndeterminate() {
        let error = TMUtilController.ToolError.timedOut(arguments: ["startbackup"])
        #expect(error.mayHaveDispatched == true)
    }
}
