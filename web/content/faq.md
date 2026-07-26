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

It's signed with a Developer ID and notarized by Apple, and contains no
networking code at all: no analytics, no update check, no accounts.

## Do backups run when the app is closed?

Yes. A background agent keeps the schedule; the app is just the window you open
to change it.

## What happens if my Mac is asleep at the scheduled time?

The run fires shortly after it wakes, with a brief delay so that several overdue
destinations don't all start at once. Escapement won't wake your Mac to take a
backup — that needs root and a privileged helper.

## What can't it do yet?

- A backup you stop by hand is recorded as completed rather than cancelled. The
  outcome is inferred from Time Machine's status, and from outside the two look
  alike.
- There's no per-destination log window. History is recorded and the last run is
  shown, but there's no viewer for it.
- The editor sets one time of day per destination, though the engine supports
  several.
- Hourly windows can't cross midnight.

## What does it cost, and where's the source?

Nothing, and on [GitHub](https://github.com/granroth/escapement) under the MIT
license, along with the architecture notes and a specification for every
feature. Bugs and requests go in
[the issue tracker](https://github.com/granroth/escapement/issues).
