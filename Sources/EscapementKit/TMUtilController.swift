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
        /// The tool did not finish within its bound and was abandoned. Callers
        /// treat this like any other failure; the point is that it *arrives*.
        case timedOut(arguments: [String])
    }

    private let toolURL: URL
    private let preferencesURL: URL
    private let timeout: TimeInterval

    /// - Parameters:
    ///   - toolURL: the `tmutil` binary. Injectable for tests.
    ///   - preferencesURL: the Time Machine preferences plist. Injectable so
    ///     manual-mode detection can be tested against a fixture without Full
    ///     Disk Access.
    ///   - timeout: ceiling on a single invocation. Injectable so the bound
    ///     itself can be tested in milliseconds rather than the production
    ///     thirty seconds.
    public init(
        toolURL: URL = URL(fileURLWithPath: "/usr/bin/tmutil"),
        preferencesURL: URL = URL(
            fileURLWithPath: "/Library/Preferences/com.apple.TimeMachine.plist"),
        timeout: TimeInterval = 30
    ) {
        self.toolURL = toolURL
        self.preferencesURL = preferencesURL
        self.timeout = timeout
    }

    // MARK: - TimeMachineControlling

    public func destinations() async throws -> [Destination] {
        let output = try await run(["destinationinfo", "-X"])
        return try TimeMachineOutputParser.destinations(
            fromDestinationInfoPlist: Data(output.utf8))
    }

    public func activity() async throws -> BackupActivity {
        let output = try await run(["status"])
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
        _ = try await run(["startbackup", "--destination", destinationID])
    }

    public func stopBackup() async throws {
        _ = try await run(["stopbackup"])
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
    /// This suspends; it never blocks. An earlier version waited synchronously
    /// on a dispatch group, which held a cooperative-pool thread for the whole
    /// call — a handful of simultaneous hangs exhausted the pool and stopped
    /// every `async` operation in the process permanently. Nothing here waits
    /// on a thread: the pipes, the exit, and the timeout are all events, and
    /// the call resumes when they line up.
    ///
    /// Both pipes are drained. Reading only stdout while `tmutil` fills its
    /// stderr buffer (a burst of warnings on a flaky network destination, say)
    /// past the OS pipe limit would block the tool's write and stall the call.
    ///
    /// Internal rather than private so the bounding guarantees can be tested
    /// directly against fake tools.
    func run(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let queue = Self.callbacks
        let state = CallState()
        let timeout = self.timeout
        let grace = killGrace

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                state.continuation = continuation
                state.process = process

                state.sources = [
                    Self.drain(output, into: state, on: queue, keeping: true),
                    Self.drain(errors, into: state, on: queue, keeping: false),
                ]

                process.terminationHandler = { _ in
                    queue.async {
                        state.exited = true
                        state.finishIfReady()
                    }
                }

                do {
                    try process.run()
                } catch {
                    Self.detach(state)
                    state.fail(.launchFailed(underlying: String(describing: error)))
                    return
                }

                // Bound the call unconditionally. On expiry the call fails
                // immediately rather than waiting to see whether the child can
                // be killed: `tmutil` blocked in an uninterruptible wait on a
                // dead network mount cannot be signalled at all, and the
                // scheduler must not be held hostage to that. Reaping the child
                // is a separate, best-effort concern handled below.
                //
                // Failing is also the only honest answer. Returning whatever
                // had been read when the clock ran out would hand the caller a
                // truncated — usually empty — reading of `tmutil status` that
                // is indistinguishable from a real one.
                let expire = DispatchWorkItem {
                    guard !state.finished, let process = state.process else { return }
                    state.expired = true
                    process.terminate()
                    Self.detach(state)
                    state.fail(.timedOut(arguments: arguments))
                }
                // Insist, for a child that trapped SIGTERM. This only reaps the
                // child; the call has already failed above, so nothing here
                // touches the continuation. A child that has already exited is
                // not running and this does nothing.
                let escalate = DispatchWorkItem {
                    if state.expired, let process = state.process, process.isRunning {
                        // Only the child itself. Foundation's `Process` gives no
                        // way to put it in its own process group, so anything it
                        // forked is not reached; `tmutil` talks to `backupd` over
                        // XPC and does not fork, so this is the whole job in
                        // practice. Noted in the spec as a known limit.
                        kill(process.processIdentifier, SIGKILL)
                    }
                    state.process = nil
                    state.pending = []
                }
                // Held so a call that finishes normally can cancel them.
                state.pending = [expire, escalate]
                queue.asyncAfter(deadline: .now() + timeout, execute: expire)
                queue.asyncAfter(deadline: .now() + timeout + grace, execute: escalate)
            }
        }
    }

    /// Serialises every completion callback: pipe reads, termination, and the
    /// timeout stages. A private queue, deliberately — dispatch brings up a
    /// thread for one of these even when the shared worker pool is fully
    /// occupied, which is the exact condition the previous implementation died
    /// in when it dispatched its own rescue onto `DispatchQueue.global`.
    private static let callbacks = DispatchQueue(
        label: "com.granroth.Escapement.tmutil", qos: .utility)

    /// Gap between escalation stages. Derived from the timeout so a test can
    /// drive the whole ladder in a fraction of a second while production keeps
    /// a five-second pause between asking and insisting.
    private var killGrace: TimeInterval { max(0.25, timeout / 6) }

    /// Accumulates one pipe until EOF. `keeping` distinguishes the stream whose
    /// bytes are the result from the one that is drained only so the tool
    /// cannot block writing to it.
    ///
    /// Reads the descriptor directly rather than going through
    /// `FileHandle.readabilityHandler` plus `availableData`. That pairing
    /// cannot express the difference between end-of-file and "nothing to read
    /// right now": both surface as empty `Data`, so a tool that pauses
    /// mid-stream — `tmutil` waiting on a slow network destination between two
    /// writes — is mistaken for one that has finished, and its remaining output
    /// is silently dropped. `read` reports the two as `0` and `-1`/`EAGAIN`,
    /// which is the distinction this depends on.
    private static func drain(
        _ pipe: Pipe, into state: CallState, on queue: DispatchQueue, keeping: Bool
    ) -> DispatchSourceRead {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [pipe] in
            // `pipe` is captured to keep the descriptor open: the handle closes
            // it when it deallocates, and nothing else here holds a reference.
            withExtendedLifetime(pipe) {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = buffer.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress, $0.count)
                }
                let err = errno
                if count > 0 {
                    if keeping { state.output.append(contentsOf: buffer[0..<count]) }
                } else if count == 0 {
                    source.cancel()
                } else if err != EAGAIN && err != EINTR {
                    source.cancel()
                }
            }
        }
        source.setCancelHandler {
            if keeping { state.outputOpen = false } else { state.errorsOpen = false }
            state.finishIfReady()
        }
        source.resume()
        return source
    }

    /// Stops reading. Used when giving up on a child that will not die, so the
    /// sources do not outlive the call.
    private static func detach(_ state: CallState) {
        for source in state.sources { source.cancel() }
        state.sources = []
    }

    /// Completion state for a single invocation. Every member is touched only
    /// on `callbacks`, which is what makes the unchecked conformance sound and
    /// guarantees the continuation is resumed exactly once.
    private final class CallState: @unchecked Sendable {
        var continuation: CheckedContinuation<String, any Error>?
        var output = Data()
        var outputOpen = true
        var errorsOpen = true
        var exited = false
        /// Set when the timeout fired, so the escalation stage knows the child
        /// is unwanted rather than merely slow.
        var expired = false
        /// The escalation stages still scheduled, so normal completion can
        /// cancel them and stop pinning the process and its pipes.
        var pending: [DispatchWorkItem] = []
        /// The two pipe readers, held so they stay alive for the call and can
        /// be cancelled when it is abandoned.
        var sources: [DispatchSourceRead] = []
        /// The child. Held here rather than captured by the escalation stages:
        /// cancelling a `DispatchWorkItem` suppresses its body but does not
        /// release what the body captured until its deadline passes, so a stage
        /// capturing the process directly would pin it — and the pipes — for the
        /// whole timeout window after the call had already returned.
        var process: Process?

        var finished: Bool { continuation == nil }

        /// Resumes once the child has exited *and* both pipes have closed.
        /// Waiting for the pipes as well as the exit is what stops a fast
        /// `tmutil` from returning truncated output.
        func finishIfReady() {
            guard exited, !outputOpen, !errorsOpen, let continuation else { return }
            self.continuation = nil
            cancelPending()
            // Dropping these is what actually frees the child and its
            // descriptors; cancelling the stages alone would not.
            sources = []
            process = nil
            continuation.resume(returning: String(decoding: output, as: UTF8.self))
        }

        /// Drops the escalation stages. Only ever called on the normal path —
        /// an expired call deliberately leaves its SIGKILL stage armed, since
        /// that is the thing still trying to reap the child.
        func cancelPending() {
            for item in pending { item.cancel() }
            pending = []
        }

        func fail(_ error: ToolError) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: error)
        }
    }
}

extension TMUtilController.ToolError: CustomStringConvertible {

    /// A `startbackup` that fails is recorded in history and shown to the user,
    /// and `String(describing:)` on a bare enum case is not something to put in
    /// front of anyone.
    public var description: String {
        switch self {
        case .launchFailed(let underlying):
            "could not run tmutil: \(underlying)"
        case .timedOut:
            "tmutil stopped responding"
        }
    }
}

extension TMUtilController.ToolError: PossiblyDispatchedError {

    public var mayHaveDispatched: Bool {
        switch self {
        // `Process.run()` itself failed: nothing ever reached `backupd`.
        case .launchFailed: false
        // The tool stopped answering. It may well have dispatched the work
        // before it did, and killing the CLI does not recall a request
        // `backupd` has already accepted.
        case .timedOut: true
        }
    }
}
