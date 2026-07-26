# Spec 009 — Managing the background agent

Status: draft

## Purpose

Spec 007 gave Escapement a background agent that fires schedules with the GUI
closed. It did not give the user any way to *govern* it. Once registered the
agent is invisible (`.prohibited` activation policy), immortal (`KeepAlive`
restarts it the instant it is killed), and switchable only through a heavyweight
`SMAppService.unregister()` buried in the Schedule menu. In practice the only
ways to stop it are Activity Monitor — which does not work, because launchd
brings it straight back — or `launchctl bootout` from a terminal.

That is the wrong deal to offer. If the app is going to run something in the
background, the user must be able to see that it is running, tell what it is
about to do, and stop it without a terminal.

## Shape

**A menu bar extra, owned by the agent.** Time Machine's own menu bar item is
the idiom macOS already established for this exact job — is the backup thing
alive, when is the next one, back up now, stop — and Escapement's users arrive
with that mental model. Putting the status item in the *agent* rather than the
GUI makes it honest: the agent is the only process that can run a backup, so

> the icon is present exactly when something is scheduled to happen.

No extra status channel is needed to keep the indicator truthful; presence is
the indicator. The GUI keeps its current lifecycle (a regular app, launched on
demand, quitting when its window closes).

The agent already runs an `NSApplication` with a main run loop for wake
notifications, so this is an activation-policy change plus a status item that
reads the stores the agent already owns.

## The menu

```
Next backup: Backups at 3:00 PM        (or "Backing up… 42%" while running)
Latest backup: Today at 9:00 AM
─────────────────────────────────
Back Up Now                     ▸      (submenu only when >1 destination)
Stop Backup
─────────────────────────────────
Pause Backups                   ▸      1 hour / 4 hours / Until tomorrow /
                                       Until I resume
─────────────────────────────────
Open Escapement
Turn Off Background Backups…
```

`Back Up Now` and `Stop Backup` are invoked directly, not through
`command.json`: the agent *is* the command's destination, so it calls
`SchedulerRunner` in-process. The command file remains the GUI→agent channel.

`Open Escapement` opens the containing app via `NSWorkspace.openApplication`.
The agent is its own nested bundle (see below), so the app is derived from
`Bundle.main` four levels up rather than being `Bundle.main` itself.

`Turn Off Background Backups…` confirms, then unregisters. The agent is
unregistering itself, which ends the process — acceptable, and the same thing
`launchctl bootout` does.

## Pause is a first-class state

The missing concept is a *soft* stop. Unregistering the agent tears down the
Login Items registration and may need re-approval to undo; it is the wrong tool
for "not for the next two hours." So:

- A new agent-owned `AgentState`, persisted to `state.json`, gains
  `pausedUntil: Date?`. `nil` means running; a date in the future means paused
  until then; "until I resume" is a distant sentinel date.

  **Not** in `Configuration`, as an earlier draft of this spec had it. The file
  lock in `JSONFileStore` is per-process and cannot serialise the GUI against
  the agent, so the single-writer rule is the only thing keeping the two from
  clobbering each other. Pause has to be settable from the agent's own menu bar
  extra, so putting it in the GUI-owned configuration file would let a pause and
  a schedule edit race on the same read-modify-write and lose one. The GUI
  therefore asks for a pause through `AgentCommand` instead, and the agent — the
  sole writer of `state.json` — applies it.
- `SchedulerRunner` skips *scheduled* fires while paused, and `nextWakeUp()`
  returns the pause expiry when that comes first, so the agent wakes and resumes
  on its own.
- A **manual** `Back Up Now` still runs while paused. Pausing suppresses the
  schedule, not the user.
- Pause survives restarts and login, because it is persisted rather than held in
  memory.
- Decoding is backward compatible: a state file without the key decodes as not
  paused, matching how `schemaVersion` was added.

Pause state is shown in both surfaces: the menu bar item's header line and the
GUI's status banner.

## Settings

A real Settings window (`⌘,`), deliberately small, holding the things that are
preferences rather than verbs:

- **Background backups** — the master on/off, with honest status text
  (`Enabled` / `Waiting for approval` / `Off`), replacing the Schedule menu's
  pair of items where one is always disabled. A persistent master switch is a
  preference, not a command.
- **Show menu bar icon** — a menu bar item the user cannot hide is un-Mac-like.
  This is also the only way to get it back, so it lives here rather than in the
  menu it would remove.
- **Notify me when a backup fails** — the background thing being accountable
  without the user watching it.

The `Enable/Disable Background Backups` items are removed from the Schedule
menu, which goes back to holding only verbs.

## The agent is its own bundle

The agent is a nested application at
`Contents/Library/LoginItems/EscapementAgent.app`, with its own identifier
`com.granroth.Escapement.Agent` and `LSUIElement`, rather than a bare executable
in `Contents/MacOS`. The LaunchAgent plist's `BundleProgram` points into it, so
`RunAtLoad` and `KeepAlive` still apply.

This is not tidiness. As a bare executable its `Bundle.main` was the *app's*
bundle, so it registered with LaunchServices under `com.granroth.Escapement` —
the same identifier as the GUI. Both consequences were observed on hardware:

