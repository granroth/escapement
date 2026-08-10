# Spec 016 — Overnight hourly windows

Status: implemented

## Purpose

Spec 006 added `TimeWindow` so an hourly schedule could be restricted to part
of the day ("every hour at :00 from 9:00 AM to 5:00 PM") and explicitly deferred
the wrapping case: *"Overnight hourly windows (end before start) [...] are out
of scope."* This spec removes that restriction. A window whose end precedes its
start means the window crosses midnight — "every hour at :00 from 11:00 PM to
4:00 AM" — which is the shape a user wants when backups should run only while
the Mac is idle overnight.

This is a change to one predicate and its validation. The next-fire engine, the
on-disk schema, and the day-by-day search are untouched; the reasoning for why
they *can* be untouched is most of what follows.

## Model

    TimeWindow { start: TimeOfDay, end: TimeOfDay }   // inclusive at both ends

    start <  end   same-day window:  start ... end
    start >  end   overnight window: start ... midnight ... end
    start == end   a single instant  (unchanged from spec 006)

    isOvernight == (start > end)

    contains(t) == isOvernight ? (t >= start || t <= end)
                               : (start <= t && t <= end)

Both endpoints stay inclusive in both branches, so the rule spec 006 established
("only the hourly firing points at or between `start` and `end` fire") is
preserved verbatim — only the meaning of *between* widens.

### Why `start > end` becomes valid rather than rejected

There is exactly one other reading of an inverted window: the empty set. That
reading is worthless — a user who enters it gets a schedule that never fires,
and there is no gesture that would produce it on purpose. "Crosses midnight" is
the only interpretation anybody means, so it is the one the type should carry.

The consequence is that **`TimeWindow` gains a total initialiser.** With the
inverted case admitted, every pair of `TimeOfDay` values is a well-formed
window; there is no invalid inhabitant left for a failable initialiser to
reject, so `init?(start:end:)` becomes `init(start:end:)`.

That is a bigger simplification than it looks. Spec 001's decoding argument —
"synthesised `Codable` conformances assign stored properties directly and would
bypass every check" — is why `Recurrence.hourly` re-validates the window a
second time today:

    // Re-validate the window here too: a decoded `TimeWindow` bypasses its
    // failable initialiser, so an inverted window can reach this factory
    // and must be rejected rather than trusted.
    if let window, window.start > window.end { return nil }

That guard is deleted, and nothing replaces it. The hazard it defended against
does not move somewhere else; it stops existing, because the state it was
guarding against is now a legal state. `TimeWindow` keeps its synthesised
`Codable`, and the two `TimeOfDay` values it holds keep their own hand-written,
range-checking decoders — so the boundary spec 001 cares about (an hour of 99
reaching the engine from a hand-edited file) is still enforced exactly where it
was, one level down.

**The doc comment above the type must be rewritten in the same edit.**
`Recurrence.swift:3-5` currently reads:

    /// A window of the day, inclusive of both ends, used to restrict which hourly
    /// firing points run. Overnight windows (end before start) are out of scope,
    /// so construction requires `start <= end`.

Left alone it would contradict the initialiser three lines below it, which is
the worst kind of stale comment — it documents a precondition the compiler no
longer has. It is replaced by:

    /// A window of the day, inclusive of both ends, used to restrict which hourly
    /// firing points run. A window whose end precedes its start crosses midnight:
    /// it then matches every time at or after `start` together with every time at
    /// or before `end`. Every pair of `TimeOfDay` values is a well-formed window,
    /// so construction cannot fail; equal endpoints are a single instant rather
    /// than the whole day, and endpoints one minute apart the other way round are
    /// the whole day. See spec 016.

### Why `start == end` stays a single instant, not "the whole day"

The wrap rule `t >= start || t <= end` degenerates to "always true" when
`start == end`, which would silently reclassify every equal-endpoint window from
"fires at one time of day" to "fires all day". Spec 006 admitted the equal case
deliberately, and the implemented suite pins it:

    #expect(TimeWindow(start: t(8), end: t(8)) != nil)  // a single-instant window is allowed

So equality is routed to the same-day branch, where it already means one
instant. The ordering of the two branches is therefore load-bearing:
`isOvernight` is a strict `>`, never `>=`.

The alternative — "equal endpoints mean the whole day" — would also make the
window control non-monotonic in a way a user cannot see: dragging the end picker
back one minute past the start would flip a schedule from six fires a night to
one, and dragging it one minute further would flip it to twenty-four. One
instant at equality keeps the transition continuous in both directions: a window
shrinking towards its start converges on a single fire, and a window widening
past its start begins wrapping.

