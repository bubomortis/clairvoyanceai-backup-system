# Clairvoyance Backup System — Companion Scripts

*Full source of the three config-driven PowerShell scripts referenced by the Build Runbook. The executing Clairvoyance AI writes these VERBATIM into the tool directory during setup — no script files are transferred from anyone, so a trustless adopter needs nothing beyond this text.*

**Before use:** all real paths come from `config.json`; the only environment-specific bits are the param DEFAULTS shown as `<TOOL_DIR>` / `<WORKSPACES_ROOT>` (replace with your tool dir / workspaces root, or always invoke with explicit `-ConfigPath`). `7z.exe` default is the standard install path.

## backup.ps1
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
  [switch]$ForceRehash
)
$ErrorActionPreference = "Stop"
$cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$now = if($RunDate){ [datetime]::ParseExact($RunDate,"yyyy-MM-dd",$null).AddHours(3) } else { Get-Date }
$stamp = $now.ToString("yyyy-MM-dd_HHmm")
$instName = if($InstanceName){ $InstanceName } else { $cfg.instanceName }
$instanceRoot = Join-Path $cfg.backupRoot $instName
$statePath = Join-Path $instanceRoot "backup_state.json"
$seven = $cfg.sevenZip
$robocopy = Join-Path $env:SystemRoot "System32\robocopy.exe"   # F9: pin, no PATH resolution while elevated
$mirror = $cfg.stagingDir
$toolDir = Split-Path -Parent $ConfigPath   # for _Restore self-containment (scripts live beside config.json)
$logStages = @()
$script:pass = $null
function Log($stage,$status,$detail){ $script:logStages += [pscustomobject]@{ ts=(Get-Date).ToString("s"); stage=$stage; status=$status; detail=$detail }; Write-Host ("[{0}] {1} : {2} {3}" -f (Get-Date).ToString("HH:mm:ss"),$stage,$status,$detail) }

# ---- abort-window guard ----
$abortAt = $null
if($cfg.abortAfterLocalTime -and -not $RunDate){ $ap = $cfg.abortAfterLocalTime -split ':'; $abortAt = (Get-Date -Hour ([int]$ap[0]) -Minute ([int]$ap[1]) -Second 0) }
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

# F7: depth-agnostic secret matching (bare name = basename anywhere; dir/** = that dir anywhere)
function Match-Secret($rel,$patterns){ $r=($rel -replace '\\','/'); $base=($r -replace '.*/',''); foreach($p in $patterns){ if($p -notmatch '/'){ if($base -ieq $p){ return $true }; continue }; $rx=[regex]::Escape($p) -replace '\\\*\\\*','.*' -replace '\\\*','[^/]*'; if($r -match ('(^|/)'+$rx+'$')){ return $true } }; return $false }
function Is-Excluded($rel,$src){ $segs=($rel -replace '\\','/').Split('/'); foreach($d in $src.excludeDirs){ if($segs -icontains $d){ return $true } }; $base=$segs[-1]; foreach($f in $src.excludeFiles){ if($base -like $f){ return $true } }; return $false }

# F3: passphrase from DPAPI file (else env), then clear env so children don't inherit it
function Get-Passphrase(){ if($script:pass){ return $script:pass }; $p=$null
  if($cfg.passphraseFile -and (Test-Path -LiteralPath $cfg.passphraseFile)){ try { Add-Type -AssemblyName System.Security -EA SilentlyContinue; $b=[Convert]::FromBase64String((Get-Content -Raw -LiteralPath $cfg.passphraseFile).Trim()); $dec=[Security.Cryptography.ProtectedData]::Unprotect($b,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine); $p=[Text.Encoding]::UTF8.GetString($dec) } catch {} }   # F11b: LocalMachine DPAPI so the SYSTEM task can read it
  if(-not $p -and $env:ARCHIVIST_SECRETS_PASS){ $p=$env:ARCHIVIST_SECRETS_PASS }
  Remove-Item Env:ARCHIVIST_SECRETS_PASS -ErrorAction SilentlyContinue
  $script:pass=$p; return $p }

function SevenZip { param([Parameter(ValueFromRemainingArguments=$true)]$a) & $seven @a; return $LASTEXITCODE }
function SevenZipPw([string]$pw,[string[]]$z){ $pw | & $seven @z; return $LASTEXITCODE }   # F3: bare -p, password via stdin (explicit arg array so $pw isn't swallowed)

