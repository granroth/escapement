# Fixtures

Representative `tmutil` output from macOS 26.5.1. Hostnames, user names,
destination identifiers, timestamps, and backup measurements are replaced by
obvious example values. The quoting, key names, and dictionary shapes remain
as emitted because the parsers under test must cope with `tmutil`'s format,
not a tidied version of it.

| File | Captured from |
| --- | --- |
| `destinationinfo-two-destinations.plist` | `tmutil destinationinfo -X`, one network and one local destination |
| `destinationinfo-none.plist` | `tmutil destinationinfo -X` on a Mac with no destination configured (an empty dictionary) |
| `status-idle.txt` | `tmutil status` with no backup running |
| `status-mounting.txt` | `tmutil status` during `MountingDiskImage`, before any progress is known |
| `status-stopping.txt` | `tmutil status` after `stopbackup`, which persisted for roughly 30 seconds on a network destination |
| `status-copying.txt` | `tmutil status` during a multi-day local backup's `Copying` phase |

Note that `status-mounting.txt` and `status-stopping.txt` both carry
`Percent = "-1"` and `Running = 1`. Progress is genuinely unknown in those
phases and must render as indeterminate; `Stopping` is distinguished from
`MountingDiskImage` only by `BackupPhase`.

`status-copying.txt` preserves the nested-only `Progress` shape observed during
a long-running local backup while using synthetic identifiers and measurements.
