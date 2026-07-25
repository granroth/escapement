# Spec 008 — The app icon

Status: implemented and verified live (bundle icon renders full-size on its own
ground in Finder; Dock tile and ⌘-Tab switcher show the free-form wheel;
`codesign --verify --strict` and the Developer ID signature unaffected)

## Purpose

Escapement's mark is a brass escape wheel with a ruby jewel bearing — a toothed
silhouette, not a rounded square. Ship it so the system never mangles it.

## The constraint

Since macOS Tahoe the system clips **every** app's bundle icon to its own
rounded-rect. This was verified empirically across a wide sample of installed
apps — old and new, Apple and third-party, from VLC and Wireshark to Xcode.
There were no exceptions, and no Info.plist key opts out.

What the clip does depends on the art:

| Bundle icon art | Result |
| --- | --- |
| Transparent background (free-form) | rescaled into a fixed inner box, composited onto a system-generated light-grey plate, with a second shadow |
| Opaque, full-bleed | corners rounded off; art keeps its full size, no plate |

The rescale is a fit to a fixed box, not a proportional shrink: synthetic art
filling anywhere from 5% to 95% of its canvas all came out at the same 54.7%
of the tile, so small art is *enlarged* as readily as large art is shrunk.
Escapement's wheel fills ~90% of its own canvas, so for this mark the fit
works out to about 65% of its original footprint — a property of this art, not
a system constant.

Opacity is what decides it, and the threshold is nearly absolute. Sweeping a
full-canvas background from alpha 0 to 255: at 252/255 the art is still shrunk
and plated, at 253/255 the plate vanishes entirely. Nothing short of ~99%
opaque escapes, so a near-transparent backing (alpha 1 or 8) buys nothing.

Two routes escape the clip entirely, and only one of them is usable:

- **A custom Finder icon** (an `Icon\r` file plus the `com.apple.FinderInfo`
  attribute, as `NSWorkspace.setIcon` writes) renders completely unmasked on
  every surface — but it breaks the signature. `codesign` refuses the bundle
  outright (*"resource fork, Finder information, or similar detritus not
  allowed"*) in either order, and `spctl` then rejects the app. Escapement
  ships Developer ID + Hardened Runtime, so this route is closed.
- **An icon set at runtime** (`NSApplication.applicationIconImage`) is exempt
  from the clip and costs the signature nothing.

## The design

Two icons, generated from one set of masters:

| File | Where it is used | Form |
| --- | --- | --- |
| `Escapement.icns` | `CFBundleIconFile` — Finder, Launchpad, Spotlight, the Dock while the app is not running | full-bleed, wheel on a near-black ground |
| `EscapementFreeform.icns` | installed as the app icon at launch — the Dock tile, the ⌘-Tab switcher, the About panel | the wheel alone, transparent |

The bundle icon draws its own ground so the system's clip lands inside artwork
we control. The wheel is never shrunk, never plated, and never given the second
shadow; the result is the app's own rounded-rect rather than a generated one.
The ground is a subtle radial ramp, `#1a140e` at the centre to `#0d0a06` at the
corners, drawn from the mark's own outline colour so wheel and ground stay in
one material family.

`AppIcon.installFreeformDockIcon()` runs in `main.swift` *before*
`NSApplication.run()`, so the Dock tile is the free-form wheel from the first
frame rather than visibly changing shape after launch. If the resource is
missing it leaves the bundle icon in place; `scripts/build-app.sh` treats a
missing icon as a build error, so that path is unreachable in a real bundle.

Setting the runtime icon does **not** cover every surface that draws the app's
icon: the standard About panel resolves the *bundle* icon and so showed the
full-bleed one. It does no clipping of its own, so `AppDelegate.showAbout`
passes `AppIcon.freeform` as the panel's `applicationIcon` and the wheel
appears as drawn. Anything else that grows its own icon-drawing surface should
do the same.

A caveat for anyone re-verifying this: `NSRunningApplication.icon` and the
`NSWorkspace` icon lookups do *not* reflect a live `applicationIconImage`
override — they keep returning the system-clipped bundle render. Only a real
Dock screenshot shows what is actually on screen.

## Generating

`swift scripts/make-icons.swift`, run from the repository root, rebuilds both
`.icns` files from `App/Icon/freeform/` and is the only step that needs
re-running when the art changes. The results are committed, so an ordinary
build stays a plain `swift build` plus `build-app.sh`.

The masters are hand-tuned per size — 16 and 32 px come from a simplified small
master with fatter teeth, heavier spokes and no fine bevel lines — so each size
is composited at its own resolution rather than downscaled from 1024. The art
is already inset a little from the canvas (unevenly, roughly 2–7% depending on
the edge, since the shadow falls low and right), which reads as a correct
optical margin once the corners are rounded off.

`App/Icon/` also carries the SVG masters, including a shadowless flat mark for
marketing and print, which nothing in the build consumes.
