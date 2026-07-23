# Spec 001 — Recurrence and the next-fire engine

Status: implemented

## Purpose

Given a user's schedule and a reference instant, decide the next instant at
which a destination should be backed up. This is the core of the app;
everything else is presentation or plumbing.

## Model

Following the Calendar repeating-event paradigm, but only as far as backup
scheduling actually warrants. Calendar's full interval multipliers ("every 3
weeks") are deliberately omitted: they require an anchor date to be
meaningful, they complicate the editor, and no realistic backup cadence needs
them.

    Recurrence
      .hourly(everyHours: Int, minute: Int)
      .daily(times: [TimeOfDay])
      .weekly(weekdays: Set<Weekday>, times: [TimeOfDay])
      .monthly(days: Set<Int>, times: [TimeOfDay])

`TimeOfDay` is an hour/minute pair in the user's current calendar. `Weekday`
is a Sunday-first enum matching `Calendar`'s 1-based weekday numbering, since
that is what macOS itself uses.

## Rules

1. **Strictly future.** `nextFireDate(after:)` returns an instant strictly
   greater than the reference. A schedule due exactly now yields the following
   occurrence, never the reference instant itself. This makes the engine safe
   to call in a loop without it returning the same answer forever.

2. **Hourly is anchored to midnight.** `.hourly(everyHours: 4, minute: 30)`
   fires at 00:30, 04:30, 08:30, 12:30, 16:30, 20:30 — the hours where
   `hour % everyHours == 0`. Users think of "every 4 hours" in terms of clock
   positions, not an arbitrary offset from when they happened to click Save.
   An interval that does not divide 24 evenly restarts at midnight; the day
   boundary always wins.

3. **Multiple times per day are supported and ordered.** `times` is treated as
   a set of daily firing points; the engine returns the earliest one that is
   still in the future. Duplicate entries collapse.

4. **A day-of-month that does not exist is skipped, not clamped.** `.monthly`
   on day 31 fires in January and March but not February. Clamping to the 28th
   would silently invent a backup on a date the user did not choose. This
   matches Calendar's own behaviour for monthly repeats.

5. **Daylight-saving transitions resolve through `Calendar`.** The engine
   never does arithmetic on raw time intervals; it asks `Calendar` for date
   components. A wall-clock time that does not exist on a spring-forward day
   resolves to the next valid instant. A time that occurs twice on a
   fall-back day fires once, on the first occurrence.

6. **An empty selection has no next fire.** `.weekly` with no weekdays,
   `.monthly` with no days, or any recurrence with no times returns `nil`
   rather than an arbitrary default. The editor prevents this state; the
   engine does not assume it has.

7. **Bounded search.** The engine searches a bounded window (400 days) and
   returns `nil` past it rather than looping forever on an unsatisfiable
   recurrence.

## Validation

`Recurrence` is validated, not merely constructed:

- `everyHours` in `1...12`
- `minute` in `0...59`
- monthly `days` in `1...31`
- `times` non-empty

Invalid values are rejected at the boundary so that the engine's internals may
assume well-formedness.

**Decoding is a boundary too.** Synthesised `Codable` conformances assign
stored properties directly and would bypass every check above. Since schedules
are read from a JSON file the agent loads at launch, a truncated write or a
hand-edit is a realistic input — and an unvalidated one is not merely wrong but
fatal: an `everyHours` of `0` reaches `stride(by:)`, which traps rather than
returning an empty sequence, crashing the agent on every launch thereafter
because the bad file persists on disk.

`Recurrence` and `TimeOfDay` therefore implement `init(from:)` by hand,
rebuilding the value through the same factories and throwing
`DecodingError.dataCorrupted` when it will not rebuild. A decoded value is
indistinguishable from a constructed one; callers never need a separate
validation step. `Weekday` gets this for free, as raw-value enum synthesis
already routes through `init?(rawValue:)`.

An hourly recurrence carrying times is also rejected, since the interval and
the times would disagree about when to fire.

Rules 6 and 7 are consequently unreachable through the public API — which is
the point. They remain implemented as defence in depth rather than deleted,
because a scheduling agent should not sit one invariant slip away from a crash
loop.

## Out of scope

Whether a backup *may* run at the computed instant — destination reachability,
a backup already in flight, the global `AutoBackup` precondition — is a
separate concern. This engine answers only "when next", never "is it allowed".
