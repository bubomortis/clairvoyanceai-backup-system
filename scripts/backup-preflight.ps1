<#
  Clairvoyance Backup System -- Install Preflight / Idempotency Probe  (2026-07-23)

  PURPOSE
    Deterministic, READ-ONLY detection of an existing install, so "install when already
    installed" is handled by a parseable PROBE instead of prose the agent is trusted to
    obey. AGENTS.md rule #4 and Build-Runbook.md Step 0 run this FIRST and branch on the
    verdict. Models the Persona-Sync (clvsync) `status`-as-idempotency-gate pattern:
    probe the REAL end-state -- never trust a written marker alone -- then decide.

  WHAT IT PROBES (each invariant independently; live state, not just "a file exists")
    scripts : <ToolDir> holds backup.ps1 + restore.ps1 + evaluate-workspaces.ps1, each PARSES.
    config  : <ToolDir>\config.json is present, valid JSON, and carries the required keys.
    seal    : the DPAPI passphrase file is present AND actually UNSEALS on THIS machine
              (LocalMachine DPAPI) to a non-empty value -- a foreign/corrupt seal is caught,
              not passed. The secret itself is never printed.
    task    : the "Clairvoyance Nightly Backup" SYSTEM scheduled task exists; its State and
              RunAs principal are captured; >1 match is reported as DUPLICATE.
    Also reads .backup-install.json (if present) and CROSS-CHECKS its recorded components
    against the live probe, so a manifest that claims "installed" while the real thing is
    missing/broken surfaces as drift rather than a false COMPLETE.

  VERDICTS (see -Json for the machine-readable shape)
    NOT_INSTALLED  none of the 4 core invariants present  -> full install.
    PARTIAL        1..3 present -> resume at the FIRST unmet invariant (reported), not all-or-nothing.
    COMPLETE       all 4 present -> STOP; do NOT re-seal or re-register. (Offer Update if -CheckUpdate.)
    DUPLICATE      ambiguous state (e.g. >1 matching SYSTEM task) -> STOP and ask the user.

  EXIT CODES  0 COMPLETE | 1 NOT_INSTALLED | 2 PARTIAL | 3 DUPLICATE | 4 probe error

  This script performs NO mutation. It never writes the install manifest, seals a key, or
  touches the task. Writing .backup-install.json is a separate, atomic go-live step (Runbook Step 12).
#>
[CmdletBinding()]
param(
  [string]$ToolDir    = "<TOOL_DIR>",
  [string]$ConfigPath = "",                                  # default: <ToolDir>\config.json
  [string]$TaskName   = "Clairvoyance Nightly Backup",
  [switch]$Json,                                             # emit JSON instead of the text report
  [switch]$CheckUpdate                                       # best-effort: compare installed vs latest GitHub release
)
$ErrorActionPreference = "Stop"
$repoApi = "https://api.github.com/repos/bubomortis/clairvoyanceai-backup-system/releases/latest"

if(-not $ConfigPath){ $ConfigPath = Join-Path $ToolDir "config.json" }
$manifestPath = Join-Path $ToolDir ".backup-install.json"
$requiredScripts = @("backup.ps1","restore.ps1","evaluate-workspaces.ps1")
$requiredConfigKeys = @("instanceName","backupRoot","stagingDir","passphraseFile","sources")

function New-Component($present,$detail){ [pscustomobject]@{ present=[bool]$present; detail=$detail } }

# ---- scripts: present AND parse-clean ----
function Probe-Scripts(){
  if(-not (Test-Path -LiteralPath $ToolDir)){ return (New-Component $false "tool dir not found: $ToolDir") }
  $missing=@(); $badParse=@()
  foreach($s in $requiredScripts){
    $p = Join-Path $ToolDir $s
    if(-not (Test-Path -LiteralPath $p)){ $missing += $s; continue }
    $errs=$null
    try { [void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$null,[ref]$errs) } catch { $badParse += $s; continue }
    if($errs -and $errs.Count){ $badParse += $s }
  }
  if($missing.Count -or $badParse.Count){
    $d = @(); if($missing.Count){ $d += "missing: $($missing -join ', ')" }; if($badParse.Count){ $d += "parse errors: $($badParse -join ', ')" }
    return (New-Component $false ($d -join '; '))
  }
  return (New-Component $true "all 3 scripts present and parse-clean")
}

# ---- config: present, valid JSON, required keys ----
function Probe-Config(){
  if(-not (Test-Path -LiteralPath $ConfigPath)){ return (New-Component $false "config.json not found: $ConfigPath") }
  try { $c = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json } catch { return (New-Component $false "config.json is not valid JSON: $($_.Exception.Message)") }
  $names = @($c.PSObject.Properties.Name)
  $absent = @($requiredConfigKeys | Where-Object { $names -notcontains $_ })
  if($absent.Count){ return (New-Component $false "config.json missing keys: $($absent -join ', ')") }
  return (New-Component $true "valid; instance='$($c.instanceName)'")
}