A single-instant window may select no firing point at all — a window of exactly
08:00 against `minute: 30` matches nothing, and `nextFireDate` returns `nil`
after exhausting the bounded search. That is spec 001's rule 6 ("an empty
selection has no next fire") behaving as designed, and it is reachable today,
before this change. Making it unreachable is out of scope; see below.

### Adjacent endpoints mean the whole day — anywhere in the day

Stated as an exclusion rather than an inclusion, the wrap rule is

    contains(t) == !(end < t && t < start)      // when isOvernight

so an overnight window excludes exactly the **open** interval strictly between
`end` and `start`, and includes everything else. `TimeOfDay` is `Comparable` by
plain lexicographic `(hour, minute)` order at minute granularity
(`TimeOfDay.swift:18-20`) — not modular — so that excluded interval is an
ordinary run of minutes, `start - end - 1` of them. When `start` is exactly one
minute after `end`, it is empty, and the window matches every representable
`TimeOfDay`.

This is not a midnight-adjacent curiosity. It happens at every one of the 1439
adjacent-minute pairs in the day:

    TimeWindow(start: t(13, 1), end: t(13, 0))

    isOvernight   true            (13:01 > 13:00)
    excluded      (13:00, 13:01)  — no TimeOfDay lies strictly between
    contains(t)   true for every t
    summary       "Every hour at :00 overnight from 1:01 PM to 1:00 PM"

That window is functionally identical to no window at all, and its label gives
the user no hint of it. Entering the two pickers the wrong way round — 1:01 PM
to 1:00 PM where 1:00 PM to 1:01 PM was meant — silently converts a two-minute
window into an unrestricted one: against "every hour at :00" that is twenty-four
fires a day where the user asked for one.

**The formula is correct and is not changed.** It is the consistent
generalisation of the wrap semantics, and it is exactly what the continuity
argument above predicts: a window shrinking to equality converges on one
instant, and one minute past equality it begins wrapping — the first wrap it can
express is the one that wraps all the way round. Special-casing adjacent
endpoints would reintroduce the discontinuity that argument exists to avoid, and
there is no other value the pair could mean.

**But it generalises the hazard spec 006 took care to avoid.** Spec 006 admitted
`start == end` as a single instant precisely so that a window could not silently
come to mean "all day"; this change hands that same trapdoor to any adjacent
pair in the 24 hours. The spec records it here rather than in a comment because
it is the one behaviour of this feature a user could hit by accident and not
notice.

The mitigation belongs in the editor, not the model: **an editor-level warning
when the two pickers are one minute apart in the inverted direction** — "this
window covers the whole day" — is worth doing, and is noted here for a later
spec rather than folded into this one, keeping the same engine-first scoping
spec 006 used. Nothing in this spec's model or firing logic changes if that
warning is added later; it reads the same two `TimeOfDay` values the pickers
already hold.

**The failure direction is asymmetric.** An overnight window can only trend
towards matching *more*, never towards matching nothing: `start > end` is
required, both endpoints are inclusive, so the window always contains at least
`start` and `end` themselves — two times of day minimum, 1440 maximum. The
excluded region can shrink to empty; it can never grow to swallow the day. A
same-day window fails the other way, towards matching too little, bottoming out
at the single instant that may select no grid point at all. The two directions
need different treatment and only one of them is deferred below.

## Firing points

### The day-by-day search needs no change

`nextFireDate` walks real days from `startOfDay(for: reference)` and, for each,
asks `firingPoints(on:)` for that day's instants in ascending order, returning
the first one strictly greater than the reference. The hourly case builds
`stride(from: 0, to: 24, by: everyHours)`, keeps the hours whose
`TimeOfDay(hour:minute:)` satisfies `window?.contains(time) ?? true`, and
resolves each through `Calendar`.

The natural worry is day attribution: the 01:00 fire of an 11:00 PM–4:00 AM
window *belongs*, to a human, to the previous evening's session, but the engine
files it under the day whose components produced it. That worry does not
survive contact with the algorithm, because the two readings generate the same
set of instants:

- **Per-day membership** (what the code does) yields, for every day D, the grid
  hours H with `contains(H)` — that is `{D + H : H ≥ start} ∪ {D + H : H ≤ end}`.
