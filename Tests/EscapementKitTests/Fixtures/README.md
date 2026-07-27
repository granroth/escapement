# Fixtures

Real `tmutil` output, captured from macOS 26.5.1, with hostnames and user
names replaced by `example` / `user`. Nothing else has been reformatted —
including the quoting and the `attemptOptions` key — because the parsers under
test have to cope with exactly what `tmutil` emits, not with a tidied version
of it.

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

`status-copying.txt` was captured during a long-running backup to a local
destination. Its volume name was replaced with `example`; numeric values and
the nested-only `Progress` shape are otherwise unchanged.
