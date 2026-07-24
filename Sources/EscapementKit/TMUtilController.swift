import Foundation

/// The production `TimeMachineControlling`, backed by the `tmutil` command and
/// the Time Machine preferences file.
///
/// Everything format-specific is delegated to `TimeMachineOutputParser`, which
/// is unit-tested against fixtures; this type is the thin, hard-to-test layer
/// that actually launches the process and reads the file.
public struct TMUtilController: TimeMachineControlling {

    public enum ToolError: Error, Sendable {
        case launchFailed(underlying: String)
    }

    private let toolURL: URL
    private let preferencesURL: URL

    /// - Parameters:
    ///   - toolURL: the `tmutil` binary. Injectable for tests.
    ///   - preferencesURL: the Time Machine preferences plist. Injectable so
    ///     manual-mode detection can be tested against a fixture without Full
    ///     Disk Access.
    public init(
        toolURL: URL = URL(fileURLWithPath: "/usr/bin/tmutil"),
        preferencesURL: URL = URL(
            fileURLWithPath: "/Library/Preferences/com.apple.TimeMachine.plist")
    ) {
        self.toolURL = toolURL
        self.preferencesURL = preferencesURL
    }

    // MARK: - TimeMachineControlling

    public func destinations() async throws -> [Destination] {
        let output = try run(["destinationinfo", "-X"])
        return try TimeMachineOutputParser.destinations(
            fromDestinationInfoPlist: Data(output.utf8))
    }

    public func activity() async throws -> BackupActivity {
        let output = try run(["status"])
        return try TimeMachineOutputParser.activity(fromStatusOutput: output)
    }

    public func startBackup(destinationID: String) async throws {
        // Plain start, never `--auto`: `--auto` submits to backupd's
        // elapsed-time throttle and would silently discard a cadence tighter
        // than the system interval.
        //
        // The exit *status* is deliberately ignored — `tmutil` exits zero even
        // when backupd refuses the work, so success is confirmed only by a
        // later `activity()`. But a failure to *launch* the tool (missing or
        // unexecutable binary) is a genuinely different problem and is allowed
        // to throw, so it is not silently indistinguishable from a dispatched
        // request.
        _ = try run(["startbackup", "--destination", destinationID])
    }

    public func stopBackup() async throws {
        _ = try run(["stopbackup"])
    }

    public func automaticBackupState() async -> AutomaticBackupState {
        // Reading the preferences file needs Full Disk Access, which Escapement
        // does not require; any failure resolves to `.unknown` rather than
        // propagating, so the caller is never blocked on a permission it was
        // never asked to grant.
        guard let data = try? Data(contentsOf: preferencesURL),
            let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = root as? [String: Any],
            let flag = (dict["AutoBackup"] as? NSNumber)?.boolValue
        else {
            return .unknown
        }
        return flag ? .automatic : .manual
    }

    // MARK: - Process

    /// Launches `tmutil` with the given arguments and returns its standard
    /// output. Standard error is discarded — but still drained.
    ///
    /// Both pipes are read concurrently: reading only stdout while `tmutil`
    /// fills its stderr buffer (a burst of warnings on a flaky network
    /// destination, say) past the OS pipe limit would block the tool's write
    /// and deadlock this call. Draining stderr on a separate queue removes that
    /// hazard regardless of how much either stream produces.
    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ToolError.launchFailed(underlying: String(describing: error))
        }

        // Drain stderr concurrently so a full stderr pipe cannot wedge the
        // stdout read below.
        let drainedError = DispatchGroup()
        drainedError.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            drainedError.leave()
        }

        // Bound the call: a `tmutil` that hangs (an unreachable network
        // destination, a wedged backupd) would otherwise block indefinitely,
        // and this runs on a cooperative-pool thread whose supply is limited.
        // Terminate a process that overstays; the pipe then closes and the read
        // below completes. tmutil's own operations are normally sub-second, so
        // the ceiling only ever fires on a genuine hang.
        let timeoutItem = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.timeout, execute: timeoutItem)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        drainedError.wait()
        process.waitUntilExit()
        timeoutItem.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    /// Ceiling on any single `tmutil` invocation.
    private static let timeout: TimeInterval = 30
}
