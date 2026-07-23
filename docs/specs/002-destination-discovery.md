# Spec 002 — Destination discovery and Time Machine state

Status: implemented

## Purpose

Learn which Time Machine destinations exist, whether the system is in the
manual mode Escapement requires, and what backupd is doing right now.

## Source of truth

`tmutil`, not `com.apple.TimeMachine.plist`. Reading the plist directly
requires Full Disk Access; `tmutil destinationinfo -X` does not, and returning
a clean install to a working state with no privacy prompt is worth more than
the extra fields the plist would give us.

### Destinations

`tmutil destinationinfo -X` emits a plist:

```
Destinations: [
  { ID, Name, Kind: "Local" | "Network", URL?, LastDestination? }
]
```

`ID` is the stable identifier passed to `startbackup --destination`. `URL` is
present only for network destinations. `LastDestination` marks the most
recently used one and is absent otherwise.

Modelled as:

    Destination { id: String, name: String, kind: .local | .network(URL?), isLastUsed: Bool }

Zero destinations is a normal state, not an error — it is what a Mac with
Time Machine never configured looks like, and the UI has an empty state for it.

### Manual-mode precondition

`AutoBackup` in the system preferences plist is the authority, but reading it
needs Full Disk Access. `tmutil destinationinfo` does not report it.

**Resolution (implemented):** no `tmutil` surface reports this flag, so
`TMUtilController` attempts an unprivileged read of the preferences plist and
resolves any failure — file missing, permission denied, key absent — to
`.unknown` rather than throwing. The result is the three-way
`AutomaticBackupState` (`.automatic` / `.manual` / `.unknown`).

The app must degrade gracefully to `.unknown` — it must never block scheduling
solely because it could not determine the mode. On a machine that has granted
Full Disk Access the read succeeds and returns the definite state; without it,
the softer `.unknown` caution is shown.

### Live status

`tmutil status` while a backup runs:

    BackupPhase, DestinationID, DestinationMountPoint, Percent, Running

Modelled as an enum, not a bag of optionals:

    BackupActivity
      .idle
      .running(destinationID: String?, phase: Phase, progress: Double?)
      .stopping(destinationID: String?)

Two rules from observed behaviour, both of which the UI depends on:

- `Percent` is `-1` until a copying phase begins. That maps to `progress: nil`
  and must render as an indeterminate indicator, never as 0%.
- `Stopping` persists for tens of seconds on network destinations. It is a
  first-class state with its own display, not a transient to be collapsed into
  `.idle`.

## Testability

The process boundary sits behind a protocol:

    protocol TimeMachineControlling {
        func destinations() async throws -> [Destination]
        func activity() async throws -> BackupActivity
        func startBackup(destinationID: String) async throws
        func stopBackup() async throws
    }

The real implementation shells out to `tmutil`. Tests drive parsing from
captured fixture output — real bytes from a real machine, checked in under
`Tests/Fixtures/` — so the parsers are tested without a Time Machine
destination or a live backup.

`startBackup` returning without throwing means only that the request was
dispatched. It is explicitly **not** a success signal: `tmutil` exits 0 even
when backupd rejects the work outright. Confirmation comes from observing
`activity()`, and the protocol's documentation must say so, because the
opposite assumption is the natural one.

## Out of scope

Deciding whether to start a backup, and recording that one happened. Spec 003
covers the agent's run loop and history.