- **Nightly sessions** (what the user pictures) yields, for every day D, the
  evening tail `{D + H : H ≥ start}` and the following morning's head
  `{D+1 + H : H ≤ end}`.

Taken over all days, these are the same union — the second is the first with the
morning half re-indexed by one day. They differ only if the window itself does
not recur every day, and a `TimeWindow` has no notion of which days it applies
to. (This is precisely why the session reading *would* matter for a
weekly-plus-window feature, which is out of scope and noted below.)

So the wrap is invisible to the search: the engine finds 23:00 on day D, fails
to find anything later that day, advances to D+1, and finds 00:00. The window
boundary and the day boundary simply do not have to agree.

**The entire firing-logic change is inside `TimeWindow.contains`.**
`Recurrence.firingPoints` and `Recurrence.nextFireDate` are not edited.

### The window filters the grid; it never re-anchors it

Spec 001 rule 2 anchors hourly to midnight: the firing hours are those where
`hour % everyHours == 0`, and "the day boundary always wins". The window is a
filter applied *after* that grid is generated, which is already how same-day
windows behave — "every 4 hours at :00 from 9:00 AM to 5:00 PM" fires at 12:00
and 16:00, not at 09:00 and 13:00.

Overnight windows make this more visible, because the window start a user
naturally picks (23:00) is on the grid only when `everyHours == 1`:

| Recurrence | Grid hours | In window 23:00–04:00 |
| --- | --- | --- |
| every hour at :00 | 0…23 | 23:00, 00:00, 01:00, 02:00, 03:00, 04:00 |
| every 2 hours at :00 | 0,2,…,22 | 00:00, 02:00, 04:00 |
| every 3 hours at :00 | 0,3,…,21 | 00:00, 03:00 |
| every 4 hours at :00 | 0,4,…,20 | 00:00, 04:00 |
| every 2 hours at :30 | 0:30,…,22:30 | 00:30, 02:30 |

Two consequences to state plainly rather than discover in the field:

- **"Every 3 hours from 11 PM to 4 AM" fires at 00:00 and 03:00, and never at
  23:00.** 23 is not a multiple of 3. Only `everyHours == 1` puts 23:00 on the
  grid at all.
- **The end is a time, not an hour.** "Every 2 hours at :30" against a window
  ending 04:00 stops at 02:30; 04:30 is past the end.

Re-anchoring the grid to the window start would fix the first bullet and break
rule 2, the daily reset, and every existing same-day window's behaviour. It is
not done. If a user wants a fire at exactly 23:00, the schedule is "every hour".

### Trace: every hour at :00, window 23:00–04:00

Phoenix (no DST). Each day's candidate list is
`[00:00, 01:00, 02:00, 03:00, 04:00, 23:00]` — sorted by instant, so the
window's two halves appear at opposite ends of the list with a nineteen-hour
gap between them, where a same-day window produces one contiguous run.

| Reference | Where the loop finds it | Result |
| --- | --- | --- |
| Mar 10 10:00 | Mar 10, past the morning half | Mar 10 23:00 |
| Mar 10 23:00 | Mar 10 exhausted; Mar 11's first | Mar 11 00:00 |
| Mar 11 00:30 | Mar 11, mid morning half | Mar 11 01:00 |
| Mar 11 04:00 | Mar 11, **jumps the gap** | Mar 11 23:00 |
| Mar 11 23:00 | Mar 11 exhausted; Mar 12's first | Mar 12 00:00 |

The fourth row is the one that distinguishes this from anything spec 006 could
produce, and the one most likely to be got wrong: after 04:00 the *current* day
still has a candidate left (23:00), so the loop must not advance a day. It does
not, because it advances only when every candidate on the day has been passed —
but a filter written to stop at the first out-of-window hour, or an
implementation that tried to model the window as a contiguous interval, would
fail here.

Chaining from any reference therefore produces the repeating nightly sequence
23:00, 00:00, 01:00, 02:00, 03:00, 04:00 — six fires per night — with no
duplicates and no gaps, which is exactly what the user asked for.

## Daylight saving

