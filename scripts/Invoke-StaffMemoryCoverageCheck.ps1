<#
  Invoke-StaffMemoryCoverageCheck.ps1 -- READ-ONLY staff-memory backup coverage drift check.

  WHAT THIS IS. The detection half of F17, extracted so it can run WITHOUT activating F17.
  F17's Assert-StaffMemoryCoverage lives in backup.ps1 (activated 2026-08-13)
  and sets ok=false on drift. Its activation is COUPLED: code + staffMemoryProjectsRoot +
  staffMemoryIgnore must land together, because "root set, ignore list missing" is DESTRUCTIVE --
  ok=false from run one, permanently. That is not theoretical: measured 2026-08-11, the two
  deliberately-excluded orphan project dirs are populated and unconfigured RIGHT NOW, so a
  half-activation fires immediately and forever.

  So this script runs the same comparison and REPORTS. It never touches backup.ps1, config.json,
  last-run.json, the lease, the log note, or `ok`. Its only write is its own verdict log.

  WHY IT EXISTS AT ALL (the defect it closes is not the drift, it is the silence):
  staff-memory sources are C: project dirs keyed by a slug DERIVED FROM THE WORKSPACE PATH. Rename
  or move a workspace and Claude Code mints a NEW, EMPTY project dir; the accumulated memory stays
  behind in the old one. The configured source then points at a directory that EXISTS and is EMPTY,
  so optional:true produces no "absent" WARN and that source backs up ZERO FILES INDEFINITELY while
  every signal reads healthy. This has already happened TWICE (07-03 and 07-23).

  DIRECTION 2 IS THE LOAD-BEARING ONE. A rename leaves the OLD dir still populated, so a
  configured-but-empty test (direction 1) stays silent forever. "Populated but unconfigured" is the
  only detector for what actually happened on 07-23. Do not treat it as the redundant half.

  THREE STATES, DELIBERATELY. A missing ignore list must NOT be reported as either health or drift:
    OK      - every configured source holds files; every populated dir is configured or ignored
    DRIFT   - at least one real finding
    UNKNOWN - the check could not be evaluated (no ignore list, no config, root unreadable)
  Collapsing UNKNOWN into OK is vacuous-green; collapsing it into DRIFT trains people to ignore red.

  EVERY RUN WRITES A VERDICT LINE, INCLUDING A PASS. A check that writes nothing when healthy is
  byte-identical to one that never ran. Learned the hard way on the backup health check, 2026-08-10.

  ALL PATHS ARE PARAMETERS so this is testable without touching production state. A test that has to
  back up production data in order to run is a test people stop running.
#>
[CmdletBinding()]
param(
  [string] $ConfigPath     = '<TOOL_DIR>\config.json',
  [string] $ProjectsRoot   = 'C:\Users\<YOU>\.claude\projects',
  [string] $IgnorePath,
  [string] $VerdictLogPath,
  [ValidateSet('scheduled','manual')]
  [string] $Trigger        = 'manual'
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not reliably populated in a param default block under 5.1; resolve here instead.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $IgnorePath)     { $IgnorePath     = Join-Path $here 'staff-memory-coverage.ignore.json' }
if (-not $VerdictLogPath) { $VerdictLogPath = Join-Path $here 'staff-memory-coverage.jsonl' }

function Write-Verdict($state, $drift, $counts, $reason) {
  # Written for EVERY outcome, including OK. See header.
  try {
    $rec = [ordered]@{
      ts_utc    = (Get-Date).ToUniversalTime().ToString('o')
      local_day = (Get-Date).ToString('yyyy-MM-dd')
      trigger   = $Trigger
      state     = $state
      drift     = [bool]$drift
      counts    = $counts
      reason    = $reason
    }
    $dir = Split-Path $VerdictLogPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # NOT Add-Content -Encoding UTF8: under 5.1 that writes a BOM when it creates the file, and a BOM
    # on line 1 of a .jsonl is rejected by Node's JSON.parse even though jq tolerates it. The sibling
    # health-verdicts.jsonl is BOM-less; match it. Validate with the strictest consumer, not the
    # friendliest one.
    $line = ($rec | ConvertTo-Json -Depth 5 -Compress) + "`n"
    [System.IO.File]::AppendAllText($VerdictLogPath, $line, (New-Object System.Text.UTF8Encoding($false)))
  } catch {
    Write-Host "COVERAGE-WARN could not write verdict log: $($_.Exception.Message)"
  }
}

function Count-Files($path) {
  # @() guard: a single-file directory must not collapse to a scalar. Assigning the @()-wrapped
  # pipeline is the comma-guard-safe form.
  $items = @(Get-ChildItem -LiteralPath $path -File -Recurse -ErrorAction SilentlyContinue)
  return $items.Count
}

