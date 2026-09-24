<#!
.SYNOPSIS
    Pipeline CI do pacote (steps 4-8 do ci.yml): fixture, fresh install,
    idempotencia, preservacao, rollback, uninstall. PS 5.1 compativel.
.DESCRIPTION
    Extraido do .github/workflows/ci.yml para que actionlint valide o
    workflow (steps.shell nao aceita contexts/expressoes). Cada job do CI
    (ps51/pwsh) so invoca este script. Exit 0 = todos os asserts OK; 1 = falha.
#>
param(
  [string]$BaseDir = ''
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = $env:RUNNER_TEMP }
if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = $env:TEMP }
if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = [IO.Path]::GetTempPath() }
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($PSVersionTable.PSEdition -eq 'Core') { $engine = 'pwsh' } else { $engine = 'powershell' }

$script:nOk = 0
$script:nBad = 0
function Assert-Ok([string]$Name) {
  $script:nOk += 1
  Write-Host ('[OK] ' + $Name)
}
function Assert-Fail([string]$Name, [string]$Detail) {
  $script:nBad += 1
  $line = '[FAIL] ' + $Name
  if (-not [string]::IsNullOrWhiteSpace($Detail)) { $line = $line + ' -- ' + $Detail }
  Write-Host $line
}
function Check($Cond, [string]$Name, [string]$Detail) {
  if ($Cond) { Assert-Ok $Name }
  else { Assert-Fail $Name $Detail }
}

