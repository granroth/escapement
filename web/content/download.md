+++
title = "Download"
description = "Download Escapement for macOS. Universal, notarized, free and open source. Requires macOS 14 or later."
path = "download"
template = "download.html"
+++

## Before you install

- **macOS 14 (Sonoma) or later.**
- **Time Machine already set up.** Escapement schedules the destinations you
  have; it doesn't create them.
- **Backup frequency set to Manually.** Required rather than recommended: macOS
  applies backup frequency system-wide, so leaving Apple's scheduler on means
  two schedulers running at once.
  [How to set it →](../docs/#setting-time-machine-to-manually)

Escapement needs no administrator password, installs no privileged helper, and
does not require Full Disk Access.

## Installing

1. **Open the disk image and drag Escapement to Applications.** Install it in
   `/Applications` rather than running it from the disk image — the background
   agent is registered from inside the app bundle.
2. **Set Time Machine's backup frequency to Manually**, under System Settings ›
   General › Time Machine › Options…
3. **Open Escapement and give a disk a schedule.** Select a destination, switch
   Enabled on, pick a frequency, click Apply. macOS may ask you to approve the
   background agent in Login Items & Extensions.

## Verifying the download

Each release ships a `.sha256` file alongside the disk image:

```sh
shasum -a 256 ~/Downloads/Escapement-*.dmg
```

Compare that against the `.sha256` file on the release page. Gatekeeper already
checks Apple's notarization when you first open the app.

## Building it yourself

```sh
git clone https://github.com/granroth/escapement.git
cd escapement
scripts/build-app.sh release
```

Full instructions, including code signing, are in the
[documentation](../docs/#building-from-source).

{% note(title="A word about version 0.1", plain=true) %}
Escapement has been verified driving real backups on a live Mac, but this is an
early release. It cannot touch your backup data — there's no code that does —
but keep an eye on it for the first week, and consider switching on failure
notifications in Settings.
{% end %}
