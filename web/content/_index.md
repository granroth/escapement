+++
title = "Escapement"
template = "index.html"

[extra]
headline = "Time Machine backups,<br>on your schedule."
lede = "macOS backs up every hour, every day, every week, or not at all. Escapement adds the option Apple left out: whenever you say."
facts = ["macOS 14 or later", "Universal", "Notarized", "Free and open source"]
screenshot_alt = "The Escapement window: two Time Machine destinations, one idle and one copying, beside the schedule editor for the selected disk."

frequencies_title = "Four frequencies, one per disk"
frequencies_lede = "Hourly, daily, weekly, monthly. Escapement summarises what you set like this:"
examples = [
  "Daily at 2:15 AM",
  "Weekdays at 7:00 AM",
  "Every 4 hours at :00 from 9:00 AM to 6:00 PM",
  "Every 2 days at 12:00 AM",
  "Monthly on the 1st and 15th at 3:00 AM",
  "Weekends at 11:00 PM",
]

cta_title = "Back up when it suits you"
cta_body = "Free, open source, about five megabytes."

[[extra.features]]
icon = "disk"
title = "One schedule per disk"
body = "macOS applies a single backup frequency to every destination. Escapement gives each disk its own: the local SSD every few hours, the network share once a night."

[[extra.features]]
icon = "clock"
title = "Runs with the app closed"
body = "A background agent keeps the schedule and registers in Login Items & Extensions, where you would expect to find it. Open the app to change something, then close it again."

[[extra.features]]
icon = "pause"
title = "Pause without uninstalling"
body = "Quiet the schedule for an hour, until tomorrow, or until you say otherwise. Back Up Now still works while it is paused, and the pause survives a restart."

[[extra.features]]
icon = "shield"
title = "Nothing privileged"
body = "No administrator password, no helper tool, no Full Disk Access required. Escapement starts a backup the same way you could from a terminal."
+++

## What Escapement doesn't do

It doesn't create, configure, encrypt, or delete Time Machine destinations, and
it never touches backup data. You set your disks up in System Settings as usual.
Escapement decides when they run.

It won't change your system settings for you either. When one of them conflicts
with what you've asked for, it says so and points at the right pane. The
decision stays yours.

Apple documents this use case. From `man tmutil`:

> The `--auto` option provides a supported mechanism with which to trigger
> "automatic-like" backups [...] it provides custom schedulers the ability to
> achieve some (but not all) behavior normally exhibited when operating in
> automatic mode.
