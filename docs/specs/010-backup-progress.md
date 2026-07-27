# Spec 010 — Detailed backup progress

Status: implemented

## Purpose

Show the useful progress Time Machine already reports while a backup is
running: completion percentage, bytes copied, and its approximate remaining
time. Escapement reads this state; it does not inspect backup data or calculate
its own competing estimate.

## Source and compatibility

`tmutil status` remains the sole live status source. On macOS 26.5.1 a copying
backup reports a nested dictionary:

    Progress = {
        Percent = "0.02497832746480003";
        TimeRemaining = "452949.0753096844";
        bytes = 10750128128;
        files = 170;
        totalBytes = 2191954460672;
        totalFiles = 5451403;
    };

Older observed output also carries `Percent` at the top level. Parse both
shapes, preferring the nested value when it is valid. Every progress field is
optional because Time Machine omits or withholds estimates during some phases.
Malformed, negative, non-finite, and out-of-range values degrade to unknown
rather than failing the entire status read.

The model records:

- fraction complete, clamped to `0...1`;
- bytes and total bytes, when non-negative;
- files and total files, when non-negative;
- remaining seconds, when finite and non-negative.

The projected totals are retained because they are part of the same status
snapshot and useful for diagnostics, but the first UI does not display them.
`FractionOfProgressBar` and `_raw_*` fields are private implementation details
and are ignored.

## Presentation

While copying, a destination row shows:

- the phase and whole-number percentage when known;
- the existing determinate progress bar when a fraction is known, otherwise
  the existing indeterminate indicator;
- a secondary detail line containing the copied byte count and Time Machine's
  approximate remaining time when either is known.

Examples:

    Copying — 2%
    10.75 GB copied — About 5 days remaining

    Copying
    About 8 minutes remaining

Use `ByteCountFormatter` with decimal file-size units and locale-aware
`DateComponentsFormatter`-style units. Prefix the estimate with “About” because
Time Machine revises it as sizing and throughput change. Do not derive an ETA
from bytes, percentage, or elapsed time.

The menu bar extra remains compact: it shows phase and percentage, not bytes or
ETA.

## Verification

- Replace the synthesized Copying fixture with sanitized output captured from
  the live “Time Machine 5TB” backup.
- Test nested current output, legacy top-level percentage, absent progress,
  malformed metrics, and clamping.
- Build and install the signed app, then verify its row against live
  `tmutil status` without stopping or restarting the backup.
