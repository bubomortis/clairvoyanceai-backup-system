<#
  backup-window.ps1 -- shared reader for the Clairvoyance backup quiesce window.

  ONE implementation, dot-sourced by every orchestrator. The contract used to live only in the
  Build Runbook as prose ("before any automated run, check for the BACKUP_IN_PROGRESS flag"), and
  an audit on 2026-07-27 found that ZERO orchestrators actually did it. Prose is not a control.

  USAGE (unprivileged orchestrators only):
      . "<TOOL_DIR>\backup-window.ps1"
      if (Test-BackupQuiet) { return }        # stand down, try again next tick

  Lives beside the lease in the ACL-hardened backup directory (see the trust-boundary note below).
  backup.ps1 (SYSTEM) WRITES the lease and never reads this module; that asymmetry is deliberate.
#>

# TRUST BOUNDARY -- FIXED AT THE ROOT, not mitigated at the callsite.
#
# THIS FILE MUST LIVE IN AN ACL-HARDENED DIRECTORY, and it lives here for that reason: no
# `Authenticated Users` ACE. A module advertising itself as "the shared module for every
# orchestrator" while being user-writable is an invitation. Do not move it back to a user-writable
# location and document the boundary instead of enforcing it.
#
# DO NOT "enforce" this by throwing for Administrator-role callers. That was measured and would
# DISABLE THIS GATE ENTIRELY here: orchestrator ticks already run elevated, callers wrap the
# dot-source in try/catch and fail open, so the throw is swallowed and Test-BackupQuiet simply
# never runs again -- a control that silently becomes a permanent no-op. A warning instead fires on
# 100% of normal runs and trains everyone to ignore it.
#
# It also buys a property worth keeping: the module and the lease it reads now SHARE FATE. Any
# identity that cannot read this file cannot read the lease either, so there is no configuration
# where one is visible and the other is not.
#
# DEPENDENCY THIS CREATES -- read before de-elevating orchestrators. This directory grants only
# SYSTEM / Administrators / <PC>\<YOU>. That works today precisely BECAUSE orchestrator
# ticks run elevated as <YOU>. The right long-term direction is to de-elevate them -- and by the
# shared-fate property above, an unprivileged identity would then be able to read neither the
# module nor the lease, so this gate stops working for it until that identity is granted read on
# <TOOL_DIR>. It fails LOUDLY, not silently (the caller's catch prints
# "gate unavailable ... proceeding", and Test-BackupQuiet reports the INERT case distinctly), so
# this is a sequencing note, not a defect. GRANT THE READ AS PART OF ANY DE-ELEVATION CHANGE.
#
# The SYSTEM block below is retained as a DESIGN separation, no longer an escalation guard:
# backup.ps1 is the lease WRITER and must never become a reader of its own gate.
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18') {
    throw 'backup-window.ps1 must not be dot-sourced from SYSTEM context. backup.ps1 is the lease WRITER and must never read this module; orchestrators that consume the gate run unprivileged or as the interactive user.'
}

# Default lease path. Callers may override with -LeasePath; the backup's own config.json is the
# authority, but reading THAT from here would just move the hardcoded path one level down.
$script:BackupLeaseDefaultPath = '<TOOL_DIR>\BACKUP_IN_PROGRESS'

<#
.SYNOPSIS
  $true if a backup lease is currently held (caller should NOT start new work).

.DESCRIPTION
  FAILS OPEN, deliberately and in every direction: unreadable, malformed, unparseable date,
  missing expiresAt, or any unexpected error all return $false (= proceed).

  Quiescing is an OPTIMISATION, not a safety control -- the backup's copy is crash-consistent
  whether or not the fleet is quiet. So the two failure modes are not symmetric:
      fail-open  costs a slower backup.
      fail-closed costs a SILENTLY DEAD AUTOMATION FLEET, on one bad file, until a human notices.
  This is deliberately the OPPOSITE of the fail-closed posture used for secrets and overage, where
  the failure mode is silent data loss or unbounded spend. Do not "harmonise" the two.

  NEVER DELETES THE LEASE FILE. An expired lease is IGNORED, not cleaned up. Removing it is what a
  janitor does, and the janitor is the bug: on 2026-07-27 the Nightly Backup Monitor judged the
  flag stale and deleted it while 7-Zip was actively compressing. Expiry replaces that judgement.
  If you are about to add a Remove-Item here, re-read this paragraph.
