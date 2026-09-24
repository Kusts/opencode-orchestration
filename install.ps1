<#!
.SYNOPSIS
    Instala o pacote opencode-orchestration de forma transacional e preservadora.
.DESCRIPTION
    P2 (distribution hardening): precheck total antes de qualquer escrita,
    stage directory validado, backup + CAS por arquivo, apply atomico com
    rollback, manifest e plano por recurso no -WhatIf. PS 5.1 compativel:
    sem operador ternario, sem ??, sem Invoke-Expression e sem executar
    codigo vindo de JSON.

    DECISOES DE DESENHO (2.1):
    - As 5 funcoes de merge vivem NESTE arquivo (sem dot-source): instalacao
      em arquivo unico, sem dependencia de resolucao de caminho extra e sem
      risco de carregar codigo inesperado. Merge-ManagedOpencodeConfig
      orquestra Merge-ManagedAgentConfig / Merge-ManagedSkillsConfig /
      Merge-ManagedPluginConfig; Merge-ManagedAgentsMdBlock cuida do AGENTS.md.
    - Auto-criacao de models.jsonc a partir do exemplo foi REMOVIDA: criava
      um write antes da validacao. Ausente/invalido agora falha no PRECHECK
      (exit 3) sem nenhuma escrita.
    - Instalacao da dependencia do plugin (bun/npm) e pos-instalacao
      best-effort, fora da transacao e fora do rollback (efeito externo).
    - Exit codes: 0 ok; 3 falha de precheck (nada escrito); 4 CAS_CONFLICT
      (aborta SEM rollback, nada aplicado); 5 falha no apply (rollback
      tentado).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$RepoRoot,
  [string]$TargetHome,
  [switch]$NoCoreSkills,
  [Parameter(DontShow)]
  [ValidateSet('backup', 'stage', 'apply-half', 'apply-json', 'manifest')]
  [string]$InjectFailureAfter = ''
)

$ErrorActionPreference = 'Stop'

# NOTA test-only: -InjectFailureAfter força falha no ponto indicado para
# exercitar backup/stage/rollback nos testes. Nunca usar em uso real.
# Valores: 'backup' (falha após backup), 'stage' (falha após stage),
# 'apply-half' (falha no meio do apply -> rollback, exit 5),
# 'apply-json' (falha APÓS escrever opencode.json, última etapa -> rollback, exit 5),
# 'manifest' (falha na gravação do manifest -> rollback completo, exit 5).

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($TargetHome)) { $TargetHome = $env:USERPROFILE }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$PackageVersion = '1.0.0-hardening'
$OpenCodePluginSpec = '@opencode-ai/plugin@1.18.31'
$MarkStart = '<!-- opencode-orchestration:start -->'
$MarkEnd = '<!-- opencode-orchestration:end -->'
$ManifestRelPath = '.opencode-orchestration\manifest.json'

# ---- helpers base -----------------------------------------------------------
function Read-Utf8([string]$Path) {
  return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Get-FileHashSafe([string]$Path) {
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
  }
  return $null
}

function Has-Member($Obj, [string]$Name) {
  if ($null -eq $Obj) { return $false }
  return ($null -ne ($Obj | Get-Member -Name $Name -ErrorAction SilentlyContinue))
}

