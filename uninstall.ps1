<#!
.SYNOPSIS
    Remove somente o ownership do pacote opencode-orchestration (P2).
.DESCRIPTION
    Remove agentes, bloco markered do AGENTS.md, chaves managed do
    config (opencode.json ou opencode.jsonc — jsonc vence se ambos
    existirem), skills, plugin e o manifest. Nunca toca mcp.*, agentes
    desconhecidos, chaves de topo desconhecidas, conteudo do usuario fora
    dos markers nem ~/.opencode-orchestration/evidence/ (dados do usuario).
    Arquivo alterado pelo usuario depois do install (hash diverge do
    manifest) e mantido com AVISO. Sem manifest, heuristica conservadora:
    so remove o que reconhecer como do pacote e lista o resto.
    PS 5.1 compativel. Suporta -WhatIf via SupportsShouldProcess.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$TargetHome,
  [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TargetHome)) { $TargetHome = $env:USERPROFILE }
$ocDir = Join-Path $TargetHome '.config\opencode'
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  $ManifestPath = Join-Path $TargetHome '.opencode-orchestration\manifest.json'
}

$MarkStart = '<!-- opencode-orchestration:start -->'
$MarkEnd = '<!-- opencode-orchestration:end -->'
$AgentNames = @(
  'ai-agent-engineer.md', 'architect.md', 'automation-engineer.md',
  'backend-engineer.md', 'coder.md', 'database-engineer.md', 'debugger.md',
  'docs-manager.md', 'engineering-advisor.md', 'explorer.md',
  'frontend-engineer.md', 'infra-engineer.md', 'product-designer.md',
  'requirements-analyst.md', 'researcher.md', 'reviewer.md',
  'security-reviewer.md', 'skeptic.md', 'tester.md'
)
$WorkerKeys = @(
  'explorer', 'researcher', 'coder', 'tester', 'reviewer', 'debugger',
  'security-reviewer', 'architect', 'docs-manager', 'frontend-engineer',
  'backend-engineer', 'database-engineer', 'ai-agent-engineer',
  'automation-engineer', 'infra-engineer'
)
$SkillNames = @(
  'dispatching-parallel-agents', 'hybrid-development',
  'subagent-driven-development', 'using-superpowers',
  'verification-before-completion'
)

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

function Convert-Canonical($Value) {
  if ($null -eq $Value) { return 'null' }
  if (($Value -is [array]) -and ($Value.Count -eq 0)) { return '[]' }
  $j = ($Value | ConvertTo-Json -Depth 32 -Compress)
  if ([string]::IsNullOrEmpty($j)) { return '[]' }
  return $j
}

