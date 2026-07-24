# Spec 006 — Recurrence refinement: daily interval and hourly window

Status: implemented

## Purpose

Two model additions requested after playtesting the first cut:

1. **Daily interval.** "Every N days at T" — every day (N = 1), every other day
   (N = 2), and so on. The earlier decision to omit interval multipliers is
   revisited *only* for daily, because "every other day" is a real backup
   cadence and the anchor problem has a natural answer here (see below).
2. **Hourly window.** "Every N hours at :MM, from Start to End." The window is
   optional; empty means all day, exactly today's behaviour.

Weekly and monthly are unchanged: they stay selection-based (specific weekdays
/ days-of-month) with no "every N weeks/months" multiplier.

## The anchor problem, and why daily is safe

An interval like "every 2 days" is meaningless without a reference: every 2
days *counting from when?* The original spec dropped multipliers partly for
this reason. Daily has a natural anchor already on hand: the schedule's
`effectiveFrom`, the instant the user saved it. "Every 2 days" therefore means
every second day counting from the save date.

`Recurrence.nextFireDate` gains an `anchor: Date` parameter. Only
`daily(everyDays:)` with `everyDays > 1` consults it; every other kind ignores
it. Callers that own a schedule (the scheduler, the run loop, the status list)
pass that schedule's `effectiveFrom`. A day matches when the whole-day count
from the anchor's day to that day is divisible by `everyDays`.

## Model

    Kind
      .hourly(everyHours: Int, minute: Int, window: TimeWindow?)
      .daily(everyDays: Int)
      .weekly(weekdays: Set<Weekday>)
      .monthly(days: Set<Int>)

    TimeWindow { start: TimeOfDay, end: TimeOfDay }   // inclusive, same day

- `everyDays` validates to `1...366`. One means every day, unchanged.
- `window` is optional; `nil` is all day. When present, only the hourly firing
  points at or between `start` and `end` (inclusive) fire. `start <= end` is
  required; an overnight window is out of scope for this pass.
- `daily(times:)` keeps its old shape at the call site through a convenience
  that defaults `everyDays` to 1, so existing schedules and the many existing
  tests read unchanged.

## Backward compatibility

Configurations written by the first cut have `daily` with no `everyDays` and
`hourly` with no `window`. The hand-written decoders default a missing
`everyDays` to 1 and a missing `window` to `nil`, so old files load without
loss. `schemaVersion` stays 1 — the change is purely additive and the decoders
absorb it.

## Formatting

- Daily: "Daily at T" for N = 1 (unchanged), "Every N days at T" for N > 1.
- Hourly: "Every N hours at :MM" for an all-day window, with " from S to E"
  appended when a window is set. "Every hour" for N = 1.

## Out of scope

Overnight hourly windows (end before start), and any interval for weekly or
monthly.
