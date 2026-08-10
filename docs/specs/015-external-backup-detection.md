# Spec 015 — Recognising backups Escapement did not start

Status: implemented

## Problem

Escapement records a backup only if it started one. `SchedulerRunner.start()`
(`SchedulerRunner.swift:257-271`) is the only place a live `.running` record is
created, and `reconcileOpenRuns` (`:278-302`) iterates `runs where run.outcome
== .running` — rows Escapement itself inserted. There is no path from "backupd
is running a backup" to "history knows about it". The three writes to
`history.json` are `start()`, `close()` (`:335-342`, reached from `closeFinished`
`:305-323` and `stall` `:329-333`), and the `.skipped` bookkeeping at `:426`;
none of them can be reached by anything the user does outside the app.

So a backup started anywhere else — System Settings → General → Time Machine →
"Back Up Now", `tmutil startbackup` from a script or another utility, or macOS's
own scheduler while `AutoBackup` is on — is invisible to everything downstream
of history: the card's "Last: …" line (spec 013, `DisplayModel.swift:101-124`),
the Activity Log, the menu bar's "Latest backup" line
(`StatusSummary.swift:110-138`), the last-completed reference due-ness is
computed from (`Stores.swift:124-132`), and the attempt time fairness orders on
(`:135-144`).

The sharp point is that Escapement is not blind to the backup. It sees it
perfectly well while it runs: `RowBuilder.statusText` (`DisplayModel.swift:60-74`)
and `holder(activity)` (`SchedulerRunner.swift:474-480`) both read
`BackupActivity` directly, so the card shows "Copying — 40%" for an external
backup exactly as it would for one of Escapement's own, and `holder` even names
it as the reason another destination is waiting. Escapement watches the whole
thing and then forgets it happened. The instant it ends, the card reverts to a
"Last: …" line that predates it.

Concretely, the reported case. A 1am scheduled run completes. At 8am the user
backs up from System Settings. At 9am the card still reads "Last: 8 hours ago",
the Activity Log's newest row is 1am, and the destination's next occurrence is
computed from 1am — so Escapement will shortly start another backup of a Mac
that was backed up an hour ago.

That last consequence is not cosmetic. Escapement exists to decide *when*
backups run; a decision made from a last-run reference it knows to be stale is a
wrong decision, and the user pays for it with a redundant backup.

## Scope

This spec adds one thing: a live backup that Escapement did not start becomes a
history record on the same terms as one it did. It does not change how
Escapement's own runs start, close, or are ordered; it adds no source of history
other than direct observation; and it does not let Escapement act *of its own
accord* on a backup it did not start (§6).

## 1. Adoption

At the end of `reconcileOpenRuns`, which already holds the activity and has just
finished closing out whatever was open, adopt when all of:

1. activity is `.running(destinationID: D, …)` with `D` non-nil;
2. no record in history remains `.running` after reconciliation;
3. the in-memory `openRun` (`:55`) is nil.

**Condition 2 must be read from disk again, not from `runs`.** The array bound
at `:279` is a snapshot taken *before* the loop. `closeFinished` and `stall`
persist through `history.update()` (`:339`) and never touch the local copy, so
after the loop `runs` still reports as `.running` every record the loop just
closed. An implementation that filters that array therefore suppresses adoption
on exactly the tick where one backup ends and an external one is already live:
the run Escapement itself just closed masquerades as a reason not to record the
new one, and the external backup is adopted a poll late with a `startedAt` to
match. The check is a second `history.load()` taken after the loop, asked only
whether any record is still `.running`. Gate it behind conditions 1 and 3,
which are free, so the extra read happens only on ticks that are genuine
adoption candidates. Re-reading history within one tick is not a new pattern —
`evaluate` already does it at `:149`, after reconciliation, for the same reason.

Conditions 2 and 3 are different facts — disk and memory — and the pair is
deliberately redundant. Condition 2 is the load-bearing one, and it catches a
case condition 3 cannot: a record stranded by a previous process whose backup is
*still live*. `openRun` does not survive a restart, so it is nil, while
`reconcileOpenRuns` finds the record live (`:285`) and leaves it `.running`.
Adopting there would file a second record for a backup that already has one.
Condition 3 costs nothing and holds the same invariant from the other side —
every path that clears `openRun` also closes its record (`:316`, `:332`,
`:268-269`), so an `openRun` outliving a closed record means a `history.update`
was swallowed by its `try?` (`:339`), and a tick that cannot explain its own
state should abstain rather than write another live record into it.

