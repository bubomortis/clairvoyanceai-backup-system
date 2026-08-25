# Exercise the ALARM path end to end against a fabricated state.
# Production last-run.json, the real note, and the real verdict log are NEVER
# touched -- every path is redirected by parameter.
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
$sb = Join-Path $env:TEMP ("bhc-alarm-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $sb -Force | Out-Null
$result  = Join-Path $sb 'last-run.json'
$note    = Join-Path $sb 'Backup Health Watch.md'
$verdict = Join-Path $sb 'health-verdicts.jsonl'

function Set-Fixture {
    param([bool]$Ok, [string]$Stamp, [bool]$ReportingOk)
    $obj = [ordered]@{
        ok = $Ok; stamp = $Stamp; tiers = @(); substitutions = @(); withheld = @()
        reportingOk = $ReportingOk
        log = @(@{ detail = 'mode=Live'; stage = 'test'; ok = $Ok })
    }
    [System.IO.File]::WriteAllText($result, ($obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
}

function Run-Check {
    param([string]$Label)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script `
        -ResultPath $result -NotePath $note -VerdictLog $verdict 2>&1
    $res = @($out | Where-Object { "$_" -match '^HEALTHCHECK-RESULT' })
    $rea = @($out | Where-Object { "$_" -match '^HEALTHCHECK-REASON' })
    Write-Host ("[" + $Label + "]")
    Write-Host ("   " + $(if ($res.Count) { $res[0] } else { '(NO RESULT LINE)' }))
    if ($rea.Count) { Write-Host ("   " + $rea[0]) }
    return @{ result = $(if ($res.Count) { "$($res[0])" } else { '' }); reason = $(if ($rea.Count) { "$($rea[0])" } else { '' }) }
}

# A FAILED backup, freshly stamped so age is not the trigger -- ok=false is.
Set-Fixture -Ok $false -Stamp ((Get-Date).ToString('yyyy-MM-dd_HHmm')) -ReportingOk $true
$r1 = Run-Check -Label '1. FAILED backup, first sight  -> expect alarm=YES + REASON'

# Same state again -> the notification must be SUPPRESSED (dedup on stamp+state+reporting).
$r2 = Run-Check -Label '2. SAME state again           -> expect alarm=NO (deduplicated, not forgotten)'

# A NEW backup that is still failing -> dedup must RE-ARM on a new stamp.
Start-Sleep -Seconds 1
Set-Fixture -Ok $false -Stamp ((Get-Date).AddMinutes(1).ToString('yyyy-MM-dd_HHmm')) -ReportingOk $true
$r3 = Run-Check -Label '3. NEW stamp, still failing    -> expect alarm=YES (re-armed)'

# A healthy backup -> quiet.
Set-Fixture -Ok $true -Stamp ((Get-Date).AddMinutes(2).ToString('yyyy-MM-dd_HHmm')) -ReportingOk $true
$r4 = Run-Check -Label '4. NEGATIVE CONTROL: healthy   -> expect alarm=NO'

Write-Host ''
Write-Host '=== ASSERTIONS ==='
$checks = @(
    @{ n = 'A1 first failure alarms';                 ok = ($r1.result -match 'alarm=YES') }
    @{ n = 'A2 and carries a REASON line';            ok = ($r1.reason -ne '') }
    @{ n = 'A3 repeat of same state is suppressed';   ok = ($r2.result -match 'alarm=NO') }
    @{ n = 'A4 a NEW stamp re-arms the alarm';        ok = ($r3.result -match 'alarm=YES') }
    @{ n = 'A5 NEGATIVE CONTROL: healthy is quiet';   ok = ($r4.result -match 'alarm=NO') }
    @{ n = 'A6 note was written';                     ok = (Test-Path -LiteralPath $note) }
    @{ n = 'A7 every run left a verdict (4 lines)';   ok = ((@([System.IO.File]::ReadAllLines($verdict)) | Where-Object { $_ -ne '' }).Count -eq 4) }
    @{ n = 'A8 verdict records the alarm as true';    ok = ((Get-Content $verdict | Select-Object -First 1) -match '"alarm":true') }
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
