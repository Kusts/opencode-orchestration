<#!
.SYNOPSIS
    Instala o pacote opencode-orchestration de forma transacional e preservadora.
.DESCRIPTION
    P2 (distribution hardening): precheck total antes de qualquer escrita,
    stage directory validado, backup + CAS por arquivo, apply atomico com
    rollback, manifest e plano por recurso no -WhatIf. PS 5.1 compativel:
    sem operador ternario, sem ??, sem Invoke-Expression e sem executar
    codigo vindo de JSON.

    Phase 6 (V3.1): installer runtime-aware. -Runtime V1 instala o dialeto
    V1 (agent/permission.task/subagent_depth); -Runtime V2 instala o dialeto
    V2 nativo (agents/permissions/experimental.subagent_depth) com o MESMO
    merge estrutural preservador (user-owned intacto). Explicito vence (sem
    probe, sem conflito); -Runtime Auto segue o probe (V1 ou V2); ambiguo
    aborta com exit 6. -Runtime Both segue BLOQUEADO (exit 6; perfis isolados
    chegam na Phase 7).
    Smoke V2 pos-install e best-effort com warning nesta fase (exit 0);
    smoke bloqueante entra na Phase 8 (CI).

    DECISOES DE DESENHO (2.1):
    - As funcoes de merge vivem NESTE arquivo (sem dot-source): instalacao
      em arquivo unico, sem dependencia de resolucao de caminho extra e sem
      risco de carregar codigo inesperado. Merge-ManagedOpencodeConfig
      orquestra Merge-ManagedAgentConfig; Merge-ManagedAgentsMdBlock cuida
      do AGENTS.md. (skills.paths/plugin/autoupdate: ownership removida —
      ver NOTA ownership acima de Get-DesiredManagedPaths.)
    - Auto-criacao de models.jsonc a partir do exemplo foi REMOVIDA: criava
      um write antes da validacao. Ausente/invalido agora falha no PRECHECK
      (exit 3) sem nenhuma escrita.
    - plugin_dependency e METADADO offline no manifest (sem bun/npm,
      sem rede): o bundle e autocontido; validacao da dependency no CI.
    - Exit codes: 0 ok; 3 falha de precheck (nada escrito); 4 CAS_CONFLICT
      (aborta SEM rollback, nada aplicado); 5 falha no apply (rollback
      tentado).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$RepoRoot,
  [string]$TargetHome,
  [switch]$NoCoreSkills,
  [ValidateSet('Auto', 'V1', 'V2', 'Both')]
  [string]$Runtime = 'Auto',
  [Parameter(DontShow)]
  [ValidateSet('backup', 'stage', 'cas', 'apply-half', 'apply-json', 'manifest')]
  [string]$InjectFailureAfter = ''
)

# -Runtime (Auto|V1|V2|Both), default Auto. Phase 6 (V3.1): V1 e V2 ATIVOS
# (fluxos nativos por runtime, mesma transacao backup+stage+CAS+apply+
# manifest+rollback). Explicito vence: -Runtime V1/V2 aplica o dialeto pedido
# SEM probe e SEM conflito (probe so no Auto). Auto resolve via probe (V1 ou
# V2); ambiguo/inconclusivo com binario presente aborta com exit 6. Both segue
# BLOQUEADO com exit 6 (perfis isolados chegam na Phase 7). Auto sem binario
# opencode no PATH degrada para V1 (comportamento legado, com aviso).

$ErrorActionPreference = 'Stop'

# NOTA test-only: -InjectFailureAfter forÃ§a falha no ponto indicado para
# exercitar backup/stage/rollback nos testes. Nunca usar em uso real.
# Valores: 'backup' (falha apos backup), 'stage' (falha apos stage),
# 'cas' (conflito CAS forcado -> exit 4, sem tocar o legado),
# 'apply-half' (falha no meio do apply -> rollback, exit 5),
# 'apply-json' (falha APOS escrever o config — opencode.json ou opencode.jsonc,
# ultima etapa -> rollback, exit 5),
# 'manifest' (falha na gravaÃ§Ã£o do manifest -> rollback completo, exit 5).

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($TargetHome)) { $TargetHome = $env:USERPROFILE }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$PackageVersion = '1.1.0'
$OpenCodePluginSpecV1 = '@opencode-ai/plugin@1.18.32'
$OpenCodePluginSpecV2 = '@opencode/plugin@2.0.18'
$OpenCodePluginSpec = $OpenCodePluginSpecV1
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

function Get-Sha256HexLower([string]$Path) {
  # SHA256 hex lowercase dos BYTES do arquivo, via .NET direto (sem
  # cmdlet): Get-FileHash retorna $null sob -WhatIf, e esta funcao roda no
  # PRECHECK (antes do exit WhatIf). Byte-identico ao
  # Get-FileHash -Algorithm SHA256. PS 5.1 compativel.
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $fs = [IO.File]::OpenRead($Path)
    try {
      $bytes = $sha.ComputeHash($fs)
    }
    finally { $fs.Close() }
    return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
  }
  finally { $sha.Dispose() }
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
  # Conversor JSONC->JSON em DUAS FASES (mesma logica no uninstall.ps1).
  # Fase 1 remove comentarios // (ate o fim da linha, preservando a quebra)
  # e /* */ (preservando quebras internas para nao colar linhas), respeitando
  # literais de string (nao remove // ou /* */ dentro de strings, trata
  # escapes \" e \\). Fase 2 remove virgulas sobrando sobre o texto JA SEM
  # comentarios (',' seguida so de whitespace e depois } ou ]), tambem
  # respeitando strings. Duas fases porque o lookahead de virgula no texto
  # ORIGINAL enxergava '/' de comentario (ex.: {"a": 1, // c + quebra + })
  # e nao removia a virgula (exit 3 no precheck). Sem ternario/??/
  # Invoke-Expression; nao executa codigo.
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
      # Olhar a frente (texto ja sem comentarios) pulando whitespace;
      # se o proximo significativo for } ou ], a virgula e descartada.
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

