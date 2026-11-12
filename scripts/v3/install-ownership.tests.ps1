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
  $cfgWorker = "---`nmode: subagent`nmodel: openai/gpt-6-luna`npermissions: []`n---`n# Agent Config worker`n"
  Write-Utf8 (Oc-File $h2 @('AGENTS.md')) $cfgGlobal
  New-Item -ItemType Directory -Path (Oc-File $h2 @('agents')) -Force | Out-Null
  Write-Utf8 (Oc-File $h2 @('agents', 'coder.md')) $cfgWorker
  Write-Utf8 (Oc-File $h2 @('agents', 'explorer.md')) $cfgWorker
  Write-Utf8 (Oc-File $h2 @('opencode.json')) ((@{ plugin = @('keep-me'); permissions = @(@{ action = 'shell'; resource = 'mine *'; effect = 'allow' }); agents = @{ build = @{ mode = 'primary'; permissions = @(@{ action = 'subagent'; resource = 'x'; effect = 'deny' }) }; coder = @{ mode = 'user-mode'; model = 'user/model'; permissions = @(@{ action = 'shell'; resource = '*'; effect = 'deny' }) } } } | ConvertTo-Json -Depth 10))
  $o2 = Invoke-Install $h2 @()
  Assert-OwnTrue ($LASTEXITCODE -eq 0) 'T2 owned install exit 0' ($o2 | Select-Object -Last 1)
  Assert-OwnTrue (((Get-Content -LiteralPath (Oc-File $h2 @('AGENTS.md')) -Raw) -ceq $cfgGlobal)) 'T2 global text untouched'
  Assert-OwnTrue (((Get-Content -LiteralPath (Oc-File $h2 @('agents', 'coder.md')) -Raw) -ceq $cfgWorker)) 'T2 Agent Config worker file untouched'
  Assert-OwnTrue (((Get-Content -LiteralPath (Oc-File $h2 @('agents', 'explorer.md')) -Raw) -ceq $cfgWorker)) 'T2 second Agent Config worker file untouched'
  $after2 = Get-Content -LiteralPath (Oc-File $h2 @('opencode.json')) -Raw | ConvertFrom-Json
  Assert-OwnTrue ((@($after2.permissions | Where-Object { $_.resource -ceq 'mine *' })).Count -eq 1) 'T2 top-level user permissions intact'
  Assert-OwnTrue ((@($after2.agents.build.permissions | Where-Object { $_.resource -ceq 'x' })).Count -eq 1) 'T2 agents.*.permissions untouched by installer'
  Assert-OwnTrue (($after2.plugin -contains 'keep-me')) 'T2 user plugin key preserved'
  Assert-OwnTrue (($after2.agents.coder.mode -ceq 'user-mode') -and ($after2.agents.coder.model -ceq 'user/model') -and ($after2.agents.coder.permissions[0].effect -ceq 'deny')) 'T2 C-owned worker profile unchanged'
  Assert-OwnTrue (-not (Get-Member -InputObject $after2.agents -Name 'explorer' -ErrorAction SilentlyContinue)) 'T2 missing worker JSON profile not inserted'
  $m2 = Read-Manifest $h2
  Assert-OwnTrue (($null -ne $m2) -and ($m2.config_ownership -ceq 'agent-config') -and ((@($m2.skipped_namespaces)).Count -eq 3)) 'T2 manifest records ownership+skips'
  Assert-OwnTrue (@($m2.skipped_namespaces) -contains 'opencode.json:agents.worker-profiles') 'T2 manifest names skipped JSON worker profiles'
  Assert-OwnTrue (-not (@($m2.managed_config_paths) | Where-Object { $_ -match '^agents\.(coder|explorer)\.' })) 'T2 manifest excludes C-owned worker paths'
  $uninstall2 = Join-Path $repo 'uninstall.ps1'
  $u2 = (& pwsh -NoProfile -File $uninstall2 -TargetHome $h2 -Runtime V2 -WhatIf 2>&1)
  Assert-OwnTrue (($LASTEXITCODE -eq 0) -and (($u2 -join "`n") -notmatch '\[REMOVE\] agents\.(coder|explorer)\.(mode|model|permissions)') -and (($u2 -join "`n") -notmatch '\[REMOVE\] agents\.build\.permissions') -and (($u2 -join "`n") -notmatch '\[REMOVE\] agents\\coder\.md') -and (Test-Path -LiteralPath (Oc-File $h2 @('agents', 'coder.md')))) 'T2 uninstall preview preserves C-owned profiles and permissions'

  # --- T3: idempotent re-install on owned home.
  $before3 = Get-Content -LiteralPath (Oc-File $h2 @('opencode.json')) -Raw
  $o3 = Invoke-Install $h2 @()
  Assert-OwnTrue (($LASTEXITCODE -eq 0) -and (((Get-Content -LiteralPath (Oc-File $h2 @('opencode.json')) -Raw) -ceq $before3))) 'T3 re-install stable' ($o3 | Select-Object -Last 1)

  # --- T4: Orch-then-Config order converges.
  $h4 = New-FixtureHome 'order'
  $o4a = Invoke-Install $h4 @()
  Assert-OwnTrue ($LASTEXITCODE -eq 0) 'T4a standalone first exit 0' ($o4a | Select-Object -Last 1)
  $t4a = Oc-File $h4 @('AGENTS.md')
  $t4cfg = Oc-File $h4 @('opencode.json')
  $t4json = Get-Content -LiteralPath $t4cfg -Raw | ConvertFrom-Json
  $t4json.agents.coder.mode = 'agent-config-mode'
  $t4json.agents.coder.model = 'agent-config/coder-model'
  $t4json.agents.coder.permissions = @(@{ action = 'shell'; resource = '*'; effect = 'deny' })
  Write-Utf8 $t4cfg (($t4json | ConvertTo-Json -Depth 20) + "`n")
  $conv = ((Get-Content -LiteralPath $t4a -Raw) -replace '<!-- opencode-orchestration:start -->', '<!-- agent-config:global:start -->') -replace '<!-- opencode-orchestration:end -->', '<!-- agent-config:global:end -->'
  Write-Utf8 $t4a $conv
  $u4Legacy = (& pwsh -NoProfile -File (Join-Path $repo 'uninstall.ps1') -TargetHome $h4 -Runtime V2 -WhatIf 2>&1)
  Assert-OwnTrue (($LASTEXITCODE -eq 0) -and (($u4Legacy -join "`n") -notmatch '\[REMOVE\] agents\.build\.permissions') -and (($u4Legacy -join "`n") -notmatch '\[REMOVE\] agents\.coder\.(mode|model|permissions)') -and (($u4Legacy -join "`n") -notmatch '\[REMOVE\] agents\\coder\.md')) 'T4 legacy uninstall preserves profiles after Config takes ownership' ($u4Legacy -join "`n")
  $profileBefore4 = ((Get-Content -LiteralPath $t4cfg -Raw | ConvertFrom-Json).agents.coder | ConvertTo-Json -Compress -Depth 8)
  $prePerms = ((Get-Content -LiteralPath (Oc-File $h4 @('opencode.json')) -Raw | ConvertFrom-Json).agents.build.permissions | ConvertTo-Json -Compress)
  $o4b = Invoke-Install $h4 @()
  $profileAfter4 = ((Get-Content -LiteralPath $t4cfg -Raw | ConvertFrom-Json).agents.coder | ConvertTo-Json -Compress -Depth 8)
  $postPerms = ((Get-Content -LiteralPath (Oc-File $h4 @('opencode.json')) -Raw | ConvertFrom-Json).agents.build.permissions | ConvertTo-Json -Compress)
  $m4 = Read-Manifest $h4
  Assert-OwnTrue (($LASTEXITCODE -eq 0) -and ($prePerms -ceq $postPerms) -and ($profileBefore4 -ceq $profileAfter4) -and ($m4.config_ownership -ceq 'agent-config')) 'T4 converges without overwriting Config-owned profile' ($o4b | Select-Object -Last 1)

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

  # --- T8: Config-owned mode omits worker JSON profiles when config is new.
  $h8 = New-FixtureHome 'owned-no-config'
  Write-Utf8 (Oc-File $h8 @('AGENTS.md')) $cfgGlobal
  $t8AgentsDir = Oc-File $h8 @('agents')
  New-Item -ItemType Directory -Path $t8AgentsDir -Force | Out-Null
  $t8SourceAgents = @(Get-ChildItem -LiteralPath (Join-Path $repo 'source\agents') -Filter '*.md' -File)
  foreach ($sourceAgent in $t8SourceAgents) {
    Write-Utf8 (Join-Path $t8AgentsDir $sourceAgent.Name) $cfgWorker
  }
  $o8 = Invoke-Install $h8 @()
  $t8cfg = Oc-File $h8 @('opencode.json')
  $t8json = $null
  if (Test-Path -LiteralPath $t8cfg -PathType Leaf) { $t8json = Get-Content -LiteralPath $t8cfg -Raw | ConvertFrom-Json }
  $t8WorkerFiles = @(Get-ChildItem -LiteralPath $t8AgentsDir -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
  Assert-OwnTrue (($LASTEXITCODE -eq 0) -and ($t8WorkerFiles -eq $t8SourceAgents.Count) -and ($null -ne $t8json) -and (Get-Member -InputObject $t8json.agents -Name 'build' -ErrorAction SilentlyContinue) -and (-not (Get-Member -InputObject $t8json.agents -Name 'coder' -ErrorAction SilentlyContinue)) -and (-not (Get-Member -InputObject $t8json.agents -Name 'researcher' -ErrorAction SilentlyContinue))) 'T8 new Config-owned install uses markdown worker profiles, not JSON mirrors' ($o8 | Select-Object -Last 1)

  # T9: legacy retirement is EOL-independent; stale deletion requires manifest hash proof.
  foreach ($eolName in @('LF','CRLF')) {
    $h9 = New-FixtureHome ('combined-' + $eolName); $nl = "`n"; if ($eolName -eq 'CRLF') { $nl = "`r`n" }
    $bn = '<!-- GENERATED FILE: direct edits will be overwritten. -->' + $nl + '<!-- Canonical source: source/; regenerate with scripts/render-opencode-config.ps1. -->' + $nl + '<!-- This file is active only after scripts/reconcile-opencode-config.ps1 applies it. -->' + $nl + $nl
    $ob = '<!-- opencode-orchestration:start -->' + $nl + 'DIRECT_VERIFIED_MICRO_EDIT_LOW_RISK' + $nl + '<!-- opencode-orchestration:end -->' + $nl
    $personal = '# regra pessoal' + $nl; $cfg = '<!-- agent-config:global:start -->' + $nl + '# Config' + $nl + '<!-- agent-config:global:end -->' + $nl
    $ag = Oc-File $h9 @('AGENTS.md'); Write-Utf8 $ag ($bn + $ob + $bn + $ob + $personal + $cfg)
    $thirdPlugin = Oc-File $h9 @('plugins','terceiro.js'); New-Item -ItemType Directory -Path (Split-Path -Parent $thirdPlugin) -Force | Out-Null; Write-Utf8 $thirdPlugin 'third-party bytes'
    $thirdHash = (Get-FileHash -LiteralPath $thirdPlugin -Algorithm SHA256).Hash
    $config9 = Oc-File $h9 @('opencode.json'); Write-Utf8 $config9 ((@{plugin=@('terceiro-plugin');mcp=@{terceiro=@{type='local';command=@('x')}}} | ConvertTo-Json -Depth 8) + "`n")
    $sd = Oc-File $h9 @('skills','retired-fixture'); New-Item -ItemType Directory -Path $sd -Force | Out-Null
    $owned = Join-Path $sd 'owned.txt'; Write-Utf8 $owned 'owned bytes'; $edited = Join-Path $sd 'edited.txt'; Write-Utf8 $edited 'edited bytes'
    $outside = Oc-File $h9 @('outside-canary.txt'); Write-Utf8 $outside 'outside must survive'; $outsideHash = (Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash
    $nestedDir = Oc-File $h9 @('skills','empty-tree','sub'); New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
    $nestedFile = Join-Path $nestedDir 'file.md'; Write-Utf8 $nestedFile 'nested old file'; $nestedHash = (Get-FileHash -LiteralPath $nestedFile -Algorithm SHA256).Hash
    $siblingA = Oc-File $h9 @('skills','x','a'); $siblingB = Oc-File $h9 @('skills','x','b'); New-Item -ItemType Directory -Path $siblingA,$siblingB -Force | Out-Null
    $siblingFileA = Join-Path $siblingA 'f'; $siblingFileB = Join-Path $siblingB 'g'; Write-Utf8 $siblingFileA 'a'; Write-Utf8 $siblingFileB 'b'
    $siblingHashA = (Get-FileHash -LiteralPath $siblingFileA -Algorithm SHA256).Hash; $siblingHashB = (Get-FileHash -LiteralPath $siblingFileB -Algorithm SHA256).Hash
    $oh = (Get-FileHash -LiteralPath $owned -Algorithm SHA256).Hash
    $md = Join-Path $h9 '.opencode-orchestration'; New-Item -ItemType Directory -Path $md -Force | Out-Null
    $junctionTarget = Join-Path $base ('junction-target-' + $eolName); New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    $junctionFile = Join-Path $junctionTarget 'keep.txt'; Write-Utf8 $junctionFile 'junction target bytes'; $junctionHash = (Get-FileHash -LiteralPath $junctionFile -Algorithm SHA256).Hash
    $junction = Oc-File $h9 @('skills','legacy-link'); $junctionMade = $false
    try { New-Item -ItemType Junction -Path $junction -Target $junctionTarget -ErrorAction Stop | Out-Null; $junctionMade = $true } catch { Write-Host ('[SKIP] junction fixture unavailable: ' + $_.Exception.Message) }
    $entries9 = @(@{relative='skills\retired-fixture\owned.txt';sha256=$oh.ToLowerInvariant()},@{relative='skills\retired-fixture\owned.txt';sha256=$oh.ToLowerInvariant()},@{relative='skills\retired-fixture\edited.txt';sha256=('0'*64)},@{relative='skills\empty-tree\sub\file.md';sha256=$nestedHash},@{relative='skills\x\a\f';sha256=$siblingHashA},@{relative='skills\x\b\g';sha256=$siblingHashB},@{relative='skills\..\outside-canary.txt';sha256=$outsideHash})
    if ($junctionMade) { $entries9 += @{relative='skills\legacy-link\keep.txt';sha256=$junctionHash} }
    Write-Utf8 (Join-Path $md 'manifest.json') (@{managed_files=$entries9} | ConvertTo-Json -Depth 8)
    $run = Invoke-Install $h9 @(); $mf = Read-Manifest $h9
    $backupExists = @(Get-ChildItem -LiteralPath (Oc-File $h9 @('backups')) -Recurse -Filter 'owned.txt' -ErrorAction SilentlyContinue).Count -gt 0
    $jsonAfter = Get-Content -LiteralPath $config9 -Raw | ConvertFrom-Json
    $cleanManaged = @($mf.managed_files | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.sha256) }).Count -eq 0
    $agentText = Get-Content -LiteralPath $ag -Raw
    $cfgAfter = [regex]::Match($agentText, '(?s)<!-- agent-config:global:start -->(.*?)<!-- agent-config:global:end -->').Groups[1].Value -replace "`r`n", "`n" -replace "`r", "`n"
    $cfgExpected = "`n# Config`n"
    $junctionSafe = (-not $junctionMade) -or ((Get-FileHash -LiteralPath $junctionFile -Algorithm SHA256).Hash -ceq $junctionHash)
    if ($junctionMade -and (($run -join "`n") -notmatch '\[PRESERVE\].*reparse point')) { $junctionSafe = $false }
    Assert-OwnTrue (($LASTEXITCODE -eq 0) -and ($agentText -notmatch 'opencode-orchestration:start|GENERATED FILE') -and ($agentText -match 'regra pessoal') -and ($cfgAfter -ceq $cfgExpected) -and (-not (Test-Path $owned)) -and (Test-Path $edited) -and (Test-Path $outside) -and (($run -join "`n") -match '\[PRESERVE\].*outside-canary') -and (-not (Test-Path (Oc-File $h9 @('skills','empty-tree')))) -and (-not (Test-Path (Oc-File $h9 @('skills','x')))) -and $junctionSafe -and $backupExists -and ((Get-FileHash -LiteralPath $thirdPlugin -Algorithm SHA256).Hash -ceq $thirdHash) -and ($jsonAfter.plugin -contains 'terceiro-plugin') -and ($jsonAfter.mcp.terceiro.type -ceq 'local') -and ($jsonAfter.mcp.terceiro.command[0] -ceq 'x') -and $cleanManaged -and ($mf.config_ownership -ceq 'agent-config') -and (@($mf.retired_blocks).Count -gt 0) -and (@($mf.removed_stale).Count -eq 4) -and ($null -ne $mf.ownership)) ('T9 ' + $eolName + ' retirement, pruning and third-party preservation') ($run | Select-Object -Last 1)
    $hfirst = (Get-FileHash -LiteralPath $ag -Algorithm SHA256).Hash; $run2 = Invoke-Install $h9 @()
    Assert-OwnTrue (($LASTEXITCODE -eq 0) -and ((Get-FileHash -LiteralPath $ag -Algorithm SHA256).Hash -ceq $hfirst)) ('T9 ' + $eolName + ' idempotence') ($run2 | Select-Object -Last 1)
  }
  # T10: manifest failure rolls back both changed targets byte-for-byte.
  $h10 = New-FixtureHome 'rollback'; $ag10 = Oc-File $h10 @('AGENTS.md')
  Write-Utf8 $ag10 ($bn + $ob + $personal + $cfg); $d10 = Oc-File $h10 @('skills','old'); New-Item -ItemType Directory -Path $d10 -Force | Out-Null
  $f10 = Join-Path $d10 'restore.txt'; Write-Utf8 $f10 'restore bytes'; $hh10 = (Get-FileHash -LiteralPath $f10 -Algorithm SHA256).Hash
  $m10dir = Join-Path $h10 '.opencode-orchestration'; New-Item -ItemType Directory -Path $m10dir -Force | Out-Null
  $manifest10 = Join-Path $m10dir 'manifest.json'; $manifestText10 = (@{managed_files=@(@{relative='skills\old\restore.txt';sha256=$hh10})} | ConvertTo-Json -Depth 8); Write-Utf8 $manifest10 $manifestText10
  $a10hash = (Get-FileHash -LiteralPath $ag10 -Algorithm SHA256).Hash; $manifestBefore10 = [IO.File]::ReadAllBytes($manifest10); $run10 = Invoke-Install $h10 @('-InjectFailureAfter','manifest')
  $manifestAfter10 = [IO.File]::ReadAllBytes($manifest10); $manifestSame10 = ([Convert]::ToBase64String($manifestBefore10) -ceq [Convert]::ToBase64String($manifestAfter10))
  $backup10 = @(Get-ChildItem -LiteralPath (Oc-File $h10 @('backups')) -Directory -Filter 'oo-*' -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue })
  $hasAgentBackup10 = @($backup10 | Where-Object { $_.Name -eq 'AGENTS.md' }).Count -gt 0; $hasSkillBackup10 = @($backup10 | Where-Object { $_.Name -eq 'restore.txt' }).Count -gt 0
  Assert-OwnTrue (($LASTEXITCODE -eq 5) -and (($run10 -join "`n") -match 'ROLLBACK_COMPLETED') -and ((Get-FileHash -LiteralPath $ag10 -Algorithm SHA256).Hash -ceq $a10hash) -and ((Get-FileHash -LiteralPath $f10 -Algorithm SHA256).Hash -ceq $hh10) -and $manifestSame10 -and $hasAgentBackup10 -and $hasSkillBackup10) 'T10 manifest failure fully rolls back bytes and proves backups' ($run10 | Select-Object -Last 2)

  # T11: injected failure after the final apply operation proves removal rollback.
  $h11 = New-FixtureHome 'apply-last-rollback'; $ag11 = Oc-File $h11 @('AGENTS.md'); Write-Utf8 $ag11 ($bn + $ob + $personal + $cfg)
  $d11 = Oc-File $h11 @('skills','old'); New-Item -ItemType Directory -Path $d11 -Force | Out-Null
  $f11 = Join-Path $d11 'stale.txt'; Write-Utf8 $f11 'stale restore'; $fh11 = (Get-FileHash -LiteralPath $f11 -Algorithm SHA256).Hash
  $m11dir = Join-Path $h11 '.opencode-orchestration'; New-Item -ItemType Directory -Path $m11dir -Force | Out-Null
  Write-Utf8 (Join-Path $m11dir 'manifest.json') (@{managed_files=@(@{relative='skills\old\stale.txt';sha256=$fh11})} | ConvertTo-Json -Depth 8)
  $agentBytes11 = [IO.File]::ReadAllBytes($ag11); $skillBytes11 = [IO.File]::ReadAllBytes($f11)
  $run11 = Invoke-Install $h11 @('-InjectFailureAfter','apply-last')
  $agentRestored11 = [Convert]::ToBase64String($agentBytes11) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($ag11))
  $skillRestored11 = [Convert]::ToBase64String($skillBytes11) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($f11))
  Assert-OwnTrue (($LASTEXITCODE -eq 5) -and (($run11 -join "`n") -match 'ROLLBACK_COMPLETED') -and $agentRestored11 -and $skillRestored11) 'T11 apply-last removal rollback restores exact bytes' ($run11 | Select-Object -Last 2)

  # T12: Agent Config content inside the legacy marker is preserved, not retired or replaced.
  $h12 = New-FixtureHome 'config-in-legacy-marker'; $ag12 = Oc-File $h12 @('AGENTS.md')
  $configLegacyBody = '<!-- GENERATED FILE: direct edits will be overwritten. -->' + "`n" + '<!-- Canonical source: source/; regenerate with scripts/render-agent-config.ps1. -->' + "`n" + 'SINGLE_WORKER: write work must use a worker.' + "`n"
  $personal12 = '# personal outside' + "`n"
  Write-Utf8 $ag12 ('<!-- opencode-orchestration:start -->' + $configLegacyBody + '<!-- opencode-orchestration:end -->' + "`n" + $personal12)
  $legacyBodyBefore12 = $configLegacyBody -replace "`r`n", "`n" -replace "`r", "`n"
  $run12 = Invoke-Install $h12 @(); $exit12 = $LASTEXITCODE; $m12 = Read-Manifest $h12
  $text12 = Get-Content -LiteralPath $ag12 -Raw
  $legacyBodyAfter12 = [regex]::Match($text12, '(?s)<!-- opencode-orchestration:start -->(.*?)<!-- opencode-orchestration:end -->').Groups[1].Value -replace "`r`n", "`n" -replace "`r", "`n"
  $cfg12 = Get-Content -LiteralPath (Oc-File $h12 @('opencode.json')) -Raw | ConvertFrom-Json
  $hasWorker12 = Get-Member -InputObject $cfg12.agents -Name 'coder' -ErrorAction SilentlyContinue
  $agents12 = Oc-File $h12 @('agents')
  $hash12 = (Get-FileHash -LiteralPath $ag12 -Algorithm SHA256).Hash; $run12b = Invoke-Install $h12 @()
  $t12checks = @("exit=$exit12/$LASTEXITCODE", "body=$($legacyBodyAfter12 -ceq $legacyBodyBefore12)", "personal=$($text12 -match 'personal outside')", "agentsDir=$(Test-Path $agents12)", "worker=$(($null -ne $hasWorker12))", "owner=$($m12.config_ownership)/$($m12.ownership.global_text)", "ownerWarn=$(($run12 -join "`n") -match '\[OWNER\]')", "hash=$((Get-FileHash -LiteralPath $ag12 -Algorithm SHA256).Hash -ceq $hash12)")
  Assert-OwnTrue (($exit12 -eq 0) -and ($LASTEXITCODE -eq 0) -and ($legacyBodyAfter12 -ceq $legacyBodyBefore12) -and ($text12 -match 'personal outside') -and (-not (Test-Path $agents12)) -and ($null -eq $hasWorker12) -and ($m12.config_ownership -ceq 'agent-config') -and ($m12.ownership.global_text -ceq 'agent-config') -and (($run12 -join "`n") -match '\[OWNER\] AGENTS\.md:') -and ((Get-FileHash -LiteralPath $ag12 -Algorithm SHA256).Hash -ceq $hash12)) 'T12 Agent Config legacy-marked content preserved and idempotent' ($t12checks -join '; ')

  # T13: remove only the orchestration banner at file start when Config owns global text.
  $h13 = New-FixtureHome 'owned-banner'; $ag13 = Oc-File $h13 @('AGENTS.md')
  $banner13 = '<!-- GENERATED FILE: direct edits will be overwritten. -->' + "`n" + '<!-- Canonical source: source/; regenerate with scripts/render-opencode-config.ps1. -->' + "`n" + '<!-- This file is active only after scripts/reconcile-opencode-config.ps1 applies it. -->' + "`n"
  $caseVariant13 = '<!-- GENERATED FILE: direct edits will be overwritten. -->' + "`n" + '<!-- Canonical SOURCE: source/; regenerate with scripts/render-opencode-config.ps1. -->' + "`n" + '<!-- This file is active only after scripts/reconcile-opencode-config.ps1 Applies It. -->' + "`n"
  $agentBanner13 = '<!-- GENERATED FILE: direct edits will be overwritten. -->' + "`n" + '<!-- Canonical source: source/; regenerate with scripts/render-agent-config.ps1. -->' + "`n"
  $config13 = '<!-- agent-config:global:start -->' + "`n" + $agentBanner13 + '# Canonical Config text' + "`n" + '<!-- agent-config:global:end -->'
  $personal13 = '# personal rule' + "`n"
  Write-Utf8 $ag13 ("`n`n" + $banner13 + "`n" + '# user immediately after banner' + "`n" + $caseVariant13 + '<!-- opencode-orchestration:start -->' + "`n" + 'legacy orchestration content' + "`n" + '<!-- opencode-orchestration:end -->' + "`n" + $config13 + "`n" + $personal13)
  $run13 = Invoke-Install $h13 @(); $exit13 = $LASTEXITCODE; $mf13 = Read-Manifest $h13
  $text13 = Get-Content -LiteralPath $ag13 -Raw
  $configAfter13 = [regex]::Match($text13, '(?s)<!-- agent-config:global:start -->(.*?)<!-- agent-config:global:end -->').Groups[1].Value -replace "`r`n", "`n" -replace "`r", "`n"
  $firstHash13 = (Get-FileHash -LiteralPath $ag13 -Algorithm SHA256).Hash; $run13b = Invoke-Install $h13 @()
  $configExpected13 = "`n" + $agentBanner13 + '# Canonical Config text' + "`n"
  $t13checks = @("exit=$exit13/$LASTEXITCODE", "config=$($configAfter13 -ceq $configExpected13)", "caseVariant=$($text13.Contains($caseVariant13.TrimEnd("`n")))", "agentBanner=$($text13.Contains('render-agent-config.ps1'))", "userAfter=$($text13.Contains('# user immediately after banner'))", "personal=$($text13 -match 'personal rule')", "retired=$(@($mf13.retired_blocks) -join ',')", "hash=$((Get-FileHash -LiteralPath $ag13 -Algorithm SHA256).Hash -ceq $firstHash13)")
  $exactBannerRemaining13 = [regex]::Matches($text13, [regex]::Escape($banner13)).Count
  Assert-OwnTrue (($exit13 -eq 0) -and ($LASTEXITCODE -eq 0) -and ($exactBannerRemaining13 -eq 0) -and ($text13.Contains($caseVariant13.TrimEnd("`n"))) -and ($text13.Contains('render-agent-config.ps1')) -and ($text13.Contains('# user immediately after banner')) -and ($configAfter13 -ceq $configExpected13) -and ($text13 -match 'personal rule') -and ($mf13.config_ownership -ceq 'agent-config') -and (@($mf13.retired_blocks) -contains 'opencode-orchestration-banner') -and (@($mf13.retired_blocks) -contains 'opencode-orchestration') -and ((Get-FileHash -LiteralPath $ag13 -Algorithm SHA256).Hash -ceq $firstHash13)) 'T13 retires only exact orchestration banner and preserves Config/personal content idempotently' ($t13checks -join '; ')
}
finally {
  if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f ($passed + $failed), $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
