# Clairvoyance Backup System â€” Companion Scripts

*Full source of the config-driven PowerShell scripts referenced by the Build Runbook. The executing Clairvoyance AI writes these VERBATIM into the tool directory during setup â€” no script files are transferred from anyone, so a trustless adopter needs nothing beyond this text.*

**Before use:** all real paths come from `config.json`; the only environment-specific bits are the param DEFAULTS shown as placeholders (`<TOOL_DIR>`, `<WORKSPACES_ROOT>`, `<DATA_DIR>`, `<TOOLS_DIR>`, `<YOU>`, `<PC>`) â€” replace them with your real paths, or always invoke with an explicit `-ConfigPath`. `7z.exe` default is the standard install path. See `AGENTS.md` for the full placeholder table.

> **This file is generated from `scripts/*.ps1`.** It is not hand-maintained. The blocks below are byte-identical to those files; if you need to change a script, change it in `scripts/` and regenerate, or the two will drift the way they did before v0.2.0.

**Test harnesses (`tests/*.ps1`) are deliberately not included here** â€” they are not authored during an install and are only needed by someone modifying the system.

## backup-preflight.ps1

*Read-only install / idempotency probe. Run this FIRST, before any mutation. Prints a parseable VERDICT (NOT_INSTALLED / PARTIAL / COMPLETE / DUPLICATE) and mutates nothing.*

```powershell
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
# The CORE engine. These must be present on every install, no exceptions.
# backup.ps1 dot-sources nothing -- it writes and clears the lease file directly -- so the
# core set is genuinely self-contained and stays unconditional.
$requiredScripts = @("backup.ps1","restore.ps1","evaluate-workspaces.ps1")

# OPTIONAL components that drag in their own dependencies.
# The monitoring scripts are a separately-approved mutation (Runbook step 12a), so their
# ABSENCE is a perfectly valid install and must never fail preflight. What is NOT valid is
# an optional component present WITHOUT the module it dot-sources: Invoke-BackupHealthCheck.ps1
# hard dot-sources backup-window.ps1 at load, so that combination is an install which reports
# healthy and whose watchdog throws the first time it runs -- exactly the "you believe you have
# backups you do not" failure this system exists to prevent, reached through the tool whose job
# is to say otherwise.
# Requiring backup-window.ps1 UNCONDITIONALLY would be the obvious fix and is the wrong one:
# it fails a correct core-only install, and a check that fires on a healthy system is a check
# nobody reads.
$conditionalScripts = @{ "Invoke-BackupHealthCheck.ps1" = @("backup-window.ps1") }
$requiredConfigKeys = @("instanceName","backupRoot","stagingDir","passphraseFile","sources")

function New-Component($present,$detail){ [pscustomobject]@{ present=[bool]$present; detail=$detail } }

# ---- scripts: present AND parse-clean ----
function Probe-Scripts(){
  if(-not (Test-Path -LiteralPath $ToolDir)){ return (New-Component $false "tool dir not found: $ToolDir") }
  # Build the set to check: the core, plus the dependencies of whichever optional
  # components are actually installed. Derived, never a hardcoded count -- the previous
  # version asserted "all 3" and went stale the moment the script set grew.
  $toCheck = @($requiredScripts)
  $brokenDeps = @()
  foreach($trigger in $conditionalScripts.Keys){
    if(-not (Test-Path -LiteralPath (Join-Path $ToolDir $trigger))){ continue }
    $toCheck += $trigger
    foreach($dep in $conditionalScripts[$trigger]){
      $toCheck += $dep
      if(-not (Test-Path -LiteralPath (Join-Path $ToolDir $dep))){
        # Reported separately from a plain 'missing': the operator needs to know WHICH
        # component made this file required, or the fix looks arbitrary.
        $brokenDeps += "$dep (required because $trigger is installed and dot-sources it)"
      }
    }
  }
  $toCheck = @($toCheck | Select-Object -Unique)

  $missing=@(); $badParse=@()
  foreach($s in $toCheck){
    $p = Join-Path $ToolDir $s
    if(-not (Test-Path -LiteralPath $p)){ $missing += $s; continue }
    $errs=$null
    try { [void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$null,[ref]$errs) } catch { $badParse += $s; continue }
    if($errs -and $errs.Count){ $badParse += $s }
  }
  if($missing.Count -or $badParse.Count -or $brokenDeps.Count){
    $d = @()
    if($brokenDeps.Count){ $d += "broken dependency: $($brokenDeps -join '; ')" }
    # A dep counted above is already named there; do not report it twice.
    $plainMissing = @($missing | Where-Object { $n = $_; -not ($brokenDeps | Where-Object { $_.StartsWith("$n ") }) })
    if($plainMissing.Count){ $d += "missing: $($plainMissing -join ', ')" }
    if($badParse.Count){ $d += "parse errors: $($badParse -join ', ')" }
    return (New-Component $false ($d -join '; '))
  }
  $optional = @($toCheck | Where-Object { $_ -notin $requiredScripts })
  $detail = "all $($toCheck.Count) installed script(s) present and parse-clean"
  $detail += if($optional.Count){ " (core $($requiredScripts.Count) + optional: $($optional -join ', '))" } else { " (core only; no optional components installed)" }
  return (New-Component $true $detail)
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
    $c=New-Component $false "seal file present but unsealed to empty value (CORRUPT -- do NOT blindly overwrite; recover by re-sealing the SAME passphrase, rotate only to change it)"; $c | Add-Member NoteProperty foreign $true -Force; return $c
  } catch {
    $c=New-Component $false "seal file present but does NOT unseal on this machine (machine-bound; expected after rebuild/transport -- recover by re-sealing the SAME passphrase, rotate only to change it): $($_.Exception.Message)"; $c | Add-Member NoteProperty foreign $true -Force; return $c
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
    "STOP -- the passphrase file is present but does NOT unseal on THIS machine. The seal is machine-bound (LocalMachine DPAPI), so this is EXPECTED after an OS rebuild or when the tool dir was copied to another computer. Choose the RIGHT path -- do not blindly re-seal: (1) RECOVERY / TRANSPORT with the SAME passphrase (you still have it in your password manager) -- delete this stale machine-bound seal, then RE-SEAL THE SAME PASSPHRASE from your password manager (Runbook Step 7). This is recovery, NOT rotation; it does NOT orphan anything -- the archives are keyed to the passphrase, not to this blob. (2) ROTATE -- ONLY if you actually intend to CHANGE the passphrase; follow the Rotate path. NEVER seal a DIFFERENT passphrase over existing archives -- that permanently orphans every _secrets.7z keyed to the old one."
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
  if($sealForeign){ Write-Host "  [!] SEAL IS FOREIGN -- present but does NOT unseal on this machine (machine-bound; expected after rebuild/transport). RECOVERY = delete the stale seal + re-seal the SAME passphrase from your password manager (safe). ROTATE only if changing the passphrase. Never seal a DIFFERENT passphrase over existing archives." }
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
```

## backup.ps1

*The engine. Everything else is a companion to this.*