# ---- robocopy /MIR into persistent mirror; excludes secrets (F4) + encrypt-workspaces (F6a) ----
function Mirror-Source($src){
  $dst = Join-Path $mirror $src.name
  $tail = @("/MIR","/R:2","/W:5","/NFL","/NDL","/NJH","/NJS","/NP")
  foreach($x in $src.excludeDirs){ $tail += @("/XD",$x) }
  foreach($x in $script:secDirNames){ $tail += @("/XD",$x) }              # F4: never mirror secret dirs
  foreach($x in $src.excludeFiles){ $tail += @("/XF",$x) }
  foreach($x in $script:secFileNames){ $tail += @("/XF",$x) }             # F4: never mirror secret files
  if($Mode -eq "DryRun"){ $tail += "/L" }
  $lastRc=-1
  foreach($bmode in @("/B","/ZB","")){
    $a = if($bmode){ @($src.path,$dst,$bmode)+$tail } else { @($src.path,$dst)+$tail }
    & $robocopy @a | Out-Null; $lastRc=$LASTEXITCODE
    if($lastRc -lt 8){ if($bmode -ne "/B"){ Log "copy-mode" "WARN" "$($src.name): used '$bmode' (rc=$lastRc)" }; return $dst }
  }
  throw "robocopy failed ($($src.name)) rc=$lastRc"
}
function Manifest-Source($src,$dst){
  Get-ChildItem -LiteralPath $dst -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $rel=$_.FullName.Substring($dst.Length).TrimStart('\'); $key="$($src.name)|$rel"
    [pscustomobject]@{ rel=$rel; sha256=(Hash-Cached $_.FullName $key); bytes=$_.Length; source=$src.name; category=$src.category; target=(Join-Path $src.path $rel) }
  }
}
# F4/F6a: gather secret files from LIVE sources (never mirrored). encrypt-workspaces => ALL files.
function Get-SecretFilesLive(){ $out=@()
  foreach($src in $script:effectiveSources){ if(-not (Test-Path -LiteralPath $src.path)){ continue }
    foreach($f in (Get-ChildItem -LiteralPath $src.path -Recurse -File -ErrorAction SilentlyContinue)){
      $rel=$f.FullName.Substring($src.path.Length).TrimStart('\')
      if((Is-Excluded $rel $src)){ continue }
      if($src.encrypt -or (Match-Secret $rel $cfg.secretsSet)){
        $out += [pscustomobject]@{ rel=$rel; sha256=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash; bytes=$f.Length; source=$src.name; category=$src.category; target=$f.FullName; full=$f.FullName }
      }
    }
  }
  return ,@($out)
}
# F7: pre-upload scan gate for NOVEL secrets leaking into the plaintext main set (warn-first)
function Scan-Secrets($mainMan){ if(-not $cfg.secretScanPatterns){ return }
  $maxB=([int]$cfg.secretScanMaxFileKB)*1024; $hits=@()
  foreach($e in $mainMan){ if($e.bytes -gt $maxB){ continue }
    $full=Join-Path (Join-Path $mirror $e.source) $e.rel; if(-not(Test-Path -LiteralPath $full)){ continue }
    $txt=$null; try { $txt=Get-Content -Raw -LiteralPath $full -ErrorAction Stop } catch { continue }
    if($txt -match "\0"){ continue }   # skip binary
    foreach($pat in $cfg.secretScanPatterns){ if($txt -match $pat){ $hits+="$($e.source)\$($e.rel)"; break } }
  }
  if($hits.Count){ Log "secret-scan" "WARN" "possible secret(s) in plaintext main: $((@($hits)|Select-Object -First 5) -join '; ')$(if($hits.Count -gt 5){" (+$($hits.Count-5) more)"})" } else { Log "secret-scan" "PASS" "no novel secrets detected in main set" }
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
function Write-Recovery($file){
  $L=New-Object System.Collections.Generic.List[string]
  $L.Add("# Clairvoyance - Bare-Metal Recovery Plan"); $L.Add("Instance: $instName | stamp: $stamp | Generated: $($now.ToString('u'))"); $L.Add("")
  $L.Add("## Archives"); $L.Add("- backup_${stamp}_main.7z - plaintext, all non-secret files; see MANIFEST.json."); $L.Add("- backup_${stamp}_secrets.7z - AES-256 (credentials + any encrypt-elected workspaces); full inventory in MANIFEST.full.json inside it; passphrase = credential '$($cfg.secretsCredentialName)' (password manager).")
  $L.Add(""); $L.Add("## Source -> restore target"); foreach($s in $script:effectiveSources){ $L.Add("- [$($s.category)] $($s.name) ($(if($s.encrypt){'ENCRYPTED'}else{'plain'})) -> $($s.path)") }
  $L.Add(""); $L.Add("## Rebuild: 1.Reinstall Clairvoyance 2.restore.ps1 -Mode InPlace (main) 3.decrypt _secrets.7z 4.re-add workspaces 5.RE-AUTH OAuth tools 6.reconstitute deps (rclone/SMB/local-AI; whisper via setup-whisper.ps1) 7.recreate the SYSTEM backup task (03:00).")
  $L.Add(""); $L.Add("## Environment snapshot")
  try { $rr=((& rclone listremotes 2>$null) -join ', ') } catch { $rr='(n/a)' }; $L.Add("- rclone remotes: $rr")
  try { $ol=(((& ollama list 2>$null)|Select-Object -Skip 1|ForEach-Object{($_ -split '\s+')[0]}) -join ', ') } catch { $ol='(n/a)' }; $L.Add("- Ollama models: $ol")
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
    $dst = Join-Path $artStage $rel; New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null; Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    $man += [pscustomobject]@{ rel=$rel; sha256=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash; bytes=$f.Length; source=$m.name; category="artifact"; target=$f.FullName }; $idx[$rel]=$sig; $new++
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

$result = [ordered]@{ ok=$true; stamp=$stamp; tiers=@(); substitutions=@() }
$arcTmp = Join-Path $cfg.tempDir ("cvarc_"+$stamp)     # F10: temp inside the locked dir
$secTmp = Join-Path $arcTmp "sec"
try {
  Log "start" "INFO" "mode=$Mode instance=$instName stamp=$stamp mirror=$mirror"
  New-Item -ItemType Directory -Force -Path $mirror,$instanceRoot,$cfg.tempDir | Out-Null
  if($cfg.pauseFlag -and $Mode -ne "DryRun"){ Set-Content -LiteralPath $cfg.pauseFlag -Value ("backup in progress since "+$now.ToString('s')) -EA SilentlyContinue }  # F11b: orchestrators self-gate on this
  Get-ChildItem -LiteralPath $cfg.tempDir -Directory -Filter "cvarc_*" -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue  # F10: sweep stale
  Load-Cache
  $state = if(Test-Path -LiteralPath $statePath){ Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json } else { [pscustomobject]@{ lastSuccess=$null; lastWeekly=$null; lastMonthly=$null; lastAnnual=$null; lastFullRehash=$null } }
  if(-not ($state.PSObject.Properties.Name -contains 'lastFullRehash')){ $state | Add-Member NoteProperty lastFullRehash $null -Force }
  $script:doRehash = [bool]$ForceRehash -or (-not $state.lastFullRehash) -or (([datetime]$state.lastFullRehash) -lt $now.AddDays(-28))
  if($script:doRehash){ Log "rehash" "INFO" "FULL re-hash this run (monthly integrity pass)" }
  if(-not $SkipSecrets){ Get-Passphrase | Out-Null }   # F3: fetch + clear env BEFORE any child process spawns

  # 1. mirror (delta, secrets excluded) + manifest
  New-Item -ItemType Directory -Force -Path $arcTmp | Out-Null
  $mainMan=@()
  foreach($src in $script:effectiveSources){
    if($src.encrypt){ Log "copy+verify" "PASS" "$($src.name) (encrypt-elected -> secrets)"; continue }   # F6a: not mirrored, goes to secrets
    $dst = Mirror-Source $src
    if($Mode -ne "DryRun"){ $mainMan += @(Manifest-Source $src $dst) }
    Log "copy+verify" "PASS" "$($src.name)"
  }
  if($Mode -eq "DryRun"){ Log "dryrun" "PASS" "mirrored (delta) $($script:effectiveSources.Count) sources"; $result.ok=$true; return }
  Assert-Window "secrets"

  # 2. gather secrets from LIVE sources (F4); F7 scan gate on main
  $secEntries = if(-not $SkipSecrets){ @(Get-SecretFilesLive) } else { @() }
  $allManifest = @($mainMan) + @($secEntries | Select-Object rel,sha256,bytes,source,category,target)
  Log "secrets-split" "PASS" "main=$($mainMan.Count) secret=$($secEntries.Count)"
  Scan-Secrets $mainMan
  Assert-Window "compress"

  # 3. meta (F8: full inventory -> secrets archive only)
  Write-Recovery (Join-Path $arcTmp "RECOVERY.md")
  ($mainMan | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $arcTmp "MANIFEST.json") -Encoding UTF8

  # 4. compress main from mirror (already secret-free) + append meta
  $mainArc = Join-Path $arcTmp ("backup_"+$stamp+"_main.7z")
  $secArc  = Join-Path $arcTmp ("backup_"+$stamp+"_secrets.7z")
  Push-Location $mirror; try { if((SevenZip a -t7z -mx=5 -mmt=on -bso0 -bsp0 $mainArc '*') -ne 0){ throw "7z main compress failed" } } finally { Pop-Location }
  Push-Location $arcTmp; try { if((SevenZip a -bso0 -bsp0 $mainArc "MANIFEST.json" "RECOVERY.md") -ne 0){ throw "7z main meta add failed" } } finally { Pop-Location }
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
  # NOTE (F3 residual): 7z 't' cannot read the password from stdin (only 'a' can), so the test needs inline -p for ~1s.
  # Compress above is stdin-safe; env is cleared; log is redacted. This brief test exposure is the only residual.
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
  foreach($t in $tiers){ if($t.last -and ([datetime]$t.last).Date -ge $t.boundary){ continue }
    $dir=Join-Path $instanceRoot $t.name; New-Item -ItemType Directory -Force -Path $dir|Out-Null; $isSub=$now.Date -ne $t.boundary
    foreach($da in $dailyArcs){ $leaf=Split-Path $da -Leaf; if($isSub){ $leaf=$leaf -replace '\.7z$',("__SUBSTITUTE-for-$($t.name)-"+$t.boundary.ToString("yyyy-MM-dd")+".7z") }; Copy-Item -LiteralPath $da -Destination (Join-Path $dir $leaf) -Force }
    if($isSub){ "Expected $($t.name) backup for period ending $($t.boundary.ToString('yyyy-MM-dd')) was not produced. This archive ($($now.ToString('yyyy-MM-dd HH:mm'))) substitutes it; contents reflect creation-time state." | Set-Content -LiteralPath (Join-Path $dir ("backup_"+$stamp+"__SUBSTITUTE-for-$($t.name)-"+$t.boundary.ToString('yyyy-MM-dd')+".README.txt")) -Encoding UTF8; $result.substitutions+="$($t.name)<-$($t.boundary.ToString('yyyy-MM-dd'))"; Log "tier" "SUBSTITUTION" "$($t.name) <- $($t.boundary.ToString('yyyy-MM-dd'))" } else { Log "tier" "PASS" "$($t.name) (natural)" }
    $result.tiers += $t.name; switch($t.name){ "Weekly"{$state.lastWeekly=$now.ToString('s')} "Monthly"{$state.lastMonthly=$now.ToString('s')} "Annual"{$state.lastAnnual=$now.ToString('s')} }
  }

  # 9. incremental weekly artifacts
  Build-Artifacts ($result.tiers -contains "Weekly")

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
  if($cfg.pauseFlag){ Remove-Item -LiteralPath $cfg.pauseFlag -Force -EA SilentlyContinue }   # F11b: clear -> fleet may resume
  if(Test-Path -LiteralPath $arcTmp){ Remove-Item -Recurse -Force -LiteralPath $arcTmp -EA SilentlyContinue; if(Test-Path -LiteralPath $arcTmp){ Log "cleanup" "WARN" "temp not fully removed: $arcTmp" } }
  if($script:pass){ foreach($e in $script:logStages){ if($e.detail -and ("$($e.detail)").Contains($script:pass)){ $e.detail="[REDACTED]" } } }   # F13
  $result.log = $logStages
  $json = ($result | ConvertTo-Json -Depth 6)
  if($cfg.lastRunFile){ $json | Set-Content -LiteralPath $cfg.lastRunFile -Encoding UTF8 -EA SilentlyContinue }   # F11b: Archivist reads this to report
  $json
}

```

## restore.ps1
```powershell
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

```

## evaluate-workspaces.ps1
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
