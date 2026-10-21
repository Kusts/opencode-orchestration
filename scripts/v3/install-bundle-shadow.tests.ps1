<#!
.SYNOPSIS
    Tests for installer bundle shadow mode (PLAN-ORCH O7.1, report-only).
.DESCRIPTION
    Run: pwsh -NoProfile -File <this-file> (or powershell 5.1). Exit 0/1.
    TEMP homes only; live config never touched. PS 5.1 compatible.
    - S1 Shadow valid bundle => exit 0, parity reported, manifest records.
    - S2 Shadow missing file => BUNDLE_UNAVAILABLE reported, exit 0, no writes beyond normal install.
    - S3 Shadow without -BundlePath => exit 2 usage.
    - S4 Default Off => manifest bundle_shadow null.
    - S5 Shadow writes nothing extra (target bytes identical pre/post).
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installer = Join-Path $repo 'install.ps1'
# Installer subprocesses require pwsh: machine powershell 5.1 lacks Get-FileHash
# (environmental, O0 residual); 5.1 syntax of the suite itself is runner-covered.
$script:engine = 'pwsh'
. (Join-Path $repo (Join-Path 'scripts' (Join-Path 'v3' (Join-Path 'lib' 'AgentProfileBundleConsumer.ps1'))))

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
function Write-ShadowBundle($path) {
  $obj = [ordered]@{
    schema = 'agent-profile-bundle/v1'; bundle_id = 'agent-config:shadow01'
    source_repository = 'kust-projetos/agent-config'; source_commit_sha = 'c' * 40
    target_runtime = 'opencode-v2'
    compatibility = [ordered]@{ dialect = 'v2'; minimum_capabilities = @('agents', 'permissions') }
    policy_refs = [ordered]@{ agent_profiles = 'p'; native_permissions = 'n'; risk_requirements = 'r'; capability_catalog = 'c' }
    agent_profiles = @(
      [ordered]@{ agent_id = 'coder'; mode = 'subagent'; native_permissions = @([ordered]@{ action = 'edit'; resource = '*'; effect = 'deny' }) })
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

$base = Join-Path ([IO.Path]::GetTempPath()) ('bundle-shadow-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
try {
  $bfx = Join-Path $base 'bundle.json'
  Write-ShadowBundle $bfx

  # --- S1: Shadow valid bundle.
  $h1 = New-Home $base 's1'
  $o1 = (& $script:engine -NoProfile -File $installer -TargetHome $h1 -Runtime V2 -BundleMode Shadow -BundlePath $bfx 2>&1)
  $m1 = Read-Manifest $h1
  Assert-B (($LASTEXITCODE -eq 0) -and (($o1 -join "`n") -match 'bundle-shadow') -and ($null -ne $m1) -and ($null -ne $m1.bundle_shadow) -and ($m1.bundle_shadow.code -ceq 'BUNDLE_OK')) 'S1 shadow reports bundle' ($o1 | Select-Object -Last 1)

  # --- S2: Shadow missing file => reported, install still exits 0.
  $h2 = New-Home $base 's2'
  $o2 = (& $script:engine -NoProfile -File $installer -TargetHome $h2 -Runtime V2 -BundleMode Shadow -BundlePath (Join-Path $base 'absent.json') 2>&1)
  $m2 = Read-Manifest $h2
  Assert-B (($LASTEXITCODE -eq 0) -and (($o2 -join "`n") -match 'BUNDLE_UNAVAILABLE') -and ($m2.bundle_shadow.code -ceq 'BUNDLE_UNAVAILABLE')) 'S2 missing bundle reported' ($o2 | Select-Object -Last 1)

  # --- S3: Shadow without path => exit 2 BEFORE any write.
  $h3 = New-Home $base 's3'
  $o3 = (& $script:engine -NoProfile -File $installer -TargetHome $h3 -Runtime V2 -BundleMode Shadow 2>&1)
  $h3files = @(Get-ChildItem (Join-Under $h3 @('.config', 'opencode')) -Recurse -File -ErrorAction SilentlyContinue)
  Assert-B (($LASTEXITCODE -eq 2) -and ($h3files.Count -eq 0)) 'S3 shadow without path refused, nothing written' ($o3 | Select-Object -Last 1)

  # --- S3b: lowercase 'shadow' is accepted as Shadow (no silent Off).
  $h3b = New-Home $base 's3b'
  $o3b = (& $script:engine -NoProfile -File $installer -TargetHome $h3b -Runtime V2 -BundleMode shadow -BundlePath $bfx 2>&1)
  Assert-B (($LASTEXITCODE -eq 0) -and (($o3b -join "`n") -match 'bundle-shadow')) 'S3b lowercase shadow accepted' ($o3b | Select-Object -Last 1)

  # --- S4: Default Off => manifest bundle_shadow null.
  $h4 = New-Home $base 's4'
  $o4 = (& $script:engine -NoProfile -File $installer -TargetHome $h4 -Runtime V2 2>&1)
  $m4 = Read-Manifest $h4
  Assert-B (($LASTEXITCODE -eq 0) -and ($null -eq $m4.bundle_shadow)) 'S4 default off records nothing' ($o4 | Select-Object -Last 1)

  # --- S5: Shadow writes nothing extra (bytes identical pre/post shadow run).
  $h5 = New-Home $base 's5'
  $null = (& $script:engine -NoProfile -File $installer -TargetHome $h5 -Runtime V2 2>&1)
  $preA = Get-Content -LiteralPath (Join-Under $h5 @('.config', 'opencode', 'AGENTS.md')) -Raw
  $preC = Get-Content -LiteralPath (Join-Under $h5 @('.config', 'opencode', 'opencode.json')) -Raw
  $o5 = (& $script:engine -NoProfile -File $installer -TargetHome $h5 -Runtime V2 -BundleMode Shadow -BundlePath $bfx 2>&1)
  Assert-B (($LASTEXITCODE -eq 0) -and (((Get-Content -LiteralPath (Join-Under $h5 @('.config', 'opencode', 'AGENTS.md')) -Raw) -ceq $preA)) -and (((Get-Content -LiteralPath (Join-Under $h5 @('.config', 'opencode', 'opencode.json')) -Raw) -ceq $preC))) 'S5 shadow writes nothing' ($o5 | Select-Object -Last 1)
}
finally {
  if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f $total, $passed, ($total - $passed))
if ($passed -ne $total) { exit 1 }
exit 0