The effect is an ordinary record and an ordinary open run:

    let run = BackupRun(destinationID: D, trigger: .external, startedAt: now())
    history.append(run)
    openRun = OpenRun(id: run.id, destinationID: D,
                      observedRunning: true, observedStopping: false,
                      awaitingCloseConfirmation: false)
    lastAttempt[D] = now()

Everything after that is the existing machinery: `reconcileOpenRuns` tracks it,
`closeFinished` closes it — subject to the confirmation rule in §4 — and
`close()` stamps `finishedAt`.

Adoption sits **above** the pause guard (`:144-147`), alongside the
reconciliation it extends. Pausing suppresses scheduled fires, not observation;
a user who paused Escapement and then backed up from System Settings has done
nothing to say the run should go unrecorded, and the existing comment at
`:140-143` already establishes that reconciliation runs regardless of pause so a
pause never strands history. Adoption inherits the guard at `:134` too: a tick
that cannot read activity does nothing, rather than guessing.

`startedAt` is the first instant Escapement *observed* the backup, which may be
later than the true start — `tmutil status` cannot report when the current
backup began, and nothing else may be consulted (§10). The error is bounded by
the poll cadence except when the agent starts up mid-backup, where it can be
large. Two consumers see it: the Activity Log's "Started" column, and
`mostRecentAttempts`. For the log it is honest — it is when Escapement learned
of the run. For fairness it errs on the late side, which understates the
destination's priority rather than letting it jump the queue.

## 2. Attributing the backup to a destination

`BackupActivity.running(destinationID: String?, …)` (`BackupActivity.swift:10`)
carries the value `tmutil status` reports as `DestinationID`
(`TimeMachineOutputParser.swift:66`), which is the same UUID string
`destinationinfo -X` reports as `ID` (`:29`) and the same value passed to
`startbackup --destination`. Escapement already stakes correctness on that
identity: `isLive` (`:344-353`) matches a status id against a run started from a
`DestinationSchedule.destinationID`, and `RowBuilder` matches it against
`Destination.id`. Adoption relies on nothing new.

The id is deliberately *not* resolved against `control.destinations()` at
adoption time. `destinationID` is a bare string in `history.json` today, and
every display path already falls back to the raw id when it names nothing
configured (`LogWindowController.swift:72-74`, `StatusSummary.swift:100-102`) —
the same fallback that lets a schedule outlive its disk (spec 003). Executing
`tmutil destinationinfo` on every tick to validate a value already in hand would
add a subprocess to the poll loop and buy nothing but a chance to discard a true
record.

**A nil `destinationID` records nothing.** `isLive`'s "nil means ours"
rule (`:349-351`) is defensible only because it is deciding about a run it
already has; there is no equivalent excuse for inventing one. A nil id means
"some backup is live" and Escapement cannot say which destination it would be
crediting. The live UI still shows the activity, as today; only history
abstains. A missing row is much cheaper than a wrong one: a wrong row advances
some other destination's last-completed reference and suppresses a scheduled
backup that should have happened.

**`.stopping` is not adopted.** A backup first seen while it is already ending
has no start time worth recording and no outcome that can be inferred, and will
read `.idle` within a poll or two.

## 3. Overlap with a run Escapement already owns

The question is whether an external backup starting while one of Escapement's
own runs is open needs distinguishing. It does not, because condition 2 makes it
unrepresentable — but the reason is worth stating rather than leaving implicit.

Time Machine runs one backup at a time: `tmutil startbackup` "will begin a
backup if one is not already running", `tmutil status` has no shape in which to
report a second session, and spec 003 rule 1 models the constraint. So an
activity reading `.running` while a record is open is either that record's own
backup — `isLive` matches it, and it is not an adoption candidate — or a state
Escapement cannot explain. The only realistic way to reach the second is a run
inside its startup grace (`:310-313`), which is kept open precisely because
backupd has not been seen to pick it up yet.

Adopting in that state would leave two `.running` rows and point `openRun` at
the newer one, so `closeFinished`'s `run.id == openRun?.id` test (`:306`) would
fail for the older row and file it `.failed(reason: "interrupted")` — turning a
race into a spurious failure notification (`AgentService.swift:96-113`).
Abstaining costs at most one unrecorded external run in a case that requires
backupd to have started something else in the gap between this tick's activity
read and its own `startbackup`.

## 4. Outcome

The existing inference in `closeFinished` is reused unchanged, with
`observedRunning` seeded `true` at adoption.

