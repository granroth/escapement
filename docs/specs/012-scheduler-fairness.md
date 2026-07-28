# Spec 012 — Scheduler fairness and stall recovery

Status: proposed

## Problem

Time Machine runs one backup at a time. `tmutil`'s own man page says so —
`startbackup` will "begin a backup if one is not already running" — and
`tmutil status` has no shape to report a second session. Rule 1 of spec 003
models that constraint correctly.

What spec 003 does not model is the *policy* that has to sit on top of a single
shared slot. macOS's built-in scheduler cycles between destinations (the
`--rotation` flag on `startbackup` is the visible edge of it). Escapement
replaced that scheduler and inherited the constraint without inheriting the
fairness, so one destination can hold the slot indefinitely and every other
schedule silently stops firing.

Observed on real hardware over four days:

- An hourly schedule on a local disk started a backup that wedged in `Copying`
  at a fixed file count and never moved another byte.
- `reconcileOpenRuns` only closes a run whose backup is no longer live. A run
  that is alive and catatonic is never closed, so the slot was never released.
- A daily 03:00 schedule on a second destination came due four times and was
  refused every time by rule 1.
- `lastCompletedRuns` advances a destination's reference only on `.completed`.
  The wedged destination had never completed a run, so its reference stayed
  pinned at `effectiveFrom`, it remained permanently the *most overdue*
  schedule, and `min(by:)` handed it the slot again the instant a reboot freed
  it — as trigger `.missed`, ahead of the schedule that had actually been
  starved.
- A tick refused by rule 1 writes nothing. Four days of starvation rendered as
  an empty Activity Log, indistinguishable from a dead agent.

Each of these is survivable alone. Together they mean one destination that
cannot finish silently owns the machine, which is not how Time Machine behaves
on its own.

## Scope

This spec changes *which* due destination is started, *when* a run's hold on
the slot ends, and *what is recorded* while nothing can start. It does not
change rule 1, does not add concurrency, and does not touch the recurrence
maths in spec 001/006.

## 1. Fairness ordering

Replace "most overdue wins" with "least recently attempted wins".

    attempt(d) = the startedAt of the most recent BackupRun for d that
                 actually started — any outcome except .skipped — or
                 .distantPast if there is none.

Among the schedules that are due, start the one with the oldest `attempt(d)`.
Ties break on the earlier due occurrence, then on configuration order, so the
existing behaviour is preserved whenever attempt times are equal.

Due-ness is unchanged: it still derives from `lastCompletedRuns`, so a
destination whose backup failed stays due and is retried rather than being
skipped until its next occurrence. That deliberate property, documented on
`retryCooldown`, is why due-ness and ordering must be separated — the bug is
that a destination which never completes also never yields its *priority*, not
that it stays due.

Deriving the key from history rather than the in-memory `lastAttempt` makes
fairness survive a restart, which is exactly the case that failed: the reboot
handed the slot straight back to the destination that had just held it for two
days.

Against the observed failure, at 03:00 on day two the network destination's
last attempt was 08:40 the previous morning and the local disk's was 10:00, so
the network destination wins and the starvation does not begin.

## 2. Stall watchdog

A run's hold on the slot ends when it stops making observable progress, not
only when backupd lets go of it.

The runner records, per open run, the last instant at which the activity
snapshot changed — where "changed" means any of the backup phase,
`progress.bytesCopied`, or `progress.filesCopied` differs from the previous
observation. If that instant is more than `stallTimeout` old, the run is
stalled:

1. Request `stopBackup()`.
2. Close the run as `.failed(reason: "stalled")`.
3. Release the slot; the next evaluation picks a winner under §1.

`stallTimeout` defaults to **2 hours**, injected like the existing graces so
tests drive it without waiting. The threshold is deliberately generous: a long
`FindingChanges` or `Thinning` phase legitimately reports no byte movement, and
the failure this guards against ran for two days with zero change of any kind.
A single timeout over "nothing at all changed" is preferred to per-phase
thresholds, which would need a table of phase behaviour that Apple does not
document and that spec 010 already declines to assume.

Stopping a backup is safe to do: Time Machine's in-progress bundle is
incremental, so the next attempt resumes rather than restarting from zero.
`.stopping` may persist for tens of seconds on network destinations, which the
existing `BackupActivity.stopping` case already models; the slot is not
considered free until activity reads `.idle`.

## 3. Failure backoff

The watchdog alone would let a reliably-stalling destination reclaim the slot
every `stallTimeout` forever. The existing flat 15-minute `retryCooldown`
becomes exponential in the number of *consecutive* non-completing attempts for
that destination, counted from history:

    cooldown(n) = min(retryCooldown * 2^(n-1), maxRetryCooldown)

