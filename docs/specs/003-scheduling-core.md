# Spec 003 — Scheduling core and persistence

Status: implemented

## Purpose

Decide, at a given instant, whether to start a backup and which one; compute
when next to wake; and persist the user's schedules and the run history across
launches. This is the logic the agent runs on a timer, kept pure so it can be
tested without a clock, a timer, or a backup.

## Configuration

    DestinationSchedule {
        destinationID: String
        recurrence: Recurrence
        isEnabled: Bool
        effectiveFrom: Date
    }

    Configuration { schemaVersion: Int, schedules: [DestinationSchedule] }

`effectiveFrom` is the instant from which occurrences count, set to "now" when
the schedule is created or its recurrence edited. It exists so that
configuring "daily at 03:00" at noon does **not** trigger an immediate backup:
the first fire is the next 03:00, not the moment of saving. It is also the
catch-up baseline for a destination that has never run.

`schemaVersion` is written so a future format change can be migrated; a file
without it decodes as version 1. Schedules are keyed by `destinationID`;
adding one for a destination that already has a schedule replaces it.

A schedule referencing a destination that no longer exists is retained, not
pruned. Disks come and go — an unplugged backup drive should keep its schedule
for when it returns — so reconciling schedules against live destinations is the
UI's presentation concern, not something the store silently does.

## History

    BackupRun {
        id: UUID
        destinationID: String
        trigger: .scheduled | .manual | .missed
        startedAt: Date
        finishedAt: Date?
        outcome: .running | .completed | .failed(String?) | .cancelled
    }

`.missed` marks a run started as catch-up for an occurrence the machine slept
through. `outcome` is `.running` until the agent observes the backup end. The
history is capped at a bounded number of most-recent runs so the file cannot
grow without limit.

## The decision function

Pure. Inputs: the current instant, the schedules, the last completed run per
destination, and the current `BackupActivity`. Output:

    SchedulerDecision = .idle | .start(destinationID: String)

Rules:

1. **One backup at a time.** If activity is anything but `.idle`, the decision
   is `.idle`. `tmutil` runs a single backup globally, and gating here also
   serialises a wake-up flood: the next due destination is started only once
   the current one finishes and a later evaluation sees `.idle` again.

2. **Due.** An enabled schedule is due when
   `recurrence.nextFireDate(after: reference) <= now`, where `reference` is the
   destination's last run, or `effectiveFrom` if it has never run. A disabled
   schedule is never due.

3. **Missed runs coalesce.** A machine that was off for three days does not
   fire three backups. Because the reference advances to the last run, a long
   gap yields a single overdue occurrence, not one per missed period. This is
   deliberate: nobody wants three consecutive catch-up backups.

4. **Most overdue first.** When several destinations are due at once, the one
   whose occurrence is earliest is started, ties broken by configuration
   order. The rest follow on subsequent evaluations under rule 1.

## The next-wake computation

`nextWakeUp(now:)` returns the earliest strictly-future occurrence across all
enabled schedules — `min` over `nextFireDate(after: now)` — or `nil` if nothing
is scheduled. The agent uses it to arm its timer. It is independent of the
last-run reference: overdue occurrences are handled immediately by the decision
function, so the timer only ever looks forward.

## Persistence

Configuration and history are JSON files under
`~/Library/Application Support/Escapement/`. Writes are atomic (write to a
temporary file, then replace) so a crash mid-write cannot truncate a file into
the corrupting shape that decode-time validation exists to reject. A missing
file loads as empty; a corrupt file surfaces as an error the caller handles
rather than a crash.

## Out of scope

The timer, wake observation, file watching, and the act of turning a
`.start` decision into a running backup — all of that is the agent (spec 004).
This spec is only the logic the agent calls.