That is not a shortcut. `observedRunning` records "this backup was seen live at
least once", and adoption's precondition *is* a direct observation of it running.
The startup-grace branch (`:310-313`) and the "backup did not start" failure
(`:314`) exist to judge a run that may never have been picked up; an adopted run
was picked up by definition, so neither branch is reachable for it. An adopted
run therefore closes `.completed` once its activity no longer names it — the
same evidence, no weaker, that closes every run Escapement starts itself —
subject to the confirmation rule below.

Two additions, and the reasons for them.

**A cancelled external backup must not record as completed.** An external run is
far more likely to be cancelled than one of Escapement's own: in System Settings
the control that started it becomes the control that stops it, and the user
pressing it tells Escapement nothing. Today such a run would close `.completed`,
because `.stopping` counts as live (`:348-352`) and the run is closed from a live
state on the tick that first reads `.idle`. That would advance the destination's
last-completed reference on the strength of a partial copy and suppress the next
scheduled backup — the exact failure this spec exists to prevent, arrived at
from the other direction.

So `OpenRun` (`:50-54`) gains `observedStopping`, set when reconciliation sees
`.stopping` naming that run's destination, and `closeFinished` closes a run that
carries it as `.cancelled` rather than `.completed`.

This is best-effort, like every inference drawn from `tmutil status`.
Cancellation of a local-disk backup can complete inside one five-second poll and
be missed, in which case the run records `.completed` and the destination's next
occurrence is deferred once — bounded, self-correcting at the following
occurrence. Cancellation of a network destination sits in `Stopping` for tens of
seconds (`ARCHITECTURE.md:91-96`) and is caught reliably.

Note what else this fixes. `.cancelled` has existed since spec 003 and is
rendered in three places (`DisplayModel.swift:120`,
`LogWindowController.swift:90`, `StatusSummary.swift:132-133`), but nothing in
`Sources/` ever assigns it — so the GUI's and menu bar's Stop command
(`AgentService.swift:141-143`, `:297-302`) currently records the run it stopped
as "Completed". The same change gives `.cancelled` its first writer and corrects
that path too, which is why it is specified here rather than confined to
adoption. It needs its own test either way.

**One non-live poll is not proof that an adopted backup ended.** `isLive` treats
`.idle` as not-live unconditionally (`:346-347`), so a single status sample that
reads idle while the backup is in fact still going closes the run. For a run
Escapement started that is a bounded, if unwelcome, error: the record ends early
and wrongly, and nothing re-opens it — `evaluate`'s decision path will not,
because the false `.completed` has just advanced `lastCompletedRuns[D]` and the
destination is no longer due, and `backUpNow` (`:203-210`) needs the user to
press a button. Adoption is the only path that mints a record from activity
alone, so it is the only one that turns the same blip into a *duplicate*:

- Tick N: `.running(A)`, nothing open — adopt record R.
- Tick N+1: the status reads `.idle` for one poll — a network destination
  dropping out from under the mount, or any dictionary whose `Running` key is
  absent or `0`, which the parser reports as `.idle` outright
  (`TimeMachineOutputParser.swift:63-64`). `closeFinished` closes R
  `.completed` and clears `openRun`, and
  `lastCompletedRuns[A]` advances to an instant at which nothing completed.
- Tick N+2: `.running(A)` again — the same session, never actually interrupted.
  History holds no `.running` record and `openRun` is nil, so conditions 1-3 are
  all satisfied and a *second* `.external` record is written for one
  human-visible backup.

Two rows for one backup, and a completion stamped for a backup that had not
completed: the same false advance of the last-completed reference the
`.cancelled` rule above exists to prevent, reached by a different route.

So `OpenRun` gains `awaitingCloseConfirmation`, and an adopted run — identified
by `run.trigger == .external`, the same hook §6 uses — is closed only on the
*second consecutive* non-live observation. The first sets the flag and returns
without writing; the live branch that already sets `observedRunning` (`:289`)
clears it, so "consecutive" means what it says. During the pending tick the
record is still `.running` in history, so condition 2 also keeps that tick from
adopting anything else. Nothing changes for `.scheduled`, `.manual`, or
`.missed` runs: the single-poll exposure they carry predates this feature and
closing them differently is a separate question (Out of scope).

A count of polls rather than a grace period, deliberately. The hazard is a bad
*sample*, not a slow transition, so the sample is the natural unit — and there
is no duration that would mean the same thing twice, because the cadence is not
fixed: `rescheduleTimer` (`AgentService.swift:363-374`) drops straight back to
`idleCap` the moment activity reads `.idle` (`:366-369`), so the confirming poll
arrives up to 60 seconds later rather than at `activePoll`'s five. That is the
cost and it is the right one — a genuinely finished adopted run gets its
`finishedAt` and its Activity Log row up to a minute late, while a blip is
answered by a poll far enough out to have seen the truth. An external backup
that ends while another is starting pays the same one-poll toll before the next
one is adopted, which is the abstention §3 already accepts.