with `maxRetryCooldown` defaulting to 12 hours. One completed run resets the
count. A destination that cannot be backed up therefore fades into the
background instead of consuming the slot on a loop, while a transient failure
still retries promptly.

## 4. Visibility

Two additions, because the live state and the historical record answer
different questions.

**Live.** `AgentState` gains an optional waiting reason, written by the agent
and read by the GUI and the menu bar extra:

    AgentState {
        pausedUntil: Date?
        waiting: Waiting?
    }

    Waiting { blockedDestinationID: String?, holderDestinationID: String?, since: Date }

This is what turns "nothing is happening" into "waiting — Time Machine is busy
with X since 10:00". It stays in `state.json`, which the agent already owns
outright, so the single-writer rule from `ARCHITECTURE.md` is unaffected.

**Historical.** `BackupRun.Outcome` gains

    case skipped(reason: String?)

recorded **once per due occurrence** that could not be started, not once per
tick — deduplicated on the occurrence date. This inherits rule 3's coalescing
exactly as written: a destination's reference does not advance on `.skipped`
any more than it does on `.failed`, so a schedule blocked across several days
still yields a single skipped occurrence, not one per day and not one per
poll. What was missing from the Activity Log was not a record per missed day —
it is that a blocked tick left no record at all.

Two consequences to hold onto:

- `lastCompletedRuns` must continue to ignore `.skipped`; a skipped occurrence
  did not run and must not advance the reference.
- `attempt(d)` in §1 must also ignore `.skipped`; no attempt was made, so it
  must not cost the destination its place in the rotation.

Adding an enum case is additive for decoding existing `history.json` files. A
history containing `.skipped` will not decode in an older build, which is
acceptable for a forward-only change and consistent with how `schemaVersion` is
handled in spec 003.

## Open decision — a hard cap on slot tenure

Not specified above, and needs a call before implementation.

§2 only frees the slot from a run that has *stopped* progressing. A run that
progresses genuinely but absurdly slowly — an estimate of weeks remaining is
achievable on a slow or near-full destination — still starves every other
schedule for as long as it inches along, and no threshold on "is it moving"
will catch it.

A `maxRunDuration` (24 hours, say) that yields the slot regardless of progress
would close that gap, at the cost of being able to interrupt a legitimate first
full backup to a large slow destination. Because backups resume incrementally,
the interruption is not destructive, but a destination that cannot finish
within the cap would never complete a full backup at all — it would be stopped
and resumed forever, which is worse than the starvation it prevents.

Recommendation: **define it, default it off**, and let §1 plus §2 land first.
Once fairness ordering exists, a slow-but-progressing run costs the other
destinations one delayed occurrence rather than permanent starvation, which may
well be enough.

## Verification

`EscapementKit` is unit-testable, and all four sections live in `Scheduler`,
`SchedulerRunner`, and the stores. TDD per `CLAUDE.md`: failing test first,
confirmed to fail for the right reason.

1. **Fairness.** Two due destinations, one never completed with a recent
   attempt, one completed long ago; assert the long-idle one is chosen. Assert
   the tie-break falls back to due occurrence and then configuration order.
2. **Fairness across restart.** Build the decision from history alone with an
   empty in-memory `lastAttempt`; assert the destination that just held the
   slot does not win.
3. **Watchdog.** Drive the fake control through identical activity snapshots
   past `stallTimeout`; assert `stopBackup` is requested and the run closes as
   `.failed(reason: "stalled")`. Assert a run whose phase changes, or whose
   byte or file count advances, is *not* stalled — including one that only
   changes phase with no byte movement, which is the `Thinning` false positive.
4. **Backoff.** Assert consecutive non-completing attempts lengthen the
   cooldown, that it saturates at `maxRetryCooldown`, and that one completed
   run resets it.
5. **Visibility.** Assert one `.skipped` record per blocked occurrence and not
   per tick; assert `lastCompletedRuns` and `attempt(d)` both ignore
   `.skipped`; assert `AgentState.waiting` is set while blocked and cleared
   when a backup starts.
6. **Regression.** The existing spec 003 suite must pass unchanged where it
   does not concern ordering; rule 1, missed-run coalescing, and pause
   behaviour are untouched.

Beyond the suite, per `CLAUDE.md` the agent cannot be `@testable`-imported.
Verify in the signed build with two real destinations: confirm the Activity Log
shows the waiting state, and that a schedule blocked by a busy destination
fires once the slot frees rather than losing its turn.