$fixture = Join-Path $BaseDir 'oo-home'
$modelsBackup = $null
$modelsPath = Join-Path $RepoRoot 'models.jsonc'
try {
  if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
  New-Item -ItemType Directory -Path $fixture -Force | Out-Null
  Check ($true) 'fixture temp home criado' $fixture
  if (Test-Path -LiteralPath $modelsPath -PathType Leaf) {
    $modelsBackup = [IO.File]::ReadAllText($modelsPath, [Text.Encoding]::UTF8)
  }
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'models.example.jsonc') -Destination $modelsPath -Force
  Check ($true) 'models.jsonc do example' ''

  & $engine -NoProfile -NoLogo -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'install.ps1') -TargetHome $fixture
  $c0 = $LASTEXITCODE
  Check ($c0 -eq 0) 'fresh install exit 0' ('exit ' + $c0)
  $oc = Join-Path $fixture '.config\opencode'
  $agentsMd = Join-Path $oc 'AGENTS.md'
  $jsonPath = Join-Path $oc 'opencode.json'
  $manifest = Join-Path $fixture '.opencode-orchestration\manifest.json'
  $plugin = Join-Path $oc 'plugins\orchestration-enforcement.ts'
  $allExist = $true
  foreach ($p in @($agentsMd, $jsonPath, $manifest, $plugin)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $allExist = $false }
  }
  Check $allExist 'fresh install arquivos existem' 'AGENTS.md/opencode.json/manifest/plugin'
  $nAgents = @(Get-ChildItem -File (Join-Path $oc 'agents\*.md') -ErrorAction SilentlyContinue).Count
  Check ($nAgents -eq 19) 'fresh install 19 agents' ('achado ' + $nAgents)
  $noModel = $false
  try {
    $cfg = (Get-Content -LiteralPath $jsonPath -Raw) | ConvertFrom-Json
    $noModel = (($cfg.agent.build | Get-Member -Name 'model' -ErrorAction SilentlyContinue) -eq $null)
  }
  catch { $noModel = $false }
  Check $noModel 'build sem model (heranca de sessao)' ''
  $mkOk = $false
  try {
    $t = [IO.File]::ReadAllText($agentsMd, [Text.Encoding]::UTF8)
    $cS = ([regex]::Matches($t, [regex]::Escape('<!-- opencode-orchestration:start -->'))).Count
    $cE = ([regex]::Matches($t, [regex]::Escape('<!-- opencode-orchestration:end -->'))).Count
    $mkOk = (($cS -eq 1) -and ($cE -eq 1))
  }
  catch { $mkOk = $false }
  Check $mkOk 'markers AGENTS.md 1/1' ''
  $maniOk = ((Test-Path -LiteralPath $manifest -PathType Leaf) -and (Test-Path -LiteralPath $plugin -PathType Leaf))
  Check $maniOk 'manifest+plugin presentes' ''

  $cfg = (Get-Content -LiteralPath $jsonPath -Raw) | ConvertFrom-Json
  $srv = New-Object PSObject
  $srv | Add-Member -NotePropertyName 'command' 'my-server-cmd' -Force
  $srv | Add-Member -NotePropertyName 'args' @('--flag') -Force
  $mcp = New-Object PSObject
  $mcp | Add-Member -NotePropertyName 'my-server' $srv -Force
  $cfg | Add-Member -NotePropertyName 'mcp' $mcp -Force
  $custom = New-Object PSObject
  $custom | Add-Member -NotePropertyName 'mode' 'subagent' -Force
  $custom | Add-Member -NotePropertyName 'model' 'my-org/my-model' -Force
  $cfg.agent | Add-Member -NotePropertyName 'my-custom-agent' $custom -Force
  $cfg.plugin = @($cfg.plugin) + @('file://./my-custom-plugin.ts')
  $text = (($cfg | ConvertTo-Json -Depth 32).TrimEnd() + "`n")
  [IO.File]::WriteAllText($jsonPath, ($text -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
  Check ($true) 'user config injetada (mcp+custom agent+plugin)' ''

  & $engine -NoProfile -NoLogo -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'install.ps1') -TargetHome $fixture
  $c1 = $LASTEXITCODE
  Check ($c1 -eq 0) '2o install exit 0 (idempotencia)' ('exit ' + $c1)
  $idemOk = $false
  try {
    $t2 = [IO.File]::ReadAllText($agentsMd, [Text.Encoding]::UTF8)
    $s2 = ([regex]::Matches($t2, [regex]::Escape('<!-- opencode-orchestration:start -->'))).Count
    $e2 = ([regex]::Matches($t2, [regex]::Escape('<!-- opencode-orchestration:end -->'))).Count
    $n2 = @(Get-ChildItem -File (Join-Path $oc 'agents\*.md') -ErrorAction SilentlyContinue).Count
    $idemOk = (($s2 -eq 1) -and ($e2 -eq 1) -and ($n2 -eq 19))
  }
  catch { $idemOk = $false }
  Check $idemOk 'idempotencia markers 1/1 + 19 agents' ''

  $presOk = $false
  try {
    $cfg2 = (Get-Content -LiteralPath $jsonPath -Raw) | ConvertFrom-Json
    $presOk = (($cfg2.mcp.'my-server'.command -eq 'my-server-cmd') -and ($cfg2.agent.'my-custom-agent'.model -eq 'my-org/my-model') -and (@($cfg2.plugin) -contains 'file://./my-custom-plugin.ts'))
  }
  catch { $presOk = $false }
  Check $presOk 'preservation mcp+custom agent+plugin' ''

  $hJsonBefore = (Get-FileHash -LiteralPath $jsonPath -Algorithm SHA256).Hash
  $hMdBefore = (Get-FileHash -LiteralPath $agentsMd -Algorithm SHA256).Hash
  & $engine -NoProfile -NoLogo -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'install.ps1') -TargetHome $fixture -InjectFailureAfter apply-json
  $cRb = $LASTEXITCODE
  Check ($cRb -eq 5) 'rollback exit 5' ('exit ' + $cRb)
  $rbOk = $false
  try {
    $hJsonAfter = (Get-FileHash -LiteralPath $jsonPath -Algorithm SHA256).Hash
    $hMdAfter = (Get-FileHash -LiteralPath $agentsMd -Algorithm SHA256).Hash
    $rbOk = (($hJsonBefore -eq $hJsonAfter) -and ($hMdBefore -eq $hMdAfter))
  }
  catch { $rbOk = $false }
  Check $rbOk 'rollback hash-compare opencode.json+AGENTS.md' ''

  & $engine -NoProfile -NoLogo -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'uninstall.ps1') -TargetHome $fixture
  $cU = $LASTEXITCODE
  Check ($cU -eq 0) 'uninstall exit 0' ('exit ' + $cU)
  $leftAgents = @(Get-ChildItem -File (Join-Path $oc 'agents\*.md') -ErrorAction SilentlyContinue).Count
  Check ($leftAgents -eq 0) 'uninstall remove managed agents' ('restaram ' + $leftAgents)
  Check (-not (Test-Path -LiteralPath $plugin -PathType Leaf)) 'uninstall remove plugin gerenciado' ''
  Check (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) 'uninstall remove manifest' ''
  $blockGone = $true
  if (Test-Path -LiteralPath $agentsMd -PathType Leaf) {
    $tu = [IO.File]::ReadAllText($agentsMd, [Text.Encoding]::UTF8)
    $blockGone = (-not $tu.Contains('opencode-orchestration:start'))
  }
  Check $blockGone 'uninstall remove bloco markered AGENTS.md' ''
  $ownOk = $false
  try {
    $kept = Test-Path -LiteralPath $jsonPath -PathType Leaf
    $cfgU = (Get-Content -LiteralPath $jsonPath -Raw) | ConvertFrom-Json
    $ownOk = ($kept -and ($cfgU.mcp.'my-server'.command -eq 'my-server-cmd') -and ($cfgU.agent.'my-custom-agent'.model -eq 'my-org/my-model'))
  }
  catch { $ownOk = $false }
  Check $ownOk 'uninstall ownership-only (opencode.json+mcp+custom agent do usuario)' ''
}
finally {
  if ($null -ne $modelsBackup) {
    [IO.File]::WriteAllText($modelsPath, $modelsBackup, (New-Object Text.UTF8Encoding $false))
  }
  if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''
Write-Host ('CI-PIPELINE: ' + $script:nOk + ' OK / ' + $script:nBad + ' FAIL')
if ($script:nBad -gt 0) { exit 1 }
exit 0
