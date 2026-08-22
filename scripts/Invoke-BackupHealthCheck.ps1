<#
  Invoke-BackupHealthCheck.ps1 -- deterministic consumer of Get-BackupHealth.

  WHY THIS IS A SCRIPT AND NOT PROMPT TEXT. The scheduled task that runs this is an LLM agent, and
  this week established that an agent must not be the thing that attests to its own side effects.
  So every decision here -- read health, write the note, decide whether to alarm -- is made by
  deterministic code whose output can be checked from outside. The agent's ONLY job is to deliver
  the notification when this script tells it to, which is the one part that genuinely needs a tool
  an agent has and a script does not (mailbox_tools).

  CONTRACT WITH THE CALLER
    Always writes the note. Always exits 0 unless it genuinely could not run.
    Prints exactly one machine-readable line the caller keys off:
        HEALTHCHECK-RESULT alarm=YES|NO state=<STATE> healthy=<bool> stamp=<stamp> age=<hours> reporting=OK|FAILED|ABSENT|UNKNOWN

    `healthy` is the EFFECTIVE verdict: archive health AND reporting integrity. `state` still
    describes the ARCHIVE only, so `state=OK healthy=False reporting=FAILED` is a legitimate and
    expected combination -- the backup is fine, the log note/share mirror is not.
    `reporting`: OK = mirrored and hash-verified. FAILED = it did not complete. ABSENT = the result
    file predates F16 and carries no such field. UNKNOWN = the result file could not be read at all,
    which is NOT the same as ABSENT and must never be reported as one.
    alarm=YES  -> the caller must send ONE notification, quoting Reason from the note.
    alarm=NO   -> the caller says nothing. A checker that speaks when nothing is wrong trains
                  people to ignore it.

  DEDUPLICATION -- ALARM ONLY, NEVER THE CHECK.
    The check runs every tick; it is one small file read. Only the NOTIFICATION is deduplicated,
    keyed on the backup's own `stamp`, the resulting state, AND the reporting flag (F16, 2026-08-01).
    Reporting is part of the key on purpose: without it a reporting failure arriving on an
    already-alarmed (stamp,state) would be swallowed as a duplicate, and a reporting-only failure
    would never clear because the key would not change on recovery. Disarming the CHECK after a success
    would be the stale-success trap wearing a new coat: if the backup stopped running entirely
    there would be no new state to react to, the checker would stay disarmed, and it would go
    silent -- which is indistinguishable from health, the exact anti-pattern this exists to kill.
    Keying on stamp+state+reporting means a new backup, a changed verdict on the same backup, or a
    reporting failure appearing/clearing on an otherwise unchanged backup, all re-arm automatically.
    The key lives in the note itself, so there is no second state file to rot or acquire a BOM.

  THE NOTE IS ALWAYS PRESENT AND DATED, deliberately -- not a marker that exists only on failure.
  A date that stops advancing is itself a signal, and it is the ONLY artifact that catches both
  "the backup failed" and "the checker died", including the case where this very schedule gets
  silently dropped by the loader. Absence cannot carry that information.

  Does not modify Get-BackupHealth, Test-BackupQuiet, backup.ps1, restore.ps1 or config.json.
#>
[CmdletBinding()]
param(
    [string]$NotePath    = '<DATA_DIR>\notes\Backup Health Watch.md',
    [string]$ResultPath  = '<TOOL_DIR>\last-run.json',
    # Parameterised for the same reason NotePath and ResultPath are: the alarm
    # path has to be exercisable against a fabricated state WITHOUT writing into
    # the real verdict history. A test that has to save and restore production
    # data to run is a test people stop running.
    [string]$VerdictLog  = '<TOOL_DIR>\health-verdicts.jsonl',
    # THE SCHEDULE THAT DETERMINES THIS CHECK'S CADENCE. Read (never written) so
    # the note can state the expected cadence as a DERIVED fact instead of a
    # transcribed one. Parameterised like the three paths above so the cadence
    # paragraph is exercisable against a fabricated schedule without touching the
    # live task -- a branch that can only be reached by editing production is a
    # branch nobody tests.
    [string]$SchedulePath = '<DATA_DIR>\schedules\backup-health-check.json',
    # WHY A RUN HAPPENED, recorded because gap detection is day-granular and
    # therefore cannot tell "the 06:10 check fired" from "somebody ran this by
    # hand that day". On 2026-08-11 those two were conflated for real: the host
    # died at 04:00 and did not recover until 08:48, so the scheduled check never
    # ran -- but a manual run at 01:00 had already stamped that local_day, and the
    # gap report said missed=- on the very first occurrence it existed to catch.
    # A day with a verdict and a day whose CHECK FIRED are not the same fact.
    #
    # Defaults to 'manual' on purpose. If the scheduled task ever stops passing
    # -Trigger scheduled, every day reports as missed: a loud false alarm, which
    # is recoverable. The opposite default fails silent, which is the defect.
    [ValidateSet('scheduled','manual','test')]
    [string]$Trigger     = 'manual',
    [double]$MaxAgeHours = 26,
    [int]$HistoryLimit   = 30
)

