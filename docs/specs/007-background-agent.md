# Spec 007 — The background agent

Status: implemented and verified live (agent registered, fired an overdue
schedule with the GUI closed, stopped via the command channel, unregistered)

## Purpose

Fire scheduled backups even when the GUI is closed. A small headless
`LaunchAgent`, registered through `SMAppService.agent`, owns the scheduler and
runs whenever the user is logged in. This realises the split
`ARCHITECTURE.md` designed for from the start; the scheduling logic already
lives in `EscapementKit` and is called identically, so this is packaging, not a
rewrite.

## Ownership

The agent is the single scheduler and the single thing that invokes
`tmutil startbackup` / `stopbackup`. It is the sole writer of the run history.
The GUI never fires a scheduled backup and never writes history; it edits the
configuration, shows status, and asks the agent to run a manual backup.

Enabling the agent is therefore required for any schedule to run. The GUI makes
this state plain and offers to enable it; until then, schedules are configured
but dormant.

Both processes may *read* Time Machine state (`destinationinfo`, `status`) — a
read is harmless and lets the GUI show destinations before the agent is
enabled. Only the *write* verbs are single-owner.

## Coordination (files, not XPC)

Under `~/Library/Application Support/Escapement/`:

| File | Writer | Reader | Purpose |
| --- | --- | --- | --- |
| `configuration.json` | GUI | agent | the schedules |
| `history.json` | agent | GUI | run history |
| `command.json` | GUI | agent | a pending manual command |

`command.json` holds one `AgentCommand` — `backUpNow(destinationID:)` or
`stop`. The GUI writes it atomically; the agent processes it and deletes the
file. One command at a time is sufficient for user-paced manual actions; a
command issued while another is unprocessed overwrites it, which is acceptable
for a start/stop a person clicks by hand.

XPC is deliberately avoided (per `ARCHITECTURE.md`): file coordination keeps
both processes trivially testable and removes connection-lifecycle bugs. The
GUI learns whether the agent is enabled from `SMAppService.status`, not a file.

## The agent process

A UI-less executable, `EscapementAgent`, bundled in the app at
`Contents/MacOS/EscapementAgent`, with a LaunchAgent plist at
`Contents/Library/LaunchAgents/com.granroth.Escapement.Agent.plist`
(`RunAtLoad`, `KeepAlive`). It:

1. Builds the same `SchedulerRunner` the GUI used, over the shared stores.
2. Arms a timer for `runner.nextWakeUp()`, re-arming after each evaluation, with
   a periodic safety tick so a missed wake-up is still caught.
3. Observes `NSWorkspace.didWakeNotification` and re-evaluates after a short
   debounce, so a machine waking to overdue schedules settles before firing.
4. Watches `configuration.json` and `command.json` for changes and re-evaluates
   / executes promptly.
5. Sets its activation policy to `.prohibited` so it has AppKit's run loop (for
   wake notifications) without any Dock or menu-bar presence.

The agent runs `startbackup` plainly (never `--auto`, which is throttled) and
treats `tmutil`'s exit code as meaningless, exactly as the adapter already
does.

## Registration and location

`SMAppService.agent(plistName:)` registers the bundled LaunchAgent. launchd
launches the agent from the app bundle's path, so the app must live somewhere
stable — in practice `/Applications`. Registration surfaces the app in System
Settings › General › Login Items, where the user can approve or disable it;
`SMAppService.status` reports `enabled` / `requiresApproval` / `notRegistered`,
which the GUI reflects.

## Out of scope (for this pass)

A per-command queue (single `command.json` is enough for now), and a
`state.json` agent→GUI channel (the GUI reads history and polls read-only
`tmutil status` for display, and `SMAppService.status` for agent state, so no
extra channel is needed yet).

## Known limitations found during verification

- **Updating the app while the agent is registered.** If the bundle is replaced
  (a rebuild, an update) while the previously-registered agent is still running
  the old binary, the new app's code-signing hash no longer matches the
  registration and launchd/LaunchServices refuses to launch the new app.
  Working around it during development means disabling background backups (or
  `launchctl bootout`-ing the agent) before replacing the bundle. A real update
  path — re-registering the agent on launch when already enabled, or an
  installer that unregisters first — is future work.
- **A manually-stopped background backup is recorded `completed`, not
  `cancelled`.** The stop command goes straight to `tmutil stopbackup`, so the
  runner only observes the backup going from running to idle and infers
  completion. Distinguishing a user stop would mean threading the cancel through
  the runner's open-run tracking. Low priority — outcome inference is
  documented as best-effort.
