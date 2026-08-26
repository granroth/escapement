# 018 — Bounding `tmutil` calls

Status: implemented

## The failure this fixes

A running agent stopped scheduling backups for four days while continuing to
look healthy: the process was alive, the menu bar icon was present, and the
menu still opened and drew. Only the contents were frozen — the menu reported a
"last backup" from before the freeze, and `history.json` and `state.json` had
not been written since.

Sampling the live process found nine of its eleven threads parked in
`TMUtilController.run(_:)`, every one of them in `drainedError.wait()`. None
were in the standard-output read, and the process had no surviving child
processes at all: every `tmutil` had exited, yet nine calls were still waiting.

## Why it deadlocked

Three separate defects compounded. Any one alone is survivable; together they
are terminal.

**`run(_:)` was synchronous and blocking, but every caller was `async`.**
`TMUtilController` is not actor-isolated, so `await control.activity()` leaves
the main actor and runs on Swift's cooperative thread pool. Blocking there
consumes a pool thread for the whole call. The pool's width is the active
processor count, so a handful of simultaneous hangs exhausts it and every
remaining `async` operation in the process — including the scheduler — stops
running forever.

**The mitigation was dispatched onto the resource it was protecting.** Both the
stderr drain and the timeout that was supposed to bound the call were submitted
to `DispatchQueue.global(qos: .utility)`. Once the shared worker pool was
saturated by blocked threads, neither could be scheduled. The drain block never
ran, so `drainedError.leave()` was never called, so `drainedError.wait()` never
returned — even though the child had already exited and the pipe was at EOF.
The 30-second ceiling could not fire for exactly the reason it existed.

**Ticks had no re-entrancy guard.** The support-directory watcher starts a
`tick()` on every file-system event, and the agent writes `history.json` and
`state.json` into that same directory, so it triggers its own watcher. With
each tick blocking a pool thread, a single hung `tmutil` multiplied into nine.

## Requirements

1. A `tmutil` invocation must never block a cooperative-pool thread. `run(_:)`
   is `async` and suspends rather than waits; no thread is held for the
   duration of the call.
2. A `tmutil` invocation must always complete within a bounded time, whatever
   the child does — including ignoring `SIGTERM`. It reports `.timedOut` rather
   than hanging, and rather than returning the truncated output it happened to
   have collected.
3. Nothing that delivers completion may be scheduled on a shared global queue.
   Pipe draining, termination, and the timeout all run on a private queue whose
   thread supply is independent of the cooperative pool.
4. Both output streams are still drained concurrently, so a tool that fills its
   stderr buffer cannot wedge the stdout read.
5. Concurrent calls in excess of the cooperative pool's width all complete.
   This is the regression bar for the original defect.
6. A timed-out `startbackup` must not be recorded as a failed run. It is not
   known to have failed.
7. At most one `tick()` runs at a time. Requests that arrive during a tick
   coalesce into exactly one follow-up tick rather than stacking.

## Design

`run(_:)` is `async`, built on `withCheckedThrowingContinuation`. All
completion state lives in a single box mutated only on a private serial queue,
so there are no locks and no data races, and the continuation is resumed
exactly once.

Completion is event-driven: a read source per pipe accumulates output and
detects EOF, `terminationHandler` records the exit, and the call resumes once
the child has exited *and* both pipes have closed. Waiting on the pipes as well
as the exit is what stops a fast tool from returning truncated output. No step
waits on a thread.

The pipes are read through `DispatchSource` read sources and `read(2)` rather
than `FileHandle.readabilityHandler` and `availableData`. That pairing cannot
express the difference between end-of-file and "nothing to read right now" —
both surface as empty `Data` — so a tool that pauses mid-stream is mistaken for
one that has finished and the rest of its output is silently dropped. `read`
reports the two as `0` and `-1`/`EAGAIN`.

### The bound

Two stages, on the same private queue:

- At `timeout`: send `SIGTERM`, stop reading, and **fail the call immediately**
  with `.timedOut`. The call does not wait to find out whether the child can
  actually be killed — a `tmutil` blocked in an uninterruptible wait on a dead
  network mount cannot be signalled at all, and the scheduler must not be held
  hostage to that.
- At `timeout + grace`: send `SIGKILL` if the child is still running. This is
  best-effort reaping only; the call has already returned, and this stage never
  touches the continuation.

`grace` is derived from the timeout (`max(0.25, timeout / 6)`) so a test can
drive the whole ladder in a fraction of a second while production keeps five
seconds between asking and insisting. The timeout itself is injectable for the
same reason.

Both stages are held as `DispatchWorkItem`s so a call that finishes normally can
cancel them. Cancellation alone is not enough to release the child, though:
`DispatchWorkItem.cancel()` suppresses the body but does not release what the
body captured until the original deadline passes. The `Process` is therefore
held in the state box and cleared on completion, rather than captured by the
stages — otherwise every call would pin its child and both pipes, descriptors
included, for the whole timeout window after it had already returned, and the
agent runs `tmutil status` on every tick.

**Known limit:** `SIGKILL` is sent to the child alone. Foundation's `Process`
offers no way to place the child in its own process group, so anything the child
forked is not reached. `tmutil` talks to `backupd` over XPC and does not fork,
so this does not arise against the real tool.

### A timeout is not a failure to start

`startbackup` hands work to `backupd` and returns; the two are not the same
event. A call that times out may well have dispatched the request already, and
killing the CLI does not recall a request `backupd` has accepted.

`PossiblyDispatchedError` marks that distinction. `SchedulerRunner.start()`
closes a run immediately only for an error that is known to have dispatched
nothing — a failure to launch the tool. For an indeterminate one it leaves the
run open and lets the ordinary observation path settle it: `closeFinished`
gives the backup `startupGrace` to appear in `tmutil status`, then closes it as
"backup did not start" only if it genuinely never did.

Recording a failure at the point of the timeout instead would both lie about a
backup that is running and strand it, to be re-adopted afterwards as a second,
external-looking record for the same physical backup.

### Coalescing

`TickCoalescer` runs one evaluation at a time; anything asked for while one is
in flight collapses into a single follow-up. It lives in `EscapementKit` rather
than the agent so the interleaving can be tested — the agent target is an
executable and cannot be imported by the test suite.

The follow-up re-runs the body from the original call. Every caller asks for the
same evaluation, and the point of a request is that one happens soon, not that a
particular closure runs.

## Not in scope

The exit *status* of `tmutil` remains ignored. It carries no information — the
tool exits zero even when backupd declines the work — and outcomes are still
inferred from `tmutil status` across ticks. A launch failure still throws, and
is still a different thing from a refused backup.
