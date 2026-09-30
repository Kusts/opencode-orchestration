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
    + experimental.subagent_depth=1) num XDG root temporario e roda o binario
    com isolamento de config por processo (XDG_CONFIG_HOME; fallback
    USERPROFILE/HOME temporario, mesmo padrao de scripts/ci/smoke-opencode.ps1).
    XDG_DATA_HOME/XDG_STATE_HOME/XDG_CACHE_HOME tambem apontam para o temp para
    conter arquivos do servico. stdin vem de NUL (sem isso os subcomandos debug
    do V2 aguardam entrada e o harness trava). Exit code e capturado por echo
    de marcador (Start-Process .ExitCode nao e confiavel com este binario).
    Checks automatizados correspondem 1:1 a comandos realmente executados.
    Enforcement comportamental (levar um agente live a tentar operacao negada)
    NAO e automatizavel aqui: registrado como manual_checklist_pending.

    PS 5.1 compativel. ASCII only. Nunca escreve fora de temp/evidencia; nunca
    toca a config global do usuario; nunca persiste env.
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
    -RuntimeId opencode-v2 -ProvisionRuntime, baixa @opencode/cli@2.0.18 para
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

function Invoke-SpikeChild {
  param([string]$Binary, [string]$ArgsLine, [hashtable]$EnvSet = $null, [int]$TimeoutMs = 60000)
  $logs = Join-Path (Get-SpikeTempBase) ('v2spike-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $logs -Force | Out-Null
  $outFile = Join-Path $logs 'out.log'
  $errFile = Join-Path $logs 'err.log'
  $saved = @{}
  try {
    if ($null -ne $EnvSet) {
      foreach ($k in @($EnvSet.Keys)) {
        $kk = [string]$k
        if (Test-Path -LiteralPath ('Env:\' + $kk)) { $saved[$kk] = (Get-Item -LiteralPath ('Env:\' + $kk)).Value }
        else { $saved[$kk] = $null }
        [Environment]::SetEnvironmentVariable($kk, [string]$EnvSet[$kk], 'Process')
      }
    }
    $quoted = $Binary
    if (($quoted.Contains(' ')) -or ($quoted.Contains('"'))) {
      $quoted = '"' + ($quoted -replace '"', '\"') + '"'
    }
    $line = $quoted
    if (-not [string]::IsNullOrWhiteSpace($ArgsLine)) { $line = $line + ' ' + $ArgsLine }
    $line = $line + ' < NUL & echo SPIKE_RC_7F3A:%ERRORLEVEL%'
    $p = Start-Process -FilePath 'cmd' -ArgumentList @('/c', $line) -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $done = $p.WaitForExit($TimeoutMs)
    if (-not $done) {
      try { & taskkill /PID $p.Id /T /F 2>$null | Out-Null } catch { }
      try { $p.WaitForExit(10000) } catch { }
      return @{ ExitCode = -1; Stdout = ''; Stderr = 'timeout'; TimedOut = $true }
    }
    Start-Sleep -Milliseconds 500
    $o = ''
    $e = ''
    if (Test-Path -LiteralPath $outFile -PathType Leaf) { $o = [IO.File]::ReadAllText($outFile) }
    if (Test-Path -LiteralPath $errFile -PathType Leaf) { $e = [IO.File]::ReadAllText($errFile) }
    $code = -2
    $m = [regex]::Match($o, 'SPIKE_RC_7F3A:(\d+)')
    if ($m.Success) {
      $code = [int]$m.Groups[1].Value
      $o = ($o -replace '\s*SPIKE_RC_7F3A:\d+\s*$', '')
    }
    return @{ ExitCode = $code; Stdout = $o; Stderr = $e; TimedOut = $false }
  }
  finally {
    foreach ($k in @($saved.Keys)) {
      $kk = [string]$k
      if ($null -eq $saved[$kk]) { Remove-Item -LiteralPath ('Env:\' + $kk) -ErrorAction SilentlyContinue }
      else { [Environment]::SetEnvironmentVariable($kk, [string]$saved[$kk], 'Process') }
    }
    Remove-Item -LiteralPath $logs -Recurse -Force -ErrorAction SilentlyContinue
  }
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
      $vr = Invoke-SpikeChild -Binary $src -ArgsLine '--version' -TimeoutMs 30000
      if (($vr.ExitCode -eq 0) -and ((Get-SpikeMajor ($vr.Stdout + "`n" + $vr.Stderr)) -eq 2)) {
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
  Write-Host '[FIXTURE] temp XDG root com opencode/opencode.json (V2: agents/permissions ordenadas, experimental.subagent_depth=1) + agents/*.md de registro'
  Write-Host '[RUN] --version | debug paths (isolamento) | debug config (fontes) | debug agents (load da fixture)'
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
      date = '2026-09-29'
      status = 'skipped'
      reason = 'provision_script_missing'
      detail = ('new-opencode-profile.ps1 nao encontrado: ' + $provScript)
      how_to_run = 'powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v2 -ProvisionRuntime  # opt-in (rede, baixa @opencode/cli@2.0.18 no perfil); depois re-execute este spike'
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
      date = '2026-09-29'
      status = 'skipped'
      reason = 'provision_timeout'
      detail = 'provisionamento V2 excedeu 300s (rede instavel ou indisponivel); partial log tail: ' + (($provText -split "`r?`n" | Select-Object -Last 5) -join ' | ')
      how_to_run = 'powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v2 -ProvisionRuntime  # opt-in (rede, baixa @opencode/cli@2.0.18 no perfil); depois re-execute este spike'
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
      date = '2026-09-29'
      status = 'skipped'
      reason = $reason
      detail = ('new-opencode-profile.ps1 -ProvisionRuntime saiu com exit ' + $provProc.ExitCode + '; tail: ' + ((($provText -split "`r?`n" | Select-Object -Last 5) -join ' | ')))
      how_to_run = 'powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v2 -ProvisionRuntime  # opt-in (rede, baixa @opencode/cli@2.0.18 no perfil); depois re-execute este spike'
    }
    Write-SpikeJsonAtomic $skipped $EvidencePath
    Write-Host ('[spike] SKIPPED: provisionamento falhou (exit ' + $provProc.ExitCode + '). Evidencia escrita.')
    exit 0
  }
}
if ($null -eq $resolved) {
  $skipped = [ordered]@{
    spike = 'v2-permissions'
    date = '2026-09-29'
    status = 'skipped'
    reason = 'v2_binary_unavailable'
    how_to_run = 'powershell -NoProfile -File scripts\runtime\new-opencode-profile.ps1 -RuntimeId opencode-v2 -ProvisionRuntime  # opt-in (rede, baixa @opencode/cli@2.0.18 no perfil); depois re-execute este spike'
  }
  Write-SpikeJsonAtomic $skipped $EvidencePath
  Write-Host '[spike] SKIPPED: nenhum binario V2 (explicit/manifest/PATH). Evidencia escrita.'
  exit 0
}

$binary = [string]$resolved.Path
Write-Host ('[spike] binario V2: ' + $binary + ' (fonte: ' + [string]$resolved.Source + ')')

$checks = New-Object System.Collections.ArrayList
$notes = New-Object System.Collections.ArrayList
$tempRoot = Join-Path (Get-SpikeTempBase) ('oo-v2spike-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
  $fx = New-SpikeFixture $tempRoot
  $xdgData = Join-Path $tempRoot 'xdg-data'
  $xdgState = Join-Path $tempRoot 'xdg-state'
  $xdgCache = Join-Path $tempRoot 'xdg-cache'
  New-Item -ItemType Directory -Path $xdgData -Force | Out-Null
  New-Item -ItemType Directory -Path $xdgState -Force | Out-Null
  New-Item -ItemType Directory -Path $xdgCache -Force | Out-Null
  $isoEnv = @{
    XDG_CONFIG_HOME = [string]$fx.XdgRoot
    XDG_DATA_HOME = $xdgData
    XDG_STATE_HOME = $xdgState
    XDG_CACHE_HOME = $xdgCache
  }

  $vr = Invoke-SpikeChild -Binary $binary -ArgsLine '--version' -EnvSet $isoEnv -TimeoutMs 30000
  $verText = ($vr.Stdout + "`n" + $vr.Stderr).Trim()
  $verFirst = (([string]$verText -split "`r?`n" | Select-Object -First 1)).Trim()
  $is2x = (($vr.ExitCode -eq 0) -and ((Get-SpikeMajor $verText) -eq 2))
  if ($is2x -and [string]::IsNullOrWhiteSpace($verFirst)) { $verFirst = $verText }
  [void]$checks.Add([ordered]@{ name = 'version_responds_2x'; passed = $is2x; detail = ('cmd: <bin> --version; rc=' + $vr.ExitCode + '; out=' + $verFirst) })

  $dp = Invoke-SpikeChild -Binary $binary -ArgsLine 'debug paths' -EnvSet $isoEnv -TimeoutMs 60000
  $dpText = $dp.Stdout + "`n" + $dp.Stderr
  $wantSlash = (([string]$fx.XdgRoot) -replace '\\', '/')
  $wantBack = (([string]$fx.XdgRoot) -replace '/', '\')
  $xdgOk = (($dp.ExitCode -eq 0) -and ($dpText.Contains($wantSlash) -or $dpText.Contains($wantBack)))
  if ($xdgOk) {
    [void]$checks.Add([ordered]@{ name = 'isolation_xdg_honored'; passed = $true; detail = 'cmd: <bin> debug paths com XDG_CONFIG_HOME=temp; config resolve dentro da fixture' })
  }
  else {
    [void]$checks.Add([ordered]@{ name = 'isolation_xdg_honored'; passed = $false; detail = ('cmd: <bin> debug paths com XDG_CONFIG_HOME=temp; rc=' + $dp.ExitCode + '; sem resolucao na fixture (tentando fallback USERPROFILE/HOME)') })
    $homeT = Join-Path $tempRoot 'home'
    New-Item -ItemType Directory -Path (Join-Path $homeT '.config\opencode') -Force | Out-Null
    Copy-Item -LiteralPath ([string]$fx.ConfigPath) -Destination (Join-Path $homeT '.config\opencode\opencode.json') -Force
    $dp2 = Invoke-SpikeChild -Binary $binary -ArgsLine 'debug paths' -EnvSet @{ USERPROFILE = $homeT; HOME = $homeT } -TimeoutMs 60000
    $dp2Text = $dp2.Stdout + "`n" + $dp2.Stderr
    $hSlash = ($homeT -replace '\\', '/')
    if (($dp2.ExitCode -eq 0) -and ($dp2Text.Contains($hSlash) -or $dp2Text.Contains($homeT))) {
      $isoEnv = @{ USERPROFILE = $homeT; HOME = $homeT }
      [void]$checks.Add([ordered]@{ name = 'isolation_userprofile_home_honored'; passed = $true; detail = 'cmd: <bin> debug paths com USERPROFILE/HOME=temp; config resolve dentro da fixture' })
    }
    else {
      [void]$checks.Add([ordered]@{ name = 'isolation_userprofile_home_honored'; passed = $false; detail = ('cmd: <bin> debug paths com USERPROFILE/HOME=temp; rc=' + $dp2.ExitCode + '; isolamento nao provado; checks de fixture NAO executados contra config global') })
      $isoEnv = $null
    }
  }

  if ($null -ne $isoEnv) {
    $dc = Invoke-SpikeChild -Binary $binary -ArgsLine 'debug config' -EnvSet $isoEnv -TimeoutMs 90000
    $dcText = $dc.Stdout + "`n" + $dc.Stderr
    $dcOk = (($dc.ExitCode -eq 0) -and ($dc.TimedOut -eq $false))
    if ($dc.TimedOut) {
      [void]$checks.Add([ordered]@{ name = 'config_sources_listed'; passed = $false; detail = 'cmd: <bin> debug config (isolado); TIMEOUT 90s (stdin vem de NUL; sem saidas)' })
    }
    else {
      [void]$checks.Add([ordered]@{ name = 'config_sources_listed'; passed = $dcOk; detail = ('cmd: <bin> debug config (isolado); rc=' + $dc.ExitCode + '; V2 lista fontes de config, nao valida conteudo') })
    }
    [void]$notes.Add('V2 `debug config` lista fontes de configuracao (nao e o validador do V1); `debug agents` e a sonda de load da fixture.')

    $da = Invoke-SpikeChild -Binary $binary -ArgsLine 'debug agents' -EnvSet $isoEnv -TimeoutMs 90000
    $daText = $da.Stdout + "`n" + $da.Stderr
    if ($da.TimedOut) {
      [void]$checks.Add([ordered]@{ name = 'agents_load_fixture'; passed = $false; detail = 'cmd: <bin> debug agents (isolado); TIMEOUT 90s (stdin vem de NUL; sem saidas)' })
    }
    else {
      $daOk = (($da.ExitCode -eq 0) -and ($daText -match 'fixture-writer'))
      [void]$checks.Add([ordered]@{ name = 'agents_load_fixture'; passed = $daOk; detail = ('cmd: <bin> debug agents (isolado); rc=' + $da.ExitCode + '; lista fixture-writer=' + ($daText -match 'fixture-writer')) })
    }
  }

  $allAuto = $true
  foreach ($c in $checks) { if (-not [bool]$c.passed) { $allAuto = $false } }
  $status = 'failed'
  if ($allAuto) { $status = 'ok' }

  $evidence = [ordered]@{
    spike = 'v2-permissions'
    date = '2026-09-29'
    status = $status
    binary = $binary
    binary_source = [string]$resolved.Source
    version = $verFirst
    isolation = 'XDG_CONFIG_HOME (+XDG_DATA/STATE/CACHE no temp; stdin NUL; rc por echo)'
    checks = @($checks)
    notes = @($notes)
    behavioral_permission_enforcement = [ordered]@{
      status = 'manual_checklist_pending'
      note = 'Levar um agente live a tentar operacao negada nao e automatizavel neste harness; passos abaixo pendentes de execucao manual contra o binario acima.'
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
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