```powershell
<#
  Clairvoyance Backup Engine v3  (Fable efficiency + security hardening 2026-07-12)
  Pipeline: robocopy /B /MIR into a PERSISTENT mirror (delta; SECRETS EXCLUDED) -> SHA-256
    manifest w/ hash cache -> main 7z from the mirror -> secrets gathered from LIVE sources
    into a small AES-256 7z (passphrase via stdin, never on the cmdline/env) -> 7z test +
    deep-verify -> hash-verified upload -> SHARE-SIDE GFS tiering (+substitution) ->
    incremental weekly artifacts -> prune (+ shorter secrets retention). Abort-window guarded.
  Passphrase: DPAPI passphraseFile if present, else env ARCHIVIST_SECRETS_PASS (then env cleared).
  Modes: -Mode DryRun|Live ; -RunDate yyyy-MM-dd ; -SkipSecrets ; -InstanceName <o> ; -ForceRehash
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = "<TOOL_DIR>\config.json",
  [ValidateSet("DryRun","Live")][string]$Mode = "Live",
  [string]$RunDate = "",
  [switch]$SkipSecrets,
  [string]$InstanceName = "",
  [switch]$ForceRehash,
  [switch]$WriteInstallManifest
)
$ErrorActionPreference = "Stop"
$cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$now = if($RunDate){ [datetime]::ParseExact($RunDate,"yyyy-MM-dd",$null).AddHours(3) } else { Get-Date }
$stamp = $now.ToString("yyyy-MM-dd_HHmm")
$instName = if($InstanceName){ $InstanceName } else { $cfg.instanceName }
$instanceRoot = Join-Path $cfg.backupRoot $instName
$statePath = Join-Path $instanceRoot "backup_state.json"
$seven = $cfg.sevenZip
# ============================================================================================
# STANDING RULE (F9, generalised 2026-07-26) -- READ BEFORE ADDING ANY EXTERNAL COMMAND CALL
#
#   ANYTHING RUNNING ELEVATED RESOLVES ITS BINARIES BY ABSOLUTE PATH, NEVER BY PATH.
#
# This script's scheduled task runs as SYSTEM (verified: schtasks 'Run As User: SYSTEM').
# A bare `& toolname` in this file is resolved through the PATH of an elevated process. If any
# directory on that PATH is writable by a non-administrator, planting a binary of that name is
# arbitrary code execution as SYSTEM, on a timer, every night.
#
# That is not hypothetical here. <CLV_ROOT> inherits `Authenticated Users: Modify` from the
# E:\ root, so any shared tools directory created under it is user-writable by default. The
# proposal to put such a directory on the MACHINE PATH is what turned this from latent to live.
#
# This rule previously existed only as the comment on the $robocopy line below -- pinned at ONE
# call site instead of stated as a rule -- which is exactly why it did not protect the two bare
# `& rclone` / `& ollama` calls in Write-Recovery. Those are now gone.
#
# IF YOU ADD AN EXTERNAL COMMAND: bind it to an absolute path near the top of this file, or take
# the value from config.json. Do not add a bare name.
#
# -- COROLLARY (added 2026-07-26, adversarial review): EXECUTION vs INGESTION are different rules. --
#
# The rule above governs what this script RUNS. It does not govern what this script READS, and an
# earlier version of this very comment said "or read the value from ... the tools manifest" --
# which, followed literally by a future author, restores the escalation by a different route:
# read a PATH out of the manifest, then execute it. The manifest is NOT a trusted source.
# `<TOOLS_DIR>` carries `Authenticated Users:(I)(M)` (inherited), so tools-manifest.json
# is a USER-WRITABLE FILE being read by a process running as SYSTEM.
#
#   DESCRIPTIVE data from the manifest, used only for DISPLAY, is fine.
#     -> version strings, paths and notes $L.Add()ed into RECOVERY.md text. This is what
#        Write-Recovery does today: the values are printed, never resolved and never invoked.
#
#   NEVER derive anything EXECUTED or SECURITY-DECIDING from the manifest, or from any other
#   user-writable file:
#     -> do not `& $t.path`, Start-Process it, pass it to Invoke-Expression, use it as a script
#        or module path, or let it choose which binary runs.
#     -> do not gate a security decision on a manifest field (e.g. "skip the check if pinned").
#
#   AND: SANITIZE AT INGESTION. A user-writable value that lands in a document a HUMAN ACTS ON is
#   an INSTRUCTION CHANNEL, whether or not this process ever executes it.
#
# TEST TO APPLY -- ask what a plausible READER WOULD DO, not whether the process executes it.
#
#   An earlier version of this comment said "changing text in a recovery document is a nuisance."
#   THAT WAS FALSE, and it was the permissive half of the rule: a future author applying it
#   faithfully would have concluded the injection below was acceptable. RECOVERY.md is read by a
#   human under pressure, mid-restore, when they are disposed to follow instructions rather than
#   audit them. A CR/LF in any manifest string field let an attacker author ARBITRARY ADDITIONAL
#   LINES -- a fabricated "## STEP 7 - MANDATORY BEFORE RESTORE" heading with a plausible
#   irm|iex command, placed directly above the real Rebuild line. It does not need to execute.
#   It needs to be BELIEVED. (Found by adversarial review 2026-07-26 with a working PoC; the defect was live.)
#
# NOTE ON THE OBVIOUS-LOOKING FIX: do NOT "solve" this by hardening <TOOLS_DIR>. That
# directory holds the app-generated MCP launchers (the app runs in USER context) AND is the write
# target of generate-tools-manifest.ps1, which must run in user context to see the user PATH.
# Locking it to Users:RX would break manifest generation for certain and risk the app's own
# writes -- trading a low-severity ingestion concern for a self-inflicted outage. The correct
# mitigation is this rule: treat the file's CONTENT as untrusted, not the directory as trusted.
# ============================================================================================
$robocopy = Join-Path $env:SystemRoot "System32\robocopy.exe"   # F9: pin, no PATH resolution while elevated (see STANDING RULE above)
$mirror = $cfg.stagingDir
$toolDir = Split-Path -Parent $ConfigPath   # for _Restore self-containment (scripts live beside config.json)
$logStages = @()
$script:pass = $null
# ---- backup-window LEASE (2026-07-27) ----
# The pause flag is a LEASE, not a bare marker, and readers MUST honour expiry.
#
# WHY: the `finally` that clears this flag DOES NOT RUN when the process is killed -- reboot,
# TerminateProcess, hard power loss. That is not theoretical: the flag was stranded on 2026-07-23,
# and again on 2026-07-27 when the run was hard-killed mid-compress by the scheduled task's
# ExecutionTimeLimit (then PT40M). A bare marker therefore silences the whole automation fleet
# INDEFINITELY after any hard kill.
# And the obvious fix for that -- a janitor deciding whether the owner is still alive -- is exactly
# what cleared the flag ON A LIVE BACKUP on 2026-07-27, while 7-Zip was still compressing.
# An expiring lease deletes the janitor ROLE: a reader treats an expired lease as absent and NEVER
# removes the file. Only this script's own `finally` deletes it. Nobody has to guess at liveness.
#
# TTL SIZING -- size against the longest plausible RUN, NOT the longest gap between Log calls.
# (B2, corrected 2026-07-27 after adversarial review; the first version of this comment reasoned from the gap
# and picked 45. That was wrong twice over and both errors are worth recording.)
#
#   1. RIGHT-CENSORED EVIDENCE. The 45 was justified by "compress ran 03:31 -> past 04:00 on
#      07-27", i.e. a ~29 min gap. BOTH HALVES OF THAT WERE WRONG, and the second only surfaced
#      after the root cause was corrected. The run was hard-killed at ~03:40 by the task's
#      ExecutionTimeLimit (PT40M at the time), NOT by the 04:00 host reboot -- last write 03:39 =
#      start + 40 min, and an attended run the same day died at exactly 40 min with no reboot
#      involved. So compress was never running past 04:00: the real gap was nearer 9 min, and the
#      "29" was an inference FROM the wrong cause, not a measurement. DO NOT re-quote it.
#      The lesson survives its own bad number: sizing a margin from a censored observation
#      understates it by an unknown amount. A superseded root cause leaves its inferences behind,
#      and those are what get quoted later as fact.
#   2. WRONG LONG POLE. Measured from the last COMPLETE run (07-26, 18.4 min), the largest gap is
#      secrets-split -> secret-scrub at 12.07 min -- 65% of the whole nominal run inside one
#      un-renewed interval -- not compress, which the old comment reasoned about.
#      (The old "3.3x contention factor" is struck for the same reason: it compared a killed run
#      against a completed one, so it is a LOWER BOUND of ~2.2x with the true value unknown.)
#      SUPERSEDING DIRECT OBSERVATION: the attended run on 2026-07-27 was watched live via the
#      lease `stage` field and showed stages of 19-28 min -- secrets-split alone sat 19 min with
#      no intervening Log call and was still climbing. That is measurement, not inference, and it
#      is what justifies 120 on its own.
#
# Why a too-short TTL is not merely "a bit risky": the failure is SELF-AMPLIFYING and has no
# in-run recovery. Lease expires mid-run -> fleet resumes -> contention rises -> the current stage
# slows -> the gap to the next renewal grows -> the lease stays expired for the rest of the run.
# One breach converts into "the fleet runs on top of the backup until it finishes", which is the
# original bug plus everyone believing the control works.
#
# The costs are wildly asymmetric, so do NOT split the difference:
#   too long  -> quiet for TTL after a hard kill. Bounded, self-healing, no human action, and at
#                most a couple of skipped ticks against 60-minute and 2-hour periods.
#   too short -> the incident this was built to prevent, with positive feedback.
#
# THE NUMBER: 120 min, justified by DIRECT OBSERVATION -- roughly 10x the measured nominal worst
# gap (12.07 min on the last complete run) and >4x the longest gap ever actually watched live
# (19-28 min stages, attended run 2026-07-27, observed via the lease `stage` field). Earlier drafts
# justified it against a "3.3x contended projection"; that factor is withdrawn as an artefact of the
# wrong root cause -- see the note above. A clean finish always clears the lease in the `finally`,
# so the only cost of being generous is post-kill quiet time.
#
# DO NOT restore the earlier justification, which read "the 03:00-start / 05:00-reboot window
# physically caps a run at 120 min". That bound is NOT verifiable from inside this guest, and a
# reviewer correctly challenged it after finding no such scheduled task. The nuance is that the
# reboot IS scheduled -- just not here: it is driven by `qemu-ga` on behalf of the hypervisor
# (System event 1074, fired at 04:00:0x for 14 consecutive days, which is not Windows Update), so
# `Get-ScheduledTask` in the guest cannot see it BY CONSTRUCTION and its absence there proves
# nothing either way. Either way the conclusion stands: resting a safety margin on a bound this
# process cannot observe is the same error class as the censored 29 above -- an inferred limit
# standing in for a measured one. Rest it on the gap margin, which is evidence we hold.
#
# FOOTNOTE (2026-07-27, later the same day): the reviewer's challenge above turned out to be even
# more right than either of us knew. The binding ceiling was never the reboot at all -- it was the
# scheduled task's own ExecutionTimeLimit, PT40M, set at go-live 2026-07-12 and referenced in no
# config, script or runbook. It has since been raised to PT2H, which is why 120 here and the task
# limit now agree rather than contradicting. See _note_overrun_guards in config.json: there are
# THREE overrun guards in three different places, and only one of them lives in this codebase.
#
# COROLLARY, and the reason not to go higher than 120: a hard kill can land at any time (task
# limit or host reboot), so the post-kill quiet window should stay short enough to self-heal
# within a couple of
# orchestrator ticks (60-minute and 2-hour periods).
#
# The knob is CLAMPED. Unclamped, a fat-fingered 4500 would quiesce the fleet for three days and
# look like a healthy lease the entire time -- a config typo should not be able to outrun a human.
# DryRun never writes the lease -- a dry run must not be able to quiesce production.
$script:leaseStartedAt = (Get-Date).ToString("o")
$script:leaseReleased = $false
$script:leaseTtlMin = 120
if($cfg.leaseTtlMinutes){
  $req = 0
  if([int]::TryParse("$($cfg.leaseTtlMinutes)", [ref]$req)){
    $script:leaseTtlMin = [Math]::Max(30, [Math]::Min(240, $req))
  }
}
function Set-BackupLease($stage){
  if(-not $cfg.pauseFlag -or $Mode -eq "DryRun"){ return }
  # ONCE RELEASED, NEVER RE-CREATED. Ordering-independent by construction (B1, adversarial review 2026-07-27).
  # The bug this closes: `Log` renews the lease as a side effect, and the `finally` calls
  # Log "cleanup" "WARN" AFTER the Remove-Item that releases it. On any run where the temp tree is
  # not fully removed, the teardown deleted the lease and then wrote a brand-new one with a full
  # TTL -- with no remaining code path to remove it. The fleet would stay quiesced for a full TTL
  # AFTER the backup finished. Bounded, but the same family as the forever-bug this design exists
  # to kill: a lease outliving its owner.
  # It matters more than its frequency suggests: "temp not fully removed" is a FILE-HANDLE
  # CONTENTION symptom, so it fires precisely under the condition this feature was built for --
  # correlated with the scenario, not independent of it.
  # Reordering the two lines would work today and re-arm the moment someone adds a Log below them.
  # Same argument as riding the heartbeat on an existing chokepoint: prefer the invariant to the
  # thing a future author has to remember.
  if($script:leaseReleased){ return }
  try {
    ([ordered]@{
      schemaVersion = 1
      owner         = "backup.ps1"
      ownerPid      = $PID
      instance      = $instName
      stamp         = $stamp
      stage         = $stage
      startedAt     = $script:leaseStartedAt
      renewedAt     = (Get-Date).ToString("o")
      expiresAt     = (Get-Date).AddMinutes($script:leaseTtlMin).ToString("o")
      ttlMinutes    = $script:leaseTtlMin
      note          = "Backup in progress. Honour expiresAt. DO NOT DELETE THIS FILE -- an expired lease is to be IGNORED, not removed; only backup.ps1 removes it."
    } | ConvertTo-Json -Compress) | Set-Content -LiteralPath $cfg.pauseFlag -Encoding UTF8 -EA SilentlyContinue
  } catch {}   # a lease write must NEVER be able to fail a backup
}
# Log renews the lease as a side effect: it is already called at every stage boundary, so the
# heartbeat rides an existing chokepoint instead of adding a timer that could itself stop.
function Log($stage,$status,$detail){ $script:logStages += [pscustomobject]@{ ts=(Get-Date).ToString("s"); stage=$stage; status=$status; detail=$detail }; Write-Host ("[{0}] {1} : {2} {3}" -f (Get-Date).ToString("HH:mm:ss"),$stage,$status,$detail); Set-BackupLease $stage }

# ---- F16: backup log note + share mirror. SINGLE WRITER. (the maintainer's decision 2026-08-01) ----
# Ownership moved OUT of the AI monitor prompt and INTO backup.ps1.
#
# WHY THE MIRROR EXISTS AT ALL (do not "simplify" it away): the moment you need the backup history is
# the moment the machine holding it is gone. A copy therefore has to sit ON THE SHARE beside the
# archives, for the same reason _Restore carries its four scripts. "Retire the mirror and rely on the
# local note plus docs/reports" fails that test -- both of those die with the machine.
#
# WHY THE MONITOR COULD NOT DO IT: the monitor drives PowerShell through a bash/MSYS argument layer
# that eats '\\', so every UNC write collapsed -- Copy-Item, cmd /c copy and robocopy failed
# IDENTICALLY, which is why "switch tools" never helped. backup.ps1 has no such layer and already
# writes this exact share every night (it uploads ~400MB of archives to it). The capability was never
# missing; the OWNER was, and an owner that punts on failure is not an owner.
#
# WHY DIRECTION CAN NO LONGER INVERT: local is written first, then copied to the share, then
# hash-compared. One writer, one direction, every run. The 8-day divergence (share stale to 07-31,
# then local stale from 07-30) happened because two actors wrote two copies with no defined
# authority. That is structurally impossible while this is the only writer.
#
# WHY THIS DOES NOT SET ok=false: as of F15, ok=false WITHHOLDS tier promotion. A markdown note that
# failed to copy is a REPORTING failure, not an archive-integrity failure, and must not cost a
# Weekly/Monthly/Annual archive or pile up substitutions. It gets its own loud channel instead:
# a FAIL stage plus $result.reportingOk. Keep the two concepts separate -- ok = "is this archive
# trustworthy", reportingOk = "can we still see what happened". Conflating them was the temptation.
function Write-BackupLogNote {
  param([string]$localPath,[string]$shareLogsDir,$result,$stages,[string]$stamp,[datetime]$startedAt)

  $ok   = [bool]$result.ok
  $mins = [Math]::Round(((Get-Date)-$startedAt).TotalMinutes,1)
  $sb   = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("### $($stamp.Substring(0,10)) (Daily) $(if($ok){'OK SUCCESS'}else{'XX DEGRADED'})")
  [void]$sb.AppendLine("- **Status**: $(if($ok){'PASS'}else{'FAIL'})")
  [void]$sb.AppendLine("- **Timestamp**: $stamp")
  [void]$sb.AppendLine("- **Result**: ok=$($ok.ToString().ToLower())")
  [void]$sb.AppendLine("- **Tiers**: $(@($result.tiers) -join ', ')")
  if(@($result.withheld).Count){      [void]$sb.AppendLine("- **WITHHELD**: $(@($result.withheld) -join ', ') -- degraded run, NOT promoted; the next healthy run substitutes for these boundaries") }
  if(@($result.substitutions).Count){ [void]$sb.AppendLine("- **Substitutions**: $(@($result.substitutions) -join ', ')") }
  [void]$sb.AppendLine("- **Stages**: ")
  foreach($e in @($stages)){ [void]$sb.AppendLine("  - $($e.stage): $($e.status)$(if($e.detail){" ($($e.detail))"})") }
  [void]$sb.AppendLine("- **Runtime**: ~$mins minutes")
  [void]$sb.AppendLine("- **Written by**: backup.ps1 F16 (single writer; not the monitor)")
  $entry = $sb.ToString().TrimEnd()

  # --- local note: entries are NEWEST-FIRST, so prepend under the '## Backup Log' heading ---
  $marker = '## Backup Log'
  $body = if(Test-Path -LiteralPath $localPath){ [IO.File]::ReadAllText($localPath) }
          else { "# Clairvoyance Backup Log`r`n`r`n$marker`r`n" }
  # Idempotent on the LOCAL PREPEND ONLY -- a re-invoked run must not double-enter. Keyed on the exact
  # timestamp line.
  # [!] DO NOT turn this into an early `return`. (adversarial review, blocking, 2026-08-01.) -RunDate makes $stamp
  # deterministic per DATE, so RE-RUNNING A FAILED NIGHT lands here every single time -- which is
  # precisely when the share copy is most likely to be stale and least likely to be looked at. An early
  # return reports skipped=true / reportingOk=true and never touches the share, so the one path that
  # exists to repair a mirror would silently decline to. Skipping the local write is correct; skipping
  # the VERIFICATION is the bug. Fall through to the mirror unconditionally.
  $already = $body.Contains("- **Timestamp**: $stamp")
  if(-not $already){
    $i = $body.IndexOf($marker)
    if($i -lt 0){ $body = $body.TrimEnd() + "`r`n`r`n$marker`r`n"; $i = $body.IndexOf($marker) }
    $ins  = $i + $marker.Length
    $body = $body.Substring(0,$ins) + "`r`n`r`n" + $entry + "`r`n" + $body.Substring($ins)
    # WriteAllText + UTF8Encoding($false): Set-Content without -Encoding double-encodes non-ASCII and
    # adds a BOM, silently, while reporting success. This file is read by humans and by the monitor.
    [IO.File]::WriteAllText($localPath,$body,(New-Object System.Text.UTF8Encoding($false)))
  }

  # --- share mirror: copy, then PROVE it landed. Assertions throw; they never warn. ---
  if(-not (Test-Path -LiteralPath $shareLogsDir)){ New-Item -ItemType Directory -Force -Path $shareLogsDir | Out-Null }
  $shareFile = Join-Path $shareLogsDir (Split-Path $localPath -Leaf)
  Copy-Item -LiteralPath $localPath -Destination $shareFile -Force
  if(-not (Test-Path -LiteralPath $shareFile)){ throw "share copy reported success but the file is not there: $shareFile" }
  # A collapsed UNC ('\\server\...' -> 'E:\server\...') writes SUCCESSFULLY to the wrong disk and is
  # invisible in every other check. FullName is the only thing that catches it.
  $fn = (Get-Item -LiteralPath $shareFile).FullName
  if(-not $fn.StartsWith('\\')){ throw "UNC collapsed -- wrote to a LOCAL path instead of the share: $fn" }
  $lh = (Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash
  $sh = (Get-FileHash -LiteralPath $shareFile -Algorithm SHA256).Hash
  if($lh -ne $sh){ throw "share copy hash mismatch (local $($lh.Substring(0,12)) / share $($sh.Substring(0,12)))" }
  return @{ ok=$true; skipped=$already; shareFile=$fn; hash=$lh.Substring(0,12) }
}

# ---- Clairvoyance app-version stamp (restore-time mismatch guard) ----
# Source = the INSTALL dir's exe file-metadata, NOT anything under userData. This is
# deliberately base-migration-safe: the install path is independent of the C:/E: userData
# base flip (encryption-context.json), so it resolves identically before/after the flip.
# Console-less + SYSTEM-readable (pure file metadata; no running app, no stdout).
function Get-ClairvoyanceVersion {
  $exe = if($cfg.clairvoyanceExePath){ $cfg.clairvoyanceExePath } else { "C:\Program Files\Clairvoyance\Clairvoyance.exe" }
  if(Test-Path -LiteralPath $exe){
    try {
      $vi = (Get-Item -LiteralPath $exe).VersionInfo
      if($vi.FileVersion -and $vi.FileVersion.Trim()){ return @{ version=$vi.FileVersion.Trim(); source="Clairvoyance.exe/FileVersion" } }
      if($vi.ProductVersion -and $vi.ProductVersion.Trim()){ return @{ version=$vi.ProductVersion.Trim(); source="Clairvoyance.exe/ProductVersion" } }
    } catch {}
  }
  return @{ version="unknown"; source=("unresolved:"+$exe) }   # never abort a backup over this (F14 philosophy)
}
# backup-tool (engine) version -- SINGLE SOURCE OF TRUTH. Bump on release.
$EngineVersion = "0.4.0"
# backupToolVersion resolution: prefer the installer-written .backup-install.json (the proper source,
# also read by backup-preflight for idempotency/version cross-check); fall back to $EngineVersion so
# an install WITHOUT the manifest (e.g. this one) still stamps a real version instead of "unknown".
function Get-BackupToolVersion {
  $f = Join-Path $toolDir ".backup-install.json"
  if(Test-Path -LiteralPath $f){ try { $j=Get-Content -Raw -LiteralPath $f|ConvertFrom-Json; if($j.version){ return [string]$j.version } } catch {} }
  return $EngineVersion
}
# Install-manifest writer (proper resolution / option 2): the go-live + update runbook invokes
# `backup.ps1 -WriteInstallManifest` to persist the engine version into .backup-install.json so the
# lookup above reads it authoritatively. Merge-preserving (keeps any installer-written
# components/taskName/sealFingerprint) + atomic (temp -> rename). Idempotent.
function Write-InstallManifest {
  $f = Join-Path $toolDir ".backup-install.json"
  $obj = [ordered]@{}
  if(Test-Path -LiteralPath $f){ try { $ex=Get-Content -Raw -LiteralPath $f|ConvertFrom-Json; foreach($p in $ex.PSObject.Properties){ $obj[$p.Name]=$p.Value } } catch {} }  # preserve unknown keys
  if(-not $obj.Contains('schemaVersion')){ $obj['schemaVersion']=1 }
  $obj['version']=$EngineVersion
  $obj['versionWrittenAt']=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $obj['versionWrittenBy']="backup.ps1 -WriteInstallManifest"
  $tmp="$f.tmp"; ($obj|ConvertTo-Json -Depth 6)|Set-Content -LiteralPath $tmp -Encoding UTF8; Move-Item -LiteralPath $tmp -Destination $f -Force
  return $f
}

# -WriteInstallManifest: install/go-live entry point. Persist the engine version, then EXIT before
# any pipeline / abort-window / pause-flag logic runs (no backup, no lastRunFile write).
if($WriteInstallManifest){ $mf = Write-InstallManifest; Write-Host ("[install-manifest] version=$EngineVersion -> $mf"); exit 0 }

# ---- abort-window guard ----
# Deadline = first occurrence of abortAfterLocalTime AT OR AFTER run start, NOT a bare
# same-day time-of-day. The old same-day compare (Get-Date -Hour/-Minute builds *today* at
# HH:MM) aborted any run started after HH:MM: an attended evening run tripped instantly
# because 23:xx > today-03:45. Rolling to the next occurrence keeps the nightly's overrun
# guard intact (start 03:00 -> today 03:45, ~45min deadline) while letting off-hours runs
# proceed to their next 03:45. Exempt when -RunDate (backfill) is set, as before.
# Min-window floor: don't arm a deadline too small to complete a run. A late-starting nightly
# (machine asleep -> Task Scheduler catch-up at ~03:40) would otherwise get a ~5min window and
# abort BEFORE the secrets stage, yielding NO backup that night while reading as a failure. A
# window shorter than one run's duration can only ever produce a mid-phase abort, never a
# completed-then-guarded backup -- so below the floor, roll forward and run to completion.
# Threshold = config minAbortWindowMinutes (default 20; set a bit above a delta run's
# secrets+compress time). $now is wall-clock here (armed branch is -not $RunDate).
$abortAt = $null
if($cfg.abortAfterLocalTime -and -not $RunDate){
  $ap = $cfg.abortAfterLocalTime -split ':'
  $abortAt = (Get-Date -Hour ([int]$ap[0]) -Minute ([int]$ap[1]) -Second 0)
  $minWin = if($cfg.minAbortWindowMinutes){ [int]$cfg.minAbortWindowMinutes } else { 20 }
  if($abortAt -le $now.AddMinutes($minWin)){ $abortAt = $abortAt.AddDays(1) }
}
function Assert-Window($phase){ if($abortAt -and (Get-Date) -gt $abortAt){ throw "past abort window ($($cfg.abortAfterLocalTime)) before '$phase'" } }

# ---- boundary helpers ----
function Last-DowOnOrBefore([datetime]$d,[string]$dow){ while($d.DayOfWeek.ToString() -ne $dow){ $d=$d.AddDays(-1) }; return $d.Date }
function Last-DayOfMonth([datetime]$d){ (Get-Date -Year $d.Year -Month $d.Month -Day 1).AddMonths(1).AddDays(-1).Date }
function MonthEndOnOrBefore([datetime]$d){ $lom=Last-DayOfMonth $d; if($d.Date -ge $lom){ return $lom } else { return (Get-Date -Year $d.Year -Month $d.Month -Day 1).AddDays(-1).Date } }
function YearEndOnOrBefore([datetime]$d){ $ye=(Get-Date -Year $d.Year -Month 12 -Day 31).Date; if($d.Date -ge $ye){ return $ye } else { return (Get-Date -Year ($d.Year-1) -Month 12 -Day 31).Date } }

# ---- per-workspace tuning -> effective daily sources (+ encrypt flag) + weekly artifact map ----
$script:effectiveSources = @()
foreach($s in $cfg.sources){ $s | Add-Member NoteProperty encrypt $false -Force; $script:effectiveSources += $s }
$script:wsArtifactMap = @()
if($cfg.workspacesRoot){
  $wd = $cfg.workspaceDefaults
  foreach($ws in (Get-ChildItem -LiteralPath $cfg.workspacesRoot -Directory -ErrorAction SilentlyContinue)){
    $tune = $null; if($cfg.workspaceTuning){ $pp = $cfg.workspaceTuning.PSObject.Properties | Where-Object { $_.Name -eq $ws.Name }; if($pp){ $tune=$pp.Value } }
    $exD=@(); $exF=@(); $artD=@(); $enc=$false
    if($wd){ $exD+=@($wd.excludeDirs); $exF+=@($wd.excludeFiles); $artD+=@($wd.artifactDirs); if($wd.encrypt){$enc=$true} }
    if($tune){ $exD+=@($tune.excludeDirs); $exF+=@($tune.excludeFiles); $artD+=@($tune.artifactDirs); if($tune.PSObject.Properties.Name -contains 'encrypt'){ $enc=[bool]$tune.encrypt } }
    $artD = @($artD | Where-Object { $_ } | Select-Object -Unique)
    $dailyExD = @(@($exD)+@($artD) | Where-Object { $_ } | Select-Object -Unique)
    $exF = @($exF | Where-Object { $_ } | Select-Object -Unique)
    $script:effectiveSources += [pscustomobject]@{ name="workspace-$($ws.Name)"; path=$ws.FullName; category="workspace"; excludeDirs=$dailyExD; excludeFiles=$exF; encrypt=$enc }
    if($artD.Count -and -not $enc){ $script:wsArtifactMap += [pscustomobject]@{ name="workspace-$($ws.Name)"; path=$ws.FullName; dirs=$artD } }
  }
}
# F4: secret name/dir exclusions for the mirror (derived from secretsSet)
$script:secFileNames = @($cfg.secretsSet | Where-Object { $_ -notmatch '/' })
$script:secDirNames  = @($cfg.secretsSet | Where-Object { $_ -match '/' } | ForEach-Object { ($_ -split '/')[0] })

# ---- hash cache ----
$cachePath = Join-Path $mirror ".hashcache.json"
$script:hcache = @{}; $script:doRehash = $false
function Load-Cache(){ if(Test-Path -LiteralPath $cachePath){ try { $o=Get-Content -Raw -LiteralPath $cachePath|ConvertFrom-Json; foreach($p in $o.PSObject.Properties){ $script:hcache[$p.Name]=$p.Value } } catch {} } }
function Save-Cache(){ ($script:hcache | ConvertTo-Json -Depth 3 -Compress) | Set-Content -LiteralPath $cachePath -Encoding UTF8 }
function Hash-Cached($full,$key){ $fi=Get-Item -LiteralPath $full; $c=$script:hcache[$key]; if((-not $script:doRehash) -and $c -and [int64]$c.size -eq $fi.Length -and [int64]$c.mtime -eq $fi.LastWriteTimeUtc.Ticks){ return $c.sha }; $h=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash; $script:hcache[$key]=[pscustomobject]@{ size=$fi.Length; mtime=$fi.LastWriteTimeUtc.Ticks; sha=$h }; return $h }

# ---- F20: secret-scan VERDICT store (incremental scan, 2026-08-23) -------------------------
# WHY A SECOND STORE AND NOT .hashcache.json: the hash cache is saved by the FAILURE path too
# (line ~1498, `catch { ... Save-Cache }`). A run that dies before Scan-Secrets -- e.g. at
# Assert-Window "secrets", which sits immediately BEFORE the scan -- therefore persists fresh
# hashes for files that were never scanned. Deriving "unchanged, so skip" from a hash-cache hit
# would make those files invisible to the scanner FOREVER: a real credential, in plaintext main,
# with no signal. So the verdict is keyed on the file's sha256 and written ONLY after the scan
# phase completes. "Hashed" and "scanned" are different facts and must not share a record.
#
# The verdict stores the OUTCOME, not merely "clean". Binary/read-error files are identified BY
# READING them; if a cache hit skipped the read we could no longer count them, and skipBin would
# silently collapse from ~641 to ~5, breaking every Assert-ScanDelta comparison against history.
# Re-emitting the recorded outcome keeps every ledger counter meaning what it meant before.
#   o = c(lean) | b(inary) | f(lagged, staff-memory no-scrub) | r(ead error)
$scanVerdictPath = Join-Path $mirror ".scan-verdicts.json"
function Get-ScanEpoch(){
  # Binds a verdict to the rule set that produced it. Change any input below and every stored
  # verdict is stale, because it answers a question we are no longer asking.
  #
  # THE NO-SCRUB SET IS AN INPUT. The 'f' outcome (detected, deliberately not scrubbed) depends on
  # which sources are category=staff-memory. Omit it and moving a source out of that category
  # leaves its stored 'f' verdicts "valid": reuse re-emits flagged and passes the file through
  # UNSCRUBBED while the current config says scrub it. Sorted, so source ordering cannot churn it.
  #
  # Separator is [char]0, NOT `u{0}: the `u{..} escape is PowerShell 6+ only and renders as seven
  # LITERAL characters under 5.1, so the epoch would differ between hosts and force a spurious
  # full rescan the first time this ran under a different PowerShell.
  $ns = @($script:effectiveSources | Where-Object { $_.category -eq "staff-memory" } | ForEach-Object { [string]$_.name } | Sort-Object)
  $src = (@($cfg.secretScanPatterns) -join ([string][char]0)) + ([string][char]0) + "maxKB=" + [int]$cfg.secretScanMaxFileKB + ([string][char]0) + "noscrub=" + ($ns -join ',')
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($src)) } finally { $sha.Dispose() }
  return (($h | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,16)
}
function Load-ScanVerdicts(){
  $empty = [pscustomobject]@{ epoch=$null; verdicts=@{} }
  if(-not (Test-Path -LiteralPath $scanVerdictPath)){ return $empty }
  try {
    $o = Get-Content -Raw -LiteralPath $scanVerdictPath | ConvertFrom-Json
    $v = @{}
    if($o.verdicts){ foreach($p in $o.verdicts.PSObject.Properties){ $v[$p.Name] = $p.Value } }
    return [pscustomobject]@{ epoch=$o.epoch; verdicts=$v }
  } catch {
    # A corrupt store must fail CLOSED: no epoch => nothing matches => full rescan this run.
    Log "scan-verdicts" "WARN" ("verdict store unreadable, FULL rescan this run: " + $_.Exception.Message)
    return $empty
  }
}

function Save-ScanVerdicts($epoch,$verdicts){
  $obj = [pscustomobject]@{ epoch=$epoch; savedAt=(Get-Date).ToUniversalTime().ToString("o"); verdicts=$verdicts }
  ($obj | ConvertTo-Json -Depth 4 -Compress) | Set-Content -LiteralPath $scanVerdictPath -Encoding UTF8
}

# ---- F19: unhashable-file guard (hashguard 2026-08-14) ----
# WHY THIS EXISTS: a single file whose path Win32 cannot open used to abort the ENTIRE nightly.
# On 2026-08-14 a file literally named 'nul' landed in workspace-ExampleMediaPipeline -- a Git Bash
# '2>nul' redirect, which does not know 'nul' is a DOS device and so CREATED a file instead of
# discarding output. Get-ChildItem ENUMERATES it fine (it is a real NTFS entry), but Get-Item and
# Get-FileHash route the reserved final component to the NUL DEVICE and throw "because it does not
# exist". With $ErrorActionPreference=Stop (:21) that escaped Manifest-Source, hit the top-level
# catch, and cost the whole night: zero archives, ok=false, nothing uploaded.
# SCOPE: reserved names are CON/PRN/AUX/NUL/COM1-9/LPT1-9, WITH OR WITHOUT AN EXTENSION -- measured,
# 'aux.log' throws identically, so a basename-only sweep is not sufficient. The same failure shape
# covers a locked file, an ACL-denied file and a broken reparse point, which is why the guard is on
# the HASH rather than on a list of reserved names.
# MEASURED, AND IT DECIDES THE DESIGN: 7z compresses such a directory with EXIT CODE 0, so the
# archive itself was never at risk -- only the manifest. But 7z stored 'nul' as a ZERO-BYTE entry
# (the real file was 92 bytes) because it opened the device too. We therefore deliberately SKIP the
# entry rather than recovering the true hash through a \\?\ extended-length path: the recovered hash
# would NOT match the archived bytes and would break the manifest==archived-bytes invariant that
# deep-verify depends on (see the same reasoning at the Scan-Secrets rehash). An UNRECORDED file is
# honest; a manifest that misdescribes the archive is not.
# NOT SILENT: every skip is logged as it happens (first 10 by name, then suppressed to avoid a flood)
# AND totalled in a 'hash-guard' stage line that is ALWAYS emitted, including the unhashable=0 case.
# A guard that writes nothing on a clean night is indistinguishable from one that never ran.
$script:unhashable = @(); $script:unhashableSecret = @()
function Try-Hash($full,$key,$srcName,$isSecret){
  try {
    if($key){ return (Hash-Cached $full $key) }
    return (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
  } catch {
    $rec = [pscustomobject]@{ path=$full; source=$srcName; reason=$_.Exception.Message }
    if($isSecret){ $script:unhashableSecret += $rec } else { $script:unhashable += $rec }
    $n = @($script:unhashable).Count + @($script:unhashableSecret).Count
    if($n -le 10){ Log "hash-guard" "WARN" ("UNHASHABLE, excluded from manifest: [$srcName] $full -- $($_.Exception.Message)") }
    elseif($n -eq 11){ Log "hash-guard" "WARN" "further unhashable files suppressed from the per-file log; see the hash-guard summary for the total" }
    return $null
  }
}

# F7: depth-agnostic secret matching (bare name = basename anywhere; dir/** = that dir anywhere)
function Match-Secret($rel,$patterns){ $r=($rel -replace '\\','/'); $base=($r -replace '.*/',''); foreach($p in $patterns){ if($p -notmatch '/'){ if($base -ieq $p){ return $true }; continue }; $rx=[regex]::Escape($p) -replace '\\\*\\\*','.*' -replace '\\\*','[^/]*'; if($r -match ('(^|/)'+$rx+'$')){ return $true } }; return $false }
function Is-Excluded($rel,$src){ $segs=($rel -replace '\\','/').Split('/'); foreach($d in $src.excludeDirs){ if($segs -icontains $d){ return $true } }; $base=$segs[-1]; foreach($f in $src.excludeFiles){ if($base -like $f){ return $true } }; return $false }

# includeFiles ALLOWLIST (2026-07-26). When a source declares includeFiles it becomes FILE-SCOPED:
# top-level files only, and only those matching one of the basename globs. Everything else is invisible
# to that source -- mirror AND secrets gatherer alike.
# WHY this exists instead of an exclude-list: the two flip-immune root strays (crash.log / relay.log)
# sit at the ROOT of the legacy C: base, next to Cache\, Code Cache\, blob_storage\, Network\ AND next to
# auth-storage.json, claude-auth-debug.jsonl and the stale C:-naming encryption-context.json. An
# exclude-only source rooted there is a DENYLIST: (1) any NEW dir under the legacy root silently enters
# every nightly, and (2) Get-SecretFilesLive recurses the LIVE source path, so it would sweep that legacy
# auth material -- and a second, C:-naming encryption-context.json -- into _secrets.7z, re-muddying the
# exact restore-provenance question the 2026-07-26 flip certification just settled. An allowlist fails
# closed on both. Sources without includeFiles are completely unaffected (Get-IncludeGlobs -> empty).
# B1 VALIDATION -- fail closed on a degenerate includeFiles.
# An ABSENT includeFiles means "not include-scoped": return empty, source takes the normal /MIR path.
# A PRESENT-but-degenerate includeFiles is the dangerous case, and it fails in two directions at once:
#   (a) $inc.Count -eq 0 makes Mirror-Source take the /MIR DENYLIST branch -- so declaring an allowlist
#       and mistyping it would silently sweep the entire legacy C: root, the exact outcome the
#       allowlist exists to prevent (fails OPEN); and
#   (b) if it did stay include-scoped, it would back up nothing while reporting success (fails SILENT).
# TRIM BEFORE TESTING. `Where-Object { $_ }` alone is NOT sufficient: a whitespace-only string is
# truthy in PowerShell, so ["", "  "] survives as 1 "usable" glob and skips the guard entirely, then
# matches nothing downstream. Trimming first collapses it to 0 and the throw fires.
function Get-IncludeGlobs($src){
  # COMMA-GUARD IS LOAD-BEARING -- do not "simplify" to `return @()`.
  # PowerShell UNROLLS an empty array on return, so a bare `return @()` hands the caller $null.
  # That $null then binds to Test-Included's $inc parameter, where @($inc).Count is 1 (an array
  # wrapping one null) -- so its "no allowlist means include everything" guard does NOT fire, and
  # every file from every non-allowlisted source is rejected. Live consequence 2026-07-26..27:
  # Get-SecretFilesLive returned 0 entries and NO _secrets.7z was produced for two nights, while
  # the run reported ok=true with every stage PASS.
  # The oddity is real and only exists ACROSS the call boundary -- the same count read in the
  # caller's own scope is 0 and looks fine, which is why two isolated repros disagreed before the
  # functions were extracted and driven directly. Matches the idiom already used by
  # Get-SecretFilesLive and Scan-Secrets (`return ,@($out)`).
  if($src.PSObject.Properties.Name -notcontains 'includeFiles'){ return ,@() }
  $globs = @($src.includeFiles | ForEach-Object { if($null -ne $_){ ([string]$_).Trim() } } | Where-Object { $_ })
  if(-not $globs.Count){
    throw ("source '{0}': includeFiles is declared but resolves to no usable glob (raw count={1}). " -f $src.name, @($src.includeFiles).Count) +
          "Remove the key to use the normal exclude-only behaviour, or give it at least one non-empty pattern. " +
          "Refusing to continue: an empty allowlist would silently fall back to a denylist over '$($src.path)'."
  }
  return $globs
}
# C4: takes the ALREADY-RESOLVED globs, not the source. Previously this re-derived them per file,
# so every file of home-appdata and the workspace sources paid a PSObject.Properties.Name
# enumeration purely to be told "no allowlist here". Callers compute $inc once per source.
# The explicit `$null -eq $inc` is DEFENCE IN DEPTH, not redundancy with the comma-guard above.
# This guard is fail-OPEN BY INTENT ("no allowlist => include everything"), and handed $null it
# fails CLOSED -- inverting its own stated purpose and silently excluding everything. A guard whose
# failure mode inverts its intent is a defect independent of who calls it, and this function has
# two call sites today with no contract preventing a third. Same shape as the null check already
# used for $script:wsArtifactMap further down. Keep BOTH: the comma-guard stops null being
# produced; this stops null being harmful if it ever is again.
function Test-Included($rel,$inc){ if($null -eq $inc -or -not @($inc).Count){ return $true }
  $r=($rel -replace '\\','/'); if($r.Contains('/')){ return $false }   # top-level only: an include-scoped source never recurses
  foreach($g in $inc){ if($r -like $g){ return $true } }; return $false }

# C4: validate includeFiles ONCE at load, for every effective source -- config sources AND the
# workspace-derived ones -- so a config error refuses the run up front instead of surfacing
# mid-mirror after other sources have already been copied. Fail-closed either way; this is about
# failing EARLY. MUST stay BELOW the Get-IncludeGlobs definition: PowerShell resolves functions at
# call time in top-to-bottom order, and an earlier placement (next to the effectiveSources loop,
# where this logically belongs) dies at load with "Get-IncludeGlobs is not recognized" on EVERY
# run, valid config or not. Do not "tidy" this back up next to the loop it validates.
foreach($s in $script:effectiveSources){ $null = Get-IncludeGlobs $s }

# F3: passphrase from DPAPI file (else env), then clear env so children don't inherit it
function Get-Passphrase(){ if($script:pass){ return $script:pass }; $p=$null
  if($cfg.passphraseFile -and (Test-Path -LiteralPath $cfg.passphraseFile)){ try { Add-Type -AssemblyName System.Security -EA SilentlyContinue; $b=[Convert]::FromBase64String((Get-Content -Raw -LiteralPath $cfg.passphraseFile).Trim()); $dec=[Security.Cryptography.ProtectedData]::Unprotect($b,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine); $p=[Text.Encoding]::UTF8.GetString($dec) } catch {} }   # F11b: LocalMachine DPAPI so the SYSTEM task can read it
  if(-not $p -and $env:ARCHIVIST_SECRETS_PASS){ $p=$env:ARCHIVIST_SECRETS_PASS }
  Remove-Item Env:ARCHIVIST_SECRETS_PASS -ErrorAction SilentlyContinue
  $script:pass=$p; return $p }

function SevenZip { param([Parameter(ValueFromRemainingArguments=$true)]$a) & $seven @a; return $LASTEXITCODE }
function SevenZipPw([string]$pw,[string[]]$z){ $pw | & $seven @z; return $LASTEXITCODE }   # F3: bare -p, password via stdin (explicit arg array so $pw isn't swallowed)

# ---- reparse-point (junction/symlink) reporting + explicit exclusion (2026-08-15; revised 2026-08-16 on adversarial review's review) ----
# /XJD is SILENT about what it skipped, and a control that writes nothing on a pass is indistinguishable
# from one that never ran. This names every directory reparse point in the source and RETURNS their paths
# so the caller can exclude them by explicit /XD.
#
# WHY /XD AND NOT /XJD ALONE. /XJD's coverage of a directory SYMLINK (as opposed to a junction) is
# UNVERIFIED here: a symlink cannot be created from an unelevated token, so the test was inconclusive on
# 2026-08-16. It is not academic -- the app function that creates the live cycle is literally named
# ensureClairvoyanceHomeSymlink() and picks "junction" only on win32, so a future or non-win32 path
# produces a symlink with the identical cycle shape. An explicit /XD by full path is type-independent:
# it excludes the directory whatever kind of reparse point it is, so correctness no longer rests on an
# untested robocopy semantic. /XJD stays as defence in depth.
#
# CLASSIFICATION -- four cases, not two. The 2026-08-15 version collapsed these into "self-referential vs
# outbound" and told the operator "nothing is lost" for anything self-referential. That was FALSE on the
# ancestor branch (adversarial review, BLOCKER #1): if the target CONTAINS the source root, the source is inside the
# target, not the reverse, and most of the target is not covered here at all. A definitive "nothing is
# lost" over genuinely unbacked content is precisely the lying-verdict failure this file argues against
# everywhere else (see B2 at mirror-prune and the secrets-zero postmortem). Silence would beat that
# message; being right beats both.
#   SELF     target IS the source root -- the excluded content is this source. Nothing is lost.
#   INSIDE   target is strictly below the root -- covered ONLY if that subtree is really mirrored, so it
#            is NOT claimed when the path sits under an exclusion.
#   ANCESTOR target contains the root -- the source is inside the target. Most of it is NOT covered here.
#   OUTBOUND target is unrelated -- not copied at all; a coverage hole unless another source covers it.
#
# NOT depth-bounded. The 2026-08-15 version capped this at depth 4 to avoid "paying the full enumeration
# cost twice per source". adversarial review measured that cost: 1.9s bounded vs 4.2s unbounded across all 14 sources,
# i.e. +2.3s per nightly, against a 60-minute ceiling -- 0.07% of the margin, three orders of magnitude
# smaller than the thing it protects. The trade did not exist. The bound was also not harmless: it MISSED
# a live junction at depth 6 under workspace-ExampleMediaPipeline (scratch\tmp\s13\...\link), on a
# mirrored path, which /XJD dropped and this function said nothing about -- the exact silent skip it
# exists to prevent. Get-ChildItem -Recurse does not descend into reparse points (verified on
# PS 5.1.22621.6133 with a positive control), which is what makes an unbounded walk safe here.
function Report-Junctions($src){
  $found = New-Object System.Collections.Generic.List[string]
  $inc = Get-IncludeGlobs $src
  # An include-scoped source mirrors TOP-LEVEL FILES ONLY (no /MIR, no /S, no /E), so nothing below the
  # root is in scope and a reparse point down there was never going to be copied. Reporting it as
  # "excluded from the mirror" would be a false positive about a decision this function did not make.
  if($inc.Count){ Log "junction-scan" "PASS" "$($src.name): n/a (include-scoped: top-level files only, subtree never mirrored)"; return ,@() }

  $rootN = $src.path.TrimEnd('\') + '\'
  Get-ChildItem -LiteralPath $src.path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | ForEach-Object {
      $full = $_.FullName
      $kind = if($_.LinkType){ $_.LinkType } else { "reparse-point" }
      $found.Add($full)
      $tgt = ''
      try { $tgt = ($_.Target -join ';') } catch {}
      if(-not $tgt){
        Log "junction-skip" "WARN" "$($src.name): $kind excluded from mirror -- '$full' -> (target unreadable). Treat as UNBACKED until confirmed"
        return
      }
      $tgtN = $tgt.TrimEnd('\') + '\'
      if($tgtN -ieq $rootN){
        Log "junction-skip" "WARN" "$($src.name): CYCLE excluded from mirror -- '$full' -> '$tgt' IS this source root, which is copied directly; nothing is lost"
      } elseif($tgtN.StartsWith($rootN,[StringComparison]::OrdinalIgnoreCase)){
        $rel = $tgt.Substring($src.path.TrimEnd('\').Length).TrimStart('\')
        if(Is-Excluded $rel $src){
          Log "junction-skip" "WARN" "$($src.name): $kind excluded from mirror -- '$full' -> '$tgt' is inside this source but under an EXCLUSION, so that content is NOT in this archive"
        } else {
          Log "junction-skip" "WARN" "$($src.name): CYCLE excluded from mirror -- '$full' -> '$tgt' is inside this source and is mirrored directly; nothing is lost"
        }
      } elseif($rootN.StartsWith($tgtN,[StringComparison]::OrdinalIgnoreCase)){
        Log "junction-skip" "WARN" "$($src.name): $kind excluded from mirror -- '$full' -> '$tgt' is an ANCESTOR of this source; only the part under '$($src.path)' is covered here, the REST IS NOT. Confirm another source covers it"
      } else {
        Log "junction-skip" "WARN" "$($src.name): $kind excluded from mirror -- '$full' -> '$tgt'. Content behind it is NOT in this archive; confirm another source covers that path or it is UNBACKED"
      }
    }
  # ALWAYS emit, including the zero case -- same contract as the hash-guard summary at step 9b. A control
  # that logs only when it finds something cannot be distinguished from one that never ran.
  Log "junction-scan" "PASS" "$($src.name): directory reparse points found=$($found.Count)"
  return ,@($found.ToArray())
}

# ---- robocopy /MIR into persistent mirror; excludes secrets (F4) + encrypt-workspaces (F6a) ----
function Mirror-Source($src){
  $dst = Join-Path $mirror $src.name
  $inc = Get-IncludeGlobs $src
  # include-scoped sources drop /MIR deliberately: /MIR implies /E (recurse) + /PURGE, and an allowlist
  # wants neither. Robocopy's own positional file filter does the include; top-level-only is the default
  # when /S and /E are absent. Stale entries are pruned explicitly below (the /PURGE we gave up).
  # /XJD -- JUNCTION CYCLE GUARD (2026-08-15). robocopy FOLLOWS junction points unless told not to, and
  # a junction whose target contains its own parent is an infinite descent. Measured: a junction created
  # 2026-08-14 15:38 at UserData\.Clairvoyance\home targeting UserData ITSELF made the home-appdata mirror
  # descend 63 levels (deepest path 1,261 chars), write 637,742 files / 20.0 GB into the stage, and consume
  # the ENTIRE window -- 03:00:14 to 03:54, never reaching source 2 of 14 -- until the 04:00 host reboot
  # hard-killed the run. No archive, and because the kill is hard there was no last-run.json either.
  # /XJD not /XJ: /XJD excludes junctions for DIRECTORIES only, leaving file symlinks alone. It is now
  # DEFENCE IN DEPTH rather than the primary guard -- as of 2026-08-16 Report-Junctions returns each
  # directory reparse point and the caller excludes it by explicit /XD, which is type-independent and so
  # does not depend on whether /XJD covers directory SYMLINKS (untested; see that function's header).
  # It is on BOTH branches deliberately -- an include-scoped source does not
  # recurse today, but that is a property of the other switches, not a promise, and guarding one branch and
  # not its sibling is exactly how this class of defect survives.
  # NOTE for anyone tuning this: PowerShell 5.1's Get-ChildItem -Recurse does NOT descend into reparse
  # points (verified 2026-08-15 with a positive control -- the junction enumerates 60 children directly
  # while -Recurse returns 0 beneath it), so the other walkers in this file are already safe. .NET's
  # DirectoryInfo.GetDirectories() is NOT safe: it returns the junction like any other directory. Do not
  # "modernise" a Get-ChildItem walker here into a hand-rolled .NET one without an explicit attribute check.
  $tail = if($inc.Count){ @("/XJD","/R:2","/W:5","/NFL","/NDL","/NJH","/NJS","/NP") }
          else          { @("/MIR","/XJD","/R:2","/W:5","/NFL","/NDL","/NJH","/NJS","/NP") }
  foreach($x in $src.excludeDirs){ $tail += @("/XD",$x) }
  foreach($x in $script:secDirNames){ $tail += @("/XD",$x) }              # F4: never mirror secret dirs
  foreach($x in $src.excludeFiles){ $tail += @("/XF",$x) }
  foreach($x in $script:secFileNames){ $tail += @("/XF",$x) }             # F4: never mirror secret files
  if($Mode -eq "DryRun"){ $tail += "/L" }
  # 2026-08-16: name what is about to be dropped, AND drop it explicitly by full path. The returned list
  # is what makes the exclusion type-independent instead of resting on /XJD's unverified handling of
  # directory symlinks -- see the header on Report-Junctions. Comma-guarded return, so ASSIGN it directly:
  # an @() wrap would re-nest it (same trap as the line-236 manifest-nest-fix) and a bare pipe would
  # unroll it. The 2026-08-15 version discarded this value with | Out-Null, which is why it could only
  # report and not act.
  $jx = Report-Junctions $src
  foreach($p in $jx){ $tail += @("/XD",$p) }
  # RESIDUE CHECK (adversarial review 2026-08-16). EXCLUSION IS NOT RETROACTIVE: $mirror is PERSISTENT, and /MIR's
  # purge does not reach a directory that /XD or /XJD excluded from the walk. So anything copied through
  # a reparse point BEFORE it was excluded is frozen in the mirror -- invisible to the purge and silently
  # recompressed into every archive from now on. Verified by controlled test: pass 1 without /XJD created
  # dst\jlink\f.txt, pass 2 with /XJD left it in place, while the control (deleting a REAL source dir)
  # purged correctly. The 2026-08-15 incident missed this only by luck: the 20.0 GB landed in the stage
  # but under home-appdata\.Clairvoyance\home, which was cleared by hand before this ran.
  # This cannot self-heal, so it must at least be LOUD -- a permanent silent inclusion is the same class
  # of defect as the silent skip this whole change exists to close.
  foreach($p in $jx){
    $rel = $p.Substring($src.path.TrimEnd('\').Length).TrimStart('\')
    if($rel -and (Test-Path -LiteralPath (Join-Path $dst $rel))){
      Log "junction-residue" "WARN" "$($src.name): mirror still holds '$rel', copied through a reparse point BEFORE it was excluded. /MIR will NOT purge it and it ships in every archive until deleted from '$dst' by hand"
    }
  }
  $lastRc=-1
  foreach($bmode in @("/B","/ZB","")){
    # robocopy arg order is <source> <dest> [file...] [options] -- the include globs MUST precede the switches.
    $a = if($inc.Count){ if($bmode){ @($src.path,$dst)+$inc+@($bmode)+$tail } else { @($src.path,$dst)+$inc+$tail } }
         else          { if($bmode){ @($src.path,$dst,$bmode)+$tail }        else { @($src.path,$dst)+$tail } }
    & $robocopy @a | Out-Null; $lastRc=$LASTEXITCODE
    if($lastRc -lt 8){
      if($bmode -ne "/B"){ Log "copy-mode" "WARN" "$($src.name): used '$bmode' (rc=$lastRc)" }
      # Replaces /PURGE for include-scoped sources: if includeFiles is ever narrowed, previously-mirrored
      # files would otherwise linger in the persistent mirror and keep landing in every future archive.
      # C3: the prune must be able to report its OWN failure. The first version used
      # -ErrorAction SilentlyContinue and then logged unconditionally on the next line, so a
      # locked or in-use file logged "pruned" while still sitting in the mirror -- and would then be
      # archived despite not matching includeFiles. A guard that cannot fail loudly is not a guard.
      # Note: $_ inside catch is the ErrorRecord, not the pipeline item, so capture the name first.
      if($inc.Count -and $Mode -ne "DryRun"){
        Get-ChildItem -LiteralPath $dst -Force -ErrorAction SilentlyContinue | ForEach-Object {
          $item = $_
          if($item.PSIsContainer -or -not (Test-Included $item.Name $inc)){
            $nm = $item.Name
            try {
              Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
              Log "mirror-prune" "WARN" "$($src.name): pruned non-included '$nm' from mirror"
            } catch {
              # B2: Log() only appends to $logStages -- it does NOT touch $result. Every other FAIL in
              # this file sets ok=$false explicitly (secret-scrub, protected-paths, the outer catch).
              # Without this the run reports ok=true while a file that does NOT match includeFiles is
              # archived anyway: truthful detail, lying verdict. `ok` is what last-run.json carries and
              # what anything watching the nightly reads, so the verdict is the part that must not lie.
              # $result is defined in the main scope before the mirror loop, so this reaches it by the
              # same dynamic scoping Scan-Secrets already relies on.
              $result.ok=$false
              Log "mirror-prune" "FAIL" "$($src.name): COULD NOT prune '$nm' from mirror -- it does NOT match includeFiles but WILL be archived: $($_.Exception.Message)"
            }
          } } }
      return $dst }
  }
  throw "robocopy failed ($($src.name)) rc=$lastRc"
}
function Manifest-Source($src,$dst){
  Get-ChildItem -LiteralPath $dst -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $rel=$_.FullName.Substring($dst.Length).TrimStart('\'); $key="$($src.name)|$rel"
    $sha = Try-Hash $_.FullName $key $src.name $false      # F19: null => this ONE file is skipped, not the run
    if($null -eq $sha){ return }                           # 'return' inside ForEach-Object == continue to next file
    [pscustomobject]@{ rel=$rel; sha256=$sha; bytes=$_.Length; source=$src.name; category=$src.category; target=(Join-Path $src.path $rel) }
  }
}
# F4/F6a: gather secret files from LIVE sources (never mirrored). encrypt-workspaces => ALL files.
function Get-SecretFilesLive(){ $out=@()
  foreach($src in $script:effectiveSources){ if(-not (Test-Path -LiteralPath $src.path)){ continue }
    # An include-scoped source must NOT be recursed here. This function walks the LIVE path, so without
    # this branch a source rooted at the legacy C: base would pull that tree's auth-storage.json,
    # claude-auth-debug.jsonl and stale encryption-context.json into _secrets.7z regardless of how
    # narrow its includeFiles is. Enumerate top-level only, then apply the allowlist.
    $inc = Get-IncludeGlobs $src
    $srcFiles = if($inc.Count){ Get-ChildItem -LiteralPath $src.path -File -ErrorAction SilentlyContinue }
                else          { Get-ChildItem -LiteralPath $src.path -Recurse -File -ErrorAction SilentlyContinue }
    foreach($f in $srcFiles){
      $rel=$f.FullName.Substring($src.path.Length).TrimStart('\')
      if(-not (Test-Included $rel $inc)){ continue }
      if((Is-Excluded $rel $src)){ continue }
      if($src.encrypt -or (Match-Secret $rel $cfg.secretsSet)){
        # F19: SIBLING PATH of the Manifest-Source guard -- this walks the LIVE source, so it meets
        # exactly the same unopenable files. Tracked separately ($isSecret=$true) because the cost is
        # different in kind: a skipped secret is a CREDENTIAL missing from _secrets.7z, which the
        # hash-guard summary escalates to ok=false rather than a WARN.
        $sha = Try-Hash $f.FullName $null $src.name $true
        if($null -eq $sha){ continue }
        $out += [pscustomobject]@{ rel=$rel; sha256=$sha; bytes=$f.Length; source=$src.name; category=$src.category; target=$f.FullName; full=$f.FullName }
      }
    }
  }
  return ,@($out)
}
# F7/B2: pre-upload gate for NOVEL secrets leaking into the plaintext main set.
# B2: instead of only warning, PROACTIVELY SCRUB the secret from the archived copy
# (the mirror file -- NEVER the live source) and let the backup proceed. A night's
# backup is never skipped over a detected secret. Only when an in-line scrub is
# impossible (write fails) is that single file EXCLUDED from the archive so the
# secret cannot ship. Files that cannot be scanned (oversized/binary) are surfaced,
# never silently treated as clean. Returns the possibly-trimmed main manifest.
# F17 STAFF-MEMORY COVERAGE DRIFT (the maintainer 2026-08-02, ok=false ruling).
# Detects the enumeration drifting away from reality in BOTH directions. Gated on category, not
# source names, so a sixth memory source needs no edit here.
#   (1) configured-but-MISSING or configured-but-EMPTY. EMPTY is the one that matters: a renamed
#       workspace makes Claude Code mint a NEW, EMPTY project dir while the memory stays behind,
#       so the source resolves to a directory that EXISTS and holds nothing -- optional=true never
#       fires and the nightly backs up zero files forever. Absence alone is NOT a sufficient test.
#   (2) present-but-UNCONFIGURED: a project dir holding memory that no source covers. This is the
#       ONLY direction that catches the historical failure, because a rename WITHOUT repointing
#       leaves the configured source pointing at the old dir, still populated, so (1) stays silent.
# Sets ok=false, which under F15 WITHHOLDS Weekly/Monthly/Annual promotion. That is deliberate:
# a WARN would not create the pressure to fix it, and an archive that reports healthy while missing
# staff memory is worse than a stalled tier. Read the WITHHELD note at the tier guard before
# treating a sustained failure here as merely annoying -- intermediate boundaries are LOST, not deferred.
# staffMemoryIgnore is per-directory and explicit ON PURPOSE. It is not a global mute: there is
# deliberately no acknowledge-and-promote switch, because that would restore the silent pass this
# assertion exists to remove.
function Assert-StaffMemoryCoverage(){
  $root=$cfg.staffMemoryProjectsRoot
  if([string]::IsNullOrWhiteSpace($root)){ Log "staff-memory-coverage" "INFO" "staffMemoryProjectsRoot not configured -- coverage drift NOT checked"; return }
  if(-not (Test-Path -LiteralPath $root)){ $result.ok=$false; Log "staff-memory-coverage" "FAIL" ("projects root UNREADABLE: $root -- cannot verify coverage; an input we cannot read must not report the same as a clean result"); return }
  $ignore=@{}; foreach($g in @($cfg.staffMemoryIgnore)){ if($g){ $ignore[[string]$g]=$true } }
  $configured=@{}; $bad=@(); $nSrc=0
  foreach($s in $script:effectiveSources){ if($s.category -ne "staff-memory"){ continue }
    $nSrc++; $configured[([string]$s.path).TrimEnd("\\")]=$true
    if(-not (Test-Path -LiteralPath $s.path)){ $bad+="MISSING: $($s.name) -> $($s.path)"; continue }
    if(@(Get-ChildItem -LiteralPath $s.path -Recurse -File -EA SilentlyContinue).Count -eq 0){ $bad+="EMPTY: $($s.name) -> $($s.path)" }
  }
  foreach($d in @(Get-ChildItem -LiteralPath $root -Directory -EA SilentlyContinue)){
    if($ignore.ContainsKey([string]$d.Name)){ continue }
    $mem=Join-Path $d.FullName "memory"
    if(-not (Test-Path -LiteralPath $mem)){ continue }
    if(@(Get-ChildItem -LiteralPath $mem -Recurse -File -EA SilentlyContinue).Count -eq 0){ continue }
    if($configured.ContainsKey(([string]$mem).TrimEnd("\\"))){ continue }
    $bad+="UNCONFIGURED: $($d.Name) -> $mem"
  }
  if($bad.Count){ $result.ok=$false; Log "staff-memory-coverage" "FAIL" ("coverage drift (staff memory cannot be reconstructed from the repo): "+($bad -join "; ")+" -- fix config: add/repoint a source, or add the slug to staffMemoryIgnore") }
  else { Log "staff-memory-coverage" "PASS" ("$nSrc staff-memory source(s), all non-empty; no unconfigured memory dirs under $root") }
}

# ---- F18-C step 2: scan-coverage delta assert (2026-08-14) --------------------------------
# Step 1 RECORDS; this ASSERTS. Recording without asserting is instrumentation theatre --
# the ledger only earns its place if something reads it back.
#
# WHAT IT DETECTS: coverage silently shrinking. The failure it exists for is a reader rewrite
# (the deferred "A") that makes previously-scanned text files start being skipped -- the run
# still reports ok=true and every stage PASS, because nothing today compares one night to the
# next. `scanned` falling while `total` holds is the signal.
#
# WHY THE TOLERANCES LOOK LOOSE -- measured, not guessed. Coverage drifts DOWNWARD on its own
# as binaries accumulate: skipBin ran 435 -> 464 -> 521 over 08-11..08-13, and delta-scanned trailed
# delta-total by 29 then 57 files on those same nights. A tight ratio assert would fire on ordinary
# churn within a week and get muted, which is worse than no assert. So the ratio band is wide
# and the real detection weight sits on the PER-BUCKET jumps, which is where a reader
# regression actually shows up (misread -> skipRead, misclassified -> skipBin).
#
# VERDICT IS WARN-ONLY, per the maintainer's 2026-08-13 call, and there is deliberately NO auto-escalation
# on a date: a behaviour change that arrives by calendar is a surprise nobody consented to at the
# moment it fires. Escalating to ok=false is a separate, explicit decision.
#
# Compares LIVE-to-LIVE only. The ReadOnlyBaseline line is a replica of the scan path, not the
# shipped function, so it is used for CONTEXT only and can never produce a verdict.
function Get-LedgerLines($path){
  # Returns the parsed lines AND the count that failed to parse. Counting discards is not
  # bookkeeping: without it a truncated, BOM-re-encoded or corrupt ledger yields zero records and
  # the assert reports "first Live line" forever -- indistinguishable from a genuinely new ledger,
  # and silent for as long as the corruption lasts. Same reasoning as the append catch below.
  # (adversarial review review 2026-08-14, finding 5.)
  if(-not (Test-Path -LiteralPath $path)){ return [pscustomobject]@{ lines=@(); discarded=0; present=$false } }
  $out=@(); $bad=0
  foreach($ln in [IO.File]::ReadAllLines($path)){
    if([string]::IsNullOrWhiteSpace($ln)){ continue }
    # One corrupt line must not disarm the assert for every following night -- but it must be counted.
    try { $out += ($ln | ConvertFrom-Json) } catch { $bad++ }
  }
  return [pscustomobject]@{ lines=@($out); discarded=$bad; present=$true }
}
function ScanCov($r){ if([int]$r.total -gt 0){ return (100.0 * [int]$r.scanned / [int]$r.total) } else { return 0.0 } }
# InvariantCulture + RoundtripKind: ts_utc is written with ToString("o"). A culture-sensitive parse
# would silently return MinValue on a machine with a different locale, collapsing the sort order.
function LedgerTs($r){ $d=[datetime]::MinValue; [void][datetime]::TryParse([string]$r.ts_utc,[System.Globalization.CultureInfo]::InvariantCulture,[System.Globalization.DateTimeStyles]::RoundtripKind,[ref]$d); return $d }
function Assert-ScanDelta($cur,$ledger){
  # EXPLICIT script scope. Read as a bare ambient $cfg this silently falls back to every default the
  # moment any caller has a local $cfg in its scope chain -- thresholds would look configured and not
  # be. (adversarial review finding 4.)
  $t = $script:cfg.secretScanDelta
  $tCovPP      = if($t -and $null -ne $t.maxCoverageDropPP){ [double]$t.maxCoverageDropPP } else { 1.5 }
  $tAnchorPP   = if($t -and $null -ne $t.maxCoverageBelowAnchorPP){ [double]$t.maxCoverageBelowAnchorPP } else { 3.0 }
  $tWindow     = if($t -and $null -ne $t.anchorWindow){ [int]$t.anchorWindow } else { 7 }
  $tBinAbs     = if($t -and $null -ne $t.maxSkipBinJump){ [int]$t.maxSkipBinJump } else { 300 }
  $tReadAbs    = if($t -and $null -ne $t.maxSkipRead){ [int]$t.maxSkipRead } else { 25 }
  $tBigAbs     = if($t -and $null -ne $t.maxSkipBigJump){ [int]$t.maxSkipBigJump } else { 25 }
  $tMissAbs    = if($t -and $null -ne $t.maxSkipMissingJump){ [int]$t.maxSkipMissingJump } else { 25 }
  $tSkipBudget = if($t -and $null -ne $t.maxTotalSkipGrowth){ [int]$t.maxTotalSkipGrowth } else { 250 }
  $tScanLag    = if($t -and $null -ne $t.maxScanLagOnShrink){ [int]$t.maxScanLagOnShrink } else { 50 }
  # (!) THESE DEFAULTS ARE PROVISIONAL AS OF 2026-08-14 AND MUST NOT BE READ AS EMPIRICAL.
  # They were sized from three nightly rows (08-11..08-13) whose `scanned` was DERIVED from the run
  # log as total-oversized-binary, with skipRead and skipMissing ASSUMED ZERO -- those nights predate
  # the step-1 ledger and have no line at all. The single genuinely measured row, the ReadOnlyBaseline,
  # contradicts that assumption: it carries skipRead=8 and reconciles exactly (19529+66+521+0+8=20124).
  # Nothing here breaks on that (8 against a 250 budget is nothing), but the combined budget spans four
  # buckets of which TWO have never been observed on a Live run. The first real Live rows are the
  # CALIBRATION, not a confirmation. Re-check these numbers once ~7 Live lines exist.

  # ---- (1) RECONCILE. No history needed, so it works on the very first line. Every file must leave
  # the loop through exactly one counted door; if the arithmetic does not close there is a door no
  # counter covers -- which is how `scanned` over-reported before.
  # STATE PLAINLY, because a reader will assume otherwise: reconcile is SILENT on the regression this
  # feature exists to catch. Moving 300 files from scanned to skipBin closes the sum perfectly.
  # Reconcile detects a FIFTH UNCOUNTED door; rewrite "A" uses an EXISTING counted one. Reconcile
  # passing is not evidence about coverage. (adversarial review finding 6.)
  $sum = [int]$cur.scanned + [int]$cur.skipBig + [int]$cur.skipBin + [int]$cur.skipMissing + [int]$cur.skipRead
  if($sum -ne [int]$cur.total){
    Log "scan-delta" "WARN" ("RECONCILE FAILED: scanned+skipBig+skipBin+skipMissing+skipRead = $sum but total = $($cur.total) (difference $([Math]::Abs($sum - [int]$cur.total))). A file is leaving the scan loop through an UNCOUNTED path, so 'scanned' overstates real coverage.")
  }
  if($ledger -and [int]$ledger.discarded -gt 0){
    Log "scan-delta" "WARN" ("ledger integrity: $($ledger.discarded) line(s) in secret-scan-counts.jsonl could not be parsed and were ignored. A wholly unreadable ledger otherwise looks identical to a brand-new one, so the comparisons below may be running against less history than they appear to.")
  }

  if([string]$cur.mode -ne 'Live'){ Log "scan-delta" "INFO" "mode=$($cur.mode); delta verdict is Live-to-Live only, not evaluated"; return }

  # Sort by TIMESTAMP, not file order: an out-of-order append (a manual re-run, or a Live run that
  # finishes after a later one started) would otherwise silently select the wrong reference.
  $lines = if($ledger){ @($ledger.lines) } else { @() }
  $live  = @($lines | Where-Object { [string]$_.mode -eq 'Live' }             | Sort-Object { LedgerTs $_ })
  $prev  = @($live) | Select-Object -Last 1
  # Baseline also selected by timestamp, not file order: a later re-baseline appended out of order
  # would otherwise be ignored in favour of an older one.
  $base  = @($lines | Where-Object { [string]$_.mode -eq 'ReadOnlyBaseline' } | Sort-Object { LedgerTs $_ }) | Select-Object -Last 1

  # ---- THE ANCHOR. This is the fix for the two blocking findings in adversarial review's 2026-08-14 review.
  # Comparing only against the PREVIOUS Live line makes this a first-derivative alarm with nothing
  # holding the level: (a) the FIRST Live line silently becomes the reference, so a rewrite landing
  # before it is baked in and undetectable at any threshold; (b) thereafter each night is graded
  # against the last, so an absorbed regression is promoted to the new pass mark permanently.
  # Anchoring on the BEST coverage in a trailing window fixes both, and the ReadOnlyBaseline SEEDS it
  # so the very first Live run is graded rather than merely recorded. The baseline is a replica of the
  # scan path, not the shipped function -- but it measured 97.04% against three Live nights at
  # 97.40/97.36/97.09, i.e. within 0.05pp, so it is empirically an excellent level anchor even though
  # it must never be used for a per-night DELTA.
  # RESIDUAL, STATED SO IT IS NOT DISCOVERED LATER: the window is ROLLING, so a regression that is
  # WARNed and then ignored for $tWindow consecutive Live runs eventually ages out of the anchor and
  # becomes the new normal. That is deliberate, not an oversight -- pinning the anchor to the
  # baseline forever would eventually turn legitimate long-term drift (binaries accumulating) into a
  # permanently red run, and a permanently red run teaches everyone to ignore red. The trade is: you
  # get $tWindow consecutive nights of WARN naming the drop. If nobody acts in a week, the instrument
  # has done its job and the level re-seats.
  # THE SEED MUST STAY IN THE CANDIDATE SET UNTIL THE WINDOW IS FULL. Taking best-of-window OR the
  # baseline (an elseif) discards the seed the moment ONE Live line exists -- so a regression present
  # from the very first Live run becomes its own anchor on run 2, and the ratchet reopens after ONE
  # night rather than the $tWindow the rolling window implies. The window has no good night in it yet.
  # max(window, seed) while the window is still filling. (adversarial review round-2 review, finding 1, BLOCKING.)
  $window = @($live) | Select-Object -Last $tWindow
  $cands  = @($window)
  if($base -and @($live).Count -lt $tWindow){ $cands += $base }
  $anchor = $null; $anchorWhat = ""
  if(@($cands).Count){
    $anchor = @($cands | Sort-Object { ScanCov $_ })[-1]
    $anchorWhat = if([string]$anchor.mode -eq 'ReadOnlyBaseline'){ "ReadOnlyBaseline seed ($($anchor.stamp))" }
                  elseif(@($live).Count -lt $tWindow){ "best of $(@($window).Count) Live + seed ($($anchor.stamp))" }
                  else { "best of last $(@($window).Count) Live ($($anchor.stamp))" }
  }

  # UNCONDITIONAL CONTEXT FIELD -- never a verdict, printed on PASS and WARN alike. The rolling anchor
  # DESCENDS in lockstep with a sustained regression, so the WARN text is identical on night 7 and
  # night 40 while the damage compounds: the instrument reports a constant. This field grows with the
  # damage, so "-3.0pp vs anchor, -14.2pp vs baseline" tells you how bad it has got without adding a
  # second alarm or destabilising the verdict. (adversarial review round-2, finding 2.)
  $allCands = @($live); if($base){ $allCands += $base }
  $ctxTxt = ""
  if(@($allCands).Count){
    $allBest = @($allCands | Sort-Object { ScanCov $_ })[-1]
    $ctxTxt = " | vs all-time best [$($allBest.stamp)] $([Math]::Round((ScanCov $allBest),2))%: $([Math]::Round((ScanCov $cur) - (ScanCov $allBest),3))pp"
  }

  $covNow = ScanCov $cur
  $find=@()

  # ---- (2) LEVEL check against the anchor. Catches the slow bleed and makes ratcheting impossible:
  # coverage can never drift more than the band below the best recently observed.
  if($anchor){
    $covAnc = ScanCov $anchor
    $dAnc   = [Math]::Round($covNow - $covAnc, 3)
    if($dAnc -lt (-1 * $tAnchorPP)){
      $find += "coverage is ${dAnc}pp BELOW the anchor [$anchorWhat] ($([Math]::Round($covAnc,2))% -> $([Math]::Round($covNow,2))%), beyond the ${tAnchorPP}pp level band"
    }
  } else {
    # A Live run with NO anchor is exactly the state in which this assert cannot do its job -- a
    # fresh, truncated, rotated or wholly corrupt ledger. Reporting PASS there is the silent
    # first-run hole reopening under a different cause. (adversarial review round-2, finding 5.)
    $find += "NO ANCHOR AVAILABLE -- the ledger holds no usable Live or ReadOnlyBaseline row, so NO level check ran and a coverage regression could not be detected on this run"
  }

  if(-not $prev){
    # ${name} not $name: a bare '$anchorWhat:' parses the colon as a SCOPE QUALIFIER ($script:, $env:)
    # and is a syntax error, not a string with a colon in it.
    $lvl = if($anchor){ " Level check ran against the ${anchorWhat}: $([Math]::Round((ScanCov $anchor),2))% -> $([Math]::Round($covNow,2))%." } else { " No anchor available, so NO level check ran." }
    if($find.Count){
      Log "scan-delta" "WARN" ("COVERAGE REGRESSION SUSPECTED on the FIRST Live line (verdict is WARN-only by decision, run NOT marked unhealthy): " + ($find -join '; ') + " || scanned=$($cur.scanned)/$($cur.total) ($([Math]::Round($covNow,2))%)." + $lvl + $ctxTxt)
    } else {
      Log "scan-delta" "PASS" ("first Live ledger line -- per-night delta comparisons arm from the next Live run. scanned=$($cur.scanned)/$($cur.total) ($([Math]::Round($covNow,2))%)." + $lvl + $ctxTxt)
    }
    return
  }

  $covPrev = ScanCov $prev
  $dCov    = [Math]::Round($covNow - $covPrev, 3)
  $dScan   = [int]$cur.scanned - [int]$prev.scanned
  $dTotal  = [int]$cur.total   - [int]$prev.total

  # A config change EXPLAINS a delta. Compare only when BOTH sides carry the field: [int]$null is 0,
  # so a pre-step-1 line without maxFileKB would fabricate a "0 -> 1024" change and, through the
  # guard below, silently disable the skipBig check. (adversarial review finding 4.)
  $capChanged=$false; $cfgChg=@()
  if($null -ne $prev.maxFileKB -and $null -ne $cur.maxFileKB -and [int]$cur.maxFileKB -ne [int]$prev.maxFileKB){ $cfgChg += "maxFileKB $($prev.maxFileKB)->$($cur.maxFileKB)"; $capChanged=$true }
  if($null -ne $prev.patterns  -and $null -ne $cur.patterns  -and [int]$cur.patterns  -ne [int]$prev.patterns ){ $cfgChg += "patterns $($prev.patterns)->$($cur.patterns)" }

  # ---- (3) the workhorse: an absolute drop in scanned that the corpus does not explain.
  # Two arms on purpose. The first keeps the original tightness (ANY drop when the corpus did not
  # shrink). The second closes the hole where `dTotal -lt 0` was an unconditional excuse: a night
  # that legitimately loses 1000 files but drops 1200 scanned is a 200-file regression hiding inside
  # a shrink. (adversarial review finding 3.)
  if($dTotal -ge 0 -and $dScan -lt 0){
    $find += "scanned DROPPED by $([Math]::Abs($dScan)) while total rose by $dTotal"
  } elseif($dTotal -lt 0 -and ($dScan - $dTotal) -lt (-1 * $tScanLag)){
    $find += "corpus shrank by $([Math]::Abs($dTotal)) but scanned fell by $([Math]::Abs($dScan)) -- $([Math]::Abs($dScan - $dTotal)) more than the shrink explains"
  }

  # ---- (4) per-night ratio band. Faster to fire than the level check on a single bad night.
  # Boundaries are EXCLUSIVE throughout (-lt / -gt): exactly -1.5pp, exactly +300 skipBin etc. PASS.
  # Deliberate -- at these magnitudes one file either way is noise, and an inclusive bound would make
  # the documented tolerance fire at the tolerance.
  if($dCov -lt (-1 * $tCovPP)){ $find += "coverage fell ${dCov}pp night-over-night ($([Math]::Round($covPrev,2))% -> $([Math]::Round($covNow,2))%), beyond the ${tCovPP}pp band" }

  # ---- (5) per-bucket jumps: WHERE the loss went. Each bucket is a distinct mechanism.
  if([int]$cur.skipRead -gt $tReadAbs -and [int]$cur.skipRead -gt (3 * [Math]::Max([int]$prev.skipRead,1))){ $find += "skipRead spiked $($prev.skipRead) -> $($cur.skipRead) (reader failing to open files it used to read)" }
  if(([int]$cur.skipBin - [int]$prev.skipBin) -gt $tBinAbs){ $find += "skipBin jumped $($prev.skipBin) -> $($cur.skipBin), beyond the $tBinAbs-file band -- text may now be misclassified as binary" }
  # skipMissing had NO band at all and is the natural destination for "the reader can no longer find
  # the file" -- a plausible outcome of the very rewrite this assert exists to catch. (adversarial review 3.)
  if(([int]$cur.skipMissing - [int]$prev.skipMissing) -gt $tMissAbs){ $find += "skipMissing jumped $($prev.skipMissing) -> $($cur.skipMissing) -- files present in the manifest but absent from the mirror" }
  # Suppressed ONLY by a cap change; a patterns change has nothing to do with the size threshold.
  if(-not $capChanged -and ([int]$cur.skipBig - [int]$prev.skipBig) -gt $tBigAbs){ $find += "skipBig jumped $($prev.skipBig) -> $($cur.skipBig) with maxFileKB unchanged" }

  # ---- (6) COMBINED skip budget. The per-bucket bands are tested independently, so a loss split
  # across four buckets can stay under all four while summing to a material regression. One budget
  # over the sum removes that evasion without changing any individual tolerance. (adversarial review finding 3.)
  $skipNow  = [int]$cur.skipBig  + [int]$cur.skipBin  + [int]$cur.skipRead  + [int]$cur.skipMissing
  $skipPrev = [int]$prev.skipBig + [int]$prev.skipBin + [int]$prev.skipRead + [int]$prev.skipMissing
  if(($skipNow - $skipPrev) -gt $tSkipBudget){ $find += "total unscanned grew $skipPrev -> $skipNow (+$($skipNow - $skipPrev)) across all buckets, beyond the $tSkipBudget-file combined budget" }

  $ancTxt = " | no anchor"
  if($anchor){
    $covAnc2 = ScanCov $anchor
    $dAnc2   = [Math]::Round($covNow - $covAnc2, 3)
    $ancTxt  = " | anchor [$anchorWhat] $([Math]::Round($covAnc2,2))%, delta ${dAnc2}pp"
  }
  $stat = "scanned=$($cur.scanned)/$($cur.total) ($([Math]::Round($covNow,2))%) vs prev Live $($prev.stamp) $($prev.scanned)/$($prev.total) ($([Math]::Round($covPrev,2))%) | dScanned=$dScan dTotal=$dTotal dCov=${dCov}pp | skipBig=$($cur.skipBig) skipBin=$($cur.skipBin) skipRead=$($cur.skipRead) skipMissing=$($cur.skipMissing)" + $ancTxt + $ctxTxt
  $note = if($cfgChg.Count){ " | CONFIG CHANGED: " + ($cfgChg -join ', ') + " -- deltas above are expected to move" } else { "" }

  if($find.Count){
    Log "scan-delta" "WARN" ("COVERAGE REGRESSION SUSPECTED (verdict is WARN-only by decision, run NOT marked unhealthy): " + ($find -join '; ') + " || " + $stat + $note)
  } else {
    Log "scan-delta" "PASS" ($stat + $note)
  }
}

function Scan-Secrets($mainMan){ if(-not $cfg.secretScanPatterns){ return ,@($mainMan) }
  $maxB=([int]$cfg.secretScanMaxFileKB)*1024
  # $out is a List, not @(): `+=` on an array reallocates the whole array per element, which at
  # 24k entries measured 18.1s against 0.06s for List.Add -- 300x, all of it interpreter overhead.
  $scrubbed=@(); $dropped=@(); $skipBig=0; $skipBin=0; $flagged=@(); $out=New-Object 'Collections.Generic.List[object]'
  # F18-C scan-counts ledger (2026-08-13). $scanned is counted EXPLICITLY, not derived as
  # total-skipBig-skipBin: three paths below (absent from mirror, read failure, null content)
  # also leave a file unexamined, and subtraction would silently book them as scanned -- the
  # exact over-reporting this ledger exists to catch.
  $scanned=0; $skipMissing=0; $skipRead=0
  # ---- F20 incremental scan --------------------------------------------------------------
  # Only files whose content changed are read; everything else re-emits its recorded outcome.
  # Rationale and measurements: CHANGELOG. The three facts below are editing constraints.
  #
  # 1. REUSE RESTS ON THE HASH CACHE, NOT ON A HASH OF THE BYTES BEING SKIPPED.
  #    The test is $prior.s -eq $e.sha256, and $e.sha256 arrives via Manifest-Source -> Try-Hash
  #    -> Hash-Cached, which returns a STORED hash whenever size and LastWriteTimeUtc.Ticks match
  #    -- without opening the file. So "content unchanged" is decided by size+mtime.
  #    Before F20 the scanner read every file regardless, so a stale cached hash was inert; F20
  #    promotes it into a read/skip decision. Anything that weakens Hash-Cached's key, or that
  #    reuses a hash from a wider window, widens this scanner's blind spot by the same amount.
  #
  # 2. $scanned MEANS "HOLDS A VALID VERDICT UNDER THE CURRENT RULE SET", NOT "READ THIS RUN".
  #    Assert-ScanDelta compares it against the ledger's history, so redefining it silently
  #    invalidates every prior night's comparison. fresh/cached are reported separately for
  #    exactly that reason; do not fold them into $scanned.
  #
  # 3. THE VERDICT STORE IS SEPARATE FROM .hashcache.json DELIBERATELY.
  #    The hash cache is persisted by the FAILURE path (see the catch at the bottom of the run),
  #    so a run that dies before Scan-Secrets -- e.g. at Assert-Window "secrets", immediately
  #    before it -- records fresh hashes for files it never scanned. Deriving skips from a
  #    hash-cache hit would make those files invisible to the scanner. "Hashed" and "scanned" are
  #    different facts and must not share a record.
  $vs = Load-ScanVerdicts
  $curEpoch = Get-ScanEpoch
  $epochOk = ($null -ne $vs.epoch -and $vs.epoch -eq $curEpoch)
  if(-not $epochOk){ Log "scan-epoch" "WARN" ("rule set changed or no baseline (stored=$($vs.epoch) current=$curEpoch) -- FULL rescan this run; every stored verdict answered a question we are no longer asking") }
  # doRehash (the 28-day integrity pass) also forces a full rescan: it is already the mechanism
  # that refuses to let a cached fact live forever, and the scan needs exactly that bound too.
  $auditRate = if($null -ne $cfg.secretScanAuditRate){ [double]$cfg.secretScanAuditRate } else { 0.01 }
  # REUSE REQUIRES ITS CONTROL. The audit sample is the only thing that can falsify a stored
  # verdict; with auditRate at 0 reuse becomes unfalsifiable and a wrong verdict passes silently.
  # So a zero rate disables REUSE, not the audit -- fail slow, never fail quiet.
  $auditDisabled = ($auditRate -le 0)
  if($auditDisabled){ Log "scan-audit" "WARN" "secretScanAuditRate=$auditRate disables the only check on reuse, so reuse is DISABLED this run and every file is read" }
  $forceFull = (-not $epochOk) -or $script:doRehash -or $auditDisabled
  $fresh=0; $cachedN=0; $audited=0; $auditMismatch=@(); $newVerdicts=@{}
  $rnd = New-Object Random
  # NO-SCRUB SET: source NAMES whose category is exempt from the destructive rewrite below.
  # Gated on CATEGORY, not names, so adding a sixth staff-memory source needs no edit here.
  $noScrub=@{}; foreach($ns in $script:effectiveSources){ if($ns.category -eq "staff-memory"){ $noScrub[[string]$ns.name]=$true } }
  foreach($e in $mainMan){
    if($e.bytes -gt $maxB){ $skipBig++; $out.Add($e); continue }
    $vkey="$($e.source)|$($e.rel)"
    $full=Join-Path (Join-Path $mirror $e.source) $e.rel
    # ---- verdict reuse: identical CONTENT, identical rule set => outcome cannot have changed --
    $prior = if($forceFull){ $null } else { $vs.verdicts[$vkey] }
    $reuse = ($null -ne $prior -and [string]$prior.s -eq [string]$e.sha256)
    # AUDIT SAMPLE (the control): a fraction of reusable files are re-read anyway and their fresh
    # outcome compared to the stored one. Without this, a wrong verdict is unfalsifiable -- and a
    # counter that records reuse without ever testing it is instrumentation, not a control.
    $isAudit = ($reuse -and $auditRate -gt 0 -and $rnd.NextDouble() -lt $auditRate)
    if($reuse -and -not $isAudit){
      $cachedN++
      switch([string]$prior.o){
        'b' { $skipBin++ }
        'r' { $skipRead++ }
        'f' { $scanned++; $flagged+="$($e.source)\$($e.rel)" }
        default { $scanned++ }
      }
      $newVerdicts[$vkey]=$prior
      $out.Add($e); continue
    }
    # On an audited file, $auditPriorO holds the outcome the store CLAIMED for this exact sha.
    # Any terminal below that disagrees with it is a verdict that was wrong, which is the one
    # thing the reuse path cannot detect about itself.
    $auditPriorO = if($isAudit){ [string]$prior.o } else { $null }
    if(-not [IO.File]::Exists($full)){ $skipMissing++; $out.Add($e); continue }
    # Counted HERE, at the open, not after the binary/read-error branches: `fresh` is the cost
    # metric -- files this run actually opened -- and a binary file costs a full read to discover
    # it is binary. Counting it later made fresh and cached tally different populations (fresh=4
    # vs cached=5 over the same five files), which would have made the ledger unreadable.
    # Invariant: fresh + cached + skipBig + skipMissing == total.
    $fresh++; if($isAudit){ $audited++ }
    $txt=$null; try { $txt=[IO.File]::ReadAllText($full) } catch { $skipRead++; if($auditPriorO -and $auditPriorO -ne 'r'){ $auditMismatch+="$($e.source)\$($e.rel) (stored=$auditPriorO fresh=r)" }; $newVerdicts[$vkey]=@{s=$e.sha256;o='r'}; $out.Add($e); continue }
    if($null -eq $txt){ $skipRead++; if($auditPriorO -and $auditPriorO -ne 'r'){ $auditMismatch+="$($e.source)\$($e.rel) (stored=$auditPriorO fresh=r)" }; $newVerdicts[$vkey]=@{s=$e.sha256;o='r'}; $out.Add($e); continue }
    if($txt.IndexOf([char]0) -ge 0){ $skipBin++; if($auditPriorO -and $auditPriorO -ne 'b'){ $auditMismatch+="$($e.source)\$($e.rel) (stored=$auditPriorO fresh=b)" }; $newVerdicts[$vkey]=@{s=$e.sha256;o='b'}; $out.Add($e); continue }   # binary: cannot text-scrub
    $scanned++   # examined; a flagged (no-scrub) file below still counts as scanned
    $found=$false; $new=$txt
    foreach($pat in $cfg.secretScanPatterns){ if($new -match $pat){ $found=$true; $new=[regex]::Replace($new,$pat,'***REDACTED-BY-BACKUP-SCRUB***') } }
    if(-not $found){ if($auditPriorO -and $auditPriorO -ne 'c'){ $auditMismatch+="$($e.source)\$($e.rel) (stored=$auditPriorO fresh=c)" }; $newVerdicts[$vkey]=@{s=$e.sha256;o='c'}; $out.Add($e); continue }
    # A secret WAS found. If the store claimed 'c' for this exact content hash, the stored verdict
    # was wrong -- this is the leak the audit sample exists to catch, and it is reported as FAIL.
    if($auditPriorO -eq 'c'){ $auditMismatch+="$($e.source)\$($e.rel) (stored=c fresh=SECRET-FOUND)" }
    # STAFF-MEMORY NO-SCRUB (the maintainer 2026-08-02). Detect and WARN, but never rewrite. These files
    # exist to RECORD failure modes, and a credential-shaped failure mode must be written in
    # credential-shaped text -- scrubbing destroys the exact string that made the note worth
    # keeping (measured: pattern[4] cuts mid-value, leaving a mangled line, not a clean hole).
    # The SCAN is deliberately NOT skipped: exempting these from DETECTION would let a real
    # credential reach plaintext _main.7z with no signal at all -- trading a lossy archive for
    # a silent leak, which is strictly worse. The entry is passed through UNMODIFIED, so its
    # bytes/sha256 still describe the archived file and deep-verify stays consistent.
    if($noScrub.ContainsKey([string]$e.source)){ $flagged+="$($e.source)\$($e.rel)"; $newVerdicts[$vkey]=@{s=$e.sha256;o='f'}; $out.Add($e); continue }
    try {
      # ENCODING: detection reads via [IO.File]::ReadAllText (BOM, else UTF8) because it is ~5x
      # cheaper and the patterns are pure ASCII, so detection is decoder-independent. The WRITE
      # is not: for a BOM-less file in the system codepage the two decoders disagree, and this is
      # the only destructive path in the function. So the bytes we rewrite are re-read through
      # Get-Content -Raw -- the exact decoder the pre-F20 code used -- leaving scrub output
      # byte-identical to today's. Costs one extra read on the ~17 files a night that scrub.
      # (powershell-encoding-roundtrip)
      $orig = Get-Content -Raw -LiteralPath $full -ErrorAction Stop
      $new = $orig
      foreach($pat in $cfg.secretScanPatterns){ if($new -match $pat){ $new=[regex]::Replace($new,$pat,'***REDACTED-BY-BACKUP-SCRUB***') } }
      # TWO DECODERS, AND THE SECOND ONE DECIDES THE BYTES. Detection ran on ReadAllText; the
      # replace above runs on Get-Content -Raw. If a pattern ever matches under one and not the
      # other, this branch would write the file back UNCHANGED-but-re-encoded and record it clean
      # -- booking a scrub that removed nothing while the secret is still in the archive. Refuse
      # to treat that as a scrub. -ceq: case-SENSITIVE, since a case-only delta is still a delta.
      if($new -ceq $orig){ throw "scrub removed nothing: detection matched under ReadAllText but the replace pass matched nothing under Get-Content -Raw (decoder disagreement)" }
      Set-Content -LiteralPath $full -Value $new -Encoding UTF8 -NoNewline -ErrorAction Stop
      $e.bytes=(Get-Item -LiteralPath $full).Length
      $e.sha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash   # keep manifest == archived bytes (deep-verify stays consistent)
      # Verdict is recorded against the POST-scrub sha, whose content is now genuinely clean.
      # (Next run robocopy restores the unscrubbed original, its sha differs, and it is rescanned
      # and rescrubbed -- which is why `scrubbed` stays non-zero night after night, as today.)
      $newVerdicts[$vkey]=@{s=$e.sha256;o='c'}
      $scrubbed+="$($e.source)\$($e.rel)"; $out.Add($e)
    } catch {
      try { Remove-Item -LiteralPath $full -Force -ErrorAction Stop } catch {}   # cannot scrub -> exclude so it can't leak (file NOT added to $out)
      # NO verdict recorded: the file is not in the archive, and a stored verdict would let a
      # later run that CAN read it skip the scan on a sha it never actually examined.
      $newVerdicts.Remove($vkey)
      $dropped+="$($e.source)\$($e.rel)"
    }
  }
  if($scrubbed.Count){ Log "secret-scrub" "WARN" ("scrubbed secret(s) from plaintext main -- archived copy only, live source untouched: "+((@($scrubbed)|Select-Object -First 5) -join '; ')+$(if($scrubbed.Count -gt 5){" (+$($scrubbed.Count-5) more)"}else{""})) }
  if($dropped.Count){ $result.ok=$false; Log "secret-scrub" "FAIL" ("could not scrub; EXCLUDED from archive to prevent leak (file NOT backed up this run): "+(@($dropped) -join '; ')) }
  if($skipBig -or $skipBin){ Log "secret-scan" "WARN" ("not scanned (so NOT scrubbed): $skipBig oversized (>$($cfg.secretScanMaxFileKB)KB), $skipBin binary") }
  if($flagged.Count){ Log "secret-flag" "WARN" ("secret-shaped text DETECTED but deliberately NOT scrubbed (category=staff-memory; archived verbatim, live source untouched) -- REVIEW each: "+((@($flagged)|Select-Object -First 5) -join "; ")+$(if($flagged.Count -gt 5){" (+$($flagged.Count-5) more)"}else{""})) }
  if(-not $scrubbed.Count -and -not $dropped.Count -and -not $flagged.Count){ Log "secret-scan" "PASS" ("no novel secrets in main set"+$(if($skipBig -or $skipBin){" ($skipBig oversized/$skipBin binary not scanned)"}else{""})) }
  # ---- F20: report the split, and ASSERT the control ---------------------------------------
  # A pass must leave a trace: a run that silently reused every verdict is indistinguishable from
  # one where the scanner never executed, unless the split is written down every time.
  Log "scan-mode" "PASS" ("fresh=$fresh cached=$cachedN audited=$audited of total=$(@($mainMan).Count) | epoch=$curEpoch reuse=$(if($forceFull){'DISABLED'}else{'on'})$(if($script:doRehash){' (28-day integrity pass: FULL rescan)'}elseif(-not $epochOk){' (rule set changed: FULL rescan)'}else{''}) | auditRate=$auditRate")
  # THE CONTROL. A mismatch means a stored verdict did not describe the bytes it was keyed to --
  # i.e. the reuse path skipped a file it should have read. Fail the run AND drop the epoch, so
  # the next run cannot reuse anything from a store that has demonstrably lied once.
  if($auditMismatch.Count){
    $result.ok=$false
    Log "scan-audit" "FAIL" ("VERDICT STORE WRONG on $($auditMismatch.Count) of $audited audited file(s) -- reuse is unsafe and the store is being invalidated; next run scans everything: "+((@($auditMismatch)|Select-Object -First 5) -join '; ')+$(if($auditMismatch.Count -gt 5){" (+$($auditMismatch.Count-5) more)"}else{""}))
    $curEpoch = $null
  } elseif($audited -gt 0){
    Log "scan-audit" "PASS" "$audited reused verdict(s) re-read and confirmed against fresh scan"
  } elseif($cachedN -gt 0){
    # Reuse happened but nothing tested it. Not a failure, but it must not read as a clean bill.
    Log "scan-audit" "WARN" "$cachedN verdict(s) reused with ZERO audited this run (auditRate=$auditRate) -- reuse was not tested"
  }
  # Persist LAST, and only here: reaching this point means the scan phase completed. Persisting
  # earlier (or from the failure path, as the hash cache does) would record files as scanned by a
  # run that died before scanning them.
  try { Save-ScanVerdicts $curEpoch $newVerdicts }
  catch { Log "scan-verdicts" "WARN" ("could not persist verdict store, next run rescans everything: " + $_.Exception.Message) }
  # ---- F18-C step 1: append the scan-counts ledger line ----------------------------------
  # WHY: `scanned` falling while `total` holds is the signal that coverage silently shrank.
  # `mode` is MANDATORY and recorded, so a DryRun line can never be read as a live one
  # (that bug already exists in the neighbouring last-run.json and is not being repeated).
  # Step 2 SHIPPED 2026-08-14: see Assert-ScanDelta above. It did NOT need the ~7 live lines
  # this comment originally promised to wait for -- the tolerances were sized from the 2026-08-13
  # read-only baseline plus the 08-11..08-13 nightly log history, which gave real churn figures
  # without waiting a week. Recording without asserting is NOT done, and no longer is.
  try {
    # Path resolves through the SAME resolver as the other state files (cfg.lastRunFile's
    # directory), not a baked literal and not $PSScriptRoot -- the latter is empty inside a
    # dynamically-created scriptblock, which makes this branch untestable in isolation.
    $countsDir = if($cfg.lastRunFile){ Split-Path -Parent $cfg.lastRunFile } else { $PSScriptRoot }
    if(-not $countsDir){ throw "cannot resolve ledger directory (cfg.lastRunFile unset and PSScriptRoot empty)" }
    $countsPath = Join-Path $countsDir "secret-scan-counts.jsonl"
    # Step 2: read the history BEFORE appending. Read it after and "the last Live line" is the
    # one we are about to write -- the assert would compare this run against itself and always pass.
    # Selection of the reference (previous Live, and the level anchor) lives INSIDE Assert-ScanDelta
    # so the choice is testable in one place rather than split across the call site.
    $ledger = Get-LedgerLines $countsPath
    $rec = [ordered]@{
      ts_utc      = (Get-Date).ToUniversalTime().ToString("o")
      local_day   = $now.ToString("yyyy-MM-dd")
      stamp       = $stamp
      mode        = $Mode
      total       = @($mainMan).Count
      scanned     = $scanned
      skipBig     = $skipBig
      skipBin     = $skipBin
      skipMissing = $skipMissing
      skipRead    = $skipRead
      flagged     = @($flagged).Count
      scrubbed    = @($scrubbed).Count
      dropped     = @($dropped).Count
      maxFileKB   = [int]$cfg.secretScanMaxFileKB
      patterns    = @($cfg.secretScanPatterns).Count
      # F20. `scanned` above still means "holds a valid verdict under the current rule set", which
      # is what Assert-ScanDelta's history comparisons are about -- so those tolerances keep
      # working unchanged. These say HOW that coverage was obtained. freshScanned collapsing to 0
      # while scanned holds is the signal that the scanner stopped executing entirely.
      freshScanned  = $fresh
      cachedVerdict = $cachedN
      audited       = $audited
      auditMismatch = @($auditMismatch).Count
      scanEpoch     = [string]$curEpoch
      fullRescan    = [bool]$forceFull
    }
    # ConvertTo-Json, never -f: the format operator silently emits literal {n} on this codebase.
    # AppendAllText with a BOM-less UTF8 encoder -- Add-Content -Encoding UTF8 injects a BOM,
    # and a BOM mid-file breaks every downstream JSON reader of this ledger.
    $line = ($rec | ConvertTo-Json -Compress -Depth 3)
    [IO.File]::AppendAllText($countsPath, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
  } catch {
    # Instrumentation must never fail the backup -- but its absence must leave a trace,
    # or a ledger that stopped writing is indistinguishable from one that never drifted.
    Log "secret-scan-counts" "WARN" ("could not append scan-counts ledger: " + $_.Exception.Message)
  }
  # Step 2 assert, OUTSIDE the append try/catch on purpose: folded inside, a fault in the assert
  # would be reported as "could not append the ledger", sending the reader to the wrong defect.
  # $rec survives the try (PowerShell try does not open a scope) but is absent if the append
  # block threw before building it -- hence the guard.
  if($rec){
    try { Assert-ScanDelta $rec $ledger }
    catch { Log "scan-delta" "WARN" ("delta assert failed to evaluate (counts still recorded): " + $_.Exception.Message) }
  }
  # $out is a List now: ToArray() first, THEN comma-guard. Assign-then-return rather than
  # ,@($out) so there is no question of the wrap re-nesting. (powershell-comma-guard-access-rule)
  $outArr = $out.ToArray()
  return ,$outArr
}

function Upload-Verify($srcFile,$destDir){
  New-Item -ItemType Directory -Force -Path $destDir | Out-Null
  $leaf = Split-Path $srcFile -Leaf
  & $robocopy (Split-Path $srcFile) $destDir $leaf /R:3 /W:10 /J /NFL /NDL /NJH /NJS /NP | Out-Null
  if($LASTEXITCODE -ge 8){ throw "upload failed ($leaf) rc=$LASTEXITCODE" }
  $lh=(Get-FileHash -LiteralPath $srcFile -Algorithm SHA256).Hash
  $rh=(Get-FileHash -LiteralPath (Join-Path $destDir $leaf) -Algorithm SHA256).Hash
  if($lh -ne $rh){ throw "upload hash mismatch ($leaf)" }
  return (Join-Path $destDir $leaf)
}
# SECURITY CONTROL (2026-07-26) -- line-injection defence for untrusted file content.
# tools-manifest.json is USER-WRITABLE (<TOOLS_DIR> carries Authenticated Users:(I)(M)) and
# its values are interpolated into RECOVERY.md, which a human FOLLOWS during a restore. Without
# this, a CR/LF in any string field adds arbitrary LINES to that document -- see the STANDING RULE
# corollary at the top of this file for the full reasoning and the PoC.
# APPLIED AT EACH DISPLAY SITE, not at ingestion. The $tools object that Write-Recovery parses
# (Get-Content -Raw | ConvertFrom-Json) is stored RAW and is never cleaned; every render site calls
# Clean-ManifestText on its own values inline. An earlier version of this comment claimed the
# opposite -- ingestion-time cleaning, "which cannot be forgotten" -- corrected 2026-07-27 after a
# adversarial review review, having asserted a property the code does not have. (Deliberately no line numbers
# here: the stale-citation habit is the same rot as the stale claim. Grep Clean-ManifestText.)
#
# OBLIGATION, because the structure does NOT enforce it: every value read from the manifest -- or
# from any other user-writable source rendered into RECOVERY.md -- MUST be passed through
# Clean-ManifestText AT ITS USE SITE. Adding a field to the manifest and interpolating it raw
# reintroduces the vector silently. Two residuals found exactly this way on 2026-07-27 -- the
# Clairvoyance app-version pair, and $tmPath in the MANIFEST-MISSING branch -- are the proof that
# "remembered by every future caller" is not a property this file has.
#
# If you ever DO move this to ingestion-time cleaning, delete this obligation paragraph with it.
function Clean-ManifestText($v){
  if($null -eq $v){ return '' }
  $s = [string]$v
  $s = $s -replace '[\r\n]+',' '                # THE vector: no value may introduce a line break
  $s = $s -replace '[\x00-\x1f\x7f]',''         # other control chars (NUL/ESC/backspace/etc.)
  if($s.Length -gt 300){ $s = $s.Substring(0,300) + '...[truncated]' }   # cap flooding/obscuring
  return $s
}
# Highest tools-manifest schemaVersion this renderer understands. Bump ONLY together with the
# per-tool render below -- the whole point of the guard is that the number and the renderer move
# as one. v2 added route/routeStatus/coupling; v1 had none of them.
$KnownToolsManifestSchema = 2
function Write-Recovery($file){
  $L=New-Object System.Collections.Generic.List[string]
  $L.Add("# Clairvoyance - Bare-Metal Recovery Plan"); $L.Add("Instance: $instName | stamp: $stamp | Generated: $($now.ToString('u'))")
  # Both values originate in Get-ClairvoyanceVersion (:102), which reads FileVersion/ProductVersion
  # off Clairvoyance.exe -- and that exe carries Authenticated Users:(I)(M) inherited from the E:\
  # root ACE (measured 2026-07-27). A user-writable value read by a SYSTEM process is NOT a trusted
  # source; clean it. Non-gating only because the injection is strictly dominated -- anyone who can
  # rewrite the version resource can replace the executable outright.
  $L.Add("Clairvoyance app version at backup: $(Clean-ManifestText $script:appVersion) (source: $(Clean-ManifestText $script:appVersionSource)). CAUTION: restoring onto a DIFFERENT Clairvoyance version risks data/schema incompatibility -- restore.ps1 warns on mismatch (see version-check stage).")
  $L.Add("")
  $L.Add("## Archives"); $L.Add("- backup_${stamp}_main.7z - plaintext, all non-secret files; see MANIFEST.json."); $L.Add("- backup_${stamp}_secrets.7z - AES-256 (credentials + any encrypt-elected workspaces); full inventory in MANIFEST.full.json inside it; passphrase = credential '$($cfg.secretsCredentialName)' (password manager).")
  # CONSISTENCY, not a defect fix (approved 2026-07-27): these three come from config.json, which is
  # ACL-hardened (no Authenticated Users ACE, measured), so there is no live injection path here --
  # unlike the tools manifest. Wrapped anyway because the codebase was cleaning ONE config-sourced
  # value ($tmPath, in the MANIFEST-MISSING branch) while interpolating three others raw on identical
  # reasoning. That inconsistency is ambiguity a future reviewer pays for on every pass.
  # $s.encrypt is deliberately NOT wrapped: it is a boolean selecting between two LITERALS, so the
  # rendered text is CONSTRUCTED here, never taken from the file. Constructing beats sanitising --
  # do not "fix" it by wrapping the literals.
  $L.Add(""); $L.Add("## Source -> restore target"); foreach($s in $script:effectiveSources){ $L.Add("- [$(Clean-ManifestText $s.category)] $(Clean-ManifestText $s.name) ($(if($s.encrypt){'ENCRYPTED'}else{'plain'})) -> $(Clean-ManifestText $s.path)") }
  $L.Add(""); $L.Add("## Rebuild: 1.Reinstall Clairvoyance 2.restore.ps1 -Mode InPlace (main) 3.decrypt _secrets.7z 4.re-add workspaces 5.RE-AUTH OAuth tools 6.reconstitute deps (rclone/SMB/local-AI; whisper via setup-whisper.ps1) 7.recreate the SYSTEM backup task (03:00).")
  $L.Add(""); $L.Add("## Environment snapshot")
  # 2026-07-26: these two lines used to be `& rclone listremotes` and `& ollama list` -- BARE,
  # PATH-RESOLVED invocations executing as SYSTEM. See the STANDING RULE at the top of this file.
  # They were also silently useless: rclone and ollama live only on the maintainer's USER path, which
  # SYSTEM cannot see, so both calls hit their catch and EVERY archive ever produced recorded
  # "(n/a)" for both. Removing the PATH resolution and reading the manifest fixes the security
  # exposure and the dead content in one move, and works regardless of what PATH is set to.
  $tmPath = '<TOOLS_DIR>\tools-manifest.json'
  if($cfg.toolsManifest){ $tmPath = $cfg.toolsManifest }
  $tools = $null
  if(Test-Path -LiteralPath $tmPath){ try { $tools = Get-Content -Raw -LiteralPath $tmPath | ConvertFrom-Json } catch { $tools = $null } }
  if($tools -and $tools.tools){
    # ---- tools-manifest schemaVersion guard (2026-07-27; maintainer-ruled) ----
    # WARN AND DEGRADE, NEVER FAIL. A backup that refuses to run because a documentation section
    # evolved is a self-inflicted outage. Fail-closed belongs where the failure mode is silent data
    # loss -- NOT where it is a stale paragraph in a text file. Do not "harmonize" this with the
    # fail-closed posture used for secrets/overage; the asymmetry is deliberate.
    #
    # Guard BOTH directions, because the two failures look different in the OUTPUT:
    #   newer (v3+) : contains fields we do not know about -> render what we understand + banner.
    #   OLDER (v1)  : the case that actually bites, and it is REACHABLE -- restore any archive from
    #                 before 2026-07-27 and you get a v1 manifest with NO `route` KEY AT ALL. A v2
    #                 renderer would then print "INVOKE: (none)" for every tool: not a degraded
    #                 render but N FALSE STATEMENTS, each indistinguishable from yt-dlp's genuine
    #                 route:null.
    # Hence the load-bearing rule in the per-tool loop: a MISSING `route` FIELD is NOT a NULL
    # `route` VALUE. $t.route yields $null for both, so presence is tested on PSObject.Properties.
    # schemaVersion itself comes from a USER-WRITABLE file, so it is parsed defensively -- a
    # non-numeric value must warn, not throw.
    $tmSchema = if($tools.PSObject.Properties.Name -contains 'schemaVersion'){ $tools.schemaVersion } else { $null }
    $tmSchemaNum = $null
    if($null -ne $tmSchema){ $p = 0; if([int]::TryParse("$tmSchema", [ref]$p)){ $tmSchemaNum = $p } }
    $tmNote = $null
    if($null -eq $tmSchema){
      $tmNote = "manifest carries NO schemaVersion (predates stamping) -- fields below are best-effort; absent fields are reported as unknown, never as absent values"
    } elseif($null -eq $tmSchemaNum){
      $tmNote = "manifest schemaVersion '$(Clean-ManifestText $tmSchema)' is not a number -- treating as unknown; fields below are best-effort"
    } elseif($tmSchemaNum -lt $KnownToolsManifestSchema){
      $tmNote = "manifest schemaVersion $tmSchemaNum is OLDER than this backup understands (v$KnownToolsManifestSchema) -- fields added after v$tmSchemaNum are absent from the file and are reported as 'unknown', NOT as 'none'"
    } elseif($tmSchemaNum -gt $KnownToolsManifestSchema){
      $tmNote = "manifest schemaVersion $tmSchemaNum is NEWER than this backup understands (v$KnownToolsManifestSchema) -- any field added after v$KnownToolsManifestSchema is NOT rendered below; read the manifest directly before trusting this section"
    }
    if($tmNote){
      $L.Add("- !! TOOLS MANIFEST SCHEMA: $tmNote")
      # Write-Recovery is called twice per run (archive copy + _Restore copy); log the stage once.
      if(-not $script:tmSchemaWarned){ Log "tools-manifest" "WARN" $tmNote; $script:tmSchemaWarned = $true }
    }
    $L.Add("- external tools: $(@($tools.tools).Count) recorded in $(Clean-ManifestText $tmPath) (generated $(Clean-ManifestText $tools.generatedAt), schemaVersion $(if($null -ne $tmSchema){ Clean-ManifestText $tmSchema } else { 'absent' }))")
    foreach($t in @($tools.tools | Where-Object { $_.present })){
      $nm = Clean-ManifestText $t.name; $vr = Clean-ManifestText $t.version; $pa = Clean-ManifestText $t.path
      $pin = if($t.pinned){ "  [PINNED $(Clean-ManifestText $t.pinnedVersion) -- $(Clean-ManifestText $t.pinnedBy)]" } else { "" }
      # `route` is WHAT TO INVOKE; `path` is only WHERE THE BYTES ARE. Rendering path as the answer
      # to "what do I run" is what sent restorers at a vendored duplicate marked do-not-invoke and
      # at a borrowed cross-Workspace path. Both are still printed -- path is legitimately useful
      # for DR/hashes -- but only one of them is labelled as the invocation.
      # MISSING field vs NULL value: see the schema guard above. Do NOT collapse these two.
      $inv = if(-not ($t.PSObject.Properties.Name -contains 'route')){ 'unknown (manifest predates the route field; resolve by bare name and verify)' }
             elseif($null -eq $t.route -or "$($t.route)".Trim() -eq ''){ '(none -- see coupling)' }
             else { Clean-ManifestText $t.route }
      $rs = if($t.PSObject.Properties.Name -contains 'routeStatus'){ "  [" + (Clean-ManifestText $t.routeStatus) + "]" } else { "" }
      $L.Add("  - ${nm} ${vr}  |  INVOKE: ${inv}${rs}")
      $L.Add("      bytes (inventory, NOT a route): $pa$pin")
      # Coupling: the ACTIONABLE field is named per type -- `recovery` on a c14-exception,
      # `remediation` on a c14-violation. Resolve it, never hardcode one name: reading only
      # `recovery` renders nothing for rclone, the flagged violation we most want a warning on.
      # If neither exists, say so EXPLICITLY -- an absent instruction must be visible as absent,
      # never a silently dropped row. Restore-time only: whyViolation/completionTest/owner/
      # consumers/lender are remediation-tracking for a WORKING machine, not a dead one.
      $c = $t.coupling
      if($c){
        $act = if($c.recovery){ $c.recovery } elseif($c.remediation){ $c.remediation } else { $null }
        $actTxt = if($act){ Clean-ManifestText $act } else { '(no recovery instruction recorded -- see the manifest coupling entry)' }
        $L.Add("      COUPLING [$(Clean-ManifestText $c.type)]: $actTxt")
      }
    }
    if(@($tools.pinDriftWarnings).Count){ $L.Add("  - PIN DRIFT: $((@($tools.pinDriftWarnings) | ForEach-Object { Clean-ManifestText $_ }) -join '; ')") }
  } else {
    # Same $tmPath is already cleaned in the manifest-present branch above. Source is
    # $cfg.toolsManifest and config.json is
    # ACL-hardened (no Authenticated Users ACE, verified 2026-07-27), so this is non-gating on the
    # merits -- but this is the branch a human is most likely to be READING during a restore.
    $L.Add("- external tools: MANIFEST MISSING at $(Clean-ManifestText $tmPath) -- run <TOOLS_DIR>\generate-tools-manifest.ps1 (in USER context) to restore this section.")
  }
  ($L -join "`r`n") | Set-Content -LiteralPath $file -Encoding UTF8
}

$artIndexPath = Join-Path $mirror ".artifacts-index.json"
function Build-Artifacts($weeklyProduced){
  if(-not $weeklyProduced){ return }
  if(-not $script:wsArtifactMap -or @($script:wsArtifactMap).Count -eq 0){ Log "artifacts" "SKIP" "none configured"; return }
  $idx=@{}; if(Test-Path -LiteralPath $artIndexPath){ try { $o=Get-Content -Raw -LiteralPath $artIndexPath|ConvertFrom-Json; foreach($p in $o.PSObject.Properties){ $idx[$p.Name]=$p.Value } } catch {} }
  $artStage = Join-Path $arcTmp "art"; $man=@(); $new=0
  foreach($m in $script:wsArtifactMap){ foreach($dn in $m.dirs){ foreach($d in (Get-ChildItem -LiteralPath $m.path -Recurse -Directory -Filter $dn -ErrorAction SilentlyContinue)){ foreach($f in (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue)){
    $rel = "$($m.name)\" + $f.FullName.Substring($m.path.Length).TrimStart('\'); $sig="$($f.Length):$($f.LastWriteTimeUtc.Ticks)"
    if($idx[$rel] -eq $sig){ continue }
    # F19: third sibling path -- Build-Artifacts walks LIVE workspace dirs and hashes per file, so it
    # carries the same abort risk. Hash BEFORE copying: if we cannot hash it we do not stage it, which
    # keeps the artifact stage dir and its MANIFEST.json describing the same set of bytes.
    $sha = Try-Hash $f.FullName $null $m.name $false
    if($null -eq $sha){ continue }
    $dst = Join-Path $artStage $rel; New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null; Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    $man += [pscustomobject]@{ rel=$rel; sha256=$sha; bytes=$f.Length; source=$m.name; category="artifact"; target=$f.FullName }; $idx[$rel]=$sig; $new++
  } } } }
  if($new -eq 0){ Log "artifacts" "SKIP" "no new/changed artifact files"; return }
  ($man | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $artStage "MANIFEST.json") -Encoding UTF8
  $artArc = Join-Path $arcTmp ("backup_"+$stamp+"_artifacts.7z")
  Push-Location $artStage; try { if((SevenZip a -t7z -mx=1 -mmt=on -bso0 -bsp0 $artArc '*') -ne 0){ throw "artifacts compress failed" } } finally { Pop-Location }
  if((SevenZip t -bso0 -bsp0 $artArc) -ne 0){ throw "artifacts test FAILED" }
  Upload-Verify $artArc (Join-Path $instanceRoot "Artifacts") | Out-Null
  ($idx | ConvertTo-Json -Depth 3 -Compress) | Set-Content -LiteralPath $artIndexPath -Encoding UTF8
  Log "artifacts" "PASS" "$new new file(s) archived incrementally + verified"
}

$result = [ordered]@{ ok=$true; stamp=$stamp; tiers=@(); substitutions=@(); withheld=@(); reportingOk=$true }   # F15/F16: 'withheld' and 'reportingOk' always present so last-run.json keeps a stable shape for readers (health check, monitor)
$arcTmp = Join-Path $cfg.tempDir ("cvarc_"+$stamp)     # F10: temp inside the locked dir
$secTmp = Join-Path $arcTmp "sec"
try {
  Log "start" "INFO" "mode=$Mode instance=$instName stamp=$stamp mirror=$mirror"
  New-Item -ItemType Directory -Force -Path $mirror,$instanceRoot,$cfg.tempDir | Out-Null
  Set-BackupLease "start"   # F11b: orchestrators self-gate on this. Lease, not marker -- see Set-BackupLease.
  Get-ChildItem -LiteralPath $cfg.tempDir -Directory -Filter "cvarc_*" -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue  # F10: sweep stale
  Load-Cache
  $state = if(Test-Path -LiteralPath $statePath){ Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json } else { [pscustomobject]@{ lastSuccess=$null; lastWeekly=$null; lastMonthly=$null; lastAnnual=$null; lastFullRehash=$null } }
  if(-not ($state.PSObject.Properties.Name -contains 'lastFullRehash')){ $state | Add-Member NoteProperty lastFullRehash $null -Force }
  # THIS 28 IS ALSO A SECURITY PARAMETER, NOT ONLY AN INTEGRITY ONE.
  # Scan-Secrets (F20) treats doRehash as its full-rescan trigger, so this interval is the hard
  # ceiling on how long a file can go unread by the secret scanner. Lengthening it for hashing-cost
  # reasons lengthens the scanner's blind window by the same amount, silently.
  $script:doRehash = [bool]$ForceRehash -or (-not $state.lastFullRehash) -or (([datetime]$state.lastFullRehash) -lt $now.AddDays(-28))
  if($script:doRehash){ Log "rehash" "INFO" "FULL re-hash this run (monthly integrity pass)" }
  if(-not $SkipSecrets){ Get-Passphrase | Out-Null }   # F3: fetch + clear env BEFORE any child process spawns

  # 1. mirror (delta, secrets excluded) + manifest
  New-Item -ItemType Directory -Force -Path $arcTmp | Out-Null
  $mainMan=@()
  foreach($src in $script:effectiveSources){
    # 2026-08-15: the mirror phase previously had NO Assert-Window call at all -- the three that existed
    # (secrets/compress/upload) all sit AFTER this loop. So an overrun inside the longest phase of the run
    # could never reach the clean 03:45 gate and could only ever end as a hard kill: no finally, no
    # last-run.json, and the PREVIOUS night's ok=true left standing, which reads as success.
    # HONEST LIMIT, stated so nobody mistakes this for more than it is: this is checked BETWEEN sources,
    # so it would NOT have caught 2026-08-15, where a SINGLE robocopy ran 54 minutes without returning.
    # Bounding one hung child process needs a watchdog on the process itself; that is a separate change
    # and is deliberately not bundled into this fix. What this does buy is the multi-source overrun --
    # 14 sources that are each individually reasonable but collectively past the window.
    Assert-Window "mirror:$($src.name)"
    if($src.encrypt){ Log "copy+verify" "PASS" "$($src.name) (encrypt-elected -> secrets)"; continue }   # F6a: not mirrored, goes to secrets
    # optional=true sources may legitimately disappear (e.g. the legacy C: base once the split is closed).
    # Skip-with-WARN instead of aborting. Sources WITHOUT the flag keep failing loud: if E:\...\UserData
    # vanishes, robocopy rc>=8 throws, and that MUST stay an abort, not a warning. (optional-source 2026-07-25)
    if($src.optional -and -not (Test-Path -LiteralPath $src.path)){ Log "copy+verify" "WARN" "$($src.name): optional source absent, skipped ($($src.path))"; continue }
    $dst = Mirror-Source $src
    if($Mode -ne "DryRun"){ $mainMan += @(Manifest-Source $src $dst) }
    Log "copy+verify" "PASS" "$($src.name)"
  }
  if($Mode -eq "DryRun"){ Log "dryrun" "PASS" "mirrored (delta) $($script:effectiveSources.Count) sources"; $result.ok=$true; return }
  Assert-Window "secrets"

  # 2. gather secrets from LIVE sources (F4); F7 scan gate on main
  $secEntries = if(-not $SkipSecrets){ Get-SecretFilesLive } else { @() }   # NO @() wrap -- Get-SecretFilesLive returns a comma-guarded array (',@($out)'); wrapping re-nests it (same trap as the line-236 manifest-nest-fix). Comma-guarded return => assign directly. (manifest-nest-fix 2026-07-23)
  # 2a. POST-CONDITION (secrets-zero 2026-07-28): secret=0 is only legitimate when nothing COULD have
  # matched. If secretsSet is non-empty AND at least one live source path exists, zero secret files is
  # not "nothing to protect" -- it is a gatherer that has stopped matching, and no pre-condition can
  # see it because every pre-condition still passes on its own terms. The 07-26 and 07-27 nights each
  # reported ok=true, exit 0, every stage PASS, having archived ZERO credentials: Get-IncludeGlobs
  # returned an unrolled $null, so Test-Included rejected every candidate file. Assert on the RESULT.
  # Loud but non-fatal, same contract as protected-paths below: the main archive is still worth
  # keeping and uploading; we simply refuse to call the run healthy. (powershell-empty-return-unrolls-to-null)
  # Status flips in place rather than adding a stage, so the "main=N secret=N" prefix any consumer
  # already parses stays byte-identical.
  $secZeroBad = $false
  if((-not $SkipSecrets) -and $secEntries.Count -eq 0 -and @($cfg.secretsSet).Count -gt 0){
    $liveSrc = @($script:effectiveSources | Where-Object { Test-Path -LiteralPath $_.path })
    if($liveSrc.Count){ $secZeroBad = $true }
  }
  if($secZeroBad){
    $result.ok=$false
    Log "secrets-split" "FAIL" ("main=$($mainMan.Count) secret=0 -- POST-CONDITION FAILED: secretsSet has $(@($cfg.secretsSet).Count) pattern(s) and $($liveSrc.Count) live source(s) exist (" + ((@($liveSrc) | ForEach-Object { $_.name }) -join ', ') + ") yet NOTHING matched. No credentials are in this archive; a restore from it will NOT recover auth material. Check Get-IncludeGlobs/Test-Included and config.secretsSet.")
  } else {
    Log "secrets-split" "PASS" "main=$($mainMan.Count) secret=$($secEntries.Count)"
  }
  $mainMan = Scan-Secrets $mainMan      # B2: may scrub (hash updated in place) or drop unscrubbable files. NOTE: NO @() wrap -- Scan-Secrets already returns a comma-guarded array (',@($out)'); wrapping in @() re-nests it into a single-element array, which collapses $mainMan.Count to 1, breaks the protected-paths assertion (covRel loses every real path -> false MISSING), and serializes MANIFEST.json as {value:[...],Count:N} instead of a bare array. (manifest-nest-fix 2026-07-23)
  $allManifest = @($mainMan) + @($secEntries | Select-Object rel,sha256,bytes,source,category,target)   # rebuild AFTER scrub so manifests match archived bytes

  # 2b. Staff-continuity coverage assertion (F14): staff.json / personas / .Clairvoyance memory must be in the archive.
  # Loud (ok=false + FAIL stage) but non-fatal: never skip a night's backup over a coverage miss.
  if($cfg.protectedPaths){
    $covRel=@($allManifest | ForEach-Object { (($_.source + '/' + $_.rel) -replace '\\','/') })
    $missing=@(); foreach($g in $cfg.protectedPaths){ if(-not(@($covRel) -like $g)){ $missing+=$g } }   # -like: case-insensitive wildcard, no regex escaping
    $staffSrcs=@($allManifest | Where-Object { (($_.source + '/' + $_.rel) -replace '\\','/') -like '*/.clairvoyance/staff/*' } | Select-Object -ExpandProperty source -Unique)
    if($missing.Count){ $result.ok=$false; Log "protected-paths" "FAIL" ("MISSING from archive: "+($missing -join '; ')+" -- Staff identity/memory may not be recoverable; check config excludes and workspacesRoot") }
    else { Log "protected-paths" "PASS" ("all protected paths present; per-workspace staff memory from: "+(@($staffSrcs) -join ', ')) }
  Assert-StaffMemoryCoverage   # F17: must run BEFORE the tier guard, which reads $result.ok
  }
  Assert-Window "compress"

  # 3. meta (F8: full inventory -> secrets archive only)
  # Resolve the Clairvoyance app version BEFORE Write-Recovery (both this archive copy and the
  # _Restore copy consume $script:appVersion). Never fatal -- "unknown" + WARN, never an abort.
  $cv = Get-ClairvoyanceVersion; $script:appVersion = $cv.version; $script:appVersionSource = $cv.source
  if($script:appVersion -eq "unknown"){ Log "app-version" "WARN" "could not resolve Clairvoyance app version ($($script:appVersionSource)); archive stamped 'unknown'" }
  else { Log "app-version" "PASS" "Clairvoyance $($script:appVersion) ($($script:appVersionSource))" }
  # BACKUP-META.json: app-version stamp for restore-time mismatch check. SEPARATE file --
  # NOT folded into MANIFEST.json (must stay a bare array; see manifest-nest-fix 2026-07-23),
  # and distinct from .backup-install.json (which carries the backup-TOOL version, not the app).
  $meta = [ordered]@{
    schemaVersion     = 1
    appVersion        = $script:appVersion
    appVersionSource  = $script:appVersionSource
    backupToolVersion = (Get-BackupToolVersion)
    instance          = $instName
    stamp             = $stamp
    takenAtUtc        = $now.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  }
  ($meta | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Join-Path $arcTmp "BACKUP-META.json") -Encoding UTF8
  Write-Recovery (Join-Path $arcTmp "RECOVERY.md")
  ($mainMan | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $arcTmp "MANIFEST.json") -Encoding UTF8

  # 4. compress main from mirror (already secret-free) + append meta
  $mainArc = Join-Path $arcTmp ("backup_"+$stamp+"_main.7z")
  $secArc  = Join-Path $arcTmp ("backup_"+$stamp+"_secrets.7z")
  Push-Location $mirror; try { if((SevenZip a -t7z -mx=5 -mmt=on -bso0 -bsp0 $mainArc '*') -ne 0){ throw "7z main compress failed" } } finally { Pop-Location }
  Push-Location $arcTmp; try { if((SevenZip a -bso0 -bsp0 $mainArc "MANIFEST.json" "RECOVERY.md" "BACKUP-META.json") -ne 0){ throw "7z main meta add failed" } } finally { Pop-Location }
  Log "compress" "PASS" "main -> $(Split-Path $mainArc -Leaf)"

  $hasSecrets = (-not $SkipSecrets) -and $secEntries.Count
  if($hasSecrets){
    $pass = Get-Passphrase; if(-not $pass){ throw "no passphrase (DPAPI file or env)" }
    New-Item -ItemType Directory -Force -Path $secTmp | Out-Null
    foreach($e in $secEntries){ $d=Join-Path (Join-Path $secTmp $e.source) $e.rel; New-Item -ItemType Directory -Force -Path (Split-Path $d)|Out-Null; Copy-Item -LiteralPath $e.full -Destination $d -Force }
    ($secEntries | Select-Object rel,sha256,bytes,source,category,target | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $secTmp "MANIFEST.secrets.json") -Encoding UTF8
    ($allManifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $secTmp "MANIFEST.full.json") -Encoding UTF8   # F8
    Push-Location $secTmp; try { if((SevenZipPw $pass @('a','-t7z','-mx=5','-mhe=on','-p','-bso0','-bsp0',$secArc,'*')) -ne 0){ throw "7z secrets compress failed" } } finally { Pop-Location }
    Log "compress" "PASS" "secrets -> $(Split-Path $secArc -Leaf) (AES-256, stdin pw)"
  } elseif($SkipSecrets){ Log "compress" "SKIP" "secrets skipped (validation)" }
  $arcs = if($hasSecrets){ @($mainArc,$secArc) } else { @($mainArc) }

  # 5. integrity test
  if((SevenZip t -bso0 -bsp0 $mainArc) -ne 0){ throw "7z test main FAILED" }
  # NOTE (F3/B4 residual, deliberate): NO 7-Zip read mode (t/x/e/l) accepts the password from stdin
  # or a redirected file -- only 'a' (compress) does (verified empirically 2026-07-21). This self-test
  # runs unattended as SYSTEM with no console, so an interactive prompt is impossible too. Inline -p is
  # therefore the only way to verify the encrypted archive here; keeping the test (vs. dropping it) was
  # chosen over eliminating the ~1s exposure, which is readable only by SYSTEM/admin on a box that
  # already runs this task as SYSTEM. Compress above is stdin-safe; env is cleared; log is redacted.
  # (restore.ps1 has no console constraint, so it prompts interactively -- no cmdline exposure there.)
  if($hasSecrets){ if((SevenZip t ("-p"+$pass) -bso0 -bsp0 $secArc) -ne 0){ throw "7z test secrets FAILED" } }
  Log "compress-test" "PASS" ("verified " + (($arcs|ForEach-Object{Split-Path $_ -Leaf}) -join ', '))
  Assert-Window "upload"

  # 6. upload to Daily (hash-verified)
  $daily = Join-Path $instanceRoot "Daily"; $dailyArcs=@(); foreach($a in $arcs){ $dailyArcs += (Upload-Verify $a $daily) }
  $result.tiers += "Daily"; Log "upload" "PASS" "Daily <- $($arcs.Count) archive(s), hash-verified on share"

  # 6b. keep the destination SELF-CONTAINED for bare-metal recovery: copy the tooling into _Restore (NEVER the sealed key)
  $restoreDir = Join-Path $instanceRoot "_Restore"
  & $robocopy $toolDir $restoreDir "backup.ps1" "restore.ps1" "evaluate-workspaces.ps1" "config.json" /R:3 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
  if($LASTEXITCODE -lt 8){ Write-Recovery (Join-Path $restoreDir "RECOVERY.md"); Log "restore-tooling" "PASS" "_Restore refreshed (scripts+config+RECOVERY.md; .secretkey excluded)" } else { Log "restore-tooling" "WARN" "could not refresh _Restore (rc=$LASTEXITCODE)" }

  # 7. deep-verify from the SHARE main archive
  $n=[int]$cfg.deepVerifySample; if($n -gt 0 -and $mainMan.Count){
    $sample=@($mainMan | Get-Random -Count ([Math]::Min($n,$mainMan.Count))); $vTmp=Join-Path $arcTmp "verify"; New-Item -ItemType Directory -Force -Path $vTmp|Out-Null
    $shareMain=Join-Path $daily (Split-Path $mainArc -Leaf); $bad=0
    foreach($e in $sample){ $inner="$($e.source)\$($e.rel)"; & $seven e -bso0 -bsp0 "-o$vTmp" $shareMain $inner -y | Out-Null; $xf=Join-Path $vTmp (Split-Path $inner -Leaf); if((Test-Path $xf) -and (Get-FileHash -LiteralPath $xf -Algorithm SHA256).Hash -eq $e.sha256){} else { $bad++ } }
    if($bad -gt 0){ throw "deep-verify FAILED ($bad/$($sample.Count))" }
    Log "deep-verify" "PASS" "$($sample.Count) file(s) from share hash-matched"
  }

  # 8. tiering + substitution (share-side copies)
  $tiers=@(@{name="Weekly";boundary=(Last-DowOnOrBefore $now $cfg.lastDayOfWeek);last=$state.lastWeekly},@{name="Monthly";boundary=(MonthEndOnOrBefore $now);last=$state.lastMonthly},@{name="Annual";boundary=(YearEndOnOrBefore $now);last=$state.lastAnnual})
  # F15 PROMOTION GUARD (the maintainer's decision 2026-08-01). A DEGRADED run (ok=false) is still uploaded to
  # Daily at step 6 -- you never lose the night's backup -- but it must NOT be promoted into a
  # long-retention tier. Daily rolls off in 7 days; retention.annual is -1, i.e. FOREVER, so a degraded
  # archive promoted to Annual becomes a permanent artifact that reads as a good backup. The four
  # non-fatal ok=false sites (mirror-prune, secret-scrub, secrets-split, protected-paths) all execute
  # BEFORE this step, so $result.ok is settled by the time we get here; anything that throws never
  # reaches step 8 at all.
  # DELIBERATELY does not touch $state. Leaving lastWeekly/lastMonthly/lastAnnual unadvanced means the
  # next HEALTHY run still sees the boundary as unmet and emits a SUBSTITUTE for it through the existing
  # machinery below. Advancing state here would be the actual bug -- it would consume the boundary with
  # nothing archived against it.
  # ACCURACY CORRECTION (adversarial review, 2026-08-01): withholding defers promotion for the MOST RECENT boundary
  # only. It does NOT guarantee every boundary gets a copy. Last-DowOnOrBefore/MonthEndOnOrBefore return
  # the LATEST boundary at or before $now, so if degradation spans two or more boundaries, the earlier
  # ones are skipped outright -- the recovering run substitutes for the newest one and the intermediate
  # periods end up with no copy at all. That is still preferable to promoting a degraded archive, but do
  # not read this guard as "no tier is ever missed". Sustained degradation DOES cost retained periods,
  # which is a reason to treat a WITHHELD stage as urgent rather than informational.
  $degraded = -not $result.ok
  if($degraded){
    $due=@(); foreach($t in $tiers){ if(-not($t.last -and ([datetime]$t.last).Date -ge $t.boundary)){ $due+=$t.name } }
    if($due.Count){ $result.withheld = $due; Log "tier" "WITHHELD" ("DEGRADED run (ok=false): promotion withheld for "+($due -join ', ')+" -- Daily copy retained, tier state NOT advanced, so the next healthy run will SUBSTITUTE for these boundaries") }
    else{ Log "tier" "INFO" "DEGRADED run (ok=false): no tier boundary was due, nothing to withhold" }
  }
  foreach($t in $tiers){ if($degraded -or ($t.last -and ([datetime]$t.last).Date -ge $t.boundary)){ continue }
    $dir=Join-Path $instanceRoot $t.name; New-Item -ItemType Directory -Force -Path $dir|Out-Null; $isSub=$now.Date -ne $t.boundary
    foreach($da in $dailyArcs){ $leaf=Split-Path $da -Leaf; if($isSub){ $leaf=$leaf -replace '\.7z$',("__SUBSTITUTE-for-$($t.name)-"+$t.boundary.ToString("yyyy-MM-dd")+".7z") }; Copy-Item -LiteralPath $da -Destination (Join-Path $dir $leaf) -Force }
    if($isSub){ "Expected $($t.name) backup for period ending $($t.boundary.ToString('yyyy-MM-dd')) was not produced. This archive ($($now.ToString('yyyy-MM-dd HH:mm'))) substitutes it; contents reflect creation-time state." | Set-Content -LiteralPath (Join-Path $dir ("backup_"+$stamp+"__SUBSTITUTE-for-$($t.name)-"+$t.boundary.ToString('yyyy-MM-dd')+".README.txt")) -Encoding UTF8; $result.substitutions+="$($t.name)<-$($t.boundary.ToString('yyyy-MM-dd'))"; Log "tier" "SUBSTITUTION" "$($t.name) <- $($t.boundary.ToString('yyyy-MM-dd'))" } else { Log "tier" "PASS" "$($t.name) (natural)" }
    $result.tiers += $t.name; switch($t.name){ "Weekly"{$state.lastWeekly=$now.ToString('s')} "Monthly"{$state.lastMonthly=$now.ToString('s')} "Annual"{$state.lastAnnual=$now.ToString('s')} }
  }

  # 9. incremental weekly artifacts
  Build-Artifacts ($result.tiers -contains "Weekly")

  # 9b. F19 hash-guard summary. Placed AFTER Build-Artifacts so it covers all three hashing walks
  # (mirror manifest, live secrets gather, artifacts). ALWAYS emitted, including the zero case: a
  # guard that logs nothing on a clean night cannot be distinguished from one that never ran.
  $uhAll = @($script:unhashable) + @($script:unhashableSecret)
  if($uhAll.Count -eq 0){
    Log "hash-guard" "PASS" "unhashable=0 (every enumerated file hashed into its manifest)"
  } else {
    $shown = (@($uhAll | ForEach-Object { "[$($_.source)] $($_.path)" } | Select-Object -First 5) -join '; ')
    Log "hash-guard" "WARN" ("unhashable=$($uhAll.Count) -- excluded from the manifest. These files are still PRESENT in the archive (7z reads them without error) but UNRECORDED, and if the name is a reserved device the archived copy may be ZERO BYTES. Fix the file at source: " + $shown + $(if($uhAll.Count -gt 5){" (+$($uhAll.Count-5) more)"}else{""}))
  }
  # A skipped SECRET is not a bookkeeping gap -- it is a credential absent from _secrets.7z, and a
  # restore would come up short with no other signal. Loud (ok=false) but NON-FATAL, same contract as
  # protected-paths: the archive is still worth keeping, we just refuse to call the run healthy.
  if(@($script:unhashableSecret).Count -gt 0){
    $result.ok=$false
    Log "hash-guard" "FAIL" ("$(@($script:unhashableSecret).Count) SECRET file(s) could not be hashed and are therefore NOT in _secrets.7z -- a restore from this archive will NOT recover them: " + ((@($script:unhashableSecret) | ForEach-Object { "[$($_.source)] $($_.path)" }) -join '; '))
  }

  # 10. prune (main tiers; F12: shorter secrets retention in Monthly/Annual)
  function Prune($tierName,$keep,$filter){ if($keep -lt 0){ return }; $dir=Join-Path $instanceRoot $tierName; if(-not(Test-Path $dir)){return}
    $keys = Get-ChildItem $dir -File -Filter $filter -EA SilentlyContinue | ForEach-Object { ($_.Name -split '_')[1..2] -join '_' } | Sort-Object -Unique
    foreach($k in ($keys | Sort-Object -Descending | Select-Object -Skip $keep)){ Get-ChildItem $dir -File | Where-Object { $_.Name -like "backup_$k*" -and $_.Name -like $filter } | Remove-Item -Force } }
  foreach($ti in @("Daily","Weekly","Monthly","Annual","Artifacts")){ Prune $ti $cfg.retention.$($ti.ToLower()) "backup_*" }
  if($cfg.secretsRetention){ Prune "Monthly" $cfg.secretsRetention.monthly "*_secrets*"; Prune "Annual" $cfg.secretsRetention.annual "*_secrets*" }   # F12
  Log "prune" "PASS" "retention applied"

  # 11. persist
  Save-Cache
  $state.lastSuccess=$now.ToString('s'); if($script:doRehash){ $state.lastFullRehash=$now.ToString('s') }
  $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
  Log "done" "PASS" ("tiers="+($result.tiers -join ',')+" subs="+($result.substitutions -join ','))
}
catch { $result.ok=$false; Log "ERROR" "FAIL" $_.Exception.Message; try { Save-Cache } catch {} }
finally {
  # Set the latch BEFORE the delete: any Log() later in this finally (e.g. the "temp not fully
  # removed" WARN below) must not be able to resurrect the lease. See Set-BackupLease.
  if($cfg.pauseFlag){ $script:leaseReleased = $true; Remove-Item -LiteralPath $cfg.pauseFlag -Force -EA SilentlyContinue }   # F11b: clear -> fleet may resume
  if(Test-Path -LiteralPath $arcTmp){ Remove-Item -Recurse -Force -LiteralPath $arcTmp -EA SilentlyContinue; if(Test-Path -LiteralPath $arcTmp){ Log "cleanup" "WARN" "temp not fully removed: $arcTmp" } }
  if($script:pass){ foreach($e in $script:logStages){ if($e.detail -and ("$($e.detail)").Contains($script:pass)){ $e.detail="[REDACTED]" } } }   # F13

  # ---- 12. backup log note + share mirror (F16) ----
  # Runs in FINALLY, and AFTER the F13 passphrase redaction above, so that (a) a FAILED or aborted run
  # is still recorded -- those are the entries you most want during a restore -- and (b) the note can
  # never carry the archive passphrase. Deliberately before '$result.log = $logStages' so this stage's
  # own PASS/FAIL still reaches last-run.json.
  $result.reportingOk = $true
  try {
    $noteSrc = @($cfg.sources | Where-Object { $_.name -eq 'home-appdata' })[0]
    if(-not $noteSrc){ throw "cannot locate the 'home-appdata' source in config.sources -- log note path is underivable" }
    $r = Write-BackupLogNote (Join-Path $noteSrc.path "Clairvoyance Backup Log.md") (Join-Path $instanceRoot "Logs") $result $script:logStages $stamp $now
    if($r.skipped){ Log "log-note" "PASS" "entry for $stamp already present -- local unchanged, share RE-VERIFIED: $($r.shareFile) sha256[0:12]=$($r.hash)" }
    else{ Log "log-note" "PASS" "note updated + mirrored, hash-verified on share: $($r.shareFile) sha256[0:12]=$($r.hash)" }
  } catch {
    $result.reportingOk = $false
    Log "log-note" "FAIL" ("LOG NOTE/MIRROR FAILED -- the ARCHIVE is unaffected and ok is deliberately NOT changed, but the recovery-side history is now stale and a restore would be flying blind: " + $_.Exception.Message)
  }

  $result.log = $logStages
  $json = ($result | ConvertTo-Json -Depth 6)
  if($cfg.lastRunFile){ $json | Set-Content -LiteralPath $cfg.lastRunFile -Encoding UTF8 -EA SilentlyContinue }   # F11b: Archivist reads this to report
  $json
}
```

