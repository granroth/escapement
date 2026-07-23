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
| `status-copying.txt` | **Synthesized**, not captured — see below |

Note that `status-mounting.txt` and `status-stopping.txt` both carry
`Percent = "-1"` and `Running = 1`. Progress is genuinely unknown in those
phases and must render as indeterminate; `Stopping` is distinguished from
`MountingDiskImage` only by `BackupPhase`.

`status-copying.txt` is the one fixture not captured live: the backup used to
probe the system was cancelled during `MountingDiskImage`, so no real
`Copying` sample exists. It is reconstructed from tmutil's documented shape —
a fractional top-level `Percent` plus a nested `Progress` dictionary — so the
parser is exercised against a real percentage and against the nested block it
must skip over without tripping. If a genuine capture is taken later, replace
this file with it.
