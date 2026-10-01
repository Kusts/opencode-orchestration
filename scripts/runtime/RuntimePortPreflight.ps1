<#!
.SYNOPSIS
    CLI do preflight de porta do servico V2 (Phase 22): read-only, nunca mata PID.
.DESCRIPTION
    PS 5.1 e PS7 compativel. ASCII only. Exit codes: 0 = PORT_FREE (start
    autorizado); 2 = qualquer outro outcome (fail-closed); 1 = erro de uso/
    execucao. REUSE HOLD (RR-P22-FIX2): PORT_OWNED_BY_EXPECTED_SERVICE consta
    no enum mas nao e emitido em producao (expected => STALE, sem reuse) ate
    prova de instancia exata. Emite texto humano + JSON opcional (--Json) e
    evidencia opcional (--EvidencePath). Nunca mata PID; nunca escreve config
    global. --PersistProfileDir / -SelectFree persistem SOMENTE pending
    (desired) no perfil indicado (service-port.json com schema exato).
#>
param(
  [int]$Port = 0,
  [string]$ProfileDir = '',
  [string]$BinaryPath = '',
  [string[]]$ExpectedProcessNames = @('opencode'),
  [switch]$Json,
  [string]$EvidencePath = '',
  [string]$PersistProfileDir = '',
  [switch]$SelectFree,
  [string]$CandidatePorts = '',
  [switch]$ProbeServiceStatus
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($here)) { $here = (Get-Location).Path }
$lib = Join-Path $here 'lib\RuntimePortPreflight.ps1'
. $lib

