# Spec 005 — The AppKit application

Status: implemented (nominal); login-item registration and the detailed-log
window deferred to refinement — see "Background operation" and "Deferred".

## Purpose

The Mac app itself: a status window that shows what is scheduled and what is
happening, a Settings window for editing schedules, and the platform glue —
timer, wake observation, file watching — that drives the run loop.

AppKit, by the user's decision; the app is Mac-only and will never be ported.
The guiding question throughout is "what would Apple do?".

## Windows

**Main window — status.** The primary viewport. One row per destination
(discovered live via `tmutil`), each showing:

- name and kind (local disk / network share);
- whether it has a schedule, and a plain-language summary of it
  ("Daily at 3:00 AM", "Weekdays at 2:00 AM");
- current state — idle, or the live phase and progress from `activity()`, with
  the indeterminate case shown as a barber-pole, never as 0%;
- last run (relative: "2 hours ago") and next run ("Today at 3:00 AM").

A destination with no schedule reads as such, with an obvious way to add one. A
"Back Up Now" action per row triggers `backUpNow`. Selecting a row and opening
the detailed log shows that destination's history.

The window restores size and position (standard state restoration). Toolbar and
menu commands, not just buttons, reach every action.

**Settings window — schedule editing.** Standard `Cmd-,`. Per destination, a
schedule editor in the Calendar repeating-event idiom: frequency
(hourly / daily / weekly / monthly), the times of day, and the weekday or
day-of-month selection where relevant. Enabling a schedule or changing its
recurrence stamps `effectiveFrom` so no immediate backup fires.

**The manual-mode banner.** When `automaticBackupState()` is `.automatic`, a
prominent, non-dismissable banner explains that macOS's own scheduler is
running and will conflict, with a button that opens Time Machine in System
Settings (`x-apple.systempreferences:com.apple.Time-Machine-Settings.extension`).
Scheduling controls are disabled while automatic. When `.unknown`, a softer
caution is shown and scheduling stays enabled. When `.manual`, no banner.

## Platform glue

- **Timer.** A `DispatchSourceTimer` armed for `runner.nextWakeUp()`, re-armed
  after each `evaluate()`. Also evaluate on launch and on becoming active.
- **Wake.** Observe `NSWorkspace.didWakeNotification`; on wake, evaluate after a
  short debounce so a machine waking to several overdue destinations settles
  before the first backup starts, and so a network share has a moment to mount.
- **Activity polling.** While a backup is running, poll `activity()` on a short
  interval so the UI progress and the run-closing logic stay current; fall back
  to the schedule timer when idle.
- **Configuration changes.** The Settings window writes configuration; the
  status window observes the file (or is notified in-process) and refreshes.

## Background operation

For this first cut, scheduling runs while the app is running: closing the
window does not quit it (`applicationShouldTerminateAfterLastWindowClosed`
returns false), so it keeps evaluating in the Dock. Backups therefore fire as
long as the app is open.

Two pieces of "keeps working when you are not looking" are deliberately
deferred to refinement, because both need a bundle installed in `/Applications`
and signed to register cleanly, which the worktree build cannot verify:

- **Login-item registration** (`SMAppService.mainApp`) so the app relaunches at
  login and stays resident.
- **The dedicated `SMAppService.agent` daemon** from `ARCHITECTURE.md`, which
  fires backups even when the app has been quit.

The scheduling logic already lives in `EscapementKit` and is called identically
from either host, so both are repackaging, not a rewrite. Until they land, the
honest limitation — scheduling runs while the app is open — is documented in the
README.

## Deferred

- Login item / background agent (above).
- The per-destination detailed-log window. History is captured and the last run
  is shown in the status list; a dedicated log viewer is not yet built.
- Multiple times per day in the editor. The model and engine support it; the
  editor currently edits a single time per schedule.

## Mac-assed checklist (applied)

- Every action reachable from the menu bar, not only from buttons.
- Standard Settings window and `Cmd-,`.
- Window state restoration.
- Full keyboard navigation; VoiceOver labels on status rows.
- Light, dark, and high-contrast appearances.
- Relative, humane date formatting via `Date.RelativeFormatStyle` and the
  user's locale and calendar.
- No custom not-Mac chrome; native `NSTableView`/`NSOutlineView`, standard
  toolbar, standard controls.

## Verification

Build a signed `.app` bundle, launch it, and drive the real UI: confirm the
status list populates from live `tmutil`, the manual-mode banner appears (this
development machine is currently `.automatic`), a schedule can be created and
survives relaunch, and "Back Up Now" starts and can stop a backup. Screenshot
before/after. Unit-tested logic in `EscapementKit` is necessary but not
sufficient; the app is verified running.
