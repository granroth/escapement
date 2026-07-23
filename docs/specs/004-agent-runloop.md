# Spec 004 — The scheduler run loop

Status: implemented

## Purpose

Tie the pure `Scheduler`, the stores, and a `TimeMachineControlling` into a
loop that actually starts backups at the right time and records what happened.
The pure decision is spec 003; this is the stateful coordinator that calls it.

## Shape

    actor SchedulerRunner {
        init(
            control: any TimeMachineControlling,
            configuration: ConfigurationStore,
            history: HistoryStore,
            scheduler: Scheduler,
            now: @Sendable () -> Date)

        func evaluate() async        // the tick
        func backUpNow(destinationID: String) async
        func nextWakeUp() async -> Date?
    }

An `actor` because it is shared state — timer callbacks, UI actions, and
activity polling all reach it — and it must never evaluate twice concurrently.
The clock is injected as a closure so the loop is testable without waiting.

The `Timer` itself lives in the app, not here: the runner exposes `evaluate()`
and `nextWakeUp()`, and the app arms an `NSTimer`/`DispatchSourceTimer` for the
returned instant, re-arming after each tick. This keeps the runner free of any
particular timer API and testable by calling `evaluate()` directly.

## What `evaluate()` does

1. Read activity, configuration, and the last-completed-run map.
2. Reconcile history: if a run recorded `.running` is no longer reflected by a
   live backup, close it out (see "Closing out runs").
3. Ask the `Scheduler` for a decision.
4. On `.start(id)`: append a `.running` history record with the right trigger,
   then call `control.startBackup`. Remember the started run's id so the next
   evaluations can close it out.
5. Always compute `nextWakeUp` for the caller to re-arm the timer.

Determining the trigger: a start whose due occurrence is older than a small
grace period (the machine was plainly asleep for it) is `.missed`; otherwise
`.scheduled`. `backUpNow` records `.manual`.

**Retry cooldown.** A failed attempt does not advance the last-completed
reference — the backup still needs to happen — so the destination stays due and
would be restarted on the very next evaluation. A per-destination in-memory
cooldown turns that into an occasional retry rather than a tight storm against
an unreachable disk. A manual `backUpNow` bypasses the cooldown. The cooldown
is in memory only; a stale attempt from before a restart should not suppress a
fresh one. (Exponential backoff is a reasonable later refinement; a flat
cooldown is enough to be safe.)

**Actor reentrancy.** An `await` inside `evaluate` would otherwise let a second
`evaluate` interleave at the suspension point and double-start. A busy flag
makes overlapping calls no-ops; a skipped tick re-fires soon enough.

## Closing out runs

`startBackup` is fire-and-forget and `tmutil`'s exit code is meaningless, so
the runner infers outcomes by watching `activity()` across ticks:

- A `.running` record whose backup is observed running stays `.running`.
- When activity returns to `.idle` (or moves to a different destination) while a
  record is still open, the record is closed. Success versus failure is
  distinguished by whether `latestbackup` for that destination advanced past
  the record's `startedAt`; absent that signal, a backup that ran for more than
  a trivial duration is recorded `.completed`, and one that never got going
  `.failed`. This is best-effort by design — the platform gives no authoritative
  per-run result — and the spec says so plainly rather than pretending to
  certainty.
- A record open across a launch (the app or agent was killed mid-backup) is
  closed on the next evaluation using the same rules, so a crash cannot strand a
  run in `.running` forever.

## Concurrency and the shared files

Per spec 003 the agent is the sole writer of history; the app only reads it.
The app may write configuration while the runner reads it — both tolerate this
because each read is a whole-file load and each write is atomic, so a reader
sees either the old or the new file, never a torn one. The runner re-reads
configuration every tick rather than caching, so a schedule change takes effect
on the next evaluation without any change-notification plumbing.

## Out of scope

The timer, wake-from-sleep observation, and file-change observation are the
app/agent's platform glue (spec 005). The runner is driven entirely by
`evaluate()` calls.