function Write-PreflightJsonAtomic($Object, [string]$TargetPath) {
  $parent = Split-Path -Parent $TargetPath
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $tmp = $TargetPath + '.tmp-' + [guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($tmp, ((($Object | ConvertTo-Json -Depth 10).TrimEnd() + "`n") -replace "`r`n", "`n" -replace "`r", "`n"), (New-Object Text.UTF8Encoding $false))
  Move-Item -LiteralPath $tmp -Destination $TargetPath -Force
}

try {
  $targetPort = $Port
  if ($SelectFree) {
    $cands = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($CandidatePorts)) {
      foreach ($tok in @($CandidatePorts -split '[,;\s]+')) {
        if ([string]::IsNullOrWhiteSpace($tok)) { continue }
        $n = 0
        try { $n = [int]$tok } catch { continue }
        [void]$cands.Add($n)
      }
    }
    if ($cands.Count -eq 0) {
      for ($i = 0; $i -lt 5; $i++) { [void]$cands.Add((Get-PreflightEphemeralPort)) }
    }
    $ex = Get-PreflightExcludedRanges
    if (-not [bool]$ex.Available) {
      Write-Host '[preflight] SELECT_FREE: faixas excluidas indisponiveis (fail-closed).'
      exit 2
    }
    $picked = Select-PreflightServicePort -CandidatePorts @($cands) -ExcludedRanges @($ex.Ranges)
    if ($picked -eq 0) {
      Write-Host '[preflight] SELECT_FREE: nenhuma porta livre verificada nos candidatos.'
      exit 2
    }
    $targetPort = $picked
    Write-Host ('[preflight] SELECT_FREE: porta livre verificada (pending; aplicada somente via service set + prova): ' + $targetPort)
    if (-not [string]::IsNullOrWhiteSpace($PersistProfileDir)) {
      $sv = Set-PreflightPersistedPort -ProfileDir $PersistProfileDir -Port $targetPort -Source 'select-free' -State 'pending'
      Write-Host ('[preflight] desired (pending) por perfil: ' + [string]$sv.Path)
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
      Write-PreflightJsonAtomic ([ordered]@{ tool = 'RuntimePortPreflight'; mode = 'select-free'; port = $targetPort; date = ((Get-Date).ToString('o')) }) $EvidencePath
    }
    exit 0
  }
  if ($targetPort -eq 0 -and (-not [string]::IsNullOrWhiteSpace($ProfileDir))) {
    $pp = Get-PreflightPersistedPort -ProfileDir $ProfileDir
    if ($null -ne $pp) { $targetPort = [int]$pp.Port }
  }
  if ($targetPort -eq 0) {
    Write-Host 'Uso: RuntimePortPreflight.ps1 -Port <1..65535> [-ProfileDir <perfil>] [-ProbeServiceStatus -BinaryPath <bin> -ProfileDir <perfil>] [-SelectFree ...]'
    exit 1
  }
  $probe = $null
  $expPaths = @()
  $expProfile = ''
  if ($ProbeServiceStatus) {
    if ([string]::IsNullOrWhiteSpace($BinaryPath) -or [string]::IsNullOrWhiteSpace($ProfileDir)) {
      Write-Host '[preflight] -ProbeServiceStatus exige -BinaryPath e -ProfileDir (health ownership por perfil).'
      exit 1
    }
    if (-not $BinaryPath.ToLowerInvariant().EndsWith('.exe')) {
      Write-Host '[preflight] -BinaryPath deve ser .exe (sem shell).'
      exit 1
    }
    if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) {
      Write-Host ('[preflight] binario inexistente: ' + $BinaryPath)
      exit 1
    }
    $pm = $null
    try {
      $mf = Join-Path $ProfileDir 'manifest.json'
      if (Test-Path -LiteralPath $mf -PathType Leaf) {
        $pm = (([IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8)) | ConvertFrom-Json)
      }
    }
    catch { $pm = $null }
    $xdg = ''
    $provBin = ''
    try { if (($null -ne $pm) -and (-not [string]::IsNullOrWhiteSpace([string]$pm.config_root))) { $xdg = [string]$pm.config_root } } catch { $xdg = '' }
    try {
      if (($null -ne $pm) -and ($null -ne $pm.provisioned) -and (-not [string]::IsNullOrWhiteSpace([string]$pm.provisioned.binary_path))) {
        $provBin = [string]$pm.provisioned.binary_path
      }
    }
    catch { $provBin = '' }
    if (-not [string]::IsNullOrWhiteSpace($provBin)) {
      try {
        $a = ([IO.Path]::GetFullPath($provBin)).TrimEnd('\')
        $b = ([IO.Path]::GetFullPath($BinaryPath)).TrimEnd('\')
        if (-not $a.Equals($b, [StringComparison]::OrdinalIgnoreCase)) {
          Write-Host '[preflight] binario divergente do provisioned do manifest (recusado).'
          exit 1
        }
      }
      catch { }
      $expPaths = @($provBin)
    }
    else {
      $expPaths = @($BinaryPath)
    }
    $expProfile = $ProfileDir
    if ([string]::IsNullOrWhiteSpace($xdg)) {
      Write-Host '[preflight] manifest sem config_root (env nao confinado; recusado).'
      exit 1
    }
    $binCap = $BinaryPath
    $xdgCap = $xdg
    $profCap = $ProfileDir
    $probe = {
      param($ctx)
      $envT = @{ XDG_CONFIG_HOME = $xdgCap }
      try {
        $stHome = Join-Path $profCap 'home\.local\state'
        $dtHome = Join-Path $profCap 'home\.local\share'
        $envT['XDG_STATE_HOME'] = $stHome
        $envT['XDG_DATA_HOME'] = $dtHome
        $envT['XDG_CACHE_HOME'] = (Join-Path $profCap 'home\.local\cache')
        $envT['HOME'] = (Join-Path $profCap 'home')
        $envT['USERPROFILE'] = (Join-Path $profCap 'home')
      }
      catch { }
      $st = Invoke-PreflightBoundedExe -File $binCap -ArgsLine 'service status' -WorkDir ([IO.Path]::GetTempPath()) -EnvTable $envT -EnvRemove @('OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_HOME', 'OPENCODE_CONFIG_PATH') -TimeoutMs 30000
      if ([bool]$st.TimedOut -or (-not [bool]$st.Finished)) {
        return @{ Checked = $true; Healthy = $false; Detail = 'service status timeout (filho proprio encerrado; unhealthy)' }
      }
      if ([int]$st.ExitCode -ne 0) {
        $short = ''
        try { $short = (([string]$st.Output -split "`r?`n" | Select-Object -First 1)) } catch { $short = '' }
        return @{ Checked = $true; Healthy = $false; Detail = ('service status exit ' + [int]$st.ExitCode + ': ' + $short) }
      }
      if (Test-PreflightExactEndpoint -Detail ([string]$st.Output) -Port ([int]$ctx.Port)) {
        return @{ Checked = $true; Healthy = $true; Detail = ('service status confirma 127.0.0.1:' + $ctx.Port) }
      }
      return @{ Checked = $true; Healthy = $false; Detail = 'service status sem endpoint exato esperado (prefixo nao basta)' }
    }
  }
  else {
    if (-not [string]::IsNullOrWhiteSpace($ProfileDir)) {
      $expProfile = $ProfileDir
      try {
        $mf2 = Join-Path $ProfileDir 'manifest.json'
        if (Test-Path -LiteralPath $mf2 -PathType Leaf) {
          $pm2 = (([IO.File]::ReadAllText($mf2, [Text.Encoding]::UTF8)) | ConvertFrom-Json)
          if (($null -ne $pm2) -and ($null -ne $pm2.provisioned) -and (-not [string]::IsNullOrWhiteSpace([string]$pm2.provisioned.binary_path))) {
            $expPaths = @([string]$pm2.provisioned.binary_path)
          }
        }
      }
      catch { }
    }
  }
  $r = Invoke-PreflightPort -Port $targetPort -ExpectedProcessNames $ExpectedProcessNames -ExpectedProcessPaths $expPaths -ExpectedProfileDir $expProfile -HealthProbe $probe
  $line = ('[preflight] porta ' + $targetPort + ' => ' + [string]$r.Outcome + ' (start=' + [string]$r.ShouldStart + ' reuse=' + [string]$r.ShouldReuse + ')')
  Write-Host $line
  foreach ($d in @($r.Diagnostics)) { Write-Host ('  - ' + [string]$d) }
  if (-not [string]::IsNullOrWhiteSpace([string]$r.CollisionHint)) { Write-Host ('  ! ' + [string]$r.CollisionHint) }
  if ($Json -or (-not [string]::IsNullOrWhiteSpace($EvidencePath))) {
    $obj = [ordered]@{
      tool = 'RuntimePortPreflight'
      date = ((Get-Date).ToString('o'))
      port = $targetPort
      outcome = [string]$r.Outcome
      should_start = [bool]$r.ShouldStart
      should_reuse = [bool]$r.ShouldReuse
      listener = $r.Listener
      process = $r.Process
      excluded = $r.Excluded
      health = $r.Health
      diagnostics = @($r.Diagnostics)
      collision_hint = [string]$r.CollisionHint
    }
    if ($Json) { Write-Host (($obj | ConvertTo-Json -Depth 10)) }
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
      Write-PreflightJsonAtomic $obj $EvidencePath
      Write-Host ('[preflight] evidencia em ' + $EvidencePath)
    }
  }
  if ((([string]$r.Outcome -eq 'PORT_FREE') -or ([string]$r.Outcome -eq 'PORT_OWNED_BY_EXPECTED_SERVICE'))) { exit 0 }
  exit 2
}
catch {
  Write-Host ('[preflight] ERRO: ' + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
