<#!
.SYNOPSIS
    Gera o bundle instalavel do plugin orchestration-enforcement (P4).
.DESCRIPTION
    A FONTE canonica do plugin e plugins/orchestration-enforcement.ts mais
    plugins/orchestration-enforcement/{shared,v1,v2}.ts (implementacao
    compartilhada entre os runtimes V1 e V2). Este script NAO muda a fonte:
    apenas emite o ARTEFATO DERIVADO autocontido
    plugins/dist/orchestration-enforcement.js via
    bun build --target node (zero deps de runtime; os adapters usam
    `import type`, apagado no build, entao o bundle nao referencia
    @opencode-ai/plugin nem @opencode/plugin).

    O install.ps1 instala o BUNDLE (nao a fonte .ts), porque a fonte tem
    imports relativos (./v1 ./v2 ./shared/*) que quebrariam copiados
    sozinhos. O dist e COMMITADO (plugins/dist/ nao esta gitignored).

    Integridade (V31-R2 F2): junto do bundle e emitido o sidecar
    plugins/dist/orchestration-enforcement.js.sha256 (SHA256 hex lowercase
    do bundle + newline). O install exige bundle+sidecar com hash igual
    ANTES de qualquer escrita (exit 6); sem sidecar ou com mismatch, nada
    e instalado.

    Atomicidade (V31-R2 F4): o build vai para arquivos temporarios no
    mesmo diretorio, valida marcadores + gera o hash do temporario, e SO
    ENTAO substitui bundle + sidecar por move. Falha em qualquer ponto
    preserva o dist anterior.

    Exit codes: 0 ok; 6 bun ausente no PATH; 7 build falhou ou bundle sem
    marcadores minimos. PS 5.1 compativel. Suporta -WhatIf.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = (Split-Path -Parent $PSScriptRoot) }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$src = Join-Path $RepoRoot 'plugins\orchestration-enforcement.ts'
$dst = Join-Path $RepoRoot 'plugins\dist\orchestration-enforcement.js'

if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
  Write-Host ('[build-plugin] FALHA: fonte canonica ausente: ' + $src) -ForegroundColor Red
  exit 7
}

$bun = Get-Command 'bun' -ErrorAction SilentlyContinue
if ($null -eq $bun) {
  Write-Host '[build-plugin] FALHA de ambiente (exit 6): bun nao encontrado no PATH. Instale bun e rode de novo.' -ForegroundColor Red
  exit 6
}

if ($WhatIfPreference) {
  Write-Host '=== BUILD-PLUGIN PLAN (WhatIf, nenhuma escrita) ===' -ForegroundColor Cyan
  Write-Host ('[CREATE] plugins/dist/orchestration-enforcement.js (bun build --target node a partir de plugins/orchestration-enforcement.ts)') -ForegroundColor DarkGray
  Write-Host ('[CREATE] plugins/dist/orchestration-enforcement.js.sha256 (SHA256 hex lowercase do bundle + newline)') -ForegroundColor DarkGray
  exit 0
}

$dstDir = Split-Path -Parent $dst
$sidecar = $dst + '.sha256'
if (-not (Test-Path -LiteralPath $dstDir -PathType Container)) {
  New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
}

# F4: build em temporarios no MESMO dir (mesmo filesystem => move atomico).
$tmpTag = [guid]::NewGuid().ToString('N')
$tmpBundle = Join-Path $dstDir ('.' + [IO.Path]::GetFileName($dst) + '.' + $tmpTag + '.tmp')
$tmpSidecar = $tmpBundle + '.sha256'

function Remove-BuildTemp {
  foreach ($t in @($tmpBundle, $tmpSidecar)) {
    try {
      if (($t) -and (Test-Path -LiteralPath $t -PathType Leaf)) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
    }
    catch { }
  }
}

Write-Host '[build-plugin] bun build plugins/orchestration-enforcement.ts --target node ...'
& bun build $src --target node --outfile $tmpBundle
if ($LASTEXITCODE -ne 0) {
  Remove-BuildTemp
  Write-Host ('[build-plugin] FALHA (exit 7): bun build saiu com exit ' + $LASTEXITCODE + '. Dist anterior preservado.') -ForegroundColor Red
  exit 7
}

if (-not (Test-Path -LiteralPath $tmpBundle -PathType Leaf)) {
  Remove-BuildTemp
  Write-Host '[build-plugin] FALHA (exit 7): bun build exit 0 mas o outfile temporario nao existe. Dist anterior preservado.' -ForegroundColor Red
  exit 7
}

$text = [IO.File]::ReadAllText($tmpBundle, [Text.Encoding]::UTF8)
$errs = New-Object System.Collections.ArrayList
if (-not $text.Contains('orchestration-enforcement:')) { [void]$errs.Add('bundle sem marcador orchestration-enforcement:') }
if (-not $text.Contains('server')) { [void]$errs.Add('bundle sem marcador server (entry V1)') }
if ($errs.Count -gt 0) {
  Remove-BuildTemp
  foreach ($e in $errs) { Write-Host ('[build-plugin] FALHA (exit 7): ' + $e + ' Dist anterior preservado.') -ForegroundColor Red }
  exit 7
}

# F2: hash do temporario validado; sidecar temporario com hex lowercase + newline.
$hash = ((Get-FileHash -LiteralPath $tmpBundle -Algorithm SHA256).Hash).ToLowerInvariant()
try {
  [IO.File]::WriteAllText($tmpSidecar, ($hash + "`n"), (New-Object Text.UTF8Encoding $false))
}
catch {
  Remove-BuildTemp
  Write-Host ('[build-plugin] FALHA (exit 7): nao foi possivel gravar sidecar temporario: ' + $_.Exception.Message + ' Dist anterior preservado.') -ForegroundColor Red
  exit 7
}

# F4 + V31-R2-RESIDUAL R2: publica o par com rollback. Antes de publicar,
# preserva alvos antigos em .prev-<tag>; move bundle; move sidecar; se o
# move do sidecar falhar, restaura o bundle antigo do .prev e garante o
# sidecar antigo (ou ausente), exit 7. Em sucesso remove os .prev.
$prevBundle = $dst + '.prev-' + $tmpTag
$prevSidecar = $sidecar + '.prev-' + $tmpTag
function Remove-BuildPrev {
  foreach ($t in @($prevBundle, $prevSidecar)) {
    try {
      if (($t) -and (Test-Path -LiteralPath $t -PathType Leaf)) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
    }
    catch { }
  }
}
try {
  if (Test-Path -LiteralPath $dst -PathType Leaf) { Copy-Item -LiteralPath $dst -Destination $prevBundle -Force }
  if (Test-Path -LiteralPath $sidecar -PathType Leaf) { Copy-Item -LiteralPath $sidecar -Destination $prevSidecar -Force }
}
catch {
  Remove-BuildTemp
  Remove-BuildPrev
  Write-Host ('[build-plugin] FALHA (exit 7): nao foi possivel preservar dist anterior: ' + $_.Exception.Message + ' Dist anterior preservado.') -ForegroundColor Red
  exit 7
}
# Move-Item para um destino que e diretorio move PARA DENTRO (exit 0 com
# par inconsistente). Barre antes de qualquer move: destino-container e
# falha fechada, nada publicado.
if ((Test-Path -LiteralPath $dst -PathType Container) -or (Test-Path -LiteralPath $sidecar -PathType Container)) {
  Remove-BuildTemp
  Remove-BuildPrev
  Write-Host '[build-plugin] FALHA (exit 7): destino e diretorio (bundle ou sidecar); nada publicado. Dist anterior preservado.' -ForegroundColor Red
  exit 7
}
try {
  Move-Item -LiteralPath $tmpBundle -Destination $dst -Force
  try {
    Move-Item -LiteralPath $tmpSidecar -Destination $sidecar -Force
  }
  catch {
    $pairErr = $_.Exception.Message
    try {
      if (Test-Path -LiteralPath $prevBundle -PathType Leaf) {
        if (Test-Path -LiteralPath $dst -PathType Leaf) { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $prevBundle -Destination $dst -Force
      }
      elseif (Test-Path -LiteralPath $dst -PathType Leaf) {
        Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
      }
    }
    catch { }
    try {
      if (Test-Path -LiteralPath $prevSidecar -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) {
          Copy-Item -LiteralPath $prevSidecar -Destination $sidecar -Force -ErrorAction SilentlyContinue
        }
        else {
          $hPrev = ''
          $hCur = ''
          try { $hPrev = (Get-FileHash -LiteralPath $prevSidecar -Algorithm SHA256).Hash } catch { $hPrev = '' }
          try { $hCur = (Get-FileHash -LiteralPath $sidecar -Algorithm SHA256).Hash } catch { $hCur = '' }
          if (($hPrev -ne '') -and ($hCur -ne $hPrev)) {
            Copy-Item -LiteralPath $prevSidecar -Destination $sidecar -Force -ErrorAction SilentlyContinue
          }
        }
      }
      elseif (Test-Path -LiteralPath $sidecar -PathType Leaf) {
        Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue
      }
    }
    catch { }
    Remove-BuildTemp
    Remove-BuildPrev
    Write-Host ('[build-plugin] FALHA (exit 7): sidecar nao publicado, par restaurado: ' + $pairErr + ' Dist anterior preservado.') -ForegroundColor Red
    exit 7
  }
  # Verificacao pos-move do par: ambos Leaf e sidecar == sha256(dst).
  # Cobre o caso Move-Item-para-dentro-de-dir e sobrescrita parcial.
  $okPair = $false
  try {
    if ((Test-Path -LiteralPath $dst -PathType Leaf) -and (Test-Path -LiteralPath $sidecar -PathType Leaf)) {
      $hDstNow = ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash).ToLowerInvariant()
      $sNow = ([IO.File]::ReadAllText($sidecar, [Text.Encoding]::UTF8)).Trim()
      if ($sNow -ceq $hDstNow) { $okPair = $true }
    }
  }
  catch { $okPair = $false }
  if (-not $okPair) {
    try {
      if (Test-Path -LiteralPath $prevBundle -PathType Leaf) {
        if (Test-Path -LiteralPath $dst -PathType Leaf) { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $prevBundle -Destination $dst -Force
      }
      elseif (Test-Path -LiteralPath $dst -PathType Leaf) {
        Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
      }
    }
    catch { }
    try {
      if (Test-Path -LiteralPath $prevSidecar -PathType Leaf) {
        Copy-Item -LiteralPath $prevSidecar -Destination $sidecar -Force -ErrorAction SilentlyContinue
      }
      elseif (Test-Path -LiteralPath $sidecar -PathType Leaf) {
        Remove-Item -LiteralPath $sidecar -Force -ErrorAction SilentlyContinue
      }
    }
    catch { }
    Remove-BuildTemp
    Remove-BuildPrev
    Write-Host '[build-plugin] FALHA (exit 7): par bundle+sidecar inconsistente apos move; par anterior restaurado. Dist anterior preservado.' -ForegroundColor Red
    exit 7
  }
}
catch {
  Remove-BuildTemp
  Remove-BuildPrev
  Write-Host ('[build-plugin] FALHA (exit 7): troca atomica falhou: ' + $_.Exception.Message + ' Dist anterior preservado.') -ForegroundColor Red
  exit 7
}
Remove-BuildPrev

Write-Host ('[build-plugin] OK: ' + $dst) -ForegroundColor Green
Write-Host ('[build-plugin] OK: ' + $sidecar + ' (' + $hash + ')') -ForegroundColor Green
exit 0
