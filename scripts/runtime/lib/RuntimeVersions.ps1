<#!
.SYNOPSIS
    Loader fail-closed dos pins de runtime/tools (registry unico).
.DESCRIPTION
    Fonte unica: source/registry/runtime-versions.json. Nenhum consumidor
    deve escrever versao como literal; este loader e a unica leitura, para que
    um bump seja uma edicao de UM arquivo.

    Fail closed SEMPRE: registry ausente, ilegivel, JSON invalido, entrada
    ausente ou campos vazios => throw com motivo claro. PROIBIDO fallback
    para literal default (um pin adivinhado e pior que um pin ausente).

    Lib dot-sourceable, PS 5.1 compativel (sem ternario, sem ??, sem
    Invoke-Expression). Nao depende de nenhuma outra lib. Nao executa nada no
    dot-source alem de definir funcoes.

    O repo root e resolvido pela localizacao do proprio script
    (scripts/runtime/lib -> 3 niveis acima), portanto funciona de qualquer cwd;
    -RepoRoot existe para fixtures/testes apontarem para outra raiz.
#>

$ErrorActionPreference = 'Stop'

function Get-OrchestrationRuntimeVersionsPath {
  param([string]$RepoRoot = '')
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here)) { $here = (Get-Location).Path }
    # lib vive em scripts/runtime/lib -> repo root = 3 niveis acima
    $root = $here
    try { $root = (Resolve-Path -LiteralPath (Join-Path $here '..\..\..')).Path } catch { }
    $RepoRoot = $root
  }
  return (Join-Path $RepoRoot 'source\registry\runtime-versions.json')
}

function Get-OrchestrationRuntimeVersion {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('v1', 'v2', 'plugin_v1', 'plugin_v2', 'bun')]
    [string]$Name,
    [string]$RepoRoot = ''
  )
  $path = Get-OrchestrationRuntimeVersionsPath -RepoRoot $RepoRoot
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw ('runtime versions registry ausente (arquivo nao encontrado): ' + $path)
  }
  $raw = ''
  try {
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
  }
  catch {
    throw ('runtime versions registry ilegivel (leitura falhou): ' + $path + ' : ' + $_.Exception.Message)
  }
  $doc = $null
  try {
    $doc = $raw | ConvertFrom-Json
  }
  catch {
    throw ('runtime versions registry ilegivel (JSON invalido): ' + $path + ' : ' + $_.Exception.Message)
  }
  if (($null -eq $doc) -or [string]::IsNullOrWhiteSpace([string]$doc.schema_version)) {
    throw ('runtime versions registry invalido (sem schema_version): ' + $path)
  }

  $group = ''
  $key = ''
  switch ([string]$Name) {
    'v1' { $group = 'runtimes'; $key = 'v1'; break }
    'v2' { $group = 'runtimes'; $key = 'v2'; break }
    'plugin_v1' { $group = 'plugins'; $key = 'v1'; break }
    'plugin_v2' { $group = 'plugins'; $key = 'v2'; break }
    'bun' { $group = 'tools'; $key = 'bun'; break }
  }
  if ([string]::IsNullOrWhiteSpace($group)) {
    throw ('runtime versions registry: nome invalido (esperado v1|v2|plugin_v1|plugin_v2|bun): ' + [string]$Name)
  }
  $bucket = $null
  try { $bucket = $doc.$group } catch { $bucket = $null }
  if (($null -eq $bucket) -or ($null -eq $bucket.PSObject.Properties[$key])) {
    throw ('runtime versions registry sem entrada ' + $group + '.' + $key + ': ' + $path)
  }
  $entry = $bucket.$key
  $pkg = ''
  $ver = ''
  $spec = ''
  try { $pkg = [string]$entry.package } catch { $pkg = '' }
  try { $ver = [string]$entry.version } catch { $ver = '' }
  try { $spec = [string]$entry.spec } catch { $spec = '' }
  if ([string]::IsNullOrWhiteSpace($pkg)) {
    throw ('runtime versions registry: ' + $group + '.' + $key + ' sem package: ' + $path)
  }
  if ([string]::IsNullOrWhiteSpace($ver)) {
    throw ('runtime versions registry: ' + $group + '.' + $key + ' sem version: ' + $path)
  }
  if ([string]::IsNullOrWhiteSpace($spec)) {
    throw ('runtime versions registry: ' + $group + '.' + $key + ' sem spec: ' + $path)
  }
  # RR-VERSIONS-REGISTRY-FIX2: formato FECHADO dos dois campos. Um pin e um
  # pin: 'latest', '1.x', '^1.2.3', '~1.2.3', '1.2.3 ', espaco interno,
  # caractere de controle ou qualquer coisa fora do conjunto abaixo nao e um
  # pin -- e um range/erro de digitacao que instalaria algo diferente do
  # revisado. Rejeitar aqui (fail-closed, sem fallback) mantem o CI, o
  # instalador e o provisionador com o MESMO pin exato.
  # version: semver estrito (semver.org 2.0.0) ancorado em \A...\z -- NUNCA
  # ^/$, porque em .NET '$' casa tambem antes de um LF final e '01.2.3'
  # (zeros a esquerda), '1.2.3-..' (identificador de prerelease vazio) e
  # "1.2.3\n" passariam como se fossem pins revisados. Zero a esquerda em
  # major/minor/patch e identificador de prerelease vazio nao sao semver =>
  # reject (fail-closed) em vez de instalar outra coisa.
  # RR-VERSIONS-REGISTRY-FIX4: \d em .NET casa digito UNICODE (categoria Nd),
  # nao so '0'-'9'. '1\u0662.2.3' e '1.2.3-1\u0662' (arabic-indic digit) casavam
  # como se fossem pins revisados -- o mesmo buraco que '^...$' abria com LF
  # final. Usar [0-9] explicito em toda posicao numerica: o conjunto de digitos
  # aceitos passa a ser ASCII e independente de cultura/versao do runtime.
  $verPattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?\z'
  if ($ver -cnotmatch $verPattern) {
    throw ('runtime versions registry: ' + $group + '.' + $key + ' com version fora do semver exato (esperado ' + $verPattern + '; rejeita latest/range/^/~/espaco): ' + $ver + ' em ' + $path)
  }
  # package: nome npm fechado, opcionalmente com scope (@org/name), todo
  # lowercase (npm rejeita maiusculas; maiuscula aqui = entrada errada).
  $pkgPattern = '^(@[a-z0-9-][a-z0-9-._]*/)?[a-z0-9-][a-z0-9-._]*$'
  if ($pkg -cnotmatch $pkgPattern) {
    throw ('runtime versions registry: ' + $group + '.' + $key + ' com package fora do padrao npm fechado/lowercase (esperado ' + $pkgPattern + '): ' + $pkg + ' em ' + $path)
  }
  # Derivao obrigatoria: spec DEVE ser <package>@<version>. Divergencia entre
  # os tres campos e drift de edicao manual => fail closed (sem adivinhacao).
  if ($spec -cne ($pkg + '@' + $ver)) {
    throw ('runtime versions registry inconsistente em ' + $group + '.' + $key + ' (spec=' + $spec + ' esperado ' + $pkg + '@' + $ver + '): ' + $path)
  }
  return [pscustomobject]@{
    name = [string]$Name
    package = $pkg
    version = $ver
    spec = $spec
  }
}
