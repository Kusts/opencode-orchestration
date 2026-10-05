<#!
.SYNOPSIS
    Spike de validacao de permissoes/politicas V2 contra o runtime real (Phase 5, V3.1).
.DESCRIPTION
    Harness honesto: registra SOMENTE fatos observados. Nunca alega enforcement
    sem teste contra o binario exato.

    Ordem de resolucao do binario V2:
      1. -BinaryPath explicito (validado no disco);
      2. manifest do perfil v2 (<ProfileRoot>\v2\manifest.json, campo
         provisioned.binary_path gravado por new-opencode-profile.ps1);
      3. probe no PATH (opencode --version com major 2).
    Sem binario: escreve evidencia {status:skipped, reason:v2_binary_unavailable}
    e sai 0.

    Com binario: gera fixture V2 (agents/permissions ordenadas + subagent deny
    + experimental.subagent_depth=1) num run-child temporario e roda o binario
    com isolamento total por processo (XDG_CONFIG/DATA/STATE/CACHE + HOME/
    USERPROFILE no run-child, OPENCODE_CONFIG* removido do filho, clean env
    com allowlist de runtime do SO em todas as sondas, cwd no run-child;
    stdin fechado). Versao exigida exata = pin do registry unico
    (source/registry/runtime-versions.json, runtimes.v2; linha
    'opencode v<pin>'; mismatch bloqueia servico/config).
    Subprocesso via scripts/runtime/lib/SpikeProcess.ps1
    (exit code verdadeiro, drenos limitados com deadline, timeout com
    diagnostico parcial, sem tocar o env do pai; shim .cmd resolvido para o
    .exe real quando possivel).

    Achado exato (binario pinado em 2.0.18, 2026-09-30; historico):
    `debug config`/`debug agents` exigem o
    background service (`serve --service`), que escuta na porta fixa
    127.0.0.1:49374; porta ocupada => o servico falha em loop e o CLI trava
    sem saida. O harness configura UMA porta livre por ambiente
    (`service set port <livre>` okay documentado pelo proprio erro do
    binario) e prova o servidor privado via `service status`. A primeira
    chamada `debug agents` apos subir o servico pode devolver `[]`
    (servico ainda inicializando): o harness aquece com `debug config` e
    tenta `debug agents` ate 3x com espera limitada. `service stop` + remocao
    do temp no finally (sem orfaos).

    Checks automatizados correspondem 1:1 a comandos realmente executados.
    Enforcement comportamental (levar um agente live a tentar operacao negada)
    NAO e automatizavel aqui: registrado como manual_checklist_pending.
    `ok` do load automatizado NAO e PASS comportamental.

    PS 5.1 e PS7 compativel. ASCII only. Nunca escreve fora de temp/evidencia;
    nunca toca a config global do usuario; nunca persiste env.
.PARAMETER BinaryPath
    Binario V2 explicito (opcional). Quando vazio, usa manifest do perfil e PATH.
.PARAMETER ProfileRoot
    Raiz dos perfis isolados. Default: $env:USERPROFILE\.opencode-orchestration\profiles.
.PARAMETER EvidencePath
    JSON de evidencia. Default: evidence/v3.1/kernel-hardening/v2-permissions-spike.json
    relativo a raiz do repo.
.PARAMETER SkipProvision
    Nao tenta provisionar o binario V2 via rede/npm: usa apenas binario ja
    disponivel (explicito/manifest/PATH) ou grava skipped. Sem este switch,
    quando nenhum binario V2 e resolvido o harness tenta UMA vez o
    provisionamento opt-in do repo (scripts/runtime/new-opencode-profile.ps1
    -RuntimeId opencode-v2 -ProvisionRuntime, baixa o pin do registry
    (source/registry/runtime-versions.json) para
    DENTRO do perfil, sem tocar o global); falha de rede/npm grava skipped
    com o motivo e sai 0 (nunca falha o harness por falta de rede).
.PARAMETER WhatIf
    Mostra o plano (resolucao + fixture + comandos) sem executar nada e sem escrever.
