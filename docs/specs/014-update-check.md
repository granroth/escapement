# Spec 014 — Checking for updates

Status: draft

## Problem

Escapement will likely be feature-complete at v1.0. After that, releases will
be rare and mostly critical — a security fix, or a fix for a `tmutil`/Time
Machine behaviour change on a new macOS version. Rare-but-critical is the
worst combination for "check GitHub yourself": nothing trains the habit, so
nobody looks, and the releases that matter most are exactly the ones a user
won't notice by accident. A user running a year-old build with a known
`tmutil` incompatibility, silently failing every night, is a worse outcome
than the one piece of network code this adds.

## Behaviour

**One exception to "no network," and it is documented, not hidden.** Escapement
makes exactly one kind of outbound request: a check of GitHub's release API
for the latest published release tag. Nothing is ever downloaded or executed
as a result — a match only ever produces a version string and a link to a
GitHub release page.

- Settings gains a fourth preference, **Check for Updates**, alongside the
  existing three:
  - A dropdown: **Never**, **On Startup** (default), **Daily**, **Weekly**,
    **Monthly**.
  - A **Check Now** button.
  - A status line: `Last check: <relative time>`, or `Never checked` before
    the first one. When a newer release is known, it reads e.g. `Escapement
    1.1.0 is available` with a link to the GitHub release.
- **On Startup** means once per agent process launch (i.e. roughly once per
  login, since the agent is a `KeepAlive` LaunchAgent), not once per GUI
  launch — the GUI is not guaranteed to run at all, and the whole point of
  this feature is reaching the user who never opens it.
- **Daily / Weekly / Monthly** are evaluated against wall-clock time elapsed
  since the last check, independent of whether the agent restarted in
  between. Monthly is approximated as 30 days rather than a calendar month —
  precision doesn't matter for a background check this infrequent.
- **Check Now** always runs immediately, regardless of the configured
  interval or when the last check happened.
- **Never** disables both the scheduled checks and the startup check. Check
  Now still works — it is an explicit user action, not a background one.
- When a check finds a newer published release, the agent posts a native
  notification ("Escapement 1.1.0 is available") using the same
  `UNUserNotificationCenter` pattern already shipped for failure
  notifications (`notifiesOnFailure`), so it reaches the user without the GUI
  being open at all. Clicking it opens the release page in the default
  browser — not the app.
- The Settings status line is the fallback channel and does not depend on
  notification permission: it reflects the last check's outcome whenever
  Settings is opened, whether or not the user ever granted notification
  permission. Unlike `notifiesOnFailure`, denial of notification permission
  does not disable the feature — there is no failure mode where the user
  learns nothing, only one where they have to open the app to find out.
- A version is only ever reported once by notification: repeated checks that
  keep finding the same already-known release do not re-notify. A newer
  release than the last-known one notifies again; a check that finds nothing
  newer clears any previously reported available update (e.g. the user
  already installed it).
- A failed check (offline, GitHub unreachable, malformed response) stamps
  the last-checked time so it doesn't retry every tick, but leaves any
  previously known available update untouched — a transient failure must not
  erase a real result.

## Design

**All new state follows the existing single-writer files.**

- `Configuration` (GUI-owned) gains `updateCheckInterval: UpdateCheckInterval`,
  defaulting to `.onStartup`, decoded the same backward-compatible way as
  `notifiesOnFailure` — a file predating the key decodes as the default
  rather than failing.
- `AgentState` (agent-owned) gains `lastUpdateCheck: Date?` and
  `availableUpdate: AvailableUpdate?` (`version: String`, `releaseURL: URL`).
  Two mutators: `recordUpdateCheck(at:availableUpdate:)` for a successful
  check (always overwrites `availableUpdate`, including to `nil`), and
  `recordFailedUpdateCheck(at:)` for a failed one (stamps the timestamp only).
- `AgentCommand` gains `.checkForUpdatesNow`, following the existing
  `backUpNow`/`stop`/`pause`/`resume` one-shot pattern: the GUI posts it via
  `command.json`, the agent drains and acts on it in `processCommands()`.

**The network call is isolated behind a protocol, like `TMUtilController`.**
`EscapementKit` gets a new `UpdateSource` protocol (one method: fetch the
latest release's tag and URL) and an `UpdateChecker` that takes an
`UpdateSource` and a current version string and returns the comparison
result. This is pure, testable logic with no I/O — version parsing,
comparison, and the "is a check due" scheduling math all live here and are
covered by `EscapementKitTests`, the same way `SchedulerRunner` is tested
against a fake `TMUtilController` rather than real `tmutil`.

The one real implementation of `UpdateSource` — an actual `URLSession`
request to `https://api.github.com/repos/granroth/escapement/releases/latest`
— lives in `EscapementAgent`, the only place in the whole app that ever
touches the network. It cannot be `@testable`-imported any more than
`TMUtilController`'s live implementation can, so it is verified by tracing
and by driving the real agent, not by unit test.

**Wiring into the agent's tick.** `AgentService.start()` performs the startup
check (if the interval isn't `.never`); `tick()` additionally checks
`UpdateCheckScheduling.isDue` each pass for the daily/weekly/monthly cases;
`processCommands()` handles `.checkForUpdatesNow` unconditionally. All three
paths converge on one `performUpdateCheck()` that loads `Configuration` and
`AgentState`, calls `UpdateChecker`, writes the result via `StateStore`, and
posts a notification only when the found version differs from the
previously known one.

**Current version** is read from the agent's own `Bundle.main` (`CFBundleShortVersionString`), the same value the release pipeline stamps into
both `Info.plist` files from the git tag — no cross-process read needed.

## Out of scope

Downloading or installing anything. Auto-restart after an update. Release
notes / changelog display beyond the version number and a link. Checking for
pre-release or draft versions — the `/releases/latest` endpoint only ever
returns a published, non-draft, non-prerelease release, which is exactly
what should be offered.

## Verification

`EscapementKitTests` covers, against a fake `UpdateSource`:

1. A newer release tag than the current version produces an `AvailableUpdate`.
2. An equal or older release tag produces `nil`.
3. An unparseable tag (missing a component, non-numeric) produces `nil`
   rather than throwing.
4. `UpdateCheckScheduling.isDue` for each interval: `.never`/`.onStartup`
   always `false`; `.daily`/`.weekly`/`.monthly` `false` before their window
   elapses and `true` at/after it; every interval `true` when
   `lastCheckedAt` is `nil`.
5. `AgentState.recordUpdateCheck` overwrites `availableUpdate` including to
   `nil`; `recordFailedUpdateCheck` stamps the timestamp and leaves
   `availableUpdate` untouched.
6. `Configuration` decodes a file with no `updateCheckInterval` key as
   `.onStartup`.

The agent-side network call and notification, and the Settings UI, are
verified in the signed application per project convention:

1. Build and install. Confirm Settings shows the new row with **On Startup**
   selected by default on a fresh configuration.
2. Point the agent at a fake older `CFBundleShortVersionString` (or a test
   endpoint) and confirm **Check Now** produces a notification and updates
   the status line to name the available version and link to it.
3. Confirm a second **Check Now** against the same known release does not
   post a second notification.
4. Deny notification permission and confirm the status line still reports
   the available update correctly — the feature must not depend on it.
5. Set the interval to **Never**, confirm no automatic check happens across a
   restart, and confirm **Check Now** still works.
6. Quit network access (e.g. Wi-Fi off) and confirm a check fails silently —
   no crash, no dialog, `Last check` still updates — and that a previously
   known available update is not cleared by the failure.
