$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Assert([bool]$Condition, [string]$Name) {
  if ($Condition) { $script:pass++; Write-Host "PASS $Name" }
  else { $script:fail++; Write-Host "FAIL $Name" }
}
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installer = Join-Path $repo 'install.ps1'
$utf8 = New-Object Text.UTF8Encoding $false
function P([string]$targetHome, [string]$relative) { Join-Path (Join-Path $targetHome '.config\opencode') $relative }
function Write-Text([string]$path, [string]$text) {
  $parent = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  [IO.File]::WriteAllText($path, $text, $script:utf8)
}
function Invoke-Install([string]$targetHome, [string[]]$extra = @()) {
  $engine = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
  $output = & $engine -NoProfile -ExecutionPolicy Bypass -File $script:installer -TargetHome $targetHome -Runtime V2 @extra 2>&1
  return @{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}
function New-Home([string]$name) {
  $targetHome = Join-Path ([IO.Path]::GetTempPath()) ('clean-reinstall-' + $name + '-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $targetHome -Force | Out-Null
  return $targetHome
}
function Remove-Home([string]$targetHome) { if (Test-Path -LiteralPath $targetHome) { Remove-Item -LiteralPath $targetHome -Recurse -Force -ErrorAction SilentlyContinue } }
function Read-Manifest([string]$targetHome) { Get-Content -LiteralPath (Join-Path $targetHome '.opencode-orchestration\manifest.json') -Raw | ConvertFrom-Json }

# Config-owned install, Agent Config sync, and stable clean reinstall are one E2E lifecycle.
$h = New-Home 'owned'
try {
  $global = "<!-- agent-config:global:start -->`n# External global rules`n<!-- agent-config:global:end -->`n"
  Write-Text (P $h 'AGENTS.md') $global
  $permissions = @(@{ action = 'shell'; resource = 'custom'; effect = 'allow' })
  $json = @{ permissions = $permissions; plugins = @('external') } | ConvertTo-Json -Depth 10
  Write-Text (P $h 'opencode.json') $json
  $permissionsBytes = ((Get-Content -LiteralPath (P $h 'opencode.json') -Raw | ConvertFrom-Json).permissions | ConvertTo-Json -Compress -Depth 10)
  $r = Invoke-Install $h
  $profiles = @(Get-ChildItem -LiteralPath (P $h 'agents') -Filter '*.md' -File)
  $cfg = Get-Content -LiteralPath (P $h 'opencode.json') -Raw | ConvertFrom-Json
  Assert (($r.Code -eq 0) -and ($profiles.Count -eq 19) -and ($null -ne $cfg.agents.build.model)) 'INSTALL_WITH_AGENT_CONFIG: 19 profiles and build model'
  $permissionsAfter = ((Get-Content -LiteralPath (P $h 'opencode.json') -Raw | ConvertFrom-Json).permissions | ConvertTo-Json -Compress -Depth 10)
  Assert (([IO.File]::ReadAllText((P $h 'AGENTS.md'), [Text.Encoding]::UTF8) -ceq $global) -and ($permissionsAfter -ceq $permissionsBytes)) 'INSTALL_WITH_AGENT_CONFIG: global and permissions bytes preserved'
  Write-Text (P $h 'agents\coder.md') '# External Agent Config sync'
  Write-Text (P $h 'AGENTS.md') ($global + "# synchronized outside global`n")
  $r = Invoke-Install $h
  Assert (($r.Code -eq 0) -and ((Get-Content -LiteralPath (P $h 'agents\coder.md') -Raw) -notmatch 'External Agent Config sync') -and ((Get-Content -LiteralPath (P $h 'agents\coder.md') -Raw) -match 'model: openai/gpt-6-luna')) 'AGENT_CONFIG_SYNC_AFTER: canonical profile restored'
  Assert ((Get-Content -LiteralPath (P $h 'AGENTS.md') -Raw).Contains($global.TrimEnd("`n"))) 'AGENT_CONFIG_SYNC_AFTER: global block preserved'
  $manifestPath = Join-Path $h '.opencode-orchestration\manifest.json'
  $manifest = Read-Manifest $h
  $stale = P $h 'agents\legacy-agent.md'; Write-Text $stale 'legacy bytes'
  $manifest.managed_files = @($manifest.managed_files) + @(@{ relative = 'agents\legacy-agent.md'; sha256 = (Get-FileHash $stale -Algorithm SHA256).Hash.ToLowerInvariant() })
  Write-Text $manifestPath ($manifest | ConvertTo-Json -Depth 32)
  $beforeBackup = @(Get-ChildItem -LiteralPath (P $h 'backups') -Directory -ErrorAction SilentlyContinue).Count
  $r = Invoke-Install $h @('-Clean', '-WhatIf')
  Assert (($r.Code -eq 0) -and ($r.Text -match '\[REMOVE\].*legacy-agent') -and (Test-Path $stale) -and (@(Get-ChildItem -LiteralPath (P $h 'backups') -Directory -ErrorAction SilentlyContinue).Count -eq $beforeBackup)) 'CLEAN_WHATIF: reports removal without mutation or backup'
  $r = Invoke-Install $h @('-Clean')
  $manifest = Read-Manifest $h
  $backup = @(Get-ChildItem -LiteralPath (P $h 'backups') -Recurse -File -Filter 'legacy-agent.md' -ErrorAction SilentlyContinue)
  Assert (($r.Code -eq 0) -and (-not (Test-Path $stale)) -and ($backup.Count -gt 0) -and (@($manifest.clean.removed | Where-Object { $_ -eq 'agents\legacy-agent.md' }).Count -gt 0)) 'CLEAN_REMOVES_OBSOLETE: removed, backed up, recorded'
  $hashes = @{}; foreach ($f in @(Get-ChildItem -LiteralPath (P $h 'agents') -Filter '*.md' -File)) { $hashes[$f.Name] = (Get-FileHash $f.FullName -Algorithm SHA256).Hash }
  $r = Invoke-Install $h @('-Clean')
  $stable = $true; foreach ($f in @(Get-ChildItem -LiteralPath (P $h 'agents') -Filter '*.md' -File)) { if ($hashes[$f.Name] -ne (Get-FileHash $f.FullName -Algorithm SHA256).Hash) { $stable = $false } }
  Assert (($r.Code -eq 0) -and ($r.Text -match 'INSTALLED=0') -and ($r.Text -notmatch '\[REMOVE\]') -and $stable -and ($hashes.Count -eq 19)) 'SECOND_INSTALL_UNCHANGED: clean idempotent and profiles stable'
  Assert (($r.Text -match 'RESULT: INSTALLED=') -and ($r.Text -match '\[STATE\].*agents') -and ($r.Text -match '\[STATE\].*config') -and ($r.Text -match '\[STATE\].*plugin') -and ($r.Text -match '\[STATE\].*skills') -and ($r.Text -match '\[STATE\].*AGENTS\.md') -and ((Read-Manifest $h).validation.functional_delegation -ceq 'NOT_RUN')) 'VALIDATION_RESULT: summary, states, and NOT_RUN recorded'
}
finally { Remove-Home $h }

# External namespaces survive clean; rollback restores the stale owned file and exact old manifest.
$h = New-Home 'rollback'
try {
  $r = Invoke-Install $h
  Assert ($r.Code -eq 0) 'PRESERVES_EXTERNAL fixture install'
  Write-Text (P $h 'mcp\custom.json') '{"external":true}'
  Write-Text (P $h 'plugins\third-party.js') 'third party'
  Write-Text (P $h 'skills\third-party\SKILL.md') '# third party'
  $stale = P $h 'agents\legacy-agent.md'; Write-Text $stale 'legacy restore'
  $mp = Join-Path $h '.opencode-orchestration\manifest.json'; $m = Read-Manifest $h
  $m.managed_files = @($m.managed_files) + @(@{ relative = 'agents\legacy-agent.md'; sha256 = (Get-FileHash $stale -Algorithm SHA256).Hash.ToLowerInvariant() })
  Write-Text $mp ($m | ConvertTo-Json -Depth 32)
  $r = Invoke-Install $h @('-Clean')
  Assert (($r.Code -eq 0) -and (Test-Path (P $h 'mcp\custom.json')) -and (Test-Path (P $h 'plugins\third-party.js')) -and (Test-Path (P $h 'skills\third-party\SKILL.md'))) 'PRESERVES_EXTERNAL: custom namespaces survive clean'
}
finally { Remove-Home $h }

$h = New-Home 'clean-rollback'
try {
  $r = Invoke-Install $h
  $stale = P $h 'agents\legacy-agent.md'; Write-Text $stale 'rollback exact bytes'
  $mp = Join-Path $h '.opencode-orchestration\manifest.json'; $m = Read-Manifest $h
  $m.managed_files = @($m.managed_files) + @(@{ relative = 'agents\legacy-agent.md'; sha256 = (Get-FileHash $stale -Algorithm SHA256).Hash.ToLowerInvariant() })
  Write-Text $mp ($m | ConvertTo-Json -Depth 32)
  $manifestBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mp))
  $r = Invoke-Install $h @('-Clean', '-InjectFailureAfter', 'apply-last')
  Assert (($r.Code -eq 5) -and ($r.Text -match 'ROLLBACK_COMPLETED') -and (Test-Path $stale) -and ([Convert]::ToBase64String([IO.File]::ReadAllBytes($mp)) -ceq $manifestBefore)) 'ROLLBACK_CLEAN: exit 5, restored stale bytes and original manifest'
}
finally { Remove-Home $h }

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f ($pass + $fail), $pass, $fail)
if ($fail -gt 0) { exit 1 }; exit 0