# ---- seal: present AND actually DPAPI-unseals on THIS machine (never prints the secret) ----
function Probe-Seal(){
  $sealPath = $null
  if(Test-Path -LiteralPath $ConfigPath){ try { $sealPath = (Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json).passphraseFile } catch {} }
  if(-not $sealPath){ $sealPath = Join-Path $ToolDir ".secretkey" }
  if(-not (Test-Path -LiteralPath $sealPath)){ return (New-Component $false "sealed passphrase file not found: $sealPath") }
  try {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $b = [Convert]::FromBase64String((Get-Content -Raw -LiteralPath $sealPath).Trim())
    $dec = [Security.Cryptography.ProtectedData]::Unprotect($b,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    if($dec -and $dec.Length -gt 0){
      $fp = ([System.BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash($b))).Replace('-','').Substring(0,16).ToLower()
      return (New-Component $true "seals present and DPAPI-unseals (LocalMachine); sealFingerprint=$fp")
    }
    $c=New-Component $false "seal file present but unsealed to empty value (CORRUPT -- do NOT overwrite; needs rotate)"; $c | Add-Member NoteProperty foreign $true -Force; return $c
  } catch {
    $c=New-Component $false "seal file present but does NOT unseal on this machine (foreign/corrupt -- do NOT overwrite; needs rotate): $($_.Exception.Message)"; $c | Add-Member NoteProperty foreign $true -Force; return $c
  }
}

# ---- task: SYSTEM scheduled task exists; capture state/principal; detect duplicates ----
function Probe-Task(){
  # Query BY NAME (fast direct lookup) -- never enumerate every task (slow on busy hosts).
  $matches = @()
  try { $matches = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) } catch { $matches = @() }
  if($matches.Count -eq 0){
    # Fallback for hosts without the ScheduledTasks module
    try { & schtasks /query /tn "$TaskName" /fo LIST 2>$null | Out-Null; if($LASTEXITCODE -eq 0){ $matches = @([pscustomobject]@{ TaskName=$TaskName; State='Unknown'; Principal=$null }) } } catch {}
  }
  if($matches.Count -eq 0){ return (New-Component $false "SYSTEM task '$TaskName' not found") }
  if($matches.Count -gt 1){ return (New-Component $false "DUPLICATE: $($matches.Count) tasks named '$TaskName' -- remove extras before proceeding") }
  $t = $matches[0]
  $state = if($t.PSObject.Properties.Name -contains 'State'){ [string]$t.State } else { 'Unknown' }
  $runas = try { [string]$t.Principal.UserId } catch { $null }
  return (New-Component $true "present; state=$state runAs=$runas")
}

