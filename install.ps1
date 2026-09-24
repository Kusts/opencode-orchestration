<#!
.SYNOPSIS
    Instala o sistema de orquestracao de subagents do OpenCode neste computador.
.DESCRIPTION
    Le os modelos de models.jsonc, concatena source/global + source/adapters
    em AGENTS.md (dentro de marcadores), instala os 19 agents (sem o bloco
    orchestration: do frontmatter), copia skills-core e o plugin de
    enforcement, e faz merge estrutural do opencode.json preservando as
    chaves do usuario (mcp, plugin preenchido, chaves desconhecidas).
    PowerShell 5.1 compativel. Idempotente: rodar 2x nao duplica nem quebra.
    Suporta -WhatIf via SupportsShouldProcess.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$RepoRoot,
  [string]$TargetHome,
  [switch]$NoCoreSkills
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($TargetHome)) { $TargetHome = $env:USERPROFILE }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$written = New-Object System.Collections.ArrayList

# Dependencia do plugin de enforcement (versao fixada para instalacao reproduzivel)
$openCodePluginVersion = '1.18.31'
$openCodePluginSpec = '@opencode-ai/plugin@1.18.31'

function Read-Utf8([string]$Path) {
  return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Write-Utf8([string]$Path, [string]$Text, [string]$Action) {
  if ($PSCmdlet.ShouldProcess($Path, $Action)) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
    [void]$written.Add($Path)
  }
}

# 1. Modelos ---------------------------------------------------------------
$modelsPath = Join-Path $RepoRoot 'models.jsonc'
$examplePath = Join-Path $RepoRoot 'models.example.jsonc'
if (-not (Test-Path -LiteralPath $modelsPath -PathType Leaf)) {
  if ($PSCmdlet.ShouldProcess($modelsPath, 'Criar models.jsonc a partir do exemplo')) {
    Copy-Item -LiteralPath $examplePath -Destination $modelsPath -Force
  }
  Write-Host 'models.jsonc nao encontrado: criado a partir de models.example.jsonc.' -ForegroundColor Yellow
  Write-Host 'Edite models.jsonc e rode de novo.' -ForegroundColor Yellow
  exit 1
}
$modelsRaw = Read-Utf8 $modelsPath
$modelsLines = $modelsRaw -split "`n" | Where-Object { $_ -notmatch '^\s*//' }
$models = ($modelsLines -join "`n") | ConvertFrom-Json
$modelPlanner = $models.planner
$modelCheap = $models.cheap
$modelStrong = $models.strong
if ([string]::IsNullOrWhiteSpace($modelPlanner) -or [string]::IsNullOrWhiteSpace($modelCheap) -or [string]::IsNullOrWhiteSpace($modelStrong)) {
  Write-Host 'models.jsonc precisa definir planner, cheap e strong.' -ForegroundColor Red
  exit 1
}

function Resolve-Tokens([string]$Text) {
  $r = $Text.Replace('{{MODEL_PLANNER}}', $modelPlanner)
  $r = $r.Replace('{{MODEL_CHEAP}}', $modelCheap)
  $r = $r.Replace('{{MODEL_STRONG}}', $modelStrong)
  $homeSlash = $TargetHome -replace '\\', '/'
  $r = $r.Replace('{{HOME}}', $homeSlash)
  $r = $r.Replace('{{REPO_DIR}}', ($RepoRoot -replace '\\', '/'))
  return $r
}

$ocDir = Join-Path $TargetHome '.config\opencode'

