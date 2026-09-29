<#!
.SYNOPSIS
    Perfis isolados V1/V2 side-by-side (Phase 7, V3.1): lib dot-sourceable.
.DESCRIPTION
    Define funcoes para criar, verificar e remover perfis OpenCode isolados
    por XDG_CONFIG_HOME. Nao executa nada no dot-source: so define funcoes.
    PS 5.1 compativel (sem ternario, sem ??, sem Invoke-Expression).
    ASCII only. Nunca persiste env de usuario/maquina; nunca toca o binario
    opencode global; -ProvisionRuntime escreve SOMENTE sob o perfil.
    Fail closed: sem prova de isolamento, Both nao instala.
#>

$ErrorActionPreference = 'Stop'

function Get-P7Engine {
  if ($PSVersionTable.PSEdition -eq 'Core') { return 'pwsh' }
  return 'powershell'
}

function Get-P7DefaultProfileRoot {
  return (Join-Path $env:USERPROFILE '.opencode-orchestration\profiles')
}

function Get-P7ProfileName([string]$RuntimeId) {
  if ($RuntimeId -eq 'opencode-v1') { return 'v1' }
  if ($RuntimeId -eq 'opencode-v2') { return 'v2' }
  throw ('P7-PROFILE-FAIL: RuntimeId desconhecido (esperado opencode-v1|opencode-v2): ' + $RuntimeId)
}

function Get-P7InstallMode([string]$RuntimeId) {
  if ($RuntimeId -eq 'opencode-v2') { return 'V2' }
  if ($RuntimeId -eq 'opencode-v1') { return 'V1' }
  throw ('P7-PROFILE-FAIL: RuntimeId desconhecido: ' + $RuntimeId)
}

function Get-P7Generation([string]$RuntimeId) {
  if ($RuntimeId -eq 'opencode-v2') { return 2 }
  if ($RuntimeId -eq 'opencode-v1') { return 1 }
  throw ('P7-PROFILE-FAIL: RuntimeId desconhecido: ' + $RuntimeId)
}

function Get-P7ProvisionedBinary([string]$ProfileDir) {
  return (Join-Path $ProfileDir 'runtime\node_modules\.bin\opencode.cmd')
}

function Get-P7SourceRevision([string]$RepoRoot) {
  $rev = 'unknown'
  try {
    Push-Location -LiteralPath $RepoRoot
    try {
      $r = (& git rev-parse --short HEAD 2>$null)
      if (($LASTEXITCODE -eq 0) -and (-not [string]::IsNullOrWhiteSpace([string]$r))) {
        $rev = ([string]$r).Trim()
      }
    }
    finally { Pop-Location }
  }
  catch { $rev = 'unknown' }
  return $rev
}