## restore.ps1

*Restore, verify and single-file extract. -Mode InPlace is whole-archive and overwrites live locations; -Mode Extract is the single-file path.*

```powershell
<#
  Clairvoyance Restore  (companion to backup.ps1)  -- security-hardened
    -Mode Verify   : extract to temp, hash every file vs MANIFEST (NO writes) [default]
    -Mode Extract  : extract the archive to -Dest (NO placement)
    -Mode InPlace  : restore each file to its MANIFEST target, VALIDATED against allowed roots (requires -Force)
  F2: InPlace targets are validated against the real config's source roots (NOT the manifest);
      UNC/device/traversal paths are rejected. Provide -ConfigPath or -AllowRoot for InPlace.
  A2: a config source declaring includeFiles is FILE-SCOPED here exactly as it is in backup.ps1 --
      top-level files matching a basename glob, NOT the whole root. Without this an allowlisted
      source rooted at a shared directory authorized InPlace writes to every file beside it.
  F3/B4: with no -Pass/env, 7-Zip prompts for the passphrase interactively (bare -p) so it never
      touches the process command line or shell history. env RESTORE_SECRETS_PASS / -Pass remain for
      scripted validation and are passed inline (explicit opt-in; 7z x/t cannot read a pw from stdin).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Archive,
  [ValidateSet("Verify","Extract","InPlace")][string]$Mode = "Verify",
  [string]$Dest = "",
  [string]$Pass = "",
  [string]$ConfigPath = "<TOOL_DIR>\config.json",
  [string]$AllowRoot = "",
  [string]$SevenZip = "C:\Program Files\7-Zip\7z.exe",
  [string]$ClairvoyanceExePath = "",
  [switch]$RequireVersionMatch,
  [switch]$AllowUnknownVersion,
  [switch]$Force
)
$ErrorActionPreference = "Stop"
function Say($s,$d){ Write-Host ("[{0}] {1} {2}" -f (Get-Date).ToString("HH:mm:ss"),$s,$d) }
if(-not $Pass -and $env:RESTORE_SECRETS_PASS){ $Pass = $env:RESTORE_SECRETS_PASS }   # F3: prefer env over -Pass

# ---- Clairvoyance app-version mismatch guard (companion to backup.ps1 BACKUP-META.json) ----
# Read the CURRENTLY-INSTALLED version from the install-dir exe (base-migration-safe: the
# install path is independent of the C:/E: userData base). -ClairvoyanceExePath overrides;
# else config.clairvoyanceExePath; else the default install path.
function Get-InstalledCVVersion {
  $exe = $ClairvoyanceExePath
  if(-not $exe -and $ConfigPath -and (Test-Path -LiteralPath $ConfigPath)){ try { $c=Get-Content -Raw -LiteralPath $ConfigPath|ConvertFrom-Json; if($c.clairvoyanceExePath){ $exe=$c.clairvoyanceExePath } } catch {} }
  if(-not $exe){ $exe = "C:\Program Files\Clairvoyance\Clairvoyance.exe" }
  if(Test-Path -LiteralPath $exe){ try { $vi=(Get-Item -LiteralPath $exe).VersionInfo; if($vi.FileVersion -and $vi.FileVersion.Trim()){ return $vi.FileVersion.Trim() }; if($vi.ProductVersion -and $vi.ProductVersion.Trim()){ return $vi.ProductVersion.Trim() } } catch {} }
  return "unknown"
}
# Highest BACKUP-META schemaVersion this restore understands. Bump ONLY together with the
# writer at backup.ps1 (search 'BACKUP-META.json' -- the $meta ordered hashtable, NOT the
# lease schemaVersion in Set-BackupLease, which is a different artifact that happens to
# share the field name). A version field nobody guards on is decoration: it creates the
# appearance of forward-compatibility while providing none.
$KnownBackupMetaSchema = 1

# Granularity (the maintainer 2026-07-24): exact=match; patch diff=light WARN; minor/major diff=full WARN.
# Numeric compare so "0.79.1" vs "0.79.1.0" is a match, not a false patch-warn.
function Compare-CVVersion($archiveVer,$installedVer){
  if(-not $archiveVer -or $archiveVer -eq 'unknown' -or -not $installedVer -or $installedVer -eq 'unknown'){ return 'unknown' }
  if($archiveVer -eq $installedVer){ return 'match' }
  $a=@($archiveVer   -split '[.\-+]' | Where-Object { $_ -match '^\d+$' } | ForEach-Object {[int]$_})
  $b=@($installedVer -split '[.\-+]' | Where-Object { $_ -match '^\d+$' } | ForEach-Object {[int]$_})
  $n=[Math]::Max([Math]::Max($a.Count,$b.Count),3)
  for($i=0;$i -lt $n;$i++){
    $av= if($i -lt $a.Count){$a[$i]}else{0}; $bv= if($i -lt $b.Count){$b[$i]}else{0}
    if($av -ne $bv){ switch($i){ 0{return 'major'} 1{return 'minor'} default{return 'patch'} } }
  }
  return 'match'
}

# F2: allowed restore roots come from the LOCAL config (not the archive's manifest)
#
# A2 (2026-07-28): each entry is @{ Path=<normalized root>; Globs=@(basename globs) }. Globs empty
# means the whole subtree, which is the historical behaviour. Globs non-empty means FILE-SCOPED:
# top-level files only, basename must match one of the patterns.
# WHY: backup.ps1 honours an includeFiles ALLOWLIST (14 references); this file honoured it in ZERO
# places and derived allowedRoots from $s.path alone. So 'legacy-c-root-logs' -- allowlisted to
# crash.log/relay.log but ROOTED AT THE LEGACY C: BASE -- authorized manifest-supplied InPlace writes
# to everything beside them: auth-storage.json, claude-auth-debug.jsonl, the stale C:-naming
# encryption-context.json, the whole dead cache tree. Backup failed CLOSED on the allowlist while
# restore failed OPEN on the same config. The target path comes from the MANIFEST and is only
# VALIDATED here, so widening this check widens what a tampered archive may overwrite.
# Wildcards are honoured (-like, same operator as backup.ps1's Test-Included) so a glob-shaped
# allowlist stays restorable without regranting the subtree.
# -AllowRoot deliberately stays a plain subtree grant: it is an explicit operator decision at the
# command line, not something config drift can widen.
$allowedRoots = @()
if($Mode -eq "InPlace"){
  $raw = @()
  $cfg = $null
  $cfgErr = $null
  # A3/J5: capture the parse failure. Discarding it made a config TYPO present as
  # "no allowed roots", i.e. as a permissions problem, and with -AllowRoot supplied it presented as
  # nothing at all -- the run proceeded on AllowRoot alone and every other target landed in the
  # rejected= tally, which in a recovery reads as archive damage. Fail direction was already
  # correct; only the diagnosis was wrong, and it is wrong at 3am.
  if($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)){
    try { $cfg=Get-Content -Raw -LiteralPath $ConfigPath|ConvertFrom-Json } catch { $cfg=$null; $cfgErr=$_.Exception.Message }
  }
  # A4/J4: TRUNCATE. PowerShell 5.1's ConvertFrom-Json embeds THE ENTIRE INPUT DOCUMENT in the
  # exception message, so a failure on the real 15KB config dumped ~15KB of JSON to the console and
  # buried the one useful datum -- the offset, which sits in the prefix ("Unterminated string passed
  # in. (9023):"). J5 existed to make a typo diagnosable at 3am; a wall of JSON is not that. No
  # credential VALUES are in this file (passphraseFile is a path, secretsCredentialName is a
  # Credential Manager entry name), but it does disclose topology -- backup destination, every source
  # path -- so there is no reason to echo it either. The prefix survives the cut: MEASURED across
  # five corruption shapes, the offset marker ends at 34-37 chars, including a bad escape at offset
  # 11884 in a 14KB document. 200 is not magic -- it is ~5x the measured maximum. The two
  # "Invalid JSON primitive" shapes carry no offset at all and are short, so nothing is lost there.
  if($cfgErr -and $cfgErr.Length -gt 200){ $cfgErr = $cfgErr.Substring(0,200) + ("... [+{0} chars suppressed; re-run the parse by hand to see the document]" -f ($cfgErr.Length-200)) }
  if($cfgErr){ Say "config" "WARN could not parse '$ConfigPath': $cfgErr -- NO config-derived roots are in effect; only -AllowRoot (if supplied) will authorize anything" }
  $badSources = @()
  if($cfg){
    foreach($s in $cfg.sources){
      $g = @()
      if($s.PSObject.Properties.Name -contains 'includeFiles'){
        # TRIM BEFORE TESTING, for the reason backup.ps1's B1 guard documents: a whitespace-only
        # string is truthy in PowerShell, so Where-Object {$_} alone lets ["", "  "] through.
        $g = @($s.includeFiles | ForEach-Object { if($null -ne $_){ ([string]$_).Trim() } } | Where-Object { $_ })
        # Declared-but-degenerate contributes NOTHING and is reported below. It must never fall back
        # to a subtree grant -- that is precisely the fail-open this scoping exists to close, and it
        # would be invisible: the restore would succeed while writing outside the allowlist.
        # A3/J3: this used to throw HERE, which is before -AllowRoot is appended below, so the error
        # text told the operator to pass -AllowRoot and passing it did not help. Defer the decision
        # until the grant set is fully built, so the advertised remedy is one that actually works.
        if(-not $g.Count){ $badSources += ("'{0}' (raw count={1})" -f $s.name,@($s.includeFiles).Count); continue }
        # A4/J1: REPORT WHAT THE GLOBS ACTUALLY AUTHORIZE, by enumerating the root.
        # The globs are operator-supplied and load-bearing for AUTHORIZATION, not merely selection.
        # The previous version of this check tested a SYNTACTIC property -- is the glob literally
        # '*' or '*.*' -- as a proxy for a SEMANTIC one: does this glob authorize files nobody
        # intended. That proxy failed badly and silently. Measured at the legacy root:
        #     '*'      warns, authorizes auth-storage.json + encryption-context.json
        #     '?*'     IDENTICALLY broad, warned NOT AT ALL
        #     '*.json' authorizes BOTH credential files, warned NOT AT ALL
        # Breadth is not a property of the glob; it is a property of the glob X the directory
        # contents. So enumerate and name the files. This needs no list of dangerous patterns and
        # cannot be outflanked by the next one someone invents.
        # WARN, never refuse: backup.ps1 accepts these patterns happily for selection, and an
        # asymmetric refusal would make a config that backs up cleanly fail to restore -- a worse
        # failure than the one it prevents.
        # DEGRADED MODE: in a bare-metal DR the root may not exist yet, and enumeration is not
        # evidence of anything then. Say so plainly and fall back to the literal check rather than
        # reporting an empty match set, which would read as "authorizes nothing" -- the exact
        # false reassurance this finding was about.
        $encl = $null
        try { if(Test-Path -LiteralPath $s.path){ $encl = @(Get-ChildItem -LiteralPath $s.path -File -Force -ErrorAction Stop | Select-Object -ExpandProperty Name) } } catch { $encl = $null }
        if($null -eq $encl){
          Say "config" "WARN source '$($s.name)': cannot enumerate '$($s.path)' (absent or unreadable), so what its includeFiles authorize CANNOT be shown here -- verify the patterns by hand [$($g -join ', ')]"
          foreach($bg in $g){ if($bg -eq '*' -or $bg -eq '*.*'){ Say "config" "WARN source '$($s.name)' includeFiles contains '$bg', which authorizes EVERY top-level file under '$($s.path)'" } }
        } else {
          $hit = @($encl | Where-Object { $n=$_; @($g | Where-Object { $n -like $_ }).Count -gt 0 })
          # A5/J2+J3: NAME THE SECRETS UNCONDITIONALLY, and escalate to WARN when any are in reach.
          # A plain positional cap degrades exactly as risk rises: with '?*' matching 19 of 19, the
          # first twelve alphabetically include auth-storage.json but push encryption-context.json
          # into "and N more" -- so the broadest case hid one of the two files this exists to protect.
          # secretsSet is the right escalation signal and is already parsed and maintained here; a
          # FRACTION threshold would not be -- it cannot tell '*.log' matching 8 of 19 (fine) from
          # '*.json' matching 8 of 19 (both credentials), and 1-of-1 is 100%. That is the old
          # syntactic heuristic in numeric clothing. Entries containing / or \ describe directories
          # and cannot match a top-level basename, so they are skipped rather than mis-tested.
          $secretPats = @($cfg.secretsSet | Where-Object { $_ -and ($_ -notmatch '[\\/]') })
          $secretHit  = @($hit | Where-Object { $n=$_; @($secretPats | Where-Object { $n -like $_ }).Count -gt 0 })
          $rest       = @($hit | Where-Object { $secretHit -notcontains $_ })
          $shown      = @($secretHit) + @($rest | Select-Object -First 12)
          if($rest.Count -gt 12){ $shown += ("... and {0} more" -f ($rest.Count-12)) }
          # A5/J1 -- BLOCKING FIX. This branch used to end "it authorizes nothing today", which is a
          # claim about the DIRECTORY masquerading as a claim about the GRANT. Test-SafeTarget never
          # touches the filesystem: existence is not a precondition for authorization, and InPlace
          # CREATES the targets the manifest names. So an empty root with glob '*' authorized
          # auth-storage.json while this line said it authorized nothing -- a REGRESSION against the
          # version before it, which warned correctly. It was worst in the bare-metal DR this
          # enumeration was written to serve: root present (an earlier source or New-Item made it)
          # but not yet populated, which is precisely when someone reads this line.
          # RULE: describe the GRANT; use enumeration only as illustration, never as evidence of
          # narrowness. Never say "nothing" about a pattern that still matches anything.
          $lvl = if($secretHit.Count){ 'WARN ' } else { '' }
          if($hit.Count){ Say "config" "$($lvl)source '$($s.name)' includeFiles [$($g -join ', ')] authorizes ANY top-level file matching those patterns under '$($s.path)' for InPlace restore -- $($hit.Count) of $($encl.Count) present now: $($shown -join ', ')$(if($secretHit.Count){ " <-- $($secretHit.Count) of these are in secretsSet" })" }
          else { Say "config" "source '$($s.name)' includeFiles [$($g -join ', ')] authorizes ANY top-level file matching those patterns under '$($s.path)' -- 0 of $($encl.Count) present now, so this list is NOT evidence of narrowness" }
        }
      }
      $raw += ,@{ Path=$s.path; Globs=$g }
    }
    if($cfg.workspacesRoot){ $raw += ,@{ Path=$cfg.workspacesRoot; Globs=@() } }
  }
  if($AllowRoot){ $raw += ,@{ Path=$AllowRoot; Globs=@() } }
  # A3/J3: report degenerate sources once the full grant set is known, so the remedy named in the
  # error is one that actually works (the throw used to fire before -AllowRoot was appended).
  # A4/J3 -- WHAT THIS ACTUALLY DOES, stated as behaviour rather than as a rationale that was false:
  # any degenerate source REFUSES THE RUN UNLESS -AllowRoot IS SUPPLIED. It is not "nothing is left
  # to authorize" -- verified false, it fires with workspacesRoot and other valid sources standing.
  # Failing closed on a config that shows corruption in a security-relevant path is the intent; do
  # not re-justify it as an emptiness check, because the next reader will reason from that sentence.
  # A4/J2 -- and note the flag's SECOND meaning, which is not obvious from its name: -AllowRoot is
  # what flips refuse->warn, and NOTHING requires it to relate to the broken source. -AllowRoot
  # D:\unrelated (nonexistent, granting nothing) is enough. That is not an over-authorization -- the
  # grant set is unchanged -- but it does make the refusal circumventable by an operator who does not
  # know why it fired, which is the population it exists for. So the message says so out loud.
  if($badSources.Count){
    $msg = "source(s) {0} declare includeFiles but resolve to no usable pattern" -f ($badSources -join ', ')
    if($AllowRoot){ Say "config" "WARN $msg -- those sources authorize NOTHING; continuing on -AllowRoot plus any sources that parsed cleanly. NOTE: supplying -AllowRoot is what downgraded this from a refusal to a warning, whether or not it relates to the broken source -- fix the config rather than relying on that" }
    else { throw ("InPlace refused: {0}. Fix the config, or re-run with -AllowRoot <path> to authorize a subtree explicitly, or with -ConfigPath '' to ignore the config entirely." -f $msg) }
  }
  # Dedupe on path+globs. Select-Object -Unique cannot do this over hashtables.
  $seen = @{}
  foreach($e in $raw){
    if(-not $e.Path){ continue }
    $p=$null; try { $p=[IO.Path]::GetFullPath($e.Path).TrimEnd('\') } catch { continue }
    if(-not $p){ continue }
    $key = $p.ToLowerInvariant()+'|'+(@($e.Globs) -join ';').ToLowerInvariant()
    if($seen.ContainsKey($key)){ continue }
    $seen[$key]=$true
    $allowedRoots += ,@{ Path=$p; Globs=@($e.Globs) }
  }
  if(-not $allowedRoots.Count){ throw "InPlace refused: no allowed roots (pass -ConfigPath and/or -AllowRoot)" }
}
function Test-SafeTarget($tgt){
  if([string]::IsNullOrWhiteSpace($tgt)){ return $false }
  if($tgt -like '\\*' -or $tgt -like '*..*'){ return $false }            # reject UNC/device/traversal
  $full=$null; try { $full=[IO.Path]::GetFullPath($tgt) } catch { return $false }
  if($full -ne $tgt){ return $false }                                     # normalization changed it => suspicious
  # A3/J4: reject alternate data streams EXPLICITLY. These already failed under PowerShell 5.1, but
  # only because .NET Framework's GetFullPath throws on a second colon -- the platform was doing the
  # work, not this guard. .NET Core / .NET 5+ dropped that check, so under pwsh 7 'auth-storage.json:x.log'
  # would survive normalization, return 'auth-storage.json:x.log' from GetFileName, and MATCH a
  # wildcard glob -- authorizing a stream write onto a credential file. Do not remove this on the
  # grounds that ADS paths "already fail": they fail on a runtime detail we do not control.
  # Index 2 so the drive-letter colon at index 1 is not counted.
  if($full.IndexOf(':',2) -ge 0){ return $false }
  # NOTE (A3/J2): this is a DISJUNCTION over roots, so a subtree grant on the same path or on any
  # ancestor silently defeats a file-scoped one -- there is no detection for that. The current config
  # is clean (legacy-c-status is a CHILD of the legacy root, and nothing grants ...\Roaming or above),
  # and backup.ps1 composes overlapping sources the same way, so this is a config-design hazard both
  # sides share rather than drift introduced here. Check it before adding any broad source.
  foreach($r in $allowedRoots){
    $root=$r.Path; $globs=@($r.Globs)
    if($globs.Count){
      # FILE-SCOPED: the target's directory must BE the root (no subtree), and the basename must
      # match an allowlist pattern. Mirrors backup.ps1: "top-level files only, basename globs".
      $dir=$null; try { $dir=[IO.Path]::GetDirectoryName($full) } catch { continue }
      if($null -eq $dir){ continue }
      if(-not ($dir.TrimEnd('\') -ieq $root)){ continue }
      $base=[IO.Path]::GetFileName($full)
      foreach($g in $globs){ if($base -like $g){ return $true } }
      continue
    }
    if(($full -ieq $root) -or $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){ return $true }
  }
  return $false
}
$work = Join-Path $env:TEMP ("cvrestore_"+(Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
  if($Mode -eq "Extract"){
    if(-not $Dest){ throw "-Dest required for Extract mode" }
    # B4: prefer an interactive 7-Zip prompt (bare -p) so the passphrase never lands
    # on the process command line. Inline -p only when a passphrase was supplied
    # non-interactively (scripted validation), which is an explicit opt-in.
    $pArgs = @("x",$Archive,"-o$Dest","-y","-bso0","-bsp0"); $pArgs += if($Pass){ "-p$Pass" } else { "-p" }
    & $SevenZip @pArgs | Out-Null; if($LASTEXITCODE -ne 0){ throw "extract failed (bad passphrase or corrupt archive)" }
    Say "extract-to" $Dest; return
  }
  # B4: bare -p => interactive prompt (nothing on the cmdline); inline only if -Pass/env given.
  $pArgs = @("x",$Archive,"-o$work","-y","-bso0","-bsp0"); $pArgs += if($Pass){ "-p$Pass" } else { "-p" }
  & $SevenZip @pArgs | Out-Null; if($LASTEXITCODE -ne 0){ throw "extract failed (bad passphrase or corrupt archive)" }
  Say "extract" "ok -> $work"

  # ---- version-check: warn (loud, non-blocking by default) if the archive was taken against a
  # different Clairvoyance version. Runs BEFORE any MANIFEST placement, so an InPlace restore that
  # trips a -RequireVersionMatch gate throws before writing a single file.
  # -RequireVersionMatch is a HARD gate, deliberately independent of -Force (which InPlace requires
  # for a different reason). It FAILS CLOSED: it stops not only on a confirmed mismatch but also
  # when the version cannot be determined at all -- a legacy archive with no stamp, or an
  # unreadable/missing install exe (exactly when you'd want the brakes). -AllowUnknownVersion is the
  # explicit escape for the two "cannot determine" cases ONLY; it never lets a confirmed mismatch through.
  $metaPath = Join-Path $work "BACKUP-META.json"; $archiveVer = $null
  $bm = $null; $metaPresent = $false; $metaParsed = $false
  if(Test-Path -LiteralPath $metaPath){
    $metaPresent = $true
    try { $bm=Get-Content -Raw -LiteralPath $metaPath|ConvertFrom-Json; $metaParsed = $true; $archiveVer=[string]$bm.appVersion } catch {}
  }

  # ---- BACKUP-META schemaVersion guard (maintainer-authorised 2026-07-27; implemented 2026-08-07) ----
  # Posture is WARN, never fatal, matching the tools-manifest guard in backup.ps1 and the F14
  # philosophy: a restore that refuses to proceed because a metadata schema evolved is a
  # self-inflicted outage at the worst possible moment -- the machine is already dead. Proceed
  # with what is understood, say so loudly. Fail-closed belongs where the failure mode is silent
  # data loss, not where it is a stale field in a metadata file.
  #
  # Stage label is deliberately 'meta-schema', distinct from 'version-check'. Since the 0.82.1
  # upgrade every archive we hold is stamped 0.81.3, so version-check WARNs on essentially every
  # restore. An acceptance test that asserted on "was there a WARN" could no longer tell this
  # guard's signal from that ambient noise -- it would pass while discriminating nothing. Assert
  # on this label.
  #
  # A field that is ABSENT is not a field that is NULL. PowerShell reads both as $null, so
  # presence is tested structurally via PSObject.Properties, and an absent field is reported as
  # "predates stamping" rather than asserted to have a value.
  #
  # Nothing is emitted when BACKUP-META.json is missing entirely: version-check already reports
  # that one line below, and a second copy of the same news is noise in a live recovery.
  if($metaPresent -and -not $metaParsed){
    Say "meta-schema" "WARN BACKUP-META.json is present but could not be parsed -- schemaVersion is UNKNOWN (not absent); treat every field this file would have supplied as unverified"
  }
  elseif($metaParsed){
    if($bm.PSObject.Properties.Name -notcontains 'schemaVersion'){
      Say "meta-schema" "WARN archive predates BACKUP-META schema stamping (no schemaVersion field) -- cannot compare; fields are best-effort and absent ones are unknown, NOT empty"
    } else {
      $svRaw = [string]$bm.schemaVersion
      if($null -eq $bm.schemaVersion -or $svRaw.Trim() -eq ''){
        Say "meta-schema" "WARN BACKUP-META schemaVersion is present but NULL/empty -- this is NOT the same as predating stamping; the writer emitted a field it failed to fill, so treat the whole file as suspect"
      } else {
        $svNum = 0.0
        if(-not [double]::TryParse($svRaw,[ref]$svNum)){
          Say "meta-schema" "WARN BACKUP-META schemaVersion '$svRaw' is not a number -- treating as unknown; fields are best-effort"
        }
        elseif($svNum -gt $KnownBackupMetaSchema){
          Say "meta-schema" "WARN BACKUP-META schemaVersion $svRaw is NEWER than this restore understands (v$KnownBackupMetaSchema) -- any field added after v$KnownBackupMetaSchema is NOT interpreted here; read BACKUP-META.json directly before trusting this restore's version reporting"
        }
        elseif($svNum -lt $KnownBackupMetaSchema){
          Say "meta-schema" "WARN BACKUP-META schemaVersion $svRaw is OLDER than this restore understands (v$KnownBackupMetaSchema) -- fields added after v$svRaw are absent from the file and are reported as 'unknown', NOT as empty values"
        }
        # schemaVersion == known: deliberately SILENT. A guard that fires on every restore is as
        # useless as one that never fires, and is the harder failure to notice.
      }
    }
  }

  if(-not $archiveVer){
    if($RequireVersionMatch -and -not $AllowUnknownVersion){
      throw "version-check: -RequireVersionMatch set but the archive carries no version stamp (legacy archive, cannot confirm a match). Re-run with -AllowUnknownVersion to restore anyway, or drop -RequireVersionMatch."
    }
    $ov = if($RequireVersionMatch){ " -- proceeding: -AllowUnknownVersion overrides -RequireVersionMatch" } else { "" }
    Say "version-check" "INFO archive predates version-stamping (no BACKUP-META.json) -- app version unknown, cannot compare$ov"
  } else {
    $installedVer = Get-InstalledCVVersion; $cmp = Compare-CVVersion $archiveVer $installedVer
    if($cmp -eq 'unknown'){
      if($RequireVersionMatch -and -not $AllowUnknownVersion){
        throw "version-check: -RequireVersionMatch set but the version could not be determined (archive=$archiveVer installed=$installedVer -- install exe unreadable/missing?). Re-run with -AllowUnknownVersion to restore anyway, or drop -RequireVersionMatch."
      }
      $ov = if($RequireVersionMatch){ " -- proceeding: -AllowUnknownVersion overrides -RequireVersionMatch" } else { "" }
      Say "version-check" "INFO archive=$archiveVer installed=$installedVer -- one side unknown, cannot compare$ov"
    }
    elseif($cmp -eq 'match'){ Say "version-check" "PASS archive=$archiveVer installed=$installedVer" }
    else {
      if($cmp -eq 'patch'){ Say "version-check" "WARN (patch) archive=$archiveVer installed=$installedVer -- low risk, but verify data/schema compatibility" }
      else { Say "version-check" "WARN ($cmp) archive=$archiveVer installed=$installedVer -- data/schema compatibility NOT guaranteed across a $cmp version change; review before trusting an InPlace restore" }
      # confirmed mismatch: -AllowUnknownVersion does NOT apply here (it only covers "cannot determine").
      if($RequireVersionMatch){
        throw "version-check: -RequireVersionMatch set and versions differ (archive=$archiveVer installed=$installedVer). Restore onto Clairvoyance $archiveVer, or drop -RequireVersionMatch to proceed with a warning."
      }
    }
  }

  $manPath = Join-Path $work "MANIFEST.json"; if(-not (Test-Path $manPath)){ $manPath = Join-Path $work "MANIFEST.secrets.json" }
  if(-not (Test-Path $manPath)){ throw "no MANIFEST in archive" }
  $man = Get-Content -Raw $manPath | ConvertFrom-Json
  # Tolerate LEGACY nested manifests: archives produced before the manifest-nest-fix (2026-07-23)
  # serialized as {"value":[...],"Count":N} instead of a bare array. Unwrap so those remain restorable.
  if(($man -is [pscustomobject]) -and ($man.PSObject.Properties.Name -contains 'value') -and ($man.PSObject.Properties.Name -contains 'Count')){ $man = $man.value }
  $man = @($man)
  $ok=0; $bad=0; $missing=0; $restored=0; $rejected=0
  foreach($e in $man){
    $inArc = Join-Path (Join-Path $work ([string]$e.source)) ([string]$e.rel)
    if(-not (Test-Path -LiteralPath $inArc)){ $missing++; Say "MISSING" ([string]$e.rel); continue }
    $h = (Get-FileHash -LiteralPath $inArc -Algorithm SHA256).Hash
    if($h -ne $e.sha256){ $bad++; Say "HASH-MISMATCH" ([string]$e.rel); continue }
    $ok++
    if($Mode -eq "InPlace"){
      if(-not $Force){ throw "InPlace requires -Force (writes to real target locations)" }
      $tgt = [string]$e.target
      if(-not (Test-SafeTarget $tgt)){ $rejected++; Say "REJECTED-TARGET" $tgt; continue }   # F2
      New-Item -ItemType Directory -Force -Path (Split-Path $tgt) | Out-Null
      Copy-Item -LiteralPath $inArc -Destination $tgt -Force
      $v = (Get-FileHash -LiteralPath $tgt -Algorithm SHA256).Hash
      if($v -eq $e.sha256){ $restored++ } else { $bad++; Say "RESTORE-VERIFY-FAIL" $tgt }
    }
  }
  Say "result" ("mode=$Mode ok=$ok bad=$bad missing=$missing restored=$restored rejected=$rejected total=$($man.Count)")
  if($bad -gt 0 -or $missing -gt 0 -or $rejected -gt 0){ exit 2 }
}
finally { Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue }
```

