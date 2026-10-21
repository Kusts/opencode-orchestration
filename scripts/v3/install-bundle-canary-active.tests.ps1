<#!
.SYNOPSIS
    Tests for installer bundle Canary/Active modes (PLAN-ORCH O7.2).
.DESCRIPTION
    Run: pwsh -NoProfile -File <this-file> (or powershell 5.1). Exit 0/1.
    TEMP homes only; live config never touched. PS 5.1 compatible.
    Installer subprocesses require pwsh (machine 5.1 lacks Get-FileHash).
    - K1/K2: Canary reports without writing.
    - A1: Active sources permissions from bundle (standalone V2).
    - A2/A3/A4/A5: Active fail-closed (mode mismatch, Config-owned, bad bundle, V1).
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installer = Join-Path $repo 'install.ps1'
. (Join-Path $repo (Join-Path 'scripts' (Join-Path 'v3' (Join-Path 'lib' 'AgentProfileBundleConsumer.ps1'))))
$script:engine = 'pwsh'

$total = 0
$passed = 0
function Assert-B($condition, $name, $detail) {
  $script:total++
  if ($condition) { $script:passed++; Write-Host ("PASS {0}" -f $name) }
  else { Write-Host ("FAIL {0} :: {1}" -f $name, $detail) }
}
function Join-Under($base, [string[]]$segs) {
  $p = $base
  foreach ($s in $segs) { $p = Join-Path $p $s }
  return $p
}
function New-Home($base, $name) {
  $h = Join-Path $base $name
  New-Item -ItemType Directory -Path (Join-Under $h @('.config', 'opencode')) -Force | Out-Null
  return $h
}
function Write-Utf8($path, $text) {
  [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}
function Write-Bundle($path, $mode, $id) {
  $obj = [ordered]@{
    schema = 'agent-profile-bundle/v1'; bundle_id = $id
    source_repository = 'kust-projetos/agent-config'; source_commit_sha = 'd' * 40
    target_runtime = 'opencode-v2'
    compatibility = [ordered]@{ dialect = 'v2'; minimum_capabilities = @('agents', 'permissions') }
    policy_refs = [ordered]@{ agent_profiles = 'p'; native_permissions = 'n'; risk_requirements = 'r'; capability_catalog = 'c' }
    agent_profiles = @(
      [ordered]@{ agent_id = 'coder'; mode = $mode; native_permissions = @([ordered]@{ action = 'edit'; resource = '*'; effect = 'deny' }) })
    managed_paths = @([ordered]@{ resource = 'AGENTS.md'; namespace = 'agent-config:global'; owner = 'agent-config' })
    legacy_compatibility = [ordered]@{ v1_mutation = $false }
    format_version = 1
  }
  $canon = Get-ConsumerCanonicalJson -Bundle $obj
  $digest = Get-ConsumerDigest -CanonicalJson $canon
  Write-Utf8 $path (($canon.TrimEnd('}')) + ',"payload_digest":"' + $digest + '"}')
}
function Read-Manifest($homeDir) {
  $mp = Join-Under $homeDir @('.opencode-orchestration', 'manifest.json')
  if (-not (Test-Path -LiteralPath $mp -PathType Leaf)) { return $null }
  return (Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json)
}
function Read-InstalledCfg($homeDir) {
  $c = Join-Under $homeDir @('.config', 'opencode', 'opencode.json')
  if (-not (Test-Path -LiteralPath $c -PathType Leaf)) { return $null }
  return (Get-Content -LiteralPath $c -Raw | ConvertFrom-Json)
}

$base = Join-Path ([IO.Path]::GetTempPath()) ('bundle-modes-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
try {
  $bfx = Join-Path $base 'bundle.json'
  Write-Bundle $bfx 'subagent' 'agent-config:canary01'
  $bmode = Join-Path $base 'bundlemode.json'
  Write-Bundle $bmode 'primary' 'agent-config:canary02'

  # --- K1: Canary reports (fixture: 1 agent vs 21 snapshots => DIVERGENT detail).
  $h1 = New-Home $base 'k1'
  $o1 = (& $script:engine -NoProfile -File $installer -TargetHome $h1 -Runtime V2 -BundleMode Canary -BundlePath $bfx 2>&1)
  $m1 = Read-Manifest $h1
  Assert-B (($LASTEXITCODE -eq 0) -and (($o1 -join "`n") -match 'bundle-canary') -and ($m1.bundle_canary.code -ceq 'BUNDLE_OK') -and ($m1.bundle_canary.verdict -ceq 'DIVERGENT') -and ($null -ne $m1.bundle_canary.file_sha256) -and ((@($m1.bundle_canary.divergent) | Where-Object { $_ -match 'absent-from-bundle' }).Count -ge 1)) 'K1 canary reports divergent + digest' ($o1 | Select-Object -Last 1)

  # --- K3: Both + bundle mode => exit 2 before any provisioning.
  # Profiles resolve via -ProfileRoot (never TargetHome): isolate it in TEMP.
  $h3b = New-Home $base 'k3b'
  $prof3b = Join-Path $base 'k3bprof'
  $o3b = (& $script:engine -NoProfile -File $installer -TargetHome $h3b -Runtime Both -ProfileRoot $prof3b -BundleMode Active -BundlePath $bfx 2>&1)
  Assert-B (($LASTEXITCODE -eq 2) -and (($o3b -join "`n") -match 'Both') -and (-not (Test-Path -LiteralPath $prof3b)) -and ($null -eq (Read-Manifest $h3b))) 'K3 Both+bundle refused clean' ($o3b | Select-Object -Last 1)
  # --- K3b: lowercase 'both' also refused (case-insensitive gate).
  $h3c = New-Home $base 'k3c'
  $prof3c = Join-Path $base 'k3cprof'
  $o3c = (& $script:engine -NoProfile -File $installer -TargetHome $h3c -Runtime both -ProfileRoot $prof3c -BundleMode shadow -BundlePath $bfx 2>&1)
  Assert-B (($LASTEXITCODE -eq 2) -and (-not (Test-Path -LiteralPath $prof3c)) -and ($null -eq (Read-Manifest $h3c))) 'K3b lowercase both refused clean' ($o3c | Select-Object -Last 1)

  # --- K4: permission order inversion is DIVERGENT (order-sensitive compare).
  $tmplRaw = Get-Content -LiteralPath (Join-Path $repo 'templates\opencode.v2.json.tmpl') -Raw | ConvertFrom-Json
  $bperms = @($tmplRaw.agents.build.permissions)
  [array]::Reverse($bperms)
  $bobj = [ordered]@{
    schema = 'agent-profile-bundle/v1'; bundle_id = 'agent-config:order01'
    source_repository = 'kust-projetos/agent-config'; source_commit_sha = 'e' * 40
    target_runtime = 'opencode-v2'
    compatibility = [ordered]@{ dialect = 'v2'; minimum_capabilities = @('agents', 'permissions') }
    policy_refs = [ordered]@{ agent_profiles = 'p'; native_permissions = 'n'; risk_requirements = 'r'; capability_catalog = 'c' }
    agent_profiles = @(
      [ordered]@{ agent_id = 'build'; mode = 'primary'; native_permissions = @($bperms | ForEach-Object { [ordered]@{ action = [string]$_.action; resource = [string]$_.resource; effect = [string]$_.effect } }) })
    managed_paths = @([ordered]@{ resource = 'AGENTS.md'; namespace = 'agent-config:global'; owner = 'agent-config' })
    legacy_compatibility = [ordered]@{ v1_mutation = $false }
    format_version = 1
  }
  $bcanon = Get-ConsumerCanonicalJson -Bundle $bobj
  $bdig = Get-ConsumerDigest -CanonicalJson $bcanon
  $bfxOrd = Join-Path $base 'bundleord.json'
  Write-Utf8 $bfxOrd (($bcanon.TrimEnd('}')) + ',"payload_digest":"' + $bdig + '"}')
  $hOrd = New-Home $base 'kord'
  $oOrd = (& $script:engine -NoProfile -File $installer -TargetHome $hOrd -Runtime V2 -BundleMode Canary -BundlePath $bfxOrd 2>&1)
  $mOrd = Read-Manifest $hOrd
  Assert-B (($LASTEXITCODE -eq 0) -and ($mOrd.bundle_canary.verdict -ceq 'DIVERGENT') -and ((@($mOrd.bundle_canary.divergent) -contains 'build'))) 'K4 order inversion divergent' ($oOrd | Select-Object -Last 1)

  # --- K2: Canary missing file => reported, exit 0.
  $h2 = New-Home $base 'k2'
  $o2 = (& $script:engine -NoProfile -File $installer -TargetHome $h2 -Runtime V2 -BundleMode Canary -BundlePath (Join-Path $base 'absent.json') 2>&1)
  Assert-B (($LASTEXITCODE -eq 0) -and (($o2 -join "`n") -match 'BUNDLE_UNAVAILABLE')) 'K2 canary missing reported' ($o2 | Select-Object -Last 1)

  # --- A1: Active sources coder permissions from bundle.
  $h3 = New-Home $base 'a1'
  $o3 = (& $script:engine -NoProfile -File $installer -TargetHome $h3 -Runtime V2 -BundleMode Active -BundlePath $bfx 2>&1)
  $c3 = Read-InstalledCfg $h3
  $m3 = Read-Manifest $h3
  $cp = @($c3.agents.coder.permissions | ForEach-Object { $_.action + '|' + $_.resource + '|' + $_.effect })
  $rp = @($c3.agents.reviewer.permissions | ForEach-Object { $_.action + '|' + $_.resource + '|' + $_.effect })
  Assert-B (($LASTEXITCODE -eq 0) -and (($cp -join ',') -ceq 'edit|*|deny') -and (($rp -join ',') -ceq 'subagent|*|deny') -and ($m3.bundle_active.agents -eq 1) -and ($m3.bundle_active.code -ceq 'BUNDLE_OK')) 'A1 active sources bundle permissions' ($o3 | Select-Object -Last 1)

  # --- A2: Active mode mismatch => exit 2, nothing written.
  $h4 = New-Home $base 'a2'
  $o4 = (& $script:engine -NoProfile -File $installer -TargetHome $h4 -Runtime V2 -BundleMode Active -BundlePath $bmode 2>&1)
  Assert-B (($LASTEXITCODE -eq 2) -and (($o4 -join "`n") -match 'DIVERGENT') -and ($null -eq (Read-InstalledCfg $h4))) 'A2 mode mismatch refused clean' ($o4 | Select-Object -Last 1)

  # --- A3: Active on Config-owned home => exit 3.
  $h5 = New-Home $base 'a3'
  Write-Utf8 (Join-Under $h5 @('.config', 'opencode', 'AGENTS.md')) "<!-- agent-config:global:start -->`n# G`n<!-- agent-config:global:end -->`n"
  $o5 = (& $script:engine -NoProfile -File $installer -TargetHome $h5 -Runtime V2 -BundleMode Active -BundlePath $bfx 2>&1)
  Assert-B (($LASTEXITCODE -eq 3)) 'A3 owned home refused' ($o5 | Select-Object -Last 1)

  # --- A4: Active invalid bundle => exit 2.
  $h6 = New-Home $base 'a4'
  $bad = Join-Path $base 'bad.json'
  Write-Utf8 $bad '{"nope":true}'
  $o6 = (& $script:engine -NoProfile -File $installer -TargetHome $h6 -Runtime V2 -BundleMode Active -BundlePath $bad 2>&1)
  Assert-B (($LASTEXITCODE -eq 2) -and ($null -eq (Read-InstalledCfg $h6))) 'A4 invalid bundle refused clean' ($o6 | Select-Object -Last 1)

  # --- A5: Active V1 => exit 3.
  $h7 = New-Home $base 'a5'
  $o7 = (& $script:engine -NoProfile -File $installer -TargetHome $h7 -Runtime V1 -BundleMode Active -BundlePath $bfx 2>&1)
  Assert-B (($LASTEXITCODE -eq 3)) 'A5 V1 refused' ($o7 | Select-Object -Last 1)
}
finally {
  if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f $total, $passed, ($total - $passed))
if ($passed -ne $total) { exit 1 }
exit 0
