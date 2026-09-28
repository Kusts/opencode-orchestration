<#!
.SYNOPSIS
    Renderiza source/agents/*.md para roots V1/V2 separadas via AgentTranslator.
.DESCRIPTION
    Le os 19 .md canonicos, traduz o frontmatter (V1 = roundtrip identico em
    semantica; V2 = permissions array nativo) e escreve <OutDir>\<agent>.md com
    o CORPO markdown original intacto. Escrita atomica simples (tmp+move).
    PS 5.1 compativel. ASCII puro.
    Exit 0 = ok; 6 = falha de traducao/parse (fail closed, sem stack).
#>
param(
  [string]$AgentsDir = '',
  [ValidateSet('V1', 'V2')]
  [string]$Runtime = 'V1',
  [string]$OutDir = '',
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AgentTranslator.ps1')

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($AgentsDir)) {
  $AgentsDir = Join-Path $repoRoot 'source\agents'
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $repoRoot ('generated\opencode\' + $Runtime.ToLowerInvariant() + '\agents')
}

if (-not (Test-Path -LiteralPath $AgentsDir -PathType Container)) {
  Write-Host ('RENDER FAILED: AgentsDir ausente: ' + $AgentsDir)
  exit 6
}

$files = @(Get-ChildItem -LiteralPath $AgentsDir -Filter '*.md' -File | Sort-Object Name)
if ($files.Count -eq 0) {
  Write-Host ('RENDER FAILED: nenhum .md em ' + $AgentsDir)
  exit 6
}

if ((-not $WhatIf) -and (-not (Test-Path -LiteralPath $OutDir -PathType Container))) {
  $pendingMkdir = $true
}
else {
  $pendingMkdir = $false
}

# Two-phase (finding V31-R1 F4): fase 1 traduz/valida TUDO em memoria (qualquer
# falha => exit 6 SEM escrever nada); fase 2 publica tudo com tmp+move.
$staged = New-Object System.Collections.ArrayList
foreach ($f in $files) {
  $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  $parsed = $null
  try {
    $parsed = Read-AgentFileCanonical -Path $f.FullName
  }
  catch {
    Write-Host ('TRANSLATION FAILED (' + $stem + '): ' + $_.Exception.Message)
    exit 6
  }
  $res = $null
  try {
    if ($Runtime -ceq 'V1') {
      $res = Convert-CanonicalToV1Frontmatter -Canonical $parsed.Canonical
    }
    else {
      $res = Convert-CanonicalToV2Frontmatter -Canonical $parsed.Canonical
    }
  }
  catch {
    Write-Host ('TRANSLATION FAILED (' + $stem + '): ' + $_.Exception.Message)
    exit 6
  }
  $dest = Join-Path $OutDir ($stem + '.md')
  $omit = (@($res.OmittedFields) -join ',')
  $drop = (@($res.DroppedFields) -join ',')
  $bodyText = [string]$parsed.Body
  if ($bodyText.EndsWith("`n")) { $bodyText = $bodyText.Substring(0, $bodyText.Length - 1) }
  $text = ('---' + "`n" + [string]$res.Text + "`n" + '---' + "`n" + $bodyText)
  [void]$staged.Add(@{ Stem = $stem; Dest = $dest; Text = $text; Omitted = $omit; Dropped = $drop })
}

if ($WhatIf) {
  foreach ($s in $staged) {
    Write-Host ('[whatif] ' + [string]$s.Stem + ' ' + $Runtime + ' -> ' + [string]$s.Dest + ' Omitted=[' + [string]$s.Omitted + '] Dropped=[' + [string]$s.Dropped + ']')
  }
  Write-Host ('RENDER OK: ' + $staged.Count + ' agente(s) ' + $Runtime + ' -> ' + $OutDir)
  exit 0
}

if ($pendingMkdir) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$nOk = 0
foreach ($s in $staged) {
  $stem = [string]$s.Stem
  $dest = [string]$s.Dest
  $tmp = $dest + '.tmp-' + [guid]::NewGuid().ToString('N')
  try {
    [IO.File]::WriteAllText($tmp, [string]$s.Text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $dest -Force
  }
  catch {
    try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch { }
    Write-Host ('RENDER FAILED (' + $stem + '): ' + $_.Exception.Message)
    exit 6
  }
  Write-Host ('[render] ' + $stem + ' ' + $Runtime + ' Omitted=[' + [string]$s.Omitted + '] Dropped=[' + [string]$s.Dropped + ']')
  $nOk += 1
}

Write-Host ('RENDER OK: ' + $nOk + ' agente(s) ' + $Runtime + ' -> ' + $OutDir)
exit 0
