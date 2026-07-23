# Escapement — Architecture

Escapement schedules Time Machine backups on a user-defined cadence instead of
Apple's fixed hourly/daily/weekly options. It does not create, configure, or
destroy Time Machine destinations; those are set up normally in System
Settings. Escapement only decides *when* each existing destination runs.

The name comes from horology: the escapement is the component that converts
stored energy into regular, measured ticks.

## Platform findings

These were established empirically against macOS 26.5.1 and drive the design.
They are recorded here because several contradict what the documentation
implies.

### Apple sanctions this use case

`man tmutil`, under `startbackup --auto`:

> The `--auto` option provides a supported mechanism with which to trigger
> "automatic-like" backups [...] it provides custom schedulers the ability to
> achieve some (but not all) behavior normally exhibited when operating in
> automatic mode.

### Backup frequency is a system-wide setting, not per-destination

`/Library/Preferences/com.apple.TimeMachine.plist` carries `AutoBackup` (bool)
and `AutoBackupInterval` (seconds) at the *top level*. Individual entries in
the `Destinations` array contain no automatic-backup or interval key of any
kind.

macOS therefore cannot place one destination on "Manually" and another on
"Every hour". "Manually" is all-or-nothing.

Consequence: Escapement treats manual mode as a global precondition. When
`AutoBackup` is on, the destination list is shown but scheduling is disabled,
behind an explanation and a button that opens Time Machine in System Settings.
Escapement never changes the setting itself — `tmutil enable`/`disable`
require root and Full Disk Access, and the backup frequency is the user's
system-wide decision to make.

### No elevated privileges are required to trigger a backup

`tmutil startbackup --destination <id>` run as an ordinary user starts a
backup. `stopbackup` likewise. Neither appears in the man page's list of verbs
requiring root and Full Disk Access, and both were confirmed to work
unprivileged.

Escapement needs no privileged helper, no `SMAppService.daemon`, no XPC
service, and no admin authorization prompt.

### `--auto` is throttled and unsuitable for custom schedules

Invoking `startbackup --auto` when the previous backup was recent produces, in
the unified log:

    backupd: Backup failed: BACKUP_DELAYED_NOT_ENOUGH_ELAPSED_TIME (107)

`--auto` submits to backupd's own elapsed-time policy, which is governed by
`AutoBackupInterval`. A user asking for a four-hour cadence on a system whose
interval is 86400 would simply get nothing.

Escapement therefore issues plain `startbackup --destination <id>`, which is
not throttled. The trade-off is that a plain start does not inherit every
automatic-mode behavior; that is the accepted cost of honouring the user's
stated schedule.

### `tmutil`'s exit code carries no information

In the throttled case above, `tmutil` exited **0** while backupd refused the
work. The command is fire-and-forget: it dispatches a request and returns.

Escapement must never treat exit 0 as "the backup succeeded". Outcome is
determined by observing `tmutil status` and, where richer detail is wanted,
the unified log subsystem `com.apple.TimeMachine`.

### `tmutil status` is the status source

While running it reports the fields the UI needs:

    BackupPhase = MountingDiskImage
    DestinationID = B2FFC925-...
    DestinationMountPoint = /Volumes/Backups of m1
    Percent = -1
    Running = 1

`Percent` is `-1` until a copying phase begins; the UI must render that as
indeterminate rather than 0%.

### Cancellation is not instant

After `stopbackup`, a network destination sat in `BackupPhase = Stopping` for
roughly 30 seconds before returning to `Running = 0`. `Stopping` is a real
state the UI models and displays; it is not an instant transition.

### Avoiding Full Disk Access

Reading `com.apple.TimeMachine.plist` directly requires Full Disk Access.
`tmutil destinationinfo -X` returns the destination list without it.

Escapement prefers the `tmutil` surface so that it works on a clean install
with no privacy prompts, and records its own run history rather than mining
Apple's plist for it. Full Disk Access remains an optional enhancement, never
a requirement.

## Process shape

Three pieces, so that schedules still fire when the GUI is closed.

**EscapementKit** — a pure-logic library: the recurrence model, the next-fire
engine, configuration and history stores, and a protocol-fronted Time Machine
adapter. No AppKit, no I/O in the core paths. This is where the tests live.

**EscapementAgent** — a small, UI-less LaunchAgent registered through
`SMAppService.agent`, so it appears in Login Items & Extensions where a Mac
user expects to find and disable it. It owns the timer, fires backups, watches
for wake, and appends to the run history. It is the only writer of history.

**Escapement.app** — the AppKit front end. Main window is the status
viewport: each destination, its state, last run, next run. Settings holds
per-destination schedule editing. The app is a reader of state and a writer of
configuration; it never fires a backup on a timer itself.

Coordination is through files in `~/Library/Application Support/Escapement/`
rather than XPC: the app writes `configuration.json`, the agent watches it
with a `DispatchSource` file-system source; the agent writes `state.json` and
`history.json`, the app watches those. This keeps both processes trivially
testable and removes an entire class of connection-lifecycle bugs.

## Missed schedules

A run that comes due while the Mac is asleep or shut down fires shortly after
the agent next runs or the machine wakes, with a short debounce so that waking
to five overdue destinations does not start five simultaneous backups.

Escapement does not schedule wake-from-sleep power events. Doing so requires
root, and the resulting privileged helper is a poor trade for a utility this
small.
