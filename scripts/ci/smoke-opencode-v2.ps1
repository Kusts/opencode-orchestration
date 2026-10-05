<#!
.SYNOPSIS
    Smoke test do pacote com OpenCode V2 REAL num home isolado (Phase 8, V3.1).
.DESCRIPTION
    Pinned: OpenCode V2 exato, pin do registry unico
    (source/registry/runtime-versions.json, entrada runtimes.v2; default via
    -OpenCodeSpec; comparado por igualdade de versao, nao so major 2).
    Instalacao no CI via `npm install -g <spec do registry>` (passo do
    workflow) + postinstall oficial; este script NAO provisiona: sem binario
    exato e MANDATORIO falhar (exit 1, nunca skip silencioso).

    Fluxo (tudo em TEMP isolado; config global do usuario intocada):
      1. Resolve o binario (explicito ou PATH) e exige `--version` == pin do
         registry (igualdade de versao, nao so major 2).
      2. Constroi opencode.json com os 19 workers canonicos via
         scripts/runtime/lib/AgentTranslator.ps1 (mesmas funcoes dos testes
         de paridade) + build primario + experimental.subagent_depth=1.
      3. Servidor privado por ambiente (`service set port` em porta livre;
         o V2 exige background service com porta fixa 49374, ocupada trava
         o CLI sem saida).
      4. Assercoes: debug paths (isolamento) / debug config (fontes, warmup)
         / service status (URL privada) / debug agents ate 3x (19 ids)
         / plugin list + mcp list (observados, rc=0) / service stop.
      5. Evidencia JSON 1:1 com os comandos (so fatos observados). O campo
          `date` e o carimbo da execucao (data do relogio na escrita da
          evidencia, formato yyyy-MM-dd), nunca um literal do script.

    Sem chamadas pagas, sem credenciais, sem modelo/API. Falhas de load ou
    timeout => exit 1. `models` nao e tentado (exige providers/rede):
    registrado como not_attempted. Enforcement comportamental continua
    manual_checklist_pending no spike (nao afirmado aqui).

    PS 5.1 e PS7 compativel. ASCII only. Exit 0 = PASS; 1 = FAIL.
.PARAMETER RepoRoot
    Raiz do repositorio do pacote. Default: dois niveis acima deste script.
.PARAMETER TargetHome
    Home isolado do smoke. Default: $env:RUNNER_TEMP\oo-v2smoke-home (CI) ou
    $env:TEMP\oo-v2smoke-home fora do CI.
.PARAMETER OpenCodeSpec
    Spec npm esperada (igualdade de versao; a instalacao global e feita pelo
    workflow ou pelo dev). Vazio (default) = pin do registry unico
    source/registry/runtime-versions.json (runtimes.v2); valor explicito =
    override do pin.
.PARAMETER BinaryPath
    Binario V2 explicito (opcional; CI usa o PATH apos npm install -g).
.PARAMETER EvidencePath
    JSON de evidencia. Default: evidence/v3.1/kernel-hardening/v2-ci-smoke.json
    relativo a raiz do repo.