The confirmation brings one corollary with it. **A run awaiting confirmation
still holds the slot.** A tick that has declined
to believe an idle sample must not then start a backup on the strength of that
same sample. If it did, the start would overwrite `openRun` at `:261` and strand
R: `closeFinished` would find `run.id != openRun?.id` on the next tick and file a
completed backup as `.failed(reason: "interrupted")` (`:321`), while the run just
started — against a `startbackup` that no-ops because a backup really is still
running — sits out its startup grace and then records `.failed(reason: "backup
did not start")` (`:314`). One blip, two wrong records and a failure
notification. So a pending `awaitingCloseConfirmation` defers the start in the
same `actuallyStarting` computation that the retry cooldown uses (`:173-184`),
and inherits its semantics exactly: `winnerID` is unchanged, so `recordSkipped`
still excludes the destination and writes no skip row (`:168-169`), and
`updateWaiting` shows it blocked with no named holder — the same shape a
cooldown deferral already produces. The deferral lasts one poll.

The same overwrite hazard reaches `backUpNow` (`:203-210`), a second, independent
entry point into `start()` that derives its own "is anything running" from a bare
`activity == .idle` check. The user's own activity read is fooled by the same
blip that armed the confirmation, so a manual start for an unrelated destination
would strand R exactly as an automatic one would. `backUpNow` therefore carries
the identical guard, `openRun?.awaitingCloseConfirmation != true`, alongside its
existing idle check.

## 5. What the record means to the scheduler

All of the following follow from writing an *ordinary* record rather than a
special one, and all are intended:

- **Due-ness.** A completed external run advances `lastCompletedRuns`
  (`Stores.swift:124-132`), so the destination's next occurrence is computed
  from it. This is the substance of the feature: Time Machine backed that
  destination up, the schedule's purpose was served, and firing again an hour
  later serves nobody. The recurrence anchor remains `effectiveFrom`, not the
  reference (`Scheduler.swift:135-139`), so the cadence keeps its clock
  positions instead of drifting onto whatever time the external run happened to
  land on.
- **Fairness.** `mostRecentAttempts` (`Stores.swift:135-144`) counts every
  outcome but `.skipped`, so an adopted run costs its destination its place in
  the rotation with no code change. Correct on spec 012 §1's own reasoning: the
  key measures when the single shared slot last did work for a destination, and
  it just did. Excluding `.external` would let a destination that Time Machine
  is already backing up regularly keep outranking one that is being starved.
- **Cooldown.** Adoption stamps `lastAttempt[D]` (`:64`) exactly as `start()`
  does (`:258`). This matters when an external run ends badly: `.cancelled`
  does not advance the last-completed reference, so the destination is still due
  on the very next tick, and without the stamp Escapement would start its own
  backup seconds after the user cancelled one. With it, the user gets
  `retryCooldown` of quiet.
- **Backoff.** `consecutiveFailures` (`:381-394`) counts `.cancelled` alongside
  `.failed`, so repeated cancellation lengthens the retry gap. Acceptable, and
  arguably right — a user cancelling twice in a row is a signal — and a single
  completed run resets it.
- **Failure notification.** An adopted run closing `.failed` notifies like any
  other, if the user asked for failure notices (`AgentService.swift:96-113`). It
  should: the failure is real, and once System Settings is closed the user has
  no other channel for it.

## 6. What Escapement must not do on its own to a backup it did not start

The stall watchdog (`:329-333`) issues `stopBackup()`. **It must not do that to
an adopted run.**

The watchdog exists to reclaim the slot from a run Escapement started and can no
longer account for. An external run is accounted for by definition — someone
else asked for it, and may be standing in System Settings watching the progress
bar. Escapement stopping it would be the app deciding, on the user's behalf,
that a backup they explicitly requested should end. That is the same line the
app already declines to cross with `AutoBackup`, which it detects and explains
but never flips (`ARCHITECTURE.md:36-42`).

**The hook is `run.trigger == .external`.** Nothing new is needed to know that a
run was adopted: `reconcileOpenRuns` iterates whole `BackupRun` values (`:284`),
so `run` is in scope at the stall test (`:297-300`), and that test is the only
caller of `stall(run:)`. The exemption is therefore one added condition at that
call site — `run.trigger != .external` — with no new state, no lookup back into
history, and no change inside `stall` itself. It is the same field §4's close
confirmation keys on: "Escapement did not start this" is asked in exactly one
way, so the two rules cannot drift apart.

