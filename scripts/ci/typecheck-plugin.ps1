<#
.SYNOPSIS
    Typecheck do plugin contra a API REAL @opencode-ai/plugin@1.18.32.
.DESCRIPTION
    Cria um diretorio temporario, instala as dependencias reais via bun
    (bun add @opencode-ai/plugin@1.18.32 typescript@5 @types/node@22),
    copia plugins/orchestration-enforcement.ts do RepoRoot e roda:
      bun x tsc --noEmit --strict --target es2022 --module esnext
        --moduleResolution bundler --skipLibCheck --types node <plugin>
    Qualquer erro do tsc => exit 1 com o output.

    O plugin atual usa casts `as any`, entao deve passar; o gate fica real
    quando o plugin ganhar hooks tipados. Se o tsc falhar por config de
    ambiente (bun ausente, rede, resolucao de tipos), a mensagem deixa isso
    claro em vez de parecer erro de tipos do plugin.

    PS 5.1 compativel: sem ternario, sem ??, sem Invoke-Expression.
    Exit codes via Start-Process -Wait -PassThru (confiavel no PS 5.1).
    Nao escreve nada no RepoRoot; o temp e removido no sucesso.
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

$PluginSpec = '@opencode-ai/plugin@1.18.32'
$TypescriptSpec = 'typescript@5'
$TypesNodeSpec = '@types/node@22'

$pluginFile = Join-Path $RepoRoot 'plugins\orchestration-enforcement.ts'
if (-not (Test-Path -LiteralPath $pluginFile -PathType Leaf)) {
  Write-Host "[typecheck] FALHA: plugin nao encontrado em $pluginFile."
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
$workDir = Join-Path $base ('oo-typecheck-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
Write-Host "[typecheck] workdir=$workDir"
Write-Host "[typecheck] plugin=$pluginFile"
Write-Host "[typecheck] deps: $PluginSpec $TypescriptSpec $TypesNodeSpec"

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

Copy-Item -LiteralPath $pluginFile -Destination (Join-Path $workDir 'orchestration-enforcement.ts') -Force

$tmpBase = $base
$addOut = Join-Path $tmpBase ('oo-typecheck-add-out-' + [guid]::NewGuid().ToString('N') + '.log')
$addErr = Join-Path $tmpBase ('oo-typecheck-add-err-' + [guid]::NewGuid().ToString('N') + '.log')
Write-Host '[typecheck] bun add (API real + tsc + tipos node)...'
$addProc = Start-Process -FilePath 'bun' -ArgumentList @('add', $PluginSpec, $TypescriptSpec, $TypesNodeSpec) -NoNewWindow -Wait -PassThru -WorkingDirectory $workDir -RedirectStandardOutput $addOut -RedirectStandardError $addErr
if ($addProc.ExitCode -ne 0) {
  Write-Host '[typecheck] FALHA de ambiente: bun add falhou (rede? registry? versao?). Nao e necessariamente erro de tipos do plugin.'
  Show-FileTail -Path $addOut
  Show-FileTail -Path $addErr
  Write-Host "[typecheck] workdir preservado para inspecao: $workDir"
  exit 1
}
Write-Host '[typecheck] bun add OK.'

$tscOut = Join-Path $tmpBase ('oo-typecheck-tsc-out-' + [guid]::NewGuid().ToString('N') + '.log')
$tscErr = Join-Path $tmpBase ('oo-typecheck-tsc-err-' + [guid]::NewGuid().ToString('N') + '.log')
Write-Host '[typecheck] bun x tsc --noEmit --strict ...'
$tscProc = Start-Process -FilePath 'bun' -ArgumentList @('x', 'tsc', '--noEmit', '--strict', '--target', 'es2022', '--module', 'esnext', '--moduleResolution', 'bundler', '--skipLibCheck', '--types', 'node', 'orchestration-enforcement.ts') -NoNewWindow -Wait -PassThru -WorkingDirectory $workDir -RedirectStandardOutput $tscOut -RedirectStandardError $tscErr
$tscText = ''
if (Test-Path -LiteralPath $tscOut -PathType Leaf) { $tscText = $tscText + [IO.File]::ReadAllText($tscOut) }
if (Test-Path -LiteralPath $tscErr -PathType Leaf) { $tscText = $tscText + "`n" + [IO.File]::ReadAllText($tscErr) }
if ($tscProc.ExitCode -ne 0) {
  Write-Host '[typecheck] FALHA: tsc reportou erros (output abaixo). Se o erro for de resolucao de tipos/ambiente (nao encontra modulo, config), trata-se de FALHA de ambiente, nao de tipos do plugin.'
  Show-FileTail -Path $tscOut
  Show-FileTail -Path $tscErr
  Write-Host "[typecheck] workdir preservado para inspecao: $workDir"
  exit 1
}
if (-not ([string]::IsNullOrWhiteSpace($tscText))) {
  Write-Host '[typecheck] tsc emitiu output (nao fatal, exit 0):'
  Write-Host $tscText
}

Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host '[typecheck] PASS: plugin tipa limpo contra a API real.'
exit 0
