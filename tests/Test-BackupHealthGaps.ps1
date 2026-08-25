# Exercise GAP DETECTION against a fabricated verdict history.
# Production last-run.json, the real note, and the real verdict log are NEVER
# touched -- every path is redirected by parameter.
#
# WHY THIS EXISTS. On 2026-08-11 the host died at ~04:00 and did not recover
# until 08:48, so the scheduled 06:10 check never ran. The gap report still said
# missed=- , because a MANUAL run at 01:00 that day had already stamped that
# local_day and coverage was day-granular. The mechanism built to make absence
# visible reported nothing on the first absence it ever faced.
#
# G2 is that exact scenario and is the reason this file exists. G1 is its
# negative control: without G1, G2 could pass simply because the code reports
# every day as missed.
$ErrorActionPreference = 'Stop'
# Locate the subject relative to this test, so one source runs both from the live tool directory
# (subject alongside) and from a repo clone (tests\ beside scripts\). DO NOT hardcode an absolute
# path here: packaging rewrites absolute paths into angle-bracketed placeholders, and those
# characters are illegal in a Windows path -- which left this test unable to run from a clone for
# every adopter from v0.3.0 onward while still passing at the maintainer's seat.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here 'Invoke-BackupHealthCheck.ps1'
if(-not (Test-Path -LiteralPath $script)){ $script = Join-Path $here '..\scripts\Invoke-BackupHealthCheck.ps1' }
if(-not (Test-Path -LiteralPath $script)){ throw "Invoke-BackupHealthCheck.ps1 not found beside this test or in ..\scripts" }
$sb = Join-Path $env:TEMP ("bhc-gaps-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $sb -Force | Out-Null

$today = (Get-Date).Date
$d1 = $today.AddDays(-1).ToString('yyyy-MM-dd')   # yesterday
$d2 = $today.AddDays(-2).ToString('yyyy-MM-dd')
$d5 = $today.AddDays(-5).ToString('yyyy-MM-dd')

$result = Join-Path $sb 'last-run.json'
$obj = [ordered]@{
    ok = $true; stamp = (Get-Date).ToString('yyyy-MM-dd_HHmm'); tiers = @()
    substitutions = @(); withheld = @(); reportingOk = $true
    log = @(@{ detail = 'mode=Live'; stage = 'test'; ok = $true })
}
[System.IO.File]::WriteAllText($result, ($obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

# Build one verdict line. Omitting -Trigger produces a LEGACY line with no
# trigger field, which is what every entry written before 2026-08-11 looks like.
function New-Line {
    param([string]$Day, [string]$Trigger)
    $o = [ordered]@{ ts_utc = "${Day}T12:00:00.0000000Z"; local_day = $Day }
    if ($Trigger) { $o.trigger = $Trigger }
    $o.alarm = $false; $o.state = 'OK'; $o.healthy = $true
    $o.stamp = "${Day}_0300"; $o.age_hours = 3; $o.reporting = 'OK'
    ($o | ConvertTo-Json -Compress -Depth 4)
}

# Each case gets its OWN verdict log: the check appends a line for TODAY on every
# run, so a shared log would let one case contaminate the next.
function Get-Gaps {
    param([string]$Label, [string[]]$Seed, [string]$Trigger = 'scheduled')
    $vl = Join-Path $sb ("verdicts-" + [guid]::NewGuid().ToString('N').Substring(0,6) + ".jsonl")
    if ($null -ne $Seed -and @($Seed).Count -gt 0) {
        [System.IO.File]::WriteAllText($vl, ((@($Seed) -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script `
        -ResultPath $result -NotePath (Join-Path $sb 'note.md') -VerdictLog $vl -Trigger $Trigger 2>&1
    $g = @($out | Where-Object { "$_" -match '^HEALTHCHECK-GAPS' })
    $line = $(if ($g.Count) { "$($g[0])" } else { '(NO GAPS LINE)' })
    Write-Host ("[" + $Label + "]")
    Write-Host ("   " + $line)
    return @{ gaps = $line; log = $vl }
}

$g1 = Get-Gaps -Label 'G1 NEGATIVE CONTROL: D-1 and D-2 both scheduled -> expect missed=-' `
                -Seed @((New-Line $d2 'scheduled'), (New-Line $d1 'scheduled'))

$g2 = Get-Gaps -Label 'G2 THE 2026-08-11 CASE: D-1 has only a MANUAL run -> expect D-1 missed' `
                -Seed @((New-Line $d2 'scheduled'), (New-Line $d1 'manual'))

$g3 = Get-Gaps -Label 'G3 LEGACY line (no trigger field) on D-1 -> expect D-1 missed' `
                -Seed @((New-Line $d2 'scheduled'), (New-Line $d1 $null))

$g4 = Get-Gaps -Label 'G4 ANCHORING: log begins at D-1 -> expect D-2/D-5 NOT reported' `
                -Seed @((New-Line $d1 'scheduled'))

$g5 = Get-Gaps -Label 'G5 DAY ONE: empty history -> expect missed= - (no false alarm)' -Seed @()

# The flag must actually reach the record. If it does not, G1 would pass for the
# wrong reason on the very next run.
$g6line = (Get-Content -LiteralPath $g1.log | Select-Object -Last 1)

Write-Host ''
Write-Host '=== ASSERTIONS ==='
$checks = @(
    @{ n = "G1 NEGATIVE CONTROL: full scheduled history reports no gaps"; ok = ($g1.gaps -match 'missed=-\s*$') }
    @{ n = "G2 a MANUAL run does NOT mark the day covered ($d1)";         ok = ($g2.gaps -match [regex]::Escape($d1)) }
    @{ n = "G3 a LEGACY untriggered line does NOT mark it covered";       ok = ($g3.gaps -match [regex]::Escape($d1)) }
    @{ n = "G4 days before the log began are not reported";               ok = (($g4.gaps -notmatch [regex]::Escape($d2)) -and ($g4.gaps -notmatch [regex]::Escape($d5))) }
    @{ n = "G5 an empty history reports no gaps";                         ok = ($g5.gaps -match 'missed=-\s*$') }
    @{ n = "G6 -Trigger scheduled is recorded in the verdict";            ok = ($g6line -match '"trigger":"scheduled"') }
)
$fail = 0
foreach ($c in $checks) {
    Write-Host ("  [{0}] {1}" -f $(if ($c.ok) { 'PASS' } else { 'FAIL' }), $c.n)
    if (-not $c.ok) { $fail++ }
}
Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f ($checks.Count - $fail), $fail)
Write-Host ("sandbox: " + $sb)
if ($fail -gt 0) { exit 1 }
exit 0