# ---- P9.1 identidade unica de caminhos relativos ------------------------------
# Regra: o caminho relativo de cada arquivo gerenciado e calculado UMA vez,
# a partir da enumeracao da fonte canonica, e carregado como dado imutavel
# (ManagedOperation) por todo o pipeline (plan/backup/stage/CAS/apply/
# manifest/rollback). Nunca recalcular RelativePath com Substring() sobre
# FullName enumerado: no CI o prefixo passado ao enumerador (ex.: TEMP com
# nome 8.3 "RUNNER~1") diverge do FullName canonicalizado retornado, e o
# Substring produzia relativos corrompidos ("skills\<skill>\on\SKILL.md").
function Test-ManagedRelativePath([string]$RelativePath) {
  if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
  if ([IO.Path]::IsPathRooted($RelativePath)) { return $false }
  if ($RelativePath -match '(^|[\\/])\.\.($|[\\/])') { return $false }
  if ($RelativePath.Contains(':')) { return $false }
  if ($RelativePath.StartsWith('\') -or $RelativePath.StartsWith('/')) { return $false }
  return $true
}

function Get-ManagedSourceFiles([string]$Dir) {
  # Enumeracao recursiva que constroi RelativePath SOMENTE com Name (e o
  # FullName apenas para DESCER a arvore, auto-consistente com o enumerador).
  # Retorna @{ SourcePath; RelativePath } para cada arquivo.
  $found = New-Object System.Collections.ArrayList
  foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction Stop)) {
    if ($item.PSIsContainer) {
      foreach ($child in @(Get-ManagedSourceFiles $item.FullName)) {
        [void]$found.Add(@{ SourcePath = $child.SourcePath; RelativePath = ($item.Name + '\' + $child.RelativePath) })
      }
    }
    else {
      [void]$found.Add(@{ SourcePath = $item.FullName; RelativePath = $item.Name })
    }
  }
  return $found
}

function Assert-PathUnder([string]$Path, [string]$Root, [string]$What) {
  $rootNorm = $Root.TrimEnd('\')
  $isUnder = $Path.StartsWith($rootNorm + '\', [StringComparison]::OrdinalIgnoreCase)
  $isRoot = $Path.Equals($rootNorm, [StringComparison]::OrdinalIgnoreCase)
  if ((-not $isUnder) -and (-not $isRoot)) {
    throw ($What + ' fora da raiz esperada: ' + $Path)
  }
}

function Assert-NoReparseUnder([string]$Root, [string]$Leaf, [string]$What) {
  # Falha com seguranca se algum diretorio ancestral (abaixo da raiz) do
  # destino gerenciado for junction/reparse point: o apply nao deve seguir
  # redirecionamento para fora da raiz gerenciada.
  $rootNorm = $Root.TrimEnd('\')
  $cur = $Leaf
  while ($true) {
    $parent = Split-Path -Parent $cur
    if ([string]::IsNullOrEmpty($parent)) { return }
    if ($parent.Length -le $rootNorm.Length) { return }
    if (Test-Path -LiteralPath $parent -PathType Container) {
      $item = Get-Item -LiteralPath $parent -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ($What + ': junction/reparse point detectado em ' + $parent)
      }
    }
    $cur = $parent
  }
}

function Restore-FileAtomicBytes([string]$BackupPath, [string]$DstPath) {
  # Restaura os BYTES exatos do backup (sem normalizacao de EOL). Um arquivo
  # pre-existente pode estar em CRLF: restaura-lo via texto mudaria seus
  # bytes, o hash divergiria e o rollback emitiria ROLLBACK_REQUIRED indevido.
  $parent = Split-Path -Parent $DstPath
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  $tmp = Join-Path $parent ('.' + (Split-Path -Leaf $DstPath) + '.' + [guid]::NewGuid().ToString('N') + '.rstr')
  try {
    Copy-Item -LiteralPath $BackupPath -Destination $tmp -Force
    if (Test-Path -LiteralPath $DstPath) {
      $bak2 = $tmp + '.bak'
      try { [System.IO.File]::Replace($tmp, $DstPath, $bak2, $false) }
      catch { Move-Item -LiteralPath $tmp -Destination $DstPath -Force }
      if (Test-Path -LiteralPath $bak2) { Remove-Item -LiteralPath $bak2 -Force -ErrorAction SilentlyContinue }
    }
    else { [IO.File]::Move($tmp, $DstPath) }
  }
  finally {
    if ((Test-Path -LiteralPath $tmp -PathType Leaf)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
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

# NOTA ownership (trim): "skills.paths", "plugin" e "autoupdate" NAO sao mais
# do pacote — auto-discovery do runtime cobre skills/plugins sem essas chaves
# e autoupdate em artefato distribuido e indesejado. Ficam so $schema/model/
# default_agent/subagent_depth + agent.*. Manifests antigos que listem as
# chaves removidas sao tolerados (uninstall simplesmente nao as processa).

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
  return @{ Config = $Existing; ManagedPaths = $managedPaths }
}

# ---- Phase 6: merge do dialeto V2 (agents/permissions/experimental) --------
# Mesma semantica preservadora do V1: somente as chaves do template sao
# gerenciadas; agentes user-owned dentro de agents{} e chaves de topo
# desconhecidas (mcp/plugin/skills/autoupdate/...) ficam intactos.
# permissions e array: substituicao integral quando o canonico diverge
# (ordem broad-first do template e significativa no runtime V2).

function Merge-ManagedAgentConfigV2($ExistingAgents, $DesiredAgents) {
  $appliedPaths = New-Object System.Collections.ArrayList
  if ($null -eq $ExistingAgents) {
    $ExistingAgents = (New-Object PSObject)
  }
  foreach ($key in @($DesiredAgents.PSObject.Properties.Name)) {
    $desiredEntry = $DesiredAgents.$key
    if (-not (Has-Member $ExistingAgents $key)) {
      Set-Prop $ExistingAgents $key (($desiredEntry | ConvertTo-Json -Depth 32) | ConvertFrom-Json)
    }
    else {
      $node = $ExistingAgents.$key
      if ($key -eq 'build') {
        if (Set-PropIfDifferent $node 'mode' $desiredEntry.mode) { }
        if (Has-Member $desiredEntry 'permissions') {
          if (Set-PropIfDifferent $node 'permissions' $desiredEntry.permissions) { }
        }
        Remove-Prop $node 'model'
      }
      elseif ($key -eq 'title') {
        if (Has-Member $desiredEntry 'model') {
          if (Set-PropIfDifferent $node 'model' $desiredEntry.model) { }
        }
      }
      else {
        if (Has-Member $desiredEntry 'mode') {
          if (Set-PropIfDifferent $node 'mode' $desiredEntry.mode) { }
        }
        if (Has-Member $desiredEntry 'model') {
          if (Set-PropIfDifferent $node 'model' $desiredEntry.model) { }
        }
        if (Has-Member $desiredEntry 'permissions') {
          if (Set-PropIfDifferent $node 'permissions' $desiredEntry.permissions) { }
        }
      }
    }
    if ($key -eq 'build') {
      [void]$appliedPaths.Add('agents.build.mode')
      [void]$appliedPaths.Add('agents.build.permissions')
      [void]$appliedPaths.Add('agents.build.model=ABSENT')
    }
    elseif ($key -eq 'title') {
      [void]$appliedPaths.Add('agents.title.model')
    }
    else {
      [void]$appliedPaths.Add('agents.' + $key + '.mode')
      [void]$appliedPaths.Add('agents.' + $key + '.model')
      [void]$appliedPaths.Add('agents.' + $key + '.permissions')
    }
  }
  return @{ Agents = $ExistingAgents; ManagedPaths = $appliedPaths }
}

function Get-DesiredManagedPathsV2($Desired) {
  $paths = New-Object System.Collections.ArrayList
  foreach ($top in @('$schema', 'model', 'default_agent', 'experimental.subagent_depth')) {
    [void]$paths.Add($top)
  }
  foreach ($key in @($Desired.agents.PSObject.Properties.Name)) {
    if ($key -eq 'build') {
      [void]$paths.Add('agents.build.mode')
      [void]$paths.Add('agents.build.permissions')
      [void]$paths.Add('agents.build.model=ABSENT')
      continue
    }
    if ($key -eq 'title') { [void]$paths.Add('agents.title.model'); continue }
    [void]$paths.Add('agents.' + $key + '.mode')
    [void]$paths.Add('agents.' + $key + '.model')
    [void]$paths.Add('agents.' + $key + '.permissions')
  }
  return $paths
}

function Merge-ManagedOpencodeConfigV2($Existing, $Desired) {
  $managedPaths = New-Object System.Collections.ArrayList
  foreach ($top in @('$schema', 'model', 'default_agent')) {
    if (Set-PropIfDifferent $Existing $top $Desired.$top) { }
    [void]$managedPaths.Add($top)
  }
  if (-not (Has-Member $Existing 'experimental') -or ($null -eq $Existing.experimental)) {
    Set-Prop $Existing 'experimental' (New-Object PSObject)
  }
  if (Set-PropIfDifferent $Existing.experimental 'subagent_depth' $Desired.experimental.subagent_depth) { }
  [void]$managedPaths.Add('experimental.subagent_depth')
  if (-not (Has-Member $Existing 'agents') -or ($null -eq $Existing.agents)) {
    Set-Prop $Existing 'agents' (New-Object PSObject)
  }
  $agentRes = Merge-ManagedAgentConfigV2 $Existing.agents $Desired.agents
  foreach ($p in $agentRes.ManagedPaths) { [void]$managedPaths.Add($p) }
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

function Get-RequiredTemplatesForRuntime([string]$RuntimeId) {
  if ([string]$RuntimeId -eq 'opencode-v2') { return @('templates\opencode.v2.json.tmpl') }
  return @('templates\opencode.v1.json.tmpl')
}

function Validate-RequiredFiles([string]$Root, [string[]]$RequiredTemplates) {
  if ($null -eq $RequiredTemplates) { $RequiredTemplates = @('templates\opencode.v1.json.tmpl', 'templates\opencode.v2.json.tmpl') }
  $errs = @()
  foreach ($rel in @('source\global\AGENTS.md', 'source\adapters\opencode.md', 'source\adapters\opencode-v2.md', 'scripts\runtime\lib\AgentTranslator.ps1', 'plugins\orchestration-enforcement.ts')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $rel) -PathType Leaf)) {
      $errs += ('fonte obrigatoria ausente: ' + $rel)
    }
  }
  $agents = @(Get-ChildItem -File (Join-Path $Root 'source\agents\*.md') -ErrorAction SilentlyContinue)
  if ($agents.Count -ne 19) { $errs += ('source\agents: esperado 19 .md, encontrado ' + $agents.Count) }
  foreach ($trel in @($RequiredTemplates)) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $trel) -PathType Leaf)) {
      $errs += ('fonte obrigatoria ausente: ' + $trel)
    }
  }
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
  $tmplPath = Join-Path $Root 'templates\opencode.v1.json.tmpl'
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

function Validate-TemplateV2([string]$Root, [string]$Planner, [string]$Cheap, [string]$Strong) {
  # Espelho V2 de Validate-Template: shape nativo (agents/permissions/
  # experimental.subagent_depth), 17 blocos agents, build sem model,
  # tokens resolvidos. Mesmos exit paths (precheck exit 3, nada escrito).
  $errs = @()
  $tmplPath = Join-Path $Root 'templates\opencode.v2.json.tmpl'
  if (-not (Test-Path -LiteralPath $tmplPath -PathType Leaf)) {
    return @{ Ok = $false; Errors = @('template V2 ausente'); Desired = $null }
  }
  $resolved = Resolve-Tokens (Read-Utf8 $tmplPath) $Planner $Cheap $Strong $env:USERPROFILE $Root
  try {
    $desired = $resolved | ConvertFrom-Json
  }
  catch {
    return @{ Ok = $false; Errors = @('template V2 nao e JSON valido pos-token: ' + $_.Exception.Message); Desired = $null }
  }
  $agentCount = 0
  if (Has-Member $desired 'agents') {
    $agentCount = @($desired.agents.PSObject.Properties.Name).Count
  }
  if ($agentCount -ne 17) { $errs += ('template V2: esperado 17 blocos agents, encontrado ' + $agentCount) }
  if (Has-Member $desired 'agents') {
    if (Has-Member $desired.agents 'build') {
      if (Has-Member $desired.agents.build 'model') {
        $errs += 'template V2: bloco build nao deve conter "model" (DH-03, heranca de sessao).'
      }
      if (-not (Has-Member $desired.agents.build 'permissions')) {
        $errs += 'template V2: bloco agents.build sem permissions array.'
      }
    }
    else { $errs += 'template V2: bloco agents.build ausente.' }
    if (Has-Member $desired.agents 'title') {
      if (Has-Member $desired.agents.title 'permissions') {
        $errs += 'template V2: bloco title nao deve conter permissions.'
      }
    }
    else { $errs += 'template V2: bloco agents.title ausente.' }
  }
  else { $errs += 'template V2: bloco agents ausente.' }
  if (Has-Member $desired 'agent') { $errs += 'template V2: contem chave legada "agent" (singular).' }
  if (Has-Member $desired 'subagent_depth') { $errs += 'template V2: contem chave legada "subagent_depth" no topo (use experimental.subagent_depth).' }
  if (-not (Has-Member $desired 'experimental')) { $errs += 'template V2: bloco experimental ausente.' }
  if ((Has-Member $desired 'experimental') -and ($null -ne $desired.experimental) -and (Has-Member $desired.experimental 'subagent_depth')) {
    $sdV2 = $desired.experimental.subagent_depth
    $sdOkV2 = $false
    if (($sdV2 -is [int]) -or ($sdV2 -is [long])) { if ([int64]$sdV2 -ge 1) { $sdOkV2 = $true } }
    elseif ($sdV2 -is [double]) { if (($sdV2 -eq [Math]::Floor($sdV2)) -and ($sdV2 -ge 1)) { $sdOkV2 = $true } }
    if (-not $sdOkV2) { $errs += 'template V2: experimental.subagent_depth deve ser inteiro >= 1.' }
  }
  else { $errs += 'template V2: experimental.subagent_depth ausente.' }
  if (Has-Member $desired 'agents') {
    if (($null -eq $desired.agents) -or ($desired.agents -is [array]) -or ($desired.agents -is [string])) {
      $errs += 'template V2: bloco agents deve ser objeto.'
    }
    else {
      foreach ($akV2 in @($desired.agents.PSObject.Properties.Name)) {
        $nodeV2 = $desired.agents.$akV2
        if (($null -ne $nodeV2) -and (Has-Member $nodeV2 'permissions')) {
          $permsV2 = $nodeV2.permissions
          if (-not ($permsV2 -is [array])) {
            $errs += ('template V2: agents.' + $akV2 + '.permissions deve ser array.')
          }
          else {
            $piV2 = 0
            foreach ($pV2 in @($permsV2)) {
              $entryOkV2 = $true
              if (($null -eq $pV2) -or (-not (Has-Member $pV2 'action')) -or (-not ($pV2.action -is [string])) -or ([string]$pV2.action -eq '')) { $entryOkV2 = $false }
              if (($null -eq $pV2) -or (-not (Has-Member $pV2 'resource')) -or (-not ($pV2.resource -is [string])) -or ([string]$pV2.resource -eq '')) { $entryOkV2 = $false }
              if (($null -eq $pV2) -or (-not (Has-Member $pV2 'effect'))) { $entryOkV2 = $false }
              elseif (@('allow', 'ask', 'deny') -cnotcontains [string]$pV2.effect) { $entryOkV2 = $false }
              if (-not $entryOkV2) { $errs += ('template V2: agents.' + $akV2 + '.permissions[' + $piV2 + '] requer action/resource/effect validos (effect em allow|ask|deny).') }
              $piV2 += 1
            }
          }
        }
      }
      if ((Has-Member $desired.agents 'build') -and ($null -ne $desired.agents.build) -and (Has-Member $desired.agents.build 'permissions')) {
        $bpV2 = $desired.agents.build.permissions
        if (($bpV2 -is [array]) -and (@($bpV2).Count -gt 0)) {
          $firstV2 = @($bpV2)[0]
          if (($null -eq $firstV2) -or ([string]$firstV2.action -ne 'subagent') -or ([string]$firstV2.resource -ne '*') -or ([string]$firstV2.effect -ne 'deny')) {
            $errs += 'template V2: agents.build.permissions[0] deve ser {action:subagent, resource:*, effect:deny}.'
          }
        }
        else {
          $errs += 'template V2: bloco agents.build sem permissions array.'
        }
      }
    }
  }
  if ((Count-TokenMarkers $resolved) -ne 0) { $errs += 'template V2: tokens nao resolvidos apos substituicao.' }
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

function Validate-PluginBundle([string]$Root) {
  # P4: o instalador distribui o BUNDLE autocontido (a fonte .ts tem
  # imports relativos ./v1 ./v2 ./shared/* que quebrariam copiados
  # sozinhos). Ausente/invalido => exit 6 sem escrita parcial; regenere
  # com scripts/build-plugin.ps1.
  # V31-R2 F2: validacao deterministica por INTEGRIDADE (primeira camada):
  # bundle existe, sidecar .sha256 existe, Get-FileHash(bundle) == sidecar
  # (case-insensitive, trim). Mismatch ou sidecar ausente => falha ANTES de
  # qualquer escrita (rebuild com scripts/build-plugin.ps1). Os checks de
  # marcadores seguem como segunda camada.
  $p = Join-Path $Root 'plugins\dist\orchestration-enforcement.js'
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
    return @{ Ok = $false; Errors = @('plugin bundle ausente: plugins\dist\orchestration-enforcement.js nao encontrado no repo. Regenere com: powershell -NoProfile -File scripts\build-plugin.ps1') }
  }
  $side = $p + '.sha256'
  if (-not (Test-Path -LiteralPath $side -PathType Leaf)) {
    return @{ Ok = $false; Errors = @('plugin bundle sem sidecar de integridade: plugins\dist\orchestration-enforcement.js.sha256 ausente. Regenere com: powershell -NoProfile -File scripts\build-plugin.ps1') }
  }
  $actual = Get-Sha256HexLower $p
  $expected = ''
  try {
    $expected = ([IO.File]::ReadAllText($side, [Text.Encoding]::UTF8)).Trim().ToLowerInvariant()
  }
  catch {
    return @{ Ok = $false; Errors = @('plugin bundle com sidecar ilegivel: plugins\dist\orchestration-enforcement.js.sha256 nao pode ser lido. Regenere com: powershell -NoProfile -File scripts\build-plugin.ps1') }
  }
  if (($expected -ne $actual) -or ([string]::IsNullOrWhiteSpace($expected))) {
    return @{ Ok = $false; Errors = @('plugin bundle com hash divergente do sidecar (sidecar=' + $expected + ' bundle=' + $actual + '). Regenere com: powershell -NoProfile -File scripts\build-plugin.ps1') }
  }
  $t = Read-Utf8 $p
  if ((-not $t.Contains('orchestration-enforcement:')) -or (-not $t.Contains('server'))) {
    return @{ Ok = $false; Errors = @('plugin bundle sem marcadores minimos (orchestration-enforcement: + server). Regenere com: powershell -NoProfile -File scripts\build-plugin.ps1') }
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

# ---- Phase 6: smoke V2 pos-install (best-effort) ------------------------------
# DECISAO Phase 6: smoke roda apos o apply como VALIDACAO POS com warning
# (exit 0 mantido). Smoke bloqueante (exit 5 / rollback) entra na Phase 8
# (CI). Motivo: install em TargetHome isolado nao requer binario global;
# binario ausente ou nao-V2 => smoke skipped com motivo, arquivos ok.
function Invoke-V2PostInstallSmoke([string]$TargetHome) {
  try {
    $bin = Get-Command 'opencode' -ErrorAction SilentlyContinue
    if ($null -eq $bin) {
      Write-Host '[smoke v2] skipped: binario opencode ausente no PATH (install de arquivos ok).' -ForegroundColor Yellow
      return
    }
    $pr = Invoke-RuntimeProbe -ProbeCommand @('opencode', '--version') -TimeoutMs 15000
    if (-not $pr.Ok) {
      Write-Host ('[smoke v2] skipped: probe de versao indisponivel (' + [string]$pr.Reason + ').') -ForegroundColor Yellow
      return
    }
    $parsed = Get-RuntimeFromVersionOutput -VersionText $pr.Output
    if ((-not $parsed.Known) -or ([int]$parsed.Generation -ne 2)) {
      Write-Host ('[smoke v2] skipped: binario no PATH nao e V2 (' + [string]$parsed.Reason + ').') -ForegroundColor Yellow
      return
    }
    $verLine = ([string]$pr.Output -split "`r?`n" | Select-Object -First 1)
    Write-Host ('[smoke v2] version 2.x reconhecida: ' + $verLine) -ForegroundColor DarkGray
    # debug paths sob XDG isolado: valida que o binario real resolve o
    # config root dentro do TargetHome instalado (prova de isolamento).
    # NOTA: `debug config` trava headless (aguarda o background service;
    # verificado: --help instantaneo, chamada nua trava >15s mesmo com stdin
    # fechado) e foi trocado por `debug paths` aqui; validacao completa
    # (incl. parse com default_agent e plugin load V2) fica para a Phase 8.
    # Sem Kill de arvore: debug paths responde rapido e nao deixa orfaos.
    $oldXdg = $env:XDG_CONFIG_HOME
    try {
      $env:XDG_CONFIG_HOME = $TargetHome
      $dc = Invoke-RuntimeProbe -ProbeCommand @('opencode', 'debug', 'paths') -TimeoutMs 20000
    }
    finally {
      $env:XDG_CONFIG_HOME = $oldXdg
    }
    if (-not $dc.Ok) {
      Write-Host ('[smoke v2] warning: opencode debug paths indisponivel (' + [string]$dc.Reason + '); validacao completa na Phase 8.') -ForegroundColor Yellow
      return
    }
    $homeSlash = ($TargetHome -replace '\\', '/')
    $homeBack = ($TargetHome -replace '/', '\')
    if ((([string]$dc.Output).Contains($homeSlash)) -or (([string]$dc.Output).Contains($homeBack))) {
      Write-Host '[smoke v2] ok: debug paths resolve config dentro do TargetHome instalado.' -ForegroundColor Green
    }
    else {
      Write-Host '[smoke v2] warning: debug paths sem TargetHome no output; validacao completa na Phase 8.' -ForegroundColor Yellow
    }
  }
  catch {
    Write-Host ('[smoke v2] warning: smoke falhou sem bloquear (' + $_.Exception.Message + ').') -ForegroundColor Yellow
  }
}

# ---- main -------------------------------------------------------------------
$ocDir = Join-Path $TargetHome '.config\opencode'
$modelsPath = Join-Path $RepoRoot 'models.jsonc'

$preErrors = New-Object System.Collections.ArrayList

$modelsRes = Validate-Models $modelsPath
if (-not $modelsRes.Ok) { foreach ($e in $modelsRes.Errors) { [void]$preErrors.Add($e) } }

# ---- Phase 6 (V3.1): runtime resolution ANTES do precheck de templates -----
# V31-R3 F3: -Runtime V1 exige so o template v1; -Runtime V2 exige so o v2;
# Auto exige so o do alvo resolvido. Fail closed (exit 6) sem escrita quando
# nao resolvido. Nao altera o caminho legado V1.
$runtimeLib = Join-Path $RepoRoot 'scripts\runtime\lib\RuntimeAdapters.ps1'
$runtimeRegistryPath = Join-Path $RepoRoot 'source\registry\runtimes.json'
try {
  . $runtimeLib
  $runtimeRegistry = Read-RuntimeRegistry -RegistryPath $runtimeRegistryPath
}
catch {
  Write-Host ('[install] runtime=' + $Runtime + ' decision=unresolved reason=registry ilegivel: ' + $_.Exception.Message) -ForegroundColor Red
  Write-Host 'Resolucao do runtime falhou. Passe -Runtime V1 para o comportamento legado.' -ForegroundColor Red
  exit 6
}
$runtimeMode = $Runtime
$runtimeDecision = $null
if ($runtimeMode -eq 'Both') {
  Write-Host ('[install] runtime=Both decision=deferred reason=perfis isolados chegam na Phase 7 do plano V3.1')
  Write-Host 'Modo Both bloqueado nesta fase: perfis isolados chegam na Phase 7. Use -Runtime V1, V2 ou Auto. Nada foi escrito.' -ForegroundColor Red
  exit 6
}
$runtimeBin = Get-Command 'opencode' -ErrorAction SilentlyContinue
# V31-P6-FIX-EXPLICIT: -Runtime explicito vence; probe SOMENTE no Auto.
# V1/V2 explicitos resolvem o descriptor direto, SEM probe e SEM conflito
# (instalar V2 num TargetHome isolado com V1 global no PATH e o caso de uso
# primario da Phase 7 wrappers). A lib mantem o ramo conflict quando o
# CHAMADOR passa ProbeCommand explicitamente (dupla checagem opt-in); o
# installer nao usa esse ramo.
if (($runtimeMode -eq 'V1') -or ($runtimeMode -eq 'V2')) {
  $runtimeDecision = Resolve-OpencodeRuntime -Registry $runtimeRegistry -Mode $runtimeMode
  Write-Host ('[install] runtime=' + $runtimeMode + ' decision=' + [string]$runtimeDecision.Decision + ' reason=' + [string]$runtimeDecision.Reason)
}
else {
  if ($null -ne $runtimeBin) {
    $runtimeDecision = Resolve-OpencodeRuntime -Registry $runtimeRegistry -Mode 'Auto' -ProbeCommand @('opencode', '--version')
  }
  else {
    $runtimeDecision = Resolve-OpencodeRuntime -Registry $runtimeRegistry -Mode 'Auto' -ProbeCommand @('__missing-opencode-binary__')
  }
  $autoId = ''
  if ($null -ne $runtimeDecision.RuntimeId) { $autoId = [string]$runtimeDecision.RuntimeId }
  if (([string]$runtimeDecision.Decision -eq 'target') -and (($autoId -eq 'opencode-v1') -or ($autoId -eq 'opencode-v2'))) {
    Write-Host ('[install] runtime=Auto decision=target runtime=' + $autoId + ' reason=' + [string]$runtimeDecision.Reason)
  }
  elseif ([bool]$runtimeDecision.ProbeError) {
    $binNow = Get-Command 'opencode' -ErrorAction SilentlyContinue
    if ($null -eq $binNow) {
      Write-Host ('[install] runtime probe indisponivel (' + [string]$runtimeDecision.Reason + '); assumindo V1 (comportamento legado)')
      $runtimeDecision = @{ Decision = 'target'; RuntimeId = 'opencode-v1'; Generation = 1; Reason = 'fallback legado (binario ausente, probe indisponivel)'; ProbeError = $true; ProbeErrorKind = 'binary-missing'; Mode = 'Auto'; ProbeOutput = '' }
    }
    else {
      Write-Host ('[install] runtime=Auto decision=unresolved reason=probe inconclusivo com binario presente: ' + [string]$runtimeDecision.Reason) -ForegroundColor Red
      Write-Host 'Probe do binario opencode inconclusivo (timeout/falha/saida vazia ou nao parseavel). Passe -Runtime V1 para forcar o comportamento legado. Nada foi escrito.' -ForegroundColor Red
      exit 6
    }
  }
  else {
    Write-Host ('[install] runtime=Auto decision=' + [string]$runtimeDecision.Decision + ' reason=' + [string]$runtimeDecision.Reason) -ForegroundColor Red
    Write-Host 'Runtime ambiguo ou nao reconhecido. Passe -Runtime V1 para o comportamento legado. Nada foi escrito.' -ForegroundColor Red
    exit 6
  }
}
$preRuntimeId = 'opencode-v1'
if (($null -ne $runtimeDecision) -and ($null -ne $runtimeDecision.RuntimeId)) { $preRuntimeId = [string]$runtimeDecision.RuntimeId }
$preTemplates = @(Get-RequiredTemplatesForRuntime $preRuntimeId)
$preIsV2 = ($preRuntimeId -eq 'opencode-v2')

$reqRes = Validate-RequiredFiles $RepoRoot $preTemplates
if (-not $reqRes.Ok) { foreach ($e in $reqRes.Errors) { [void]$preErrors.Add($e) } }

$defsRes = Validate-AgentDefinitions $RepoRoot
if (-not $defsRes.Ok) { foreach ($e in $defsRes.Errors) { [void]$preErrors.Add($e) } }

$tmplRes = @{ Ok = $false; Errors = @(); Desired = $null }
$tmplResV2 = @{ Ok = $false; Errors = @(); Desired = $null }
if ($modelsRes.Ok) {
  if ($preIsV2) {
    $tmplResV2 = Validate-TemplateV2 $RepoRoot $modelsRes.Values.planner $modelsRes.Values.cheap $modelsRes.Values.strong
    if (-not $tmplResV2.Ok) { foreach ($e in $tmplResV2.Errors) { [void]$preErrors.Add($e) } }
  }
  else {
    $tmplRes = Validate-Template $RepoRoot $modelsRes.Values.planner $modelsRes.Values.cheap $modelsRes.Values.strong
    if (-not $tmplRes.Ok) { foreach ($e in $tmplRes.Errors) { [void]$preErrors.Add($e) } }
  }
}
else {
  [void]$preErrors.Add('templates nao validados (modelos invalidos).')
}

$plugRes = Validate-PluginSource $RepoRoot
if (-not $plugRes.Ok) { foreach ($e in $plugRes.Errors) { [void]$preErrors.Add($e) } }

$bundleRes = Validate-PluginBundle $RepoRoot
if (-not $bundleRes.Ok) {
  foreach ($e in $bundleRes.Errors) { Write-Host ('[install] ' + $e) -ForegroundColor Red }
  Write-Host 'Bundle do plugin ausente/invalido. Regenere com scripts\build-plugin.ps1. Nenhuma escrita realizada.' -ForegroundColor Red
  exit 6
}

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

# Runtime ja resolvido no precheck (V31-R3 F3); aqui so deriva o fluxo.
$IsV2 = ([string]$runtimeDecision.RuntimeId -eq 'opencode-v2')
$RuntimeId = 'opencode-v1'
$RuntimeGeneration = 1
$RuntimeProfile = 'v1'
if ($IsV2) {
  $RuntimeId = 'opencode-v2'
  $RuntimeGeneration = 2
  $RuntimeProfile = 'v2'
  $OpenCodePluginSpec = $OpenCodePluginSpecV2
  $desired = $tmplResV2.Desired
}
else {
  $desired = $tmplRes.Desired
}

# Conteudo desejado em memoria (sem writes) -----------------------------------
$header = @'
<!-- GENERATED FILE: direct edits will be overwritten. -->
<!-- Canonical source: source/; regenerate with scripts/render-opencode-config.ps1. -->
<!-- This file is active only after scripts/reconcile-opencode-config.ps1 applies it. -->
'@
$globalBody = Read-Utf8 (Join-Path $RepoRoot 'source\global\AGENTS.md')
$adapterRel = 'source\adapters\opencode.md'
if ($IsV2) { $adapterRel = 'source\adapters\opencode-v2.md' }
$adapterBody = Read-Utf8 (Join-Path $RepoRoot $adapterRel)
$agentsContent = Resolve-Tokens (($globalBody.TrimEnd() + "`n`n" + $adapterBody.TrimEnd()).TrimEnd() + "`n") $modelPlanner $modelCheap $modelStrong $TargetHome $RepoRoot

$agentsTargetPath = Join-Path $ocDir 'AGENTS.md'
$existingAgentsMd = $null
if (Test-Path -LiteralPath $agentsTargetPath -PathType Leaf) { $existingAgentsMd = Read-Utf8 $agentsTargetPath }
$agentsMdRes = Merge-ManagedAgentsMdBlock $existingAgentsMd $agentsContent $header

$repoEsc = $RepoRoot.Replace('\', '\\')
$agentFiles = @()
if ($IsV2) {
  # V2: frontmatter nativo (permissions array) via AgentTranslator pura
  # (dot-source local, sem rede/binario/escrita). Corpo markdown intacto;
  # tokens e bloco orchestration tratados igual ao V1 abaixo.
  . (Join-Path $RepoRoot 'scripts\runtime\lib\AgentTranslator.ps1')
  foreach ($f in @(Get-ChildItem -File (Join-Path $RepoRoot 'source\agents\*.md') | Sort-Object Name)) {
    try {
      $parsedV2 = Read-AgentFileCanonical -Path $f.FullName
    }
    catch {
      Write-Host ('PRECHECK FAILED (exit 3): agente V2 nao traduz (parse canonico): ' + $f.Name + ': ' + $_.Exception.Message) -ForegroundColor Red
      exit 3
    }
    try {
      $resV2 = Convert-CanonicalToV2Frontmatter -Canonical $parsedV2.Canonical
    }
    catch {
      Write-Host ('PRECHECK FAILED (exit 3): agente V2 nao traduz (emissao V2): ' + $f.Name + ': ' + $_.Exception.Message) -ForegroundColor Red
      exit 3
    }
    $fmText = [string]$resV2.Text
    $fmText = $fmText.Replace('{{MODEL_PLANNER}}', $modelPlanner)
    $fmText = $fmText.Replace('{{MODEL_CHEAP}}', $modelCheap)
    $fmText = $fmText.Replace('{{MODEL_STRONG}}', $modelStrong)
    $fmText = $fmText.Replace('{{REPO_DIR}}', $repoEsc)
    $fmText = $fmText.Replace('{{HOME}}', ($TargetHome -replace '\\', '/'))
    $bodyV2 = [string]$parsedV2.Body
    $bodyV2 = $bodyV2.Replace('{{REPO_DIR}}', $repoEsc)
    $bodyV2 = $bodyV2.Replace('{{HOME}}', ($TargetHome -replace '\\', '/'))
    $fullV2 = ('---' + "`n" + $fmText + "`n" + '---' + "`n" + $bodyV2)
    $noNl = ($fullV2 -replace "`r`n", "`n" -replace "`r", "`n")
    $clean = Remove-OrchestrationBlock ($noNl -split "`n")
    $agentFiles += @{ Name = $f.Name; Text = ($clean.TrimEnd() + "`n") }
  }
}
else {
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
}

# P4: o instalado e o BUNDLE autocontido (fonte .ts tem imports relativos
# que quebrariam copiados sozinhos). O RelativePath de destino e composto
# por concatenacao (padrao P9.1 dos demais grupos gerenciados), nao por
# literal de caminho do repo.
$pluginBundleName = 'orchestration-enforcement.js'
$pluginText = Read-Utf8 (Join-Path $RepoRoot 'plugins\dist\orchestration-enforcement.js')
$pluginDst = Join-Path $ocDir ('plugins\' + $pluginBundleName)

$skillsSrc = Join-Path $RepoRoot 'skills-core'
$skillsDst = Join-Path $ocDir 'skills'
$skillNames = @('dispatching-parallel-agents', 'hybrid-development', 'subagent-driven-development', 'using-superpowers', 'verification-before-completion')

# Formato do config: opencode.json e/ou opencode.jsonc. O runtime (OpenCode V1)
# suporta ambos e, se AMBOS existirem no mesmo diretorio, faz merge com o
# jsonc vencendo conflitos. O instalador respeita a mesma precedencia:
# jsonc presente => alvo e o jsonc; senao, alvo e o json (criado se nada
# existir). Quando ambos existem, opencode.json e chave/arquivo do usuario
# (PRESERVE no plano) e so o jsonc e operado.
$jsonCandidatePath = Join-Path $ocDir 'opencode.json'
$jsoncCandidatePath = Join-Path $ocDir 'opencode.jsonc'
$jsonExistsNow = Test-Path -LiteralPath $jsonCandidatePath -PathType Leaf
$jsoncExistsNow = Test-Path -LiteralPath $jsoncCandidatePath -PathType Leaf
$configFileName = 'opencode.json'
if ($jsoncExistsNow) { $configFileName = 'opencode.jsonc' }
$jsonPath = Join-Path $ocDir $configFileName
$bothConfigsExist = ($jsonExistsNow -and $jsoncExistsNow)
$existingJsonObj = $null
$existingJsonRaw = $null
$configHadComments = $false
if (Test-Path -LiteralPath $jsonPath -PathType Leaf) {
  try {
    $existingJsonRaw = Read-Utf8 $jsonPath
    $strippedExisting = Strip-JsoncComments $existingJsonRaw
    if ($strippedExisting -ne $existingJsonRaw) { $configHadComments = $true }
    $existingJsonObj = $strippedExisting | ConvertFrom-Json
  }
  catch {
    Write-Host ('PRECHECK FAILED (exit 3): ' + $configFileName + ' existente nao parseia (JSONC): ' + $_.Exception.Message) -ForegroundColor Red
    exit 3
  }
}
$mergedObj = $null
$managedPaths = @()
# adopted_paths: mantido no manifest (mesmo vazio) para compatibilidade com
# consumers; o pacote nao adota mais nenhuma chave (ownership trim).
$adoptedNow = @()
if ($null -eq $existingJsonObj) {
  $mergedObj = $desired
  if ($IsV2) { $managedPaths = @(Get-DesiredManagedPathsV2 $desired) }
  else { $managedPaths = @(Get-DesiredManagedPaths $desired) }
}
else {
  $clone = (Strip-JsoncComments $existingJsonRaw) | ConvertFrom-Json
  if ($IsV2) {
    $mergeRes = Merge-ManagedOpencodeConfigV2 $clone $desired
    $mergedObj = $mergeRes.Config
    $managedPaths = @(Get-DesiredManagedPathsV2 $desired)
  }
  else {
    $mergeRes = Merge-ManagedOpencodeConfig $clone $desired
    $mergedObj = $mergeRes.Config
    $managedPaths = @(Get-DesiredManagedPaths $desired)
  }
}
$mergedText = (($mergedObj | ConvertTo-Json -Depth 32).TrimEnd() + "`n")

# ---- P9.1 operacoes gerenciadas (fonte unica de verdade de paths) -----------
# Cada arquivo gerenciado vira UMA operacao com RelativePath imutavel,
# SourcePath na fonte canonica, StagePath e DestinationPath derivados por
# Join-Path a partir do RelativePath (nunca por Substring de FullName).
$ops = New-Object System.Collections.ArrayList
[void]$ops.Add(@{ Component = 'agents-md'; RelativePath = 'AGENTS.md'; StageText = $agentsMdRes.Text; Label = 'AGENTS.md' })
foreach ($a in $agentFiles) {
  [void]$ops.Add(@{ Component = 'agents'; RelativePath = ('agents\' + $a.Name); StageText = $a.Text; Label = ('agents/' + $a.Name) })
}
if (-not $NoCoreSkills) {
  foreach ($s in $skillNames) {
    $skillSrcDir = Join-Path $skillsSrc $s
    foreach ($sf in @(Get-ManagedSourceFiles $skillSrcDir)) {
      if (-not (Test-ManagedRelativePath $sf.RelativePath)) {
        throw ('relative path invalido na fonte da skill: ' + $sf.RelativePath)
      }
      Assert-PathUnder $sf.SourcePath $skillSrcDir ('fonte da skill ' + $s)
      [void]$ops.Add(@{
        Component = 'skills'; Skill = $s
        RelativePath = ('skills\' + $s + '\' + $sf.RelativePath)
        SourcePath = $sf.SourcePath
        Label = ('skills/' + $s + '/' + ($sf.RelativePath -replace '\\', '/'))
      })
    }
  }
}
[void]$ops.Add(@{ Component = 'plugin'; RelativePath = ('plugins\' + $pluginBundleName); StageText = $pluginText; Label = ('plugins/' + $pluginBundleName) })
# Config: RelativePath/Label reais detectados (opencode.json ou opencode.jsonc).
# Todo o pipeline (stage/CAS/apply/manifest/rollback) segue keyed em
# Component='config' com esse RelativePath — nada hardcoded a 'opencode.json'.
$configRelPath = $configFileName
$configLabel = $configFileName
[void]$ops.Add(@{ Component = 'config'; RelativePath = $configRelPath; StageText = $mergedText; Label = $configLabel })

foreach ($op in $ops) {
  $dstOp = Join-Path $ocDir $op.RelativePath
  Assert-PathUnder $dstOp $ocDir ('destino de ' + $op.Label)
  Assert-NoReparseUnder $ocDir $dstOp ('destino de ' + $op.Label)
  $op.DestinationPath = $dstOp
}
# Junction na PROPRIA raiz gerenciada = redirecionamento deliberado do
# usuario (ex.: .config em outro drive); nao e bloqueado, mas e sinalizado.
if (Test-Path -LiteralPath $ocDir -PathType Container) {
  $ocRootItem = Get-Item -LiteralPath $ocDir -Force
  if (($ocRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    Write-Host ('AVISO: ' + $ocDir + ' e junction/reparse point; as escritas seguem o redirecionamento definido pelo usuario.') -ForegroundColor Yellow
  }
}

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
    # Comparacao normalizada (EOL) entre fonte canonica e destino: o installer
    # grava LF deliberadamente, entao conteudo equivalente com EOL diferente
    # NAO e divergencia. Idempotencia: tudo igual => SKIP.
    $dstDir = Join-Path $skillsDst $s
    if (-not (Test-Path -LiteralPath $dstDir)) { Add-Plan 'CREATE' ('skills/' + $s + '/'); continue }
    $diff = $false
    foreach ($op in @($ops | Where-Object { ($_.Component -eq 'skills') -and ($_.Skill -eq $s) })) {
      if (-not (Test-Path -LiteralPath $op.DestinationPath -PathType Leaf)) { $diff = $true; break }
      $srcTxt = Read-Utf8 $op.SourcePath
      $a2 = (($srcTxt -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd() + "`n")
      $b2 = ((Read-Utf8 $op.DestinationPath) -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd() + "`n"
      if ($a2 -ne $b2) { $diff = $true; break }
    }
    if ($diff) { Add-Plan 'UPDATE' ('skills/' + $s + '/') }
    else { Add-Plan 'SKIP' ('skills/' + $s + '/ (inalterado)') }
  }
}
else {
  foreach ($s in $skillNames) { Add-Plan 'SKIP' ('skills/' + $s + '/ (NoCoreSkills)') }
}
File-Plan $pluginDst $pluginText ((('plugins/' + $pluginBundleName) + ' (bundle autocontido)'))
# V31-R2 F1: upgrade de installs anteriores (pre-bundle) pode ter deixado
# o legado plugins/orchestration-enforcement.ts no home. Antes de escrever
# o bundle .js, o legado e adotado para o backup do install e removido
# (o bundle .js assume). Qualquer OUTRO .ts/.js no plugins dir e
# user-owned: nunca tocado (PRESERVE so como evidencia de plano).
$legacyPluginRel = 'plugins\orchestration-enforcement.ts'
$legacyPluginDst = Join-Path $ocDir $legacyPluginRel
$legacyExists = Test-Path -LiteralPath $legacyPluginDst -PathType Leaf
$legacyAdopted = $null
$legacyBakDst = $null
if ($legacyExists) {
  Add-Plan 'REMOVE' 'plugins/orchestration-enforcement.ts (legado pre-bundle; adotado para backup, bundle .js assume)'
}
$pluginHomeDir = Join-Path $ocDir 'plugins'
if (Test-Path -LiteralPath $pluginHomeDir -PathType Container) {
  foreach ($uf in @(Get-ChildItem -File -LiteralPath $pluginHomeDir -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $ufExt = ([IO.Path]::GetExtension($uf.Name)).ToLowerInvariant()
    if (($ufExt -ne '.ts') -and ($ufExt -ne '.js')) { continue }
    if (($uf.Name -ceq $pluginBundleName) -or ($uf.Name -ceq 'orchestration-enforcement.ts')) { continue }
    Add-Plan 'PRESERVE' ('plugins/' + $uf.Name + ' (arquivo do usuario, intacto)')
  }
}
if ($bothConfigsExist) {
  Add-Plan 'PRESERVE' 'opencode.json (presente junto de jsonc; runtime faz merge com jsonc vencendo)'
}
if ($null -eq $existingJsonObj) {
  Add-Plan 'CREATE' ($configFileName + ' (merged completo)')
}
elseif ($IsV2) {
  # Plano V2: mesma semantica do V1 sobre o dialeto nativo (agents/
  # permissions/experimental.subagent_depth). Agentes e chaves desconhecidas
  # sao PRESERVE (nunca tocados).
  $before = $existingJsonObj
  $after = $mergedObj
  foreach ($mp in @('$schema', 'model', 'default_agent')) {
    $bv = $null; $av = $null
    if (Has-Member $before $mp) { $bv = Convert-Canonical $before.$mp }
    if (Has-Member $after $mp) { $av = Convert-Canonical $after.$mp }
    if ($bv -ne $av) {
      Add-Plan 'UPDATE' $mp
    }
  }
  $bev = $null; $aev = $null
  if ((Has-Member $before 'experimental') -and ($null -ne $before.experimental) -and (Has-Member $before.experimental 'subagent_depth')) { $bev = Convert-Canonical $before.experimental.subagent_depth }
  if ((Has-Member $after 'experimental') -and ($null -ne $after.experimental) -and (Has-Member $after.experimental 'subagent_depth')) { $aev = Convert-Canonical $after.experimental.subagent_depth }
  if ($bev -ne $aev) { Add-Plan 'UPDATE' 'experimental.subagent_depth' }
  if (Has-Member $after 'agents') {
    foreach ($ak in @($after.agents.PSObject.Properties.Name)) {
      $isKnown = Has-Member $desired.agents $ak
      if (-not $isKnown) { continue }
      foreach ($leaf in @('mode', 'model', 'permissions')) {
        $hasB = (Has-Member $before.agents $ak) -and (Has-Member $before.agents.$ak $leaf)
        $bv = $null
        if ($hasB) { $bv = Convert-Canonical $before.agents.$ak.$leaf }
        $hasA = (Has-Member $after.agents $ak) -and (Has-Member $after.agents.$ak $leaf)
        $av = $null
        if ($hasA) { $av = Convert-Canonical $after.agents.$ak.$leaf }
        if ($ak -eq 'build' -and $leaf -eq 'model') {
          if ($hasB) { Add-Plan 'UPDATE' 'agents.build.model (REMOVIDO, heranca de sessao)' }
          continue
        }
        if ($bv -ne $av) { Add-Plan 'UPDATE' ('agents.' + $ak + '.' + $leaf) }
      }
    }
  }
  if (Has-Member $before 'mcp') { Add-Plan 'PRESERVE' 'mcp.*' }
  $knownTopV2 = @('$schema', 'model', 'default_agent', 'experimental', 'agents', 'mcp')
  foreach ($tk in @($before.PSObject.Properties.Name)) {
    if ($knownTopV2 -notcontains $tk) { Add-Plan 'PRESERVE' ($tk + ' (chave de topo desconhecida)') }
  }
  if ((Has-Member $before 'experimental') -and ($null -ne $before.experimental)) {
    foreach ($ek in @($before.experimental.PSObject.Properties.Name)) {
      if ($ek -ne 'subagent_depth') { Add-Plan 'PRESERVE' ('experimental.' + $ek + ' (propriedade desconhecida)') }
    }
  }
  if ((Has-Member $before 'agents') -and ($null -ne $before.agents)) {
    foreach ($ak in @($before.agents.PSObject.Properties.Name)) {
      if (-not (Has-Member $desired.agents $ak)) {
        Add-Plan 'PRESERVE' ('agents.' + $ak + ' (agente desconhecido, intacto)')
        continue
      }
      foreach ($prop in @($before.agents.$ak.PSObject.Properties.Name)) {
        if (@('mode', 'model', 'permissions') -notcontains $prop) {
          Add-Plan 'PRESERVE' ('agents.' + $ak + '.' + $prop + ' (propriedade desconhecida)')
        }
      }
    }
  }
  if ((Has-Member $before 'agents') -and (Has-Member $before.agents 'build')) {
    if (Has-Member $before.agents.build 'model') {
      Add-Plan 'UPDATE' 'agents.build.model (REMOVIDO, heranca de sessao)'
    }
  }
  if (($configFileName -eq 'opencode.jsonc') -and $configHadComments) {
    Add-Plan 'UPDATE' 'opencode.jsonc (merged; comentarios normalizados)'
  }
}
else {
  $before = $existingJsonObj
  $after = $mergedObj
  foreach ($mp in @('$schema', 'model', 'default_agent', 'subagent_depth')) {
    $bv = $null; $av = $null
    if (Has-Member $before $mp) { $bv = Convert-Canonical $before.$mp }
    if (Has-Member $after $mp) { $av = Convert-Canonical $after.$mp }
    if ($bv -ne $av) {
      Add-Plan 'UPDATE' $mp
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
  if (Has-Member $before 'mcp') { Add-Plan 'PRESERVE' 'mcp.*' }
  # skills/plugin/autoupdate (e qualquer outra chave de topo fora do
  # ownership) caem no loop de chaves desconhecidas abaixo (PRESERVE).
  $knownTop = @('$schema', 'model', 'default_agent', 'subagent_depth', 'agent', 'mcp')
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
  if (($configFileName -eq 'opencode.jsonc') -and $configHadComments) {
    Add-Plan 'UPDATE' 'opencode.jsonc (merged; comentarios normalizados)'
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
foreach ($op in $ops) { $expectedHashes[$op.DestinationPath] = Get-FileHashSafe $op.DestinationPath }

# Backup -----------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bakDir = Join-Path $ocDir ("backups\oo-" + $stamp)
$backupCount = 0
$backupMap = @{}
try {
  # V31-R2-RESIDUAL R1: remocao fisica do legado ADIADA para pos-CAS
  # (estagio apply). Aqui apenas backup dos alvos; nenhum .ts e tocado
  # antes do CAS, logo exit 4 sai com o legado intacto. Ver bloco
  # pos-CAS "adocao tardia do legado".
  foreach ($op in $ops) {
    if (Test-Path -LiteralPath $op.DestinationPath -PathType Leaf) {
      $dest = Join-Path $bakDir $op.RelativePath
      if ($PSCmdlet.ShouldProcess($dest, 'Backup')) {
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $op.DestinationPath -Destination $dest -Force
        $backupMap[$op.DestinationPath] = $dest
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
    # STAGE CANONICO: uma unica passada sobre $ops. StagePath = Join-Path(
    # stageDir, RelativePath), validado contra a raiz do stage. Todos os
    # stage files passam por Write-FileAtomic (LF, UTF-8 sem BOM). Evita
    # divergencia pos-hash quando o checkout esta em CRLF
    # (core.autocrlf=true): o apply (text round-trip) vira no-op de
    # normalizacao e o hash casa sempre.
    foreach ($op in $ops) {
      $stageOp = Join-Path $stageDir $op.RelativePath
      Assert-PathUnder $stageOp $stageDir ('stage de ' + $op.Label)
      $op.StagePath = $stageOp
      $parentOp = Split-Path -Parent $stageOp
      if (-not (Test-Path -LiteralPath $parentOp)) { New-Item -ItemType Directory -Path $parentOp -Force | Out-Null }
      if ($op.ContainsKey('StageText')) { Write-FileAtomic $stageOp $op.StageText }
      else { Write-FileAtomic $stageOp (Read-Utf8 $op.SourcePath) }
    }

    # Valida stage (config: RelativePath real detectado — json ou jsonc)
    $stageErrs = @()
    $stageConfigPath = Join-Path $stageDir $configRelPath
    try { (Read-Utf8 $stageConfigPath) | ConvertFrom-Json | Out-Null }
    catch { $stageErrs += ('stage ' + $configFileName + ' nao parseia: ' + $_.Exception.Message) }
    $stageAllText = (Read-Utf8 (Join-Path $stageDir 'AGENTS.md')) + "`n" + (Read-Utf8 $stageConfigPath)
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

    # CAS recheck (antes de qualquer apply E antes de tocar o legado) --------
    $conflicts = @()
    foreach ($op in $ops) {
      $now = Get-FileHashSafe $op.DestinationPath
      $exp = $expectedHashes[$op.DestinationPath]
      if ($exp -ne $now) { $conflicts += $op.DestinationPath }
    }
    if ($InjectFailureAfter -eq 'cas') { $conflicts += 'INJECTED_CAS_CONFLICT (test-only)' }
    if ($conflicts.Count -gt 0) {
      Write-Output 'CAS_CONFLICT (exit 4). Destino mudou entre preview e apply. NADA foi aplicado, SEM rollback.'
      foreach ($c in $conflicts) { Write-Output ('  CONFLICT: ' + $c) }
      exit 4
    }

    # V31-R2-RESIDUAL R1: adocao tardia do legado (pos-CAS, dentro da
    # transacao coberta pelos catches de apply/manifest/outer). Copia
    # byte-exata para o backup e remove do plugins dir; o manifest
    # registra o hash original (legacy-removed).
    if ($legacyExists) {
      if (Test-Path -LiteralPath $legacyPluginDst -PathType Leaf) {
        $legacyBakDst = Join-Path $bakDir $legacyPluginRel
        $legacyHash = Get-FileHashSafe $legacyPluginDst
        if ($PSCmdlet.ShouldProcess($legacyBakDst, 'Backup')) {
          $legacyParent = Split-Path -Parent $legacyBakDst
          if (-not (Test-Path -LiteralPath $legacyParent)) { New-Item -ItemType Directory -Path $legacyParent -Force | Out-Null }
          Copy-Item -LiteralPath $legacyPluginDst -Destination $legacyBakDst -Force
        }
        if ($PSCmdlet.ShouldProcess($legacyPluginDst, 'Remover legado pre-bundle')) {
          Remove-Item -LiteralPath $legacyPluginDst -Force
        }
        $legacyAdopted = @{ relative = $legacyPluginRel; sha256 = $legacyHash; status = 'legacy-removed' }
        $backupCount += 1
        Write-Host ('Backup (legado): ' + $legacyPluginRel) -ForegroundColor DarkGray
      }
    }

    # Apply --------------------------------------------------------------------
    # $ops ja carrega Src (StagePath) e Dst (DestinationPath) como dados.
    $applied = New-Object System.Collections.ArrayList
    $createdDirs = New-Object System.Collections.ArrayList
    $halfPoint = [Math]::Floor($ops.Count / 2)
    $idx = 0
    try {
      foreach ($op in $ops) {
        $idx += 1
        $existedBefore = Test-Path -LiteralPath $op.DestinationPath -PathType Leaf
        $origHash = $expectedHashes[$op.DestinationPath]
        if ($null -eq $origHash) { $origHash = Get-FileHashSafe $op.DestinationPath }
        # Registrar diretorios pais ainda inexistentes (serao criados pelo
        # write) para o rollback remove-los se ficarem vazios.
        $pdir = Split-Path -Parent $op.DestinationPath
        $ocPrefix = $ocDir.TrimEnd('\') + '\'
        while (($pdir) -and ($pdir.StartsWith($ocPrefix, [StringComparison]::OrdinalIgnoreCase))) {
          if (Test-Path -LiteralPath $pdir -PathType Container) { break }
          if (-not $createdDirs.Contains($pdir)) { [void]$createdDirs.Add($pdir) }
          $pdir = Split-Path -Parent $pdir
        }
        $script:LastWriteMode = 'atomic'
        [void]$applied.Add(@{ Dst = $op.DestinationPath; Src = $op.StagePath; Label = $op.Label; Existed = $existedBefore; OrigHash = $origHash; Mode = 'pending' })
        $rec = $applied[$applied.Count - 1]
        if ($PSCmdlet.ShouldProcess($op.DestinationPath, 'Apply ' + $op.Label)) {
          Write-FileAtomic $op.DestinationPath (Read-Utf8 $op.StagePath)
        }
        $rec.Mode = $script:LastWriteMode
        $hSrc = (Get-FileHash -LiteralPath $op.StagePath -Algorithm SHA256).Hash
        $hDst = Get-FileHashSafe $op.DestinationPath
        if ($hSrc -ne $hDst) { throw ('pos-hash divergente em ' + $op.Label) }
        if ($rec.Mode -eq 'non_atomic_fallback') {
          $hDst2 = Get-FileHashSafe $op.DestinationPath
          if ($hSrc -ne $hDst2) { throw ('pos-hash divergente (non_atomic_fallback) em ' + $op.Label) }
        }
        if (($InjectFailureAfter -eq 'apply-half') -and ($idx -eq $halfPoint)) {
          throw 'INJECTED_FAILURE_AFTER=apply-half (test-only)'
        }
        if (($InjectFailureAfter -eq 'apply-json') -and ($op.Component -eq 'config')) {
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
            Restore-FileAtomicBytes $backupMap[$rec.Dst] $rec.Dst
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
      # V31-R2 F1: restaura o legado adotado quando o apply falha (o backup
      # byte-exato esta em $legacyBakDst; hash original verificado).
      try {
        if (($null -ne $legacyAdopted) -and ($null -ne $legacyBakDst) -and (Test-Path -LiteralPath $legacyBakDst -PathType Leaf)) {
          $legacyParent2 = Split-Path -Parent $legacyPluginDst
          if (-not (Test-Path -LiteralPath $legacyParent2)) { New-Item -ItemType Directory -Path $legacyParent2 -Force | Out-Null }
          Copy-Item -LiteralPath $legacyBakDst -Destination $legacyPluginDst -Force
          if ((Get-FileHashSafe $legacyPluginDst) -ne $legacyAdopted.sha256) {
            $failedRestore += $legacyPluginDst
          }
        }
      }
      catch {
        $failedRestore += $legacyPluginDst
      }
      # Diretorios criados pelo apply que ficaram vazios: remover (mais
      # profundo primeiro), sem tocar diretorios pre-existentes.
      foreach ($cd in @($createdDirs | Sort-Object { $_.Length } -Descending)) {
        try {
          if (Test-Path -LiteralPath $cd -PathType Container) {
            $left = @(Get-ChildItem -LiteralPath $cd -Force -ErrorAction SilentlyContinue)
            if ($left.Count -eq 0) { Remove-Item -LiteralPath $cd -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $cd -PathType Container) { $failedRestore += $cd }
          }
        }
        catch { $failedRestore += $cd }
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
    $manifestByteBackup = $null
    if ($manifestExisted) {
      # Backup BYTE-EXATO do manifesto pre-existente: pode ter sido editado
      # pelo usuario (CRLF/BOM); restaurar via texto alteraria seus bytes.
      try {
        $manifestOrigText = Read-Utf8 $manifestPath
        $manifestByteBackup = Join-Path $stageDir 'manifest.orig'
        Copy-Item -LiteralPath $manifestPath -Destination $manifestByteBackup -Force
      }
      catch {
        $manifestOrigText = $null
        $manifestByteBackup = $null
      }
    }
    # Diretorio do manifest criado aqui entra no rollback de diretorios.
    if (-not (Test-Path -LiteralPath $manifestDir -PathType Container)) {
      if (-not $createdDirs.Contains($manifestDir)) { [void]$createdDirs.Add($manifestDir) }
    }
    try {
      $managedFiles = New-Object System.Collections.ArrayList
      foreach ($op in $ops) {
        [void]$managedFiles.Add(@{ relative = $op.RelativePath; sha256 = (Get-FileHashSafe $op.DestinationPath) })
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
    $snapshotPaths = @()
    if ($IsV2) { $snapshotPaths = @(Get-DesiredManagedPathsV2 $desired) }
    else { $snapshotPaths = @(Get-DesiredManagedPaths $desired) }
    foreach ($mp in $snapshotPaths) {
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
    # V31-R2 F1: legados adotados/removidos (uniao com manifests antigos;
    # evidencia de upgrade + hash original para rollback manual).
    $legacyRemoved = @()
    if ($null -ne $legacyAdopted) { $legacyRemoved += $legacyAdopted }
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
      try {
        $oldM2 = ([IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
        if (($null -ne $oldM2) -and (Has-Member $oldM2 'legacy_removed') -and ($null -ne $oldM2.legacy_removed)) {
          foreach ($p in @($oldM2.legacy_removed)) {
            $rel2 = ''
            if (Has-Member $p 'relative') { $rel2 = [string]$p.relative }
            $dup2 = $false
            foreach ($q in @($legacyRemoved)) {
              if ((Has-Member $q 'relative') -and ([string]$q.relative -ceq $rel2)) { $dup2 = $true; break }
            }
            if (-not $dup2) { $legacyRemoved += $p }
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
      runtime = [ordered]@{ id = $RuntimeId; generation = $RuntimeGeneration; profile = $RuntimeProfile }
      managed_files = @($managedFiles)
      managed_config_paths = @($managedPaths)
      adopted_paths = @($adoptedUnion)
      legacy_removed = @($legacyRemoved)
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
            Restore-FileAtomicBytes $backupMap[$rec.Dst] $rec.Dst
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
        if ($manifestExisted -and ($null -ne $manifestByteBackup)) {
          # Restaura BYTES exatos e VERIFICA o hash original; divergencia
          # vai para failedRestore (nao declara sucesso silencioso).
          Restore-FileAtomicBytes $manifestByteBackup $manifestPath
          if ((Get-FileHashSafe $manifestPath) -ne $manifestOrigHash) {
            $failedRestore += $manifestPath
          }
        }
        elseif ($manifestExisted -and ($null -ne $manifestOrigText)) {
          Write-FileAtomic $manifestPath $manifestOrigText
          if ((Get-FileHashSafe $manifestPath) -ne $manifestOrigHash) {
            $failedRestore += $manifestPath
          }
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
      # V31-R2 F1: restaura o legado adotado quando o manifest falha.
      try {
        if (($null -ne $legacyAdopted) -and ($null -ne $legacyBakDst) -and (Test-Path -LiteralPath $legacyBakDst -PathType Leaf)) {
          $legacyParent3 = Split-Path -Parent $legacyPluginDst
          if (-not (Test-Path -LiteralPath $legacyParent3)) { New-Item -ItemType Directory -Path $legacyParent3 -Force | Out-Null }
          Copy-Item -LiteralPath $legacyBakDst -Destination $legacyPluginDst -Force
          if ((Get-FileHashSafe $legacyPluginDst) -ne $legacyAdopted.sha256) {
            $failedRestore += $legacyPluginDst
          }
        }
      }
      catch {
        $failedRestore += $legacyPluginDst
      }
      foreach ($cd in @($createdDirs | Sort-Object { $_.Length } -Descending)) {
        try {
          if (Test-Path -LiteralPath $cd -PathType Container) {
            $left = @(Get-ChildItem -LiteralPath $cd -Force -ErrorAction SilentlyContinue)
            if ($left.Count -eq 0) { Remove-Item -LiteralPath $cd -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $cd -PathType Container) { $failedRestore += $cd }
          }
        }
        catch { $failedRestore += $cd }
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
  # V31-R2 F1: falhas antes/durante backup+stage (incl. injecoes test-only)
  # restauram o legado adotado quando o apply nunca rodou seu rollback.
  try {
    if (($null -ne $legacyAdopted) -and ($null -ne $legacyBakDst) -and (Test-Path -LiteralPath $legacyBakDst -PathType Leaf) -and (-not (Test-Path -LiteralPath $legacyPluginDst -PathType Leaf))) {
      $legacyParent4 = Split-Path -Parent $legacyPluginDst
      if (-not (Test-Path -LiteralPath $legacyParent4)) { New-Item -ItemType Directory -Path $legacyParent4 -Force | Out-Null }
      Copy-Item -LiteralPath $legacyBakDst -Destination $legacyPluginDst -Force
    }
  }
  catch { }
  if ($msg -like 'INJECTED_FAILURE_AFTER=stage*') { Write-Host $msg -ForegroundColor Yellow; exit 5 }
  if ($msg -like 'INJECTED_FAILURE_AFTER=backup*') { Write-Host $msg -ForegroundColor Yellow; exit 5 }
  if ($msg -like 'INJECTED_FAILURE_AFTER=apply-*') { Write-Host $msg -ForegroundColor Yellow; exit 5 }
  if ($msg -like 'INJECTED_FAILURE_AFTER=manifest*') { Write-Host $msg -ForegroundColor Yellow; exit 5 }
  if ($msg -eq 'stage validation failed') { exit 5 }
  Write-Host ('FALHA: ' + $msg) -ForegroundColor Red
  exit 5
}

# Smoke V2 pos-install (best-effort, warning; ver decisao na Phase 6 acima) ---
if ($IsV2) { Invoke-V2PostInstallSmoke -TargetHome $TargetHome }

# Dependencia do plugin: METADADO offline, sem rede ------------------------------
# plugin_dependency no manifest documenta qual API o bundle alvo usa; o bundle
# distribuido (plugins/dist/orchestration-enforcement.js) e autocontido e nao
# requer node_modules em runtime. Install 100% offline: nenhuma chamada
# bun/npm aqui (validacao da dependency vive no CI typecheck-plugin.ps1).
Write-Host ''
Write-Host 'Instalacao concluida.' -ForegroundColor Green
Write-Host 'Plano aplicado:'
foreach ($l in $plan) { Write-Host ('  ' + $l) -ForegroundColor DarkGray }
if (($configFileName -eq 'opencode.jsonc') -and $configHadComments) {
  # O merged gravado e JSON puro: comentarios/trailing-commas do jsonc do
  # usuario foram normalizados. O backup byte-exato cobre o rollback manual.
  Write-Host 'AVISO: comentarios do seu opencode.jsonc foram normalizados; original preservado no backup.' -ForegroundColor Yellow
}
Write-Host ("Backup: " + $bakDir + ' (' + $backupCount + ' arquivo(s))') -ForegroundColor DarkGray
Write-Host 'Reinicie o OpenCode para carregar AGENTS.md, agents, skills e plugin.' -ForegroundColor Yellow
exit 0
