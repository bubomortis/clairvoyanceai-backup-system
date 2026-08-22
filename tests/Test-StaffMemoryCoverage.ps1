<#
  Test-StaffMemoryCoverage.ps1 -- suite for Invoke-StaffMemoryCoverageCheck.ps1.

  Runs entirely against fixtures in a temp tree. Touches NO production state: not config.json, not
  the projects root, not the production verdict log. Every path the checker uses is a parameter,
  which is the whole reason that was done.

  The controls matter more than the positives here:
    C1 proves a healthy tree is SILENT, so C2-C4 are not passing because the check alarms at
       everything.
    C5 proves the ignore list actually suppresses, so C4 is detection rather than noise.
    C6/C7 prove UNKNOWN is its OWN state -- neither health nor drift. A missing ignore list
       reporting OK is vacuous-green; reporting DRIFT is a permanently-red check nobody reads.
    C8 proves a PASS still writes a verdict line, so "ran and was fine" is distinguishable from
       "never ran".
#>
[CmdletBinding()]
param([string] $Checker)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not reliably populated in a param default block under 5.1; resolve here instead.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Checker) { $Checker = Join-Path $here 'Invoke-StaffMemoryCoverageCheck.ps1' }
if (-not (Test-Path -LiteralPath $Checker)) { throw "checker not found: $Checker" }
$pass = 0; $fail = 0

$TestRoot = Join-Path $env:TEMP ("smc-test-" + [guid]::NewGuid().ToString('N').Substring(0,12))
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null

function New-MemDir($projRoot, $slug, $fileCount) {
  $mem = Join-Path (Join-Path $projRoot $slug) 'memory'
  New-Item -ItemType Directory -Path $mem -Force | Out-Null
  for ($i = 1; $i -le $fileCount; $i++) {
    Set-Content -LiteralPath (Join-Path $mem "note$i.md") -Value "fixture" -Encoding UTF8
  }
  return $mem
}

function New-Case($name) {
  $c = Join-Path $TestRoot $name
  New-Item -ItemType Directory -Path (Join-Path $c 'projects') -Force | Out-Null
  return $c
}