# 2. Backup ----------------------------------------------------------------
if (Test-Path -LiteralPath $ocDir) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $bakDir = Join-Path $ocDir ("backups\oo-" + $stamp)
  $backedUp = 0
  $candidates = @()
  $agentsTarget = Join-Path $ocDir 'agents'
  $pluginsTarget = Join-Path $ocDir 'plugins'
  $p1 = Join-Path $ocDir 'AGENTS.md'
  if (Test-Path -LiteralPath $p1 -PathType Leaf) { $candidates += $p1 }
  $p2 = Join-Path $ocDir 'opencode.json'
  if (Test-Path -LiteralPath $p2 -PathType Leaf) { $candidates += $p2 }
  if (Test-Path -LiteralPath $agentsTarget) {
    $candidates += @(Get-ChildItem -File (Join-Path $agentsTarget '*.md') -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  }
  if (Test-Path -LiteralPath $pluginsTarget) {
    $candidates += @(Get-ChildItem -File (Join-Path $pluginsTarget '*.ts') -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  }
  foreach ($c in $candidates) {
    $rel = $c.Substring($ocDir.Length + 1)
    $dest = Join-Path $bakDir $rel
    if ($PSCmdlet.ShouldProcess($dest, 'Backup')) {
      $parent = Split-Path -Parent $dest
      if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
      Copy-Item -LiteralPath $c -Destination $dest -Force
      $backedUp += 1
    }
  }
  if ($backedUp -gt 0) { Write-Host ("Backup: " + $backedUp + " arquivo(s) em " + $bakDir) -ForegroundColor DarkGray }
}

# 3. AGENTS.md --------------------------------------------------------------
$header = @'
<!-- GENERATED FILE: direct edits will be overwritten. -->
<!-- Canonical source: source/; regenerate with scripts/render-agent-config.ps1. -->
<!-- This file is active only after scripts/reconcile-agent-config.ps1 applies it. -->
'@
$markStart = '<!-- opencode-orchestration:start -->'
$markEnd = '<!-- opencode-orchestration:end -->'
$globalBody = Read-Utf8 (Join-Path $RepoRoot 'source\global\AGENTS.md')
$adapterBody = Read-Utf8 (Join-Path $RepoRoot 'source\adapters\opencode.md')
$content = Resolve-Tokens (($globalBody.TrimEnd() + "`n`n" + $adapterBody.TrimEnd()).TrimEnd() + "`n")
$block = $header.TrimEnd() + "`n" + $markStart + "`n" + $content.TrimEnd() + "`n" + $markEnd + "`n"
$agentsTargetPath = Join-Path $ocDir 'AGENTS.md'
if ((Test-Path -LiteralPath $agentsTargetPath -PathType Leaf) -and ((Read-Utf8 $agentsTargetPath).Contains($markStart))) {
  $existing = Read-Utf8 $agentsTargetPath
  $pattern = [regex]::Escape($markStart) + '[\s\S]*?' + [regex]::Escape($markEnd)
  $replacement = [regex]::Escape($markStart)
  $newText = [regex]::Replace($existing, $pattern, '__OO_BLOCK__')
  $newText = $newText.Replace('__OO_BLOCK__', ($markStart + "`n" + $content.TrimEnd() + "`n" + $markEnd))
  # Garante header gerado no topo quando ausente
  if (-not $newText.Contains('GENERATED FILE')) {
    $newText = $header.TrimEnd() + "`n" + $newText.TrimStart()
  }
  $replacement = $null
  Write-Utf8 $agentsTargetPath ($newText.TrimEnd() + "`n") 'Atualizar bloco opencode-orchestration em AGENTS.md'
}
elseif (Test-Path -LiteralPath $agentsTargetPath -PathType Leaf) {
  $existing = (Read-Utf8 $agentsTargetPath).TrimEnd()
  Write-Utf8 $agentsTargetPath ($existing + "`n`n" + $block.TrimEnd() + "`n") 'Anexar bloco opencode-orchestration em AGENTS.md'
}
else {
  Write-Utf8 $agentsTargetPath ($block.TrimEnd() + "`n") 'Criar AGENTS.md'
}

# 4. Agentes ---------------------------------------------------------------
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

$agentCount = 0
$repoEsc = $RepoRoot.Replace('\', '\\')
foreach ($f in (Get-ChildItem -File (Join-Path $RepoRoot 'source\agents\*.md'))) {
  $raw = Read-Utf8 $f.FullName
  $raw = $raw.Replace('{{MODEL_PLANNER}}', $modelPlanner)
  $raw = $raw.Replace('{{MODEL_CHEAP}}', $modelCheap)
  $raw = $raw.Replace('{{MODEL_STRONG}}', $modelStrong)
  $raw = $raw.Replace('{{REPO_DIR}}', $repoEsc)
  $raw = $raw.Replace('{{HOME}}', ($TargetHome -replace '\\', '/'))
  $noNl = ($raw -replace "`r`n", "`n" -replace "`r", "`n")
  $splitLines = $noNl -split "`n"
  $clean = Remove-OrchestrationBlock $splitLines
  $dest = Join-Path $ocDir ('agents\' + $f.Name)
  Write-Utf8 $dest ($clean.TrimEnd() + "`n") ('Instalar agent ' + $f.Name)
  $agentCount += 1
}

# 5. Skills ----------------------------------------------------------------
if (-not $NoCoreSkills) {
  $skillsSrc = Join-Path $RepoRoot 'skills-core'
  $skillsDst = Join-Path $ocDir 'skills'
  $skillsBackedUp = @()
  foreach ($d in (Get-ChildItem -Directory $skillsSrc -ErrorAction SilentlyContinue)) {
    $destDir = Join-Path $skillsDst $d.Name
    if ($PSCmdlet.ShouldProcess($destDir, 'Copiar skill-core ' + $d.Name)) {
      if ((Test-Path -LiteralPath $destDir) -and (-not [string]::IsNullOrWhiteSpace($bakDir))) {
        $skillBak = Join-Path $bakDir ('skills\' + $d.Name)
        $skillBakParent = Split-Path -Parent $skillBak
        if (-not (Test-Path -LiteralPath $skillBakParent)) { New-Item -ItemType Directory -Path $skillBakParent -Force | Out-Null }
        Copy-Item -LiteralPath $destDir -Destination $skillBak -Recurse -Force
        $skillsBackedUp += $d.Name
      }
      if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
      Copy-Item -Path (Join-Path $d.FullName '*') -Destination $destDir -Recurse -Force
      [void]$written.Add($destDir)
    }
  }
}

# 6. Plugin ----------------------------------------------------------------
$pluginSrc = Join-Path $RepoRoot 'plugins\orchestration-enforcement.ts'
$pluginDst = Join-Path $ocDir 'plugins\orchestration-enforcement.ts'
Write-Utf8 $pluginDst (Read-Utf8 $pluginSrc) 'Instalar plugin orchestration-enforcement.ts'
$pluginDep = Join-Path $ocDir 'node_modules\@opencode-ai\plugin'
if (-not (Test-Path -LiteralPath $pluginDep)) {
  $bun = Get-Command 'bun' -ErrorAction SilentlyContinue
  $npm = Get-Command 'npm' -ErrorAction SilentlyContinue
  $installed = $false
  if ($bun -ne $null) {
    if ($PSCmdlet.ShouldProcess($ocDir, 'bun add ' + $openCodePluginSpec)) {
      Push-Location $ocDir
      try {
        & bun add $openCodePluginSpec
        if ($LASTEXITCODE -eq 0) { $installed = $true } else { Write-Host ("bun add " + $openCodePluginSpec + " falhou (exit " + $LASTEXITCODE + "). Tentando npm...") -ForegroundColor Yellow }
      } catch {
        Write-Host ("bun add " + $openCodePluginSpec + " falhou: " + $_) -ForegroundColor Yellow
      }
      Pop-Location
    }
    else { $installed = $true }
  }
  if ((-not $installed) -and ($npm -ne $null)) {
    if ($PSCmdlet.ShouldProcess($ocDir, 'npm install ' + $openCodePluginSpec)) {
      try {
        & npm install $openCodePluginSpec --prefix $ocDir
        if ($LASTEXITCODE -eq 0) { $installed = $true } else { Write-Host ("npm install " + $openCodePluginSpec + " falhou (exit " + $LASTEXITCODE + ").") -ForegroundColor Yellow }
      } catch {
        Write-Host ("npm install " + $openCodePluginSpec + " falhou: " + $_) -ForegroundColor Yellow
      }
    }
    else { $installed = $true }
  }
  if (-not $installed) {
    Write-Host ('AVISO: nao foi possivel instalar ' + $openCodePluginSpec + ' (bun/npm indisponiveis ou falharam). Instale manualmente: cd ' + $ocDir + '; bun add ' + $openCodePluginSpec) -ForegroundColor Yellow
  }
}

# 7. opencode.json (merge estrutural) ---------------------------------------
$tmplRaw = Resolve-Tokens (Read-Utf8 (Join-Path $RepoRoot 'templates\opencode.json.tmpl'))
$desired = $tmplRaw | ConvertFrom-Json
$jsonPath = Join-Path $ocDir 'opencode.json'
if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
  $existing = (Read-Utf8 $jsonPath) | ConvertFrom-Json
  foreach ($prop in @('$schema', 'model', 'default_agent', 'subagent_depth', 'agent')) {
    $existing | Add-Member -NotePropertyName $prop -NotePropertyValue $desired.$prop -Force
  }
  $hasSkillsPaths = $false
  if (($existing | Get-Member -Name 'skills' -ErrorAction SilentlyContinue) -ne $null) {
    if (($existing.skills | Get-Member -Name 'paths' -ErrorAction SilentlyContinue) -ne $null) {
      if ($existing.skills.paths -ne $null) { $hasSkillsPaths = $true }
    }
  }
  if (-not $hasSkillsPaths) {
    if (($existing | Get-Member -Name 'skills' -ErrorAction SilentlyContinue) -eq $null) {
      $existing | Add-Member -NotePropertyName 'skills' -NotePropertyValue $desired.skills -Force
    }
    else {
      $existing.skills | Add-Member -NotePropertyName 'paths' -NotePropertyValue $desired.skills.paths -Force
    }
  }
  $hasAutoupdate = ($existing | Get-Member -Name 'autoupdate' -ErrorAction SilentlyContinue) -ne $null
  if (-not $hasAutoupdate) {
    $existing | Add-Member -NotePropertyName 'autoupdate' -NotePropertyValue $false -Force
  }
  $userPluginEmpty = $true
  if (($existing | Get-Member -Name 'plugin' -ErrorAction SilentlyContinue) -ne $null) {
    if ($existing.plugin -ne $null) {
      if (@($existing.plugin).Count -gt 0) { $userPluginEmpty = $false }
    }
  }
  if ($userPluginEmpty) {
    $existing | Add-Member -NotePropertyName 'plugin' -NotePropertyValue @() -Force
  }
  $merged = $existing | ConvertTo-Json -Depth 32
  Write-Utf8 $jsonPath ($merged.TrimEnd() + "`n") 'Merge estrutural do opencode.json'
}
else {
  Write-Utf8 $jsonPath ($tmplRaw.TrimEnd() + "`n") 'Criar opencode.json'
}

# 8. Resumo -----------------------------------------------------------------
Write-Host ''
Write-Host 'Instalacao concluida.' -ForegroundColor Green
Write-Host ("Arquivos escritos: " + $written.Count)
foreach ($w in $written) { Write-Host ("  " + $w) -ForegroundColor DarkGray }
Write-Host ("Agentes instalados: " + $agentCount)
if ($skillsBackedUp -ne $null -and @($skillsBackedUp).Count -gt 0) { Write-Host ("Skills sobrescritas com backup: " + ($skillsBackedUp -join ', ')) -ForegroundColor DarkGray }
Write-Host 'Reinicie o OpenCode para carregar AGENTS.md, agents, skills e plugin.' -ForegroundColor Yellow
exit 0
