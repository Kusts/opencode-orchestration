<#!
.SYNOPSIS
    Smoke do ciclo de vida EXPLICITO do servico gerenciado V2 real (Phase 8, V3.1).
.DESCRIPTION
    Path de CI comprovado em Windows para o binario V2 exato, seguindo o padrao
    P22 (native-start-contract) provado na lane real de 2026-10-03: o servico
    gerenciado sobe e para de forma explicita e deterministica
    (set port -> start -> status -> stop owned -> settlement).

    Diferenca propositiva para scripts/ci/smoke-opencode-v2.ps1: este smoke
    NAO tenta o caminho implicito de startup (debug config), que apresenta
    intermitencia caracterizada experimentalmente no binario 2.0.18
    (7 hangs vs 5 passes no mesmo dia; debugcfg-hang-investigation.json;
    suspeita principal interna ao binario, nao comprovada). Aqui o servico e
    iniciado EXPLICITAMENTE via `service start`, o caminho que se mostrou
    estavel na lane real.

    Fluxo (home isolado EXCLUSIVO por execucao em TEMP; config global do
    usuario intocada; ambiente dos filhos LIMPO via -CleanEnvironment,
    mantendo apenas PATH/SystemRoot/ComSpec/PATHEXT/TEMP/TMP/PSModulePath):
      1. Resolve o binario (explicito, PATH com shim resolvido para .exe, ou
         binario do perfil V2) e exige versao EXATA via Test-SpikeExactVersion
         (regex ^opencode v2.0.18$; substring NAO vale).
      2. Constroi opencode.json com os 19 workers canonicos via
         scripts/runtime/lib/AgentTranslator.ps1.
      3. Isolamento: debug paths resolve config dentro do TargetHome.
      4. Preflight de porta (padrao P22, lib RuntimePortPreflight): porta
         privada livre exige Outcome PORT_FREE E ShouldStart (os dois);
         49374 explicitamente recusada na selecao; ocupada, reservada ou
         duvidosa => fail-closed (exit 1).
      5. Ciclo de vida explicito: service set port => service start (rc=0) =>
         listener observado como FATO via contrato EXATO da lib P22
         (Get-PreflightNetTCPListenerBounded: QuerySucceeded + Exists +
         OwningPID; consulta inconclusiva NUNCA conta como ausencia) em
         janela por DEADLINE absoluto de 30s (timeout de cada consulta =
         tempo restante, cap 10s), SEM claim de ownership/reuse (REUSE HOLD
         P22: OWNED nunca emitido) => service status (URL privada, sem
         49374; apenas fatos allowlisted na evidencia) => service stop owned
         (rc=0) => settlement (sem listener, por deadline; terminacao do
         processo NAO e afirmada).
      6. Invariantes: porta 49374 com o MESMO owner (ou ausente) nos
         snapshots antes/depois via QuerySucceeded/Exists/OwningPID (consulta
         inconclusiva => invariante falha, sem adivinhacao); nenhum PID
         preexistente ou externo terminado (stop e via CLI do servico,
         gated por Invoke-SpikeServiceStopIfOwned).
      7. Excecoes inesperadas => evidencia failed com date dinamico + exit 1
         (bloco catch dedicado); falha ao gravar evidencia => melhor esforco
         em arquivo sidecar e exit 1.

    Evidencia JSON 1:1 com os passos (so fatos observados, sem stdout/stderr
    bruto). O campo `date` e o carimbo da execucao (data do relogio na
    escrita da evidencia, formato yyyy-MM-dd), nunca um literal do script.

    Sem chamadas pagas, sem credenciais no ambiente dos filhos, sem modelo/
    API, sem rede (alem do listener local do proprio servico). Timeout ou
    falha => exit 1. PS 5.1 e PS7 compativel. ASCII only. Exit 0 = PASS;
    1 = FAIL.
