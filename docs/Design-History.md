# Design History

Superseded reasoning, measurements, and decisions whose *conclusions* live in the code but whose
*derivations* do not belong there.

**Why this file exists.** A comment earns its place in the source if a future editor would introduce
a defect without it. Everything else — why a change was undertaken, what was measured, what a
previous version got wrong, and who found it — is release history. Keeping it inline pushed
`backup.ps1` to 48.5% comments, where the constraints that genuinely stop defects were buried among
paragraphs of postmortem.

Nothing here is required reading to work on the code safely. It is here so the reasoning is
recoverable rather than lost, and so nobody re-derives a number that was already withdrawn.

> ⚠️ **Some numbers below are explicitly WRONG and are recorded as withdrawn.** They are kept
> because they were quoted as fact after the reasoning behind them was superseded, which is the
> failure mode this document exists to prevent. Do not re-quote a struck figure.

---

## Pause-lease TTL — how 120 minutes was arrived at

*Constraint that remains in `backup.ps1`: the TTL is 120, it is clamped 30–240, and it must not be
shortened because a too-short TTL is self-amplifying.*

### The problem the lease solves

The `finally` that clears the pause flag **does not run when the process is killed** — reboot,
`TerminateProcess`, hard power loss. That is not theoretical: the flag was stranded on 2026-07-23,
and again on 2026-07-27 when the run was hard-killed mid-compress by the scheduled task's
`ExecutionTimeLimit` (then `PT40M`). A bare marker therefore silences the whole automation fleet
indefinitely after any hard kill.

The obvious fix — a janitor process deciding whether the owner is still alive — is exactly what
**cleared the flag on a live backup on 2026-07-27, while 7-Zip was still compressing.** An expiring
lease deletes the janitor *role*: a reader treats an expired lease as absent and never removes the
file. Nobody has to guess at liveness.

### Two errors in the first sizing, both worth recording

The first version of this reasoning sized the TTL against the longest gap between `Log` calls and
picked **45 minutes**. That was wrong twice over (corrected 2026-07-27 after review).

**1. Right-censored evidence.** The 45 was justified by "compress ran 03:31 → past 04:00 on 07-27",
a ~29 minute gap. **Both halves were wrong**, and the second only surfaced after the root cause was
corrected. The run was hard-killed at ~03:40 by the task's `ExecutionTimeLimit`, *not* by the 04:00
host reboot — last write 03:39 = start + 40 min, and an attended run the same day died at exactly
40 min with no reboot involved. Compress was never running past 04:00: the real gap was nearer
9 min, and the "29" was an inference *from the wrong cause*, not a measurement.

> 🛑 **The ~29 minute figure is withdrawn. Do not re-quote it.** The lesson survives its own bad
> number: sizing a margin from a censored observation understates it by an unknown amount, and a
> superseded root cause leaves its inferences behind — those are what get quoted later as fact.

**2. Wrong long pole.** Measured from the last complete run (2026-07-26, 18.4 min), the largest gap
is `secrets-split` → `secret-scrub` at **12.07 min** — 65% of the whole nominal run inside one
un-renewed interval — not compress, which the original reasoning addressed.

> 🛑 **The "3.3x contention factor" is also struck**, for the same reason: it compared a killed run
> against a completed one, so it is a *lower bound* of ~2.2x with the true value unknown.

**Superseding direct observation.** The attended run on 2026-07-27 was watched live via the lease's
`stage` field and showed stages of **19–28 minutes** — `secrets-split` alone sat at 19 min with no
intervening `Log` call and was still climbing. That is measurement, not inference, and it justifies
120 on its own: roughly 10x the measured nominal worst gap, and >4x the longest gap ever actually
watched live.

### A justification that was withdrawn for being unverifiable

An earlier draft justified 120 as "the 03:00-start / 05:00-reboot window physically caps a run at
120 min". **That bound is not verifiable from inside this guest**, and a reviewer correctly
challenged it after finding no such scheduled task.

The nuance: the reboot *is* scheduled — just not here. It is driven by `qemu-ga` on behalf of the
hypervisor (System event 1074, fired at 04:00:0x for 14 consecutive days, which is not Windows
Update), so `Get-ScheduledTask` in the guest **cannot see it by construction** and its absence there
proves nothing either way.

