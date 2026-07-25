# Escapement

Schedule Time Machine backups on your own cadence.

macOS lets you back up automatically every hour, every day, every week — or
not at all. Escapement adds the option Apple left out: *whenever you say*.
Every night at 2:15. Weekdays only. The first of the month. A different
schedule for each backup disk.

An escapement is the part of a mechanical watch that turns stored energy into
regular, measured ticks. That is all this app does.

## What it does not do

Escapement does not create, configure, encrypt, or delete Time Machine
destinations, and it never touches your backup data. You set your backup disks
up the normal way, in System Settings. Escapement only decides when they run,
by asking Time Machine to start a backup at the moments you chose.

`man tmutil` describes this as a supported thing to build:

> The `--auto` option provides a supported mechanism with which to trigger
> "automatic-like" backups [...] it provides custom schedulers the ability to
> achieve some (but not all) behavior normally exhibited when operating in
> automatic mode.

## Requirements

- macOS 14 or later
- Time Machine's backup frequency set to **Manually** in System Settings

That second one is a real requirement, not a suggestion. macOS applies its
backup frequency system-wide — there is no per-disk setting — so if Apple's
scheduler is still running, both it and Escapement will be starting backups
and neither will be in charge. Escapement detects this and tells you, but it
will not change the setting for you: your system-wide backup policy is yours
to set.

Escapement needs no administrator password, installs no privileged helper, and
asks for no Full Disk Access.

## Status

Nominally working. The recurrence engine, Time Machine adapter, scheduling
core, run loop, and an AppKit status window and schedule editor are implemented
and tested; the app has been verified driving real backups on a live Mac.

One honest limitation for now: **scheduling runs while the app is open.**
Closing the window keeps it running in the Dock, but quitting it stops the
scheduler. Relaunch-at-login and a fully background agent are the next
refinement — the scheduling logic is already isolated in `EscapementKit` and
called identically either way, so that step is repackaging, not a rewrite. See
`docs/specs/005-app-ui.md` for what is deferred.

See `docs/ARCHITECTURE.md` for the design and the platform research behind it,
and `docs/specs/` for feature-by-feature specifications.

## Building

```sh
swift test                       # the EscapementKit test suite
scripts/build-app.sh release     # build and sign Escapement.app
swift scripts/make-icons.swift   # rebuild the icons after changing the art
```

The app builds from `swift build` plus a bundling script — there is no Xcode
project to drift out of sync. Signing uses a Developer ID; adjust the identity
in `scripts/build-app.sh` for your own.

The icons are committed, so the icon step is only needed when the art in
`App/Icon/` changes. Escapement ships two of them — a full-bleed bundle icon
and the free-form mark it installs as its Dock tile at launch — for the reasons
in `docs/specs/008-app-icon.md`.

## License

MIT. See `LICENSE`.