$ErrorActionPreference = 'Stop'
. '<TOOL_DIR>\backup-window.ps1'

$h   = Get-BackupHealth -ResultPath $ResultPath -MaxAgeHours $MaxAgeHours
$now = Get-Date

# ---- F16 reporting-integrity signal -----------------------------------------------------------
# READ HERE, NOT IN Get-BackupHealth, ON PURPOSE. The two flags answer different questions:
#   ok          -- "is this ARCHIVE trustworthy?"      (drives F15: withholds tier promotion)
#   reportingOk -- "can we still SEE what happened?"   (the log note + share mirror)
# Folding reportingOk into Get-BackupHealth would make a failed markdown copy withhold a
# Weekly/Monthly/Annual archive, which is disproportionate and was explicitly rejected when F16
# was designed. So this is an ADDITIONAL alarm condition layered here, and Get-BackupHealth's
# contract and state vocabulary are untouched -- as this script's header promises.
#
# ABSENT IS NOT FALSE. A last-run.json written before F16 has no reportingOk property at all, and
# `-not $j.reportingOk` evaluates TRUE for an absent property -- which would alarm on every
# historic result file and train everyone to ignore the alarm. Test PRESENCE first, then an
# explicit $false. This is the same idiom Get-BackupHealth already uses for 'ok' ("'ok' absent is
# not the same as ok=false. Refuse rather than guess in either direction.").
# FOUR values, not two. An earlier version of this used a boolean pair, which rendered an
# UNREADABLE result file as "not reported (predates F16)" -- a FALSE CAUSE, and precisely the
# conflation this file states six lines below in "What the states mean": an absent input must never
# read the same as a negative result. UNKNOWN ("could not look") and ABSENT ("looked, no such
# field") are different facts and are now reported as such. (adversarial review, 2026-08-01.)
#   OK       mirrored and hash-verified
#   FAILED   the log note / share mirror did not complete
#   ABSENT   result file predates F16 -- no such field. NOT a failure.
#   UNKNOWN  the result file could not be read or parsed at all.
$reportingBad   = $false
$reportingState = 'UNKNOWN'
if (Test-Path -LiteralPath $ResultPath) {
    try {
        $rj = Get-Content -Raw -LiteralPath $ResultPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($rj.PSObject.Properties.Name -contains 'reportingOk') {
            if ($rj.reportingOk -eq $false) { $reportingBad = $true; $reportingState = 'FAILED' }
            else                            { $reportingState = 'OK' }
        } else {
            $reportingState = 'ABSENT'
        }
    } catch {
        # Stays UNKNOWN. Not silent-and-benign: an unreadable/invalid result file is ALREADY
        # Get-BackupHealth's verdict (UNREADABLE) and drives the alarm on its own, so re-raising it
        # here would double-count one fault. What must NOT happen is it masquerading as ABSENT.
        $reportingState = 'UNKNOWN'
    }
}

# Effective verdict = archive health AND reporting integrity. Kept as a separate variable so every
# downstream use is consistent; using $h.Healthy anywhere below would silently drop the new signal.
$effectiveHealthy = $h.Healthy -and (-not $reportingBad)

$reason = $h.Reason
if ($reportingBad) {
    $reason = "$($h.Reason)  ||  REPORTING FAILURE: the backup log note / share mirror did not complete (reportingOk=false). The ARCHIVE is unaffected and its tier promotion is NOT withheld -- but the recovery-side history on the share is now stale, so a restore would be flying blind about what ran and when. See the 'log-note' stage in last-run.json."
}

# Dedup key carries the reporting flag too, otherwise a reporting failure arriving on an
# already-alarmed (stamp,state) would be suppressed as a duplicate, and a reporting-only failure
# would keep re-alarming after recovery because the key never changed.
$key = "{0}|{1}|{2}" -f $(if ($h.Stamp) { $h.Stamp } else { 'no-stamp' }), $h.State, $(if ($reportingBad) { 'REPORT-FAIL' } else { 'report-ok' })