# ---- optional: latest GitHub release vs installed (from manifest) ----
function Probe-Update($installedVersion){
  if(-not $CheckUpdate){ return $null }
  try {
    $headers = @{ 'User-Agent'='clairvoyance-backup-preflight' }
    if($env:GITHUB_TOKEN){ $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
    $rel = Invoke-RestMethod -Uri $repoApi -Headers $headers -TimeoutSec 15
    $latest = ([string]$rel.tag_name).TrimStart('v')
    if(-not $installedVersion){ return [pscustomobject]@{ latest=$latest; installed=$null; updateAvailable=$null; note="installed version unknown (no manifest) -- cannot compare" } }
    $cmp = 0; try { $cmp = ([version]($installedVersion.TrimStart('v'))).CompareTo([version]$latest) } catch { $cmp = [string]::Compare($installedVersion,$latest) }
    return [pscustomobject]@{ latest=$latest; installed=$installedVersion; updateAvailable=($cmp -lt 0); note="" }
  } catch { return [pscustomobject]@{ latest=$null; installed=$installedVersion; updateAvailable=$null; note="update check failed: $($_.Exception.Message)" } }
}

# ---- read install manifest (advisory) + cross-check against live probe ----
function Read-Manifest(){
  if(-not (Test-Path -LiteralPath $manifestPath)){ return $null }
  try { return (Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json) } catch { return [pscustomobject]@{ _error="present but unreadable: $($_.Exception.Message)" } }
}

# ================= run probes =================
try {
  $scripts = Probe-Scripts
  $config  = Probe-Config
  $seal    = Probe-Seal
  $task    = Probe-Task
  $manifest = Read-Manifest

  $core = [ordered]@{ scripts=$scripts; config=$config; seal=$seal; task=$task }   # ordered = resume priority
  $presentCount = @($core.Values | Where-Object { $_.present }).Count
  $isDuplicate  = ($task.detail -like 'DUPLICATE:*')

  $firstUnmet = $null
  foreach($k in $core.Keys){ if(-not $core[$k].present){ $firstUnmet = $k; break } }

  # A foreign/corrupt seal (present but won't unseal on this machine) is NOT a "resume and seal" case --
  # re-sealing it orphans the archives keyed to the original passphrase. Distinguish it from a missing seal.
  $sealForeign = ($seal.PSObject.Properties.Name -contains 'foreign') -and $seal.foreign

  if($isDuplicate){ $verdict='DUPLICATE'; $exit=3 }
  elseif($presentCount -eq 4){ $verdict='COMPLETE'; $exit=0 }
  elseif($presentCount -eq 0 -and -not $sealForeign){ $verdict='NOT_INSTALLED'; $exit=1 }
  else { $verdict='PARTIAL'; $exit=2 }

  # manifest drift: manifest claims a component installed but live probe says missing
  $drift = @()
  if($manifest -and $manifest.components){
    foreach($k in $core.Keys){ if(($manifest.components.PSObject.Properties.Name -contains $k) -and $manifest.components.$k -and -not $core[$k].present){ $drift += $k } }
  }

  $installedVersion = if($manifest -and ($manifest.PSObject.Properties.Name -contains 'version')){ [string]$manifest.version } else { $null }
  $update = Probe-Update $installedVersion

  $result = [ordered]@{
    verdict         = $verdict
    toolDir         = $ToolDir
    configPath      = $ConfigPath
    taskName        = $TaskName
    components      = [ordered]@{ scripts=$scripts; config=$config; seal=$seal; task=$task }
    presentCount    = $presentCount
    firstUnmet      = $firstUnmet
    sealForeign     = $sealForeign
    manifestPresent = [bool]$manifest
    manifestDrift   = $drift
    installedVersion= $installedVersion
    update          = $update
  }

  if($Json){ ($result | ConvertTo-Json -Depth 6); exit $exit }

  # ---- human-readable report ----
  $recommend = if($sealForeign){
    "STOP -- the passphrase file is present but does NOT unseal on this machine (foreign or corrupt seal -- e.g. copied from another PC, or a bare-metal/OS migration). Do NOT re-seal and do NOT 'resume': re-sealing a new passphrase permanently orphans every existing AES _secrets.7z keyed to the original. Route to the Rotate path -- recover secrets with the ORIGINAL passphrase/machine, then re-key. Only if this is a fresh machine with NO dependent encrypted archives may you remove the stale seal file and install."
  } else { switch($verdict){
    'COMPLETE'      { "STOP -- a valid install is already in place. Do NOT re-run the installer, re-seal the passphrase, or re-register the task. Use the separate Update path to refresh repo-sourced scripts, or the Rotate path to re-key." }
    'PARTIAL'       { "RESUME the runbook at the first unmet invariant: '$firstUnmet'. Do NOT restart from Step 1 -- complete only what is missing. Never re-seal an existing valid passphrase." }
    'DUPLICATE'     { "STOP and ask the user. An ambiguous state was detected (see below) -- do not guess which is canonical." }
    'NOT_INSTALLED' { "Proceed with a full install per the runbook." }
  } }
  Write-Host ""
  Write-Host "  Clairvoyance Backup -- Install Preflight"
  Write-Host "  ---------------------------------------"
  Write-Host ("  VERDICT : {0}   ({1}/4 core invariants present)" -f $verdict,$presentCount)
  Write-Host ("  toolDir : {0}" -f $ToolDir)
  Write-Host ("  task    : {0}" -f $TaskName)
  Write-Host ""
  foreach($k in $core.Keys){ Write-Host ("  [{0}] {1,-8} {2}" -f $(if($core[$k].present){'x'}else{' '}),$k,$core[$k].detail) }
  if($sealForeign){ Write-Host "  [!] SEAL IS FOREIGN/CORRUPT -- present but does NOT unseal on this machine. Do NOT re-seal (would orphan existing _secrets.7z); route to Rotate." }
  elseif($firstUnmet){ Write-Host ("  first unmet invariant (resume here): {0}" -f $firstUnmet) }
  if($drift.Count){ Write-Host ("  [!] MANIFEST DRIFT -- .backup-install.json claims installed but live probe missing: {0}" -f ($drift -join ', ')) }
  if($manifest -and $installedVersion){ Write-Host ("  installed version (manifest): {0}" -f $installedVersion) }
  if($update){ if($update.updateAvailable){ Write-Host ("  UPDATE AVAILABLE: installed {0} -> latest {1}" -f $update.installed,$update.latest) } elseif($update.note){ Write-Host ("  update check: {0}" -f $update.note) } else { Write-Host ("  up to date (latest {0})" -f $update.latest) } }
  Write-Host ""
  Write-Host ("  RECOMMENDED ACTION: {0}" -f $recommend)
  Write-Host ""
  exit $exit
}
catch {
  if($Json){ ([pscustomobject]@{ verdict='PROBE_ERROR'; error=$_.Exception.Message } | ConvertTo-Json) } else { Write-Host "  PROBE ERROR: $($_.Exception.Message)" }
  exit 4
}