**No special handling, and the reason is structural rather than lucky.**
`TimeWindow.contains` takes a `TimeOfDay` and returns a `Bool`. It touches no
`Date`, no `Calendar`, and no time interval; it cannot be made DST-sensitive
because it never sees a date. Spec 001 rule 5 ("the engine never does arithmetic
on raw time intervals; it asks `Calendar` for date components") continues to
hold because this change adds no arithmetic of any kind.

Every DST interaction stays where it already was, in `instant(on:hour:minute:)`,
and behaves the same as it does for an all-day hourly schedule — which already
crosses midnight every night and already covers the small hours where US
transitions occur. Concretely, in `America/Los_Angeles` with "every hour at :00,
window 23:00–04:00":

- **Spring forward, 2026-03-08.** Wall-clock 02:00 does not exist. `Calendar`
  resolves it to the shifted instant, which coincides with the grid's own 03:00,
  so the day's candidate list contains that instant twice. The list is sorted
  and the caller takes the first entry strictly greater than the reference, so
  the duplicate is unobservable: the night fires 23:00, 00:00, 01:00, 03:00,
  04:00 — five fires, because the night is an hour short. That is correct; the
  hour genuinely did not happen.
- **Fall back, 2026-11-01.** Wall-clock 01:00 occurs twice; `Calendar` yields
  the first, and rule 1's strictly-future test prevents the second from firing.
  The night fires six times by the clock but spans seven real hours, so the gap
  between the 01:00 and 02:00 fires is two hours of elapsed time. Also correct:
  the schedule is stated in wall-clock terms.

Neither behaviour is new, and neither is specific to wrapping. The only thing
worth asserting in tests is that admitting the wrap did not perturb them.

## Backward compatibility

**No schema change. `schemaVersion` stays 1.** The encoded shape is byte-for-byte
what spec 006 defined:

    "hourly": { "everyHours": 1, "minute": 0,
                "window": { "start": {"hour":23,"minute":0},
                            "end":   {"hour":4, "minute":0} } }

Nothing is added, removed, or renamed. What changes is which values of an
existing field are accepted — a validation and firing-logic change, not a
data-shape change, so a version bump would communicate nothing and would force
old builds to reject files they can in fact read.

- **Old files, new build.** Every window written before this change has
  `start <= end` and takes the same-day branch, whose predicate is unchanged.
  There is no migration and no reinterpretation of existing data.
- **Missing `window`.** Still decodes to `nil`, still means all day. The
  `decodeIfPresent` in `Recurrence.Kind.init(from:)` is untouched.
- **New files, old build (downgrade).** An old build decodes the `TimeWindow`
  through its synthesised conformance, then rejects it in `Recurrence.hourly`,
  which fails `Recurrence.make`, which throws `dataCorrupted` — and because
  `Configuration.init(from:)` decodes `schedules` as a whole, *all* schedules
  fail to load, not just the overnight one. This is accepted rather than
  mitigated: downgrading is rare and deliberate, the failure is loud rather than
  silent, and the repair is to delete the window or re-save from a current
  build. The alternative — decoding schedules leniently, dropping the ones that
  fail — would quietly discard a user's schedule and would weaken exactly the
  boundary spec 001 built by hand. A loud failure on a downgrade is the better
  end of that trade.

## Formatting

`RecurrenceFormatter.summary` appends `" from S to E"` today. Rendered for a
wrapping window that reads "Every hour at :00 from 11:00 PM to 4:00 AM", which
is ambiguous — the same sentence describes an empty range or a typo, and the
status list is the only place a user checks what a schedule actually does.

One word disambiguates it, in the same shape:

    same-day:  Every 4 hours at :30 from 8:00 AM to 6:00 PM
    overnight: Every hour at :00 overnight from 11:00 PM to 4:00 AM

"Overnight" is the term the user reaches for when asking for this, it is short
enough for a status row, and it keeps a single template rather than forking the
sentence. The formatter does not editorialise beyond that: a degenerate wrap
such as 00:01 → 00:00 renders as "overnight from 12:01 AM to 12:00 AM", and
1:01 PM → 1:00 PM renders as "overnight from 1:01 PM to 1:00 PM". Both are
honest about what was typed, and both are wrong about what it *means* — each is
an all-day window, per "Adjacent endpoints mean the whole day" above, and the
summary does not say so. That is a known limitation of the formatter, not a
reason to fork the sentence: the summary's job is to reflect the schedule's
stated shape, and describing the all-day collapse is the editor warning's job.
The formatter is not made to detect it.

Equal endpoints take the same-day form, consistent with the model.

## User interface

Deliberately light, matching how spec 006 scoped itself — engine first, UI
follows the pattern already there. The schedule editor already presents two
independent `NSDatePicker`s for the window ends and imposes no ordering between
them, so entering 11:00 PM → 4:00 AM is already possible mechanically; it is
rejected only at the model boundary, surfacing as a validation message. The
minimal change is therefore to stop rejecting it:

- `ScheduleEditorView.currentRecurrence()` drops the
  `if windowCheckbox.state == .on && window == nil { return nil }` clause, since
  `TimeWindow(start:end:)` no longer returns an optional.
- `updateValidation()` loses its hourly arm — the message *"The window's start
  must be at or before its end."* is now unreachable and must be deleted rather
  than left as a lie. Care is needed here: that arm is `case 0` of a switch
  whose `default` produces the day-of-month message, so removing the case
  without restructuring would make an hourly schedule display "Choose at least
  one day of the month." Hourly must fall through to the empty-string branch.

The pickers gain no ordering constraint, no swap button, and no separate
"overnight" checkbox. The wrap is inferred from the values, and the formatter's
summary is the feedback that the app understood what was entered.

## Verification

`EscapementKit` is a library with no AppKit dependency, so unlike the UI-only
specs this is fully test-drivable: per `CLAUDE.md`, write the failing tests
first and confirm each fails for the right reason before touching
`Recurrence.swift`. Tests belong in `Tests/EscapementKitTests/`, extending
`RecurrenceRefinementTests.swift` (window semantics and firing points),
`RecurrenceTests.swift`'s `DaylightSavingTests` (the DST pair),
`CodingTests.swift` (round-trip and decode), and `RecurrenceFormatterTests.swift`
(wording). Existing helpers: `t(h, m)`, `date(y, mo, d, h, mi)`, and
`calendar(tz)` defaulting to `America/Phoenix`, which has no DST.

**Window semantics**

1. `TimeWindow(start:end:)` is non-failable and every pair constructs;
   `isOvernight` is true for (23:00, 04:00), false for (08:00, 18:00), false for
   (08:00, 08:00), and false for (00:00, 04:00). The last is the boundary
   literal: a window starting at midnight is same-day, because `start > end` is
   false — the strict `>` classifies it, and nothing about 00:00 is special.
2. Regression — same-day membership is unchanged: (08:00, 18:00) contains 08:00,
   12:00, 18:00 and excludes 07:59 and 18:01.
3. Overnight membership: (23:00, 04:00) contains 23:00, 23:59, 00:00, 02:00,
   04:00 and excludes 04:01, 12:00, 22:59.
4. Equal endpoints are one instant, not the whole day: (08:00, 08:00) contains
   08:00 and excludes 07:59, 08:01, and 00:00. This is the test that fails if
   `isOvernight` is written with `>=`.
5. A one-minute wrap at midnight: (23:59, 00:00) contains exactly 23:59 and
   00:00.
6. A one-minute wrap **away** from midnight collapses to the whole day:
   (13:01, 13:00) is overnight and contains 13:00, 13:01, 00:00, 06:00, 12:59,
   and 23:59 — every value tried. Written as an explicit assertion, with the
   reference to "Adjacent endpoints mean the whole day" in the test's comment,
   so the behaviour is pinned as intended rather than left to be discovered and
   "fixed" into a surprise. This is the general case; item 5 is only its
   midnight instance.

**Firing points** — every hour at :00, window 23:00–04:00, Phoenix:

7. From Mar 10 10:00 → Mar 10 23:00.
8. From Mar 10 23:00 → Mar 11 00:00. Pins that the night chains past midnight
   through the day loop, and that rule 1 (strictly future) still applies.
9. From Mar 11 00:30 → Mar 11 01:00.
10. From Mar 11 04:00 → Mar 11 **23:00**, not Mar 12 00:00. Pins the split
    candidate list — the single most likely thing to get wrong.
11. Chaining `nextFireDate` twelve times from Mar 10 12:00 yields exactly the
    two nightly runs 23:00, 00:00, 01:00, 02:00, 03:00, 04:00 with no duplicates
    and no `nil`.

**Grid interaction** — one test per row of the table above, so no row is
asserted in prose only:

12. Every 2 hours at :00, window 23:00–04:00: the night is 00:00, 02:00, 04:00;
    from Mar 10 10:00 → Mar 11 00:00; from Mar 11 04:00 → Mar 12 00:00. Pins
    that an even interval drops 23:00 and that the gap after the morning half
    runs to the next day, not to a same-day 23:00 that is not on this grid —
    the one place the "jumps the gap" behaviour of item 10 must *not* happen.
13. Every 3 hours at :00, window 23:00–04:00: from Mar 10 10:00 → Mar 11 00:00;
    from Mar 11 00:00 → Mar 11 03:00; from Mar 11 03:00 → Mar 12 00:00. Pins
    "filter, don't re-anchor" — 23:00 never fires.
14. Every 4 hours at :00, window 23:00–04:00: the night is 00:00 and 04:00 only.
15. Every 2 hours at :30, window 23:00–04:00: the night is 00:30 and 02:30 only;
    from Mar 11 02:30 → Mar 12 00:30. Pins that the end is a time, so 04:30 is
    outside a window ending 04:00.
16. Regression — spec 006's same-day cases (every 4 hours at :30, window
    08:00–18:00, and the inclusive-endpoint case) still pass unmodified. The
    existing `rejectsInverted` test inverts: `TimeWindow(start: t(18), end: t(8))`
    now constructs and is overnight.