.PARAMETER RepoRoot
    Raiz do repositorio do pacote. Default: dois niveis acima deste script.
.PARAMETER TargetHome
    Home isolado do smoke. Default: $env:RUNNER_TEMP\oo-v2lifecycle-<run-id>
    (CI) ou $env:TEMP\oo-v2lifecycle-<run-id> fora do CI, EXCLUSIVO por
    execucao. Se informado explicitamente e ja existir, FALHA (sem reuso).
.PARAMETER OpenCodeSpec
    Spec npm esperada (igualdade de versao). Default: @opencode/cli@2.0.18.
.PARAMETER BinaryPath
    Binario V2 explicito (.exe ou shim resolvivel; opcional; CI usa o PATH
    apos npm install -g).
.PARAMETER EvidencePath
    JSON de evidencia. Default:
    evidence/v3.1/kernel-hardening/v2-ci-smoke-lifecycle.json no repo.
#>
param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$TargetHome = '',
  [string]$OpenCodeSpec = '@opencode/cli@2.0.18',
  [string]$BinaryPath = '',
  [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'

# Bootstrap: resolucao de repo/libas fora do try principal tem tratamento
# proprio - falha aqui TAMBEM produz evidencia failed (r2-R6).
$bootstrapFailed = $false
$bootstrapMsg = ''
try {
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  }
  $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  . (Join-Path $RepoRoot 'scripts\runtime\lib\SpikeProcess.ps1')
  . (Join-Path $RepoRoot 'scripts\runtime\lib\AgentTranslator.ps1')
  . (Join-Path $RepoRoot 'scripts\runtime\lib\RuntimePortPreflight.ps1')
}
catch {
  $bootstrapFailed = $true
  $bootstrapMsg = $_.Exception.Message
}

# Versao OBRIGATORIA desta lane: fixada; spec divergente e recusada (SEC4).
$PinnedVersion = '2.0.18'
$ExpectedVersion = $PinnedVersion
$m = [regex]::Match($OpenCodeSpec, '(\d+)\.(\d+)\.(\d+)')
if ($m.Success -and (($m.Groups[1].Value + '.' + $m.Groups[2].Value + '.' + $m.Groups[3].Value) -ne $PinnedVersion)) {
  $bootstrapFailed = $true
  $bootstrapMsg = ('OpenCodeSpec incompativel com o pin desta lane (esperado ' + $PinnedVersion + '): ' + $OpenCodeSpec)
}

if ($bootstrapFailed) {
  $failPath = $EvidencePath
  if ([string]::IsNullOrWhiteSpace($failPath)) {
    $baseHome0 = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($baseHome0)) { $baseHome0 = [IO.Path]::GetTempPath() }
    $failPath = Join-Path $baseHome0 'v2-ci-smoke-lifecycle-failed.json'
  }
  try {
    $parent0 = Split-Path -Parent $failPath
    if (-not (Test-Path -LiteralPath $parent0 -PathType Container)) { New-Item -ItemType Directory -Path $parent0 -Force | Out-Null }
    $failed0 = [ordered]@{
      smoke = 'v2-ci-smoke-lifecycle'
      date = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
      status = 'failed'
      expected_version = $ExpectedVersion
      checks = @()
      notes = @()
      fail_detail = ('bootstrap: ' + $bootstrapMsg)
    }
    $tmp0 = $failPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($tmp0, ((($failed0 | ConvertTo-Json -Depth 6).TrimEnd() + "`n") -replace "`r`n", "`n" -replace "`r", "`n"), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp0 -Destination $failPath -Force
  }
  catch { }
  Write-Host ('[smoke-v2-lifecycle] FALHA (bootstrap): ' + $bootstrapMsg)
  exit 1
}