- **Quit AppleEvents addressed to the app terminated the agent.** A single
  `tell application "Escapement" to quit`, with the GUI not running at all,
  stopped the scheduler.
- **"Open Escapement" could not open Escapement.** With the agent running,
  asking LaunchServices to open the app found an existing instance for that
  identifier and activated *the agent* — an `.accessory` process with no
  window. A Dock icon and an app-switcher entry appeared showing the bundle
  squircle, no window ever came up, and the free-form Dock icon never replaced
  it because the GUI, which installs it at launch, had never started.

With a distinct identifier both are gone: the quit event leaves the agent's
process untouched, and Open Escapement launches the GUI.

Because `Bundle.main` is now the agent's own bundle, the containing app is
derived four levels up rather than assumed. The agent also carries its own copy
of the launchd plist: `SMAppService.agent(plistName:)` resolves that path
against the *calling* process's bundle, so without it the agent's own "Turn Off
Background Backups" fails with "Invalid argument".

## The menu bar icon is a template image

Menu bar extras are template images by long-standing convention: only the alpha
channel matters, and the system renders it dark, light, or dimmed to match the
bar's appearance and the highlight when the menu is open. A full-colour icon
does none of that and reads as foreign beside every other extra.

The shape cannot be taken from the app icon's alpha, which is a solid toothed
disc — the spokes and hub are interior detail, so its silhouette is a blob. So
the wheel is redrawn from the same geometry the art uses: twelve teeth on a 30°
pitch, each an arc along the body, a curve out to a sharp tip, and a straight
flank back down. Drawn rather than shipped as a bitmap, so it stays crisp at any
scale.

The interior is deliberately coarser than the art. On a display at a backing
scale of 1 the icon is 18 *pixels*, where the art's true rim, spokes and jewel
all fall near a single pixel and smear into a grey disc.
Spokes were tried and dropped: even four heavy ones read as a bold "+" over a
rim too thin to survive, which in the real menu bar looked like an asterisk. A
thick toothed rim around an open bore with a solid arbor reads correctly at a
glance, and the asymmetric escapement teeth keep it from being a cog.

## `KeepAlive` stays unconditional — a change that was tried and reverted

The original plan here was to weaken `KeepAlive` to
`{ SuccessfulExit: false }`, reasoning that launchd's unconditional restart was
the mechanical reason the agent could not be stopped, and that a deliberate
`exit(0)` ought to stick.

That was wrong twice over, and testing found it:

1. **Nothing needs it.** The controls this milestone adds do not stop the agent
   by exiting it. Pause is a state the *running* agent honours, and Turn Off
   unregisters the job outright, which removes it from launchd regardless of
   `KeepAlive`. No deliberate-exit path survived into the design.
2. **It turned any stray termination into a silent, permanent stop.** This was
   found through the bundle-identifier bug above: while the agent still answered
   to the app's identifier, a quit AppleEvent killed it and the weakened
   `KeepAlive` meant nothing restarted it. That root cause is now fixed, but the
   lesson stands — a scheduler that can be stopped without anyone noticing is
   the exact failure this milestone exists to prevent, and unconditional
   restart is cheap insurance against every other way a process can die.

So `KeepAlive` stays `true`. "The user can stop it" is delivered by Pause and
Turn Off — real controls with real feedback — not by making the process
killable.

## Risks proved empirically before building on them

Both were spiked on real hardware first, because the whole design rests on the
first one.

1. **A launchd-started helper showing an `NSStatusItem` — confirmed.** With the
   agent set to `.accessory` and installed at `/Applications/Escapement.app`,
   registering it through `SMAppService` had launchd start the agent, and the
   accessibility tree reported `EscapementAgent` owning a menu bar item; pressing
   it opened its menu. The status item belongs to the launchd-started process,
   not to the GUI.
2. **Two `NSApplication` processes from one bundle — confirmed.** The GUI
   (`.regular`) and the agent (`.accessory`) ran simultaneously without
   contention, and only the GUI is a foreground application: the agent reports
   as background-only, so it has a menu bar item and no Dock tile. Activation
   policy is set at runtime by each process, so no `Info.plist` change is
   involved and the GUI is unaffected.

Still unproven: start **at login** specifically. The spike registered the agent
mid-session, which puts launchd in the same `gui/$UID` domain by the same
mechanism `RunAtLoad` uses, so the risk is low — but it has not been observed
through an actual logout/login cycle, and should be before this ships.

## Interaction with the known `SMAppService` limitation

Spec 007 recorded that rebuilding the app while the agent is registered blocks
the new build (code-signing hash mismatch). That gets more visible once the
agent has a face: a stale agent would sit in the menu bar showing stale state
from the old binary. This milestone should therefore also take the backlog item
007 deferred — re-register the agent on GUI launch when it is already enabled —
so an updated app reconciles itself instead of leaving a zombie in the menu bar.

## Out of scope

Progress in the menu bar icon itself (the item shows a static symbol; progress
is text in the menu). Per-destination pause — pause is global, matching the
system-wide nature of Time Machine's own scheduling flag.