**Daylight saving** — `America/Los_Angeles`, every hour at :00, 23:00–04:00:

17. Spring forward: chaining from 2026-03-07 22:00 through the night returns
    five strictly increasing instants and no `nil`, with no two equal — the
    02:00 grid point collapsing onto 03:00 must not produce a repeated fire.
18. Fall back: chaining from 2026-11-01 00:59, the fire after 01:00 is 02:00
    PST, two real hours later; assert on the elapsed interval so the repeated
    hour is proven not to fire twice.

**Coding**

19. Round-trip: an overnight recurrence encodes and decodes back equal, and the
    emitted JSON has the same key shape as a same-day window.
20. Hand-written JSON with `start` 23:00 and `end` 04:00 now decodes to an
    overnight window instead of throwing. This is the direct inverse of the
    behaviour spec 006 shipped and should be written as such.
21. Regression — a `window` key absent still decodes to `nil` (all day).
22. Regression — a window containing an out-of-range `TimeOfDay` (hour 99) still
    throws `dataCorrupted`. Proves that removing the window's own validation did
    not open the decode boundary.
23. Regression — `.hourly` carrying non-empty `times` is still rejected.

**Formatting**

24. Overnight renders "Every hour at :00 overnight from 11:00 PM to 4:00 AM".
25. Regression — same-day renders "Every 4 hours at :30 from 8:00 AM to 6:00 PM"
    unchanged, and equal endpoints take the same-day form.

