<#!
.SYNOPSIS
    Tests for installer Config-ownership recognition (PLAN-ORCH O2.1/O2.4).
.DESCRIPTION
    Run: pwsh -NoProfile -File <this-file> from anywhere (uses -TargetHome).
    Exit 0/1. All homes are TEMP fixtures; the live config is never touched.
    PS 5.1 compatible (no multi-segment Join-Path, no param block).
    - T1 standalone: full install + SNAPSHOT_COMPAT provenance.
    - T2 Config-owned: global text, agent forks and agents.*.permissions skipped.
    - T3 idempotent re-install.
    - T4 Orch-then-Config order converges to ownership mode.
#>
$ErrorActionPreference = 'Stop'

$passed = 0
$failed = 0
function Assert-OwnTrue {
  param([bool]$Condition, [string]$Name, $Detail = '')
  if ($Condition) { Write-Host ("PASS {0}" -f $Name); $script:passed++ }
  else { Write-Host ("FAIL {0} :: {1}" -f $Name, $Detail); $script:failed++ }
}

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installer = Join-Path $repo 'install.ps1'
function Join-Under($base, [string[]]$segs) {
  $p = $base
  foreach ($s in $segs) { $p = Join-Path $p $s }
  return $p
}
function Oc-File($homeDir, [string[]]$segs) {
  return (Join-Under (Join-Under $homeDir @('.config', 'opencode')) $segs)
}
function Write-Utf8($path, $text) {
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}