#>
function Test-BackupQuiet {
    [CmdletBinding()]
    param(
        [string]$LeasePath = $script:BackupLeaseDefaultPath,
        [switch]$Explain
    )

    $verdict = { param($quiet, $reason)
        if ($Explain) { Write-Host ("[backup-window] quiet={0} :: {1}" -f $quiet, $reason) }
        return $quiet
    }

    try {
        # "Absent" and "unreadable" are different facts, and Test-Path reports $false for BOTH.
        # Distinguish them before concluding anything (adversarial review 2026-07-27). The gate resolves today
        # only because <TOOL_DIR> grants `<PC>\<YOU>` directly --
        # there is no Users or Authenticated Users ACE. Re-create that account with a new SID, or
        # run an orchestrator as any other identity, and this gate becomes a PERMANENT no-op that
        # reports "clear to run" forever -- while the test suite still passes, because the harness
        # runs as <YOU> too. Still fail open, but never silently: a control that can quietly become
        # inert is barely better than the prose it replaced.
        if (-not (Test-Path -LiteralPath (Split-Path $LeasePath -Parent))) {
            return (& $verdict $false 'lease DIRECTORY not readable from this identity -- gate is INERT, failing open (this is NOT "no backup running")')
        }
        if (-not (Test-Path -LiteralPath $LeasePath)) {
            return (& $verdict $false 'no lease file -- clear to run')
        }

        $raw = Get-Content -Raw -LiteralPath $LeasePath -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return (& $verdict $false 'lease file empty -- failing OPEN')
        }

        # --- Flags with NO USABLE EXPIRY: mtime + bounded grace, never "quiet forever". ---
        # Two ways to get here: a pre-2026-07-27 plain-text flag ("backup in progress since ..."),
        # reachable any time backup.ps1 is rolled back to a snapshot or run from the _Restore copy;
        # or JSON missing expiresAt. Both are still real "a backup is running" signals, so ignoring
        # them outright would resume the fleet on top of a live backup.
        #
        # But honouring them UNCONDITIONALLY reintroduces the exact bug this lease design exists to
        # kill: no expiry means quiet FOREVER once the owner dies without cleaning up -- and the
        # owner dying without cleaning up is precisely the 2026-07-23 / 2026-07-27 case. A
        # fail-closed branch inside a fail-open design is still a fail-closed design, on the path
        # that matters. Caught on review of my own draft, which had exactly that hole.
        #
        # So: honour it, but only for $graceMinutes after the file was last written. That bounds the
        # silence and self-heals with no janitor. Default 120 -- far beyond any observed run
        # (nominal 18 min, worst contended ~60) yet still finite.
        $graceMin = 120
        $lease = $null
        try { $lease = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $lease = $null }

        $noExpiryReason = $null
        if ($null -eq $lease) { $noExpiryReason = 'legacy non-JSON flag' }
        elseif (-not ($lease.PSObject.Properties.Name -contains 'expiresAt')) { $noExpiryReason = 'lease has no expiresAt' }

        if ($noExpiryReason) {
            $age = (New-TimeSpan -Start (Get-Item -LiteralPath $LeasePath).LastWriteTime -End (Get-Date)).TotalMinutes
            if ($age -lt $graceMin) {
                return (& $verdict $true ("{0} -- honouring on mtime, age {1:N0}m < {2}m grace" -f $noExpiryReason, $age, $graceMin))
            }
            return (& $verdict $false ("{0}, and it is {1:N0}m old (> {2}m grace) -- ignoring (NOT deleting); clear to run" -f $noExpiryReason, $age, $graceMin))
        }

        $exp = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$lease.expiresAt, [ref]$exp)) {
            return (& $verdict $false "lease expiresAt unparseable ('$($lease.expiresAt)') -- failing OPEN")
        }

        if ((Get-Date) -lt $exp) {
            return (& $verdict $true ("lease HELD by $($lease.owner) pid=$($lease.ownerPid) stage=$($lease.stage), expires $($exp.ToString('HH:mm:ss'))"))
        }

        # Expired. Ignore it; do not remove it. See the .DESCRIPTION note above.
        return (& $verdict $false ("lease EXPIRED at $($exp.ToString('HH:mm:ss')) -- ignoring (NOT deleting); clear to run"))
    }
    catch {
        return (& $verdict $false "lease unreadable ($($_.Exception.Message)) -- failing OPEN")
    }
}

<#
.SYNOPSIS
  Convenience wrapper: writes one line and returns $true if the caller should stand down.
