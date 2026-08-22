<#
  Test-PreflightScriptInventory.ps1 -- tests the script-inventory probe in backup-preflight.ps1.

  WHY THIS EXISTS. The probe used to assert "all 3 scripts present and parse-clean" against a
  hardcoded list. Once the shipped set grew past three, an install missing an optional
  component's dependency still reported COMPLETE -- so the tool whose job is to say the install
  is broken said it was fine. The rule now: the core set is unconditional, and an optional
  component that IS installed drags in whatever it dot-sources.

  Case C is the whole point: Invoke-BackupHealthCheck.ps1 present WITHOUT backup-window.ps1.
  Case F is the control -- it runs the PREVIOUS version of the probe against that same fixture
  and asserts it wrongly passes. Without F, a green suite here proves only that the new code
  agrees with itself.

  Read-only: every fixture is built under a temp directory and removed afterwards. Nothing
  touches a real install.

  Usage: .\Test-PreflightScriptInventory.ps1 [-Preflight <path>] [-OldPreflight <path>]
#>
[CmdletBinding()]
param(
  [string]$Preflight    = '',
  [string]$OldPreflight = ''   # optional: a pre-fix copy, for the discrimination control (case F)
)
$ErrorActionPreference = 'Stop'

# Resolved HERE, not as a param default: $PSScriptRoot is not yet populated during parameter
# binding, so a default built from it binds as an empty string and Split-Path throws.
if (-not $Preflight) { $Preflight = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\backup-preflight.ps1' }
if (-not (Test-Path -LiteralPath $Preflight)) { throw "preflight not found: $Preflight" }
$pass = 0; $fail = 0

function New-Fixture([string[]]$Scripts, [string]$BadParse = '') {
  $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("preflight-fix-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  foreach ($s in $Scripts) {
    $body = if ($s -eq $BadParse) { 'function Broken { if ($true) {' } else { "# stub for $s`r`nfunction Stub-$($s -replace '\W','') { }" }
    Set-Content -LiteralPath (Join-Path $dir $s) -Value $body -Encoding UTF8
  }
  $dir
}

function Get-ScriptsComponent([string]$Script, [string]$ToolDir) {
  # -Json so the assertion reads a STRUCTURED field, never scraped console text. The probe
  # exits non-zero for any incomplete install, which is expected here and not an error.
  $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -ToolDir $ToolDir -Json 2>$null
  if (-not $raw) { throw "no output from $Script" }
  ($raw -join "`n" | ConvertFrom-Json).components.scripts
}

function Check([string]$Name, [bool]$Condition, [string]$Detail) {
  if ($Condition) { Write-Host ("  PASS  {0}" -f $Name); $script:pass++ }
  else            { Write-Host ("  FAIL  {0}  -- {1}" -f $Name, $Detail); $script:fail++ }
}

$core = @('backup.ps1','restore.ps1','evaluate-workspaces.ps1')

Write-Host "== script-inventory probe =="

# A. Core only. A correct install with no optional components must PASS -- a check that fires
#    on a healthy system is a check nobody reads.
$d = New-Fixture $core
try { $r = Get-ScriptsComponent $Preflight $d
  Check 'A core-only install passes' ($r.present -eq $true) $r.detail
  Check 'A detail reports core-only'  ($r.detail -match 'core only') $r.detail
} finally { Remove-Item $d -Recurse -Force }

# B. Optional component installed together with its dependency.
$d = New-Fixture ($core + @('Invoke-BackupHealthCheck.ps1','backup-window.ps1'))
try { $r = Get-ScriptsComponent $Preflight $d
  Check 'B health check + module passes' ($r.present -eq $true) $r.detail
  Check 'B detail names the optional set' ($r.detail -match 'optional') $r.detail
} finally { Remove-Item $d -Recurse -Force }

# C. THE DEFECT. Optional component present, dependency absent. The health check hard
#    dot-sources backup-window.ps1, so this install cannot start its watchdog.
$d = New-Fixture ($core + @('Invoke-BackupHealthCheck.ps1'))
try { $r = Get-ScriptsComponent $Preflight $d
  Check 'C missing dot-sourced dependency FAILS' ($r.present -eq $false) $r.detail
  Check 'C detail names the dependency'          ($r.detail -match 'backup-window\.ps1') $r.detail
  Check 'C detail names what required it'        ($r.detail -match 'Invoke-BackupHealthCheck\.ps1') $r.detail
} finally { Remove-Item $d -Recurse -Force }

# D. A missing CORE script still fails, and is not mislabelled as a dependency problem.
$d = New-Fixture @('backup.ps1','evaluate-workspaces.ps1')
try { $r = Get-ScriptsComponent $Preflight $d
  Check 'D missing core script fails'     ($r.present -eq $false) $r.detail
  Check 'D reported as missing, not dep'  ($r.detail -match 'missing.*restore\.ps1') $r.detail
} finally { Remove-Item $d -Recurse -Force }

# E. Parse errors are still caught, including in an optional component.
$d = New-Fixture ($core + @('Invoke-BackupHealthCheck.ps1','backup-window.ps1')) -BadParse 'backup-window.ps1'
try { $r = Get-ScriptsComponent $Preflight $d
  Check 'E unparseable dependency fails' ($r.present -eq $false) $r.detail
  Check 'E reported as a parse error'    ($r.detail -match 'parse errors') $r.detail
} finally { Remove-Item $d -Recurse -Force }

# F. DISCRIMINATION CONTROL. The previous probe must WRONGLY PASS fixture C. If it also fails,
#    then C was never the defect and this suite is testing something else.
if ($OldPreflight -and (Test-Path -LiteralPath $OldPreflight)) {
  $d = New-Fixture ($core + @('Invoke-BackupHealthCheck.ps1'))
  try { $r = Get-ScriptsComponent $OldPreflight $d
    Check 'F OLD probe wrongly passes fixture C' ($r.present -eq $true) "old probe said: $($r.detail)"
  } finally { Remove-Item $d -Recurse -Force }
} else {
  Write-Host "  SKIP  F discrimination control -- pass -OldPreflight <pre-fix copy> to run it"
  Write-Host "        A suite without it shows only that the new code agrees with itself."
}

Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