So an adopted run is exempt: its progress snapshots are still recorded (harmless,
and they keep the bookkeeping uniform), but reaching `stallTimeout` does not stop
it, and its record stays `.running` rather than being filed `.failed(reason:
"stalled")` — the whole `stall(run:)` call is skipped, not just its
`stopBackup()`. A genuinely wedged external backup therefore holds the slot
until something outside Escapement resolves it — which is exactly the state
spec 012 §4 built the visibility for. `AgentState.waiting` names the holder, and
every blocked destination gets one `.skipped` record per occurrence, so the
situation is legible even though Escapement will not act on it.

Adoption in fact completes that machinery. `holder(activity)` (`:474-480`) could
previously name a destination that appears nowhere in the Activity Log, so "why
did nothing run last night" was answerable only from a live state that vanishes
on the next tick. With adoption, the holder always has a row of its own.

**The user's own Stop is a different question, and the answer is yes.** The line
drawn above is around *automatic* action — Escapement, unprompted, ending a
backup somebody asked for. A user pressing Stop is not Escapement deciding
anything: the menu bar extra (`AgentService.swift:297-302`) and the GUI, whose
`AgentCommand.stop` is drained at `:141-143`, both call `control.stopBackup()`
with no knowledge of which run is open, and both are the same person with the
same authority issuing the same `tmutil stopbackup` System Settings would have
issued. Stop already reached such a backup before this spec — `stopBackup()`
acts on whatever is live, records or no records. What changes is that the stop
now lands on a *record*, which is what makes "should that have been allowed?"
a question at all. The decision is to leave it exactly as it is: Stop is **not**
restricted to runs Escapement started.

Restricting it would cost more than it buys. The card and the menu already show
an external backup live, phase and percentage and all
(`DisplayModel.swift:60-74`), so a Stop that greyed out or silently declined for
exactly those backups would be the one place in the app where a visibly running
backup is one the UI refuses to act on. Expressing the restriction would also
mean plumbing the runner's `openRun` into menu enablement and into command
handling, to withhold something the user can do anyway one Settings pane away.

What the user gets instead is an honest record, and it needs no new code: the
stop is observed as `.stopping`, `observedStopping` is set by the same
reconciliation as any other, and the adopted run closes `.cancelled` (§4) rather
than `.completed` — so stopping someone else's backup from Escapement does not
advance the destination's last-completed reference, and §5's cooldown keeps
Escapement from starting a backup of its own seconds later. Being a decision to
add nothing, it is exactly the kind of thing a later reader would otherwise
"fix", which is why it is written down here.

## 7. The trigger, and what the UI shows

`BackupRun.Trigger` (`BackupRun.swift:6-13`) gains a fourth case:

    /// Observed running without Escapement having started it — System
    /// Settings, another tool, or macOS's own scheduler.
    case external

A trigger case rather than an outcome case or a separate flag: the field already
answers exactly this question, its three existing cases all name an initiator,
and outcome is orthogonal — an external run can complete, fail, or be cancelled
like any other, and every one of those combinations is meaningful.

`.external` asserts precisely "this agent did not start it", and nothing more.
`tmutil status` cannot report which process asked, so the app will not imply that
it knows.

**Activity Log.** `LogWindowController.swift:80-85` gains
`case .external: return "External"`. This is where the distinction belongs: the
log answers "what happened, and why", and a user who does not remember pressing
anything should be able to see that something else did. The existing 90pt Trigger
column fits it.

**Destination card.** `DisplayModel.swift:101-124` is unchanged, in code and in
intent. "Last: …" answers "when was this disk last backed up", and the answer
does not depend on who asked for it. `lastRunText` switches on outcome only,
excludes `.running` and `.skipped`, and takes the newest match from a
newest-first history, so an adopted record flows through with no change to
`RowBuilder`, `DestinationRow`, or the row layout spec 013 fixed at 62pt.
`StatusSummary.latestLine` (`:110-138`) is likewise unchanged. Spec 013 needs no
revision.

**Encoding.** Adding an enum case is additive for decoding existing
`history.json` files; a history containing `.external` will not decode in an
older build. That is the same forward-only trade spec 012 §4 accepts for
`.skipped`, and it is consistent with how `schemaVersion` is handled in spec 003.

## 8. macOS's own scheduler