function Set-Prop($Obj, [string]$Name, $Value) {
  $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Remove-Prop($Obj, [string]$Name) {
  if ($null -eq $Obj) { return }
  if ($null -ne $Obj.PSObject.Properties[$Name]) {
    $null = $Obj.PSObject.Properties.Remove($Name)
  }
}

function Convert-Canonical($Value) {
  if ($null -eq $Value) { return 'null' }
  if (($Value -is [array]) -and ($Value.Count -eq 0)) { return '[]' }
  $j = ($Value | ConvertTo-Json -Depth 32 -Compress)
  if ([string]::IsNullOrEmpty($j)) { return '[]' }
  return $j
}

function Strip-JsoncComments([string]$Text) {
  $lines = $Text -split "`n" | Where-Object { $_ -notmatch '^\s*//' }
  return ($lines -join "`n")
}

function Write-FileAtomic([string]$Path, [string]$Text) {
  $script:LastWriteMode = 'atomic'
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $norm = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
  $tmp = Join-Path $parent ('.' + (Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllText($tmp, $norm, (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) {
      $replaceBackup = $tmp + '.bak'
      try {
        [System.IO.File]::Replace($tmp, $Path, $replaceBackup, $false)
      }
      catch {
        $script:LastWriteMode = 'non_atomic_fallback'
        Move-Item -LiteralPath $tmp -Destination $Path -Force
      }
      if (Test-Path -LiteralPath $replaceBackup) {
        Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue
      }
    }
    else {
      [IO.File]::Move($tmp, $Path)
    }
  }
  finally {
    if (($tmp) -and (Test-Path -LiteralPath $tmp)) {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
  }
}

function Remove-OrchestrationBlock([string[]]$Lines) {
  $start = -1
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    if ($Lines[$i] -match '^orchestration:\s*$') { $start = $i; break }
  }
  if ($start -lt 0) { return ($Lines -join "`n") }
  $finish = -1
  for ($j = $start + 1; $j -lt $Lines.Count; $j++) {
    if ($Lines[$j] -match '^---\s*$') { $finish = $j; break }
    if ($Lines[$j] -match '^[A-Za-z_][A-Za-z0-9_]*:') { $finish = $j; break }
  }
  if ($finish -lt 0) { $finish = $Lines.Count }
  $kept = @()
  for ($k = 0; $k -lt $Lines.Count; $k++) {
    if ($k -ge $start -and $k -lt $finish) { continue }
    $kept += $Lines[$k]
  }
  return ($kept -join "`n")
}

function Resolve-Tokens([string]$Text, [string]$Planner, [string]$Cheap, [string]$Strong, [string]$HomeDir, [string]$RepoDir) {
  $r = $Text.Replace('{{MODEL_PLANNER}}', $Planner)
  $r = $r.Replace('{{MODEL_CHEAP}}', $Cheap)
  $r = $r.Replace('{{MODEL_STRONG}}', $Strong)
  $homeSlash = $HomeDir -replace '\\', '/'
  $r = $r.Replace('{{HOME}}', $homeSlash)
  $r = $r.Replace('{{REPO_DIR}}', ($RepoDir -replace '\\', '/'))
  return $r
}

function Count-TokenMarkers([string]$Text) {
  $m = [regex]::Matches($Text, '\{\{[^}]+\}\}')
  return $m.Count
}

# ---- 2.1 funcoes de merge ---------------------------------------------------
function Merge-ManagedAgentsMdBlock([string]$ExistingOrNull, [string]$Content, [string]$Header) {
  $innerNew = ($MarkStart + "`n" + $Content.TrimEnd() + "`n" + $MarkEnd)
  $block = $Header.TrimEnd() + "`n" + $innerNew + "`n"
  if ([string]::IsNullOrEmpty($ExistingOrNull)) {
    return @{ Text = ($block.TrimEnd() + "`n"); Action = 'CREATE' }
  }
  if ($ExistingOrNull.Contains($MarkStart) -and $ExistingOrNull.Contains($MarkEnd)) {
    $pattern = [regex]::Escape($MarkStart) + '[\s\S]*?' + [regex]::Escape($MarkEnd)
    $candidate = [regex]::Replace($ExistingOrNull, $pattern, '__OO_BLOCK__')
    $candidate = $candidate.Replace('__OO_BLOCK__', $innerNew)
    if (-not $candidate.Contains('GENERATED FILE')) {
      $candidate = $Header.TrimEnd() + "`n" + $candidate.TrimStart()
    }
    $candidate = $candidate.TrimEnd() + "`n"
    if ($candidate -eq $ExistingOrNull) { return @{ Text = $candidate; Action = 'SKIP' } }
    return @{ Text = $candidate; Action = 'UPDATE' }
  }
  $candidate = $ExistingOrNull.TrimEnd() + "`n`n" + $block.TrimEnd() + "`n"
  return @{ Text = $candidate; Action = 'UPDATE' }
}

function Set-PropIfDifferent($Obj, [string]$Name, $Value) {
  if (Has-Member $Obj $Name) {
    if ((Convert-Canonical $Obj.$Name) -eq (Convert-Canonical $Value)) { return $false }
  }
  $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
  return $true
}

function Merge-ManagedPermissionTask($AgentNode, $DesiredPermission) {
  $desiredTask = $null
  if (Has-Member $DesiredPermission 'task') {
    $desiredTask = ($DesiredPermission.task | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
  }
  else {
    $desiredTask = ($DesiredPermission | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
  }
  if ((-not (Has-Member $AgentNode 'permission')) -or ($null -eq $AgentNode.permission)) {
    $p = (New-Object PSObject)
    Set-Prop $p 'task' $desiredTask
    Set-Prop $AgentNode 'permission' $p
    return $true
  }
  $p = $AgentNode.permission
  if (($null -eq $p) -or ($null -eq $p.PSObject)) {
    $np = (New-Object PSObject)
    Set-Prop $np 'task' $desiredTask
    Set-Prop $AgentNode 'permission' $np
    return $true
  }
  return (Set-PropIfDifferent $p 'task' $desiredTask)
}

function Merge-ManagedAgentConfig($ExistingAgent, $DesiredAgent) {
  $appliedPaths = New-Object System.Collections.ArrayList
  if ($null -eq $ExistingAgent) {
    $ExistingAgent = (New-Object PSObject)
  }
  foreach ($key in @($DesiredAgent.PSObject.Properties.Name)) {
    $desiredEntry = $DesiredAgent.$key
    if ($key -eq 'build') {
      if (-not (Has-Member $ExistingAgent 'build')) {
        Set-Prop $ExistingAgent 'build' (New-Object PSObject)
      }
      $b = $ExistingAgent.build
      if ($null -eq $b) { $b = (New-Object PSObject); Set-Prop $ExistingAgent 'build' $b }
      if (Set-PropIfDifferent $b 'mode' $desiredEntry.mode) { }
      [void]$appliedPaths.Add('agent.build.mode')
      if (Has-Member $desiredEntry 'permission') {
        Merge-ManagedPermissionTask $b $desiredEntry.permission | Out-Null
        [void]$appliedPaths.Add('agent.build.permission.task')
      }
      Remove-Prop $b 'model'
      [void]$appliedPaths.Add('agent.build.model=ABSENT')
      continue
    }
    if ($key -eq 'title') {
      if (-not (Has-Member $ExistingAgent $key)) {
        Set-Prop $ExistingAgent $key (($desiredEntry | ConvertTo-Json -Depth 32) | ConvertFrom-Json)
      }
      else {
        if (Set-PropIfDifferent $ExistingAgent.$key 'model' $desiredEntry.model) { }
      }
      [void]$appliedPaths.Add('agent.title.model')
      continue
    }
    if (-not (Has-Member $ExistingAgent $key)) {
      Set-Prop $ExistingAgent $key (($desiredEntry | ConvertTo-Json -Depth 32) | ConvertFrom-Json)
    }
    else {
      if (Set-PropIfDifferent $ExistingAgent.$key 'mode' $desiredEntry.mode) { }
      if (Set-PropIfDifferent $ExistingAgent.$key 'model' $desiredEntry.model) { }
      if (Has-Member $desiredEntry 'permission') {
        Merge-ManagedPermissionTask $ExistingAgent.$key $desiredEntry.permission | Out-Null
      }
    }
    [void]$appliedPaths.Add('agent.' + $key + '.mode')
    [void]$appliedPaths.Add('agent.' + $key + '.model')
    [void]$appliedPaths.Add('agent.' + $key + '.permission.task')
  }
  return @{ Agent = $ExistingAgent; ManagedPaths = $appliedPaths }
}

function Merge-ManagedSkillsConfig($Existing, $Desired) {
  $changed = $false
  if (-not (Has-Member $Existing 'skills') -or ($null -eq $Existing.skills)) {
    Set-Prop $Existing 'skills' (($Desired.skills | ConvertTo-Json -Depth 32) | ConvertFrom-Json)
    return @{ Changed = $true; Path = 'skills.paths'; Mode = 'SET_ABSENT_PARENT' }
  }
  if (-not (Has-Member $Existing.skills 'paths') -or ($null -eq $Existing.skills.paths)) {
    Set-Prop $Existing.skills 'paths' $Desired.skills.paths
    return @{ Changed = $true; Path = 'skills.paths'; Mode = 'SET_ABSENT' }
  }
  return @{ Changed = $changed; Path = 'skills.paths'; Mode = 'PRESERVED' }
}

function Merge-ManagedPluginConfig($Existing, $Desired) {
  if (-not (Has-Member $Existing 'plugin')) {
    Set-Prop $Existing 'plugin' @()
    return @{ Changed = $true; Path = 'plugin'; Mode = 'SET_ABSENT_EMPTY' }
  }
  return @{ Changed = $false; Path = 'plugin'; Mode = 'PRESERVED' }
}

function Get-DesiredManagedPaths($Desired) {
  $paths = New-Object System.Collections.ArrayList
  foreach ($top in @('$schema', 'model', 'default_agent', 'subagent_depth')) {
    [void]$paths.Add($top)
  }
  foreach ($key in @($Desired.agent.PSObject.Properties.Name)) {
    if ($key -eq 'build') {
      [void]$paths.Add('agent.build.mode')
      [void]$paths.Add('agent.build.permission.task')
      [void]$paths.Add('agent.build.model=ABSENT')
      continue
    }
    if ($key -eq 'title') { [void]$paths.Add('agent.title.model'); continue }
    [void]$paths.Add('agent.' + $key + '.mode')
    [void]$paths.Add('agent.' + $key + '.model')
    [void]$paths.Add('agent.' + $key + '.permission.task')
  }
  [void]$paths.Add('skills.paths')
  [void]$paths.Add('autoupdate')
  [void]$paths.Add('plugin')
  return $paths
}

function Merge-ManagedOpencodeConfig($Existing, $Desired) {
  $managedPaths = New-Object System.Collections.ArrayList
  foreach ($top in @('$schema', 'model', 'default_agent', 'subagent_depth')) {
    if (Set-PropIfDifferent $Existing $top $Desired.$top) { }
    [void]$managedPaths.Add($top)
  }
  if (-not (Has-Member $Existing 'agent') -or ($null -eq $Existing.agent)) {
    Set-Prop $Existing 'agent' (New-Object PSObject)
  }
  $agentRes = Merge-ManagedAgentConfig $Existing.agent $Desired.agent
  foreach ($p in $agentRes.ManagedPaths) { [void]$managedPaths.Add($p) }
  $skillsRes = Merge-ManagedSkillsConfig $Existing $Desired
  if ($skillsRes.Changed) { [void]$managedPaths.Add($skillsRes.Path) }
  if (-not (Has-Member $Existing 'autoupdate')) {
    Set-Prop $Existing 'autoupdate' $Desired.autoupdate
    [void]$managedPaths.Add('autoupdate')
  }
  $pluginRes = Merge-ManagedPluginConfig $Existing $Desired
  if ($pluginRes.Changed) { [void]$managedPaths.Add($pluginRes.Path) }
  return @{ Config = $Existing; ManagedPaths = $managedPaths }
}

# ---- 2.4 precheck -----------------------------------------------------------
function Validate-Models([string]$ModelsPath) {
  $errs = @()
  if (-not (Test-Path -LiteralPath $ModelsPath -PathType Leaf)) {
    return @{ Ok = $false; Errors = @('models.jsonc ausente: ' + $ModelsPath); Values = $null }
  }
  try {
    $parsed = (Strip-JsoncComments (Read-Utf8 $ModelsPath)) | ConvertFrom-Json
  }
  catch {
    return @{ Ok = $false; Errors = @('models.jsonc nao e JSONC parseavel: ' + $_.Exception.Message); Values = $null }
  }
  foreach ($k in @('planner', 'cheap', 'strong')) {
    if (-not (Has-Member $parsed $k) -or [string]::IsNullOrWhiteSpace([string]$parsed.$k)) {
      $errs += ('models.jsonc: chave "' + $k + '" ausente ou vazia.')
    }
  }
  if ($errs.Count -gt 0) { return @{ Ok = $false; Errors = $errs; Values = $null } }
  return @{ Ok = $true; Errors = @(); Values = $parsed }
}

function Validate-RequiredFiles([string]$Root) {
  $errs = @()
  foreach ($rel in @('source\global\AGENTS.md', 'source\adapters\opencode.md', 'templates\opencode.json.tmpl', 'plugins\orchestration-enforcement.ts')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $rel) -PathType Leaf)) {
      $errs += ('fonte obrigatoria ausente: ' + $rel)
    }
  }
  $agents = @(Get-ChildItem -File (Join-Path $Root 'source\agents\*.md') -ErrorAction SilentlyContinue)
  if ($agents.Count -ne 19) { $errs += ('source\agents: esperado 19 .md, encontrado ' + $agents.Count) }
  foreach ($s in @('dispatching-parallel-agents', 'hybrid-development', 'subagent-driven-development', 'using-superpowers', 'verification-before-completion')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root ('skills-core\' + $s + '\SKILL.md')) -PathType Leaf)) {
      $errs += ('skill-core ausente: ' + $s + '/SKILL.md')
    }
  }
  if ($errs.Count -gt 0) { return @{ Ok = $false; Errors = $errs } }
  return @{ Ok = $true; Errors = @() }
}

function Validate-AgentDefinitions([string]$Root) {
  $errs = @()
  $files = @(Get-ChildItem -File (Join-Path $Root 'source\agents\*.md') -ErrorAction SilentlyContinue)
  foreach ($f in $files) {
    $raw = Read-Utf8 $f.FullName
    if ($raw -notmatch '(?s)^---\s*\r?\n.*?\r?\n---\s*') {
      $errs += ('agent sem frontmatter parseavel: ' + $f.Name)
      continue
    }
    $m = [regex]::Match($raw, '(?s)^---\s*\r?\n(.*?)\r?\n---\s*')
    $fm = $m.Groups[1].Value
    if ($fm -notmatch '(?m)^model:\s*\{\{MODEL_(PLANNER|CHEAP|STRONG)\}\}\s*$') {
      $errs += ('agent sem model token valido: ' + $f.Name)
    }
  }
  if ($errs.Count -gt 0) { return @{ Ok = $false; Errors = $errs } }
  return @{ Ok = $true; Errors = @() }
}

function Validate-Template([string]$Root, [string]$Planner, [string]$Cheap, [string]$Strong) {
  $errs = @()
  $tmplPath = Join-Path $Root 'templates\opencode.json.tmpl'
  if (-not (Test-Path -LiteralPath $tmplPath -PathType Leaf)) {
    return @{ Ok = $false; Errors = @('template ausente'); Desired = $null }
  }
  $resolved = Resolve-Tokens (Read-Utf8 $tmplPath) $Planner $Cheap $Strong $env:USERPROFILE $Root
  try {
    $desired = $resolved | ConvertFrom-Json
  }
  catch {
    return @{ Ok = $false; Errors = @('template nao e JSON valido pos-token: ' + $_.Exception.Message); Desired = $null }
  }
  $agentCount = 0
  if (Has-Member $desired 'agent') {
    $agentCount = @($desired.agent.PSObject.Properties.Name).Count
  }
  if ($agentCount -ne 17) { $errs += ('template: esperado 17 blocos agent, encontrado ' + $agentCount) }
  if (Has-Member $desired.agent 'build') {
    if (Has-Member $desired.agent.build 'model') {
      $errs += 'template: bloco build nao deve conter "model" (DH-03, heranca de sessao).'
    }
  }
  else { $errs += 'template: bloco agent.build ausente.' }
  if ((Count-TokenMarkers $resolved) -ne 0) { $errs += 'template: tokens nao resolvidos apos substituicao.' }
  if ($errs.Count -gt 0) { return @{ Ok = $false; Errors = $errs; Desired = $null } }
  return @{ Ok = $true; Errors = @(); Desired = $desired }
}

function Validate-PluginSource([string]$Root) {
  $p = Join-Path $Root 'plugins\orchestration-enforcement.ts'
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
    return @{ Ok = $false; Errors = @('plugin fonte ausente') }
  }
  $t = Read-Utf8 $p
  if (-not $t.Contains('orchestration-enforcement')) {
    return @{ Ok = $false; Errors = @('plugin fonte sem marker orchestration-enforcement') }
  }
  return @{ Ok = $true; Errors = @() }
}

function Validate-Skills([string]$Root) {
  $errs = @()
  foreach ($s in @('dispatching-parallel-agents', 'hybrid-development', 'subagent-driven-development', 'using-superpowers', 'verification-before-completion')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root ('skills-core\' + $s + '\SKILL.md')) -PathType Leaf)) {
      $errs += ('SKILL.md ausente: ' + $s)
    }
  }
  if ($errs.Count -gt 0) { return @{ Ok = $false; Errors = $errs } }
  return @{ Ok = $true; Errors = @() }
}

function Validate-V3Dependencies([string]$Root) {
  $errs = @()
  foreach ($rel in @(
    'scripts\v3\orchestration-preflight.ps1',
    'scripts\v3\route-accept.ps1',
    'scripts\v3\shadow-route.ps1',
    'scripts\v3\skill-bridge.ps1',
    'scripts\v3\lib\OrchestrationPreflight.ps1',
    'scripts\v3\lib\CapabilityAcceptance.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $rel) -PathType Leaf)) {
      $errs += ('dependencia v3 ausente: ' + $rel)
    }
  }
  if ($errs.Count -gt 0) { return @{ Ok = $false; Errors = $errs } }
  return @{ Ok = $true; Errors = @() }
}

# ---- main -------------------------------------------------------------------
$ocDir = Join-Path $TargetHome '.config\opencode'
$modelsPath = Join-Path $RepoRoot 'models.jsonc'

$preErrors = New-Object System.Collections.ArrayList

$modelsRes = Validate-Models $modelsPath
if (-not $modelsRes.Ok) { foreach ($e in $modelsRes.Errors) { [void]$preErrors.Add($e) } }

$reqRes = Validate-RequiredFiles $RepoRoot
if (-not $reqRes.Ok) { foreach ($e in $reqRes.Errors) { [void]$preErrors.Add($e) } }

$defsRes = Validate-AgentDefinitions $RepoRoot
if (-not $defsRes.Ok) { foreach ($e in $defsRes.Errors) { [void]$preErrors.Add($e) } }

$tmplRes = @{ Ok = $false; Errors = @(); Desired = $null }
if ($modelsRes.Ok) {
  $tmplRes = Validate-Template $RepoRoot $modelsRes.Values.planner $modelsRes.Values.cheap $modelsRes.Values.strong
  if (-not $tmplRes.Ok) { foreach ($e in $tmplRes.Errors) { [void]$preErrors.Add($e) } }
}
else {
  [void]$preErrors.Add('template nao validado (modelos invalidos).')
}

$plugRes = Validate-PluginSource $RepoRoot
if (-not $plugRes.Ok) { foreach ($e in $plugRes.Errors) { [void]$preErrors.Add($e) } }

$skillRes = Validate-Skills $RepoRoot
if (-not $skillRes.Ok) { foreach ($e in $skillRes.Errors) { [void]$preErrors.Add($e) } }

$v3Res = Validate-V3Dependencies $RepoRoot
if (-not $v3Res.Ok) { foreach ($e in $v3Res.Errors) { [void]$preErrors.Add($e) } }

if ($preErrors.Count -gt 0) {
  Write-Host 'PRECHECK FAILED (exit 3). Nenhuma escrita realizada.' -ForegroundColor Red
  foreach ($e in $preErrors) { Write-Host ('  - ' + $e) -ForegroundColor Red }
  exit 3
}

$modelPlanner = $modelsRes.Values.planner
$modelCheap = $modelsRes.Values.cheap
$modelStrong = $modelsRes.Values.strong
$desired = $tmplRes.Desired

# Conteudo desejado em memoria (sem writes) -----------------------------------
$header = @'
<!-- GENERATED FILE: direct edits will be overwritten. -->
<!-- Canonical source: source/; regenerate with scripts/render-opencode-config.ps1. -->
<!-- This file is active only after scripts/reconcile-opencode-config.ps1 applies it. -->
'@
$globalBody = Read-Utf8 (Join-Path $RepoRoot 'source\global\AGENTS.md')
$adapterBody = Read-Utf8 (Join-Path $RepoRoot 'source\adapters\opencode.md')
$agentsContent = Resolve-Tokens (($globalBody.TrimEnd() + "`n`n" + $adapterBody.TrimEnd()).TrimEnd() + "`n") $modelPlanner $modelCheap $modelStrong $TargetHome $RepoRoot

$agentsTargetPath = Join-Path $ocDir 'AGENTS.md'
$existingAgentsMd = $null
if (Test-Path -LiteralPath $agentsTargetPath -PathType Leaf) { $existingAgentsMd = Read-Utf8 $agentsTargetPath }
$agentsMdRes = Merge-ManagedAgentsMdBlock $existingAgentsMd $agentsContent $header

$repoEsc = $RepoRoot.Replace('\', '\\')
$agentFiles = @()
foreach ($f in @(Get-ChildItem -File (Join-Path $RepoRoot 'source\agents\*.md') | Sort-Object Name)) {
  $raw = Read-Utf8 $f.FullName
  $raw = $raw.Replace('{{MODEL_PLANNER}}', $modelPlanner)
  $raw = $raw.Replace('{{MODEL_CHEAP}}', $modelCheap)
  $raw = $raw.Replace('{{MODEL_STRONG}}', $modelStrong)
  $raw = $raw.Replace('{{REPO_DIR}}', $repoEsc)
  $raw = $raw.Replace('{{HOME}}', ($TargetHome -replace '\\', '/'))
  $noNl = ($raw -replace "`r`n", "`n" -replace "`r", "`n")
  $clean = Remove-OrchestrationBlock ($noNl -split "`n")
  $agentFiles += @{ Name = $f.Name; Text = ($clean.TrimEnd() + "`n") }
}

$pluginText = Read-Utf8 (Join-Path $RepoRoot 'plugins\orchestration-enforcement.ts')
$pluginDst = Join-Path $ocDir 'plugins\orchestration-enforcement.ts'

$skillsSrc = Join-Path $RepoRoot 'skills-core'
$skillsDst = Join-Path $ocDir 'skills'
$skillNames = @('dispatching-parallel-agents', 'hybrid-development', 'subagent-driven-development', 'using-superpowers', 'verification-before-completion')

$jsonPath = Join-Path $ocDir 'opencode.json'
$existingJsonObj = $null
$existingJsonRaw = $null
if ((Test-Path -LiteralPath $jsonPath -PathType Leaf) -and (-not $NoCoreSkills -or $true)) {
  try {
    $existingJsonRaw = Read-Utf8 $jsonPath
    $existingJsonObj = $existingJsonRaw | ConvertFrom-Json
  }
  catch {
    Write-Host ('PRECHECK FAILED (exit 3): opencode.json existente nao parseia: ' + $_.Exception.Message) -ForegroundColor Red
    exit 3
  }
}
$mergedObj = $null
$managedPaths = @()
$adoptedNow = @()
if ($null -eq $existingJsonObj) {
  $mergedObj = $desired
  $managedPaths = @(Get-DesiredManagedPaths $desired)
  $adoptedNow = @('skills.paths', 'autoupdate', 'plugin')
}
else {
  $hadSkillsPaths = (Has-Member $existingJsonObj 'skills') -and (Has-Member $existingJsonObj.skills 'paths') -and ($null -ne $existingJsonObj.skills.paths)
  $hadAutoupdate = Has-Member $existingJsonObj 'autoupdate'
  $hadPlugin = Has-Member $existingJsonObj 'plugin'
  $clone = ($existingJsonRaw | ConvertFrom-Json)
  $mergeRes = Merge-ManagedOpencodeConfig $clone $desired
  $mergedObj = $mergeRes.Config
  $managedPaths = @(Get-DesiredManagedPaths $desired)
  if (-not $hadSkillsPaths) { $adoptedNow += 'skills.paths' }
  if (-not $hadAutoupdate) { $adoptedNow += 'autoupdate' }
  if (-not $hadPlugin) { $adoptedNow += 'plugin' }
}
$mergedText = (($mergedObj | ConvertTo-Json -Depth 32).TrimEnd() + "`n")

# Plano por recurso ------------------------------------------------------------
$plan = New-Object System.Collections.ArrayList
function Add-Plan([string]$Tag, [string]$Label) {
  [void]$plan.Add('[' + $Tag + '] ' + $Label)
}
function File-Plan([string]$Dst, [string]$DesiredText, [string]$Label) {
  if (-not (Test-Path -LiteralPath $Dst -PathType Leaf)) { Add-Plan 'CREATE' $Label; return }
  $cur = Read-Utf8 $Dst
  $a = ($cur -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd() + "`n"
  $b = ($DesiredText -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd() + "`n"
  if ($a -eq $b) { Add-Plan 'SKIP' ($Label + ' (inalterado)') }
  else { Add-Plan 'UPDATE' $Label }
}
File-Plan $agentsTargetPath $agentsMdRes.Text 'AGENTS.md (bloco markered)'
foreach ($a in $agentFiles) {
  File-Plan (Join-Path $ocDir ('agents\' + $a.Name)) $a.Text ('agents/' + $a.Name)
}
if (-not $NoCoreSkills) {
  foreach ($s in $skillNames) {
    $srcDir = Join-Path $skillsSrc $s
    $dstDir = Join-Path $skillsDst $s
    if (-not (Test-Path -LiteralPath $dstDir)) { Add-Plan 'CREATE' ('skills/' + $s + '/'); continue }
    $diff = $false
    foreach ($sf in @(Get-ChildItem -File $srcDir -Recurse -ErrorAction SilentlyContinue)) {
      $rel = $sf.FullName.Substring($srcDir.Length + 1)
      $dp = Join-Path $dstDir $rel
      if (-not (Test-Path -LiteralPath $dp -PathType Leaf)) { $diff = $true; break }
      if ((Get-FileHashSafe $sf.FullName) -ne (Get-FileHashSafe $dp)) { $diff = $true; break }
    }
    if ($diff) { Add-Plan 'UPDATE' ('skills/' + $s + '/') }
    else { Add-Plan 'SKIP' ('skills/' + $s + '/ (inalterado)') }
  }
}
else {
  foreach ($s in $skillNames) { Add-Plan 'SKIP' ('skills/' + $s + '/ (NoCoreSkills)') }
}
File-Plan $pluginDst $pluginText 'plugins/orchestration-enforcement.ts'
if ($null -eq $existingJsonObj) {
  Add-Plan 'CREATE' 'opencode.json (merged completo)'
}
else {
  $before = $existingJsonObj
  $after = $mergedObj
  foreach ($mp in @('$schema', 'model', 'default_agent', 'subagent_depth', 'autoupdate')) {
    $bv = $null; $av = $null
    if (Has-Member $before $mp) { $bv = Convert-Canonical $before.$mp }
    if (Has-Member $after $mp) { $av = Convert-Canonical $after.$mp }
    if ($bv -ne $av) {
      if ($mp -eq 'autoupdate' -and (-not (Has-Member $before 'autoupdate'))) { Add-Plan 'UPDATE' 'autoupdate (set, estava ausente)' }
      else { Add-Plan 'UPDATE' $mp }
    }
  }
  if (Has-Member $after 'agent') {
    foreach ($ak in @($after.agent.PSObject.Properties.Name)) {
      $isKnown = Has-Member $desired.agent $ak
      if (-not $isKnown) { continue }
      foreach ($leaf in @('mode', 'model', 'permission')) {
        $hasB = (Has-Member $before.agent $ak) -and (Has-Member $before.agent.$ak $leaf)
        $bv = $null
        if ($hasB) { $bv = Convert-Canonical $before.agent.$ak.$leaf }
        $hasA = (Has-Member $after.agent $ak) -and (Has-Member $after.agent.$ak $leaf)
        $av = $null
        if ($hasA) { $av = Convert-Canonical $after.agent.$ak.$leaf }
        if ($ak -eq 'build' -and $leaf -eq 'model') {
          if ($hasB) { Add-Plan 'UPDATE' 'agent.build.model (REMOVIDO, heranca de sessao)' }
          continue
        }
        if ($bv -ne $av) { Add-Plan 'UPDATE' ('agent.' + $ak + '.' + $leaf) }
      }
    }
  }
  if ((Has-Member $before 'skills') -and (Has-Member $before.skills 'paths') -and ($null -ne $before.skills.paths)) {
    Add-Plan 'PRESERVE' 'skills.paths (do usuario)'
  }
  if (Has-Member $before 'mcp') { Add-Plan 'PRESERVE' 'mcp.*' }
  if ((Has-Member $before 'plugin') -and ($null -ne $before.plugin) -and (@($before.plugin).Count -gt 0)) {
    Add-Plan 'PRESERVE' 'plugin (conteudo do usuario, nao vazio)'
  }
  $knownTop = @('$schema', 'model', 'default_agent', 'subagent_depth', 'agent', 'skills', 'plugin', 'autoupdate', 'mcp')
  foreach ($tk in @($before.PSObject.Properties.Name)) {
    if ($knownTop -notcontains $tk) { Add-Plan 'PRESERVE' ($tk + ' (chave de topo desconhecida)') }
  }
  if ((Has-Member $before 'agent') -and ($null -ne $before.agent)) {
    foreach ($ak in @($before.agent.PSObject.Properties.Name)) {
      if (-not (Has-Member $desired.agent $ak)) {
        Add-Plan 'PRESERVE' ('agent.' + $ak + ' (agente desconhecido, intacto)')
        continue
      }
      foreach ($prop in @($before.agent.$ak.PSObject.Properties.Name)) {
        if (@('mode', 'model', 'permission') -notcontains $prop) {
          Add-Plan 'PRESERVE' ('agent.' + $ak + '.' + $prop + ' (propriedade desconhecida)')
        }
      }
    }
  }
  if (Has-Member $before.agent 'build') {
    if (Has-Member $before.agent.build 'model') {
      Add-Plan 'UPDATE' 'agent.build.model (REMOVIDO, heranca de sessao)'
    }
  }
}

$isWhatIf = $false
if ($WhatIfPreference) { $isWhatIf = $true }

if ($isWhatIf) {
  Write-Host '=== INSTALL PLAN (WhatIf, nenhuma escrita) ===' -ForegroundColor Cyan
  foreach ($l in $plan) { Write-Host $l -ForegroundColor DarkGray }
  Write-Host ('Plano: ' + $plan.Count + ' recurso(s). Nenhuma escrita realizada.') -ForegroundColor Cyan
  exit 0
}

# Hashes esperados (PRECHECK) para CAS ------------------------------------------
$expectedHashes = @{}
$destFilesForHash = New-Object System.Collections.ArrayList
[void]$destFilesForHash.Add($agentsTargetPath)
foreach ($a in $agentFiles) { [void]$destFilesForHash.Add((Join-Path $ocDir ('agents\' + $a.Name))) }
if (-not $NoCoreSkills) {
  foreach ($s in $skillNames) {
    $srcDir = Join-Path $skillsSrc $s
    foreach ($sf in @(Get-ChildItem -File $srcDir -Recurse -ErrorAction SilentlyContinue)) {
      $rel = $sf.FullName.Substring($srcDir.Length + 1)
      [void]$destFilesForHash.Add((Join-Path (Join-Path $skillsDst $s) $rel))
    }
  }
}
[void]$destFilesForHash.Add($pluginDst)
[void]$destFilesForHash.Add($jsonPath)
foreach ($d in $destFilesForHash) { $expectedHashes[$d] = Get-FileHashSafe $d }

# Backup -----------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bakDir = Join-Path $ocDir ("backups\oo-" + $stamp)
$backupCount = 0
$backupMap = @{}
try {
  foreach ($d in $destFilesForHash) {
    if (Test-Path -LiteralPath $d -PathType Leaf) {
      $rel = $d.Substring($ocDir.Length + 1)
      $dest = Join-Path $bakDir $rel
      if ($PSCmdlet.ShouldProcess($dest, 'Backup')) {
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $d -Destination $dest -Force
        $backupMap[$d] = $dest
        $backupCount += 1
      }
    }
  }
  if ($backupCount -gt 0) { Write-Host ("Backup: " + $backupCount + " arquivo(s) em " + $bakDir) -ForegroundColor DarkGray }
  if ($InjectFailureAfter -eq 'backup') { throw 'INJECTED_FAILURE_AFTER=backup (test-only)' }

  # Stage ----------------------------------------------------------------------
  $tempBase = $env:TEMP
  if ([string]::IsNullOrWhiteSpace($tempBase)) { $tempBase = [IO.Path]::GetTempPath() }
  $stageDir = Join-Path $tempBase ('opencode-orchestration-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
  try {
    # STAGE CANONICO: todos os stage files passam por Write-FileAtomic
    # (LF, UTF-8 sem BOM). Evita divergencia pos-hash quando o checkout
    # esta em CRLF (core.autocrlf=true): o apply (text round-trip) vira
    # no-op de normalizacao e o hash casa sempre.
    Write-FileAtomic (Join-Path $stageDir 'AGENTS.md') $agentsMdRes.Text
    $stageAgents = Join-Path $stageDir 'agents'
    New-Item -ItemType Directory -Path $stageAgents -Force | Out-Null
    foreach ($a in $agentFiles) {
      Write-FileAtomic (Join-Path $stageAgents $a.Name) $a.Text
    }
    if (-not $NoCoreSkills) {
      $stageSkills = Join-Path $stageDir 'skills'
      foreach ($s in $skillNames) {
        $srcDir = Join-Path $skillsSrc $s
        $dstDir = Join-Path $stageSkills $s
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        foreach ($sf in @(Get-ChildItem -File $srcDir -Recurse -ErrorAction SilentlyContinue)) {
          $rel = $sf.FullName.Substring($srcDir.Length + 1)
          $dp = Join-Path $dstDir $rel
          Write-FileAtomic $dp (Read-Utf8 $sf.FullName)
        }
      }
    }
    $stagePlugins = Join-Path $stageDir 'plugins'
    New-Item -ItemType Directory -Path $stagePlugins -Force | Out-Null
    Write-FileAtomic (Join-Path $stagePlugins 'orchestration-enforcement.ts') $pluginText
    Write-FileAtomic (Join-Path $stageDir 'opencode.json') $mergedText

    # Valida stage
    $stageErrs = @()
    try { (Read-Utf8 (Join-Path $stageDir 'opencode.json')) | ConvertFrom-Json | Out-Null }
    catch { $stageErrs += ('stage opencode.json nao parseia: ' + $_.Exception.Message) }
    $stageAllText = (Read-Utf8 (Join-Path $stageDir 'AGENTS.md')) + "`n" + (Read-Utf8 (Join-Path $stageDir 'opencode.json'))
    foreach ($a in $agentFiles) { $stageAllText += "`n" + $a.Text }
    if ((Count-TokenMarkers $stageAllText) -ne 0) { $stageErrs += 'stage contem tokens {{...}} nao resolvidos.' }
    $stAgents = Read-Utf8 (Join-Path $stageDir 'AGENTS.md')
    $cStart = ([regex]::Matches($stAgents, [regex]::Escape($MarkStart))).Count
    $cEnd = ([regex]::Matches($stAgents, [regex]::Escape($MarkEnd))).Count
    if (($cStart -ne 1) -or ($cEnd -ne 1)) { $stageErrs += ('stage AGENTS.md markers invalidos (start=' + $cStart + ' end=' + $cEnd + ').') }
    if ($stageErrs.Count -gt 0) {
      foreach ($e in $stageErrs) { Write-Host ('STAGE INVALIDO: ' + $e) -ForegroundColor Red }
      throw 'stage validation failed'
    }
    if ($InjectFailureAfter -eq 'stage') { throw 'INJECTED_FAILURE_AFTER=stage (test-only)' }

    # CAS recheck (antes de qualquer apply) ------------------------------------
    $conflicts = @()
    foreach ($d in $destFilesForHash) {
      $now = Get-FileHashSafe $d
      $exp = $expectedHashes[$d]
      if ($exp -ne $now) { $conflicts += $d }
    }
    if ($conflicts.Count -gt 0) {
      Write-Output 'CAS_CONFLICT (exit 4). Destino mudou entre preview e apply. NADA foi aplicado, SEM rollback.'
      foreach ($c in $conflicts) { Write-Output ('  CONFLICT: ' + $c) }
      exit 4
    }

    # Apply --------------------------------------------------------------------
    $ops = New-Object System.Collections.ArrayList
    [void]$ops.Add(@{ Src = (Join-Path $stageDir 'AGENTS.md'); Dst = $agentsTargetPath; Label = 'AGENTS.md' })
    foreach ($a in $agentFiles) {
      [void]$ops.Add(@{ Src = (Join-Path $stageAgents $a.Name); Dst = (Join-Path $ocDir ('agents\' + $a.Name)); Label = ('agents/' + $a.Name) })
    }
    if (-not $NoCoreSkills) {
      $stageSkills = Join-Path $stageDir 'skills'
      foreach ($s in $skillNames) {
        $srcDir = Join-Path $stageSkills $s
        foreach ($sf in @(Get-ChildItem -File $srcDir -Recurse -ErrorAction SilentlyContinue)) {
          $rel = $sf.FullName.Substring($srcDir.Length + 1)
          [void]$ops.Add(@{ Src = $sf.FullName; Dst = (Join-Path (Join-Path $skillsDst $s) $rel); Label = ('skills/' + $s + '/' + $rel) })
        }
      }
    }
    [void]$ops.Add(@{ Src = (Join-Path $stagePlugins 'orchestration-enforcement.ts'); Dst = $pluginDst; Label = 'plugins/orchestration-enforcement.ts' })
    [void]$ops.Add(@{ Src = (Join-Path $stageDir 'opencode.json'); Dst = $jsonPath; Label = 'opencode.json' })

    $applied = New-Object System.Collections.ArrayList
    $halfPoint = [Math]::Floor($ops.Count / 2)
    $idx = 0
    try {
      foreach ($op in $ops) {
        $idx += 1
        $existedBefore = Test-Path -LiteralPath $op.Dst -PathType Leaf
        $origHash = $expectedHashes[$op.Dst]
        if ($null -eq $origHash) { $origHash = Get-FileHashSafe $op.Dst }
        $script:LastWriteMode = 'atomic'
        [void]$applied.Add(@{ Dst = $op.Dst; Src = $op.Src; Label = $op.Label; Existed = $existedBefore; OrigHash = $origHash; Mode = 'pending' })
        $rec = $applied[$applied.Count - 1]
        if ($PSCmdlet.ShouldProcess($op.Dst, 'Apply ' + $op.Label)) {
          Write-FileAtomic $op.Dst (Read-Utf8 $op.Src)
        }
        $rec.Mode = $script:LastWriteMode
        $hSrc = (Get-FileHash -LiteralPath $op.Src -Algorithm SHA256).Hash
        $hDst = Get-FileHashSafe $op.Dst
        if ($hSrc -ne $hDst) { throw ('pos-hash divergente em ' + $op.Label) }
        if ($rec.Mode -eq 'non_atomic_fallback') {
          $hDst2 = Get-FileHashSafe $op.Dst
          if ($hSrc -ne $hDst2) { throw ('pos-hash divergente (non_atomic_fallback) em ' + $op.Label) }
        }
        if (($InjectFailureAfter -eq 'apply-half') -and ($idx -eq $halfPoint)) {
          throw 'INJECTED_FAILURE_AFTER=apply-half (test-only)'
        }
        if (($InjectFailureAfter -eq 'apply-json') -and ($op.Label -eq 'opencode.json')) {
          throw 'INJECTED_FAILURE_AFTER=apply-json (test-only)'
        }
      }
    }
    catch {
      $applyErr = $_.Exception.Message
      Write-Host ('APPLY FALHOU: ' + $applyErr) -ForegroundColor Red
      $failedRestore = @()
      for ($ri = $applied.Count - 1; $ri -ge 0; $ri--) {
        $rec = $applied[$ri]
        try {
          if ($rec.Existed -and $backupMap.ContainsKey($rec.Dst)) {
            Write-FileAtomic $rec.Dst (Read-Utf8 $backupMap[$rec.Dst])
            if (($null -ne $rec.OrigHash) -and ((Get-FileHashSafe $rec.Dst) -ne $rec.OrigHash)) {
              $failedRestore += $rec.Dst
            }
          }
          elseif (-not $rec.Existed) {
            if (Test-Path -LiteralPath $rec.Dst -PathType Leaf) {
              Remove-Item -LiteralPath $rec.Dst -Force
            }
          }
          else {
            $failedRestore += $rec.Dst
          }
        }
        catch {
          $failedRestore += $rec.Dst
        }
      }
      if ($failedRestore.Count -eq 0) {
        Write-Output 'ROLLBACK_COMPLETED'
      }
      else {
        Write-Output 'ROLLBACK_REQUIRED'
        foreach ($f in $failedRestore) { Write-Output ('  nao restaurado: ' + $f) }
      }
      exit 5
    }

    # Manifest (DENTRO da transacao: falha -> rollback completo, exit 5) ------
    $manifestDir = Join-Path $TargetHome '.opencode-orchestration'
    $manifestPath = Join-Path $manifestDir 'manifest.json'
    $manifestExisted = Test-Path -LiteralPath $manifestPath -PathType Leaf
    $manifestOrigHash = Get-FileHashSafe $manifestPath
    $manifestOrigText = $null
    if ($manifestExisted) {
      try { $manifestOrigText = Read-Utf8 $manifestPath } catch { $manifestOrigText = $null }
    }
    try {
      $managedFiles = New-Object System.Collections.ArrayList
      foreach ($op in $ops) {
        $rel = $op.Dst.Substring($ocDir.Length + 1)
        [void]$managedFiles.Add(@{ relative = $rel; sha256 = (Get-FileHashSafe $op.Dst) })
      }
    $rev = 'unknown'
    try {
      Push-Location $RepoRoot
      try {
        $r = (& git rev-parse --short HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and (-not [string]::IsNullOrWhiteSpace($r))) {
          $rev = ([string]$r).Trim()
        }
      }
      finally { Pop-Location }
    }
    catch { $rev = 'unknown' }
    $snapshot = @{}
    foreach ($mp in @(Get-DesiredManagedPaths $desired)) {
      try {
        if ($mp -eq 'agent.build.model=ABSENT') { $snapshot[$mp] = 'ABSENT'; continue }
        $parts = $mp -split '\.'
        $node = $mergedObj
        $okWalk = $true
        foreach ($pp in $parts) {
          if (($null -ne $node) -and (Has-Member $node $pp)) { $node = $node.$pp }
          else { $okWalk = $false; break }
        }
        if ($okWalk) { $snapshot[$mp] = Convert-Canonical $node }
        continue
      }
      catch { }
    }
    $adoptedUnion = @($adoptedNow)
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
      try {
        $oldM = ([IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
        if (($null -ne $oldM) -and (Has-Member $oldM 'adopted_paths') -and ($null -ne $oldM.adopted_paths)) {
          foreach ($p in @($oldM.adopted_paths)) {
            if ($adoptedUnion -notcontains $p) { $adoptedUnion += $p }
          }
        }
      }
      catch { }
    }
    $manifest = [ordered]@{
      package_version = $PackageVersion
      installed_at = (Get-Date).ToString('o')
      source_revision = $rev
      target_home = $TargetHome
      managed_files = @($managedFiles)
      managed_config_paths = @($managedPaths)
      adopted_paths = @($adoptedUnion)
      config_snapshot = $snapshot
      models = [ordered]@{ planner = $modelPlanner; cheap = $modelCheap; strong = $modelStrong }
      plugin_dependency = $OpenCodePluginSpec
    }
    if ($PSCmdlet.ShouldProcess($manifestPath, 'Escrever manifest')) {
      if ($InjectFailureAfter -eq 'manifest') { throw 'INJECTED_FAILURE_AFTER=manifest (test-only)' }
      $mp2 = Split-Path -Parent $manifestPath
      if (-not (Test-Path -LiteralPath $mp2)) { New-Item -ItemType Directory -Path $mp2 -Force | Out-Null }
      $script:LastWriteMode = 'atomic'
      Write-FileAtomic $manifestPath ((($manifest | ConvertTo-Json -Depth 32).TrimEnd()) + "`n")
      $mMode = $script:LastWriteMode
      $mCheck = ([IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
      if ($null -eq $mCheck) { throw 'manifest gravado nao parseia (pos-verificacao)' }
      if ($mMode -eq 'non_atomic_fallback') {
        $mCheck2 = ([IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
        if ($null -eq $mCheck2) { throw 'manifest divergente (non_atomic_fallback)' }
      }
    }
    }
    catch {
      $mErr = $_.Exception.Message
      Write-Host ('MANIFEST FALHOU: ' + $mErr) -ForegroundColor Red
      $failedRestore = @()
      for ($ri = $applied.Count - 1; $ri -ge 0; $ri--) {
        $rec = $applied[$ri]
        try {
          if ($rec.Existed -and $backupMap.ContainsKey($rec.Dst)) {
            Write-FileAtomic $rec.Dst (Read-Utf8 $backupMap[$rec.Dst])
            if (($null -ne $rec.OrigHash) -and ((Get-FileHashSafe $rec.Dst) -ne $rec.OrigHash)) {
              $failedRestore += $rec.Dst
            }
          }
          elseif (-not $rec.Existed) {
            if (Test-Path -LiteralPath $rec.Dst -PathType Leaf) {
              Remove-Item -LiteralPath $rec.Dst -Force
            }
          }
          else {
            $failedRestore += $rec.Dst
          }
        }
        catch {
          $failedRestore += $rec.Dst
        }
      }
      try {
        if ($manifestExisted -and ($null -ne $manifestOrigText)) {
          Write-FileAtomic $manifestPath $manifestOrigText
        }
        elseif (-not $manifestExisted) {
          if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            Remove-Item -LiteralPath $manifestPath -Force
          }
        }
      }
      catch {
        $failedRestore += $manifestPath
      }
      if ($failedRestore.Count -eq 0) {
        Write-Output 'ROLLBACK_COMPLETED'
      }
      else {
        Write-Output 'ROLLBACK_REQUIRED'
        foreach ($f in $failedRestore) { Write-Output ('  nao restaurado: ' + $f) }
      }
      exit 5
    }
  }
  finally {
    if (($stageDir) -and (Test-Path -LiteralPath $stageDir)) {
      Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
catch {
  $msg = $_.Exception.Message
  if ($msg -like 'INJECTED_FAILURE_AFTER=stage*') { Write-Host $msg -ForegroundColor Yellow; exit 5 }
  if ($msg -like 'INJECTED_FAILURE_AFTER=backup*') { Write-Host $msg -ForegroundColor Yellow; exit 5 }
  if ($msg -like 'INJECTED_FAILURE_AFTER=apply-*') { Write-Host $msg -ForegroundColor Yellow; exit 5 }
  if ($msg -like 'INJECTED_FAILURE_AFTER=manifest*') { Write-Host $msg -ForegroundColor Yellow; exit 5 }
  if ($msg -eq 'stage validation failed') { exit 5 }
  Write-Host ('FALHA: ' + $msg) -ForegroundColor Red
  exit 5
}

# Dependencia do plugin (best-effort, fora da transacao) -------------------------
$pluginDep = Join-Path $ocDir 'node_modules\@opencode-ai\plugin'
if (-not (Test-Path -LiteralPath $pluginDep)) {
  $bun = Get-Command 'bun' -ErrorAction SilentlyContinue
  $npm = Get-Command 'npm' -ErrorAction SilentlyContinue
  $installed = $false
  if ($bun -ne $null) {
    if ($PSCmdlet.ShouldProcess($ocDir, 'bun add ' + $OpenCodePluginSpec)) {
      Push-Location $ocDir
      try {
        & bun add $OpenCodePluginSpec
        if ($LASTEXITCODE -eq 0) { $installed = $true } else { Write-Host ("bun add " + $OpenCodePluginSpec + " falhou (exit " + $LASTEXITCODE + "). Tentando npm...") -ForegroundColor Yellow }
      }
      catch {
        Write-Host ("bun add " + $OpenCodePluginSpec + " falhou: " + $_) -ForegroundColor Yellow
      }
      Pop-Location
    }
    else { $installed = $true }
  }
  if ((-not $installed) -and ($npm -ne $null)) {
    if ($PSCmdlet.ShouldProcess($ocDir, 'npm install ' + $OpenCodePluginSpec)) {
      try {
        & npm install $OpenCodePluginSpec --prefix $ocDir
        if ($LASTEXITCODE -eq 0) { $installed = $true } else { Write-Host ("npm install " + $OpenCodePluginSpec + " falhou (exit " + $LASTEXITCODE + ").") -ForegroundColor Yellow }
      }
      catch {
        Write-Host ("npm install " + $OpenCodePluginSpec + " falhou: " + $_) -ForegroundColor Yellow
      }
    }
    else { $installed = $true }
  }
  if (-not $installed) {
    Write-Host ('AVISO: nao foi possivel instalar ' + $OpenCodePluginSpec + ' (bun/npm indisponiveis ou falharam). Instale manualmente: cd ' + $ocDir + '; bun add ' + $OpenCodePluginSpec) -ForegroundColor Yellow
  }
}

Write-Host ''
Write-Host 'Instalacao concluida.' -ForegroundColor Green
Write-Host 'Plano aplicado:'
foreach ($l in $plan) { Write-Host ('  ' + $l) -ForegroundColor DarkGray }
Write-Host ("Backup: " + $bakDir + ' (' + $backupCount + ' arquivo(s))') -ForegroundColor DarkGray
Write-Host 'Reinicie o OpenCode para carregar AGENTS.md, agents, skills e plugin.' -ForegroundColor Yellow
exit 0