function Write-Cfg($case, $sourcePaths) {
  $srcs = @()
  $i = 0
  foreach ($p in $sourcePaths) { $i++; $srcs += [ordered]@{ name = "staff-memory-s$i"; path = $p } }
  $cfgPath = Join-Path $case 'config.json'
  ([ordered]@{ sources = $srcs } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
  return $cfgPath
}

function Write-Ignore($case, $names) {
  $entries = @()
  foreach ($n in $names) { $entries += [ordered]@{ name = $n; reason = 'fixture' } }
  $p = Join-Path $case 'ignore.json'
  ([ordered]@{ ignoreProjectDirs = $entries } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $p -Encoding UTF8
  return $p
}

function Invoke-Checker($cfg, $projRoot, $ign, $log, $trigger = 'manual') {
  $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Checker `
           -ConfigPath $cfg -ProjectsRoot $projRoot -IgnorePath $ign -VerdictLogPath $log -Trigger $trigger 2>&1
  return ($out | Out-String)
}

function Check($label, $condition, $detail) {
  if ($condition) { $script:pass++; "  PASS  $label" }
  else            { $script:fail++; "  FAIL  $label`n        $detail" }
}

Write-Output "=== Invoke-StaffMemoryCoverageCheck.ps1 ==="
Write-Output "Fixtures: $TestRoot"
Write-Output ""

# --- C1: healthy tree -> OK, drift=NO. THE NEGATIVE CONTROL. ---
$c   = New-Case 'c1-healthy'
$pr  = Join-Path $c 'projects'
$m1  = New-MemDir $pr 'alpha' 3
$m2  = New-MemDir $pr 'beta'  2
$cfg = Write-Cfg $c @($m1, $m2)
$ign = Write-Ignore $c @()
$log = Join-Path $c 'v.jsonl'
$o = Invoke-Checker $cfg $pr $ign $log
Check 'C1 healthy tree reports OK' ($o -match 'state=OK\s+drift=NO') $o
Check 'C1 no REASON line on a pass' (-not ($o -match 'COVERAGE-REASON')) $o

# --- C2: configured source EMPTY -> DRIFT (direction 1) ---
$c   = New-Case 'c2-empty'
$pr  = Join-Path $c 'projects'
$m1  = New-MemDir $pr 'alpha' 3
$m2  = New-MemDir $pr 'beta'  0     # exists, holds nothing
$cfg = Write-Cfg $c @($m1, $m2)
$ign = Write-Ignore $c @()
$log = Join-Path $c 'v.jsonl'
$o = Invoke-Checker $cfg $pr $ign $log
Check 'C2 empty configured source reports DRIFT' ($o -match 'state=DRIFT\s+drift=YES') $o
Check 'C2 names it EMPTY with empty=1'           ($o -match 'empty=1' -and $o -match 'EMPTY: source') $o

# --- C3: configured source ABSENT -> DRIFT ---
$c   = New-Case 'c3-absent'
$pr  = Join-Path $c 'projects'
$m1  = New-MemDir $pr 'alpha' 3
$cfg = Write-Cfg $c @($m1, (Join-Path $pr 'ghost\memory'))
$ign = Write-Ignore $c @()
$log = Join-Path $c 'v.jsonl'
$o = Invoke-Checker $cfg $pr $ign $log
Check 'C3 absent configured source reports DRIFT' ($o -match 'drift=YES' -and $o -match 'absent=1') $o

# --- C4: populated dir NO source covers -> DRIFT. THE LOAD-BEARING DIRECTION. ---
$c   = New-Case 'c4-unconfigured'
$pr  = Join-Path $c 'projects'
$m1  = New-MemDir $pr 'alpha' 3
$null = New-MemDir $pr 'orphaned-by-rename' 7   # populated, unconfigured: the 07-23 shape
$cfg = Write-Cfg $c @($m1)
$ign = Write-Ignore $c @()
$log = Join-Path $c 'v.jsonl'
$o = Invoke-Checker $cfg $pr $ign $log
Check 'C4 unconfigured populated dir reports DRIFT' ($o -match 'drift=YES' -and $o -match 'unconfigured=1') $o
Check 'C4 counts the unbacked files (7)'            ($o -match 'unbacked_files=7') $o
Check 'C4 names the directory'                      ($o -match 'orphaned-by-rename') $o

# --- C5: same tree, dir IS ignored -> OK. Proves C4 is detection, not noise. ---
$c   = New-Case 'c5-ignored'
$pr  = Join-Path $c 'projects'
$m1  = New-MemDir $pr 'alpha' 3
$null = New-MemDir $pr 'known-orphan' 7
$cfg = Write-Cfg $c @($m1)
$ign = Write-Ignore $c @('known-orphan')
$log = Join-Path $c 'v.jsonl'
$o = Invoke-Checker $cfg $pr $ign $log
Check 'C5 ignore list suppresses a known orphan' ($o -match 'state=OK\s+drift=NO' -and $o -match 'unconfigured=0') $o

# --- C6: ignore list MISSING -> UNKNOWN, not OK and not DRIFT ---
$c   = New-Case 'c6-noignore'
$pr  = Join-Path $c 'projects'
$m1  = New-MemDir $pr 'alpha' 3
$cfg = Write-Cfg $c @($m1)
$log = Join-Path $c 'v.jsonl'
$o = Invoke-Checker $cfg $pr (Join-Path $c 'does-not-exist.json') $log
Check 'C6 missing ignore list reports UNKNOWN' ($o -match 'state=UNKNOWN') $o
Check 'C6 UNKNOWN is not reported as OK'       (-not ($o -match 'state=OK')) $o
Check 'C6 UNKNOWN is not reported as DRIFT'    (-not ($o -match 'state=DRIFT')) $o

# --- C7: config missing -> UNKNOWN ---
$c   = New-Case 'c7-nocfg'
$pr  = Join-Path $c 'projects'
$null = New-MemDir $pr 'alpha' 1
$ign = Write-Ignore $c @()
$log = Join-Path $c 'v.jsonl'
$o = Invoke-Checker (Join-Path $c 'nope.json') $pr $ign $log
Check 'C7 missing config reports UNKNOWN' ($o -match 'state=UNKNOWN') $o

# --- C8: a PASS still leaves a trace, and records its trigger ---
$c   = New-Case 'c8-trace'
$pr  = Join-Path $c 'projects'
$m1  = New-MemDir $pr 'alpha' 2
$cfg = Write-Cfg $c @($m1)
$ign = Write-Ignore $c @()
$log = Join-Path $c 'v.jsonl'
$null = Invoke-Checker $cfg $pr $ign $log 'scheduled'
$lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
Check 'C8 a healthy run writes a verdict line' ($lines.Count -eq 1) "lines=$($lines.Count)"
$rec = if ($lines.Count -ge 1) { $lines[0] | ConvertFrom-Json } else { $null }
Check 'C8 verdict records state=OK'            ($rec -and $rec.state -eq 'OK') $lines[0]
Check 'C8 verdict records the trigger'         ($rec -and $rec.trigger -eq 'scheduled') $lines[0]
$null = Invoke-Checker $cfg $pr $ign $log 'manual'
$lines2 = @(Get-Content -LiteralPath $log)
Check 'C8 a second run appends, does not replace' ($lines2.Count -eq 2) "lines=$($lines2.Count)"

Write-Output ""
Write-Output "=== $pass passed, $fail failed ==="
Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 }
exit 0