Worth stating outright, because it is not an edge case. `automaticBackupState`
is consulted only by the GUI (`AppController.swift:298`); neither the agent nor
`SchedulerRunner` reads it. So while `AutoBackup` is on — the conflict state the
app detects and guides the user through but never fixes
(`ARCHITECTURE.md:26-42`) — every backup Apple's scheduler runs looks to the
agent exactly like any other external backup, and will be adopted.

That is the right outcome. In that state Escapement's history is currently empty
or stale while the Mac is in fact backing up on Apple's cadence, and the app's
explanation of the conflict is stronger for being able to show what is actually
happening. The volume is bounded by the retention cap (`Stores.swift:73`): 500
records is about three weeks of hourly backups.

## 9. The single-writer rule

Unstrained. Adoption happens inside `SchedulerRunner`, which runs only in the
agent, and the agent is already the sole writer of `history.json`. The new record
goes through the same `HistoryStore.append`/`update` pair (`Stores.swift:89-104`)
as every other; the count of write sites goes from three to four, all in
`SchedulerRunner.swift`. The GUI gains no write authority: the two ways a user
can now cause a history record — Escapement's own Back Up Now button, which
posts an `AgentCommand`, and System Settings, which is observed — both terminate
at the agent.

There is not even a new subprocess or a new loop. `AgentService.rescheduleTimer`
(`AgentService.swift:363-374`) already polls at `activePoll` — five seconds
(`:40`) — whenever activity is not `.idle`, external backups included, so an
adopted run is closed out as promptly as any other. This feature needs no change
to `EscapementAgent` at all, and one line in `EscapementApp`.

## 10. What is not detectable, and is not attempted

`tmutil status` reports the present instant and carries no history. Nothing in
this design can see a backup that is already over.

- **Between polls.** While idle the agent's timer runs at up to `idleCap` — 60
  seconds (`:38`, `:368-372`). An external backup that starts and finishes inside
  one such gap is never observed and never recorded. A short incremental backup
  to a fast local disk can do exactly that.
- **Agent not running.** Nothing is observed at all, before or after.

Neither is worked around. The candidates, and why not:

- `tmutil latestbackup` / `listbackups` report a snapshot date — no start time,
  no duration, no outcome, and no way to tell whether the snapshot is one
  Escapement already has a record of. They also require the destination to be
  mounted; for a network destination that means mounting the sparsebundle, which
  Escapement will not do on the user's behalf.
- `/Library/Preferences/com.apple.TimeMachine.plist` carries completion dates but
  needs Full Disk Access, which `ARCHITECTURE.md:98-105` declines to require —
  Escapement keeps its own history precisely so it does not depend on Apple's.
- The unified log (`com.apple.TimeMachine`) does retain enough to reconstruct
  backups that ran while the agent was down, but `log show` is expensive to run,
  its message strings are undocumented and shift between releases, and much of
  what is interesting is redacted as `<private>` without an installed profile. If
  after-the-fact reconstruction is ever wanted it deserves its own spec, not a
  smuggled dependency in this one.
- Shortening the idle poll would narrow the first window at the cost of running
  `tmutil status` far more often, forever, to catch something rare. The cost of a
  miss is that one "Last: …" line reads older than the truth until the next
  observed run — which is today's behaviour in every case, so a miss is never
  worse than the status quo.

Stated plainly, so no UI copy ever overclaims: Escapement records external
backups it *witnesses*. It does not hold a complete record of the machine's
backup history and must not present itself as one.

## Out of scope

- Escapement's own scheduled and manual runs. `start()` and the `.scheduled`,
  `.manual`, and `.missed` triggers are untouched; the only effect on them is
  §4's one-poll deferral while an adopted run awaits close confirmation, which
  rides the deferral path the retry cooldown already owns (`:173-184`).
- Reconstructing backups from any source other than live observation (§10).
- Identifying which process or person started an external backup (§7).
- Changing how a run stranded across an agent restart is closed. Such a run is
  still filed `.failed(reason: "interrupted")` (`:317-322`) because `openRun`
  does not survive a restart, and that now applies to adopted runs too: an
  external backup in flight when the agent restarts ends as "interrupted" even
  if it finished cleanly. Re-adopting a stranded record whose backup is still
  live would fix it for both kinds of run and is probably the better design, but
  it changes the recorded outcome of Escapement's own runs and belongs in its
  own spec.
- Any handling of `AutoBackup` beyond §8's observation. Escapement still never
  changes the setting.
- Escapement stopping, pausing, or otherwise acting *unbidden* on a backup it
  did not start (§6). The user's own Stop is unrestricted and unchanged, also
  §6.