**Beyond the suite.** Per `CLAUDE.md`, the editor change is verified by driving
the real app: build, install, set a destination to "every hour from 11:00 PM to
4:00 AM", confirm the editor accepts it with no validation message, confirm the
status row reads the overnight summary, and confirm the persisted
`configuration.json` carries the inverted window and reloads cleanly in both the
app and the agent.

## Out of scope

- **Re-anchoring the hourly grid to the window start**, so that "every 3 hours
  from 11 PM" would fire at 23:00, 02:00. This contradicts spec 001 rule 2 and
  would change every existing same-day window's firing points.
- **Rejecting a window that selects no firing point at all** (a single-instant
  window at :00 against `minute: 30`, say). Pre-existing, unchanged by this
  spec, and correctly handled by rule 6's `nil`. Catching it would mean the
  factory cross-checking the window against the grid, which is a different
  feature — an editor-level warning — and belongs with the UI, not the model.

  This deferral covers only the *too-restrictive* direction, and it is worth
  being explicit that the two directions are not mirror images. This spec's new
  failure mode runs the other way: an overnight window can collapse to matching
  the whole day (adjacent endpoints, above) but can never collapse to matching
  nothing, since `start > end` plus inclusive endpoints guarantees at least two
  matching times. So nothing above should be read as though deferring the
  no-firing-point check also covers the all-day collapse. It does not — that is
  the separate warning noted below.

- **An editor warning for a window that has collapsed to the whole day** —
  endpoints one minute apart in the inverted direction, which `contains` matches
  everywhere and the summary describes as a wrap. Real, worth fixing, and
  deferred to a UI spec for the same reason as the item above: it is a
  cross-check between the entered values and what the user plausibly meant, not
  a property the model can reject, because every such window is well-formed and
  its meaning is unambiguous.
- **Windows on daily, weekly, or monthly recurrences.** Those carry explicit
  `times`, so a window would only be able to remove firing points the user
  typed. A weekly-plus-overnight-window feature would also force the
  day-attribution question this spec dissolves ("does Friday's schedule mean
  Friday 11 PM or Saturday 4 AM?") to be answered properly.
- **Multiple windows per schedule**, and windows expressed as a start plus a
  duration.
- **A dedicated "overnight" control in the editor.** The wrap is inferred from
  the two pickers already present.
