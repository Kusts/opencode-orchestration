<#!
.SYNOPSIS
    Instala/atualiza/remove a integracao hibrida Claude Code + Orca + OpenCode.
.DESCRIPTION
    Fonte canonica: source/claude/ (CLAUDE.hybrid.md + skills/hybrid-orchestration/).
    Destino: ClaudeHome (padrao ~/.claude), mecanismos nativos do Claude Code:
    bloco marcado em CLAUDE.md e skill em skills/hybrid-orchestration/.
    Nenhum hook, plugin, daemon ou estado novo e instalado (lacuna nao comprovada).

    Preservacao:
    - CLAUDE.md: so o bloco entre os marcadores e gerenciado; o resto fica
      intacto. Secao legada sem marcadores ("## Orquestracao hibrida ...") e
      ADOTADA (substituida pelo bloco marcado), nunca duplicada.
    - Skill: manifest com sha256 por arquivo. Arquivo editado pelo usuario
      (hash diferente do manifest e da fonte) e PRESERVADO e reportado como
      CONFLICT; outras skills/hooks/settings nunca sao tocados.
    - Backup byte-exato em <ClaudeHome>/backups/opencode-orchestration-claude/<ts>/
      antes de qualquer alteracao de arquivo existente.
    - -Uninstall remove somente conteudo gerenciado (rollback para standalone).
    - -WhatIf imprime o plano sem escrever.
    O modo OpenCode standalone nao depende deste script.
    Exit: 0 ok; 3 precheck (nada escrito); 5 falha no apply (restaurado do backup).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$RepoRoot,
  [string]$ClaudeHome,
  [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
if ([string]::IsNullOrWhiteSpace($ClaudeHome)) { $ClaudeHome = Join-Path $env:USERPROFILE '.claude' }

$MarkStart = '<!-- opencode-orchestration:claude-hybrid:start -->'
$MarkEnd = '<!-- opencode-orchestration:claude-hybrid:end -->'
# ASCII-only (PS 5.1 le .ps1 sem BOM como ANSI): c-cedilha U+00E7, a-til U+00E3, i-agudo U+00ED
$LegacyHeading = '## Orquestra' + [char]0x00E7 + [char]0x00E3 + 'o h' + [char]0x00ED + 'brida (Claude + Orca + OpenCode)'
$SkillName = 'hybrid-orchestration'
$Utf8 = New-Object Text.UTF8Encoding $false

function Read-Text([string]$Path) { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
function Write-Text([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($tmp, $Text, $Utf8)
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}
# .NET direto: Get-FileHash retorna $null sob -WhatIf no PS 5.1.
function Get-Sha([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Get-ShaText([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash($Utf8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

# --- Fonte (precheck: nada escrito se invalida) -------------------------------
$srcRoot = Join-Path $RepoRoot 'source\claude'
$srcBlock = Join-Path $srcRoot 'CLAUDE.hybrid.md'
$srcSkillDir = Join-Path $srcRoot ('skills\' + $SkillName)
if (-not (Test-Path -LiteralPath $srcBlock -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $srcSkillDir 'SKILL.md') -PathType Leaf)) {
  Write-Host 'PRECHECK FAILED (exit 3): fonte source/claude ausente ou incompleta.' -ForegroundColor Red
  exit 3
}
$blockBody = (Read-Text $srcBlock).Trim()
if (($blockBody -notmatch '^## ') -or ($blockBody.Contains($MarkStart))) {
  Write-Host 'PRECHECK FAILED (exit 3): CLAUDE.hybrid.md invalido (precisa iniciar com "## " e nao conter marcadores).' -ForegroundColor Red
  exit 3
}
$srcFiles = @(Get-ChildItem -LiteralPath $srcSkillDir -Recurse -File)
$srcPrefix = $srcSkillDir.TrimEnd('\') + '\'
$desired = [ordered]@{}   # rel -> @{ src; hash }
foreach ($f in $srcFiles) {
  $rel = $f.FullName.Substring($srcPrefix.Length).Replace('\', '/')
  $desired[$rel] = @{ src = $f.FullName; hash = (Get-Sha $f.FullName) }
}

$claudeMd = Join-Path $ClaudeHome 'CLAUDE.md'
$skillDst = Join-Path $ClaudeHome ('skills\' + $SkillName)
$manifestPath = Join-Path $ClaudeHome '.opencode-orchestration-claude.json'
$manifest = $null
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
  try { $manifest = Read-Text $manifestPath | ConvertFrom-Json } catch { Write-Host 'PRECHECK FAILED (exit 3): manifest ilegivel.' -ForegroundColor Red; exit 3 }
}
function Get-ManifestHash([string]$Rel) {
  if ($null -eq $manifest -or $null -eq $manifest.files) { return $null }
  $p = $manifest.files.PSObject.Properties[$Rel]
  if ($null -eq $p) { return $null }
  return [string]$p.Value
}

# --- CLAUDE.md: calculo do novo texto ----------------------------------------
function Get-Eol([string]$Text) { if ($Text.Contains("`r`n")) { return "`r`n" } else { return "`n" } }
function Find-BlockRange([string]$Text) {
  $s = $Text.IndexOf($MarkStart); $e = $Text.IndexOf($MarkEnd)
  if (($s -lt 0) -and ($e -lt 0)) { return $null }
  if (($s -lt 0) -or ($e -lt $s) -or ($Text.IndexOf($MarkStart, $s + 1) -ge 0) -or ($Text.IndexOf($MarkEnd, $e + 1) -ge 0)) { throw 'CLAUDE.md: marcadores do bloco hibrido corrompidos/duplicados' }
  return @{ start = $s; end = $e + $MarkEnd.Length }
}
function Find-LegacyRange([string]$Text) {
  $m = [regex]::Match($Text, '(?m)^' + [regex]::Escape($LegacyHeading) + '[ \t]*\r?$')
  if (-not $m.Success) { return $null }
  $next = [regex]::Match($Text.Substring($m.Index + $m.Length), '(?m)^## ')
  if ($next.Success) { return @{ start = $m.Index; end = $m.Index + $m.Length + $next.Index } }
  return @{ start = $m.Index; end = $Text.Length }
}
function Get-NewClaudeMd([string]$Existing, [bool]$Remove) {
  $eol = Get-Eol $Existing
  $block = $MarkStart + $eol + ($blockBody -replace "`r?`n", $eol) + $eol + $MarkEnd
  $range = Find-BlockRange $Existing
  $kind = 'managed'
  if ($null -eq $range) { $range = Find-LegacyRange $Existing; $kind = 'legacy' }
  if ($Remove) {
    if ($null -eq $range -or $kind -eq 'legacy') { return $Existing }  # legado nao-marcado e do usuario ate adocao
    $before = $Existing.Substring(0, $range.start).TrimEnd("`r", "`n")
    $after = $Existing.Substring($range.end).TrimStart("`r", "`n")
    if ($before.Length -eq 0) { return $after }
    if ($after.Length -eq 0) { return $before + $eol }
    return $before + $eol + $eol + $after
  }
  if ($null -ne $range) {
    $tail = $Existing.Substring($range.end)
    if ($kind -eq 'legacy') { $tail = $eol + $tail.TrimStart("`r", "`n") ; if ($tail.Trim().Length -eq 0) { $tail = $eol } }
    return $Existing.Substring(0, $range.start) + $block + $tail
  }
  if ($Existing.Trim().Length -eq 0) { return $block + $eol }
  return $Existing.TrimEnd("`r", "`n") + $eol + $eol + $block + $eol
}

# --- Plano -------------------------------------------------------------------
$plan = New-Object System.Collections.ArrayList
$actions = New-Object System.Collections.ArrayList   # @{ kind; path; text|src; rel }
$conflicts = 0

$existingMd = ''
if (Test-Path -LiteralPath $claudeMd -PathType Leaf) { $existingMd = Read-Text $claudeMd }
try { $newMd = Get-NewClaudeMd $existingMd ([bool]$Uninstall) } catch { Write-Host ('PRECHECK FAILED (exit 3): ' + $_.Exception.Message) -ForegroundColor Red; exit 3 }
if ($newMd -ceq $existingMd) { [void]$plan.Add('[SKIP] CLAUDE.md (sem mudanca)') }
else {
  $adopt = ($null -eq (Find-BlockRange $existingMd)) -and ($null -ne (Find-LegacyRange $existingMd)) -and (-not $Uninstall)
  $tag = 'UPDATE'; if ($Uninstall) { $tag = 'REMOVE-BLOCK' } elseif ($adopt) { $tag = 'ADOPT' } elseif (-not (Test-Path -LiteralPath $claudeMd)) { $tag = 'CREATE' }
  [void]$plan.Add('[' + $tag + '] CLAUDE.md (bloco gerenciado)')
  [void]$actions.Add(@{ kind = 'text'; path = $claudeMd; text = $newMd })
}

if ($Uninstall) {
  $uninstallRels = New-Object System.Collections.ArrayList
  foreach ($k in $desired.Keys) { [void]$uninstallRels.Add([string]$k) }
  if ($manifest -and $manifest.files) { foreach ($k in $manifest.files.PSObject.Properties.Name) { if (-not $uninstallRels.Contains([string]$k)) { [void]$uninstallRels.Add([string]$k) } } }
  foreach ($rel in $uninstallRels) {
    $dst = Join-Path $skillDst ($rel.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { continue }
    if ((Get-Sha $dst) -ceq (Get-ManifestHash $rel)) { [void]$plan.Add('[REMOVE] skills/' + $SkillName + '/' + $rel); [void]$actions.Add(@{ kind = 'delete'; path = $dst }) }
    else { [void]$plan.Add('[PRESERVE] skills/' + $SkillName + '/' + $rel + ' (modificado pelo usuario ou nao gerenciado)') }
  }
  if (Test-Path -LiteralPath $manifestPath) { [void]$actions.Add(@{ kind = 'delete'; path = $manifestPath }) }
} else {
  foreach ($rel in $desired.Keys) {
    $dst = Join-Path $skillDst ($rel.Replace('/', '\'))
    $label = 'skills/' + $SkillName + '/' + $rel
    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { [void]$plan.Add('[CREATE] ' + $label); [void]$actions.Add(@{ kind = 'copy'; path = $dst; src = $desired[$rel].src }); continue }
    $cur = Get-Sha $dst; $mh = Get-ManifestHash $rel
    if ($cur -ceq $desired[$rel].hash) { [void]$plan.Add('[SKIP] ' + $label + ' (igual a fonte)') }
    elseif ($null -eq $mh) { [void]$plan.Add('[ADOPT] ' + $label + ' (preexistente sem manifest; backup + atualiza)'); [void]$actions.Add(@{ kind = 'copy'; path = $dst; src = $desired[$rel].src }) }
    elseif ($cur -ceq $mh) { [void]$plan.Add('[UPDATE] ' + $label); [void]$actions.Add(@{ kind = 'copy'; path = $dst; src = $desired[$rel].src }) }
    else { [void]$plan.Add('[CONFLICT] ' + $label + ' (editado pelo usuario; preservado)'); $conflicts++ }
  }
}

Write-Host ('Claude hybrid -> ' + $ClaudeHome)
foreach ($l in $plan) { Write-Host ('  ' + $l) }
if (-not $PSCmdlet.ShouldProcess($ClaudeHome, 'aplicar plano Claude hybrid')) { Write-Host 'WhatIf: nada escrito.'; exit 0 }
if ($actions.Count -eq 0) { Write-Host 'Nada a fazer.'; if ($conflicts -gt 0) { Write-Host ('AVISO: ' + $conflicts + ' conflito(s) preservado(s).') -ForegroundColor Yellow }; exit 0 }

# --- Apply: backup -> escrita -> manifest; rollback em falha ------------------
$bakDir = Join-Path $ClaudeHome ('backups\opencode-orchestration-claude\' + (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
$restore = New-Object System.Collections.ArrayList  # @{ path; bak|$null }
try {
  foreach ($a in $actions) {
    if (Test-Path -LiteralPath $a.path -PathType Leaf) {
      $relBak = $a.path.Substring($ClaudeHome.TrimEnd('\').Length).TrimStart('\')
      $bak = Join-Path $bakDir $relBak
      New-Item -ItemType Directory -Path (Split-Path -Parent $bak) -Force | Out-Null
      Copy-Item -LiteralPath $a.path -Destination $bak -Force
      [void]$restore.Add(@{ path = $a.path; bak = $bak })
    } else { [void]$restore.Add(@{ path = $a.path; bak = $null }) }
  }
  foreach ($a in $actions) {
    if ($a.kind -eq 'text') { Write-Text $a.path $a.text }
    elseif ($a.kind -eq 'copy') { Write-Text $a.path (Read-Text $a.src) }
    elseif ($a.kind -eq 'delete') { Remove-Item -LiteralPath $a.path -Force }
  }
  if ($Uninstall) {
    foreach ($d in @((Join-Path $skillDst 'references'), $skillDst)) {
      if ((Test-Path -LiteralPath $d -PathType Container) -and (@(Get-ChildItem -LiteralPath $d -Force).Count -eq 0)) { Remove-Item -LiteralPath $d -Force }
    }
  } else {
    $files = [ordered]@{}
    foreach ($rel in $desired.Keys) {
      $dst = Join-Path $skillDst ($rel.Replace('/', '\'))
      # conflito preservado: manifest mantem o hash antigo para continuar detectando
      if ((Test-Path -LiteralPath $dst -PathType Leaf) -and ((Get-Sha $dst) -ceq $desired[$rel].hash)) { $files[$rel] = $desired[$rel].hash }
      elseif ($null -ne (Get-ManifestHash $rel)) { $files[$rel] = (Get-ManifestHash $rel) }
    }
    $m = [ordered]@{ schema = 1; component = 'claude-hybrid'; block_sha256 = (Get-ShaText $blockBody); files = $files }
    Write-Text $manifestPath (($m | ConvertTo-Json -Depth 6) + "`n")
  }
}
catch {
  Write-Host ('FALHA no apply: ' + $_.Exception.Message + ' -- restaurando backup') -ForegroundColor Red
  foreach ($r in $restore) {
    try {
      if ($r.bak) { Copy-Item -LiteralPath $r.bak -Destination $r.path -Force }
      elseif (Test-Path -LiteralPath $r.path) { Remove-Item -LiteralPath $r.path -Force }
    } catch { }
  }
  exit 5
}
Write-Host ('Concluido. Backup: ' + $bakDir) -ForegroundColor Green
if ($conflicts -gt 0) { Write-Host ('AVISO: ' + $conflicts + ' arquivo(s) editado(s) pelo usuario preservado(s); compare com source/claude e reconcilie manualmente.') -ForegroundColor Yellow }
exit 0
