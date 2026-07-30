# Spec 013 — Last completed time on the destination card

Status: implemented

## Problem

Each destination card shows when its next backup is scheduled, but not when
its last one finished. Finding that out means opening the Activity Log and
locating the destination's most recent entry — a detour for a fact the card
already has the data for. `RowBuilder` has computed `lastRunText` since spec
005; nothing displays it.

## Behaviour

- Each destination card shows a "Last: …" line alongside the existing
  "Next: …" line, using the same relative wording the Activity Log already
  uses ("2 hours ago", "Failed 3 days ago", "Never").
- The last-completed line is always visible, including while a backup is
  running — it answers a different question than the live status and
  progress detail above it, so it is not repurposed the way "Next:" is.
- A destination with no schedule still shows its last-completed line; only
  "Next:" is blank for those, as today.
- No change to `RowBuilder`'s `lastRunText` logic, history data, or the
  Activity Log — this is a display of an existing value.

## Verification

`DisplayModel`/`RowBuilder` already compute the value and are covered
indirectly by nothing (the app target cannot be `@testable`-imported).
Verify in the signed application:

1. Build and install; confirm each card shows both "Next:" and "Last:" lines.
2. Trigger Back Up Now on one destination and confirm its "Last:" line stays
   visible (unlike "Next:", which is replaced by live progress detail) and
   updates once the run finishes.
3. Confirm a destination that has never run reads "Last: Never".
4. Confirm a destination with no schedule still shows its "Last:" line.
5. Screenshot the row at its existing fixed height (62pt) and confirm the
   fourth line does not clip or force scrolling within the card.