if ([string]::IsNullOrWhiteSpace($TargetHome)) {
  $baseHome = $env:RUNNER_TEMP
  if ([string]::IsNullOrWhiteSpace($baseHome)) { $baseHome = $env:TEMP }
  if ([string]::IsNullOrWhiteSpace($baseHome)) { $baseHome = [IO.Path]::GetTempPath() }
  $runId = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
  $TargetHome = Join-Path $baseHome ('oo-v2lifecycle-' + $runId)
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
  $EvidencePath = Join-Path $RepoRoot 'evidence\v3.1\kernel-hardening\v2-ci-smoke-lifecycle.json'
}

$smokeChecks = New-Object System.Collections.ArrayList
$smokeNotes = New-Object System.Collections.ArrayList
$script:binaryUsed = ''
$script:portUsed = 0
$script:owner49374Before = 'NOT_SAMPLED'
$script:isolationOk = $false
$script:portConfigured = $false
$script:startAttempted = $false
$script:exitDone = $false

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
  # escrita (yyyy-MM-dd). Nunca um literal fixo de data no script.
  return (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-Listener49374Fact {
  # Snapshot da porta 49374 (servico V2 default / AI Memory local) usando o
  # contrato EXATO da lib P22: QuerySucceeded obrigatoria; consulta
  # inconclusiva NUNCA e ausencia. Somente leitura; nunca altera nada.
  $c = Get-PreflightNetTCPListenerBounded -Port 49374 -TimeoutMs 10000
  if ($null -eq $c) { return 'QUERY_FAILED' }
  if (-not [bool]$c.QuerySucceeded) { return 'QUERY_FAILED' }
  if ([bool]$c.Exists -and $null -ne $c.OwningPID) { return [string]$c.OwningPID }
  if ([bool]$c.Exists) { return 'LISTEN_NO_PID' }
  return 'NONE'
}

function Write-FailEvidence([string]$Message) {
  Write-Host ('[smoke-v2-lifecycle] FALHA: ' + $Message)
  $failed = [ordered]@{
    smoke = 'v2-ci-smoke-lifecycle'
    date = Get-SmokeEvidenceDate
    status = 'failed'
    binary = $script:binaryUsed
    expected_version = $ExpectedVersion
    service_port = $script:portUsed
    port49374_owner_before = $script:owner49374Before
    port49374_owner_after = Get-Listener49374Fact
    checks = @($script:smokeChecks)
    notes = @($script:smokeNotes)
    fail_detail = $Message
  }
  try {
    Write-SmokeJsonAtomic $failed $EvidencePath
    Write-Host ('[smoke-v2-lifecycle] evidencia (failed) em ' + $EvidencePath)
  }
  catch {
    $sidecar = $EvidencePath + '.failed-' + [guid]::NewGuid().ToString('N') + '.json'
    try { Write-SmokeJsonAtomic $failed $sidecar } catch { }
    Write-Host ('[smoke-v2-lifecycle] evidencia principal inacessivel; sidecar: ' + $sidecar)
  }
}

function Fail-Smoke([string]$Message) {
  Write-FailEvidence $Message
  $script:exitDone = $true
  exit 1
}

function Resolve-LifecycleBinary([string]$Explicit, [string]$WantVersion) {
  # Resolve candidatos (.exe direto; shim .cmd/.ps1 resolvido via
  # Resolve-SpikeShimTarget; shim irresolvivel e descartado) e exige versao
  # EXATA (regex ^opencode v<versao>$ na saida completa).
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
    # Binario do perfil V2 provisionado (padrao do repo; no CI nao existe e
    # o PATH resolve). Versao exata continua obrigatoria para qualquer cando.
    $profileBin = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe'
    if ((Test-Path -LiteralPath $profileBin -PathType Leaf) -and (-not ($cands -contains $profileBin))) {
      [void]$cands.Add($profileBin)
    }
  }
  if ($cands.Count -eq 0) {
    Fail-Smoke ('binario opencode ausente (PATH e perfil); instale ' + $OpenCodeSpec + ' (ex.: npm install -g ' + $OpenCodeSpec + ' + postinstall oficial).')
  }
  foreach ($cand in $cands) {
    $exePath = [string]$cand
    $ext = [IO.Path]::GetExtension($exePath).ToLowerInvariant()
    if ($ext -ne '.exe') {
      $resolved = Resolve-SpikeShimTarget -ShimPath $exePath
      if ([string]::IsNullOrWhiteSpace($resolved)) { continue }  # shim irresolvivel: cando descartado (fail-closed)
      if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { continue }
      $exePath = $resolved
    }
    $vr = Invoke-SpikeChild -FilePath $exePath -ArgumentList @('--version') -TimeoutMs 30000 -CleanEnvironment -StdinNul
    if ([bool]$vr.TimedOut) { continue }
    if ([int]$vr.ExitCode -ne 0) { continue }
    $verText = ([string]$vr.Stdout + "`n" + [string]$vr.Stderr)
    if (-not (Test-SpikeExactVersion -Text $verText -Version $WantVersion)) { continue }
    $first = (([string]$verText -split "`r?`n" | Select-Object -First 1)).Trim()
    return @{ Path = $exePath; VersionLine = $first }
  }
  Fail-Smoke ('nenhum binario com versao exata ' + $WantVersion + ' (candidatos considerados: ' + ($cands -join ' | ') + ').')
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

function Wait-PrivateListener([string]$ExePath, [int]$Port, [hashtable]$Env, [string[]]$EnvRem, [string]$WorkDir, [int]$DeadlineSeconds, [ValidateSet('presence', 'absence')][string]$Mode) {
  # Observa o listener como FATO com o contrato EXATO da lib P22:
  # QuerySucceeded obrigatoria. Janela por DEADLINE absoluto; timeout de cada
  # consulta = tempo restante (cap 10s). Modo:
  #   presence => retorna na PRIMEIRA PRESENCA conclusiva (startup; ausencia
  #               conclusiva NAO encerra - bind pode ser tardio);
  #   absence  => retorna na PRIMEIRA AUSENCIA conclusiva (settlement).
  # Consulta falha nunca decide: apenas conta em InconclusiveCount.
  $deadline = [DateTime]::UtcNow.AddSeconds($DeadlineSeconds)
  $seen = $false
  $absent = $false
  $inconclusiveCount = 0
  $pidSeen = ''
  $nameSeen = ''
  $pathMatch = $false
  while ([DateTime]::UtcNow -lt $deadline) {
    $remainingMs = [int]([DateTime]::UtcNow - $deadline).TotalMilliseconds * -1
    if ($remainingMs -gt 10000) { $remainingMs = 10000 }
    if ($remainingMs -lt 500) { $remainingMs = 500 }
    $ln = Get-PreflightNetTCPListenerBounded -Port $Port -TimeoutMs $remainingMs
    if ($null -ne $ln -and [bool]$ln.QuerySucceeded) {
      if ([bool]$ln.Exists -and $null -ne $ln.OwningPID) {
        $pidSeen = [string]$ln.OwningPID
        $ident = Get-PreflightProcessIdentity -OwnerPID ([int]$ln.OwningPID)
        $nameSeen = [string]$ident.Name
        $lp = [string]$ident.Path
        if (-not [string]::IsNullOrWhiteSpace($lp)) {
          $pathMatch = $lp.StartsWith($ExePath, [StringComparison]::OrdinalIgnoreCase)
        }
        $seen = $true
        if ($Mode -eq 'presence') { break }
      }
      elseif ([bool]$ln.Exists) {
        $inconclusiveCount++
      }
      else {
        $absent = $true
        if ($Mode -eq 'absence') { break }
      }
    }
    else {
      $inconclusiveCount++
    }
    Start-Sleep -Milliseconds 1000
  }
  return [ordered]@{ Seen = $seen; Absent = $absent; InconclusiveCount = $inconclusiveCount; Pid = $pidSeen; Name = $nameSeen; PathMatch = $pathMatch }
}

Write-Host ('[smoke-v2-lifecycle] RepoRoot=' + $RepoRoot)
Write-Host ('[smoke-v2-lifecycle] TargetHome=' + $TargetHome)
Write-Host ('[smoke-v2-lifecycle] OpenCodeSpec=' + $OpenCodeSpec + ' (versao exata exigida: ' + $ExpectedVersion + ')')

if (Test-Path -LiteralPath $TargetHome) {
  # Home EXCLUSIVO por execucao: reuso de home de outra execucao (ou
  # preexistente) e recusado (cleanup de stop nunca deve mirar servico alheio).
  Fail-Smoke ('TargetHome ja existe: ' + $TargetHome + ' (use um home novo por execucao).')
}

try {
  # ---- 0. home isolado + invariante 49374: snapshot ANTES (so leitura) ----
  New-Item -ItemType Directory -Path $TargetHome -Force | Out-Null
  $xdg = Join-Path $TargetHome 'xdg'
  $xdgData = Join-Path $TargetHome 'xdg-data'
  $xdgState = Join-Path $TargetHome 'xdg-state'
  $xdgCache = Join-Path $TargetHome 'xdg-cache'
  $homeT = Join-Path $TargetHome 'home'
  $cwdT = Join-Path $TargetHome 'cwd'
  foreach ($d in @($xdg, $xdgData, $xdgState, $xdgCache, $homeT, $cwdT)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
  }
  $isoEnv = @{
    XDG_CONFIG_HOME = $xdg
    XDG_DATA_HOME = $xdgData
    XDG_STATE_HOME = $xdgState
    XDG_CACHE_HOME = $xdgCache
    HOME = $homeT
    USERPROFILE = $homeT
  }
  $isoRemove = @('OPENCODE_CONFIG', 'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_CONTENT')

  $script:owner49374Before = Get-Listener49374Fact
  Write-Host ('[smoke-v2-lifecycle] port49374 antes: ' + $script:owner49374Before)

  # ---- 1. binario exato (mandatorio; sem skip) ----
  $res = Resolve-LifecycleBinary $BinaryPath $ExpectedVersion
  $binaryUsed = [string]$res.Path
  $script:binaryUsed = $binaryUsed
  Write-Host ('[smoke-v2-lifecycle] binario: ' + $binaryUsed + ' (' + [string]$res.VersionLine + ')')
  Add-SmokeCheck 'version_exact' $true ('cmd: <bin> --version (-CleanEnvironment); Test-SpikeExactVersion ' + $ExpectedVersion + '; obtido: ' + [string]$res.VersionLine)

  # ---- 2. config com os 19 workers canonicos ----
  $agentsDir = Join-Path $RepoRoot 'source\agents'
  $cfgPath = Join-Path $xdg 'opencode\opencode.json'
  $stems = @(New-SmokeConfig $cfgPath $agentsDir)
  Add-SmokeCheck 'config_19_workers_built' ($stems.Count -eq 19) ('opencode.json gerado via AgentTranslator com ' + $stems.Count + ' workers (esperado 19)')
  if ($stems.Count -ne 19) { Fail-Smoke ('workers canonicos <> 19 (obtido ' + $stems.Count + ')') }

  # ---- 3. isolamento ----
  $dp = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('debug', 'paths') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
  if ([bool]$dp.TimedOut) { Fail-Smoke 'debug paths: TIMEOUT 30s (binario nao responde isolado).' }
  if ([int]$dp.ExitCode -ne 0) { Fail-Smoke ('debug paths: exit ' + $dp.ExitCode + ' (esperado 0).') }
  $dpText = $dp.Stdout + "`n" + $dp.Stderr
  if (-not ($dpText.Contains($xdg) -or $dpText.Contains(($xdg -replace '\\', '/')))) { Fail-Smoke 'debug paths: config nao resolve dentro do home isolado.' }
  $script:isolationOk = $true
  Add-SmokeCheck 'isolation_paths' $true 'cmd: <bin> debug paths (isolado, -CleanEnvironment); config resolve no TargetHome'

  # ---- 4. preflight de porta (padrao P22; PORT_FREE E ShouldStart; 49374 recusada) ----
  $freePort = 0
  for ($try = 0; $try -lt 10; $try++) {
    $cand = Get-SpikeFreePort
    if ($cand -ne 49374) { $freePort = $cand; break }
  }
  if ($freePort -eq 0) { Fail-Smoke 'selecao de porta livre: 10 tentativas cairam em 49374 (recusada); abortado.' }
  $script:portUsed = $freePort
  $pf = Invoke-PreflightPort -Port $freePort -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @($binaryUsed) -ExpectedProfileDir $TargetHome
  $pfOutcome = [string]$pf.Outcome
  $pfShouldStart = [bool]$pf.ShouldStart
  Write-Host ('[smoke-v2-lifecycle] preflight ' + $freePort + ' => ' + $pfOutcome + ' (should_start=' + $pfShouldStart + ')')
  Add-SmokeCheck 'port_preflight_free' (($pfOutcome -eq 'PORT_FREE') -and $pfShouldStart) ('cmd: Invoke-PreflightPort (lib P22) na porta ' + $freePort + ' => ' + $pfOutcome + ' should_start=' + $pfShouldStart)
  if (($pfOutcome -ne 'PORT_FREE') -or (-not $pfShouldStart)) { Fail-Smoke ('preflight: porta ' + $freePort + ' nao esta livre/autorizada (' + $pfOutcome + ' should_start=' + $pfShouldStart + '); fail-closed.') }

  # ---- 5. ciclo de vida explicito do servico gerenciado ----
  $sp = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('service', 'set', 'port', "$freePort") -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
  if ([bool]$sp.TimedOut) { Fail-Smoke 'service set port: TIMEOUT 30s.' }
  if ([int]$sp.ExitCode -ne 0) { Fail-Smoke ('service set port: exit ' + $sp.ExitCode + ' (esperado 0).') }
  $script:portConfigured = $true
  Add-SmokeCheck 'service_port_configured' $true ('cmd: <bin> service set port => ' + $freePort + ' (rc=0)')

  $sst = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('service', 'start') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
  $script:startAttempted = $true
  if ([bool]$sst.TimedOut) { Fail-Smoke 'service start: TIMEOUT 30s.' }
  if ([int]$sst.ExitCode -ne 0) { Fail-Smoke ('service start: exit ' + $sst.ExitCode + ' (esperado 0).') }
  Add-SmokeCheck 'service_start_explicit' $true 'cmd: <bin> service start (rc=0; -CleanEnvironment)'

  # Listener observado como FATO (contrato exato da lib; SEM claim OWNED/REUSE).
  # Modo presence: ausencia conclusiva NAO encerra (bind tardio continua na janela).
  $obs = Wait-PrivateListener -ExePath $binaryUsed -Port $freePort -Env $isoEnv -EnvRem $isoRemove -WorkDir $cwdT -DeadlineSeconds 30 -Mode presence
  $listenerSeen = [bool]$obs.Seen
  Add-SmokeCheck 'service_listener_observed' $listenerSeen ('listener porta ' + $freePort + ' (deadline 30s): seen=' + $listenerSeen + ' ausente_conclusiva=' + [bool]$obs.Absent + ' consultas_inconclusivas=' + [int]$obs.InconclusiveCount + ' pid=' + $obs.Pid + ' name=' + $obs.Name + ' path_prefix_match=' + [bool]$obs.PathMatch + ' (fato observado, sem claim OWNED - REUSE HOLD P22)')
  if (-not $listenerSeen) {
    $diagSt = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('service', 'status') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
    $diagUrl = ([string]$diagSt.Stdout + "`n" + [string]$diagSt.Stderr).Contains('127.0.0.1:' + $freePort)
    $why = 'nunca visto em consultas concluidas (ausencia real)'
    if ([int]$obs.InconclusiveCount -gt 0) { $why = 'nenhuma consulta conclusiva dentro do deadline (sobrecarga?)' }
    Fail-Smoke ('service start: rc=0 mas sem listener na porta ' + $freePort + ' apos deadline 30s (' + $why + '). diagnostico service status: rc=' + $diagSt.ExitCode + ' url_privada_presente=' + $diagUrl)
  }

  $st = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('service', 'status') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
  if ([bool]$st.TimedOut) { Fail-Smoke 'service status: TIMEOUT 30s.' }
  if ([int]$st.ExitCode -ne 0) { Fail-Smoke ('service status: exit ' + $st.ExitCode + ' (esperado 0).') }
  $stText = ([string]$st.Stdout + "`n" + [string]$st.Stderr)
  $hasPrivateUrl = $stText.Contains('127.0.0.1:' + $freePort)
  $has49374 = $stText.Contains('49374')
  Add-SmokeCheck 'service_private_running' ($hasPrivateUrl -and (-not $has49374)) ('cmd: <bin> service status (rc=0): url_privada=' + $hasPrivateUrl + ' menciona_49374=' + $has49374 + ' (fatos allowlisted, sem stdout bruto)')
  if (-not $hasPrivateUrl) { Fail-Smoke ('service status: sem URL privada 127.0.0.1:' + $freePort + '.') }
  if ($has49374) { Fail-Smoke 'service status: porta fixa 49374 em uso (isolamento quebrado).' }

  $stp = Invoke-SpikeChild -FilePath $binaryUsed -ArgumentList @('service', 'stop') -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
  if ([bool]$stp.TimedOut) { Fail-Smoke 'service stop: TIMEOUT 30s.' }
  if ([int]$stp.ExitCode -ne 0) { Fail-Smoke ('service stop: exit ' + $stp.ExitCode + ' (esperado 0).') }
  Add-SmokeCheck 'service_stop_owned' $true 'cmd: <bin> service stop (rc=0; sem kill de PID)'

  # ---- 6. settlement: ausencia CONCLUSIVA do listener (terminacao NAO afirmada) ----
  $settleObs = Wait-PrivateListener -ExePath $binaryUsed -Port $freePort -Env $isoEnv -EnvRem $isoRemove -WorkDir $cwdT -DeadlineSeconds 30 -Mode absence
  $settled = [bool]$settleObs.Absent
  Add-SmokeCheck 'service_settlement' $settled ('apos stop (deadline 30s): ausente_conclusiva=' + [bool]$settleObs.Absent + ' ainda_presente=' + [bool]$settleObs.Seen + ' consultas_inconclusivas=' + [int]$settleObs.InconclusiveCount + ' (terminacao do processo NAO afirmada)')
  if (-not $settled) {
    $why = 'listener AINDA presente dentro do deadline'
    if (-not $settleObs.Seen) { $why = 'nenhuma consulta conclusiva dentro do deadline (sobrecarga?)' }
    Fail-Smoke ('settlement: ' + $why + ' na porta ' + $freePort + ' apos stop.')
  }

  # ---- 7. invariante 49374: snapshot DEPOIS igual ao ANTES ----
  $owner49374After = Get-Listener49374Fact
  $invariantOk = (($owner49374After -eq $script:owner49374Before) -and ($owner49374After -ne 'QUERY_FAILED'))
  Add-SmokeCheck 'port49374_untouched' $invariantOk ('owner antes=' + $script:owner49374Before + ' depois=' + $owner49374After + ' (nunca iniciada nem alterada; QUERY_FAILED falha o invariante)')
  if (-not $invariantOk) { Fail-Smoke ('invariante 49374: antes=' + $script:owner49374Before + ' depois=' + $owner49374After) }

  [void]$smokeNotes.Add('caminho implicito de startup (debug config) NAO tentado aqui: flake upstream caracterizado no 2.0.18 (debugcfg-hang-investigation.json); este smoke prova o ciclo explicito do servico gerenciado (padrao P22).')
  [void]$smokeNotes.Add('nenhum PID preexistente ou externo terminado; stop e via CLI do servico; home isolado EXCLUSIVO em TEMP; ambiente dos filhos limpo (-CleanEnvironment); nenhuma flag ativada.')

  $pass = [ordered]@{
    smoke = 'v2-ci-smoke-lifecycle'
    date = Get-SmokeEvidenceDate
    status = 'ok'
    binary = $binaryUsed
    expected_version = $ExpectedVersion
    version_exact = $true
    service_port = $freePort
    preflight_outcome = $pfOutcome
    listener_observed = [ordered]@{ pid = [string]$obs.Pid; name = [string]$obs.Name; path_prefix_match = [bool]$obs.PathMatch }
    port49374_owner_before = $script:owner49374Before
    port49374_owner_after = $owner49374After
    isolation = 'XDG_CONFIG/DATA/STATE/CACHE + HOME/USERPROFILE no TargetHome exclusivo; -CleanEnvironment nos filhos (so PATH/SystemRoot/ComSpec/PATHEXT/TEMP/TMP/PSModulePath); cwd no TargetHome; stdin fechado'
    checks = @($smokeChecks)
    notes = @($smokeNotes)
  }
  Write-SmokeJsonAtomic $pass $EvidencePath
  Write-Host '[smoke-v2-lifecycle] PASS: ciclo de vida explicito do servico V2 real (set/start/status/stop owned + settlement) no binario exato.'
  Write-Host ('[smoke-v2-lifecycle] evidencia em ' + $EvidencePath)
  $script:exitDone = $true
  exit 0
}
catch {
  if (-not $script:exitDone) {
    Write-FailEvidence ('excecao inesperada: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage)
    $script:exitDone = $true
    exit 1
  }
  throw
}
finally {
  # Stop OWNED e gated: so tenta se isolamento provado + porta configurada +
  # start tentado; o helper verifica o endpoint privado ANTES de parar
  # (nunca para servico de outra execucao; nunca kill de PID).
  if ((-not [string]::IsNullOrWhiteSpace($script:binaryUsed)) -and $script:isolationOk -and $script:portConfigured -and $script:portUsed -gt 0) {
    try {
      $cl = Invoke-SpikeServiceStopIfOwned -FilePath $script:binaryUsed -EnvSet $isoEnv -EnvRemove $isoRemove -WorkingDirectory $cwdT -IsolationProved $script:isolationOk -PortConfigured $script:portConfigured -Port $script:portUsed -WarmupAttempted $script:startAttempted -TimeoutMs 30000 -CleanEnvironment -StdinNul
      Write-Host ('[smoke-v2-lifecycle] cleanup: ' + [string]$cl.Reason)
      $sidecar = $EvidencePath + '.cleanup.json'
      try {
        Write-SmokeJsonAtomic ([ordered]@{ smoke = 'v2-ci-smoke-lifecycle'; date = (Get-SmokeEvidenceDate); cleanup = [ordered]@{ attempted = [bool]$cl.Attempted; stopped = [bool]$cl.Stopped; reason = [string]$cl.Reason } }) $sidecar
      }
      catch { }
    }
    catch {
      $sidecar = $EvidencePath + '.cleanup.json'
      try {
        Write-SmokeJsonAtomic ([ordered]@{ smoke = 'v2-ci-smoke-lifecycle'; date = (Get-SmokeEvidenceDate); cleanup = [ordered]@{ attempted = $false; stopped = $false; reason = ('excecao no cleanup: ' + $_.Exception.Message) } }) $sidecar
      }
      catch { }
    }
  }
}
