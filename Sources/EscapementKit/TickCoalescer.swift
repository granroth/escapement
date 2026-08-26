import Foundation

/// Runs an operation one at a time, collapsing everything asked for while it
/// runs into a single follow-up.
///
/// The agent's evaluation is triggered from several directions at once — a
/// timer, a wake notification, menu actions, and a watch on the support
/// directory that the agent itself writes into, so it re-triggers itself.
/// Without coalescing, one slow `tmutil` call becomes as many concurrent
/// stalled evaluations as those sources can fire between them; that is what
/// turned a single hung call into a permanently wedged agent
/// (`docs/specs/018-tmutil-call-bounding.md`).
///
/// Lives here rather than in the agent so the interleaving can be tested: the
/// agent target is an executable and cannot be imported by the test suite.
@MainActor
public final class TickCoalescer {

    private var isRunning = false
    private var requested = false

    public init() {}

    /// Runs `body`, or — if a pass is already in flight — records that another
    /// is wanted and returns immediately.
    ///
    /// Any number of requests arriving during a pass collapse into exactly one
    /// follow-up. The follow-up re-runs the body given to the *original* call,
    /// which is what the agent wants: every caller asks for the same
    /// evaluation, and the point of the request is that one happens soon, not
    /// that this particular closure does.
    public func run(_ body: () async -> Void) async {
        guard !isRunning else {
            requested = true
            return
        }
        isRunning = true
        defer { isRunning = false }
        repeat {
            requested = false
            await body()
        } while requested
    }
}
