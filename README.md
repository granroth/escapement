<div align="center">

<img src="App/Icon/freeform/icon_256x256.png" alt="" width="132" height="132">

# Escapement

**Time Machine backups, on your schedule.**

[![CI](https://github.com/granroth/escapement/actions/workflows/ci.yml/badge.svg)](https://github.com/granroth/escapement/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/granroth/escapement?color=a0711b&label=release)](https://github.com/granroth/escapement/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-a0711b)](https://github.com/granroth/escapement/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-a0711b)](LICENSE)

[**Website**](https://granroth.com/escapement) &nbsp;·&nbsp;
[**Download**](https://github.com/granroth/escapement/releases/latest) &nbsp;·&nbsp;
[**Documentation**](https://granroth.com/escapement/docs.html) &nbsp;·&nbsp;
[**FAQ**](https://granroth.com/escapement/faq.html)

</div>

<br>

<img src="web/assets/screenshot-main.png" alt="Escapement's main window: a list of Time Machine destinations, one idle with a daily 3:00 AM schedule and one mid-backup showing live progress, beside the schedule editor for the selected disk.">

<br>

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

## Install

Download the latest `.dmg` from
[Releases](https://github.com/granroth/escapement/releases), open it, and drag
Escapement to Applications. The build is universal (Apple silicon and Intel)
and notarized by Apple, so it opens without a Gatekeeper warning.

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
does not require Full Disk Access. It offers Full Disk Access once, on first
run, purely so it can read Time Machine's preferences and warn you when macOS's
own scheduler is still on; declining costs you only that warning.

## Status

Working, and verified driving real backups on a live Mac.

Schedules are run by a small background agent, registered as a login item, so
they fire whether or not the app is open. The agent keeps a menu bar extra —
what is happening, when the last backup finished, back up now, stop, pause —
and the app itself is the window where destinations are configured. Turning
background backups on or off, hiding the menu bar icon, and failure
notifications all live in Settings.

Known limitations: a backup stopped by hand is recorded as completed rather
than cancelled, because the outcome is inferred from `tmutil status` rather
than reported; there is no per-destination detailed log window yet; the
schedule editor sets a single time of day, though the engine supports several;
and an hourly window cannot cross midnight. The conflict banner shown when
macOS's own scheduler is on is a warning, not a guard — it does not disable
editing or stop the agent.

See `docs/ARCHITECTURE.md` for the design and the platform research behind it,
and `docs/specs/` for feature-by-feature specifications.

## Building

```sh
swift test                       # the EscapementKit test suite
scripts/build-app.sh release     # build and sign Escapement.app
swift scripts/make-icons.swift   # rebuild the icons after changing the art
```

The app builds from `swift build` plus a bundling script — there is no Xcode
project to drift out of sync.

Signing uses a Developer ID. To build under your own identity, set
`ESCAPEMENT_SIGN_IDENTITY` rather than editing the script:

```sh
ESCAPEMENT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  scripts/build-app.sh release
```

The background agent is a nested helper application inside the bundle, so it is
signed first and the app around it second; both get the Hardened Runtime.

Add `ESCAPEMENT_UNIVERSAL=1` for a universal binary; releases always do. If the
configured signing identity is not in your keychain the build falls back to
ad-hoc signing, so a clean checkout always builds — but an ad-hoc app cannot
register its background agent, because `SMAppService` refuses one.

Releases are cut by pushing a `vMAJOR.MINOR.PATCH` tag; see
`docs/RELEASING.md`. Contributor guidance is in `AGENTS.md`.

The icons are committed, so the icon step is only needed when the art in
`App/Icon/` changes. Escapement ships two of them — a full-bleed bundle icon
and the free-form mark it installs as its Dock tile at launch — for the reasons
in `docs/specs/008-app-icon.md`.

## License

MIT. See `LICENSE`.