#>
function Stop-IfBackupQuiet {
    [CmdletBinding()]
    param([string]$LeasePath = $script:BackupLeaseDefaultPath, [string]$Caller = $MyInvocation.PSCommandPath)
    if (Test-BackupQuiet -LeasePath $LeasePath) {
        Write-Host ("[backup-window] {0}: backup in progress -- standing down this tick." -f $(if ($Caller) { Split-Path $Caller -Leaf } else { 'orchestrator' }))
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------------------------
# CONSUMER-SIDE BACKUP HEALTH. Added 2026-07-28.
#
# Backup health had NO programmatic consumer outside backup.ps1 (the writer) and the Nightly
# Backup Monitor -- a scheduled task hosted inside the Clairvoyance GUI app. On 2026-07-27/28 that
# monitor stopped running for two nights (a UTF-8 BOM made the app's schedule loader drop the task
# silently) and nothing noticed, because the component that reports problems was the component
# that stopped. A watcher has an independent liveness requirement; a check invoked AT THE MOMENT A
# CALLER RELIES ON THE ANSWER does not, so it cannot go quiet that way. That is why this lives
# here, in the module every orchestrator already dot-sources, rather than in another scheduled task.
# ---------------------------------------------------------------------------------------------

# The backup's result file. Same directory as the lease, so the shared-fate property in the header
# note applies to this too: any identity that cannot read one cannot read the other.
$script:BackupResultDefaultPath = '<TOOL_DIR>\last-run.json'

<#
.SYNOPSIS
  Freshness + success verdict on the nightly backup's result file.

.DESCRIPTION
  FAILS CLOSED -- deliberately, and in the OPPOSITE direction to Test-BackupQuiet above. Read that
  function's .DESCRIPTION before 'harmonising' the two. They answer different questions and their
  failure costs are not symmetric:
      Test-BackupQuiet wrong  -> a slower backup.                          (cheap)   -> fail OPEN
      Get-BackupHealth wrong  -> you believe you have backups you do not.  (ruinous) -> fail CLOSED
  Only State 'OK' returns Healthy = $true. MISSING, UNREADABLE, STALE, DRYRUN and FAILED are all
  Healthy = $false.

  THE FAILURE THIS CLOSES. last-run.json carries `ok` from whichever run last wrote it, so a stale
  ok=true from a previous night is BYTE-IDENTICAL to a fresh success. `stamp` is the only field that
  separates them, and until now nothing read it. Age is therefore checked BEFORE `ok` and beats it
  outright: a stamp older than -MaxAgeHours is a FAILURE however cheerful `ok` is.

  AN ABSENT INPUT MUST NOT PRODUCE THE SAME ANSWER AS A NEGATIVE RESULT. 'MISSING' and 'UNREADABLE'
  are reported distinctly from 'FAILED', and none of them is Healthy. Do not collapse them.

.OUTPUTS
  [pscustomobject] Healthy, State, Reason, Stamp, StampLocal, AgeHours, Ok, Path
  State: OK | FAILED | STALE | DRYRUN | MISSING | UNREADABLE
#>
function Get-BackupHealth {
    [CmdletBinding()]
    param(
        [string]$ResultPath  = $script:BackupResultDefaultPath,
        [double]$MaxAgeHours = 26
    )

    $out = { param($healthy, $state, $reason, $stamp, $local, $age, $ok)
        [pscustomobject]@{
            Healthy = [bool]$healthy; State = $state; Reason = $reason
            Stamp   = $stamp;         StampLocal = $local; AgeHours = $age; Ok = $ok
            Path    = $ResultPath
        }
    }

    # 'Directory unreadable' and 'file absent' are different facts and Test-Path returns $false for
    # BOTH. Same distinction Test-BackupQuiet makes above, for the same reason.
    if (-not (Test-Path -LiteralPath (Split-Path $ResultPath -Parent))) {
        return (& $out $false 'UNREADABLE' 'result DIRECTORY not readable from this identity -- this is NOT the same as "no backup ran"' $null $null $null $null)
    }
    if (-not (Test-Path -LiteralPath $ResultPath)) {
        return (& $out $false 'MISSING' "no result file at $ResultPath -- either the backup has never written one, or it was removed" $null $null $null $null)
    }

    try   { $raw = Get-Content -Raw -LiteralPath $ResultPath -ErrorAction Stop }
    catch { return (& $out $false 'UNREADABLE' "result file unreadable ($($_.Exception.Message))" $null $null $null $null) }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return (& $out $false 'UNREADABLE' 'result file is empty' $null $null $null $null)
    }

    # NOTE: this file is written WITH a UTF-8 BOM. ConvertFrom-Json tolerates it; JSON.parse in Node
    # does not. If this check is ever reimplemented outside PowerShell, strip U+FEFF explicitly and
    # keep the failure fail-closed -- that exact BOM is what silently disarmed the monitor.
    $j = $null
    try   { $j = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch { return (& $out $false 'UNREADABLE' "result file is not valid JSON ($($_.Exception.Message))" $null $null $null $null) }

    $stamp = if ($j.PSObject.Properties.Name -contains 'stamp') { [string]$j.stamp } else { $null }
    if ([string]::IsNullOrWhiteSpace($stamp)) {
        return (& $out $false 'UNREADABLE' 'result file carries no stamp -- freshness cannot be established, so it cannot be called healthy' $null $null $null $null)
    }

    # backup.ps1 writes $stamp = $now.ToString('yyyy-MM-dd_HHmm') from Get-Date, i.e. LOCAL time.
    # Parse it EXACTLY: a lenient parse that guesses a format is worse than refusing to read it.
    $local = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($stamp, 'yyyy-MM-dd_HHmm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$local)) {
        return (& $out $false 'UNREADABLE' "stamp '$stamp' is not in the expected yyyy-MM-dd_HHmm form" $stamp $null $null $null)
    }

    $age = (New-TimeSpan -Start $local -End (Get-Date)).TotalHours

    # A stamp in the FUTURE is clock skew or corruption -- never freshness. Allow an hour of slop
    # (a DST boundary or a mid-run clock nudge), refuse beyond it rather than reading it as fresh.
    if ($age -lt -1) {
        return (& $out $false 'UNREADABLE' ("stamp {0} is {1:N1}h in the FUTURE -- clock skew or corruption, not freshness" -f $stamp, [math]::Abs($age)) $stamp $local $age $null)
    }

    # 'ok' absent is not the same as ok=false. Refuse rather than guess in either direction.
    if (-not ($j.PSObject.Properties.Name -contains 'ok')) {
        return (& $out $false 'UNREADABLE' 'result file carries no ok field' $stamp $local $age $null)
    }
    $ok = [bool]$j.ok

    # AGE BEATS ok. This ordering is the entire point of the function -- see .DESCRIPTION.
    if ($age -gt $MaxAgeHours) {
        return (& $out $false 'STALE' ("last backup stamp {0} is {1:N1}h old (limit {2}h) -- STALE regardless of ok={3}" -f $stamp, $age, $MaxAgeHours, $ok) $stamp $local $age $ok)
    }

    # A DryRun run overwrites this file with ok=true while copying nothing (measured 2026-07-23).
    # Fresh + ok + rehearsal is not a backup. backup.ps1 logs 'mode=<Mode>' as its first entry.
    $mode = $null
    if (($j.PSObject.Properties.Name -contains 'log') -and (@($j.log).Count -gt 0)) {
        $detail = [string]@($j.log)[0].detail
        if ($detail -match 'mode=(\w+)') { $mode = $Matches[1] }
    }
    if ($mode -and $mode -ne 'Live') {
        return (& $out $false 'DRYRUN' "result was produced by a $mode run, not a Live backup -- ok=$ok describes a rehearsal, not a copy" $stamp $local $age $ok)
    }

    if (-not $ok) {
        return (& $out $false 'FAILED' "backup stamp $stamp reported ok=false" $stamp $local $age $ok)
    }

    return (& $out $true 'OK' ("backup stamp {0} is {1:N1}h old and reported ok=true" -f $stamp, $age) $stamp $local $age $ok)
}

<#
.SYNOPSIS
  Boolean wrapper. $true only when the backup is fresh, Live and ok.

.DESCRIPTION
  For call sites that just want a gate. Use -Explain to print the state and reason. Anything other
  than a fresh successful Live backup returns $false -- see Get-BackupHealth for why that includes
  a missing or unreadable result file.
#>
function Test-BackupHealthy {
    [CmdletBinding()]
    param(
        [string]$ResultPath  = $script:BackupResultDefaultPath,
        [double]$MaxAgeHours = 26,
        [switch]$Explain
    )
    $h = Get-BackupHealth -ResultPath $ResultPath -MaxAgeHours $MaxAgeHours
    if ($Explain) { Write-Host ("[backup-window] healthy={0} state={1} :: {2}" -f $h.Healthy, $h.State, $h.Reason) }
    return $h.Healthy
}