#>
param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$TargetHome = '',
  [string]$OpenCodeSpec = '',
  [string]$BinaryPath = '',
  [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$lib = Join-Path $RepoRoot 'scripts\runtime\lib\SpikeProcess.ps1'
. $lib
$translator = Join-Path $RepoRoot 'scripts\runtime\lib\AgentTranslator.ps1'
. $translator
# Pin: registry unico (fail-closed); -OpenCodeSpec explicito sobrepoe.
. (Join-Path $RepoRoot 'scripts\runtime\lib\RuntimeVersions.ps1')
$RegistryPinV2 = [string](Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $RepoRoot).Version
if ([string]::IsNullOrWhiteSpace($OpenCodeSpec)) {
  $OpenCodeSpec = [string](Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $RepoRoot).Spec
}

if ([string]::IsNullOrWhiteSpace($TargetHome)) {
  $baseHome = $env:RUNNER_TEMP
  if ([string]::IsNullOrWhiteSpace($baseHome)) { $baseHome = $env:TEMP }
  if ([string]::IsNullOrWhiteSpace($baseHome)) { $baseHome = [IO.Path]::GetTempPath() }
  $TargetHome = Join-Path $baseHome 'oo-v2smoke-home'
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
  $EvidencePath = Join-Path $RepoRoot 'evidence\v3.1\kernel-hardening\v2-ci-smoke.json'
}

$ExpectedVersion = $RegistryPinV2
$m = [regex]::Match($OpenCodeSpec, '(\d+)\.(\d+)\.(\d+)')
if ($m.Success) {
  $ExpectedVersion = $m.Groups[1].Value + '.' + $m.Groups[2].Value + '.' + $m.Groups[3].Value
}

$smokeChecks = New-Object System.Collections.ArrayList
$smokeNotes = New-Object System.Collections.ArrayList
$binaryUsed = ''
$freePortUsed = 0
$agentsExpected = @()

function Write-SmokeJsonAtomic($Object, [string]$TargetPath) {
  $parent = Split-Path -Parent $TargetPath
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $tmp = $TargetPath + '.tmp-' + [guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($tmp, ((($Object | ConvertTo-Json -Depth 10).TrimEnd() + "`n") -replace "`r`n", "`n" -replace "`r", "`n"), (New-Object Text.UTF8Encoding $false))
  Move-Item -LiteralPath $tmp -Destination $TargetPath -Force
}

function Add-SmokeCheck([string]$Name, [bool]$Passed, [string]$Detail) {
  [void]$script:smokeChecks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
}

function Get-SmokeEvidenceDate {
  # Carimbo da EXECUCAO: data do relogio no momento em que a evidencia e
  # escrita (formato yyyy-MM-dd, o mesmo do campo historico). Antes era um
  # literal fixo de data, que carimbava com a data da PASSAGEM qualquer
  # evidencia gerada depois. Sem semantica alem do valor: nada mais no
  # registro muda.
  return (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

function Fail-Smoke([string]$Message) {
  Write-Host ('[smoke-v2] FALHA: ' + $Message)
  $failed = [ordered]@{
    smoke = 'v2-ci-smoke'
    date = Get-SmokeEvidenceDate
    status = 'failed'
    binary = $script:binaryUsed
    expected_version = $script:ExpectedVersion
    service_port = $script:freePortUsed
    checks = @($script:smokeChecks)
    notes = @($script:smokeNotes)
    fail_detail = $Message
  }
  Write-SmokeJsonAtomic $failed $EvidencePath
  Write-Host ('[smoke-v2] evidencia (failed) em ' + $EvidencePath)
  exit 1
}

function Resolve-SmokeBinary([string]$Explicit, [string]$WantVersion) {
  $cands = New-Object System.Collections.ArrayList
  if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
    if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
      Fail-Smoke ('-BinaryPath inexistente: ' + $Explicit)
    }
    [void]$cands.Add($Explicit)
  }
  else {
    $found = @(Get-Command -Name 'opencode' -All -ErrorAction SilentlyContinue)
    foreach ($c in $found) {
      $src = ''
      try { $src = [string]$c.Source } catch { $src = '' }
      if ([string]::IsNullOrWhiteSpace($src)) { continue }
      if (-not (Test-Path -LiteralPath $src)) { continue }
      [void]$cands.Add($src)
    }
    if ($cands.Count -eq 0) {
      Fail-Smoke ('binario opencode ausente no PATH; instale ' + $OpenCodeSpec + ' (ex.: npm install -g ' + $OpenCodeSpec + ' + postinstall oficial).')
    }
  }
  foreach ($cand in $cands) {
    $vr = Invoke-SpikeChild -FilePath ([string]$cand) -ArgumentList @('--version') -TimeoutMs 30000
    $verText = ($vr.Stdout + "`n" + $vr.Stderr)
    if (((-not [bool]$vr.TimedOut) -and ([int]$vr.ExitCode -eq 0)) -and ($verText.Contains($WantVersion))) {
      $first = (([string]$verText -split "`r?`n" | Select-Object -First 1)).Trim()
      return @{ Path = [string]$cand; VersionLine = $first }
    }
  }
  Fail-Smoke ('nenhum binario com versao exata ' + $WantVersion + ' (candidatos: ' + ($cands -join ' | ') + ').')
  return $null
}

function New-SmokeConfig([string]$ConfigPath, [string]$AgentsDir) {
  $files = @(Get-ChildItem -LiteralPath $AgentsDir -Filter '*.md' -File | Sort-Object Name)
  if ($files.Count -eq 0) { Fail-Smoke ('nenhum .md canonico em ' + $AgentsDir) }
  $agents = [ordered]@{}
  $stems = New-Object System.Collections.ArrayList
  foreach ($f in $files) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    [void]$stems.Add($stem)
    $parsed = $null
    try { $parsed = Read-AgentFileCanonical -Path $f.FullName }
    catch { Fail-Smoke ('parse canonico falhou (' + $stem + '): ' + $_.Exception.Message) }
    $c = $parsed.Canonical
    $rules = New-Object System.Collections.ArrayList
    if ([bool]$c.EditPresent) {
      [void]$rules.Add([ordered]@{ action = 'edit'; resource = '*'; effect = [string]$c.Edit })
    }
    foreach ($r in @(Get-OrderedV2ShellRules -Canonical $c)) {
      [void]$rules.Add([ordered]@{ action = [string]$r.Action; resource = [string]$r.Resource; effect = [string]$r.Effect })
    }
    foreach ($r in @(Get-OrderedV2TaskRules -Canonical $c)) {
      [void]$rules.Add([ordered]@{ action = [string]$r.Action; resource = [string]$r.Resource; effect = [string]$r.Effect })
    }
    $agents[$stem] = [ordered]@{
      mode = [string]$c.Mode
      permissions = @($rules)
    }
  }
  $buildRules = New-Object System.Collections.ArrayList
  [void]$buildRules.Add([ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' })
  foreach ($s in ($stems | Sort-Object)) {
    [void]$buildRules.Add([ordered]@{ action = 'subagent'; resource = [string]$s; effect = 'allow' })
  }
  $orderedAgents = [ordered]@{
    build = [ordered]@{ mode = 'primary'; permissions = @($buildRules) }
  }
  foreach ($s in ($stems | Sort-Object)) {
    $orderedAgents[[string]$s] = $agents[[string]$s]
  }
  $cfg = [ordered]@{
    default_agent = 'build'
    agents = $orderedAgents
    experimental = [ordered]@{ subagent_depth = 1 }
  }
  $parent = Split-Path -Parent $ConfigPath
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $tmp = $ConfigPath + '.tmp-' + [guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($tmp, ((($cfg | ConvertTo-Json -Depth 8).TrimEnd() + "`n") -replace "`r`n", "`n" -replace "`r", "`n"), (New-Object Text.UTF8Encoding $false))
  Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
  return @($stems)
}

Write-Host ('[smoke-v2] RepoRoot=' + $RepoRoot)
Write-Host ('[smoke-v2] TargetHome=' + $TargetHome)
Write-Host ('[smoke-v2] OpenCodeSpec=' + $OpenCodeSpec + ' (versao exata exigida: ' + $ExpectedVersion + ')')

if (-not (Test-Path -LiteralPath $TargetHome -PathType Container)) {
  New-Item -ItemType Directory -Path $TargetHome -Force | Out-Null
}
$xdg = Join-Path $TargetHome 'xdg'
$xdgData = Join-Path $TargetHome 'xdg-data'
$xdgState = Join-Path $TargetHome 'xdg-state'
$xdgCache = Join-Path $TargetHome 'xdg-cache'
$homeT = Join-Path $TargetHome 'home'
$cwdT = Join-Path $TargetHome 'cwd'
foreach ($d in @($xdg, $xdgData, $xdgState, $xdgCache, $homeT, $cwdT)) {
  if (-not (Test-Path -LiteralPath $d -PathType Container)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
  }
}
$stopEnv = @{
  XDG_CONFIG_HOME = $xdg
  XDG_DATA_HOME = $xdgData
  XDG_STATE_HOME = $xdgState
  XDG_CACHE_HOME = $xdgCache
  HOME = $homeT
  USERPROFILE = $homeT
}
$stopRemove = @('OPENCODE_CONFIG', 'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_CONTENT')

try {
  # ---- 0. binario exato (mandatorio; sem skip) ----
  $res = Resolve-SmokeBinary $BinaryPath $ExpectedVersion
  $binaryUsed = [string]$res.Path
  $script:binaryUsed = $binaryUsed
  Write-Host ('[smoke-v2] binario: ' + $binaryUsed + ' (' + [string]$res.VersionLine + ')')
  Add-SmokeCheck 'version_exact' $true ('cmd: <bin> --version; exige ' + $ExpectedVersion + '; obtido: ' + [string]$res.VersionLine)

  # ---- 1. config com os 19 workers canonicos ----
  $agentsDir = Join-Path $RepoRoot 'source\agents'
  $cfgPath = Join-Path $xdg 'opencode\opencode.json'
  $stems = @(New-SmokeConfig $cfgPath $agentsDir)
  $agentsExpected = @($stems)
  Add-SmokeCheck 'config_19_workers_built' ($stems.Count -eq 19) ('opencode.json gerado via AgentTranslator com ' + $stems.Count + ' workers (esperado 19): ' + ($stems -join ','))
  if ($stems.Count -ne 19) { Fail-Smoke ('workers canonicos <> 19 (obtido ' + $stems.Count + ')') }

  $isoEnv = @{
    XDG_CONFIG_HOME = $xdg
    XDG_DATA_HOME = $xdgData
    XDG_STATE_HOME = $xdgState
    XDG_CACHE_HOME = $xdgCache
    HOME = $homeT
    USERPROFILE = $homeT
  }
  $isoRemove = @('OPENCODE_CONFIG', 'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_CONTENT')

  # ---- 2. isolamento ----
  $dp = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('debug', 'paths') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000
  if ([bool]$dp.TimedOut) { Fail-Smoke 'debug paths: TIMEOUT 30s (binario nao responde isolado).' }
  if ([int]$dp.ExitCode -ne 0) { Fail-Smoke ('debug paths: exit ' + $dp.ExitCode + ' (esperado 0).') }
  $dpText = $dp.Stdout + "`n" + $dp.Stderr
  if (-not ($dpText.Contains($xdg) -or $dpText.Contains(($xdg -replace '\\', '/')))) { Fail-Smoke 'debug paths: config nao resolve dentro do home isolado.' }
  Add-SmokeCheck 'isolation_paths' $true 'cmd: <bin> debug paths (isolado); config resolve no TargetHome'

  # ---- 3. servidor privado ----
  $freePort = Get-SpikeFreePort
  $freePortUsed = $freePort
  $script:freePortUsed = $freePort
  $sp = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('service', 'set', 'port', "$freePort") -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000
  if ([bool]$sp.TimedOut) { Fail-Smoke 'service set port: TIMEOUT 30s.' }
  if ([int]$sp.ExitCode -ne 0) { Fail-Smoke ('service set port: exit ' + $sp.ExitCode + ' (esperado 0).') }
  Add-SmokeCheck 'service_port_configured' $true ('cmd: <bin> service set port <livre> => ' + $freePort)

  # ---- 4. debug config (fontes + warmup do servico) ----
  $dc = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('debug', 'config') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000
  if ([bool]$dc.TimedOut) { Fail-Smoke 'debug config: TIMEOUT 30s (servico nao subiu na porta privada?).' }
  if ([int]$dc.ExitCode -ne 0) { Fail-Smoke ('debug config: exit ' + $dc.ExitCode + ' (esperado 0; config possivelmente invalida).') }
  $dcNorm = (($dc.Stdout + "`n" + $dc.Stderr).Replace('\\', '\'))
  if (-not ($dcNorm.Contains($cfgPath) -or $dcNorm.Contains(($cfgPath -replace '\\', '/')))) { Fail-Smoke 'debug config: fixture opencode.json nao listada nas fontes.' }
  Add-SmokeCheck 'config_sources_listed' $true 'cmd: <bin> debug config (servidor privado); fixture listada'

  $st = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('service', 'status') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000
  if ([bool]$st.TimedOut) { Fail-Smoke 'service status: TIMEOUT 30s.' }
  if ([int]$st.ExitCode -ne 0) { Fail-Smoke ('service status: exit ' + $st.ExitCode + ' (esperado 0).') }
  $stText = ($st.Stdout + "`n" + $st.Stderr).Trim()
  if (-not ($stText.Contains('127.0.0.1:' + $freePort))) { Fail-Smoke ('service status: sem URL privada 127.0.0.1:' + $freePort + ' (obtido: ' + $stText + ').') }
  if ($stText.Contains('49374')) { Fail-Smoke 'service status: porta fixa 49374 em uso (isolamento quebrado).' }
  Add-SmokeCheck 'service_private_running' $true ('cmd: <bin> service status => ' + $stText)

  # ---- 5. debug agents: os 19 workers (+build) ----
  $wanted = @('build') + @($agentsExpected)
  $missing = @()
  $attempts = 0
  $lastRc = -1
  $agentsOk = $false
  for ($i = 1; $i -le 3; $i++) {
    if ($i -gt 1) { Start-Sleep -Seconds 3 }
    $da = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('debug', 'agents') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000
    $attempts = $i
    $lastRc = [int]$da.ExitCode
    if ([bool]$da.TimedOut) { continue }
    if ([int]$da.ExitCode -ne 0) { continue }
    $daText = $da.Stdout + "`n" + $da.Stderr
    $missing = @()
    foreach ($w in $wanted) {
      if (-not ($daText -match ('"id":\s*"' + [regex]::Escape($w) + '"'))) {
        $missing += $w
      }
    }
    if ($missing.Count -eq 0) { $agentsOk = $true; break }
  }
  if (-not $agentsOk) { Fail-Smoke ('debug agents: ids ausentes apos ' + $attempts + ' tentativa(s) (lastRc=' + $lastRc + '): ' + ($missing -join ',')) }
  Add-SmokeCheck 'agents_19_workers_loaded' $true ('cmd: <bin> debug agents ate 3x; 20/20 ids (build+19) em ' + $attempts + ' tentativa(s)')

  # ---- 6. plugin/mcp list (observados; rc=0 exigido, sem claim alem do visto) ----
  $pl = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('plugin', 'list') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000
  if ([bool]$pl.TimedOut) { Fail-Smoke 'plugin list: TIMEOUT 30s.' }
  if ([int]$pl.ExitCode -ne 0) { Fail-Smoke ('plugin list: exit ' + $pl.ExitCode + ' (esperado 0).') }
  $plText = ($pl.Stdout + "`n" + $pl.Stderr).Trim()
  if ($plText.Length -gt 500) { $plText = $plText.Substring(0, 500) }
  Add-SmokeCheck 'plugin_list_observed' $true ('cmd: <bin> plugin list (rc=0) => ' + $plText)
  [void]$smokeNotes.Add('plugin list observado sem claim de tool/hook: ambiente isolado sem plugins instalados; load de plugin V2 com tools permanece pendente de cenario dedicado.')

  $mc = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('mcp', 'list') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000
  if ([bool]$mc.TimedOut) { Fail-Smoke 'mcp list: TIMEOUT 30s.' }
  if ([int]$mc.ExitCode -ne 0) { Fail-Smoke ('mcp list: exit ' + $mc.ExitCode + ' (esperado 0).') }
  $mcText = ($mc.Stdout + "`n" + $mc.Stderr).Trim()
  if ($mcText.Length -gt 500) { $mcText = $mcText.Substring(0, 500) }
  Add-SmokeCheck 'mcp_list_observed' $true ('cmd: <bin> mcp list (rc=0) => ' + $mcText)

  # ---- 7. parada limpa ----
  $stp = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('service', 'stop') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000
  if ([bool]$stp.TimedOut) { Fail-Smoke 'service stop: TIMEOUT 30s.' }
  if ([int]$stp.ExitCode -ne 0) { Fail-Smoke ('service stop: exit ' + $stp.ExitCode + ' (esperado 0).') }
  Add-SmokeCheck 'service_stop_clean' $true 'cmd: <bin> service stop (servidor privado); rc=0'

  [void]$smokeNotes.Add('`models` nao tentado (exige providers/rede); sem chamadas pagas ou credenciais neste smoke.')
  [void]$smokeNotes.Add('Enforcement comportamental (allow/deny live) permanece manual_checklist_pending no spike v2-permissions; este smoke prova load/descoberta, nao enforcement.')

  $pass = [ordered]@{
    smoke = 'v2-ci-smoke'
    date = Get-SmokeEvidenceDate
    status = 'ok'
    binary = $binaryUsed
    expected_version = $ExpectedVersion
    version_exact = $true
    service_port = $freePort
    workers_expected = 19
    workers_loaded = @($wanted)
    isolation = 'XDG_CONFIG/DATA/STATE/CACHE + HOME/USERPROFILE no TargetHome; OPENCODE_CONFIG* removido do filho; cwd no TargetHome; stdin fechado'
    checks = @($smokeChecks)
    notes = @($smokeNotes)
  }
  Write-SmokeJsonAtomic $pass $EvidencePath
  Write-Host '[smoke-v2] PASS: config + 19 workers + plugin/mcp observados com OpenCode V2 real (servidor privado).'
  Write-Host ('[smoke-v2] evidencia em ' + $EvidencePath)
  exit 0
}
finally {
  if (-not [string]::IsNullOrWhiteSpace($script:binaryUsed)) {
    try {
      [void](Invoke-SpikeChild -FilePath $script:binaryUsed -ArgumentList @('service', 'stop') -EnvSet $stopEnv -EnvRemove $stopRemove -WorkingDirectory $TargetHome -TimeoutMs 30000)
    }
    catch { }
  }
}