function Strip-JsoncComments([string]$Text) {
  # Conversor JSONC->JSON em DUAS FASES (mesma logica do install.ps1).
  # Fase 1 remove comentarios // e /* */ respeitando literais de string
  # (trata escapes, preserva quebras para nao colar linhas); fase 2 remove
  # virgulas sobrando sobre o texto JA SEM comentarios (',' seguida so de
  # whitespace e depois } ou ]), tambem respeitando strings. Duas fases
  # porque o lookahead de virgula no texto ORIGINAL enxergava '/' de
  # comentario e nao removia a virgula.
  # PS 5.1 compativel: sem ternario, sem ??, sem Invoke-Expression.
  if ($null -eq $Text) { return '' }
  # Fase 1: strip de comentarios, preservando strings e quebras.
  $sb1 = New-Object Text.StringBuilder ($Text.Length)
  $inStr = $false
  $escaped = $false
  $inLine = $false
  $inBlock = $false
  $i = 0
  while ($i -lt $Text.Length) {
    $c = $Text[$i]
    $next = ''
    if (($i + 1) -lt $Text.Length) { $next = $Text[$i + 1] }
    if ($inLine) {
      if ($c -eq "`n") { $inLine = $false; [void]$sb1.Append($c) }
      $i += 1
      continue
    }
    if ($inBlock) {
      if (($c -eq '*') -and ($next -eq '/')) { $inBlock = $false; $i += 2; continue }
      if ($c -eq "`n") { [void]$sb1.Append($c) }
      $i += 1
      continue
    }
    if ($inStr) {
      [void]$sb1.Append($c)
      if ($escaped) { $escaped = $false }
      elseif ($c -eq '\') { $escaped = $true }
      elseif ($c -eq '"') { $inStr = $false }
      $i += 1
      continue
    }
    if ($c -eq '"') { $inStr = $true; [void]$sb1.Append($c); $i += 1; continue }
    if (($c -eq '/') -and ($next -eq '/')) { $inLine = $true; $i += 2; continue }
    if (($c -eq '/') -and ($next -eq '*')) { $inBlock = $true; $i += 2; continue }
    [void]$sb1.Append($c)
    $i += 1
  }
  $noComments = $sb1.ToString()
  # Fase 2: virgula sobrando sobre o texto sem comentarios, respeitando
  # strings (nao remove ',' dentro de literal, ex.: "x, }" permanece).
  $sb = New-Object Text.StringBuilder ($noComments.Length)
  $inStr = $false
  $escaped = $false
  $i = 0
  while ($i -lt $noComments.Length) {
    $c = $noComments[$i]
    if ($inStr) {
      [void]$sb.Append($c)
      if ($escaped) { $escaped = $false }
      elseif ($c -eq '\') { $escaped = $true }
      elseif ($c -eq '"') { $inStr = $false }
      $i += 1
      continue
    }
    if ($c -eq '"') { $inStr = $true; [void]$sb.Append($c); $i += 1; continue }
    if ($c -eq ',') {
      $j = $i + 1
      while (($j -lt $noComments.Length) -and ([char]::IsWhiteSpace($noComments[$j]))) { $j += 1 }
      if (($j -lt $noComments.Length) -and (($noComments[$j] -eq '}') -or ($noComments[$j] -eq ']'))) {
        $i += 1
        continue
      }
      [void]$sb.Append($c)
      $i += 1
      continue
    }
    [void]$sb.Append($c)
    $i += 1
  }
  return $sb.ToString()
}

function Find-ManifestHash($Manifest, [string]$Relative) {
  if ($null -eq $Manifest) { return $null }
  if (-not (Has-Member $Manifest 'managed_files')) { return $null }
  foreach ($e in $Manifest.managed_files) {
    $rel = $null
    if (Has-Member $e 'relative') { $rel = $e.relative }
    $norm = ([string]$rel) -replace '/', '\'
    if (($null -ne $rel) -and ($norm -eq $Relative)) {
      if (Has-Member $e 'sha256') { return $e.sha256 }
      return $null
    }
  }
  return $null
}

function Get-SnapshotValue($Manifest, [string]$Path) {
  if ($null -eq $Manifest) { return $null }
  if (-not (Has-Member $Manifest 'config_snapshot')) { return $null }
  if (Has-Member $Manifest.config_snapshot $Path) { return $Manifest.config_snapshot.$Path }
  return $null
}

$manifest = $null
if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
  try { $manifest = (Read-Utf8 $ManifestPath) | ConvertFrom-Json }
  catch { Write-Host ('AVISO: manifest ilegivel, modo conservador: ' + $_.Exception.Message) -ForegroundColor Yellow; $manifest = $null }
}
else {
  Write-Host 'AVISO: manifest ausente, heuristica conservadora (so remove o reconhecido como do pacote).' -ForegroundColor Yellow
}

$plan = New-Object System.Collections.ArrayList
$actions = New-Object System.Collections.ArrayList
function Add-Plan([string]$Tag, [string]$Label) {
  [void]$plan.Add('[' + $Tag + '] ' + $Label)
}

# Config: opencode.json e/ou opencode.jsonc — o ARQUIVO DO MANIFEST tem
# precedencia quando managed_files registra a entrada de config (evita operar
# o arquivo errado apos troca de formato: install geriu opencode.json, o
# usuario criou opencode.jsonc depois; sem isso o uninstall tocaria o jsonc e
# deixaria as chaves geridas no json original). Sem manifest ou sem entrada
# de config no manifest, vale a deteccao atual (jsonc presente => alvo e o
# jsonc; json sozinho junto do jsonc e do usuario e nao e tocado). Parse
# tolera JSONC (comentarios + trailing commas).
$jsonCandidatePath = Join-Path $ocDir 'opencode.json'
$jsoncCandidatePath = Join-Path $ocDir 'opencode.jsonc'
$configFileName = 'opencode.json'
$manifestConfigName = $null
if (($null -ne $manifest) -and (Has-Member $manifest 'managed_files')) {
  foreach ($e in $manifest.managed_files) {
    $mrel = $null
    if (Has-Member $e 'relative') { $mrel = ([string]$e.relative) -replace '/', '\' }
    if (($mrel -eq 'opencode.json') -or ($mrel -eq 'opencode.jsonc')) { $manifestConfigName = $mrel; break }
  }
}
if (($null -ne $manifestConfigName) -and (Test-Path -LiteralPath (Join-Path $ocDir $manifestConfigName) -PathType Leaf)) { $configFileName = $manifestConfigName }
elseif (Test-Path -LiteralPath $jsoncCandidatePath -PathType Leaf) { $configFileName = 'opencode.jsonc' }
$jsonPath = Join-Path $ocDir $configFileName
$agentsMdPath = Join-Path $ocDir 'AGENTS.md'
$pluginDst = Join-Path $ocDir 'plugins\orchestration-enforcement.ts'

# Agentes ----------------------------------------------------------------------
foreach ($n in $AgentNames) {
  $dst = Join-Path $ocDir ('agents\' + $n)
  $rel = 'agents\' + $n
  if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) {
    Add-Plan 'SKIP' ($rel + ' (ausente)')
    continue
  }
  $exp = Find-ManifestHash $manifest $rel
  if ($null -ne $exp) {
    if ((Get-FileHashSafe $dst) -eq $exp) {
      Add-Plan 'REMOVE' $rel
      [void]$actions.Add(@{ Kind = 'del-file'; Dst = $dst; Label = $rel })
    }
    else {
      Add-Plan 'KEEP' ($rel + ' (alterado pelo usuario apos install, mantido)')
    }
  }
  else {
    Add-Plan 'KEEP' ($rel + ' (manifest ausente/ilegivel, mantido; remova manualmente se desejado)')
  }
}

# AGENTS.md --------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $agentsMdPath -PathType Leaf)) {
  Add-Plan 'SKIP' 'AGENTS.md (ausente)'
}
else {
  $t = Read-Utf8 $agentsMdPath
  if ($t.Contains($MarkStart) -and $t.Contains($MarkEnd)) {
    Add-Plan 'REMOVE' 'AGENTS.md (bloco markered; resto preservado)'
    [void]$actions.Add(@{ Kind = 'unblock-agentsmd'; Dst = $agentsMdPath; Label = 'AGENTS.md' })
  }
  else {
    Add-Plan 'SKIP' 'AGENTS.md (sem bloco markered)'
  }
}

# opencode.json / opencode.jsonc ------------------------------------------------
# (arquivo detectado acima; jsonc vence quando ambos existem)
$existingJson = $null
if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
  try { $existingJson = (Strip-JsoncComments (Read-Utf8 $jsonPath)) | ConvertFrom-Json }
  catch { Add-Plan 'KEEP' ($configFileName + ' (nao parseia, mantido)'); $existingJson = 'UNPARSEABLE' }
}
else {
  Add-Plan 'SKIP' ($configFileName + ' (ausente)')
}
$configOps = New-Object System.Collections.ArrayList
if (($null -ne $existingJson) -and ($existingJson -ne 'UNPARSEABLE')) {
  foreach ($w in $WorkerKeys) {
    foreach ($leaf in @('mode', 'model', 'permission')) {
      if ($leaf -eq 'permission') {
        $mp = 'agent.' + $w + '.permission.task'
        $hasTask = (Has-Member $existingJson 'agent') -and (Has-Member $existingJson.agent $w) -and (Has-Member $existingJson.agent.$w 'permission') -and ($null -ne $existingJson.agent.$w.permission) -and (Has-Member $existingJson.agent.$w.permission 'task')
        if (-not $hasTask) { continue }
        $snap = Get-SnapshotValue $manifest $mp
        $cur = Convert-Canonical $existingJson.agent.$w.permission.task
        if (($null -ne $manifest) -and ($null -ne $snap)) {
          if ($cur -eq $snap) {
            Add-Plan 'REMOVE' ($mp + ' (intacto; demais permissoes preservadas)')
            [void]$configOps.Add(@{ Op = 'del-task'; Agent = $w })
          }
          else {
            Add-Plan 'KEEP' ($mp + ' (alterado pelo usuario, mantido)')
          }
        }
        else {
          Add-Plan 'KEEP' ($mp + ' (manifest ausente, mantido)')
        }
        continue
      }
      $mp = 'agent.' + $w + '.' + $leaf
      $has = (Has-Member $existingJson 'agent') -and (Has-Member $existingJson.agent $w) -and (Has-Member $existingJson.agent.$w $leaf)
      if (-not $has) { continue }
      $snap = Get-SnapshotValue $manifest $mp
      $cur = Convert-Canonical $existingJson.agent.$w.$leaf
      if (($null -ne $manifest) -and ($null -ne $snap)) {
        if ($cur -eq $snap) {
          Add-Plan 'REMOVE' ($mp + ' (intacto)')
          [void]$configOps.Add(@{ Op = 'del-leaf'; Agent = $w; Leaf = $leaf })
        }
        else {
          Add-Plan 'KEEP' ($mp + ' (alterado pelo usuario, mantido)')
        }
      }
      else {
        Add-Plan 'KEEP' ($mp + ' (manifest ausente, mantido)')
      }
    }
  }
  if ((Has-Member $existingJson 'agent') -and (Has-Member $existingJson.agent 'title') -and (Has-Member $existingJson.agent.title 'model')) {
    $snap = Get-SnapshotValue $manifest 'agent.title.model'
    $cur = Convert-Canonical $existingJson.agent.title.model
    if (($null -ne $manifest) -and ($null -ne $snap) -and ($cur -eq $snap)) {
      Add-Plan 'REMOVE' 'agent.title.model (intacto)'
      [void]$configOps.Add(@{ Op = 'del-leaf'; Agent = 'title'; Leaf = 'model' })
    }
    else {
      Add-Plan 'KEEP' 'agent.title.model (alterado ou manifest ausente, mantido)'
    }
  }
  if ((Has-Member $existingJson 'agent') -and (Has-Member $existingJson.agent 'build')) {
    foreach ($leaf in @('mode', 'permission')) {
      if ($leaf -eq 'permission') {
        $mp = 'agent.build.permission.task'
        $hasTask = (Has-Member $existingJson.agent.build 'permission') -and ($null -ne $existingJson.agent.build.permission) -and (Has-Member $existingJson.agent.build.permission 'task')
        if (-not $hasTask) { continue }
        $snap = Get-SnapshotValue $manifest $mp
        $cur = Convert-Canonical $existingJson.agent.build.permission.task
        if (($null -ne $manifest) -and ($null -ne $snap) -and ($cur -eq $snap)) {
          Add-Plan 'REMOVE' ($mp + ' (intacto; demais permissoes preservadas)')
          [void]$configOps.Add(@{ Op = 'del-task'; Agent = 'build' })
        }
        else {
          Add-Plan 'KEEP' ($mp + ' (alterado ou manifest ausente, mantido)')
        }
        continue
      }
      if (-not (Has-Member $existingJson.agent.build $leaf)) { continue }
      $mp = 'agent.build.' + $leaf
      $snap = Get-SnapshotValue $manifest $mp
      $cur = Convert-Canonical $existingJson.agent.build.$leaf
      if (($null -ne $manifest) -and ($null -ne $snap) -and ($cur -eq $snap)) {
        Add-Plan 'REMOVE' ($mp + ' (intacto)')
        [void]$configOps.Add(@{ Op = 'del-leaf'; Agent = 'build'; Leaf = $leaf })
      }
      else {
        Add-Plan 'KEEP' ($mp + ' (alterado ou manifest ausente, mantido)')
      }
    }
  }
  foreach ($root in @('model', 'default_agent', 'subagent_depth')) {
    if (-not (Has-Member $existingJson $root)) { continue }
    $snap = Get-SnapshotValue $manifest $root
    $cur = Convert-Canonical $existingJson.$root
    if (($null -ne $manifest) -and ($null -ne $snap) -and ($cur -eq $snap)) {
      Add-Plan 'REMOVE' ($root + ' (manifest confirma ownership, valor intacto)')
      [void]$configOps.Add(@{ Op = 'del-root'; Key = $root })
    }
    else {
      Add-Plan 'KEEP' ($root + ' (alterado, ou manifest ausente/nao confirma, mantido)')
    }
  }
  # NOTA ownership (trim): skills.paths, autoupdate e plugin NAO sao mais do
  # pacote (auto-discovery do runtime; autoupdate indesejado em distribuido).
  # Essas chaves nunca sao removidas aqui — nem mesmo quando manifests ANTIGOS
  # as listam em adopted_paths/managed_config_paths (listas legadas sao
  # ignoradas para essas chaves, sem erro). mcp.* tambem nunca e tocado.
  if (Has-Member $existingJson 'mcp') { Add-Plan 'KEEP' 'mcp.* (nunca tocado)' }
  if ((Has-Member $existingJson 'agent') -and ($null -ne $existingJson.agent)) {
    foreach ($ak in @($existingJson.agent.PSObject.Properties.Name)) {
      if ($WorkerKeys -notcontains $ak -and $ak -ne 'build' -and $ak -ne 'title') {
        Add-Plan 'KEEP' ('agent.' + $ak + ' (desconhecido, intacto)')
      }
    }
  }
  if ($configOps.Count -gt 0) {
    [void]$actions.Add(@{ Kind = 'config'; Dst = $jsonPath; Label = $configFileName })
  }
}

