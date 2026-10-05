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

# Preflight lib preload em escopo de biblioteca (fix RR-P22-FIX1 finding 6):
# dot-source AQUI no top-level do modulo, nunca dentro de funcao (senao as
# funcoes somem com o escopo local ao retornar). Import-P7Preflight abaixo
# NAO executa dot-source (so relata disponibilidade); call sites usam Ensure
# via Get-Command. Sem loops: carrega uma vez se ausente.
try {
  if (-not (Get-Command Set-PreflightPersistedPort -ErrorAction SilentlyContinue)) {
    $P7PreflightCandidate = ''
    try { $P7PreflightCandidate = (Join-Path $PSScriptRoot 'lib\RuntimePortPreflight.ps1') } catch { $P7PreflightCandidate = '' }
    if ((-not [string]::IsNullOrWhiteSpace($P7PreflightCandidate)) -and (Test-Path -LiteralPath $P7PreflightCandidate -PathType Leaf)) {
      # RR-P22-WRAPPER-FIX2: bootstrap ancestry FULL antes do dot-source
      # (sem carregar codigo antes dos checks). Walk ate o volume, sem
      # reparse em nenhum ancestral existente; falha => sem dot-source.
      $bootOk = $true
      try {
        $bootCursor = ([IO.Path]::GetFullPath($P7PreflightCandidate)).TrimEnd('\')
        while (-not [string]::IsNullOrWhiteSpace($bootCursor)) {
          if (Test-Path -LiteralPath $bootCursor) {
            try {
              $bootAttrs = (Get-Item -Force -LiteralPath $bootCursor -ErrorAction Stop).Attributes
              if (($bootAttrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $bootOk = $false; break }
            }
            catch { $bootOk = $false; break }
          }
          $bootParent = $bootCursor
          try { $bootParent = (Split-Path -Parent $bootCursor) } catch { break }
          if ([string]::IsNullOrWhiteSpace($bootParent) -or ($bootParent -eq $bootCursor)) { break }
          $bootCursor = $bootParent.TrimEnd('\')
        }
      }
      catch { $bootOk = $false }
      if ($bootOk) {
        . $P7PreflightCandidate
      }
    }
  }
}
catch { }

# RR-P22-JOB-OBJECTS: containment de ARVORE no timeout de Invoke-P7Process. Sem
# esta lib o unico primitivo seria matar so o root (cmd.exe), o que ORFA o filho
# real e mantem handles abertos - pior que o antigo /T, nao apenas diferente.
# Carrega uma vez se ausente; falha de carga e neutra (o fallback honesto por
# handle do proprio spawn continua valendo). Nao pode lancar no load.
try {
  if (-not (Get-Command -Name 'New-RuntimeJobObject' -ErrorAction SilentlyContinue)) {
    $P7JobCandidate = ''
    try { $P7JobCandidate = (Join-Path $PSScriptRoot 'lib\RuntimeJobObject.ps1') } catch { $P7JobCandidate = '' }
    if ((-not [string]::IsNullOrWhiteSpace($P7JobCandidate)) -and (Test-Path -LiteralPath $P7JobCandidate -PathType Leaf)) {
      # Mesma walk de ancestry do preflight acima: nenhum reparse point em
      # nenhum ancestral existente antes de carregar codigo.
      $jobOk = $true
      try {
        $jobCursor = ([IO.Path]::GetFullPath($P7JobCandidate)).TrimEnd('\')
        while (-not [string]::IsNullOrWhiteSpace($jobCursor)) {
          if (Test-Path -LiteralPath $jobCursor) {
            try {
              $jobAttrs = (Get-Item -Force -LiteralPath $jobCursor -ErrorAction Stop).Attributes
              if (($jobAttrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $jobOk = $false; break }
            }
            catch { $jobOk = $false; break }
          }
          $jobParent = $jobCursor
          try { $jobParent = (Split-Path -Parent $jobCursor) } catch { break }
          if ([string]::IsNullOrWhiteSpace($jobParent) -or ($jobParent -eq $jobCursor)) { break }
          $jobCursor = $jobParent.TrimEnd('\')
        }
      }
      catch { $jobOk = $false }
      if ($jobOk) { . $P7JobCandidate }
    }
  }
}
catch { }

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
  # RR-P22-FIX1 finding 8 (helper existente envolvido): rejeita paths com
  # metachars sensiveis ao cmd.exe antes de qualquer execucao. Nova mutacao
  # usa exe resolvido sem shell (ver lib preflight); este helper legado
  # mantem cmd /c mas nunca com File/WorkDir suspeitos.
  try {
    if (($File -match '[&|<>^%!`$;(){}\[\]"' + "'" + ']') -or ($WorkDir -match '[&|<>^]')) {
      $res.Output = 'P7-PROFILE-FAIL: Invoke-P7Process recusado (metachar cmd sensivel em File/WorkDir).'
      return $res
    }
  }
  catch { }
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
    # RR-P22-JOB-OBJECTS: job criado ANTES do start e filho (cmd /s /c) atribuido
    # logo apos o spawn pelo handle do spawn PROPRIO; no timeout a arvore morre
    # por KILL_ON_JOB_CLOSE (descendentes por heranca, mais forte que /T por
    # arvore). Cleanup NUNCA por arvore de PID historico. Sem a lib carregada ou sem
    # atribuicao provada o fallback e $p.Kill() no handle do proprio spawn
    # (root-only: descendentes podem escapar, sem claim de tree kill).
    $pJob = $null
    $pJobAssigned = $false
    $pJobNote = ''
    try {
      if (Get-Command -Name 'New-RuntimeJobObject' -ErrorAction SilentlyContinue) {
        # ANONIMO por chamada (sem -Name => CreateJobObjectW com nome nulo): nome
        # fixo FARIA CreateJobObjectW abrir um job preexistente e o stop de uma
        # chamada mataria filhos de outra. isolamento por handle.
        $pJob = New-RuntimeJobObject
        if ([bool]$pJob.Ok) { $pJobNote = 'job anonimo criado antes do start' }
        else { $pJobNote = ('job nao criado: ' + [string]$pJob.Reason) }
      }
      else { $pJobNote = 'lib RuntimeJobObject.ps1 nao carregada: fallback root-only' }
    }
    catch { $pJobNote = 'falha ao criar o job: ' + [string]$_.Exception.Message; $pJob = $null }
    try {
      $p = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
      $res.Output = ('processo nao iniciou (' + $File + '): ' + $_.Exception.Message)
      try { [void](Close-RuntimeJobObject -Job $pJob) } catch { }
      return $res
    }
    if ($null -ne $pJob -and [bool]$pJob.Ok) {
      try {
        $pAdd = Add-RuntimeJobProcess -Job $pJob -Process $p
        if ([bool]$pAdd.Ok) { $pJobAssigned = $true; $pJobNote = $pJobNote + ' | filho atribuido ao job' }
        else { $pJobNote = $pJobNote + ' | atribuicao falhou: ' + [string]$pAdd.Reason }
      }
      catch { $pJobNote = $pJobNote + ' | atribuicao lancou: ' + [string]$_.Exception.Message }
    }
    $finished = $false
    try {
      $finished = $p.WaitForExit($TimeoutMs)
    }
    catch {
      $res.Output = ('falha no wait: ' + $_.Exception.Message)
      try { [void](Close-RuntimeJobObject -Job $pJob) } catch { }
      return $res
    }
    if (-not $finished) {
      $res.TimedOut = $true
      if ($pJobAssigned) {
        try { [void](Stop-RuntimeJobObject -Job $pJob -TimeoutMs 15000) } catch { }
      }
      else {
        try { $p.Kill() } catch { }
      }
      try { [void](Close-RuntimeJobObject -Job $pJob) } catch { }
      try { $p.WaitForExit(10000) } catch { }
      $res.Output = ('timeout apos ' + $TimeoutMs + 'ms (' + $pJobNote + ')')
    }
    else {
      try { $res.ExitCode = $p.ExitCode } catch { $res.ExitCode = -1 }
      # Sucesso: fecha o job (idempotente) sem matar nada.
      try { [void](Close-RuntimeJobObject -Job $pJob) } catch { }
    }
    try { $p.Close() } catch { }
    try {
      if (Test-Path -LiteralPath $logFile -PathType Leaf) {
        $rawOut = ([IO.File]::ReadAllText($logFile, [Text.Encoding]::UTF8).Trim())
        if ($rawOut.Length -gt 32768) { $rawOut = $rawOut.Substring(0, 32768) + "`n...[truncado]..." }
        try { $rawOut = [regex]::Replace($rawOut, '(?i)(api[_-]?key|token|secret|authorization|bearer|password|passwd|\bpwd\b)\s*[:=]\s*\S+', '$1=[REDACTED]') } catch { }
        $res.Output = $rawOut
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

function Get-P7PreflightLib([string]$RepoRoot) {
  $lib = Join-Path $RepoRoot 'scripts\runtime\lib\RuntimePortPreflight.ps1'
  if (Test-Path -LiteralPath $lib -PathType Leaf) { return $lib }
  return ''
}

function Import-P7Preflight([string]$RepoRoot) {
  # Compat: NAO executa dot-source aqui (escopo local desapareceria no return
  # e loops dot-source sao proibidos). O preload top-level deste modulo ja
  # carregou a lib em escopo de biblioteca. Retorna disponibilidade apenas.
  try {
    if (Get-Command Set-PreflightPersistedPort -ErrorAction SilentlyContinue) { return $true }
  }
  catch { }
  try {
    $lib = Get-P7PreflightLib $RepoRoot
    if ((-not [string]::IsNullOrWhiteSpace($lib)) -and (Test-Path -LiteralPath $lib -PathType Leaf)) { return $true }
  }
  catch { }
  return $false
}

function Assert-P7PreflightLoaded {
  try {
    if (Get-Command Set-PreflightPersistedPort -ErrorAction SilentlyContinue) { return }
  }
  catch { }
  throw 'P7-PROFILE-FAIL: preflight lib indisponivel (Set-PreflightPersistedPort ausente; faca dot-source da lib em escopo de biblioteca, nunca dentro de funcao).'
}

function Write-P7PreflightLibCopy {
  param([string]$RepoRoot = '', [string]$ProfileDir = '')
  # RR-P22-FIX2 (1): a lib e distribuida JUNTO ao perfil (copia gerenciada
  # com ownership), nao inline duplicado no wrapper. O wrapper usa dot-source
  # nesta copia; lib ausente/divergente BLOQUEIA startup (fail-closed).
  if ([string]::IsNullOrWhiteSpace($RepoRoot) -or (-not (Test-Path -LiteralPath $RepoRoot -PathType Container))) {
    throw ('P7-PROFILE-FAIL: RepoRoot invalido para copia da lib preflight: ' + $RepoRoot)
  }
  if ([string]::IsNullOrWhiteSpace($ProfileDir) -or (-not (Test-Path -LiteralPath $ProfileDir -PathType Container))) {
    throw ('P7-PROFILE-FAIL: ProfileDir invalido para copia da lib preflight: ' + $ProfileDir)
  }
  $src = Get-P7PreflightLib $RepoRoot
  if ([string]::IsNullOrWhiteSpace($src)) {
    throw 'P7-PROFILE-FAIL: lib preflight ausente no repo (scripts\runtime\lib\RuntimePortPreflight.ps1); perfil sem gate e recusado.'
  }
  Assert-P7PathUnder $ProfileDir (Split-Path -Parent $ProfileDir) 'perfil (destino da lib)'
  $destDir = Join-Path $ProfileDir 'lib'
  if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
  }
  $dest = Join-Path $destDir 'RuntimePortPreflight.ps1'
  $tmp = $dest + '.tmp-' + [guid]::NewGuid().ToString('N')
  Copy-Item -LiteralPath $src -Destination $tmp -Force
  $hSrc = ''
  $hDst = ''
  try { $hSrc = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash } catch { throw 'P7-PROFILE-FAIL: hash da lib origem falhou.' }
  try { $hDst = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash } catch { throw 'P7-PROFILE-FAIL: hash da copia da lib falhou.' }
  if ($hSrc -ne $hDst) {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    throw 'P7-PROFILE-FAIL: copia da lib preflight divergente (hash); perfil sem gate e recusado.'
  }
  Move-Item -LiteralPath $tmp -Destination $dest -Force
  return $dest
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
# NOTA: parametros do wrapper sao manuais (exact-match, sem prefix-match do
# PowerShell): -BinaryPath <exe> | -ServicePort <porta> | -- <args nativos>.
# Flags nativas com traco (ex. serve --service) passam direto; '--service'
# nunca casa com -ServicePort aqui. Uso: opencode-{PROFILE}.ps1 [-BinaryPath
# <exe>] [-ServicePort <porta>] [--] <args nativos...>.
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$RemainingArgs = @()
)
$ErrorActionPreference = 'Stop'
$BinaryPath = ''
$ServicePort = 0
$NativeArgsW = New-Object System.Collections.ArrayList
try {
  $iW = 0
  $endW = $false
  $rawW = @($RemainingArgs)
  while ($iW -lt $rawW.Count) {
    $tW = [string]$rawW[$iW]
    if ($endW) { [void]$NativeArgsW.Add($tW); $iW++; continue }
    if (($tW -eq '--')) { $endW = $true; $iW++; continue }
    $lowW = $tW.Trim().ToLowerInvariant()
    if (($lowW -eq '-binarypath') -or ($lowW -eq '--binarypath') -or ($lowW -eq '/binarypath')) {
      if (($iW + 1) -ge $rawW.Count) { Write-Host ('[wrapper {PROFILE}] -BinaryPath exige valor.') -ForegroundColor Red; exit 1 }
      $BinaryPath = [string]$rawW[$iW + 1]
      $iW += 2
      continue
    }
    if (($lowW -eq '-serviceport') -or ($lowW -eq '--serviceport') -or ($lowW -eq '/serviceport')) {
      if (($iW + 1) -ge $rawW.Count) { Write-Host ('[wrapper {PROFILE}] -ServicePort exige valor 1..65535.') -ForegroundColor Red; exit 1 }
      $vvW = 0
      try { $vvW = [int]$rawW[$iW + 1] } catch { $vvW = 0 }
      if (($vvW -lt 1) -or ($vvW -gt 65535)) { Write-Host ('[wrapper {PROFILE}] -ServicePort invalida (esperado 1..65535).') -ForegroundColor Red; exit 1 }
      $ServicePort = $vvW
      $iW += 2
      continue
    }
    if (($lowW.StartsWith('-binarypath:')) -or ($lowW.StartsWith('--binarypath:')) -or ($lowW.StartsWith('-binarypath=')) -or ($lowW.StartsWith('--binarypath='))) {
      $sepW = $tW.IndexOf(':')
      $eqW = $tW.IndexOf('=')
      if (($eqW -ge 0) -and (($sepW -lt 0) -or ($eqW -lt $sepW))) { $sepW = $eqW }
      $BinaryPath = $tW.Substring($sepW + 1)
      $iW++
      continue
    }
    if (($lowW.StartsWith('-serviceport:')) -or ($lowW.StartsWith('--serviceport:')) -or ($lowW.StartsWith('-serviceport=')) -or ($lowW.StartsWith('--serviceport='))) {
      $sepW = $tW.IndexOf(':')
      $eqW = $tW.IndexOf('=')
      if (($eqW -ge 0) -and (($sepW -lt 0) -or ($eqW -lt $sepW))) { $sepW = $eqW }
      $vvW = 0
      try { $vvW = [int]$tW.Substring($sepW + 1) } catch { $vvW = 0 }
      if (($vvW -lt 1) -or ($vvW -gt 65535)) { Write-Host ('[wrapper {PROFILE}] -ServicePort invalida (esperado 1..65535).') -ForegroundColor Red; exit 1 }
      $ServicePort = $vvW
      $iW++
      continue
    }
    [void]$NativeArgsW.Add($tW)
    $iW++
  }
  # Compat: primeiro token posicional como BinaryPath SOMENTE se for arquivo
  # .exe/.cmd existente (uso legado); comandos nativos (service/serve/--version)
  # nunca sao arquivos .exe/.cmd, entao nunca ha confusao.
  if ([string]::IsNullOrWhiteSpace($BinaryPath) -and ($NativeArgsW.Count -gt 0)) {
    try {
      $firstW = [string]$NativeArgsW[0]
      if ((($firstW.ToLowerInvariant().EndsWith('.exe')) -or ($firstW.ToLowerInvariant().EndsWith('.cmd'))) -and (Test-Path -LiteralPath $firstW -PathType Leaf)) {
        $BinaryPath = $firstW
        $NativeArgsW.RemoveAt(0)
      }
    }
    catch { }
  }
  $RemainingArgs = @($NativeArgsW)
}
catch {
  if ($_.Exception.Message -match '^\[wrapper') { throw }
  Write-Host ('[wrapper {PROFILE}] argumentos invalidos: ' + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
$ErrorActionPreference = 'Stop'
$ProfileTag = '{PROFILE}'
$WantedGeneration = {GENERATION}
$BinDirW = $PSScriptRoot
$ProfileRootW = Split-Path -Parent $BinDirW
$ProfileDirW = Join-Path $ProfileRootW $ProfileTag
$ProfileManifestW = Join-Path $ProfileDirW 'manifest.json'
# RR-P22-FIX2: lib distribuida junto ao perfil (copia gerenciada com hash);
# sem inline duplicado no wrapper. Ausente => startup bloqueado.
$PreflightLibW = Join-Path $ProfileDirW 'lib\RuntimePortPreflight.ps1'

function Test-WrapperDiagAllowed {
  param([string[]]$Argv = @())
  # RR-P22-WRAPPER-FIX1: allowlist EXATA de tokens read-only. Somente
  # --version / --help (token unico exato), service status / service get
  # (dois tokens exatos) e service get port (tres tokens exatos) passam sem
  # gate. Sem regex ampla, sem bypass. get/status/--version nunca iniciam.
  $toks = @($Argv | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($toks.Count -eq 1) {
    $t0 = ([string]$toks[0]).Trim().ToLowerInvariant()
    if (($t0 -eq '--version') -or ($t0 -eq '--help')) { return $true }
    return $false
  }
  if ($toks.Count -eq 2) {
    $t0 = ([string]$toks[0]).Trim().ToLowerInvariant()
    $t1 = ([string]$toks[1]).Trim().ToLowerInvariant()
    if (($t0 -eq 'service') -and (($t1 -eq 'status') -or ($t1 -eq 'get'))) { return $true }
    return $false
  }
  if ($toks.Count -eq 3) {
    $t0 = ([string]$toks[0]).Trim().ToLowerInvariant()
    $t1 = ([string]$toks[1]).Trim().ToLowerInvariant()
    $t2 = ([string]$toks[2]).Trim().ToLowerInvariant()
    if (($t0 -eq 'service') -and ($t1 -eq 'get') -and ($t2 -eq 'port')) { return $true }
    return $false
  }
  return $false
}

function Test-WrapperStartupAllowed {
  param([string[]]$Argv = @())
  # RR-P22-WRAPPER-FIX1: startup permitido SOMENTE service start e
  # serve --service, ambos com aridade exata 2. TUI default (vazio) e
  # demais comandos sao unknown bloqueado com reason honesta (Phase22 nao
  # suporta sessao interativa sem lifetime bounded).
  $toks = @($Argv | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($toks.Count -ne 2) { return $false }
  $t0 = ([string]$toks[0]).Trim().ToLowerInvariant()
  $t1 = ([string]$toks[1]).Trim().ToLowerInvariant()
  if (($t0 -eq 'service') -and ($t1 -eq 'start')) { return $true }
  if (($t0 -eq 'serve') -and ($t1 -eq '--service')) { return $true }
  return $false
}

function Test-WrapperBlockedReason {
  param([string[]]$Argv = @())
  # RR-P22-WRAPPER-FIX1 vinculo semantico: recusa mutadores (service
  # set/stop/restart) e opts de destino (--port etc) ANTES de qualquer
  # execucao. service set SOMENTE via helper protected
  # (Invoke-PreflightServiceSetPort); o wrapper nunca encaminha mutadores
  # arbitrarios. Retorna '' quando permitido/unknown (unknown e tratado
  # como bloqueado pelo chamador com reason honesta distinta).
  # RR-P22-WRAPPER-FIX2: destino ANTES de aridade (serve --port retorna
  # opt de destino, consistente com os testes de exit 2 sem execucao).
  $toks = @($Argv | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  foreach ($rawT in @($toks)) {
    $low = ([string]$rawT).Trim().ToLowerInvariant()
    if (($low -eq '--port') -or ($low -eq '-port') -or ($low -eq '/port') -or ($low -eq '--service-port') -or ($low -eq '-serviceport') -or ($low -eq '--serviceport') -or ($low -eq '-p')) {
      return ('opt de destino recusada (' + [string]$rawT + '); porta SOMENTE via -ServicePort do wrapper com marker pending + gate central.')
    }
    if (($low.StartsWith('--port=')) -or ($low.StartsWith('--port:')) -or ($low.StartsWith('-port=')) -or ($low.StartsWith('-port:')) -or ($low.StartsWith('--service-port=')) -or ($low.StartsWith('--service-port:')) -or ($low.StartsWith('--serviceport=')) -or ($low.StartsWith('--serviceport:'))) {
      return ('opt de destino recusada (' + [string]$rawT + '); porta SOMENTE via -ServicePort do wrapper com marker pending + gate central.')
    }
  }
  if ($toks.Count -ge 2) {
    $t0 = ([string]$toks[0]).Trim().ToLowerInvariant()
    $t1 = ([string]$toks[1]).Trim().ToLowerInvariant()
    if (($t0 -eq 'service') -and (($t1 -eq 'set') -or ($t1 -eq 'stop') -or ($t1 -eq 'restart'))) {
      return ('mutador service ' + $t1 + ' recusado pelo wrapper; service set SOMENTE via helper protected com empty-state provado, stop/restart fora de escopo (cleanup E2E pelo harness com prova de ownership direta, sem wrapper).')
    }
    if (($t0 -eq 'serve') -and ($toks.Count -ne 2)) {
      return 'serve com aridade/flags fora de serve --service exato recusado (sem encaminhar flags arbitrarias).'
    }
  }
  return ''
}

function Test-WrapperAncestryClean {
  param([string]$Path = '', [string]$Root = '')
  # RR-P22-WRAPPER-FIX2 guard full: contencao lexical SEPARADA do walk.
  # Walk SEMPRE ate a raiz do filesystem (nunca break em Root): junction
  # acima do perfil redireciona todo filho confinado. Modo confinado (Root
  # nao vazio): exige Path sob Root (lexical) E walk full sem reparse.
  # Modo standalone (Root vazio): walk full sem reparse (override deliberado
  # fora do perfil, com pin bounded a jusante). Sem dot-source antes.
  if ([string]::IsNullOrWhiteSpace($Path)) { return @{ Ok = $false; Detail = 'caminho vazio (ancestry nao verificavel).' } }
  $pNorm = ''
  try { $pNorm = ([IO.Path]::GetFullPath($Path)).TrimEnd('\') } catch { return @{ Ok = $false; Detail = ('caminho nao normalizavel: ' + $Path) } }
  $rNorm = ''
  if (-not [string]::IsNullOrWhiteSpace($Root)) {
    try { $rNorm = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') } catch { return @{ Ok = $false; Detail = ('raiz nao normalizavel: ' + $Root) } }
    $isUnder = $pNorm.StartsWith($rNorm + '\', [StringComparison]::OrdinalIgnoreCase)
    $isRoot = $pNorm.Equals($rNorm, [StringComparison]::OrdinalIgnoreCase)
    if ((-not $isUnder) -and (-not $isRoot)) { return @{ Ok = $false; Detail = ('fora da raiz esperada: ' + $Path) } }
  }
  $cursor = $pNorm
  while (-not [string]::IsNullOrWhiteSpace($cursor)) {
    if (Test-Path -LiteralPath $cursor) {
      try {
        $attrs = (Get-Item -Force -LiteralPath $cursor -ErrorAction Stop).Attributes
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return @{ Ok = $false; Detail = ('atravessa reparse point: ' + $cursor) } }
      }
      catch { return @{ Ok = $false; Detail = ('inspeacao de ancestral falhando: ' + $cursor) } }
    }
    $parent = $cursor
    try { $parent = (Split-Path -Parent $cursor) } catch { break }
    if ([string]::IsNullOrWhiteSpace($parent) -or ($parent -eq $cursor)) { break }
    $cursor = $parent.TrimEnd('\')
  }
  return @{ Ok = $true; Detail = 'ancestry sem reparse' }
}

function Get-WrapperMajor([string]$Text) {
  $m = [regex]::Match([string]$Text, '(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return 0 }
  return [int]$m.Groups[1].Value
}

function Test-WrapperExact2018([string]$Text) {
  try { return [regex]::IsMatch([string]$Text, '(?m)^opencode v2\.0\.18\s*$') } catch { return $false }
}

$homeDirW = Join-Path $ProfileDirW 'home'
$configRootW = ''
$provisionedW = ''
# RR-P22-WRAPPER-FIX1 ancestry full ANTES de READ/dot-source/execute, com
# guard standalone local (sem carregar codigo antes dos checks). V2 exige:
# ProfileDir sob ProfileRoot sem reparse; manifest existente, sem reparse,
# legivel, geracao 2, com config_root MANDATORIO (fail-closed inclusive para
# diagnosticos); lib com ancestry limpa antes do dot-source. Paths
# desconhecidos => negado (exit 2/6 honesto, sem default).
if ($WantedGeneration -eq 2) {
  $pdAncW = Test-WrapperAncestryClean -Path $ProfileDirW -Root $ProfileRootW
  if (-not [bool]$pdAncW.Ok) {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: ProfileDir com ancestry invalida (' + [string]$pdAncW.Detail + '); fail-closed.') -ForegroundColor Red
    exit 2
  }
  if (-not (Test-Path -LiteralPath $ProfileDirW -PathType Container)) {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: ProfileDir inexistente; fail-closed.') -ForegroundColor Red
    exit 2
  }
  $mfAncW = Test-WrapperAncestryClean -Path $ProfileManifestW -Root $ProfileDirW
  if (-not [bool]$mfAncW.Ok) {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: manifest com ancestry invalida (' + [string]$mfAncW.Detail + '); fail-closed.') -ForegroundColor Red
    exit 2
  }
  if (-not (Test-Path -LiteralPath $ProfileManifestW -PathType Leaf)) {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: manifest ausente; fail-closed.') -ForegroundColor Red
    exit 2
  }
  try {
    $mfAttrsW = (Get-Item -Force -LiteralPath $ProfileManifestW -ErrorAction Stop).Attributes
    if (($mfAttrsW -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: manifest e reparse point; fail-closed.') -ForegroundColor Red
      exit 2
    }
  }
  catch {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: manifest nao inspecionavel; fail-closed.') -ForegroundColor Red
    exit 2
  }
  try {
    $pmW = ([IO.File]::ReadAllText($ProfileManifestW, [Text.Encoding]::UTF8)) | ConvertFrom-Json
  }
  catch {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: manifest ilegivel; fail-closed.') -ForegroundColor Red
    exit 2
  }
  if (($null -eq $pmW) -or ([string]$pmW.runtime_id -ne '{RUNTIME_ID}') -or ([int]$pmW.generation -ne $WantedGeneration)) {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: manifest nao e {RUNTIME_ID}/geracao ' + $WantedGeneration + '; fail-closed.') -ForegroundColor Red
    exit 2
  }
  if ([string]::IsNullOrWhiteSpace([string]$pmW.config_root)) {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: manifest sem config_root mandatorio (env nao confinado; recusado inclusive para diagnosticos).') -ForegroundColor Red
    exit 2
  }
  $configRootW = [string]$pmW.config_root
  $cfgAncW = Test-WrapperAncestryClean -Path $configRootW -Root $ProfileDirW
  if (-not [bool]$cfgAncW.Ok) {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: config_root com ancestry invalida (' + [string]$cfgAncW.Detail + '); fail-closed.') -ForegroundColor Red
    exit 2
  }
  if (($null -ne $pmW.provisioned) -and (-not [string]::IsNullOrWhiteSpace([string]$pmW.provisioned.binary_path))) {
    $provisionedW = [string]$pmW.provisioned.binary_path
  }
} else {
  $configRootW = Join-Path (Join-Path $ProfileDirW 'home') '.config'
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
}
$stateRootW = Join-Path $ProfileDirW 'home\.local\state'
$dataRootW = Join-Path $ProfileDirW 'home\.local\share'
$cacheRootW = Join-Path $ProfileDirW 'home\.local\cache'
# RR-P22-WRAPPER-FIX1: lib com ancestry limpa ANTES do dot-source no V2
# (marker/library com reparse na leitura => rejeitado). Sem inline duplicado.
$libLoadedW = $false
if ($WantedGeneration -eq 2) {
  $libAncW = Test-WrapperAncestryClean -Path $PreflightLibW -Root $ProfileDirW
  if (-not [bool]$libAncW.Ok) {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: lib preflight com ancestry invalida (' + [string]$libAncW.Detail + '); fail-closed.') -ForegroundColor Red
    exit 2
  }
  if (-not (Test-Path -LiteralPath $PreflightLibW -PathType Leaf)) {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: lib preflight ausente (' + $PreflightLibW + '); fail-closed.') -ForegroundColor Red
    exit 2
  }
  try {
    $libAttrsW = (Get-Item -Force -LiteralPath $PreflightLibW -ErrorAction Stop).Attributes
    if (($libAttrsW -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: lib preflight e reparse point; fail-closed.') -ForegroundColor Red
      exit 2
    }
  }
  catch {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: lib preflight nao inspecionavel; fail-closed.') -ForegroundColor Red
    exit 2
  }
  try {
    . $PreflightLibW
    if (-not (Get-Command Invoke-PreflightPort -ErrorAction SilentlyContinue)) { throw 'lib sem Invoke-PreflightPort' }
    if (-not (Get-Command Ensure-PreflightConfiguredPort -ErrorAction SilentlyContinue)) { throw 'lib sem Ensure-PreflightConfiguredPort' }
    if (-not (Get-Command Invoke-PreflightBoundedExe -ErrorAction SilentlyContinue)) { throw 'lib sem Invoke-PreflightBoundedExe' }
    if (-not (Get-Command Resolve-PreflightNativeExe -ErrorAction SilentlyContinue)) { throw 'lib sem Resolve-PreflightNativeExe' }
    $libLoadedW = $true
  }
  catch {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: lib preflight nao carregou; fail-closed.') -ForegroundColor Red
    exit 2
  }
  # RR-P22-WRAPPER-FIX1 vinculo semantico ANTES de qualquer execucao
  # (inclusive pin --version): mutadores e opts de destino recusados aqui;
  # unknown (inclui TUI vazio nesta phase) bloqueado com reason honesta.
  $blockReasonW = Test-WrapperBlockedReason -Argv $RemainingArgs
  if (-not [string]::IsNullOrWhiteSpace($blockReasonW)) {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: ' + $blockReasonW) -ForegroundColor Red
    exit 2
  }
  $isDiagW = Test-WrapperDiagAllowed -Argv $RemainingArgs
  $isStartW = Test-WrapperStartupAllowed -Argv $RemainingArgs
  if ((-not $isDiagW) -and (-not $isStartW)) {
    $tokW = [string]($RemainingArgs -join ' ')
    if ([string]::IsNullOrWhiteSpace($tokW)) { $tokW = '(sem argumentos: sessao interativa TUI)' }
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: comando desconhecido/nao suportado nesta phase (' + $tokW + '). Permitidos: diagnosticos exatos (--version, --help, service status, service get, service get port) e startup exato (service start, serve --service) com -ServicePort + gate central.') -ForegroundColor Red
    exit 2
  }
  # RR-P22-WRAPPER-FIX2: effEnv FULL validado em TODO diagnostico/start
  # ANTES do resolver e do processo final (diag nao pula validacao).
  # Paths obrigatorios + anti-reparse via Test-PreflightConfinedEnv.
  try {
    $preBaseW = @{ XDG_CONFIG_HOME = $configRootW }
    $preEffW = Get-PreflightEffectiveEnv -EnvTable $preBaseW -ProfileDir $ProfileDirW
    $preCheckW = Test-PreflightConfinedEnv -EnvTable $preEffW -ProfileDir $ProfileDirW -ConfigRoot $configRootW
    if (($null -eq $preCheckW) -or (-not [bool]$preCheckW.Ok)) {
      $preDW = ''
      try { $preDW = [string]$preCheckW.Detail } catch { $preDW = 'env nao confinado' }
      Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: env efetivo nao confinado antes do resolver (' + $preDW + '); fail-closed.') -ForegroundColor Red
      exit 2
    }
  }
  catch {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: validacao do env efetivo falhou (fail-closed).') -ForegroundColor Red
    exit 2
  }
}
# RR-P22-WRAPPER-FIX1: RESOLVE do .exe V2 ANTES do pin/selecao inicial, via
# resolver central (manifest npm .cmd shim => .exe sob o pacote; sem PATH;
# sem shell/cmd). Mesmo binario/env usados no gate e na execucao final.
# Override explicito fora do perfil: permitido quando deliberado, mas com
# ancestry full sem reparse (standalone) + pin exato bounded.
$candsW = New-Object System.Collections.ArrayList
if (-not [string]::IsNullOrWhiteSpace($BinaryPath)) { [void]$candsW.Add($BinaryPath) }
if ((-not [string]::IsNullOrWhiteSpace($provisionedW)) -and ($candsW -notcontains $provisionedW)) { [void]$candsW.Add($provisionedW) }
if ($WantedGeneration -ne 2) {
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
}
$chosenW = ''
if ($WantedGeneration -eq 2) {
  if ((-not [string]::IsNullOrWhiteSpace($BinaryPath)) -and (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf))) {
    Write-Host ('[wrapper ' + $ProfileTag + '] caminho desconhecido negado (-BinaryPath inexistente): ' + $BinaryPath) -ForegroundColor Red
    exit 6
  }
  $selBaseW = @{ XDG_CONFIG_HOME = $configRootW }
  $rvW = $null
  try {
    $rvW = Resolve-PreflightNativeExe -ProfileDir $ProfileDirW -Candidates @($candsW) -ExpectedVersion '2.0.18' -EnvTable $selBaseW -TimeoutMs 15000
  }
  catch {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: resolve do binario exato falhou (fail-closed).') -ForegroundColor Red
    exit 2
  }
  if (($null -eq $rvW) -or (-not [bool]$rvW.Ok) -or [string]::IsNullOrWhiteSpace([string]$rvW.Exe)) {
    $rdW = ''
    try { $rdW = [string]$rvW.Detail } catch { $rdW = '' }
    Write-Host ('[wrapper ' + $ProfileTag + '] nenhum binario exato 2.0.18 sob o pacote (sem PATH; shim .cmd resolve para .exe central): ' + $rdW) -ForegroundColor Red
    Write-Host 'Provisione o binario do perfil (rede, opt-in):' -ForegroundColor Red
    Write-Host ('  powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId {RUNTIME_ID} -ProvisionRuntime') -ForegroundColor Red
    exit 6
  }
  $chosenW = [string]$rvW.Exe
  $exeAncW = Test-WrapperAncestryClean -Path $chosenW -Root ''
  if (-not [bool]$exeAncW.Ok) {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: binario com ancestry invalida (' + [string]$exeAncW.Detail + '); fail-closed.') -ForegroundColor Red
    exit 2
  }
  try {
    $exeAttrsW = (Get-Item -Force -LiteralPath $chosenW -ErrorAction Stop).Attributes
    if (($exeAttrsW -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: binario e reparse point; fail-closed.') -ForegroundColor Red
      exit 2
    }
  }
  catch {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: binario nao inspecionavel; fail-closed.') -ForegroundColor Red
    exit 2
  }
  if (-not $chosenW.ToLowerInvariant().EndsWith('.exe')) {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: binario deve ser .exe (sem shell/cmd); fail-closed.') -ForegroundColor Red
    exit 2
  }
}
else {
  foreach ($candW in $candsW) {
    if (-not (Test-Path -LiteralPath $candW -PathType Leaf)) { continue }
    try {
      $voW = (& $candW --version 2>&1 | Out-String)
    }
    catch { continue }
    if ((Get-WrapperMajor $voW) -eq $WantedGeneration) { $chosenW = $candW; break }
  }
}
if ([string]::IsNullOrWhiteSpace($chosenW)) {
  Write-Host ('[wrapper ' + $ProfileTag + '] nenhum binario geracao ' + $WantedGeneration + ' encontrado.') -ForegroundColor Red
  Write-Host 'Provisione o binario do perfil (rede, opt-in):' -ForegroundColor Red
  Write-Host ('  powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId {RUNTIME_ID} -ProvisionRuntime') -ForegroundColor Red
  exit 6
}
# RR-P22-WRAPPER-FIX1: gate central via lib (sem inline duplicado).
# Marker service-port.json com schema pending exato (via lib); sem marker
# valido => Ensure retorna HOLD PORT_CONFIGURATION_UNVERIFIED (nunca muda
# 49374). Diagnostico exato passa sem gate mas com o MESMO env final e MESMO
# binario resolvido. Startup exato (service start | serve --service) exige
# Ensure-PreflightConfiguredPort. Marker pending sozinho nunca autoriza.
# Execucao final (diagnostico/startup permitido) via runner bounded 15s com
# output cap; timeout/falha/truncado => BLOCKER exit 2 (sem estado settled).
# Sessao interativa TUI nao e suportada nesta phase (unknown bloqueado acima
# com reason honesta); logo nenhum lifetime interativo e limitado aqui.
$gateW = $null
if ($WantedGeneration -eq 2) {
  if ($isStartW) {
    try {
      $gateW = Ensure-PreflightConfiguredPort -ProfileDir $ProfileDirW -ExplicitPort $ServicePort -ChosenBinary $chosenW -TimeoutMs 15000
    }
    catch {
      Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado (blocker; fail-closed).') -ForegroundColor Red
      exit 2
    }
    if (($null -eq $gateW) -or (-not [bool]$gateW.Permitted)) {
      $msgW = 'startup bloqueado.'
      $holdW = 'BLOCKED'
      try { if ($null -ne $gateW) { $msgW = [string]$gateW.Detail } } catch { }
      try { if (($null -ne $gateW) -and (-not [string]::IsNullOrWhiteSpace([string]$gateW.Hold))) { $holdW = [string]$gateW.Hold } } catch { }
      Write-Host ('[wrapper ' + $ProfileTag + '] ' + $msgW + ' (HOLD ' + $holdW + '; sem tocar 49374).') -ForegroundColor Red
      Write-Host ('Diagnostico: powershell -NoProfile -File scripts\runtime\RuntimePortPreflight.ps1 -ProfileDir "' + $ProfileDirW + '"') -ForegroundColor Red
      exit 2
    }
    try {
      $gateExeW = [string]$gateW.Exe
      if (-not [string]::IsNullOrWhiteSpace($gateExeW)) {
        $aW = ([IO.Path]::GetFullPath($gateExeW)).TrimEnd('\')
        $bW = ([IO.Path]::GetFullPath($chosenW)).TrimEnd('\')
        if (-not $aW.Equals($bW, [StringComparison]::OrdinalIgnoreCase)) {
          Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: binario do gate diverge do resolvido (mesmo binario exigido); fail-closed.') -ForegroundColor Red
          exit 2
        }
        $chosenW = $gateExeW
      }
    } catch { }
  }
}
# RR-P22-WRAPPER-FIX1: execucao final V2 via bounded runner (sem shell/cmd).
# V1 preserva o legado abaixo (somente CONFIG isolado, passthrough).
if ($WantedGeneration -eq 2) {
  if ([string]::IsNullOrWhiteSpace($chosenW)) {
    Write-Host ('[wrapper ' + $ProfileTag + '] nenhum binario geracao ' + $WantedGeneration + ' encontrado.') -ForegroundColor Red
    exit 6
  }
  $finEnvW = @{
    XDG_CONFIG_HOME = $configRootW
    XDG_STATE_HOME = $stateRootW
    XDG_DATA_HOME = $dataRootW
    XDG_CACHE_HOME = $cacheRootW
    HOME = $homeDirW
    USERPROFILE = $homeDirW
  }
  if (($null -ne $gateW) -and ($null -ne $gateW.Env)) {
    try {
      foreach ($ekW in @('XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'HOME', 'USERPROFILE')) {
        $evW = [string]$gateW.Env[$ekW]
        if (-not [string]::IsNullOrWhiteSpace($evW)) { $finEnvW[$ekW] = $evW }
      }
    } catch { }
  }
  # RR-P22-WRAPPER-FIX2: revalida env FINAL antes do processo final
  # (diagnostico e startup; mesmo env do gate quando houver).
  try {
    $finCheckW = Test-PreflightConfinedEnv -EnvTable $finEnvW -ProfileDir $ProfileDirW -ConfigRoot $configRootW
    if (($null -eq $finCheckW) -or (-not [bool]$finCheckW.Ok)) {
      $finDW = ''
      try { $finDW = [string]$finCheckW.Detail } catch { $finDW = 'env final nao confinado' }
      Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: env final nao confinado antes da execucao (' + $finDW + '); fail-closed.') -ForegroundColor Red
      exit 2
    }
  }
  catch {
    Write-Host ('[wrapper ' + $ProfileTag + '] startup bloqueado: validacao do env final falhou (fail-closed).') -ForegroundColor Red
    exit 2
  }
  $argLineW = [string]($RemainingArgs -join ' ')
  $finW = $null
  try {
    $finW = Invoke-PreflightBoundedExe -File $chosenW -ArgsLine $argLineW -WorkDir ([IO.Path]::GetTempPath()) -EnvTable $finEnvW -EnvRemove @('OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_HOME', 'OPENCODE_CONFIG_PATH') -TimeoutMs 15000
  }
  catch {
    Write-Host ('[wrapper ' + $ProfileTag + '] BLOCKER: execucao bounded falhou sem settle (fail-closed).') -ForegroundColor Red
    exit 2
  }
  if (($null -eq $finW) -or [bool]$finW.TimedOut -or (-not [bool]$finW.Finished)) {
    Write-Host ('[wrapper ' + $ProfileTag + '] BLOCKER: comando nao settled em 15s (filho direto encerrado; descendants sem prova; sem claim). Output parcial capado acima quando houver.') -ForegroundColor Red
    try { if (($null -ne $finW) -and (-not [string]::IsNullOrWhiteSpace([string]$finW.Output))) { Write-Host ([string]$finW.Output) } } catch { }
    exit 2
  }
  if ([bool]$finW.Truncated) {
    Write-Host ('[wrapper ' + $ProfileTag + '] BLOCKER: leitura truncada/incompleta (sem claim; fail-closed).') -ForegroundColor Red
    exit 2
  }
  try { if (-not [string]::IsNullOrWhiteSpace([string]$finW.Output)) { Write-Host ([string]$finW.Output) } } catch { }
  if ([int]$finW.ExitCode -ne 0) {
    Write-Host ('[wrapper ' + $ProfileTag + '] BLOCKER: exit ' + [int]$finW.ExitCode + ' (sem estado settled alem do reportado; fail-closed).') -ForegroundColor Red
    exit 2
  }
  exit 0
}
# RR-P22-WRAPPER-FIX1: caminho legado V1 INTACTO (somente CONFIG isolado,
# passthrough OPENCODE_CONFIG*). V2 nunca chega aqui (saiu via bounded
# runner acima); este bloco e exclusivo da geracao 1.
if ([string]::IsNullOrWhiteSpace($chosenW)) {
  Write-Host ('[wrapper ' + $ProfileTag + '] nenhum binario geracao ' + $WantedGeneration + ' encontrado.') -ForegroundColor Red
  exit 6
}
$oldXdgW = $env:XDG_CONFIG_HOME
$oldStateW = $env:XDG_STATE_HOME
$oldDataW = $env:XDG_DATA_HOME
$oldCacheW = $env:XDG_CACHE_HOME
$oldHomeW = $env:HOME
$oldProfileW = $env:USERPROFILE
$oldCfgValsW = @{}
try {
  foreach ($kkW in @([Environment]::GetEnvironmentVariables().Keys)) {
    if ([string]$kkW -like 'OPENCODE_CONFIG*') {
      try { $oldCfgValsW[[string]$kkW] = [string]([Environment]::GetEnvironmentVariable([string]$kkW)) } catch { }
    }
  }
}
catch { }
try {
  $env:XDG_CONFIG_HOME = $configRootW
  # RR-P22-FIX2 (8) + FIX3 (C): V1 restaura o original (somente CONFIG isolado);
  # mudancas de STATE/DATA/CACHE/HOME sao exclusivas do V2. OPENCODE_CONFIG*
  # removido do filho SOMENTE geracao 2; geracao 1 recebe o valor (passthrough).
  if ($WantedGeneration -eq 2) {
    if (($null -ne $gateW) -and ($null -ne $gateW.Env)) {
      try {
        $env:XDG_STATE_HOME = [string]$gateW.Env['XDG_STATE_HOME']
        $env:XDG_DATA_HOME = [string]$gateW.Env['XDG_DATA_HOME']
        $env:XDG_CACHE_HOME = [string]$gateW.Env['XDG_CACHE_HOME']
        $env:HOME = [string]$gateW.Env['HOME']
        $env:USERPROFILE = [string]$gateW.Env['USERPROFILE']
      }
      catch {
        $env:XDG_STATE_HOME = $stateRootW
        $env:XDG_DATA_HOME = $dataRootW
        $env:XDG_CACHE_HOME = $cacheRootW
        $env:HOME = $homeDirW
        $env:USERPROFILE = $homeDirW
      }
    }
    else {
      $env:XDG_STATE_HOME = $stateRootW
      $env:XDG_DATA_HOME = $dataRootW
      $env:XDG_CACHE_HOME = $cacheRootW
      $env:HOME = $homeDirW
      $env:USERPROFILE = $homeDirW
    }
  }
  if ($WantedGeneration -eq 2) {
    foreach ($kkW in @($oldCfgValsW.Keys)) {
      try { Remove-Item -Path ('Env:\' + [string]$kkW) -ErrorAction SilentlyContinue } catch { }
    }
  }
  & $chosenW @RemainingArgs
  $codeW = $LASTEXITCODE
}
finally {
  if ($null -eq $oldXdgW) { Remove-Item Env:\XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
  else { $env:XDG_CONFIG_HOME = $oldXdgW }
  if ($null -eq $oldStateW) { Remove-Item Env:\XDG_STATE_HOME -ErrorAction SilentlyContinue }
  else { $env:XDG_STATE_HOME = $oldStateW }
  if ($null -eq $oldDataW) { Remove-Item Env:\XDG_DATA_HOME -ErrorAction SilentlyContinue }
  else { $env:XDG_DATA_HOME = $oldDataW }
  if ($null -eq $oldCacheW) { Remove-Item Env:\XDG_CACHE_HOME -ErrorAction SilentlyContinue }
  else { $env:XDG_CACHE_HOME = $oldCacheW }
  if ($WantedGeneration -eq 2) {
    if ($null -eq $oldHomeW) { Remove-Item Env:\HOME -ErrorAction SilentlyContinue }
    else { $env:HOME = $oldHomeW }
    if ($null -eq $oldProfileW) { Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue }
    else { $env:USERPROFILE = $oldProfileW }
  }
  foreach ($kkW in @($oldCfgValsW.Keys)) {
    try {
      $vvW = $oldCfgValsW[[string]$kkW]
      if ($null -eq $vvW) { Remove-Item -Path ('Env:\' + [string]$kkW) -ErrorAction SilentlyContinue }
      else { Set-Item -Path ('Env:\' + [string]$kkW) -Value $vvW }
    }
    catch { }
  }
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
    [string]$RepoRoot = '',
    $ServicePortNode = $null,
    [string]$PreflightLibPath = ''
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
    service_port = $ServicePortNode
    preflight_lib = $PreflightLibPath
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
    [string]$BinaryOverride = '',
    [int]$ServicePort = 0
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
  if ($ServicePort -ne 0) {
    if (($ServicePort -lt 1) -or ($ServicePort -gt 65535)) {
      throw ('P7-PROFILE-FAIL: ServicePort invalida (esperado 1..65535): ' + $ServicePort)
    }
    if ($profile -ne 'v2') {
      throw 'P7-PROFILE-FAIL: ServicePort so e suportada no perfil v2 (RuntimeId opencode-v2).'
    }
  }
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
      # P7-PROVISION-NETWORK para exit 7. Phase22: preserva service-port
      # pedida no manifest parcial (persistencia por perfil).
      $partialSvcNode = $null
      if (($profile -eq 'v2') -and ($ServicePort -ne 0)) {
        try {
          Assert-P7PreflightLoaded
          $psv = Set-PreflightPersistedPort -ProfileDir $profileDir -Port $ServicePort -Source 'new-profile' -State 'pending'
          $partialSvcNode = [ordered]@{ port = [int]$psv.Port; state = 'pending'; path = [string]$psv.Path }
        }
        catch { }
      }
      $partialLib = ''
      try { $partialLib = Write-P7PreflightLibCopy -RepoRoot $RepoRoot -ProfileDir $profileDir } catch { $partialLib = '' }
      $partialWrapper = Write-P7Wrapper -ProfileRoot $ProfileRoot -Profile $profile -RuntimeId $RuntimeId -Generation $gen
      $partial = New-P7ProfileManifestObject -Profile $profile -RuntimeId $RuntimeId -Generation $gen -HomeDir $homeDir -ConfigRoot $configRoot -RuntimeDir $runtimeDir -InstallManifest $installManifest -WrapperPath $partialWrapper -ProvisionedNode $null -RepoRoot $RepoRoot -ServicePortNode $partialSvcNode -PreflightLibPath $partialLib
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
  # RR-P22-FIX2: -ServicePort grava SOMENTE pending (desired); nunca claim de
  # applied/efeito nativo. Sem -ServicePort, preserva marker valido com schema
  # exato; marker antigo sem state nao e carregado (startup bloqueia com
  # PORT_CONFIGURATION_UNVERIFIED, nunca muda 49374).
  $servicePortNode = $null
  if ($profile -eq 'v2') {
    $svcPersisted = 0
    if ($ServicePort -ne 0) { $svcPersisted = $ServicePort }
    $svcFile = Join-Path $profileDir 'service-port.json'
    if ($svcPersisted -ne 0) {
      Assert-P7PreflightLoaded
      try {
        $saved = Set-PreflightPersistedPort -ProfileDir $profileDir -Port $svcPersisted -Source 'new-profile' -State 'pending'
        $servicePortNode = [ordered]@{ port = [int]$saved.Port; state = 'pending'; path = [string]$saved.Path }
      }
      catch {
        if ($_.Exception.Message -match '^PREFLIGHT-FAIL') { throw ('P7-PROFILE-FAIL: ' + $_.Exception.Message) }
        throw
      }
      if ($svcPersisted -eq 49374) {
        Write-Host '[profile v2] AVISO: porta 49374 e o default com colisao conhecida (AI Memory local/V2); o preflight recusara start enquanto ocupada.' -ForegroundColor Yellow
      }
      Write-Host ('[profile v2] service port desired (pending) por perfil: ' + $svcPersisted) -ForegroundColor DarkGray
    }
    else {
      try {
        if (Test-Path -LiteralPath $svcFile -PathType Leaf) {
          Assert-P7PreflightLoaded
          $sj = (([IO.File]::ReadAllText($svcFile, [Text.Encoding]::UTF8)) | ConvertFrom-Json)
          $sch = Test-PreflightServicePortSchema -Json $sj
          if ([bool]$sch.Ok) {
            $servicePortNode = [ordered]@{ port = [int]$sch.Port; state = 'pending'; path = $svcFile }
          }
        }
      }
      catch { }
    }
  }
  # Ordem: LIB + WRAPPER antes do MANIFEST; o manifest e o ultimo artefato
  # (marcador de sucesso), escrito de forma atomica. Lib ausente => perfil
  # recusado (wrapper bloquearia startup sem gate).
  $preflightLibCopy = Write-P7PreflightLibCopy -RepoRoot $RepoRoot -ProfileDir $profileDir
  $wrapperPath = Write-P7Wrapper -ProfileRoot $ProfileRoot -Profile $profile -RuntimeId $RuntimeId -Generation $gen
  $provNode = $null
  if ($provisioned) {
    $provNode = [ordered]@{ binary_path = $binaryPath; version = $versionLine; provenance = $provenance }
  }
  $manifest = New-P7ProfileManifestObject -Profile $profile -RuntimeId $RuntimeId -Generation $gen -HomeDir $homeDir -ConfigRoot $configRoot -RuntimeDir $runtimeDir -InstallManifest $installManifest -WrapperPath $wrapperPath -ProvisionedNode $provNode -RepoRoot $RepoRoot -ServicePortNode $servicePortNode -PreflightLibPath $preflightLibCopy
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
