<#
  Clairvoyance Restore  (companion to backup.ps1)  -- security-hardened
    -Mode Verify   : extract to temp, hash every file vs MANIFEST (NO writes) [default]
    -Mode Extract  : extract the archive to -Dest (NO placement)
    -Mode InPlace  : restore each file to its MANIFEST target, VALIDATED against allowed roots (requires -Force)
  F2: InPlace targets are validated against the real config's source roots (NOT the manifest);
      UNC/device/traversal paths are rejected. Provide -ConfigPath or -AllowRoot for InPlace.
  F3: passphrase comes from env RESTORE_SECRETS_PASS (or -Pass fallback), never prompted onto history.
      (7z x/t cannot read the password from stdin, so it is passed inline for the ~1s of extraction.)
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
  [switch]$Force
)
$ErrorActionPreference = "Stop"
function Say($s,$d){ Write-Host ("[{0}] {1} {2}" -f (Get-Date).ToString("HH:mm:ss"),$s,$d) }
if(-not $Pass -and $env:RESTORE_SECRETS_PASS){ $Pass = $env:RESTORE_SECRETS_PASS }   # F3: prefer env over -Pass

# F2: allowed restore roots come from the LOCAL config (not the archive's manifest)
$allowedRoots = @()
if($Mode -eq "InPlace"){
  if($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)){ try { $c=Get-Content -Raw -LiteralPath $ConfigPath|ConvertFrom-Json; foreach($s in $c.sources){ $allowedRoots+=$s.path }; if($c.workspacesRoot){ $allowedRoots+=$c.workspacesRoot } } catch {} }
  if($AllowRoot){ $allowedRoots += $AllowRoot }
  $allowedRoots = @($allowedRoots | Where-Object {$_} | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Select-Object -Unique)
  if(-not $allowedRoots.Count){ throw "InPlace refused: no allowed roots (pass -ConfigPath and/or -AllowRoot)" }
}
function Test-SafeTarget($tgt){
  if([string]::IsNullOrWhiteSpace($tgt)){ return $false }
  if($tgt -like '\\*' -or $tgt -like '*..*'){ return $false }            # reject UNC/device/traversal
  $full=$null; try { $full=[IO.Path]::GetFullPath($tgt) } catch { return $false }
  if($full -ne $tgt){ return $false }                                     # normalization changed it => suspicious
  foreach($r in $allowedRoots){ if(($full -ieq $r) -or $full.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase)){ return $true } }
  return $false
}
$work = Join-Path $env:TEMP ("cvrestore_"+(Get-Date -Format "yyyyMMdd_HHmmss"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
  if($Mode -eq "Extract"){
    if(-not $Dest){ throw "-Dest required for Extract mode" }
    $pArgs = @("x",$Archive,"-o$Dest","-y","-bso0","-bsp0"); if($Pass){ $pArgs += "-p$Pass" }
    & $SevenZip @pArgs | Out-Null; if($LASTEXITCODE -ne 0){ throw "extract failed (bad passphrase or corrupt archive)" }
    Say "extract-to" $Dest; return
  }
  $pArgs = @("x",$Archive,"-o$work","-y","-bso0","-bsp0"); if($Pass){ $pArgs += "-p$Pass" }
  & $SevenZip @pArgs | Out-Null; if($LASTEXITCODE -ne 0){ throw "extract failed (bad passphrase or corrupt archive)" }
  Say "extract" "ok -> $work"

  $manPath = Join-Path $work "MANIFEST.json"; if(-not (Test-Path $manPath)){ $manPath = Join-Path $work "MANIFEST.secrets.json" }
  if(-not (Test-Path $manPath)){ throw "no MANIFEST in archive" }
  $man = Get-Content -Raw $manPath | ConvertFrom-Json
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