# ---- Load inputs. Any failure here is UNKNOWN, never OK. ----
$counts = [ordered]@{ configured = 0; ok = 0; empty = 0; absent = 0; unconfigured = 0; unbacked_files = 0 }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
  $r = "config not found at $ConfigPath"
  Write-Host "COVERAGE-RESULT state=UNKNOWN drift=UNKNOWN configured=0 ok=0 empty=0 absent=0 unconfigured=0 unbacked_files=0"
  Write-Host "COVERAGE-REASON $r"
  Write-Verdict 'UNKNOWN' $false $counts $r
  exit 0
}

if (-not (Test-Path -LiteralPath $IgnorePath)) {
  # FAIL LOUD, and as its OWN state. Without the ignore list the two known orphans would be reported
  # as drift on every single run -- a permanently-red check is a check everyone learns to ignore.
  $r = "ignore list not found at $IgnorePath -- coverage cannot be evaluated. This is NOT a health verdict."
  Write-Host "COVERAGE-RESULT state=UNKNOWN drift=UNKNOWN configured=0 ok=0 empty=0 absent=0 unconfigured=0 unbacked_files=0"
  Write-Host "COVERAGE-REASON $r"
  Write-Verdict 'UNKNOWN' $false $counts $r
  exit 0
}

try {
  $cfg    = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
  $ignore = Get-Content -LiteralPath $IgnorePath -Raw | ConvertFrom-Json
} catch {
  $r = "could not parse inputs: $($_.Exception.Message)"
  Write-Host "COVERAGE-RESULT state=UNKNOWN drift=UNKNOWN configured=0 ok=0 empty=0 absent=0 unconfigured=0 unbacked_files=0"
  Write-Host "COVERAGE-REASON $r"
  Write-Verdict 'UNKNOWN' $false $counts $r
  exit 0
}

$ignoreNames = @()
if ($ignore.ignoreProjectDirs) { $ignoreNames = @($ignore.ignoreProjectDirs | ForEach-Object { $_.name }) }

$configured = @($cfg.sources | Where-Object { $_.name -like 'staff-memory-*' })
$counts.configured = $configured.Count

$findings = @()

# ---- DIRECTION 1: configured source that exists but holds nothing ----
foreach ($s in $configured) {
  if (-not (Test-Path -LiteralPath $s.path)) {
    $counts.absent++
    $findings += "ABSENT: source '$($s.name)' path does not exist ($($s.path)) -- optional:true means this WARN+skips"
    continue
  }
  $n = Count-Files $s.path
  if ($n -eq 0) {
    $counts.empty++
    $findings += "EMPTY: source '$($s.name)' exists but holds ZERO files ($($s.path)) -- backing up nothing while reading healthy"
  } else {
    $counts.ok++
  }
}

# ---- DIRECTION 2 (load-bearing): populated project dir that no source points at ----
if (-not (Test-Path -LiteralPath $ProjectsRoot)) {
  $r = "projects root unreadable: $ProjectsRoot"
  Write-Host "COVERAGE-RESULT state=UNKNOWN drift=UNKNOWN configured=$($counts.configured) ok=$($counts.ok) empty=$($counts.empty) absent=$($counts.absent) unconfigured=0 unbacked_files=0"
  Write-Host "COVERAGE-REASON $r"
  Write-Verdict 'UNKNOWN' $false $counts $r
  exit 0
}

$cfgPaths = @($configured | ForEach-Object { $_.path.TrimEnd('\').ToLower() })

foreach ($d in @(Get-ChildItem -LiteralPath $ProjectsRoot -Directory -ErrorAction SilentlyContinue)) {
  $mem = Join-Path $d.FullName 'memory'
  if (-not (Test-Path -LiteralPath $mem)) { continue }
  $n = Count-Files $mem
  if ($n -eq 0) { continue }
  if ($cfgPaths -contains $mem.TrimEnd('\').ToLower()) { continue }
  if ($ignoreNames -contains $d.Name) { continue }
  $counts.unconfigured++
  $counts.unbacked_files += $n
  $newest = (Get-ChildItem -LiteralPath $mem -File -Recurse -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
  $findings += "UNCONFIGURED: '$($d.Name)' holds $n memory file(s) that NO source covers (newest $($newest.ToString('yyyy-MM-dd HH:mm'))) -- this is the direction that catches a workspace rename"
}

# ---- Verdict ----
$drift  = ($findings.Count -gt 0)
$state  = if ($drift) { 'DRIFT' } else { 'OK' }
$reason = if ($drift) { ($findings -join ' | ') } else { '' }

Write-Host ("COVERAGE-RESULT state={0} drift={1} configured={2} ok={3} empty={4} absent={5} unconfigured={6} unbacked_files={7}" -f `
  $state, $(if($drift){'YES'}else{'NO'}), $counts.configured, $counts.ok, $counts.empty, $counts.absent, $counts.unconfigured, $counts.unbacked_files)
if ($drift) { Write-Host "COVERAGE-REASON $reason" }

Write-Verdict $state $drift $counts $reason
exit 0
