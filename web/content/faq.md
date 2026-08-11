+++
title = "Questions"
description = "Whether Escapement replaces Time Machine, why backup frequency has to be Manually, what permissions it needs, and what it can't do yet."
path = "faq"
template = "page.html"

[extra]
eyebrow = "Frequently asked"
lede = "The questions worth asking before letting something schedule your backups."
+++

## Does it replace Time Machine?

No. Time Machine does the backing up, to the destinations you set up, in its
usual format. Escapement supplies the timing. Remove it and your backups are
untouched.

## Why does backup frequency have to be Manually?

Because macOS keeps one backup frequency for the whole system. It isn't stored
per destination, so you can't leave one disk on Apple's schedule and hand
another to Escapement. With Apple's scheduler still on, two schedulers are
starting backups on the same disks.

Escapement shows a banner when it can see the conflict, but the banner is a
warning rather than a guard — it doesn't disable the editor or stop the agent.
[How to set it →](../docs/#setting-time-machine-to-manually)

## Does it need my administrator password, or Full Disk Access?

Neither. Starting and stopping a backup needs no elevated privileges, so there's
no helper tool, no root daemon, and no authorization prompt.

Full Disk Access is optional. It buys one thing: reading Time Machine's
preferences to confirm whether Apple's scheduler is on. Escapement offers it
once, on first run, and works fine if you decline.
[More on that →](../docs/#full-disk-access-optional)

## Can it damage my backups?

It never reads, writes, moves, or deletes backup data, and has no code that
does. It doesn't create or delete destinations either. It makes the same "start
a backup now" request you could type into Terminal.

It's signed with a Developer ID and notarized by Apple. It has no analytics
and no accounts, and makes exactly one kind of network request — an optional
check of GitHub's release page for a newer version, covered next.

## Does it check for updates?

Optionally, and it's the one exception to Escapement otherwise never touching
the network at all — worth being upfront about rather than quietly adding.

Settings has a **Check for Updates** frequency: Never, On Startup, Daily,
Weekly, or Monthly, plus a **Check Now** button. It defaults to On Startup,
because Escapement is likely to be feature-complete soon after 1.0 —
after that, releases will mostly be rare, critical fixes for a `tmutil` or
macOS change, exactly the kind of update a "check GitHub yourself" habit
tends to miss.

A check asks GitHub which release is newest and compares it against the
version you're running. Nothing is ever downloaded or installed — a newer
version only ever produces a notification and a link to its release page,
which opens in your browser. Turning the frequency to Never disables it
entirely, including the check when the background agent starts; **Check
Now** still works, since that's a request you made yourself.

## Do backups run when the app is closed?

Yes. A background agent keeps the schedule; the app is just the window you open
to change it.

## What happens if my Mac is asleep at the scheduled time?

The run fires shortly after it wakes, with a brief delay so that several overdue
destinations don't all start at once. Escapement won't wake your Mac to take a
backup — that needs root and a privileged helper.

## What happens if a backup runs long and blocks another destination?

Time Machine only runs one backup at a time, so the second destination waits.
It isn't skipped invisibly: Escapement records it once and shows what it's
waiting on. When the slot frees, whichever destination has waited longest goes
first.

If the running backup is actually stuck rather than just slow, Escapement
stops it after two hours of no progress so the wait ends. A backup that's slow
but still moving keeps the slot until it finishes — there's no cutoff for that
case.
[More on that →](../docs/#one-backup-at-a-time)

## What can't it do yet?

- There's no per-destination log window. History is recorded and the last run is
  shown, but there's no viewer for it.
- The editor sets one time of day per destination, though the engine supports
  several.

## What does it cost, and where's the source?

Nothing, and on [GitHub](https://github.com/granroth/escapement) under the MIT
license, along with the architecture notes and a specification for every
feature. Bugs and requests go in
[the issue tracker](https://github.com/granroth/escapement/issues).