- Changing how Escapement's own scheduled and manual runs are closed. §4's
  two-consecutive-poll confirmation is scoped to `.external` runs; the identical
  single-poll exposure on the other triggers is older than this feature, has no
  duplicate-record consequence, and would change the recorded outcome of runs
  this spec is otherwise not touching.

## Verification

Strict TDD per `CLAUDE.md`: each test written first and confirmed to fail for
the right reason. All of the logic lives in `EscapementKit` and is driven through
the existing `Harness` and `FakeTimeMachine`
(`Tests/EscapementKitTests/SchedulerRunnerTests.swift:23-70`,
`Fakes.swift:8-47`), which already set activity by hand.

1. **Adoption.** No schedules, no open run; set activity to
   `.running(destinationID: "A", …)` and evaluate. Assert exactly one record for
   A, trigger `.external`, outcome `.running`. Set `.idle` and evaluate; assert
   the record is *still* `.running` — the first non-live poll only arms the
   confirmation. Evaluate again on the same `.idle` and assert it closes
   `.completed` with a `finishedAt`.
2. **Not once per tick.** Evaluate repeatedly while the same activity persists;
   assert one record, not one per poll.
3. **Nil destination.** `.running(destinationID: nil, …)` across several ticks;
   assert nothing is recorded, and that the run list stays empty after it goes
   idle.
4. **`.stopping` is not adopted.** `.stopping(destinationID: "A")` with no open
   run; assert nothing is recorded.
5. **No overlap.** Start a scheduled run for A with `autoBecomeRunning` off so it
   sits inside its startup grace, then report `.running(destinationID: "B")`.
   Assert no record for B and that A's record is untouched and still `.running`.
6. **Own runs are not adopted.** The existing `completesRun` path must still
   yield exactly one record, trigger `.scheduled` — a regression guard on
   conditions 2 and 3.
7. **Adoption on the tick a run closes.** The regression guard on §1's
   fresh-read rule. Drive a scheduled run for A to `observedRunning` with
   `.running(destinationID: "A", …)`, then set `.running(destinationID: "B")`
   and evaluate *once*. Assert two records after that single tick: A closed
   `.completed`, and B adopted `.external`/`.running`. An implementation that
   tests condition 2 against the `runs` array bound at `:279` fails this,
   because that snapshot still shows A as `.running`.