# Skills (por arquivo: remove só hash confirmado; extras do usuário ficam) -----
foreach ($s in $SkillNames) {
  $dstDir = Join-Path (Join-Path $ocDir 'skills') $s
  if (-not (Test-Path -LiteralPath $dstDir)) {
    Add-Plan 'SKIP' ('skills/' + $s + '/ (ausente)')
    continue
  }
  $confirmed = New-Object System.Collections.ArrayList
  $hasEntry = $false
  $mismatch = $false
  if ($null -ne $manifest) {
    foreach ($e in $manifest.managed_files) {
      $rel = $null
      if (Has-Member $e 'relative') { $rel = ([string]$e.relative) -replace '/', '\' }
      if (($null -ne $rel) -and ($rel -like ('skills\' + $s + '\*'))) {
        $hasEntry = $true
        $dp = Join-Path $ocDir $rel
        if ((Test-Path -LiteralPath $dp -PathType Leaf) -and ((Get-FileHashSafe $dp) -eq $e.sha256)) {
          [void]$confirmed.Add(@{ Dst = $dp; Rel = $rel })
        }
        else {
          $mismatch = $true
        }
      }
    }
  }
  if (($null -ne $manifest) -and $hasEntry -and ($confirmed.Count -gt 0)) {
    if ($mismatch) {
      Add-Plan 'REMOVE' ('skills/' + $s + '/ (' + $confirmed.Count + ' arquivo(s) intactos; alterados/ausentes mantidos)')
    }
    else {
      Add-Plan 'REMOVE' ('skills/' + $s + '/ (' + $confirmed.Count + ' arquivo(s), hash confere)')
    }
    foreach ($c in $confirmed) {
      [void]$actions.Add(@{ Kind = 'del-file'; Dst = $c.Dst; Label = $c.Rel })
    }
    [void]$actions.Add(@{ Kind = 'cleanup-dir'; Dst = $dstDir; Label = ('skills/' + $s + '/ (somente se vazio)') })
  }
  else {
    Add-Plan 'KEEP' ('skills/' + $s + '/ (alterado ou manifest ausente, mantido)')
  }
}

# Plugin ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $pluginDst -PathType Leaf)) {
  Add-Plan 'SKIP' 'plugins/orchestration-enforcement.ts (ausente)'
}
else {
  $exp = Find-ManifestHash $manifest 'plugins\orchestration-enforcement.ts'
  if (($null -ne $exp) -and ((Get-FileHashSafe $pluginDst) -eq $exp)) {
    Add-Plan 'REMOVE' 'plugins/orchestration-enforcement.ts (hash confere)'
    [void]$actions.Add(@{ Kind = 'del-file'; Dst = $pluginDst; Label = 'plugins/orchestration-enforcement.ts' })
    [void]$actions.Add(@{ Kind = 'cleanup-dir'; Dst = (Split-Path -Parent $pluginDst); Label = 'plugins/ (somente se vazio)' })
  }
  else {
    Add-Plan 'KEEP' 'plugins/orchestration-enforcement.ts (alterado ou manifest ausente, mantido)'
  }
}

Add-Plan 'REMOVE' 'manifest.json (ao final)'
Add-Plan 'KEEP' '.opencode-orchestration/evidence/ (dados do usuario, permanece)'

if ($WhatIfPreference) {
  Write-Host '=== UNINSTALL PLAN (WhatIf, nenhuma escrita) ===' -ForegroundColor Cyan
  foreach ($l in $plan) { Write-Host $l -ForegroundColor DarkGray }
  exit 0
}

# Backup pre-uninstall --------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bakDir = Join-Path $ocDir ("backups\oo-uninstall-" + $stamp)
$touched = @()
foreach ($a in $actions) {
  if ($a.Kind -eq 'del-dir') {
    foreach ($f in @(Get-ChildItem -File $a.Dst -Recurse -ErrorAction SilentlyContinue)) {
      $touched += $f.FullName
    }
  }
  else {
    $touched += $a.Dst
  }
}
if ($PSCmdlet.ShouldProcess($bakDir, 'Backup pre-uninstall')) {
  foreach ($t in $touched) {
    if (Test-Path -LiteralPath $t -PathType Leaf) {
      $rel = $t.Substring($ocDir.Length + 1)
      $dest = Join-Path $bakDir $rel
      $parent = Split-Path -Parent $dest
      if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
      Copy-Item -LiteralPath $t -Destination $dest -Force
    }
  }
  Write-Host ('Backup pre-uninstall em ' + $bakDir) -ForegroundColor DarkGray
}

function Write-FileAtomicLocal([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  $norm = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
  $tmp = Join-Path $parent ('.' + (Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllText($tmp, $norm, (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) {
      $rb = $tmp + '.bak'
      try { [System.IO.File]::Replace($tmp, $Path, $rb, $false) }
      catch { Move-Item -LiteralPath $tmp -Destination $Path -Force }
      if (Test-Path -LiteralPath $rb) { Remove-Item -LiteralPath $rb -Force -ErrorAction SilentlyContinue }
    }
    else { [IO.File]::Move($tmp, $Path) }
  }
  finally {
    if (($tmp) -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
}

$warnings = New-Object System.Collections.ArrayList
foreach ($a in $actions) {
  if ($a.Kind -eq 'del-file') {
    if ($PSCmdlet.ShouldProcess($a.Dst, 'Remover ' + $a.Label)) {
      Remove-Item -LiteralPath $a.Dst -Force
    }
  }
  elseif ($a.Kind -eq 'del-dir') {
    if ($PSCmdlet.ShouldProcess($a.Dst, 'Remover ' + $a.Label)) {
      Remove-Item -LiteralPath $a.Dst -Recurse -Force
    }
  }
  elseif ($a.Kind -eq 'cleanup-dir') {
    if ($PSCmdlet.ShouldProcess($a.Dst, 'Remover diretorio vazio ' + $a.Label)) {
      if (Test-Path -LiteralPath $a.Dst -PathType Container) {
        $left = @(Get-ChildItem -Force $a.Dst -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) {
          Remove-Item -LiteralPath $a.Dst -Force
        }
      }
    }
  }
  elseif ($a.Kind -eq 'unblock-agentsmd') {
    if ($PSCmdlet.ShouldProcess($a.Dst, 'Remover bloco markered do AGENTS.md')) {
      $t = Read-Utf8 $a.Dst
      $pattern = [regex]::Escape($MarkStart) + '[\s\S]*?' + [regex]::Escape($MarkEnd)
      $nt = [regex]::Replace($t, $pattern, '')
      $nt = ($nt -replace "(?m)^<!-- GENERATED FILE:.*\r?\n", '')
      $nt = ($nt -replace "(?m)^<!-- Canonical source:.*\r?\n", '')
      $nt = ($nt -replace "(?m)^<!-- This file is active only.*\r?\n", '')
      $nt = $nt.Trim()
      if ([string]::IsNullOrWhiteSpace($nt)) {
        [void]$warnings.Add('AGENTS.md ficaria vazio/header-only: mantido o resto (vazio) e avisado; remova manualmente se desejado.')
      }
      else {
        [void]$warnings.Add('AGENTS.md: bloco removido, resto preservado.')
      }
      Write-FileAtomicLocal $a.Dst ($nt.TrimEnd() + "`n")
    }
  }
  elseif ($a.Kind -eq 'config') {
    if ($PSCmdlet.ShouldProcess($a.Dst, ('Remover chaves managed de ' + $a.Label))) {
      $cfg = (Strip-JsoncComments (Read-Utf8 $a.Dst)) | ConvertFrom-Json
      foreach ($op in $configOps) {
        if ($op.Op -eq 'del-task') {
          $node = $cfg.agent.($op.Agent)
          if (($null -ne $node) -and (Has-Member $node 'permission') -and ($null -ne $node.permission) -and ($null -ne $node.permission.PSObject.Properties['task'])) {
            $null = $node.permission.PSObject.Properties.Remove('task')
          }
          if (($null -ne $node) -and (Has-Member $node 'permission') -and ($null -ne $node.permission) -and ($null -ne $node.permission.PSObject) -and (@($node.permission.PSObject.Properties).Count -eq 0)) {
            $null = $node.PSObject.Properties.Remove('permission')
          }
          if (($null -ne $node) -and (@($node.PSObject.Properties).Count -eq 0)) {
            $null = $cfg.agent.PSObject.Properties.Remove($op.Agent)
          }
        }
        elseif ($op.Op -eq 'del-leaf') {
          $node = $cfg.agent.($op.Agent)
          if (($null -ne $node) -and ($null -ne $node.PSObject.Properties[$op.Leaf])) {
            $null = $node.PSObject.Properties.Remove($op.Leaf)
          }
          if (($null -ne $node) -and (@($node.PSObject.Properties).Count -eq 0)) {
            $null = $cfg.agent.PSObject.Properties.Remove($op.Agent)
          }
        }
        elseif ($op.Op -eq 'del-root') {
          if ($null -ne $cfg.PSObject.Properties[$op.Key]) {
            $null = $cfg.PSObject.Properties.Remove($op.Key)
          }
        }
        # NOTA: 'del-opt' (skills.paths/autoupdate/plugin) foi removido com o
        # trim de ownership — nenhuma op desse tipo e mais gerada; entradas
        # legadas em manifests antigos sao ignoradas (nunca processadas).
      }
      Write-FileAtomicLocal $a.Dst ((($cfg | ConvertTo-Json -Depth 32).TrimEnd()) + "`n")
    }
  }
}

if (($PSCmdlet.ShouldProcess($ManifestPath, 'Remover manifest')) -and (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
  Remove-Item -LiteralPath $ManifestPath -Force
}

Write-Host ''
Write-Host 'Uninstall concluido.' -ForegroundColor Green
foreach ($l in $plan) { Write-Host ('  ' + $l) -ForegroundColor DarkGray }
foreach ($w in $warnings) { Write-Host ('AVISO: ' + $w) -ForegroundColor Yellow }
exit 0