#>
param(
  [string]$BinaryPath = '',
  [string]$ProfileRoot = '',
  [string]$EvidencePath = '',
  [switch]$SkipProvision,
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot 'lib\SpikeProcess.ps1')
# Gate de versao exata: pin do registry unico (fail-closed; sem literal).
. (Join-Path $PSScriptRoot 'lib\RuntimeVersions.ps1')
$PinnedVersionV2 = [string](Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $RepoRoot).Version
$PinnedSpecV2 = [string](Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $RepoRoot).Spec
$pinSpecNote = ('baixa ' + $PinnedSpecV2 + ' no perfil')

if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
  $ProfileRoot = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles'
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
  $EvidencePath = Join-Path $RepoRoot 'evidence\v3.1\kernel-hardening\v2-permissions-spike.json'
}

function Get-SpikeTempBase {
  $b = $env:TEMP
  if ([string]::IsNullOrWhiteSpace($b)) { $b = $env:TMP }
  if ([string]::IsNullOrWhiteSpace($b)) { $b = [IO.Path]::GetTempPath() }
  return $b
}

function Write-SpikeJsonAtomic($Object, [string]$TargetPath) {
  $parent = Split-Path -Parent $TargetPath
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $tmp = $TargetPath + '.tmp-' + [guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($tmp, ((($Object | ConvertTo-Json -Depth 8).TrimEnd() + "`n") -replace "`r`n", "`n" -replace "`r", "`n"), (New-Object Text.UTF8Encoding $false))
  Move-Item -LiteralPath $tmp -Destination $TargetPath -Force
}

function Get-SpikeMajor([string]$Text) {
  $m = [regex]::Match([string]$Text, '(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return 0 }
  return [int]$m.Groups[1].Value
}

function Resolve-SpikeBinary([string]$Explicit, [string]$Root) {
  if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
    if (Test-Path -LiteralPath $Explicit -PathType Leaf) {
      return @{ Path = $Explicit; Source = 'explicit-BinaryPath' }
    }
    Write-Host ('[spike] -BinaryPath inexistente: ' + $Explicit)
  }
  $mf = Join-Path (Join-Path $Root 'v2') 'manifest.json'
  if (Test-Path -LiteralPath $mf -PathType Leaf) {
    try {
      $pm = ([IO.File]::ReadAllText($mf, [Text.Encoding]::UTF8)) | ConvertFrom-Json
      $cand = ''
      if (($null -ne $pm) -and ($null -ne $pm.provisioned)) { $cand = [string]$pm.provisioned.binary_path }
      if ((-not [string]::IsNullOrWhiteSpace($cand)) -and (Test-Path -LiteralPath $cand -PathType Leaf)) {
        return @{ Path = $cand; Source = 'profile-manifest-v2' }
      }
    }
    catch { Write-Host ('[spike] manifest v2 ilegivel: ' + $_.Exception.Message) }
  }
  try {
    $cands = @(Get-Command -Name 'opencode' -All -ErrorAction SilentlyContinue)
    foreach ($c in $cands) {
      $src = ''
      try { $src = [string]$c.Source } catch { $src = '' }
      if ([string]::IsNullOrWhiteSpace($src)) { continue }
      if (-not (Test-Path -LiteralPath $src)) { continue }
      $vr = Invoke-SpikeChild -FilePath $src -ArgumentList @('--version') -TimeoutMs 30000 -CleanEnvironment -StdinNul
      if (((-not [bool]$vr.TimedOut) -and ([int]$vr.ExitCode -eq 0)) -and ((Get-SpikeMajor ($vr.Stdout + "`n" + $vr.Stderr)) -eq 2)) {
        return @{ Path = $src; Source = 'PATH-probe-2x'; VersionProbe = ($vr.Stdout + "`n" + $vr.Stderr).Trim() }
      }
    }
  }
  catch { Write-Host ('[spike] PATH probe falhou: ' + $_.Exception.Message) }
  return $null
}

function New-SpikeFixture([string]$TempRoot) {
  $xdg = Join-Path $TempRoot 'xdg'
  $cfgDir = Join-Path $xdg 'opencode'
  $agentsDir = Join-Path $TempRoot 'agents'
  New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
  New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null
  $readerMd = Join-Path $agentsDir 'fixture-reader.md'
  $writerMd = Join-Path $agentsDir 'fixture-writer.md'
  [IO.File]::WriteAllText($readerMd, "# fixture-reader`n`nRead-only fixture: sem edit, sem shell, sem subagent.`n", (New-Object Text.UTF8Encoding $false))
  [IO.File]::WriteAllText($writerMd, "# fixture-writer`n`nWriter fixture: shell deny-all + allow estreito (last-match-wins), sem subagent.`n", (New-Object Text.UTF8Encoding $false))
  $cfg = [ordered]@{
    default_agent = 'build'
    agents = [ordered]@{
      build = [ordered]@{
        mode = 'primary'
        permissions = @(
          [ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' }
        )
      }
      'fixture-reader' = [ordered]@{
        mode = 'subagent'
        permissions = @(
          [ordered]@{ action = 'edit'; resource = '*'; effect = 'deny' }
          [ordered]@{ action = 'shell'; resource = '*'; effect = 'deny' }
          [ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' }
        )
      }
      'fixture-writer' = [ordered]@{
        mode = 'subagent'
        permissions = @(
          [ordered]@{ action = 'shell'; resource = '*'; effect = 'deny' }
          [ordered]@{ action = 'shell'; resource = 'git status *'; effect = 'allow' }
          [ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' }
        )
      }
    }
    experimental = [ordered]@{ subagent_depth = 1 }
  }
  $cfgPath = Join-Path $cfgDir 'opencode.json'
  Write-SpikeJsonAtomic $cfg $cfgPath
  return @{ XdgRoot = $xdg; ConfigPath = $cfgPath; ReaderMd = $readerMd; WriterMd = $writerMd }
}

if ($WhatIf) {
  Write-Host '=== SPIKE V2 PERMISSIONS (WhatIf, nenhuma execucao, nenhuma escrita) ==='
  Write-Host ('[RESOLVE] 1. -BinaryPath explicito | 2. manifest ' + (Join-Path (Join-Path $ProfileRoot 'v2') 'manifest.json') + ' | 3. PATH probe (opencode --version major 2)')
  if ($SkipProvision) { Write-Host '[PROVISION] SkipProvision: sem tentativa de rede/npm.' }
  else { Write-Host '[PROVISION] sem binario resolvido: tenta 1x scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v2 -ProvisionRuntime (opt-in, rede/npm; falha grava skipped).' }
  Write-Host '[FIXTURE] temp XDG+HOME root com opencode/opencode.json (V2: agents/permissions ordenadas, experimental.subagent_depth=1) + agents/*.md de registro'
  Write-Host ('[RUN] --version (exato ' + $PinnedVersionV2 + ', gate) | debug paths (isolamento) | service set port <livre> | debug config warmup (fontes) | service status (servidor privado) | debug agents ate 3x (load da fixture) | service stop com gates (owned)')
  Write-Host ('[EVIDENCE] ' + $EvidencePath)
  Write-Host '[MANUAL] behavioral_permission_enforcement fica manual_checklist_pending (5 passos)'
  exit 0
}

$resolved = Resolve-SpikeBinary $BinaryPath $ProfileRoot
if (($null -eq $resolved) -and (-not $SkipProvision)) {
  # Provisionamento opt-in (UNICA tentativa, so quando nenhum binario V2 foi
  # resolvido): mecanismo do repo, escreve SOMENTE sob o perfil, nunca toca
  # o binario global. Requer rede/npm; falha => skipped com motivo, exit 0.
  $provScript = Join-Path $RepoRoot 'scripts\runtime\new-opencode-profile.ps1'
  if (-not (Test-Path -LiteralPath $provScript -PathType Leaf)) {
    $skipped = [ordered]@{
      spike = 'v2-permissions'
      date = '2026-09-30'
      status = 'skipped'
      reason = 'provision_script_missing'
      detail = ('new-opencode-profile.ps1 nao encontrado: ' + $provScript)
      how_to_run = ('powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v2 -ProvisionRuntime  # opt-in (rede, ' + $pinSpecNote + '); depois re-execute este spike')
    }
    Write-SpikeJsonAtomic $skipped $EvidencePath
    Write-Host '[spike] SKIPPED: script de provisionamento ausente. Evidencia escrita.'
    exit 0
  }
  Write-Host '[spike] nenhum binario V2 resolvido; tentando provisionamento opt-in (rede/npm, 1x)...'
  $provBase = Get-SpikeTempBase
  $provOut = Join-Path $provBase ('v2spike-prov-out-' + [guid]::NewGuid().ToString('N') + '.log')
  $provErr = Join-Path $provBase ('v2spike-prov-err-' + [guid]::NewGuid().ToString('N') + '.log')
  $provEngine = 'powershell'
  if ($PSVersionTable.PSEdition -eq 'Core') { $provEngine = 'pwsh' }
  $provProc = Start-Process -FilePath $provEngine -ArgumentList @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $provScript + '"'), '-RuntimeId', 'opencode-v2', '-ProvisionRuntime') -NoNewWindow -PassThru -RedirectStandardOutput $provOut -RedirectStandardError $provErr
  $provDone = $provProc.WaitForExit(300000)
  if (-not $provDone) {
    try { & taskkill /PID $provProc.Id /T /F 2>$null | Out-Null } catch { }
    try { $provProc.WaitForExit(15000) } catch { }
    $provText = ''
    if (Test-Path -LiteralPath $provOut -PathType Leaf) { $provText = [IO.File]::ReadAllText($provOut) }
    if (Test-Path -LiteralPath $provErr -PathType Leaf) { $provText = $provText + "`n" + [IO.File]::ReadAllText($provErr) }
    $skipped = [ordered]@{
      spike = 'v2-permissions'
      date = '2026-09-30'
      status = 'skipped'
      reason = 'provision_timeout'
      detail = 'provisionamento V2 excedeu 300s (rede instavel ou indisponivel); partial log tail: ' + (($provText -split "`r?`n" | Select-Object -Last 5) -join ' | ')
      how_to_run = ('powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v2 -ProvisionRuntime  # opt-in (rede, ' + $pinSpecNote + '); depois re-execute este spike')
    }
    Write-SpikeJsonAtomic $skipped $EvidencePath
    Write-Host '[spike] SKIPPED: provisionamento timeout (rede?). Evidencia escrita.'
    exit 0
  }
  $provProc.Refresh()
  if ($provProc.ExitCode -eq 0) {
    Write-Host '[spike] provisionamento OK (exit 0); re-resolvendo binario V2...'
    $resolved = Resolve-SpikeBinary $BinaryPath $ProfileRoot
  }
  else {
    $provText = ''
    if (Test-Path -LiteralPath $provOut -PathType Leaf) { $provText = [IO.File]::ReadAllText($provOut) }
    if (Test-Path -LiteralPath $provErr -PathType Leaf) { $provText = $provText + "`n" + [IO.File]::ReadAllText($provErr) }
    $reason = 'provision_failed'
    if ($provProc.ExitCode -eq 7) { $reason = 'provision_network_failed' }
    $skipped = [ordered]@{
      spike = 'v2-permissions'
      date = '2026-09-30'
      status = 'skipped'
      reason = $reason
      detail = ('new-opencode-profile.ps1 -ProvisionRuntime saiu com exit ' + $provProc.ExitCode + '; tail: ' + ((($provText -split "`r?`n" | Select-Object -Last 5) -join ' | ')))
      how_to_run = ('powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v2 -ProvisionRuntime  # opt-in (rede, ' + $pinSpecNote + '); depois re-execute este spike')
    }
    Write-SpikeJsonAtomic $skipped $EvidencePath
    Write-Host ('[spike] SKIPPED: provisionamento falhou (exit ' + $provProc.ExitCode + '). Evidencia escrita.')
    exit 0
  }
}
if ($null -eq $resolved) {
  $skipped = [ordered]@{
    spike = 'v2-permissions'
    date = '2026-09-30'
    status = 'skipped'
    reason = 'v2_binary_unavailable'
    how_to_run = ('powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v2 -ProvisionRuntime  # opt-in (rede, ' + $pinSpecNote + '); depois re-execute este spike')
  }
  Write-SpikeJsonAtomic $skipped $EvidencePath
  Write-Host '[spike] SKIPPED: nenhum binario V2 (explicit/manifest/PATH). Evidencia escrita.'
  exit 0
}

$binary = [string]$resolved.Path
Write-Host ('[spike] binario V2: ' + $binary + ' (fonte: ' + [string]$resolved.Source + ')')

$checks = New-Object System.Collections.ArrayList
$notes = New-Object System.Collections.ArrayList
$spikeBase = Get-SpikeTempBase
$runChild = New-SpikeRunChild -BaseDir $spikeBase -Prefix 'oo-v2spike-'
if (-not [bool]$runChild.Created) {
  $blocked = [ordered]@{
    spike = 'v2-permissions'
    date = '2026-09-30'
    status = 'failed'
    binary = $binary
    binary_source = [string]$resolved.Source
    version = ''
    pinned_version = $PinnedVersionV2
    version_exact_pin = $false
    service_port = 0
    checks = @(@{ name = 'run_child'; passed = $false; detail = [string]$runChild.Reason })
    notes = @('Raiz por-run nao criada; nada executado.')
  }
  Write-SpikeJsonAtomic $blocked $EvidencePath
  Write-Host ('[spike] FAILED: ' + [string]$runChild.Reason)
  exit 0
}
$tempRoot = [string]$runChild.Path
$isoProved = $false
$portConfigured = $false
$warmupAttempted = $false
$freePort = 0
$verFirst = ''
$isExact = $false
try {
  $fx = New-SpikeFixture $tempRoot
  $xdgData = Join-Path $tempRoot 'xdg-data'
  $xdgState = Join-Path $tempRoot 'xdg-state'
  $xdgCache = Join-Path $tempRoot 'xdg-cache'
  $homeT = Join-Path $tempRoot 'home'
  $cwdT = Join-Path $tempRoot 'cwd'
  New-Item -ItemType Directory -Path $xdgData -Force | Out-Null
  New-Item -ItemType Directory -Path $xdgState -Force | Out-Null
  New-Item -ItemType Directory -Path $xdgCache -Force | Out-Null
  New-Item -ItemType Directory -Path $homeT -Force | Out-Null
  New-Item -ItemType Directory -Path $cwdT -Force | Out-Null
  $isoEnv = @{
    XDG_CONFIG_HOME = [string]$fx.XdgRoot
    XDG_DATA_HOME = $xdgData
    XDG_STATE_HOME = $xdgState
    XDG_CACHE_HOME = $xdgCache
    HOME = $homeT
    USERPROFILE = $homeT
  }
  $isoRemove = @('OPENCODE_CONFIG', 'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_CONTENT')

  $vr = Invoke-SpikeChild -FilePath $binary -ArgumentList @('--version') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
  $verText = ($vr.Stdout + "`n" + $vr.Stderr).Trim()
  $verFirst = (([string]$verText -split "`r?`n" | Select-Object -First 1)).Trim()
  $isExact = (((-not [bool]$vr.TimedOut) -and ([int]$vr.ExitCode -eq 0)) -and (Test-SpikeExactVersion -Text $verText -Version $PinnedVersionV2))
  if ($isExact -and [string]::IsNullOrWhiteSpace($verFirst)) { $verFirst = $verText }
  [void]$checks.Add([ordered]@{ name = 'version_exact_pin'; passed = $isExact; detail = ('cmd: <bin> --version (isolado, clean env); pin=' + $PinnedVersionV2 + '; rc=' + $vr.ExitCode + '; timeout=' + $vr.TimedOut + '; out=' + $verFirst) })

  $dp = Invoke-SpikeChild -FilePath $binary -ArgumentList @('debug', 'paths') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
  $dpText = $dp.Stdout + "`n" + $dp.Stderr
  $wantSlash = (([string]$fx.XdgRoot) -replace '\\', '/')
  $wantBack = (([string]$fx.XdgRoot) -replace '/', '\')
  $isoOk = (((-not [bool]$dp.TimedOut) -and ([int]$dp.ExitCode -eq 0)) -and ($dpText.Contains($wantSlash) -or $dpText.Contains($wantBack)))
  [void]$checks.Add([ordered]@{ name = 'isolation_xdg_honored'; passed = $isoOk; detail = ('cmd: <bin> debug paths (isolado, clean env); rc=' + $dp.ExitCode + '; config resolve dentro da fixture=' + $isoOk) })
  $isoProved = ([bool]$isExact -and [bool]$isoOk)

  if (-not $isoProved) {
    if (-not $isExact) {
      [void]$notes.Add(('Versao exata ' + $PinnedVersionV2 + ' (pin do registry) nao provada: nenhuma operacao de servico/config apos este ponto (fail closed).'))
    }
    else {
      [void]$notes.Add('Isolamento nao provado: checks dependentes de servidor NAO executados contra config global (fail closed).')
    }
    foreach ($n in @('service_port_configured', 'config_sources_listed', 'service_private_running', 'agents_load_fixture', 'service_stop_clean')) {
      [void]$checks.Add([ordered]@{ name = $n; passed = $false; detail = 'nao executado: gates (versao/isolamento) nao provados' })
    }
  }
  else {
    $freePort = Get-SpikeFreePort
    $sp = Invoke-SpikeChild -FilePath $binary -ArgumentList @('service', 'set', 'port', "$freePort") -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
    $spOk = ((-not [bool]$sp.TimedOut) -and ([int]$sp.ExitCode -eq 0))
    $portConfigured = $spOk
    [void]$checks.Add([ordered]@{ name = 'service_port_configured'; passed = $spOk; detail = ('cmd: <bin> service set port <livre> (porta efemera local, clean env); rc=' + $sp.ExitCode + '; timeout=' + $sp.TimedOut) })
    [void]$notes.Add('V2 debug exige o background service (serve --service, porta fixa 127.0.0.1:49374); porta ocupada trava o CLI sem saida. Servidor privado por ambiente via `service set port` (o servico sobe sob demanda no 1o comando); prova em `service status` apos o warmup.')

    $dcOk = $false
    if ($spOk) {
      $warmupAttempted = $true
      $dc = Invoke-SpikeChild -FilePath $binary -ArgumentList @('debug', 'config') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
      $dcNorm = (($dc.Stdout + "`n" + $dc.Stderr).Replace('\\', '\'))
      $cfgSlash = (([string]$fx.ConfigPath) -replace '\\', '/')
      $dcOk = (((-not [bool]$dc.TimedOut) -and ([int]$dc.ExitCode -eq 0)) -and ($dcNorm.Contains($cfgSlash) -or $dcNorm.Contains([string]$fx.ConfigPath)))
      [void]$checks.Add([ordered]@{ name = 'config_sources_listed'; passed = $dcOk; detail = ('cmd: <bin> debug config (servidor privado, warmup, clean env); rc=' + $dc.ExitCode + '; timeout=' + $dc.TimedOut + '; fixture listada=' + $dcOk) })
    }
    else {
      [void]$checks.Add([ordered]@{ name = 'config_sources_listed'; passed = $false; detail = 'nao executado: service set port falhou' })
    }
    [void]$notes.Add('V2 `debug config` lista fontes de configuracao (nao e o validador do V1); `debug agents` e a sonda de load da fixture.')

    $stOk = $false
    $stText = ''
    if ($dcOk) {
      $st = Invoke-SpikeChild -FilePath $binary -ArgumentList @('service', 'status') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
      $stText = ($st.Stdout + "`n" + $st.Stderr).Trim()
      $stOk = (((-not [bool]$st.TimedOut) -and ([int]$st.ExitCode -eq 0)) -and ($stText.Contains('127.0.0.1:' + $freePort)) -and (-not $stText.Contains('49374')))
      [void]$checks.Add([ordered]@{ name = 'service_private_running'; passed = $stOk; detail = ('cmd: <bin> service status (apos warmup, clean env) => ' + $stText + '; esperado 127.0.0.1:' + $freePort + ' sem 49374') })
    }
    else {
      [void]$checks.Add([ordered]@{ name = 'service_private_running'; passed = $false; detail = 'nao executado: config_sources_listed falhou (warmup ausente)' })
    }

    $daOk = $false
    $daAttempts = 0
    $daLastRc = -1
    if ($dcOk) {
      for ($i = 1; $i -le 3; $i++) {
        if ($i -gt 1) { Start-Sleep -Seconds 3 }
        $da = Invoke-SpikeChild -FilePath $binary -ArgumentList @('debug', 'agents') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
        $daAttempts = $i
        $daLastRc = [int]$da.ExitCode
        $daText = $da.Stdout + "`n" + $da.Stderr
        if (((-not [bool]$da.TimedOut) -and ([int]$da.ExitCode -eq 0)) -and ($daText -match 'fixture-writer')) {
          $daOk = $true
          break
        }
      }
      [void]$checks.Add([ordered]@{ name = 'agents_load_fixture'; passed = $daOk; detail = ('cmd: <bin> debug agents ate 3x (servidor privado, clean env); tentativas=' + $daAttempts + '; lastRc=' + $daLastRc + '; lista fixture-writer=' + $daOk + ' (1a chamada pode devolver [] com servico inicializando)') })
    }
    else {
      [void]$checks.Add([ordered]@{ name = 'agents_load_fixture'; passed = $false; detail = 'nao executado: config_sources_listed falhou' })
    }

    $stopRes = Invoke-SpikeServiceStopIfOwned -FilePath $binary -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -IsolationProved $isoProved -PortConfigured $portConfigured -Port $freePort -WarmupAttempted $warmupAttempted -TimeoutMs 30000 -CleanEnvironment -StdinNul
    [void]$checks.Add([ordered]@{ name = 'service_stop_clean'; passed = [bool]$stopRes.Stopped; detail = ('stop com gates (owned): attempted=' + $stopRes.Attempted + '; ' + [string]$stopRes.Reason) })
  }

  $allAuto = $true
  foreach ($c in $checks) { if (-not [bool]$c.passed) { $allAuto = $false } }
  $status = 'failed'
  if ($allAuto) { $status = 'ok' }

  $evidence = [ordered]@{
    spike = 'v2-permissions'
    date = '2026-09-30'
    status = $status
    binary = $binary
    binary_source = [string]$resolved.Source
    version = $verFirst
    pinned_version = $PinnedVersionV2
    version_exact_pin = $isExact
    service_port = $freePort
    isolation = 'XDG_CONFIG/DATA/STATE/CACHE + HOME/USERPROFILE no run-child; OPENCODE_CONFIG* removido do filho; clean env (allowlist SO) em todas as sondas; cwd no run-child; stdin fechado; exit code real do processo'
    checks = @($checks)
    notes = @($notes)
    behavioral_permission_enforcement = [ordered]@{
      status = 'manual_checklist_pending'
      note = 'Load automatizado OK nao e PASS comportamental. Levar um agente live a tentar operacao negada nao e automatizavel neste harness; passos abaixo pendentes de execucao manual contra o binario acima.'
      steps = @(
        '1. fixture-writer executa `git status --short` (allow estreito): esperado ALLOW (last-match-wins sobre o deny-all).'
        '2. fixture-writer executa shell fora do allow (ex.: `git push --force`): esperado DENY pelo deny-all ordenado.'
        '3. fixture-reader tenta qualquer edit/shell: esperado DENY.'
        '4. worker tenta subdelegar (subagent): esperado DENY; saved approval/ask nao pode ampliar para ALLOW.'
        '5. experimental.policies com hard-deny (ex.: force-push): esperado DENY mesmo com allow + saved approval; sem policy inventada ate este passo passar no runtime real.'
      )
    }
  }
  Write-SpikeJsonAtomic $evidence $EvidencePath
  Write-Host ('[spike] ' + $status.ToUpperInvariant() + ': evidencia em ' + $EvidencePath)
  exit 0
}
finally {
  # Stop com gates (owned): so para servico provado no endpoint privado;
  # nunca toca servico global/default. Best-effort, sem falhar o harness.
  try {
    $isoEnv2 = @{
      XDG_CONFIG_HOME = (Join-Path $tempRoot 'xdg')
      XDG_DATA_HOME = (Join-Path $tempRoot 'xdg-data')
      XDG_STATE_HOME = (Join-Path $tempRoot 'xdg-state')
      XDG_CACHE_HOME = (Join-Path $tempRoot 'xdg-cache')
      HOME = (Join-Path $tempRoot 'home')
      USERPROFILE = (Join-Path $tempRoot 'home')
    }
    $stop2 = @('OPENCODE_CONFIG', 'OPENCODE_CONFIG_DIR')
    $stop2 += @('OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_CONTENT')
    [void](Invoke-SpikeServiceStopIfOwned -FilePath $binary -EnvSet $isoEnv2 -EnvRemove $stop2 -WorkingDirectory $tempRoot -IsolationProved $isoProved -PortConfigured $portConfigured -Port $freePort -WarmupAttempted $warmupAttempted -TimeoutMs 30000 -CleanEnvironment -StdinNul)
  }
  catch { }
  Start-Sleep -Seconds 2
  try {
    [void](Remove-SpikeRunChild -Path $tempRoot -BaseDir $spikeBase)
  }
  catch { }
  if (Test-Path -LiteralPath $tempRoot -PathType Container) {
    Start-Sleep -Seconds 2
    try {
      [void](Remove-SpikeRunChild -Path $tempRoot -BaseDir $spikeBase)
    }
    catch { }
  }
}