The conclusion stands regardless: resting a safety margin on a bound the process cannot observe is
the same error class as the censored 29 above — an inferred limit standing in for a measured one.
Rest it on the gap margin, which is evidence we hold.

### Footnote: the binding ceiling was a third thing entirely

Later the same day (2026-07-27), the reviewer's challenge turned out to be more right than either
party knew. The binding ceiling was never the reboot — it was **the scheduled task's own
`ExecutionTimeLimit`, `PT40M`, set at go-live 2026-07-12 and referenced in no config, script or
runbook.** It has since been raised to `PT2H`, which is why the 120 here and the task limit now
agree rather than contradict.

There are **three overrun guards in three different places**, and only one of them lives in this
codebase. See `_note_overrun_guards` in `config.json`.

### Why not go higher than 120

A hard kill can land at any time (task limit or host reboot), so the post-kill quiet window should
stay short enough to self-heal within a couple of orchestrator ticks — those run on 60-minute and
2-hour periods.

---

## Scan-coverage delta assert — why the tolerances are wide

*Constraint that remains in `backup.ps1`: do not tighten the ratio band; the detection weight sits
on the per-bucket jumps.*

Coverage drifts downward on its own as binary files accumulate in the mirror. Measured over
2026-08-11 → 08-13: `skipBin` ran **435 → 464 → 521**, and `Δscanned` trailed `Δtotal` by **29 then
57 files** on those same nights.

A ratio assert tight enough to catch a reader regression would therefore have fired on ordinary
churn within a week — and an assert that fires on ordinary churn gets muted, which is worse than no
assert at all. Hence a wide ratio band, with the real detection weight on per-bucket jumps
(`misread → skipRead`, `misclassified → skipBin`), which is where a reader regression actually
shows up.

The anchor's seed baseline measured **97.04%** against three Live nights at **97.40 / 97.36 /
97.09** — within 0.05pp, which is what makes it a good *level* anchor despite being a replica of the
scan path rather than the shipped function. It must never be used for a per-night delta.

---

## Reparse-point walk — the version-scoped safety property

*Constraint that remains in `backup.ps1`: do not depth-bound the walk.*

An unbounded recursive walk over a tree containing junctions is only safe because
**`Get-ChildItem -Recurse` does not descend into reparse points.** That was verified with a positive
control on **PowerShell 5.1.22621.6133**.

The version pin matters: if that behaviour ever changes across a PowerShell version, this claim is
what needs re-testing, and someone reading only "verified with a positive control" would not know
the verification was version-scoped. An earlier depth cap was removed after measuring its cost at
+2.3s per nightly against a 60-minute ceiling — 0.07% of the margin — while it missed a live
junction at depth 6 on a mirrored path.

---

## Backup log note — why the monitor could not own the share mirror

*Constraint that remains in `backup.ps1`: one writer, one direction, every run.*

Ownership of the log note moved out of the AI monitor prompt and into `backup.ps1` on 2026-08-01.

The monitor drove PowerShell through a bash/MSYS argument layer that eats `\\`, so **every UNC write
collapsed** — `Copy-Item`, `cmd /c copy` and `robocopy` all failed *identically*, which is why
"switch tools" never helped. `backup.ps1` has no such layer and already writes that exact share
every night. The capability was never missing; the **owner** was, and an owner that punts on failure
is not an owner.

The failure this prevents: an 8-day divergence where the share copy was stale to 07-31 and the local
copy stale from 07-30, because two actors wrote two copies with no defined authority.

---

## Elevated binary resolution — how the standing rule became a rule

*Constraint that remains in `backup.ps1`: anything running elevated resolves its binaries by
absolute path, never by PATH; the tools manifest is not a trusted source; and the fix is not to
harden the tools directory. The threat model and the proof-of-concept are in `SECURITY.md`.*

The rule previously existed **only as the comment on the `$robocopy` line** — pinned at one call
site instead of stated as a rule. That is exactly why it did not protect the two bare `& rclone` and
`& ollama` calls in `Write-Recovery`. Those are now gone, and the rule is stated once, at the top,
where someone adding an external command will read it.

The escalation from latent to live was a proposal to put a user-writable shared tools directory on
the **machine PATH**. The corollary separating EXECUTION from INGESTION was added 2026-07-26 after
review, when an earlier version of the rule said "or read the value from the tools manifest" — which
a future author following it literally would have used to restore the escalation by another route.
