# 019 — When macOS hides the menu bar icon

Status: implemented; suppression detection verified live on macOS 27 (see
"What was measured")

## The problem this fixes

Escapement's Settings has a checkbox, "Show Escapement in the menu bar", which
spec 009 made the only supported way to hide or restore the icon. macOS has its
own control over the same icon — the "Allow in the Menu Bar" list under Menu Bar
in System Settings — and it wins.

When the system's list denies Escapement, the icon does not appear, and nothing
in Escapement knows. The checkbox stays ticked, Settings goes on claiming the
icon is shown, and the user is left with a preference that visibly disagrees
with their menu bar and no indication why. That is the defect: not that macOS
can hide the icon, which is entirely its right, but that Escapement cannot tell
and therefore says something false.

A related failure motivated the original fix in this area: on macOS 27 the icon
did not appear *at all*, and setting `isVisible` explicitly on the created item
is what puts it in the menu bar. Both failures are about an item that exists
without showing; only one of them is Escapement's to fix.

## What was measured

`NSStatusItem.isVisible` cannot answer the question. With Escapement denied in
System Settings and the icon absent from the menu bar, a running agent logged
`isVisible=true` on every tick. Setting it to `true` again changed nothing: a
build that asserts visibility at creation was installed, the service booted out
and re-registered, and the icon stayed away.

The reason is visible in the agent's own log — the item is a Control Center
scene, `com.apple.controlcenter:<uuid>-Aux[1]-NSStatusItemView`, and the menu
bar's window layer belongs to Control Center rather than to Escapement. The
suppression is enforced above the application.

Nothing is written to the app's preferences either. `com.granroth.Escapement.Agent`
has no defaults domain at all, before or after toggling the system setting.
There is no persisted `NSStatusItem Visible` key to read, and the Control Center
container, `StatusKitAgent`, and every plist in `~/Library/Preferences` carry no
trace of the setting.

The one reading that does move is the status item button's window:

| | allowed | suppressed |
| --- | --- | --- |
| `window.screen` | present | **nil** |
| `occlusionState` | visible | occluded |
| `window.frame` | `{{2493, 2130}, {34, 30}}` | `{{0, -22}, {34, 22}}` |

Sampled across six consecutive ticks in the suppressed state, all identical, and
across four in the allowed state. `window.screen == nil` is the discriminator.

There is one transient. For roughly a tick after the item is created its window
reports a zero-height frame while the system places it. In every observation the
transient reported its window as still belonging to a screen, so it does not
read as suppression — but the reading is debounced anyway, because this area has
produced more than one confident wrong answer.

## The design

**The agent observes; it does not fight.** `StatusItemController.placement`
exposes the one useful reading, `MenuBarSuppression` turns a sequence of those
readings into a verdict after two consecutive unplaced ones, and the agent
publishes the verdict in `state.json`. Written only on change: the GUI reloads
on every write, and a tick that rewrites an unchanged verdict would wake it as
often as once every five seconds for nothing.

**The verdict is a tri-state, and unknown publishes nothing.** This is not
fastidiousness; skipping it produced a real defect. An agent restarting while
the icon is genuinely suppressed reads `settling` on its first tick, because a
freshly created item has not been positioned yet. Treated as "nothing is wrong",
that reading published a confident *not suppressed* over the previous run's
correct verdict, un-explaining a hidden icon for a tick or two — up to two
minutes at the idle cadence — before correcting itself. Observed in the agent's
own log: `suppressed by the system: false` at 16:51:38, then `true` at 16:52:38,
with the icon absent throughout. So `settling` is inert, the verdict starts
`nil`, and the agent publishes only once it has grounds. The last published
value is also seeded from `state.json` at startup, so a fresh process does not
rewrite a conclusion it merely forgot.

`settling` is distinguishable because the transient window has zero height,
while a settled one has a real height whether it is permitted (30) or suppressed
(22).

The explanation is shown only while the agent is running. It is the sole writer
of the verdict, so a stopped agent leaves its last conclusion frozen in the file
with nothing able to correct it — and while it is stopped the icon is missing
because the user stopped it, not because macOS intervened. Saying otherwise
sends them to System Settings to fix something that is not broken.

`state.json` is the agent's file and the GUI only reads it, so the single-writer
rule in `ARCHITECTURE.md` is intact. The field is optional so that a state file
written before it existed still decodes — a missing key on a non-optional would
throw and discard every other value in the file, the pause included.

**A suppressed item is rebuilt until the system relents.** macOS reads the
permission when the item is *created* and never revisits it for an existing
one, so restoring the setting in System Settings does not revive an item that
was refused — it stays dead for the life of the process. That is why turning the
agent off and on again was the only way to get the icon back. Rebuilding the
item is the part of that restart that matters, and the agent does it itself
every three minutes while it believes the icon is suppressed. Nothing is on
screen in that state, so the rebuild is invisible; the interval is long enough
for a fresh item to settle and be judged, since a rebuild resets the reading.

Verified live: with the permission restored and the agent left alone, the icon
returned 170s later, PID unchanged.

The reverse is deliberately not handled. Revoking the permission leaves a
visible item visible until something recreates it, and an icon that still works
needs no warning and no intervention.

**Settings explains instead of lying.** While the preference asks for an icon
and the agent reports it suppressed, the Settings window says so beneath the
checkbox and offers a button to the Menu Bar pane. Escapement never changes that
setting; taking the user to it is the most it does, which keeps the scope line
in `CLAUDE.md` — this app does not change system settings on the user's behalf.

**Visibility is asserted on acts, not on a timer.** `setVisible` installs or
removes the item to match the preference and leaves `isVisible` alone.
`install()` asserts once at creation, which is what makes the icon appear at
all. Ticking the checkbox posts `AgentCommand.showMenuBarIcon`, which the agent
honours by asserting again — the same division `pause` already uses, where the
preference lives in the configuration file and the act travels as a command
because the live state belongs to the agent. Re-asserting on every tick was
removed because it cannot overrule a system-side suppression and an item that is
already showing does not need telling.

## Deliberately not doing

**Overriding the system's list.** It is a permission, not a preference, and
there is no supported way to change it from inside the app. If there were, this
is exactly the kind of setting the project does not touch on the user's behalf.

**Correcting `showsMenuBarIcon` to match reality.** Tempting — the checkbox
could simply untick itself when the system suppresses the icon — but it would
misrepresent the user's preference as their having turned it off, and the moment
they re-allowed Escapement in System Settings the icon would stay away for a
reason they never chose. The preference records what the user asked for; the
explanation records what they are getting.

**Writing `configuration.json` from the agent.** Forbidden by the single-writer
rule, whose only protection against a lost update between two processes is that
each file has exactly one writer.
