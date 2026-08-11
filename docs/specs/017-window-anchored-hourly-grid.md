# Spec 017 — Anchor the hourly grid to the window, when there is one

Status: implemented

## Purpose

A user reported setting an hourly schedule to "every 4 hours, 11:00 PM to
4:00 AM" and expecting it to fire at 11:00 PM and 3:00 AM. It fired at
midnight only. That is not a defect — it is exactly what spec 016 documented
and deliberately chose to ship, down to using this same interval and window
as its worked example:

> "Every 3 hours from 11 PM to 4 AM" fires at 00:00 and 03:00, and never at
> 23:00.

and, more generally:

> Re-anchoring the grid to the window start would fix the first bullet and
> break rule 2, the daily reset, and every existing same-day window's
> behaviour. It is not done.

That deferral is reversed here. Real usage confirms the confusion spec 016
predicted as a live risk rather than a hypothetical one, and a user who
configures a window naturally reads its start as the schedule's anchor — not
midnight, which appears nowhere in what they typed. This spec re-anchors the
hourly grid to the window's start whenever a window is present, while leaving
the unwindowed case exactly as spec 001 rule 2 defined it.

## The change, precisely

`Recurrence.firingPoints(on:)`'s `.hourly` case currently generates the day's
candidate hours as

    stride(from: 0, to: 24, by: everyHours)

i.e. every hour where `hour % everyHours == 0`, then filters by
`window?.contains`. This spec changes the *phase* of that stride to come from
the window's start hour instead of always being zero:

    let phase = (window?.start.hour ?? 0) % everyHours
    stride(from: phase, to: 24, by: everyHours)

Nothing else changes. `window?.contains` still filters the result;
`nextFireDate`'s day-by-day search is untouched, for the same reason spec 016
gave — the phase is a property of a single day's candidate list, not of the
search that walks days.

### Only the hour of `window.start` is used, not its minute

The phase is `window.start.hour % everyHours` — an integer number of hours.
`window.start`'s minute, and the recurrence's own `minute` field, keep their
existing, independent meaning: `minute` still names the minute-of-hour every
generated candidate fires at, exactly as it does today with no window at all.

This is a deliberate narrowing, not an oversight. The two fields already mean
different things to a user: `minute` is "which minute of the hour," picked
from a five-minute-increment control; `window.start` is "when the window
opens," picked from a free-entry time control. Folding the window's minute
into the anchor would make the grid's minute-of-hour silently track two
different controls depending on whether a window is set, and would make a
window whose start isn't on the `minute` control's five-minute grid (entered
by hand, or decoded from a hand-edited file) impossible to represent as a
literal firing instant. Anchoring on the hour alone means a windowed grid is
always exactly as predictable as an unwindowed one: multiples of `everyHours`
apart, at `:minute` past — just started from a different hour.

One consequence worth stating rather than leaving to be discovered: if
`window.start`'s minute is nonzero and does not equal the recurrence's own
`minute`, the window's own start instant is not necessarily itself a firing
point. `window.start = 23:15`, `minute = 0`, `everyHours = 4` anchors the
phase at hour 23 (`23 % 4 = 3`) and generates `...,19:00,23:00,3:00,...`;
`23:00` fails `window.contains` because the window opens at 23:15, so the
first fire that night is `03:00`, not `23:00` or `23:15`. This is the same
"the end is a time, not an hour" shape spec 016 already documents for window
ends (`04:30` past a window ending `04:00`); it is not new here, only now
reachable from the start side too. **The editor does nothing today to steer a
user away from this** — `ScheduleEditorView`'s minute control and window
pickers are independent, and nothing syncs one to the other when a window is
toggled on. So this is not a rare, defended-against edge case: anyone who
free-types a window start whose minute doesn't already match the `minute`
control (which defaults to `:00`) hits it. An editor default that syncs the
two is listed under "Out of scope" below rather than claimed as already
mitigating this.

### Unwindowed hourly is unchanged