8. **Cancellation.** Adopt, report `.stopping(destinationID: "A")`, then `.idle`
   and evaluate twice (§4's confirmation); assert `.cancelled`, not
   `.completed`. Separately, drive a run Escapement started through
   `stopBackup()` and assert it too records `.cancelled` — the corrected Stop
   path from §4.
9. **Manual Stop reaches an adopted run.** §6's decision. Adopt A, call the
   fake's `stopBackup()` as the menu bar and `AgentCommand.stop` paths do
   (which sets `.stopping(destinationID: nil)`, `Fakes.swift:43-46`), evaluate,
   then go `.idle` and evaluate twice. Assert the adopted record closes
   `.cancelled` and that nothing rejected the stop on the grounds that the run
   was not Escapement's. A guard against a later change restricting Stop to
   runs Escapement started.
10. **A blip does not duplicate a record.** §4's confirmation, against the trace
    that motivates it. Adopt A; set `.idle` and evaluate; set
    `.running(destinationID: "A", …)` again and evaluate. Assert exactly one
    record throughout, still `.running`, with the same `id` — not a
    `.completed` row plus a second `.external` row. Then go `.idle` and evaluate
    twice; assert it closes `.completed` and there is still exactly one record,
    which also proves the live poll reset the flag rather than leaving one
    non-live observation banked.
11. **A pending run holds the slot.** Adopt A first, then give B a daily
    schedule whose occurrence falls after that tick, so B is not already due
    while the slot is visibly busy — otherwise the adoption tick earns B a
    legitimate `.skipped` row (`:408-428`) and muddies the assertion. Set
    `.idle` and evaluate: assert `startCalls` is empty, that no `.skipped` row
    exists for B — this tick's winner is excluded from that bookkeeping
    (`:168-169`) — and that A's record is still `.running`. Evaluate again:
    assert A closes `.completed` *and* B starts. Without the deferral the first
    of those two ticks starts B, strands A, and files it `.failed(reason:
    "interrupted")`.
12. **`backUpNow` also respects a pending confirmation.** Adopt A; one idle poll
    arms the confirmation. Call `backUpNow(B)`; assert nothing starts and A's
    record is untouched — the same overwrite hazard `evaluate()` is guarded
    against, reached through the manual entry point instead. Confirm A, then
    call `backUpNow(B)` again; assert it now starts normally.
13. **Due-ness.** Daily 03:00 schedule on A; adopt and complete an external run at
    08:00; assert the next evaluation does not start A, and that A becomes due
    again at the following 03:00 rather than immediately.
14. **Cooldown.** Adopt, cancel, then evaluate with A due; assert Escapement does
    not start its own run before `retryCooldown` has elapsed.
15. **Fairness.** Two due destinations, an adopted run for A; assert B is chosen
    next. Guards the "every outcome except `.skipped`" rule
    (`Stores.swift:135-144`) against a future exclusion of `.external`.
16. **Watchdog exemption, gated on the trigger.** Adopt A, then hold an
    identical `.running(destinationID: "A", …)` snapshot past `stallTimeout`
    and evaluate; assert `fake.stopCalls == 0` and that the record is still
    `.running` — neither stopped nor filed `.failed(reason: "stalled")`. Its
    paired positive is the existing `stallWatchdogStopsAStuckRun`
    (`SchedulerRunnerTests.swift:353-354`), which must pass unchanged: the same
    activity, the same held snapshot, the same timeout, differing only in the
    run's trigger. The two together assert that `run.trigger == .external` is
    what decides — not the destination, the timing, or the shape of the
    activity.
17. **Pause.** With the agent paused, adopt an external run and close it out;
    assert both happen, and that no scheduled run starts — pause suppresses
    the schedule (`:144-147`), not observation.
18. **Between polls.** §10's first miss case, asserted rather than merely
    described. Set activity to `.running(destinationID: "A", …)` and then to
    `.idle` with *no* `evaluate()` in between, then evaluate once; assert
    history is empty. A backup that begins and ends inside one idle-poll gap is
    not recorded, and no later tick invents it.
19. **Coding.** A history containing `.external` round-trips; a history written
    before this change still decodes.

Beyond the suite, the agent cannot be `@testable`-imported, so verify in the
signed build installed to `/Applications` with the agent registered. Hold the
display awake (`caffeinate -u -t N`, backgrounded) before driving the UI, and
capture windows by `kCGWindowNumber` rather than by screen region.

1. With Escapement idle, start a backup from System Settings → General → Time
   Machine → "Back Up Now". Confirm the card shows it running (as it does
   today), and that on completion the Activity Log gains a row naming the
   destination, with Trigger "External" and Result "Completed".
2. Confirm the card's "Last: …" line moves to that run, and that the
   destination's next scheduled backup is computed from it rather than from the
   previous Escapement run — the reported complaint, end to end.
3. Repeat, cancelling from System Settings partway through. Confirm the row
   reads "Cancelled" and that Escapement does not immediately start its own
   backup of that destination.
4. Run `tmutil startbackup --destination <id>` from a shell; confirm the same row
   appears. This is the path a third-party tool or script takes.
5. Exercise §8, which no unit test can reach: `automaticBackupState` is read
   only by the GUI (`AppController.swift:298`), so the interaction between the
   conflict state and adoption exists only in the assembled app. Turn "Back Up
   Automatically" **on** in System Settings → General → Time Machine. Confirm
   Escapement enters its
   conflict state — destination list shown, scheduling disabled, explanation
   offered (`ARCHITECTURE.md:36-42`) — and then leave the Mac alone until macOS's
   own scheduler fires, bounded by `AutoBackupInterval` (one hour by default).
   Confirm the agent adopted that backup: an Activity Log row with Trigger
   "External", written while the GUI was telling the user that scheduling is off.
   The conflict state must not suppress observation. Turn the setting back off
   afterwards — the app never does it, and neither does this step.
6. With a second destination due while an external backup holds the slot, confirm
   the waiting state names the holder and that the holder now has its own
   Activity Log row.
7. Press Stop in Escapement's menu bar extra while a backup started from System
   Settings is running. Confirm it actually stops, that the row reads
   "Cancelled", and that Escapement does not start a backup of its own
   immediately afterwards — §6's decision, exercised through the real command
   path rather than the fake.
8. Confirm the known limitation behaves as documented rather than surprisingly:
   with an external backup in flight, `launchctl bootout
   gui/$UID/com.granroth.Escapement.Agent` and re-register from Settings; the
   adopted record should close as "Failed: interrupted", per Out of scope.
9. Leave the agent running with no external activity for an hour and confirm no
   spurious `.external` rows appear — the negative case for a feature whose whole
   input is a polled status string. Watch particularly for a duplicated row
   around the end of a network backup, which is what §4's confirmation exists to
   prevent and what a real destination dropping out of the mount would produce.