function Assert-P7PathUnder([string]$Path, [string]$Root, [string]$What) {
  $pathNorm = ''
  $rootNorm = ''
  try { $pathNorm = ([IO.Path]::GetFullPath($Path)) } catch { throw ('P7-PROFILE-FAIL: ' + $What + ' com caminho nao normalizavel: ' + $Path) }
  try { $rootNorm = ([IO.Path]::GetFullPath($Root)) } catch { throw ('P7-PROFILE-FAIL: raiz nao normalizavel para ' + $What + ': ' + $Root) }
  $pathNorm = $pathNorm.TrimEnd('\')
  $rootNorm = $rootNorm.TrimEnd('\')
  $isUnder = $pathNorm.StartsWith($rootNorm + '\', [StringComparison]::OrdinalIgnoreCase)
  $isRoot = $pathNorm.Equals($rootNorm, [StringComparison]::OrdinalIgnoreCase)
  if ((-not $isUnder) -and (-not $isRoot)) {
    throw ('P7-PROFILE-FAIL: ' + $What + ' fora da raiz esperada: ' + $Path)
  }
  # Anti-reparse: caminha dos ancestrais EXISTENTES de $Path de baixo para
  # cima ate $Root; qualquer reparse point/junction no caminho falha.
  # $Root em si sendo reparse point e permitido (junction na raiz =
  # redirecionamento deliberado do usuario, decisao P9.1).
  $cursor = $pathNorm
  while ((-not [string]::IsNullOrWhiteSpace($cursor)) -and (-not $cursor.Equals($rootNorm, [StringComparison]::OrdinalIgnoreCase))) {
    if (Test-Path -LiteralPath $cursor) {
      try {
        $attrs = (Get-Item -Force -LiteralPath $cursor).Attributes
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
          throw ('P7-PROFILE-FAIL: ' + $What + ' atravessa reparse point: ' + $cursor)
        }
      }
      catch {
        if ($_.Exception.Message -match '^P7-PROFILE-FAIL') { throw }
        throw ('P7-PROFILE-FAIL: ' + $What + ' com inspeacao de ancestral falhando: ' + $cursor + ': ' + $_.Exception.Message)
      }
    }
    $parent = $cursor
    try { $parent = (Split-Path -Parent $cursor) } catch { break }
    if ([string]::IsNullOrWhiteSpace($parent) -or ($parent -eq $cursor)) { break }
    $cursor = $parent.TrimEnd('\')
    if ($cursor.Length -lt $rootNorm.Length) { break }
  }
}

function Invoke-P7Process {
  param(
    [string]$File = '',
    [string]$ArgsLine = '',
    [string]$WorkDir = '',
    [hashtable]$EnvTable = $null,
    [int]$TimeoutMs = 60000
  )
  $res = @{ ExitCode = -1; Output = ''; TimedOut = $false }
  if ([string]::IsNullOrWhiteSpace($File)) {
    $res.Output = 'P7-PROFILE-FAIL: Invoke-P7Process sem File.'
    return $res
  }
  # Anti-deadlock: filho verboso bloqueia se o pai nao drena stdout durante
  # WaitForExit (mesmo motivo dos runners: cmd /c com redirecionamento para
  # arquivo). Nunca pipe direto aqui.
  $logDir = Join-Path ([IO.Path]::GetTempPath()) ('p7-proc-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  $logFile = Join-Path $logDir 'out.log'
  try {
    $target = $File
    if (($target.Contains(' ')) -or ($target.Contains('"'))) {
      $target = '"' + ($target -replace '"', '\"') + '"'
    }
    $inner = $target
    if (-not [string]::IsNullOrWhiteSpace($ArgsLine)) { $inner = $inner + ' ' + $ArgsLine }
    $inner = $inner + ' > "' + $logFile + '" 2>&1'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/s /c "' + $inner + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true
    if ([string]::IsNullOrWhiteSpace($WorkDir)) { $psi.WorkingDirectory = [IO.Path]::GetTempPath() }
    else { $psi.WorkingDirectory = $WorkDir }
    try { $psi.EnvironmentVariables['PSModulePath'] = "$env:windir\System32\WindowsPowerShell\v1.0\Modules" } catch { }
    if ($null -ne $EnvTable) {
      foreach ($k in @($EnvTable.Keys)) {
        try { $psi.EnvironmentVariables[[string]$k] = [string]$EnvTable[$k] } catch { }
      }
    }
    try {
      $p = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
      $res.Output = ('processo nao iniciou (' + $File + '): ' + $_.Exception.Message)
      return $res
    }
    $finished = $false
    try {
      $finished = $p.WaitForExit($TimeoutMs)
    }
    catch {
      $res.Output = ('falha no wait: ' + $_.Exception.Message)
      return $res
    }
    if (-not $finished) {
      $res.TimedOut = $true
      try { & taskkill /PID $p.Id /T /F 2>$null | Out-Null } catch { }
      try { $p.WaitForExit(10000) } catch { }
      $res.Output = ('timeout apos ' + $TimeoutMs + 'ms')
    }
    else {
      try { $res.ExitCode = $p.ExitCode } catch { $res.ExitCode = -1 }
    }
    try { $p.Close() } catch { }
    try {
      if (Test-Path -LiteralPath $logFile -PathType Leaf) {
        $res.Output = ([IO.File]::ReadAllText($logFile, [Text.Encoding]::UTF8).Trim())
      }
    }
    catch { }
    return $res
  }
  finally {
    if (Test-Path -LiteralPath $logDir) {
      Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-P7Major([string]$Text) {
  $m = [regex]::Match([string]$Text, '(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return 0 }
  return [int]$m.Groups[1].Value
}

function Test-P7Isolation {
  param([string]$BinaryPath = '', [int]$Generation = 0)
  if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
    return @{ Ok = $false; Reason = 'binario ausente (caminho vazio)' }
  }
  if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
    return @{ Ok = $false; Reason = ('binario nao encontrado: ' + $BinaryPath) }
  }
  if (($Generation -ne 1) -and ($Generation -ne 2)) {
    return @{ Ok = $false; Reason = ('geracao invalida (esperado 1 ou 2): ' + $Generation) }
  }
  $vv = Invoke-P7Process -File $BinaryPath -ArgsLine '--version' -TimeoutMs 30000
  if ($vv.ExitCode -ne 0) {
    return @{ Ok = $false; Reason = ('--version falhou (exit ' + $vv.ExitCode + '): ' + [string]$vv.Output) }
  }
  $major = Get-P7Major $vv.Output
  if ($major -ne $Generation) {
    return @{ Ok = $false; Reason = ('geracao divergente: --version indica major ' + $major + ', esperado ' + $Generation) }
  }
  $dirA = Join-Path ([IO.Path]::GetTempPath()) ('p7-iso-a-' + [guid]::NewGuid().ToString('N'))
  $dirB = Join-Path ([IO.Path]::GetTempPath()) ('p7-iso-b-' + [guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType Directory -Path $dirA -Force | Out-Null
    New-Item -ItemType Directory -Path $dirB -Force | Out-Null
    foreach ($pair in @(@($dirA, $dirB), @($dirB, $dirA))) {
      $want = $pair[0]
      $other = $pair[1]
      $envT = @{ XDG_CONFIG_HOME = $want }
      $dp = Invoke-P7Process -File $BinaryPath -ArgsLine 'debug paths' -EnvTable $envT -TimeoutMs 30000
      if ($dp.ExitCode -ne 0) {
        return @{ Ok = $false; Reason = ('debug paths falhou (exit ' + $dp.ExitCode + ') com XDG=' + $want + ': ' + [string]$dp.Output) }
      }
      $out = [string]$dp.Output
      $wantSlash = ($want -replace '\\', '/')
      $wantBack = ($want -replace '/', '\')
      $seesWant = ($out.Contains($wantSlash) -or $out.Contains($wantBack))
      if (-not $seesWant) {
        return @{ Ok = $false; Reason = ('debug paths nao resolve config dentro do XDG (' + $want + ')') }
      }
      $otherSlash = ($other -replace '\\', '/')
      $otherBack = ($other -replace '/', '\')
      if ($out.Contains($otherSlash) -or $out.Contains($otherBack)) {
        return @{ Ok = $false; Reason = ('vazamento entre perfis: XDG=' + $want + ' expoe ' + $other) }
      }
    }
  }
  finally {
    if (Test-Path -LiteralPath $dirA) { Remove-Item -LiteralPath $dirA -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $dirB) { Remove-Item -LiteralPath $dirB -Recurse -Force -ErrorAction SilentlyContinue }
  }
  return @{ Ok = $true; Reason = 'XDG isolado (debug paths resolve config dentro de cada perfil, sem cross-leak)' }
}

function Get-P7RegistrySpec([string]$RepoRoot, [string]$RuntimeId) {
  $regPath = Join-Path $RepoRoot 'source\registry\runtimes.json'
  if (-not (Test-Path -LiteralPath $regPath -PathType Leaf)) {
    throw ('P7-PROFILE-FAIL: registry ausente: ' + $regPath)
  }
  try {
    $reg = ([IO.File]::ReadAllText($regPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  }
  catch {
    throw ('P7-PROFILE-FAIL: registry ilegivel: ' + $_.Exception.Message)
  }
  $node = $reg.runtimes.$RuntimeId
  if (($null -eq $node) -or [string]::IsNullOrWhiteSpace([string]$node.cli_package) -or [string]::IsNullOrWhiteSpace([string]$node.validated_version)) {
    throw ('P7-PROFILE-FAIL: registry sem cli_package/validated_version para ' + $RuntimeId)
  }
  return ([string]$node.cli_package + '@' + [string]$node.validated_version)
}

function Test-P7NetworkSignature([string]$Output) {
  $t = [string]$Output
  foreach ($sig in @('ENOTFOUND', 'ETIMEDOUT', 'EAI_AGAIN', 'ECONNREFUSED', 'ECONNRESET', 'ENETUNREACH', 'EHOSTUNREACH', 'EPROTO', 'socket hang up', 'fetch failed', 'network', 'Network', 'NETWORK')) {
    if ($t.Contains($sig)) { return $true }
  }
  return $false
}

function Install-P7RuntimeBinary {
  param([string]$RepoRoot = '', [string]$RuntimeId = '', [string]$RuntimeDir = '')
  $gen = Get-P7Generation $RuntimeId
  if ([string]::IsNullOrWhiteSpace($RuntimeDir)) {
    throw 'P7-PROFILE-FAIL: RuntimeDir vazio.'
  }
  $spec = Get-P7RegistrySpec $RepoRoot $RuntimeId
  $npmCmd = $null
  try {
    $cands = @(Get-Command -Name 'npm' -All -ErrorAction SilentlyContinue)
    foreach ($c in $cands) {
      if ($c.CommandType -eq 'Application') { $npmCmd = $c; break }
    }
    if (($null -eq $npmCmd) -and ($cands.Count -gt 0)) { $npmCmd = $cands[0] }
  }
  catch { $npmCmd = $null }
  if (($null -eq $npmCmd) -or [string]::IsNullOrWhiteSpace([string]$npmCmd.Source)) {
    throw 'P7-PROVISION: npm ausente no PATH (provisionamento requer npm; sem rede fora de -ProvisionRuntime).'
  }
  if (-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) {
    New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
  }
  $quotedPrefix = $RuntimeDir
  if (($quotedPrefix.Contains(' ')) -or ($quotedPrefix.Contains('"'))) {
    $quotedPrefix = '"' + ($quotedPrefix -replace '"', '\"') + '"'
  }
  if ($RuntimeId -eq 'opencode-v2') {
    $npmArgs = 'install --prefix ' + $quotedPrefix + ' --no-audit --no-fund --ignore-scripts ' + $spec
  }
  else {
    $npmArgs = 'install --prefix ' + $quotedPrefix + ' --no-audit --no-fund ' + $spec
  }
  $nr = Invoke-P7Process -File ([string]$npmCmd.Source) -ArgsLine $npmArgs -WorkDir ([IO.Path]::GetTempPath()) -TimeoutMs 240000
  if ($nr.TimedOut) {
    throw ('P7-PROVISION-NETWORK: npm timeout (240s) ao instalar ' + $spec + '; rede instavel ou indisponivel.')
  }
  if ($nr.ExitCode -ne 0) {
    $reason = ('npm install falhou (exit ' + $nr.ExitCode + ') para ' + $spec + ': ' + [string]$nr.Output)
    if (Test-P7NetworkSignature $nr.Output) {
      throw ('P7-PROVISION-NETWORK: ' + $reason)
    }
    throw ('P7-PROVISION: ' + $reason)
  }
  if ($RuntimeId -eq 'opencode-v2') {
    $post = Join-Path $RuntimeDir 'node_modules\@opencode\cli\postinstall.mjs'
    if (-not (Test-Path -LiteralPath $post -PathType Leaf)) {
      throw ('P7-PROVISION: postinstall V2 ausente apos npm install: ' + $post)
    }
    $nodeCmd = $null
    try { $nodeCmd = Get-Command -Name 'node' -ErrorAction SilentlyContinue } catch { $nodeCmd = $null }
    if (($null -eq $nodeCmd) -or [string]::IsNullOrWhiteSpace([string]$nodeCmd.Source)) {
      throw 'P7-PROVISION: node ausente no PATH (postinstall V2 requer node).'
    }
    $pr = Invoke-P7Process -File ([string]$nodeCmd.Source) -ArgsLine ('"' + $post + '"') -WorkDir ([IO.Path]::GetTempPath()) -TimeoutMs 240000
    if ($pr.TimedOut) {
      throw 'P7-PROVISION-NETWORK: postinstall V2 timeout (240s); rede instavel ou indisponivel.'
    }
    if ($pr.ExitCode -ne 0) {
      $reason = ('postinstall V2 falhou (exit ' + $pr.ExitCode + '): ' + [string]$pr.Output)
      if (Test-P7NetworkSignature $pr.Output) {
        throw ('P7-PROVISION-NETWORK: ' + $reason)
      }
      throw ('P7-PROVISION: ' + $reason)
    }
  }
  $bin = Join-Path $RuntimeDir 'node_modules\.bin\opencode.cmd'
  if (-not (Test-Path -LiteralPath $bin -PathType Leaf)) {
    throw ('P7-PROVISION: binario nao encontrado apos provisionamento: ' + $bin)
  }
  $vr = Invoke-P7Process -File $bin -ArgsLine '--version' -TimeoutMs 30000
  if ($vr.ExitCode -ne 0) {
    throw ('P7-PROVISION: binario provisionado nao responde --version (exit ' + $vr.ExitCode + '): ' + [string]$vr.Output)
  }
  $major = Get-P7Major $vr.Output
  if ($major -ne $gen) {
    throw ('P7-PROVISION: binario provisionado com geracao divergente (major ' + $major + ', esperado ' + $gen + ').')
  }
  $verLine = (([string]$vr.Output -split "`r?`n" | Select-Object -First 1).Trim())
  return @{ BinaryPath = $bin; Version = $verLine }
}

function Write-P7Wrapper {
  param([string]$ProfileRoot = '', [string]$Profile = '', [string]$RuntimeId = '', [int]$Generation = 0)
  $binDir = Join-Path $ProfileRoot 'bin'
  if (-not (Test-Path -LiteralPath $binDir -PathType Container)) {
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
  }
  $wrapperPath = Join-Path $binDir ('opencode-' + $Profile + '.ps1')
  $tmpl = @'
# opencode-{PROFILE}.ps1 -- wrapper de perfil isolado ({RUNTIME_ID}, geracao {GENERATION}).
# REGRAS: nunca persiste env global (USERPROFILE/machine); XDG_CONFIG_HOME
# aponta para o config root DO PERFIL apenas durante a execucao do binario,
# e o env do chamador e restaurado em finally. Nunca reescreve config de
# outro perfil; nunca instala nada (provisionamento e opt-in separado).
param(
  [string]$BinaryPath = '',
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArgs = @()
)
$ErrorActionPreference = 'Stop'
$ProfileTag = '{PROFILE}'
$WantedGeneration = {GENERATION}
$BinDirW = $PSScriptRoot
$ProfileRootW = Split-Path -Parent $BinDirW
$ProfileDirW = Join-Path $ProfileRootW $ProfileTag
$ProfileManifestW = Join-Path $ProfileDirW 'manifest.json'

function Get-WrapperMajor([string]$Text) {
  $m = [regex]::Match([string]$Text, '(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return 0 }
  return [int]$m.Groups[1].Value
}

$configRootW = Join-Path (Join-Path $ProfileDirW 'home') '.config'
$provisionedW = ''
if (Test-Path -LiteralPath $ProfileManifestW -PathType Leaf) {
  try {
    $pmW = ([IO.File]::ReadAllText($ProfileManifestW, [Text.Encoding]::UTF8)) | ConvertFrom-Json
    if (($null -ne $pmW) -and (-not [string]::IsNullOrWhiteSpace([string]$pmW.config_root))) {
      $configRootW = [string]$pmW.config_root
    }
    if (($null -ne $pmW) -and ($null -ne $pmW.provisioned) -and (-not [string]::IsNullOrWhiteSpace([string]$pmW.provisioned.binary_path))) {
      $provisionedW = [string]$pmW.provisioned.binary_path
    }
  }
  catch { }
}
$candsW = New-Object System.Collections.ArrayList
if (-not [string]::IsNullOrWhiteSpace($BinaryPath)) { [void]$candsW.Add($BinaryPath) }
if ((-not [string]::IsNullOrWhiteSpace($provisionedW)) -and ($candsW -notcontains $provisionedW)) { [void]$candsW.Add($provisionedW) }
try {
  $gcW = @(Get-Command -Name 'opencode' -All -ErrorAction SilentlyContinue)
  $pathW = $null
  foreach ($cW in $gcW) {
    if ($cW.CommandType -eq 'Application') { $pathW = $cW; break }
  }
  if (($null -eq $pathW) -and ($gcW.Count -gt 0)) { $pathW = $gcW[0] }
  if (($null -ne $pathW) -and (-not [string]::IsNullOrWhiteSpace([string]$pathW.Source)) -and ($candsW -notcontains [string]$pathW.Source)) {
    [void]$candsW.Add([string]$pathW.Source)
  }
}
catch { }
$chosenW = ''
foreach ($candW in $candsW) {
  if (-not (Test-Path -LiteralPath $candW -PathType Leaf)) { continue }
  try {
    $voW = (& $candW --version 2>&1 | Out-String)
  }
  catch { continue }
  if ((Get-WrapperMajor $voW) -eq $WantedGeneration) { $chosenW = $candW; break }
}
if ([string]::IsNullOrWhiteSpace($chosenW)) {
  Write-Host ('[wrapper ' + $ProfileTag + '] nenhum binario geracao ' + $WantedGeneration + ' encontrado.') -ForegroundColor Red
  Write-Host 'Provisione o binario do perfil (rede, opt-in):' -ForegroundColor Red
  Write-Host ('  powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId {RUNTIME_ID} -ProvisionRuntime') -ForegroundColor Red
  exit 6
}
$oldXdgW = $env:XDG_CONFIG_HOME
try {
  $env:XDG_CONFIG_HOME = $configRootW
  & $chosenW @RemainingArgs
  $codeW = $LASTEXITCODE
}
finally {
  if ($null -eq $oldXdgW) { Remove-Item Env:\XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
  else { $env:XDG_CONFIG_HOME = $oldXdgW }
}
exit $codeW
'@
  $tmpl = $tmpl.Replace('{PROFILE}', $Profile)
  $tmpl = $tmpl.Replace('{RUNTIME_ID}', $RuntimeId)
  $tmpl = $tmpl.Replace('{GENERATION}', [string]$Generation)
  [IO.File]::WriteAllText($wrapperPath, (($tmpl -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd() + "`n"), (New-Object Text.UTF8Encoding $false))
  return $wrapperPath
}

function Get-P7Profile {
  param([string]$ProfileRoot = '', [string]$Profile = '')
  $mf = Join-Path (Join-Path $ProfileRoot $Profile) 'manifest.json'
  if (-not (Test-Path -LiteralPath $mf -PathType Leaf)) { return $null }
  try {
    return (([IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8)) | ConvertFrom-Json)
  }
  catch { return $null }
}

function Write-P7JsonAtomic($Object, [string]$TargetPath) {
  # Escrita atomica padrao do repo: arquivo temporario no mesmo dir +
  # Move-Item -Force. O manifest do perfil e o ULTIMO artefato escrito
  # (marcador de sucesso): sua presenca indica perfil coerente.
  $tmp = $TargetPath + '.tmp-' + [guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($tmp, (((($Object | ConvertTo-Json -Depth 8).TrimEnd()) + "`n") -replace "`r`n", "`n" -replace "`r", "`n"), (New-Object Text.UTF8Encoding $false))
  Move-Item -LiteralPath $tmp -Destination $TargetPath -Force
}

function New-P7ProfileManifestObject {
  param(
    [string]$Profile = '',
    [string]$RuntimeId = '',
    [int]$Generation = 0,
    [string]$HomeDir = '',
    [string]$ConfigRoot = '',
    [string]$RuntimeDir = '',
    [string]$InstallManifest = '',
    [string]$WrapperPath = '',
    $ProvisionedNode = $null,
    [string]$RepoRoot = ''
  )
  $manifest = [ordered]@{
    profile = $Profile
    runtime_id = $RuntimeId
    generation = $Generation
    home_dir = $HomeDir
    config_root = $ConfigRoot
    runtime_dir = $RuntimeDir
    install_manifest = $InstallManifest
    wrapper = $WrapperPath
    created_at = ((Get-Date).ToString('o'))
    source_revision = (Get-P7SourceRevision $RepoRoot)
    provisioned = $ProvisionedNode
  }
  return $manifest
}

function New-OrchestrationProfile {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [string]$RepoRoot = '',
    [string]$ProfileRoot = '',
    [string]$RuntimeId = '',
    [switch]$ProvisionRuntime,
    [string]$BinaryOverride = ''
  )
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here)) { $here = (Get-Location).Path }
    try { $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $here '..\..')).Path } catch { }
  }
  if ([string]::IsNullOrWhiteSpace($RepoRoot) -or (-not (Test-Path -LiteralPath $RepoRoot -PathType Container))) {
    throw ('P7-PROFILE-FAIL: RepoRoot invalido: ' + $RepoRoot)
  }
  if ([string]::IsNullOrWhiteSpace($ProfileRoot)) { $ProfileRoot = Get-P7DefaultProfileRoot }
  if ([string]::IsNullOrWhiteSpace($RuntimeId)) {
    throw 'P7-PROFILE-FAIL: RuntimeId vazio (esperado opencode-v1|opencode-v2).'
  }
  $profile = Get-P7ProfileName $RuntimeId
  $mode = Get-P7InstallMode $RuntimeId
  $gen = Get-P7Generation $RuntimeId
  $profileDir = Join-Path $ProfileRoot $profile
  $homeDir = Join-Path $profileDir 'home'
  $configRoot = Join-Path $homeDir '.config'
  $runtimeDir = Join-Path $profileDir 'runtime'
  Assert-P7PathUnder $homeDir $ProfileRoot 'home do perfil'
  Assert-P7PathUnder $runtimeDir $ProfileRoot 'runtime do perfil'
  $installScript = Join-Path $RepoRoot 'install.ps1'
  if (-not (Test-Path -LiteralPath $installScript -PathType Leaf)) {
    throw ('P7-PROFILE-FAIL: install.ps1 ausente no RepoRoot: ' + $installScript)
  }
  $engine = Get-P7Engine
  if ($WhatIfPreference) {
    Write-Host ('=== PROFILE PLAN ' + $profile + ' (WhatIf, nenhuma escrita) ===') -ForegroundColor Cyan
    Write-Host ('[CREATE] ' + $homeDir + ' (install -Runtime ' + $mode + ')') -ForegroundColor DarkGray
    if (-not [string]::IsNullOrWhiteSpace($BinaryOverride)) { Write-Host ('[OVERRIDE] binario provado reusado: ' + $BinaryOverride + ' (sem npm)') -ForegroundColor DarkGray }
    elseif ($ProvisionRuntime) { Write-Host ('[PROVISION] binario ' + $RuntimeId + ' em ' + $runtimeDir + ' (rede, opt-in)') -ForegroundColor DarkGray }
    Write-Host ('[CREATE] wrapper ' + (Join-Path $ProfileRoot ('bin\opencode-' + $profile + '.ps1'))) -ForegroundColor DarkGray
    Write-Host ('[CREATE] manifest ' + (Join-Path $profileDir 'manifest.json') + ' (por ultimo, marcador de sucesso)') -ForegroundColor DarkGray
    $null = Invoke-P7Process -File $engine -ArgsLine ('-NoProfile -ExecutionPolicy Bypass -File "' + $installScript + '" -TargetHome "' + $homeDir + '" -Runtime ' + $mode + ' -WhatIf') -TimeoutMs 120000
    Write-Host ('Plano ' + $profile + ': nenhuma escrita realizada.') -ForegroundColor Cyan
    return @{ ProfileDir = $profileDir; HomeDir = $homeDir; ConfigRoot = $configRoot; RuntimeDir = $runtimeDir; WrapperPath = ''; ManifestPath = ''; BinaryPath = ''; Provisioned = $false }
  }
  if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
  }
  if (-not (Test-Path -LiteralPath $homeDir -PathType Container)) {
    New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
  }
  $ir = Invoke-P7Process -File $engine -ArgsLine ('-NoProfile -ExecutionPolicy Bypass -File "' + $installScript + '" -TargetHome "' + $homeDir + '" -Runtime ' + $mode) -TimeoutMs 300000
  if ($ir.TimedOut) {
    throw ('P7-INSTALL-EXIT-5: install do perfil ' + $profile + ' timeout (300s).')
  }
  if ([int]$ir.ExitCode -ne 0) {
    throw ('P7-INSTALL-EXIT-' + [int]$ir.ExitCode + ': install do perfil ' + $profile + ' falhou (exit ' + [int]$ir.ExitCode + '): ' + [string]$ir.Output)
  }
  $binaryPath = ''
  $versionLine = ''
  $provisioned = $false
  $provenance = ''
  $installManifest = Join-Path $homeDir '.opencode-orchestration\manifest.json'
  $manifestPath = Join-Path $profileDir 'manifest.json'
  $wrapperTarget = Join-Path $ProfileRoot ('bin\opencode-' + $profile + '.ps1')
  if (-not [string]::IsNullOrWhiteSpace($BinaryOverride)) {
    # Override explicito: valida e NAO provisiona npm. O binario provado e
    # reusado e gravado no manifest com provenance 'override'.
    if (-not (Test-Path -LiteralPath $BinaryOverride -PathType Leaf)) {
      throw ('P7-PROFILE-FAIL: BinaryOverride inexistente: ' + $BinaryOverride)
    }
    $ov = Invoke-P7Process -File $BinaryOverride -ArgsLine '--version' -TimeoutMs 30000
    if ([int]$ov.ExitCode -ne 0) {
      throw ('P7-PROFILE-FAIL: BinaryOverride nao responde --version (exit ' + [int]$ov.ExitCode + '): ' + [string]$ov.Output)
    }
    $ovMajor = Get-P7Major $ov.Output
    if ($ovMajor -ne $gen) {
      throw ('P7-PROFILE-FAIL: BinaryOverride com geracao divergente (major ' + $ovMajor + ', esperado ' + $gen + ').')
    }
    $binaryPath = $BinaryOverride
    $versionLine = (([string]$ov.Output -split "`r?`n" | Select-Object -First 1).Trim())
    $provisioned = $true
    $provenance = 'override'
  }
  elseif ($ProvisionRuntime) {
    Assert-P7PathUnder $runtimeDir $profileDir 'runtime do perfil'
    try {
      $pr = Install-P7RuntimeBinary -RepoRoot $RepoRoot -RuntimeId $RuntimeId -RuntimeDir $runtimeDir
      $binaryPath = $pr.BinaryPath
      $versionLine = $pr.Version
      $provisioned = $true
      $provenance = 'npm'
    }
    catch {
      # Falha de provisionamento: escreve wrapper + manifest com
      # provisioned = $null ANTES de rethrow da mesma excecao. O perfil de
      # arquivos criado fica coerente e recuperavel; o CLI mapeia
      # P7-PROVISION-NETWORK para exit 7.
      $partialWrapper = Write-P7Wrapper -ProfileRoot $ProfileRoot -Profile $profile -RuntimeId $RuntimeId -Generation $gen
      $partial = New-P7ProfileManifestObject -Profile $profile -RuntimeId $RuntimeId -Generation $gen -HomeDir $homeDir -ConfigRoot $configRoot -RuntimeDir $runtimeDir -InstallManifest $installManifest -WrapperPath $partialWrapper -ProvisionedNode $null -RepoRoot $RepoRoot
      Write-P7JsonAtomic $partial $manifestPath
      throw
    }
  }
  else {
    $maybe = Get-P7ProvisionedBinary $profileDir
    if (Test-Path -LiteralPath $maybe -PathType Leaf) {
      $binaryPath = $maybe
      $provisioned = $true
      $provenance = 'npm'
      try {
        $vr = Invoke-P7Process -File $maybe -ArgsLine '--version' -TimeoutMs 30000
        if ([int]$vr.ExitCode -eq 0) {
          $versionLine = (([string]$vr.Output -split "`r?`n" | Select-Object -First 1).Trim())
        }
      }
      catch { $versionLine = '' }
    }
  }
  # Ordem: WRAPPER antes do MANIFEST; o manifest e o ultimo artefato
  # (marcador de sucesso), escrito de forma atomica.
  $wrapperPath = Write-P7Wrapper -ProfileRoot $ProfileRoot -Profile $profile -RuntimeId $RuntimeId -Generation $gen
  $provNode = $null
  if ($provisioned) {
    $provNode = [ordered]@{ binary_path = $binaryPath; version = $versionLine; provenance = $provenance }
  }
  $manifest = New-P7ProfileManifestObject -Profile $profile -RuntimeId $RuntimeId -Generation $gen -HomeDir $homeDir -ConfigRoot $configRoot -RuntimeDir $runtimeDir -InstallManifest $installManifest -WrapperPath $wrapperPath -ProvisionedNode $provNode -RepoRoot $RepoRoot
  Write-P7JsonAtomic $manifest $manifestPath
  Write-Host ('[profile ' + $profile + '] home: ' + $homeDir) -ForegroundColor DarkGray
  Write-Host ('[profile ' + $profile + '] XDG_CONFIG_HOME: ' + $configRoot) -ForegroundColor DarkGray
  if ($provisioned) { Write-Host ('[profile ' + $profile + '] binario: ' + $binaryPath + ' (' + $versionLine + ')') -ForegroundColor DarkGray }
  else { Write-Host ('[profile ' + $profile + '] sem binario provisionado (usa PATH quando a geracao bate)') -ForegroundColor Yellow }
  Write-Host ('[profile ' + $profile + '] wrapper: ' + $wrapperPath) -ForegroundColor Green
  return @{ ProfileDir = $profileDir; HomeDir = $homeDir; ConfigRoot = $configRoot; RuntimeDir = $runtimeDir; WrapperPath = $wrapperPath; ManifestPath = $manifestPath; BinaryPath = $binaryPath; Provisioned = $provisioned }
}

function Remove-P7Profile {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [string]$RepoRoot = '',
    [string]$ProfileRoot = '',
    [string]$Profile = ''
  )
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here)) { $here = (Get-Location).Path }
    try { $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $here '..\..')).Path } catch { }
  }
  if ([string]::IsNullOrWhiteSpace($ProfileRoot)) { $ProfileRoot = Get-P7DefaultProfileRoot }
  if (($Profile -ne 'v1') -and ($Profile -ne 'v2')) {
    throw ('P7-PROFILE-FAIL: Profile invalido (esperado v1|v2): ' + $Profile)
  }
  $profileDir = Join-Path $ProfileRoot $Profile
  if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
    throw ('P7-PROFILE-FAIL: perfil inexistente: ' + $profileDir)
  }
  Assert-P7PathUnder $profileDir $ProfileRoot 'perfil'
  # Prova de ownership antes de destruir: manifest do perfil legivel E
  # consistente (runtime_id/generation batem com o nome do perfil; paths
  # sob ProfileRoot). Fallback unico para estado parcial: manifest do
  # perfil ausente/ilegivel, mas com install manifest no home (prova de
  # que o install.ps1 escreveu aquele home). Sem prova => throw, NADA
  # removido (remocao manual orientada na mensagem).
  $wantRuntime = 'opencode-v1'
  $wantGen = 1
  if ($Profile -eq 'v2') { $wantRuntime = 'opencode-v2'; $wantGen = 2 }
  $homeDir = Join-Path $profileDir 'home'
  Assert-P7PathUnder $homeDir $ProfileRoot ('home derivado do perfil ' + $Profile)
  $owned = $false
  $profileManifest = Join-Path $profileDir 'manifest.json'
  if (Test-Path -LiteralPath $profileManifest -PathType Leaf) {
    $pm = $null
    try { $pm = (([IO.File]::ReadAllText($profileManifest, [Text.Encoding]::UTF8)) | ConvertFrom-Json) } catch { $pm = $null }
    if ($null -eq $pm) {
      # Ilegivel: tenta o fallback de estado parcial abaixo.
    }
    else {
      if (([string]$pm.runtime_id -ne $wantRuntime) -or ([int]$pm.generation -ne $wantGen)) {
        throw ('P7-PROFILE-FAIL: perfil ' + $Profile + ' com manifest inconsistente (runtime_id/generation nao batem com o nome); nada foi removido. Remova manualmente se for seguro: ' + $profileDir)
      }
      Assert-P7PathUnder ([string]$pm.home_dir) $ProfileRoot ('home do manifest do perfil ' + $Profile)
      Assert-P7PathUnder ([string]$pm.config_root) $ProfileRoot ('config do manifest do perfil ' + $Profile)
      Assert-P7PathUnder ([string]$pm.runtime_dir) $ProfileRoot ('runtime do manifest do perfil ' + $Profile)
      $pmHomeNorm = ''
      $derivedHomeNorm = ''
      try { $pmHomeNorm = ([IO.Path]::GetFullPath([string]$pm.home_dir)).TrimEnd('\') } catch { throw ('P7-PROFILE-FAIL: perfil ' + $Profile + ' com home_dir nao normalizavel; nada foi removido.') }
      try { $derivedHomeNorm = ([IO.Path]::GetFullPath($homeDir)).TrimEnd('\') } catch { throw ('P7-PROFILE-FAIL: perfil ' + $Profile + ' com home derivado nao normalizavel; nada foi removido.') }
      if (-not $pmHomeNorm.Equals($derivedHomeNorm, [StringComparison]::OrdinalIgnoreCase)) {
        throw ('P7-PROFILE-FAIL: perfil ' + $Profile + ' com home_dir divergente do home derivado; nada foi removido. Remova manualmente se for seguro: ' + $profileDir)
      }
      $owned = $true
    }
  }
  if (-not $owned) {
    # Fallback unico para estado parcial: manifest do perfil ausente/
    # ilegivel, mas com install manifest (install.ps1) no home DERIVADO
    # cujo JSON parseia E cuja identidade bate com o perfil alvo
    # (runtime.id+generation + target_home == home derivado + package_version
    # presente). Existencia sozinha nunca e prova.
    $installProof = Join-Path $homeDir '.opencode-orchestration\manifest.json'
    if (Test-Path -LiteralPath $installProof -PathType Leaf) {
      $im = $null
      try { $im = (([IO.File]::ReadAllText($installProof, [Text.Encoding]::UTF8)) | ConvertFrom-Json) } catch { $im = $null }
      if ($null -ne $im) {
        $imTarget = ''
        $imPkg = ''
        $imRid = ''
        $imGen = 0
        try { $imTarget = [string]$im.target_home } catch { $imTarget = '' }
        try { $imPkg = [string]$im.package_version } catch { $imPkg = '' }
        try { $imRid = [string]$im.runtime.id } catch { $imRid = '' }
        try { $imGen = [int]$im.runtime.generation } catch { $imGen = 0 }
        if ((-not [string]::IsNullOrWhiteSpace($imPkg)) -and ($imRid -eq $wantRuntime) -and ($imGen -eq $wantGen) -and (-not [string]::IsNullOrWhiteSpace($imTarget))) {
          $imTargetNorm = ''
          $derivedNorm = ''
          try { $imTargetNorm = ([IO.Path]::GetFullPath($imTarget)).TrimEnd('\') } catch { $imTargetNorm = '' }
          try { $derivedNorm = ([IO.Path]::GetFullPath($homeDir)).TrimEnd('\') } catch { $derivedNorm = '' }
          if ((-not [string]::IsNullOrWhiteSpace($imTargetNorm)) -and (-not [string]::IsNullOrWhiteSpace($derivedNorm)) -and $imTargetNorm.Equals($derivedNorm, [StringComparison]::OrdinalIgnoreCase)) {
            $owned = $true
          }
        }
      }
    }
  }
  if (-not $owned) {
    throw ('P7-PROFILE-FAIL: perfil ' + $Profile + ' sem prova de ownership (sem manifest.json do perfil nem install manifest em home\.opencode-orchestration); nada foi removido. Remova manualmente se for seguro: ' + $profileDir)
  }
  $uninstallScript = Join-Path $RepoRoot 'uninstall.ps1'
  if ($WhatIfPreference) {
    Write-Host ('=== PROFILE REMOVE ' + $Profile + ' (WhatIf, nenhuma escrita) ===') -ForegroundColor Cyan
    Write-Host ('[REMOVE] uninstall do pacote em ' + $homeDir) -ForegroundColor DarkGray
    Write-Host ('[REMOVE] diretorio ' + $profileDir) -ForegroundColor DarkGray
    Write-Host ('[REMOVE] wrapper ' + (Join-Path $ProfileRoot ('bin\opencode-' + $Profile + '.ps1'))) -ForegroundColor DarkGray
    Write-Host 'Nenhuma escrita realizada.' -ForegroundColor Cyan
    return
  }
  $homeManifest = Join-Path $homeDir '.opencode-orchestration\manifest.json'
  $homeOc = Join-Path $homeDir '.config\opencode'
  if ((Test-Path -LiteralPath $homeManifest -PathType Leaf) -or (Test-Path -LiteralPath $homeOc -PathType Container)) {
    Assert-P7PathUnder $homeDir $ProfileRoot ('home derivado do perfil ' + $Profile)
    if (-not (Test-Path -LiteralPath $uninstallScript -PathType Leaf)) {
      throw ('P7-PROFILE-FAIL: uninstall.ps1 ausente no RepoRoot: ' + $uninstallScript)
    }
    $engine = Get-P7Engine
    $ur = Invoke-P7Process -File $engine -ArgsLine ('-NoProfile -ExecutionPolicy Bypass -File "' + $uninstallScript + '" -TargetHome "' + $homeDir + '"') -TimeoutMs 120000
    if ($ur.TimedOut) {
      throw ('P7-INSTALL-EXIT-5: uninstall do perfil ' + $Profile + ' timeout (120s).')
    }
    if ([int]$ur.ExitCode -ne 0) {
      throw ('P7-INSTALL-EXIT-' + [int]$ur.ExitCode + ': uninstall do perfil ' + $Profile + ' falhou (exit ' + [int]$ur.ExitCode + '): ' + [string]$ur.Output)
    }
  }
  Assert-P7PathUnder $profileDir $ProfileRoot ('perfil antes de remover ' + $Profile)
  Assert-P7PathUnder $homeDir $ProfileRoot ('home derivado antes de remover ' + $Profile)
  Remove-Item -LiteralPath $profileDir -Recurse -Force
  $wrapperPath = Join-Path $ProfileRoot ('bin\opencode-' + $Profile + '.ps1')
  if (Test-Path -LiteralPath $wrapperPath -PathType Leaf) {
    Remove-Item -LiteralPath $wrapperPath -Force
  }
  Write-Host ('[profile ' + $Profile + '] removido; demais perfis intactos.') -ForegroundColor Green
}