`phase` is `0` when `window` is `nil`, which is the existing stride
unmodified. Spec 001 rule 2 ("hourly is anchored to midnight... the day
boundary always wins") continues to hold exactly as written for every
schedule that has no window. This spec only changes behavior a user opts
into by setting a window.

## Why this does not just re-litigate spec 016's reasons for deferring it

Spec 016 gave two reasons not to do this: it would "break rule 2" and "every
existing same-day window's behaviour."

**Rule 2** stated a default, not a promise that windows share the default's
anchor. Nothing in spec 001 discusses windows — they arrive in spec 006,
after rule 2 was written — so "the day boundary always wins" is preserved
for its actual scope, the unwindowed case, and was never a statement about
windowed grids at all. Reading it as covering both was spec 016's choice, not
spec 001's.

**Existing same-day windows** do change behavior, and that is the point, not
a side effect to avoid. Spec 016's own worked table shows the same
misalignment on the same-day side: "every 4 hours, 9:00 AM to 5:00 PM" fires
at noon and 4:00 PM today (`0,4,8,12,16,20` filtered to the window), never at
9:00 AM, which is the time the user actually typed into the start picker.
Re-anchoring gives `9:00 AM, 1:00 PM` — the window's own start fires, same as
the overnight case. There is no principled reason to fix the confusion for
overnight windows and knowingly leave it for same-day ones; both come from
the same midnight-anchored stride, and a user configuring either reads the
start picker as "when this begins," not as an offset into an invisible
midnight-anchored grid.

## Firing points: before and after

Every 4 hours, 11:00 PM to 4:00 AM (the reported case):

| | Old (midnight-anchored) | New (window-anchored) |
| --- | --- | --- |
| Nightly candidates | 00:00, 04:00 | 23:00, 03:00 |

Every 3 hours, 11:00 PM to 4:00 AM:

| | Old | New |
| --- | --- | --- |
| Nightly candidates | 00:00, 03:00 | 23:00, 02:00 |

Every 2 hours, 11:00 PM to 4:00 AM:

| | Old | New |
| --- | --- | --- |
| Nightly candidates | 00:00, 02:00, 04:00 | 23:00, 01:00, 03:00 |

Every 4 hours, 9:00 AM to 5:00 PM (same-day):

| | Old | New |
| --- | --- | --- |
| Candidates | 12:00, 16:00 | 09:00, 13:00, 17:00 |

Every 4 hours, 8:00 AM to 6:00 PM (spec 006/016's own example, unaffected):

| | Old | New |
| --- | --- | --- |
| Candidates | 08:00, 12:00, 16:00 | 08:00, 12:00, 16:00 |

The last row is why several existing tests are unaffected: 8's hour is
already a multiple of 4, so the old and new phase coincide. That is
incidental to the specific numbers chosen in spec 006's examples, not a
property of same-day windows in general, as the 9:00 AM row shows.

### `everyHours` values that do not divide 24 evenly

Spec 001 rule 2 already accepts that a non-divisor interval (5, 7, 9, 10, 11
hours) produces an uneven cadence in the unwindowed case, because the day
resets the phase at midnight rather than carrying a remainder forward — "the
day boundary always wins." Re-anchoring to a window's start does not fix or
worsen this; it inherits it. Every 5 hours, window 23:00–04:00: phase is
`23 % 5 = 3`, the day's grid is `03:00, 08:00, 13:00, 18:00, 23:00`, and only
`03:00` and `23:00` survive the window filter — a 4-hour gap one way and a
20-hour gap the other, never a uniform 5. This is not a new limitation this
spec introduces; the old midnight-anchored grid for the same configuration
filtered to a single candidate (`00:00`) with a 24-hour gap, which is worse.
It is called out here, and pinned by a test, so the unevenness is a known
consequence of the untouched day-by-day search rather than something to
discover as a surprise later.

## Interaction with the window's own wrap and inclusivity rules

Untouched. `TimeWindow.contains` (spec 016) still decides which candidates
survive the filter; this spec only changes which candidates are generated
before that filter runs. All of spec 016's `contains` reasoning — the
inclusive endpoints, the overnight wrap, the single-instant and
whole-day-collapse edge cases — applies identically to the new candidate
list.

## Daylight saving

No change in kind from spec 016's analysis: the phase shift changes which
integer hours are candidates, not how a candidate hour resolves to an
instant. `instant(on:hour:minute:calendar:)` is untouched, so spring-forward
and fall-back behave exactly as spec 016 describes, just for a different set
of candidate hours.

## Backward compatibility

**No schema change.** `Recurrence`'s encoded shape is unchanged; this is a
firing-logic change, not a data-shape one, exactly as spec 016 was. A
schedule saved before this change decodes identically and simply produces
different (and, per the above, more intuitive) firing points once the new
build computes them. There is nothing to migrate: the on-disk `everyHours`,
`minute`, and `window` values are reinterpreted by the same fields, not
replaced.

## Verification

Per `CLAUDE.md`, write failing tests first. This lands mostly as edits to
existing tests in `RecurrenceRefinementTests.swift`'s `Overnight window
firing points` suite, since several of those tests currently assert the
midnight-anchored behavior as their explicit subject (their names —
"skips hours off the grid," "has no evening candidate" — describe the exact
confusion this spec removes) and must be rewritten to assert the new
candidates rather than deleted, so the grid-interaction behavior stays
pinned. New coverage needed beyond that:

1. The reported case: every 4 hours, window 23:00–04:00, fires at 23:00 and
   03:00 — not 00:00 and 04:00.
2. Every 3 hours and every 2 hours, same window: matches the "before/after"
   table above, replacing the existing tests that pin the old grid.
3. A same-day window whose start is not a multiple of the interval — "every 4
   hours, 9:00 AM–5:00 PM" fires at 09:00, 13:00, 17:00, not 12:00 and 16:00.
4. Regression: a same-day window whose start already aligns to the interval
   (spec 006's "every 4 hours, 8:00 AM–6:00 PM") is unchanged.
5. Regression: no window still anchors at midnight — spec 001 rule 2's
   existing test keeps passing unmodified.
6. `window.start`'s minute is ignored for anchoring: a window starting
   23:15 with `minute: 0` and `everyHours: 4` anchors phase at hour 23, the
   same as a window starting 23:00 — and 23:00 itself does not fire, since it
   fails `window.contains` against a window that opens at 23:15.
7. Chaining `nextFireDate` across several nights for the reported case (every
   4 hours, 23:00–04:00) produces exactly 23:00, 03:00 repeating, with no
   duplicates and no `nil`. The suite's existing chaining test uses
   `everyHours: 1`, whose phase is `23 % 1 == 0` regardless of the window —
   it does not exercise re-anchoring at all, so this needs its own test
   rather than reusing that one.
8. A window starting at midnight (`window.start.hour == 0`) produces the same
   firing points as no window at all, confirming the `window?.start.hour ?? 0`
   fallback's boundary case.
9. An interval that does not divide 24 evenly (`everyHours: 5`) combined with
   an overnight window keeps the same day-by-day unevenness spec 001 rule 2
   already accepts for the unwindowed case — alternating gaps rather than a
   uniform 5-hour cadence — rather than silently leaving that interaction
   unpinned.

**Beyond the suite.** Build, install, set a destination to "every 4 hours,
11:00 PM to 4:00 AM," and confirm via `history.json` / the status row that it
fires at 11:00 PM and 3:00 AM rather than midnight and 4:00 AM.

## Out of scope

- **Anchoring to `window.start`'s minute as well as its hour.** Considered
  and rejected above — it would couple two controls the editor presents
  independently.
- **An editor default that keeps the minute control in sync with the window
  start picker's minute.** Worth doing — nothing in the editor today steers a
  user away from the edge case above, so it is not rare in practice — but it
  is a UI-only change with no effect on the engine this spec edits, and
  belongs in its own pass over `ScheduleEditorView` if pursued.
- **Windows on daily, weekly, or monthly recurrences.** Still out of scope
  per spec 016, unaffected by this change.