## backup-window.ps1

*Shared module for LEASE AND HEALTH READERS. Dot-sourced by Invoke-BackupHealthCheck.ps1; the engine writes and clears the lease file directly and does not dot-source it. Owns the quiesce lease (fails OPEN) and the health verdict (fails CLOSED). The opposing postures are deliberate.*

```powershell
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
# This module used to live in <TOOLS_DIR>, which carries `Authenticated Users: Modify`.
# Review (adversarial review 2026-07-27) rightly called that out: a user-writable module advertising itself as
# "the shared module for every orchestrator" is an invitation, and the boundary was documented
# rather than enforced.
#
# The recommended enforcement was to throw for any Administrator-role caller. I MEASURED that
# before applying it, and it would have DISABLED THIS GATE ENTIRELY on this machine: the scheduled
# task `Clairvoyance Elevated Autostart` runs RunLevel=Highest, so the app and every orchestrator
# tick it dispatches are ALREADY elevated. Callers wrap this dot-source in try/catch and fail open,
# so the throw would be swallowed and Test-BackupQuiet would simply never run again -- a control
# that silently becomes a permanent no-op, which is the exact failure the same review flagged
# elsewhere. A warning instead would fire on 100% of normal runs and train everyone to ignore it.
#
# So the file MOVED here, to <TOOL_DIR>, which is ACL-hardened (verified:
# SYSTEM / Administrators / <PC>\<YOU> only -- NO Authenticated Users ACE). The module
# is no longer user-writable, so the finding is closed rather than warned about.
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
```

