# Working on Escapement

Guidance for AI coding agents. `CLAUDE.md` is a link to this file, so both
point at the same text.

Escapement schedules Time Machine backups on a user-defined cadence. It never
creates, configures, or deletes destinations and never touches backup data —
it only decides *when* `tmutil` is asked to start a backup.

## Layout

| Target | What it is |
| --- | --- |
| `EscapementKit` | All the logic: recurrence, scheduling, `tmutil` adapter, stores. Pure, testable, no AppKit. |
| `EscapementApp` | The GUI (AppKit, built in code — no xib, no storyboard). A viewer and configurator. |
| `EscapementAgent` | The background scheduler, a LaunchAgent. The only thing that fires backups. |

Design notes are in `docs/ARCHITECTURE.md`; every feature has a spec in
`docs/specs/NNN-*.md` with a `Status:` line.

## Commands

```sh
swift test                       # the EscapementKit suite
scripts/build-app.sh release     # build and sign .build/Escapement.app
swift scripts/make-icons.swift   # only after changing the art in App/Icon/
```

Set `ESCAPEMENT_SIGN_IDENTITY` to build under a different Developer ID rather
than editing the script.

There is no Xcode project on purpose — the whole app builds from `swift build`
plus the bundling script, so nothing can drift out of sync.

## Invariants that are easy to break

**One writer per file.** The GUI and the agent coordinate only through JSON
files in `~/Library/Application Support/Escapement/`, and each has exactly one
writer:

| File | Writer | Reader |
| --- | --- | --- |
| `configuration.json` | GUI | agent |
| `history.json` | agent | GUI |
| `state.json` | agent | GUI |
| `command.json` | GUI (posts) | agent (takes) |

This matters more than it looks. `JSONFileStore`'s lock is an in-process
`NSLock` — it cannot serialise the two processes. The single-writer rule is the
*only* thing preventing a lost update. If the agent needs to change something,
it goes in `state.json`; if the GUI wants that changed, it posts an
`AgentCommand`. Do not "simplify" this by having both write one file.

**The agent is a nested helper application** at
`Contents/Library/LoginItems/EscapementAgent.app`, with its own bundle
identifier. Do not flatten it back into `Contents/MacOS`. Sharing the app's
identifier makes LaunchServices deliver the app's quit AppleEvents to the agent
(terminating the scheduler) and makes "open the app" activate the windowless
agent instead of the GUI. Consequences worth remembering:

- `SMAppService.agent(plistName:)` resolves its path against the **calling**
  process's bundle, so the agent carries its own copy of the launchd plist.
  Without it, the agent's own "Turn Off" fails with "Invalid argument".
- `Bundle.main` in the agent is the *helper*, not the app. The containing app
  is four levels up.

**`KeepAlive` stays unconditional.** Nothing needs a clean exit to stick — Turn
Off unregisters the job outright, and Pause is a state the running agent
honours. Weakening it turns any stray termination into a silent, permanent stop
to scheduling.

**`SMAppService` behaves worse than its documentation suggests.** All observed
on real hardware:

- `register()` on an already-registered service re-submits the job — killing
  the running agent — and does *not* re-trigger `RunAtLoad`. Never re-register
  a healthy agent.
- `unregister()` is not immediate. Registering again too soon is a no-op
  against a record still reading `.enabled`, wedging the service.
- `status` can report `.enabled` while launchd has no such job at all. Status
  alone is not proof the agent will run; check for a live process too.

**Time Machine rules**, proven empirically and documented in
`docs/ARCHITECTURE.md`:

- Use plain `startbackup`. Never `--auto` — the system throttles it.
- `tmutil`'s exit code carries no information. Infer outcomes from
  `tmutil status` across ticks.
- Backup frequency (`AutoBackup`) is a **system-wide** flag, not per
  destination. The app detects a conflict and guides the user; it must never
  flip the setting itself.
- Triggering a backup needs no root and no privileged helper. The app is not
  sandboxed (it must exec `tmutil`) and ships hardened-runtime + Developer ID.

## How work is done here

Strict TDD: spec → failing test → implementation → passing test → review.
Write the spec in `docs/specs/` first, and confirm a new test fails for the
right reason before implementing.

Finish non-trivial work with an adversarial review: dimension-focused reviewers
over the diff, then verify each finding against the real code before fixing it.
Findings that do not survive tracing get dropped with the reasoning noted.

## Testing and verification

`EscapementKit` is unit-tested. The app and agent targets are executables and
cannot be `@testable`-imported, so their behaviour is verified by tracing and
by driving the real app.

Unit tests alone are not enough for anything user-visible. Build, install to
`/Applications`, and drive the real thing. Practicalities that cost time to
rediscover:

- A sleeping display makes System Events report **no windows**, which looks
  exactly like an app bug. Hold it awake (`caffeinate -u -t N`, backgrounded)
  before driving the UI.
- `launchctl bootout gui/$UID/com.granroth.Escapement.Agent` removes the
  service entirely — the cleanest dev reset, and it sidesteps the code-signing
  hash mismatch you get from replacing a bundle while its agent is registered.
- Screenshot the real Dock to check the icon. `NSRunningApplication.icon` and
  `NSWorkspace` lookups return the clipped bundle render and will mislead you.
- The app ships two icons on purpose — a full-bleed bundle icon that survives
  the system's rounded-rect clip, and the free-form mark installed at runtime.
  See `docs/specs/008-app-icon.md`.

## Scope

Escapement decides *when* backups run. It does not manage destinations, does
not change system settings on the user's behalf, and does not touch backup
data. Features that would cross those lines belong in System Settings, not
here.