# ---- read the previous alarm key out of the note (single source of state) -------------------
$prevKey  = $null
$prevBody = $null
if (Test-Path -LiteralPath $NotePath) {
    $prevBody = Get-Content -Raw -LiteralPath $NotePath
    $m = [regex]::Match($prevBody, '<!--\s*alarmKey:\s*(.*?)\s*-->')
    if ($m.Success) { $prevKey = $m.Groups[1].Value }
}

# Alarm only when unhealthy AND this exact (stamp,state,reporting) has not already been alarmed.
$alarm = (-not $effectiveHealthy) -and ($prevKey -ne $key)
# Carry the key forward: once alarmed for a key, stay quiet on it until stamp, state or reporting changes.
$newKey = if ($effectiveHealthy) { '' } elseif ($alarm) { $key } else { $prevKey }

# ---- rolling history: current state in the header, transitions in the table ------------------
# Recovery must not erase the evidence that something failed, so the table keeps prior rows even
# after the state returns to OK.
$rows = New-Object System.Collections.Generic.List[string]
if ($prevBody) {
    foreach ($line in ($prevBody -split "`n")) {
        if ($line -match '^\| \d{4}-\d{2}-\d{2} ') { $rows.Add($line.TrimEnd()) }
    }
}
# 'reporting' is APPENDED as the LAST column deliberately. Inserting it mid-row would leave the
# historic 5-cell rows rendering their 'alarm' value under the 'reporting' header -- actively
# misleading, and worse than no column at all. Appended, old rows simply have an empty final cell,
# which is honest: they genuinely carry no reporting data.
# Without this column a reporting-only alarm leaves an uninterpretable "OK ... ALARMED" row once the
# state recovers -- in the very table that exists so recovery cannot erase the evidence.
$rows.Insert(0, ("| {0} | {1} | {2} | {3} | {4} | {5} |" -f `
    $now.ToString('yyyy-MM-dd HH:mm'), $h.State, $(if ($h.Stamp) { $h.Stamp } else { '-' }),
    $(if ($null -ne $h.AgeHours) { '{0:N1}h' -f $h.AgeHours } else { '-' }),
    $(if ($alarm) { 'ALARMED' } elseif (-not $effectiveHealthy) { 'suppressed' } else { '-' }),
    $reportingState))
while ($rows.Count -gt $HistoryLimit) { $rows.RemoveAt($rows.Count - 1) }

$icon = if ($effectiveHealthy) { 'OK' } else { 'PROBLEM' }
$L = New-Object System.Collections.Generic.List[string]
$L.Add('# Backup Health Watch')
$L.Add('')
$L.Add('Written automatically by `Invoke-BackupHealthCheck.ps1`. Do not hand-edit: it is rewritten every check.')
$L.Add('')
$L.Add("**Last checked**: $($now.ToString('yyyy-MM-dd HH:mm:ss')) local")
$L.Add("**Verdict**: $icon -- state ``$($h.State)``$(if ($reportingBad) { ' + **REPORTING FAILURE**' })")
$L.Add("**Backup stamp**: $(if ($h.Stamp) { '`' + $h.Stamp + '`' } else { '(none)' })$(if ($null -ne $h.AgeHours) { '  ({0:N1}h old)' -f $h.AgeHours })")
$reportingText = switch ($reportingState) {
    'FAILED' { 'FAILED -- see Reason' }
    'OK'     { 'ok -- note mirrored and hash-verified on the share' }
    'ABSENT' { 'not reported (this result file predates F16 and carries no such field -- not a failure)' }
    default  { 'UNDETERMINED -- the result file could not be read or parsed, so reporting integrity is UNKNOWN. This is NOT the same as "not reported"; see the state above for the underlying fault.' }
}
$L.Add("**Reporting (log note + share mirror)**: $reportingText")
$L.Add("**Reason**: $reason")
$L.Add('')
# =============================================================================
# EXPECTED CADENCE -- DERIVED FROM THE SCHEDULE, NEVER TRANSCRIBED (2026-08-16)
#
# [!] The paragraph below is the ONLY guard over "nothing is watching the backup",
# so a wrong number here does not degrade the guard, it INVERTS it -- in both
# directions at once. Measured 2026-08-16: the note said `Expected cadence:
# hourly` while the task had run daily 06:10 since 2026-08-11, so a perfectly
# healthy check 10.6h old read as a dead checker, and a checker that genuinely
# died at 06:11 would have read as healthy for a full 24h. The guard could not
# distinguish the two -- the exact failure class it exists to prevent.
#
# ROOT CAUSE, and why this is a rewrite rather than a corrected string: the
# cadence was hardcoded INDEPENDENTLY of the schedule that determines it, so the
# two were free to diverge and nothing could observe that they had. Editing the
# literal to 'daily 06:10' would fix today's value and leave that property
# intact. It is now read from the schedule file, so the note cannot disagree
# with the task without the task itself being unreadable.
#
# STATED AS A STALENESS THRESHOLD, NOT A FREQUENCY. A reader reaching this note
# is asking "is anything still watching?" and should not have to convert a
# frequency into an age. The threshold is the number they can act on directly.
#
# FAILS LOUD, NOT CONFIDENT. If the schedule is missing, unparseable, or
# disabled, that is said plainly and no threshold is offered. Printing a default
# cadence for an unresolvable schedule would emit a confident wrong number,
# which is precisely the defect being removed here.
$cadenceLines = New-Object System.Collections.Generic.List[string]
try {
    if (-not (Test-Path -LiteralPath $SchedulePath)) { throw "not found at $SchedulePath" }
    # ReadAllText, not Get-Content: PS 5.1 decodes BOM-less UTF-8 as the ANSI
    # codepage, and a schedule JSON carrying a BOM is a known way for this file
    # family to fail (see the schedule-loader BOM defect).
    $schJson = [System.IO.File]::ReadAllText($SchedulePath, [System.Text.Encoding]::UTF8)
    $sch     = $schJson | ConvertFrom-Json

    # Expected hours between consecutive runs. Anything not enumerated here is
    # UNKNOWN rather than assumed -- a new frequency string must not silently
    # inherit some other cadence's threshold.
    $everyH = switch ("$($sch.frequency)".ToLowerInvariant()) {
        'daily'         { 24.0 }
        'weekly'        { 168.0 }
        'monthly'       { 720.0 }
        'every_hours'   { [double]$sch.interval }
        'every_minutes' { [double]$sch.interval / 60.0 }
        default         { $null }
    }

    if ($null -eq $everyH -or $everyH -le 0) {
        $cadenceLines.Add(('> **Expected cadence: UNKNOWN** -- schedule `{0}` declares frequency `{1}`, which this note does not know how to convert into an age. No staleness threshold can be offered; treat that as a defect in its own right.' -f $sch.internalName, $sch.frequency))
    }
    else {
        # Margin: 25% of the interval, floored at 2h. On a daily cadence that is
        # 30h -- comfortably past a late run, well short of a second missed one,
        # so the threshold cannot be tripped by ordinary jitter and cannot hide a
        # wholly skipped occurrence either.
        $threshH = [math]::Round($everyH + [math]::Max(2.0, $everyH * 0.25), 0)
        $when    = if ($sch.time) { " at $($sch.time) local" } else { '' }
        $cadenceLines.Add(('> Expected cadence: **{0}**{1} -- derived from schedule `{2}`, not transcribed here.' -f $sch.frequency, $when, $sch.internalName))
        $cadenceLines.Add(('> **Treat the checker as STOPPED if `Last checked` above is more than {0}h old.**' -f $threshH))
        # The blind window is inherent to the cadence, not to this note, and it
        # is stated rather than glossed: a reader who believes this line closes
        # the whole gap would be wrong about the one thing it cannot do.
        $cadenceLines.Add(('> Between runs there is a blind window of up to ~{0}h -- a checker that dies just after a' -f [math]::Round($everyH,0)))
        $cadenceLines.Add('> successful check looks healthy until the next one is due. What closes that window is the')
        $cadenceLines.Add('> verdict log''s gap report (`HEALTHCHECK-GAPS`), which names days no scheduled run covered.')
        if ($sch.enabled -ne $true) {
            $cadenceLines.Add('>')
            $cadenceLines.Add(('> [!] **THE SCHEDULED CHECK IS DISABLED** (`enabled: false` in `{0}`). Nothing is running this check automatically, so the date above reflects manual runs only and the threshold does not apply.' -f $SchedulePath))
        }
    }
}
catch {
    # Deliberately verbose about WHICH file and WHY: the reader's next action is
    # to go look at it, and "cadence unavailable" without a path sends them hunting.
    $cadenceLines.Add(('> **Expected cadence: UNKNOWN -- the schedule could not be read** ({0}).' -f $_.Exception.Message))
    $cadenceLines.Add('> This line is derived from that file, so with it unreadable there is no threshold to check')
    $cadenceLines.Add('> the date above against. That is a defect in its own right and not a statement about the backup.')
}

$L.Add('> **IF THE `Last checked` DATE ABOVE STOPS ADVANCING, THE CHECKER ITSELF HAS STOPPED.**')
$L.Add('> That is a failure in its own right and means nothing is watching the backup -- regardless of')
$L.Add('> what the verdict line says. This note is deliberately always present and always dated so that')
$L.Add('> a silent checker is visible; a marker that only appears on failure cannot tell you that.')
foreach ($cl in $cadenceLines) { $L.Add($cl) }
$L.Add('')
$L.Add('## Recent checks')
$L.Add('')
$L.Add('| checked (local) | state | backup stamp | age | alarm | reporting |')
$L.Add('|---|---|---|---|---|---|')
foreach ($r in $rows) { $L.Add($r) }
$L.Add('')
$L.Add('## What the states mean')
$L.Add('')
$L.Add('`OK` fresh, Live, ok=true -- the only healthy state. `FAILED` fresh but ok=false.')
$L.Add("``STALE`` last backup older than $MaxAgeHours h **regardless of ok=true** -- a stale success is")
$L.Add('byte-identical to a fresh one, which is why age is checked first. `DRYRUN` a rehearsal, not a')
$L.Add('copy. `MISSING` / `UNREADABLE` no usable result file -- reported distinctly from `FAILED`,')
$L.Add('because an absent input must never read the same as a negative result.')
$L.Add('')
$L.Add('**Reporting** is a SEPARATE axis from the states above, deliberately. `ok` answers "is this')
$L.Add('archive trustworthy"; `reportingOk` answers "can we still see what happened". A reporting')
$L.Add('failure alarms but does **not** withhold tier promotion -- a markdown mirror that failed to')
$L.Add('copy must not cost a Weekly/Monthly/Annual archive. Four values, and the last two are NOT the')
$L.Add('same fact: `ABSENT` means we looked and the result file carries no such field (it predates')
$L.Add('F16) -- not a failure; `UNKNOWN` means we could not read the file at all. An absent field is')
$L.Add('never read as a false one, and an unreadable input is never reported as an absent field.')
$L.Add('')
$L.Add("<!-- alarmKey: $newKey -->")

# NOT Split-Path: its LiteralPathSet is {LiteralPath, Resolve, Credential} and contains no -Parent,
# so `Split-Path -LiteralPath X -Parent` is an unresolvable parameter set. Worse, PS reports that
# failure against the CALLING SCRIPT's name as a ParameterBindingException, which reads exactly like
# the script's own param block is broken. Using -Path would resolve, but -Path does wildcard
# expansion and a note title may legitimately contain [ or ]. The API call has neither problem.
$dir = [System.IO.Path]::GetDirectoryName($NotePath)
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# No-BOM UTF-8, written atomically. NEVER Set-Content: on PS 5.1 it emits a BOM, and a BOM in a
# file the app parses is silently fatal -- three instances this week, one of which disarmed the
# monitor for two nights.
# LF, matching the existing notes in that directory (they are LF; the schedule JSONs are not).
$text = ($L -join "`n") + "`n"
$tmp  = "$NotePath.tmp"
[System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmp -Destination $NotePath -Force

# =============================================================================
# VERDICT LOG -- EVERY RUN LEAVES A TRACE, PASS OR ALARM (2026-08-11)
#
# [!] Until now a passing check wrote NOTHING. So "the check ran and everything
# was fine" and "the check never ran" produced byte-identical evidence: none.
# That is why this task was ORIGINALLY set to run HOURLY -- frequency was
# compensating for a signal that could not be observed. The backup runs once a
# night, so 24 runs a day produced the same one bit of information and 24x the
# exposure to a session that fails to start.
#
# CURRENT CADENCE IS DAILY 06:10 (the maintainer, 2026-08-11), and the paragraph above is
# past tense on purpose -- it explains why hourly WAS chosen, not what runs now.
# The verdict log below is what made once-a-day safe. Do not read this comment as
# a statement of the live cadence: the schedule file is the authority, this script
# derives the note's cadence text from it, and `_note_cadence` in that file prices
# the cost of the daily choice (a missed occurrence is skipped with no catch-up).
#
# Absence must be distinguishable from health. One JSONL line per run, always.
# The next run reads this file, finds the gaps, and reports the days that are
# missing -- so a run that never happened is caught by the following run rather
# than by a second watchdog that can fail exactly the same way.
#
# Appended, never rewritten: a verdict history that a later run can edit is not
# a history. Failure here must NOT fail the check -- the verdict is the product,
# the log is bookkeeping.
# =============================================================================
$verdictLog = $VerdictLog
try {
    $verdict = [ordered]@{
        ts_utc    = [datetime]::UtcNow.ToString('o')
        local_day = (Get-Date).ToString('yyyy-MM-dd')
        trigger   = [string]$Trigger
        alarm     = [bool]$alarm
        state     = [string]$h.State
        healthy   = [bool]$effectiveHealthy
        stamp     = $(if ($h.Stamp) { [string]$h.Stamp } else { $null })
        age_hours = $(if ($null -ne $h.AgeHours) { [math]::Round($h.AgeHours, 1) } else { $null })
        reporting = [string]$reportingState
    }
    $line = ($verdict | ConvertTo-Json -Compress -Depth 4)
    # Append with no BOM. Set-Content/Add-Content emit one on 5.1 and a BOM in a
    # machine-parsed file has already been silently fatal three times here.
    [System.IO.File]::AppendAllText($verdictLog, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
}
catch {
    Write-Warning "verdict log not written: $($_.Exception.Message)"
}

# GAP DETECTION. Report local days since the first verdict that have no
# SCHEDULED entry. Bounded to the last 14 days: an unbounded report after a long
# shutdown is noise, and the point is "did we miss a check", not a calendar.
#
# COVERAGE COMES ONLY FROM trigger='scheduled'; the ANCHOR comes from any entry.
# The two differ on purpose. A manual or test run proves the check EXISTED that
# day, so it is fair to anchor on -- but it does not prove the scheduled
# occurrence fired, so it must not mark the day covered. Counting any entry as
# coverage is what let 2026-08-11 report missed=- on a day the 06:10 run never
# happened. Lines predating this field have no trigger, so they anchor without
# covering, which is the correct reading of them.
$missedDays = @()
try {
    if (Test-Path -LiteralPath $verdictLog) {
        $seenAny   = @{}
        $seenSched = @{}
        foreach ($l in [System.IO.File]::ReadAllLines($verdictLog)) {
            if ([string]::IsNullOrWhiteSpace($l)) { continue }
            try {
                $o   = $l | ConvertFrom-Json
                $day = [string]$o.local_day
                if ([string]::IsNullOrWhiteSpace($day)) { continue }
                $seenAny[$day] = $true
                if ([string]$o.trigger -eq 'scheduled') { $seenSched[$day] = $true }
            } catch { }
        }
        $today = (Get-Date).Date
        for ($d = 13; $d -ge 1; $d--) {
            $key = $today.AddDays(-$d).ToString('yyyy-MM-dd')
            if (-not $seenSched.ContainsKey($key)) { $missedDays += $key }
        }
        # Only report days at or after the first verdict of ANY kind -- before
        # that there was no check to miss, and reporting those would be a false
        # alarm on day one.
        $firstDay = ($seenAny.Keys | Sort-Object | Select-Object -First 1)
        if ($firstDay) { $missedDays = @($missedDays | Where-Object { $_ -ge $firstDay }) }
        else           { $missedDays = @() }
    }
}
catch {
    Write-Warning "gap detection unavailable: $($_.Exception.Message)"
}

# 'healthy' is the EFFECTIVE verdict (archive AND reporting); 'reporting' is additive so a caller
# can tell the two apart. Widening healthy=False can only cause more attention, never less, which
# is the safe direction for a contract change on a health signal.
"HEALTHCHECK-RESULT alarm=$(if ($alarm) { 'YES' } else { 'NO' }) state=$($h.State) healthy=$effectiveHealthy stamp=$(if ($h.Stamp) { $h.Stamp } else { '-' }) age=$(if ($null -ne $h.AgeHours) { '{0:N1}' -f $h.AgeHours } else { '-' }) reporting=$reportingState"
if ($alarm) { "HEALTHCHECK-REASON $reason" }
# ADDITIVE second line, so the existing RESULT contract above is unchanged.
# missed=- means no gaps. A missed day is a check that did not happen, which is
# a reportable state in its own right and NOT an alarm about the backup.
"HEALTHCHECK-GAPS missed=$(if (@($missedDays).Count -gt 0) { ($missedDays -join ',') } else { '-' })"
exit 0