## Invoke-BackupHealthCheck.ps1

*Scheduled health verdict over last-run.json. Fails closed; age is checked before ok and beats it. Writes one line per run to the verdict log so a passing check is distinguishable from a check that never ran.*

```powershell
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
```

## Invoke-StaffMemoryCoverageCheck.ps1

*Read-only staff-memory coverage drift report. Runs the same comparison as the in-engine assertion WITHOUT touching ok, so you can see what would fire before enabling it.*

```powershell
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
```

## evaluate-workspaces.ps1

*Read-only workspace sizing helper, used when deciding exclusions and artifact directories.*

```powershell
<#
  evaluate-workspaces.ps1 - scans each workspace under -Root and reports top-level
  entry sizes, flagging large dirs as candidates for exclude or the weekly Artifacts tier.
  Reusable by the setup runbook to ask the per-workspace question PROACTIVELY (with data).
  -LargeMB threshold flags a dir as "large" (default 100).  -Json emits machine-readable output.
#>
[CmdletBinding()]
param([string]$Root = "<WORKSPACES_ROOT>", [int]$LargeMB = 100, [switch]$Json)
function DirMB($p){ [math]::Round((Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum/1MB) }
$report = @()
foreach($ws in (Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)){
  $tops = @()
  foreach($e in (Get-ChildItem -LiteralPath $ws.FullName -Directory -ErrorAction SilentlyContinue)){
    $mb = DirMB $e.FullName
    $tops += [pscustomobject]@{ name=$e.Name; mb=$mb; large=($mb -ge $LargeMB) }
  }
  $filesMB = [math]::Round((Get-ChildItem -LiteralPath $ws.FullName -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum/1MB)
  $report += [pscustomobject]@{ workspace=$ws.Name; totalMB=(($tops|Measure-Object mb -Sum).Sum + $filesMB); rootFilesMB=$filesMB; topDirs=($tops|Sort-Object mb -Descending) }
}
if($Json){ $report | ConvertTo-Json -Depth 6; return }
foreach($r in ($report | Sort-Object totalMB -Descending)){
  "== {0}  ({1:N0} MB total) ==" -f $r.workspace, $r.totalMB
  foreach($d in $r.topDirs){ "   {0} {1,-24} {2,7:N0} MB" -f $(if($d.large){"[LARGE]"}else{"       "}), $d.name, $d.mb }
  if($r.rootFilesMB -gt 0){ "           (root files){0,15:N0} MB" -f $r.rootFilesMB }
}
```

