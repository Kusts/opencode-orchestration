<#
.SYNOPSIS
    Typecheck dual-runtime do plugin contra as APIs REAIS V1 e V2.
.DESCRIPTION
    Tres trilhas, cada uma num workdir temporario com deps reais via bun:
      V1:   @opencode-ai/plugin@1.18.32 + typescript@5 + @types/node@22
            compila shared/*.ts + v1.ts (adapter V1 + nucleo puro).
      V2:   @opencode/plugin@2.0.18 + typescript@5 + @types/node@22
            compila shared/*.ts + v2.ts (adapter V2 + nucleo puro).
      DUAL: ambos os pacotes + typescript@5 + @types/node@22
            compila plugins/orchestration-enforcement.ts (o dual-export
            { id, setup, server }, que importa os dois adapters).
    Cada trilha roda:
      bun x tsc --noEmit --strict --target es2022 --module esnext
        --moduleResolution bundler --skipLibCheck --types node <raizes>
    Qualquer erro do tsc => exit 1 com o output. Falha de ambiente
    (bun ausente, rede, registry) => exit 1 com mensagem clara de ambiente,
    nunca parecendo erro de tipos do plugin.

    Os adapters usam `import type` (apagado no build), entao o typecheck
    valida conformidade de tipos sem criar dependencia de runtime entre
    geracoes: o bundle emitido nao referencia nenhum dos pacotes.

    PS 5.1 compativel: sem ternario, sem ??, sem Invoke-Expression.
    Nao escreve nada no RepoRoot; os temps sao removidos no sucesso.
.PARAMETER RepoRoot
    Raiz do repositorio do pacote. Default: dois niveis acima deste script
    (scripts/ci -> raiz).
#>
param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$V1Spec = '@opencode-ai/plugin@1.18.32'
$V2Spec = '@opencode/plugin@2.0.18'
$TypescriptSpec = 'typescript@5'
$TypesNodeSpec = '@types/node@22'

$pluginIndex = Join-Path $RepoRoot 'plugins\orchestration-enforcement.ts'
$pluginDir = Join-Path $RepoRoot 'plugins\orchestration-enforcement'
if (-not (Test-Path -LiteralPath $pluginIndex -PathType Leaf)) {
  Write-Host "[typecheck] FALHA: index do plugin nao encontrado em $pluginIndex."
  exit 1
}
if (-not (Test-Path -LiteralPath $pluginDir -PathType Container)) {
  Write-Host "[typecheck] FALHA: diretorio de adapters nao encontrado em $pluginDir."
  exit 1
}

$bunCmd = Get-Command 'bun' -ErrorAction SilentlyContinue
if ($null -eq $bunCmd) {
  Write-Host '[typecheck] FALHA de ambiente: bun nao encontrado no PATH (este gate exige bun; o workflow o provisiona via npm). Nao e erro de tipos do plugin.'
  exit 1
}

$base = $env:RUNNER_TEMP
if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TEMP }
if ([string]::IsNullOrWhiteSpace($base)) { $base = [IO.Path]::GetTempPath() }

function Show-FileTail {
  param([string]$Path, [int]$Lines = 60)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Write-Host "(sem arquivo: $Path)"
    return
  }
  Write-Host "--- tail ($Lines linhas): $Path ---"
  $content = Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction SilentlyContinue
  foreach ($l in $content) { Write-Host $l }
  Write-Host "--- fim ---"
}

function New-TrackDir {
  param([string]$Tag)
  $d = Join-Path $base ('oo-typecheck-' + $Tag + '-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $d -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $d 'orchestration-enforcement\shared') -Force | Out-Null
  Copy-Item -LiteralPath $pluginIndex -Destination (Join-Path $d 'orchestration-enforcement.ts') -Force
  Copy-Item -LiteralPath (Join-Path $pluginDir 'v1.ts') -Destination (Join-Path $d 'orchestration-enforcement\v1.ts') -Force
  Copy-Item -LiteralPath (Join-Path $pluginDir 'v2.ts') -Destination (Join-Path $d 'orchestration-enforcement\v2.ts') -Force
  foreach ($f in @('types.ts', 'sanitize.ts', 'identity.ts', 'mandate.ts', 'telemetry.ts', 'mcp-transport.ts')) {
    Copy-Item -LiteralPath (Join-Path $pluginDir ("shared\" + $f)) -Destination (Join-Path $d ("orchestration-enforcement\shared\" + $f)) -Force
  }
  return $d
}

function Test-TrackDeps {
  # O bun pode sair non-zero de forma transitoria mesmo com a instalacao
  # efetiva (rede lenta, warnings de backend). So prossegue quando TODAS
  # as deps estao fisicamente presentes + tsc resolvivel; senao e falha
  # de ambiente real. Retorna $true quando pode prosseguir.
  param([string]$WorkDir, [string[]]$Deps)
  foreach ($dep in $Deps) {
    $name = $dep -replace '@[^/]*$', ''
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $dep }
    $p = Join-Path $WorkDir ("node_modules\" + ($name -replace '/', '\') + '\package.json')
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
  }
  $tscLocal = Join-Path $WorkDir 'node_modules\typescript\bin\tsc'
  if (-not (Test-Path -LiteralPath $tscLocal -PathType Leaf)) {
    if (-not (Test-Path -LiteralPath (Join-Path $WorkDir 'node_modules\.bin\tsc') )) { return $false }
  }
  return $true
}

function Get-InstalledVersion {
  param([string]$WorkDir, [string]$PkgName)
  $p = Join-Path $WorkDir ("node_modules\" + ($PkgName -replace '/', '\') + '\package.json')
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return '(versao ilegivel)' }
  try {
    $j = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json
    return $j.version
  } catch { return '(versao ilegivel)' }
}

# Retorna 0 (ok), 1 (erro de tipos), 2 (falha de ambiente). Nunca lanca.
function Invoke-Track {
  param([string]$Tag, [string[]]$Deps, [string[]]$Roots)
  $workDir = New-TrackDir -Tag $Tag
  Write-Host "[typecheck:$Tag] workdir=$workDir"
  Write-Host "[typecheck:$Tag] deps: $($Deps -join ' ')"
  Write-Host "[typecheck:$Tag] roots: $($Roots -join ' ')"
  $tmpBase = $base
  $addOut = Join-Path $tmpBase ('oo-typecheck-add-out-' + $Tag + '-' + [guid]::NewGuid().ToString('N') + '.log')
  $addErr = Join-Path $tmpBase ('oo-typecheck-add-err-' + $Tag + '-' + [guid]::NewGuid().ToString('N') + '.log')
  Write-Host "[typecheck:$Tag] bun add (APIs reais + tsc + tipos node)..."
  # Via cmd /c: o 'bun' provisionado por npm no CI resolve como shim .ps1/.cmd,
  # que o Start-Process -FilePath 'bun' nao executa ("%1 is not a valid Win32
  # application"). cmd /c executa o shim correto e propaga o exit code.
  $quoted = @()
  foreach ($d in $Deps) { $quoted += ('"' + $d + '"') }
  $addLine = 'bun add ' + ($quoted -join ' ')
  # Cap do bun add configuravel (default 420s): sob o runner V3 (300s/suite)
  # as suites fixam OO_TYPECHECK_BUN_MS baixo para cair no fallback npm
  # rapido quando o resolver do bun trava; invocacao direta usa o default.
  $bunMs = 420000
  try {
    if (-not [string]::IsNullOrWhiteSpace($env:OO_TYPECHECK_BUN_MS)) {
      $parsed = [int]$env:OO_TYPECHECK_BUN_MS
      if ($parsed -ge 30000) { $bunMs = $parsed }
    }
  } catch { $bunMs = 420000 }
  $addProc = Start-Process -FilePath 'cmd' -ArgumentList @('/c', $addLine) -NoNewWindow -PassThru -WorkingDirectory $workDir -RedirectStandardOutput $addOut -RedirectStandardError $addErr
  $bunDone = $addProc.WaitForExit($bunMs)
  if (-not $bunDone) {
    try { & taskkill /PID $addProc.Id /T /F 2>$null | Out-Null } catch { }
    try { [void]$addProc.WaitForExit(15000) } catch { }
    Write-Host "[typecheck:$Tag] bun add excedeu ${bunMs}ms (rede? arvore pesada?). Tentando fallback: npm install..."
    $npmCmd = Get-Command 'npm' -ErrorAction SilentlyContinue
    if ($null -eq $npmCmd) {
      Write-Host "[typecheck:$Tag] FALHA de ambiente: bun travou e npm nao esta no PATH. Nao e erro de tipos do plugin."
      Show-FileTail -Path $addOut
      Show-FileTail -Path $addErr
      Write-Host "[typecheck:$Tag] workdir preservado para inspecao: $workDir"
      return 2
    }
    $npmOut = Join-Path $tmpBase ('oo-typecheck-npm-out-' + $Tag + '-' + [guid]::NewGuid().ToString('N') + '.log')
    $npmErr = Join-Path $tmpBase ('oo-typecheck-npm-err-' + $Tag + '-' + [guid]::NewGuid().ToString('N') + '.log')
    $npmLine = 'npm install --no-audit --no-fund ' + ($quoted -join ' ')
    $npmProc = Start-Process -FilePath 'cmd' -ArgumentList @('/c', $npmLine) -NoNewWindow -Wait -PassThru -WorkingDirectory $workDir -RedirectStandardOutput $npmOut -RedirectStandardError $npmErr
    if ($npmProc.ExitCode -ne 0) {
      Write-Host "[typecheck:$Tag] FALHA de ambiente: bun travou e npm install tambem falhou (rede? registry?). Nao e erro de tipos do plugin."
      Show-FileTail -Path $npmOut
      Show-FileTail -Path $npmErr
      Write-Host "[typecheck:$Tag] workdir preservado para inspecao: $workDir"
      return 2
    }
    Write-Host "[typecheck:$Tag] fallback npm install OK."
    $installedBy = 'npm-fallback'
  } else {
    $addProc.Refresh()
    $bunExit = $addProc.ExitCode
    if ($bunExit -ne 0) {
      if (Test-TrackDeps -WorkDir $workDir -Deps $Deps) {
        Write-Host "[typecheck:$Tag] AVISO: bun add reportou falha (exit '$bunExit') mas todas as deps estao presentes; prosseguindo ao tsc (transitorio conhecido sob rede lenta)."
        $installedBy = 'bun (exit nao-zero, deps presentes)'
      } else {
        Write-Host "[typecheck:$Tag] FALHA de ambiente: bun add falhou (rede? registry? versao?). Nao e necessariamente erro de tipos do plugin."
        Show-FileTail -Path $addOut
        Show-FileTail -Path $addErr
        Write-Host "[typecheck:$Tag] workdir preservado para inspecao: $workDir"
        return 2
      }
    } else {
      $installedBy = 'bun'
    }
  }
  foreach ($dep in $Deps) {
    $name = $dep -replace '@[^/]*$', ''
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $dep }
    if ($name -like '@opencode*') {
      Write-Host ("[typecheck:$Tag] pacote instalado: " + $name + "@" + (Get-InstalledVersion -WorkDir $workDir -PkgName $name))
    }
  }
  Write-Host "[typecheck:$Tag] install OK via $installedBy."
  $tscOut = Join-Path $tmpBase ('oo-typecheck-tsc-out-' + $Tag + '-' + [guid]::NewGuid().ToString('N') + '.log')
  $tscErr = Join-Path $tmpBase ('oo-typecheck-tsc-err-' + $Tag + '-' + [guid]::NewGuid().ToString('N') + '.log')
  Write-Host "[typecheck:$Tag] bun x tsc --noEmit --strict ..."
  $tscLine = 'bun x tsc --noEmit --strict --target es2022 --module esnext --moduleResolution bundler --skipLibCheck --types node ' + ($Roots -join ' ')
  $tscProc = Start-Process -FilePath 'cmd' -ArgumentList @('/c', $tscLine) -NoNewWindow -Wait -PassThru -WorkingDirectory $workDir -RedirectStandardOutput $tscOut -RedirectStandardError $tscErr
  $tscText = ''
  if (Test-Path -LiteralPath $tscOut -PathType Leaf) { $tscText = $tscText + [IO.File]::ReadAllText($tscOut) }
  if (Test-Path -LiteralPath $tscErr -PathType Leaf) { $tscText = $tscText + "`n" + [IO.File]::ReadAllText($tscErr) }
  if ($tscProc.ExitCode -ne 0) {
    Write-Host "[typecheck:$Tag] FALHA: tsc reportou erros (output abaixo). Se o erro for de resolucao de tipos/ambiente (nao encontra modulo, config), trata-se de FALHA de ambiente, nao de tipos do plugin."
    Show-FileTail -Path $tscOut
    Show-FileTail -Path $tscErr
    Write-Host "[typecheck:$Tag] workdir preservado para inspecao: $workDir"
    return 1
  }
  if (-not ([string]::IsNullOrWhiteSpace($tscText))) {
    Write-Host "[typecheck:$Tag] tsc emitiu output (nao fatal, exit 0):"
    Write-Host $tscText
  }
  Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "[typecheck:$Tag] PASS."
  return 0
}

$sharedRoots = @(
  'orchestration-enforcement/shared/types.ts',
  'orchestration-enforcement/shared/sanitize.ts',
  'orchestration-enforcement/shared/identity.ts',
  'orchestration-enforcement/shared/mandate.ts',
  'orchestration-enforcement/shared/telemetry.ts',
  'orchestration-enforcement/shared/mcp-transport.ts'
)

$code = @(Invoke-Track -Tag 'v1' -Deps @($V1Spec, $TypescriptSpec, $TypesNodeSpec) -Roots ($sharedRoots + @('orchestration-enforcement/v1.ts')))[-1]
if ($code -ne 0) {
  if ($code -eq 2) { Write-Host '[typecheck] Trilha V1: FALHA de ambiente.' }
  exit 1
}

$code = @(Invoke-Track -Tag 'v2' -Deps @($V2Spec, $TypescriptSpec, $TypesNodeSpec) -Roots ($sharedRoots + @('orchestration-enforcement/v2.ts')))[-1]
if ($code -ne 0) {
  if ($code -eq 2) { Write-Host '[typecheck] Trilha V2: FALHA de ambiente.' }
  exit 1
}

$code = @(Invoke-Track -Tag 'dual' -Deps @($V1Spec, $V2Spec, $TypescriptSpec, $TypesNodeSpec) -Roots @('orchestration-enforcement.ts'))[-1]
if ($code -ne 0) {
  if ($code -eq 2) { Write-Host '[typecheck] Trilha DUAL: FALHA de ambiente.' }
  exit 1
}

Write-Host '[typecheck] PASS: plugin tipa limpo nas trilhas V1, V2 e DUAL contra as APIs reais.'

# P4: com os tipos validados, regenera o bundle instalavel e verifica os
# marcadores (o CI regenera/valida o dist a cada rodada).
$buildScript = Join-Path $RepoRoot 'scripts\build-plugin.ps1'
if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
  Write-Host '[typecheck] FALHA: scripts\build-plugin.ps1 nao encontrado; bundle nao regenerado.'
  exit 1
}
Write-Host '[typecheck] rebuild do bundle (scripts\build-plugin.ps1)...'
& powershell -NoProfile -ExecutionPolicy Bypass -File $buildScript -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) {
  Write-Host ('[typecheck] FALHA: rebuild do bundle saiu com exit ' + $LASTEXITCODE + '.')
  exit 1
}
$bundlePath = Join-Path $RepoRoot 'plugins\dist\orchestration-enforcement.js'
$bundleText = [IO.File]::ReadAllText($bundlePath, [Text.Encoding]::UTF8)
if ((-not $bundleText.Contains('orchestration-enforcement:')) -or (-not $bundleText.Contains('server'))) {
  Write-Host '[typecheck] FALHA: bundle regenerado sem marcadores minimos (orchestration-enforcement: + server).'
  exit 1
}
Write-Host '[typecheck] bundle regenerado e validado (marcadores ok).'
exit 0
