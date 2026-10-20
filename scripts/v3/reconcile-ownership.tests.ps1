<#!
.SYNOPSIS
    Tests for reconcile-opencode-config.ps1 Config-ownership guard (C6.3-1).
.DESCRIPTION
    Run: pwsh -NoProfile -File <this-file> (or powershell 5.1). Exit 0/1.
    TEMP fixtures only; live config never touched. PS 5.1 compatible.
    - R1/R2: Config-owned home => preview+apply exit 0, SKIP, target intact.
    - R3: markerless home => normal plan, target intact (preview).
    - R4: legacy orchestration markers => normal flow, no SKIP.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$reconciler = Join-Path $repo 'scripts\reconcile-opencode-config.ps1'

$total = 0
$passed = 0
function Assert-R($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host ("PASS {0}" -f $name) }
  else { Write-Host ("FAIL {0} :: {1}" -f $name, $detail) }
}
function New-Root($base, $name) {
  $h = Join-Path $base $name
  New-Item -ItemType Directory -Path (Join-Path $h 'gen\opencode\v1') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $h 'home\.config\opencode') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $h 'backups') -Force | Out-Null
  $gen = Join-Path $h 'gen\opencode\v1\AGENTS.md'
  Write-Utf8NoBomLocal $gen ("<!-- GENERATED FILE: direct edits will be overwritten. -->`n# Generated body`n")
  return $h
}
function Write-Utf8NoBomLocal($path, $text) {
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}
function Home-Of($h) { return (Join-Path $h 'home') }
function Invoke-Reco($h, [string[]]$extra) {
  $a = @('-NoProfile', '-File', $reconciler, '-RepoRoot', $repo, '-GeneratedRoot', (Join-Path $h 'gen'), '-UserProfileRoot', (Home-Of $h), '-BackupRoot', (Join-Path $h 'backups'), '-HomeDir', (Home-Of $h), '-RepoDir', $repo, '-Runtime', 'V1') + $extra
  return (& pwsh @a 2>&1)
}

$base = Join-Path ([IO.Path]::GetTempPath()) ('reconcile-own-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
try {
  # --- R1: Config-owned preview => SKIP, intact.
  $h1 = New-Root $base 'owned'
  $t1 = Join-Path (Home-Of $h1) '.config\opencode\AGENTS.md'
  $cfg = "<!-- agent-config:global:start -->`n# Global`n<!-- agent-config:global:end -->`n"
  Write-Utf8NoBomLocal $t1 $cfg
  $o1 = Invoke-Reco $h1 @()
  Assert-R (($LASTEXITCODE -eq 0) -and (($o1 -join "`n") -match 'SKIP') -and (((Get-Content -LiteralPath $t1 -Raw) -ceq $cfg))) 'R1 owned preview SKIP intact' ($o1 | Select-Object -Last 1)

  # --- R2: Config-owned apply => exit 0, intact, no backup written.
  $o2 = Invoke-Reco $h1 @('-Apply')
  $leftovers = @(Get-ChildItem (Join-Path $h1 'backups') -Recurse -ErrorAction SilentlyContinue)
  Assert-R (($LASTEXITCODE -eq 0) -and (((Get-Content -LiteralPath $t1 -Raw) -ceq $cfg)) -and ($leftovers.Count -eq 0)) 'R2 owned apply no-op' ($o2 | Select-Object -Last 1)

  # --- R3: markerless home => normal plan, preview touches nothing.
  $h3 = New-Root $base 'plain'
  $t3 = Join-Path (Home-Of $h3) '.config\opencode\AGENTS.md'
  Write-Utf8NoBomLocal $t3 "user notes`n"
  $o3 = Invoke-Reco $h3 @()
  Assert-R (($LASTEXITCODE -eq 0) -and (($o3 -join "`n") -match 'append-block') -and (((Get-Content -LiteralPath $t3 -Raw) -ceq "user notes`n"))) 'R3 plain preview plans append' ($o3 | Select-Object -Last 1)

  # --- R4: legacy orchestration markers => normal flow, no SKIP.
  $h4 = New-Root $base 'legacy'
  $t4 = Join-Path (Home-Of $h4) '.config\opencode\AGENTS.md'
  Write-Utf8NoBomLocal $t4 "user`n<!-- opencode-orchestration:start -->`nold body`n<!-- opencode-orchestration:end -->`n"
  $o4 = Invoke-Reco $h4 @()
  Assert-R (($LASTEXITCODE -eq 0) -and (($o4 -join "`n") -match 'replace-block') -and ((($o4 -join "`n") -notmatch 'SKIP'))) 'R4 legacy flow unaffected' ($o4 | Select-Object -Last 1)
}
finally {
  if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f $total, $passed, ($total - $passed))
if ($passed -ne $total) { exit 1 }
exit 0
