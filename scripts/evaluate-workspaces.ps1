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

