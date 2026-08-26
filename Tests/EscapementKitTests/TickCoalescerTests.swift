import Testing

@testable import EscapementKit

/// Pins the interleaving the agent's tick guard depends on: a request arriving
/// mid-pass must neither be lost nor stack into a second concurrent pass.
@Suite("Tick coalescing")
@MainActor
struct TickCoalescerTests {

    @Test("runs each request when nothing is in flight")
    func runsSequentialRequests() async {
        let coalescer = TickCoalescer()
        var passes = 0
        for _ in 0..<3 { await coalescer.run { passes += 1 } }
        #expect(passes == 3)
    }

    @Test("a request arriving mid-pass produces exactly one follow-up")
    func oneFollowUp() async {
        let coalescer = TickCoalescer()
        var passes = 0
        await coalescer.run {
            passes += 1
            // Stands in for the support-directory watcher firing on a write the
            // pass itself just made.
            if passes == 1 { await coalescer.run { passes += 1_000 } }
        }
        // Two passes, and the follow-up re-ran the original body rather than
        // the requester's — the 1_000 must not appear.
        #expect(passes == 2)
    }

    @Test("many requests mid-pass collapse into a single follow-up")
    func collapsesManyRequests() async {
        let coalescer = TickCoalescer()
        var passes = 0
        await coalescer.run {
            passes += 1
            if passes == 1 {
                for _ in 0..<5 { await coalescer.run {} }
            }
        }
        #expect(passes == 2)
    }

    @Test("a pass that requests nothing does not repeat")
    func settles() async {
        let coalescer = TickCoalescer()
        var passes = 0
        await coalescer.run { passes += 1 }
        #expect(passes == 1)
    }
}