$base = Join-Path ([IO.Path]::GetTempPath()) ('install-own-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
try {
  function New-FixtureHome($name) {
    $h = Join-Path $base $name
    New-Item -ItemType Directory -Path (Join-Under $h @('.config', 'opencode')) -Force | Out-Null
    return $h
  }
  function Invoke-Install($homeDir, [string[]]$extra) {
    $a = @('-NoProfile', '-File', $installer, '-TargetHome', $homeDir, '-Runtime', 'V2') + $extra
    return (& pwsh @a 2>&1)
  }
  function Read-Manifest($homeDir) {
    $mp = Join-Under $homeDir @('.opencode-orchestration', 'manifest.json')
    if (-not (Test-Path -LiteralPath $mp -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json)
  }

  # --- T1: standalone install (no Config marker).
  $h1 = New-FixtureHome 'solo'
  $o1 = Invoke-Install $h1 @()
  Assert-OwnTrue ($LASTEXITCODE -eq 0) 'T1 standalone exit 0' ($o1 | Select-Object -Last 1)
  $t1agents = Oc-File $h1 @('AGENTS.md')
  $t1cfg = Oc-File $h1 @('opencode.json')
  if (-not (Test-Path -LiteralPath $t1cfg)) {
    $t1cfg = Oc-File $h1 @('opencode.jsonc')
  }
  Assert-OwnTrue ((Test-Path -LiteralPath $t1agents -PathType Leaf) -and ((Get-Content -LiteralPath $t1agents -Raw) -match 'opencode-orchestration:start')) 'T1 AGENTS.md with legacy marker'
  Assert-OwnTrue (@(Get-ChildItem (Oc-File $h1 @('agents')) -Filter '*.md' -ErrorAction SilentlyContinue).Count -ge 19) 'T1 agent snapshots installed'
  $m1 = Read-Manifest $h1
  Assert-OwnTrue (($null -ne $m1) -and ($m1.config_ownership -ceq 'orchestration-snapshot') -and ($m1.snapshot_provenance -match 'SNAPSHOT_COMPAT')) 'T1 manifest SNAPSHOT_COMPAT' ($m1.snapshot_provenance)

  # --- T2: Config-owned home is respected.
  $h2 = New-FixtureHome 'owned'
  $cfgGlobal = "<!-- agent-config:global:start -->`n# Global`n<!-- agent-config:global:end -->`n"
  Write-Utf8 (Oc-File $h2 @('AGENTS.md')) $cfgGlobal
  Write-Utf8 (Oc-File $h2 @('opencode.json')) ((@{ plugin = @('keep-me'); permissions = @(@{ action = 'shell'; resource = 'mine *'; effect = 'allow' }); agents = @{ build = @{ mode = 'primary'; permissions = @(@{ action = 'subagent'; resource = 'x'; effect = 'deny' }) } } } | ConvertTo-Json -Depth 10))
  $o2 = Invoke-Install $h2 @()
  Assert-OwnTrue ($LASTEXITCODE -eq 0) 'T2 owned install exit 0' ($o2 | Select-Object -Last 1)
  Assert-OwnTrue (((Get-Content -LiteralPath (Oc-File $h2 @('AGENTS.md')) -Raw) -ceq $cfgGlobal)) 'T2 global text untouched'
  Assert-OwnTrue (-not (Test-Path -LiteralPath (Oc-File $h2 @('agents')))) 'T2 no editable agent forks'
  $after2 = Get-Content -LiteralPath (Oc-File $h2 @('opencode.json')) -Raw | ConvertFrom-Json
  Assert-OwnTrue ((@($after2.permissions | Where-Object { $_.resource -ceq 'mine *' })).Count -eq 1) 'T2 top-level user permissions intact'
  Assert-OwnTrue ((@($after2.agents.build.permissions | Where-Object { $_.resource -ceq 'x' })).Count -eq 1) 'T2 agents.*.permissions untouched by installer'
  Assert-OwnTrue (($after2.plugin -contains 'keep-me')) 'T2 user plugin key preserved'
  $m2 = Read-Manifest $h2
  Assert-OwnTrue (($null -ne $m2) -and ($m2.config_ownership -ceq 'agent-config') -and ((@($m2.skipped_namespaces)).Count -eq 3)) 'T2 manifest records ownership+skips'

  # --- T3: idempotent re-install on owned home.
  $before3 = Get-Content -LiteralPath (Oc-File $h2 @('opencode.json')) -Raw
  $o3 = Invoke-Install $h2 @()
  Assert-OwnTrue (($LASTEXITCODE -eq 0) -and (((Get-Content -LiteralPath (Oc-File $h2 @('opencode.json')) -Raw) -ceq $before3))) 'T3 re-install stable' ($o3 | Select-Object -Last 1)

  # --- T4: Orch-then-Config order converges.
  $h4 = New-FixtureHome 'order'
  $o4a = Invoke-Install $h4 @()
  Assert-OwnTrue ($LASTEXITCODE -eq 0) 'T4a standalone first exit 0' ($o4a | Select-Object -Last 1)
  $t4a = Oc-File $h4 @('AGENTS.md')
  $conv = ((Get-Content -LiteralPath $t4a -Raw) -replace '<!-- opencode-orchestration:start -->', '<!-- agent-config:global:start -->') -replace '<!-- opencode-orchestration:end -->', '<!-- agent-config:global:end -->'
  Write-Utf8 $t4a $conv
  $prePerms = ((Get-Content -LiteralPath (Oc-File $h4 @('opencode.json')) -Raw | ConvertFrom-Json).agents.build.permissions | ConvertTo-Json -Compress)
  $o4b = Invoke-Install $h4 @()
  $postPerms = ((Get-Content -LiteralPath (Oc-File $h4 @('opencode.json')) -Raw | ConvertFrom-Json).agents.build.permissions | ConvertTo-Json -Compress)
  $m4 = Read-Manifest $h4
  Assert-OwnTrue (($LASTEXITCODE -eq 0) -and ($prePerms -ceq $postPerms) -and ($m4.config_ownership -ceq 'agent-config')) 'T4 converges to ownership mode' ($o4b | Select-Object -Last 1)

  # --- T5: unresolved token in user area fails stage validation.
  $h5 = New-FixtureHome 'token'
  Write-Utf8 (Oc-File $h5 @('AGENTS.md')) "user notes {{UNRESOLVED_REVIEW_CANARY}}`n"
  $o5 = Invoke-Install $h5 @()
  $t5cfg = Oc-File $h5 @('opencode.json')
  if (-not (Test-Path -LiteralPath $t5cfg)) { $t5cfg = Oc-File $h5 @('opencode.jsonc') }
  Assert-OwnTrue (($LASTEXITCODE -ne 0) -and (($o5 -join "`n") -match 'STAGE INVALIDO|tokens') -and (-not (Test-Path -LiteralPath $t5cfg))) 'T5 user-area token fails closed' ($o5 -join "`n" | Select-Object -Last 2)

  # --- T6: Config-owned home + V1 runtime refused before any write.
  $h6 = New-FixtureHome 'v1refuse'
  Write-Utf8 (Oc-File $h6 @('AGENTS.md')) "<!-- agent-config:global:start -->`n# Global`n<!-- agent-config:global:end -->`n"
  $a6 = @('-NoProfile', '-File', $installer, '-TargetHome', $h6, '-Runtime', 'V1')
  $o6 = (& pwsh @a6 2>&1)
  $t6cfg = Oc-File $h6 @('opencode.json')
  if (-not (Test-Path -LiteralPath $t6cfg)) { $t6cfg = Oc-File $h6 @('opencode.jsonc') }
  Assert-OwnTrue (($LASTEXITCODE -eq 3) -and (-not (Test-Path -LiteralPath $t6cfg)) -and ((Get-Content -LiteralPath (Oc-File $h6 @('AGENTS.md')) -Raw) -match 'agent-config:global:start')) 'T6 V1 refused on Config-owned home' ($o6 -join "`n" | Select-Object -Last 2)

  # --- T7: start-only marker (incomplete) is NOT Config-owned; standalone hardening applies.
  $h7 = New-FixtureHome 'startonly'
  Write-Utf8 (Oc-File $h7 @('AGENTS.md')) "<!-- agent-config:global:start -->`n# Partial, no end marker`n"
  $o7 = Invoke-Install $h7 @()
  $t7cfg = Oc-File $h7 @('opencode.json')
  if (-not (Test-Path -LiteralPath $t7cfg)) { $t7cfg = Oc-File $h7 @('opencode.jsonc') }
  $m7 = Read-Manifest $h7
  Assert-OwnTrue (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $t7cfg) -and ($m7.config_ownership -ceq 'orchestration-snapshot')) 'T7 incomplete marker stays standalone (hardening written)' ($o7 -join "`n" | Select-Object -Last 1)
}
finally {
  if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f ($passed + $failed), $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0