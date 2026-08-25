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
          # RULE: describe the GRANT; use enumeration only as illustration, never as evidence of
          # narrowness. NEVER SAY "NOTHING" ABOUT A PATTERN THAT STILL MATCHES ANYTHING -- that is a
          # claim about the DIRECTORY masquerading as a claim about the GRANT. Test-SafeTarget never
          # touches the filesystem: existence is not a precondition for authorization, and InPlace
          # CREATES the targets the manifest names, so an empty root with glob '*' still authorizes
          # everything. It bites hardest in a bare-metal DR -- root present but not yet populated --
          # which is exactly when someone reads this line.
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

