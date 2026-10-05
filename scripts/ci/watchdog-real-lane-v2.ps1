<#!
.SYNOPSIS
    Lane real V2 dos cenarios RR-E2E-04..10 (watchdog + kernel) com processos
    REAIS, deadlines REAIS e tasks REAIS do kernel.
.DESCRIPTION
    Harness de lane (RR-E2E-LANE-04-10). Nao fecha o release gate e nao
    reclassifica cenarios: source/registry/e2e-scenarios.json continua
    descrevendo o que a prova EXIGE; esta lane fornece apenas a EXECUCAO real
    e a evidencia datada.

    Fluxo (padrao lifecycle-smoke, scripts/ci/smoke-opencode-v2-lifecycle.ps1):
      0. Gates de lane (fail-closed, TODOS antes de qualquer cenario):
         arvore LIMPA dentro dos write scopes desta lane
         (clean_tree_within_lane_scopes: EXATAMENTE o mesmo mecanismo do
         cenario 04, Test-OrchestrationWriteScope, com untracked contando;
         fora de escopo OU scope check nao comprovaravel => lane BLOCKED
         com os paths contaminantes, porque um step anterior do job que
         sujou o checkout faria o cenario 04 virar
         skipped-out-of-scope => verified_pass=false =>
         COMPLETION_GATE_FAILED), binario V2 EXATO (pin do registry unico
         source/registry/runtime-versions.json), home isolado EXCLUSIVO em TEMP,
         snapshot da porta 49374 ANTES (leitura pura), gate do watchdog
         ENFORCE lido do registro canonico (nenhuma flag escrita),
         ciclo de vida EXPLICITO do servico V2 (set/start/status/stop owned +
         settlement) e snapshot 49374 DEPOIS com o MESMO owner.
         Falha em qualquer gate => lane BLOCKED honesta: nenhum cenario roda,
         todos ficam not-run com a causa, exit 1.
      1. Cenarios 04..10, no maximo 1 TENTATIVA por cenario (nunca repetir em
         falha). Workers = processos reais (filhos DIRETOS do processo do
         harness, exigidos pela prova de parentage CIM-proven da lib do
         watchdog) iniciados com o handle do proprio spawn e atribuidos ao
         Job Object da lane (Add-RuntimeJobProcess): a contencao e a mesma do
         padrao P22 e o backstop alcanca SOMENTE spawns proprios. Todas as
         chamadas CLI acotadas (servico V2, kernel) passam por Invoke-SpikeChild
         com -CleanEnvironment e stdin fechado, com o job no `service start`.
         Ambiente dos workers: MINIMO CONSTRUIDO (nao herdado) - lista base igual
         a do -CleanEnvironment do Invoke-SpikeChild (PATH, SystemRoot, WINDIR,
         ComSpec, PATHEXT, TEMP, TMP, PSModulePath) mais apenas o estritamente
         necessario ao cenario (TEMP/TMP apontados para o workRoot isolado
         desta execucao). Nenhuma credencial do ambiente do operador chega ao
         filho.
      2. Evidencia: um JSON por cenario em
         evidence/v3.1/runtime-reliability/v2-lane-2026-10-04/watchdog/ e
         lane-summary.json no mesmo padrao do precedente de 2026-10-03
         (converted_to_real_evidence SO para o que passou de fato; resto
         partial/blocked/failed com causa; no_fake_close=true). A evidencia
         do smoke de lifecycle que roda ANTES desta lane e' EFEMERA por
         default (fora do checkout), entao a arvore chega limpa ao gate 0.

    Cenarios (source/registry/e2e-scenarios.json, ordinals 4-10):
      04 Worker normal completion: task real do kernel (CLI), tentativa real,
          worker real com termino normal (exit 0), candidate_pass gravado e
          tentativa de terminal real via Complete-OrchestrationTask. O
          verified_pass do gate de DONE so vem de verifier allowlisted real
          (Invoke-OrchestrationVerifier + profile canonico); se o escopo ou o
          profile nao cobrir, o cenario fica partial com a razao REAL, nunca
          verde forjado.
      05 Worker hard hang: worker real ultrapassa HARD_TIMEOUT real =>
          interrupt real => PID morto (fato observado).
      06 No-progress stall: worker vivo sem progresso ate NO_PROGRESS real.
      07 Repeated identical action: acoes REAIS do worker (log JSONL do
          proprio processo) alimentadas ao avaliador com o contrato de
          identidade da lib => REPEATED_ACTION => interrupt => PID morto.
      08 Repeated short cycle: acoes REAIS alternando A,B,A,B => REPEATED_CYCLE
          => interrupt => PID morto.
      09 Interrupt failure: interrupt e deadline REAIS contra arvore owned viva;
          a nao-settlement e INJETADA pelo seam test-only documentado da lib
          (-FaultInject stop_failure, conjunto fechado da propria lib). O
          artefato diz isso explicitamente: nao-settlement injetado (seam de
          teste); interrupt e deadline reais.
      10 Sibling completes while one child hangs: dois workers reais; um
          completa (exit 0) enquanto o outro esta em hang; o hang morre pelo
          interrupt e o sibling nunca e morto pelo watchdog.

    Doctrina de prova: o harness afirma OUTCOMES observados (classificacao,
    interrupted, settlement, PID morto/vivo, estado do task no kernel, exit
    code do worker). NUNCA afirma internos do enforcement (outro worker possui o
    wiring de Job Objects no enforcement): o harness nao inspeciona qual
    caminho interno matou o processo.

    Exit codes: 0 somente quando os SETE cenarios foram pass-real. Qualquer
    partial/blocked/failed => exit 1 (vermelho honesto; um cenario nao provado
    nunca vira verde). PS 5.1 compativel. ASCII only. Sem rede, sem modelo
    pago, sem credencial no ambiente dos filhos, sem ativacao de flag.
.PARAMETER RepoRoot
    Raiz do repositorio. Default: dois niveis acima deste script.
.PARAMETER TargetHome
    Home isolado EXCLUSIVO desta execucao. Default: TEMP\oo-wdlane-<run-id>.
.PARAMETER OpenCodeSpec
    Spec npm esperada (igualdade de versao). Vazio (default) = pin do
    registry unico source/registry/runtime-versions.json (runtimes.v2);
    valor explicito = override (divergente do pin e recusado).
.PARAMETER BinaryPath
    Binario V2 explicito (.exe). Opcional.
.PARAMETER EvidenceRoot
    Raiz dos artefatos desta lane. Default:
    evidence/v3.1/runtime-reliability/v2-lane-2026-10-04.
.PARAMETER ScenarioFilter
    Ordinais separados por virgula. Default: 04,05,06,07,08,09,10.
#>
param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$TargetHome = '',
  [string]$OpenCodeSpec = '',
  [string]$BinaryPath = '',
  [string]$EvidenceRoot = '',
  [string]$ScenarioFilter = '04,05,06,07,08,09,10'
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Bootstrap (falha aqui tambem produz evidencia honesta)
# ---------------------------------------------------------------------------
$script:Lane = [ordered]@{
  lane = 'v3.1-watchdog-real-lane-v2'
  date = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  started_at = (Get-Date).ToUniversalTime().ToString('o')
  binary = ''
  version_line = ''
  gate = [ordered]@{ checks = (New-Object System.Collections.ArrayList); failed = '' }
  scenarios = @()
  blocked_reason = ''
}
$script:LaneResults = New-Object System.Collections.ArrayList
$script:KernelCalls = New-Object System.Collections.ArrayList
$script:owner49374Before = 'NOT_SAMPLED'
$script:isoEnv = $null
$script:isoRemove = @()
$script:cwdT = ''
$script:workRoot = ''
$script:teleRoot = ''
$script:laneJob = $null
$script:binaryUsed = ''
$script:portUsed = 0
$script:serviceStarted = $false
$script:portConfigured = $false
$script:isolationOk = $false
$script:finalResult = $null
$script:repoPolicy = ''
$script:repoFlags = ''
$script:tasksRoot = ''
$script:resolvedEvidenceDir = ''
$script:scenarioEvidenceDir = ''
$script:workerScript = ''
$script:hostExe = ''
$script:hostIsWinPs = $false

function Get-LaneDate {
  return (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

function Write-LaneJsonAtomic($Object, [string]$TargetPath) {
  $parent = Split-Path -Parent $TargetPath
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $tmp = $TargetPath + '.tmp-' + [guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllText($tmp, ((($Object | ConvertTo-Json -Depth 12).TrimEnd() + "`n") -replace "`r`n", "`n" -replace "`r", "`n"), (New-Object Text.UTF8Encoding $false))
  Move-Item -LiteralPath $tmp -Destination $TargetPath -Force
}

function Write-LaneText([string]$Text) {
  Write-Host ('[wd-lane] ' + $Text)
}

# Write scopes desta lane (FONTE UNICA). O gate inicial
# clean_tree_within_lane_scopes e o cenario 04 consomem EXATAMENTE esta lista:
# um unico contrato de escopo, sem lista paralela que possa divergir.
$script:laneWriteScopes = @(
  'scripts/ci/watchdog-real-lane-v2.ps1',
  'evidence/v3.1/runtime-reliability/v2-lane-2026-10-04',
  '.github/workflows/ci.yml'
)

function Add-LaneGate([string]$Name, [bool]$Passed, [string]$Detail) {
  # F2(b): saneia o detail NO PONTO MAIS CEDO possivel. Assim lane-summary.json,
  # o estado $script:Lane e lane-run.json herdam o texto limpo, sem depender de
  # cada consumidor lembrar de sanear (o detail pode conter path de policy/flags).
  $safeDetail = (Get-LaneSafeText -Text $Detail -MaxChars 400)
  [void]$script:Lane.gate.checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $safeDetail })
  if (-not $Passed -and [string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    $script:Lane.gate.failed = (Get-LaneSafeText -Text ($Name + ': ' + $Detail) -MaxChars 600)
  }
}

# ---------------------------------------------------------------------------
# Facts de porta (contrato exato da lib P22: QuerySucceeded obrigatoria)
# ---------------------------------------------------------------------------
function Get-ListenerFact([int]$Port) {
  $c = Get-PreflightNetTCPListenerBounded -Port $Port -TimeoutMs 10000
  if ($null -eq $c) { return 'QUERY_FAILED' }
  if (-not [bool]$c.QuerySucceeded) { return 'QUERY_FAILED' }
  if ([bool]$c.Exists -and $null -ne $c.OwningPID) { return [string]$c.OwningPID }
  if ([bool]$c.Exists) { return 'LISTEN_NO_PID' }
  return 'NONE'
}

# ---------------------------------------------------------------------------
# S-1: saneamento de paths e de mensagens de excecao na EVIDENCIA
# ---------------------------------------------------------------------------
function Get-LaneSafePath([string]$Path) {
  # Persiste caminho RELATIVO ao repo quando o path estiver dentro do repo;
  # dentro do home isolado da lane vira <lane-home>/...; fora disso vira
  # <external>/<leaf>. Nenhum caminho absoluto do usuario chega ao artefato.
  $p = ''
  try { $p = ([string]$Path).Trim() } catch { $p = '' }
  if ([string]::IsNullOrWhiteSpace($p)) { return '' }
  $root = ''
  try { $root = ([string]$RepoRoot).Trim().TrimEnd('\') } catch { $root = '' }
  if ((-not [string]::IsNullOrWhiteSpace($root)) -and ($p.StartsWith($root, [StringComparison]::OrdinalIgnoreCase))) {
    $rel = $p.Substring($root.Length).TrimStart('\', '/')
    if ([string]::IsNullOrWhiteSpace($rel)) { return '<repo>' }
    return ('<repo>/' + ($rel -replace '\\', '/'))
  }
  $lane = ''
  try { $lane = ([string]$TargetHome).Trim().TrimEnd('\') } catch { $lane = '' }
  if ((-not [string]::IsNullOrWhiteSpace($lane)) -and ($p.StartsWith($lane, [StringComparison]::OrdinalIgnoreCase))) {
    $rel = $p.Substring($lane.Length).TrimStart('\', '/')
    return ('<lane-home>/' + ($rel -replace '\\', '/'))
  }
  # Path RELATIVO (sem raiz): as libs do repo (ex.: Get-VerifierNormalizedPath)
  # devolvem paths relativos ao repo com barra '/'. Nenhum prefixo de raiz
  # absoluta casa, entao antes do fallback <external> tratamos como repo-relative;
  # o fallback descartaria o diretorio e viraria <external>/<leaf>, perdendo o
  # diagnostico (ex.: 'CHANGELOG.md' virava '<external>/CHANGELOG.md').
  $isRooted = $true
  try { $isRooted = [IO.Path]::IsPathRooted($p) } catch { $isRooted = $true }
  if ((-not $isRooted) -and (-not [string]::IsNullOrWhiteSpace($p))) {
    $relPath = ($p -replace '\\', '/').TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($relPath)) { return '<repo>' }
    return ('<repo>/' + $relPath)
  }
  return ('<external>/' + [IO.Path]::GetFileName($p))
}

function Get-LaneSafeError($ErrorRecord, [int]$MaxChars = 200) {
  # S-1: tipo + mensagem CURTA sanitizada. Nao persiste PositionMessage (contem
  # caminho de arquivo/linha do harness) nem a mensagem bruta (pode embutir
  # path absoluto do usuario). O segredo literal nunca e' escrito aqui.
  $typeName = ''
  $msg = ''
  try { $typeName = [string]$ErrorRecord.Exception.GetType().Name } catch { $typeName = 'Exception' }
  if ([string]::IsNullOrWhiteSpace($typeName)) { $typeName = 'Exception' }
  try { $msg = ([string]$ErrorRecord.Exception.Message) } catch { $msg = '' }
  $safe = Get-LaneSafeText -Text $msg
  if ([string]::IsNullOrWhiteSpace($safe)) { return ([string]$typeName + ' (sem mensagem)') }
  if ($safe.Length -gt [int]$MaxChars) { $safe = $safe.Substring(0, [int]$MaxChars) + '...' }
  return ([string]$typeName + ': ' + $safe)
}

function Get-LaneSafeText([string]$Text, [int]$MaxChars = 600) {
  # Neutraliza caminhos absolutos (repo, lane-home, drive) dentro de texto livre
  # (gate details, worker job_note, mensagens de libs) antes de persistir.
  $s = ''
  try { $s = ([string]$Text) } catch { $s = '' }
  if ([string]::IsNullOrWhiteSpace($s)) { return '' }
  $lane = ''
  try { $lane = ([string]$TargetHome).Trim().TrimEnd('\') } catch { $lane = '' }
  if ((-not [string]::IsNullOrWhiteSpace($lane)) -and $s.Contains($lane)) {
    $s = $s.Replace($lane, '<lane-home>')
  }
  $root = ''
  try { $root = ([string]$RepoRoot).Trim().TrimEnd('\') } catch { $root = '' }
  if ((-not [string]::IsNullOrWhiteSpace($root)) -and $s.Contains($root)) {
    $s = $s.Replace($root, '<repo>')
  }
  $prof = ''
  try { $prof = ([string]$env:USERPROFILE).Trim().TrimEnd('\') } catch { $prof = '' }
  if ((-not [string]::IsNullOrWhiteSpace($prof)) -and $s.Contains($prof)) {
    $s = $s.Replace($prof, '<user-profile>')
  }
  $tmpBase = ''
  try { $tmpBase = ([IO.Path]::GetTempPath()).TrimEnd('\') } catch { $tmpBase = '' }
  if ((-not [string]::IsNullOrWhiteSpace($tmpBase)) -and $s.Contains($tmpBase)) {
    $s = $s.Replace($tmpBase, '<temp>')
  }
  # qualquer outro caminho absoluto sobrevivente vira <external>/<leaf>
  try {
    $rx = [regex]'(?i)([A-Z]:\\[^:"<>|?*\r\n]{2,})'
    foreach ($m in @($rx.Matches($s))) {
      $hit = $m.Groups[1].Value
      if ([string]::IsNullOrWhiteSpace($hit)) { continue }
      $s = $s.Replace($hit, ('<external>/' + [IO.Path]::GetFileName($hit)))
    }
  }
  catch { }
  if ($s.Length -gt [int]$MaxChars) { $s = $s.Substring(0, [int]$MaxChars) + '...' }
  return $s
}

function Wait-PrivateListenerState([int]$Port, [int]$DeadlineSeconds, [ValidateSet('presence', 'absence')][string]$Mode) {
  $deadline = [DateTime]::UtcNow.AddSeconds($DeadlineSeconds)
  $seen = $false
  $absent = $false
  $inconclusive = 0
  $pidSeen = ''
  while ([DateTime]::UtcNow -lt $deadline) {
    $remainingMs = [int]([DateTime]::UtcNow - $deadline).TotalMilliseconds * -1
    if ($remainingMs -gt 10000) { $remainingMs = 10000 }
    if ($remainingMs -lt 500) { $remainingMs = 500 }
    $ln = Get-PreflightNetTCPListenerBounded -Port $Port -TimeoutMs $remainingMs
    if (($null -ne $ln) -and [bool]$ln.QuerySucceeded) {
      if ([bool]$ln.Exists -and $null -ne $ln.OwningPID) {
        $seen = $true
        $pidSeen = [string]$ln.OwningPID
        if ($Mode -eq 'presence') { break }
      }
      elseif ([bool]$ln.Exists) { $inconclusive++ }
      else {
        $absent = $true
        if ($Mode -eq 'absence') { break }
      }
    }
    else { $inconclusive++ }
    Start-Sleep -Milliseconds 1000
  }
  return [ordered]@{ Seen = $seen; Absent = $absent; InconclusiveCount = $inconclusive; Pid = $pidSeen }
}

# ---------------------------------------------------------------------------
# Config canonica dos 19 workers (mesmo padrao do lifecycle smoke)
# ---------------------------------------------------------------------------
function New-LaneConfig([string]$ConfigPath, [string]$AgentsDir) {
  $files = @(Get-ChildItem -LiteralPath $AgentsDir -Filter '*.md' -File | Sort-Object Name)
  if ($files.Count -eq 0) { throw ('nenhum .md canonico em ' + $AgentsDir) }
  $agents = [ordered]@{}
  $stems = New-Object System.Collections.ArrayList
  foreach ($f in $files) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    [void]$stems.Add($stem)
    $parsed = Read-AgentFileCanonical -Path $f.FullName
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
    $agents[$stem] = [ordered]@{ mode = [string]$c.Mode; permissions = @($rules) }
  }
  $buildRules = New-Object System.Collections.ArrayList
  [void]$buildRules.Add([ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' })
  foreach ($s in ($stems | Sort-Object)) {
    [void]$buildRules.Add([ordered]@{ action = 'subagent'; resource = [string]$s; effect = 'allow' })
  }
  $orderedAgents = [ordered]@{ build = [ordered]@{ mode = 'primary'; permissions = @($buildRules) } }
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

# ---------------------------------------------------------------------------
# Binario exato
# ---------------------------------------------------------------------------
function Resolve-LaneBinary([string]$Explicit, [string]$WantVersion) {
  $cands = New-Object System.Collections.ArrayList
  if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
    if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) { throw ('-BinaryPath inexistente: ' + $Explicit) }
    [void]$cands.Add($Explicit)
  }
  else {
    foreach ($c in @(Get-Command -Name 'opencode' -All -ErrorAction SilentlyContinue)) {
      $src = ''
      try { $src = [string]$c.Source } catch { $src = '' }
      if ([string]::IsNullOrWhiteSpace($src)) { continue }
      if (-not (Test-Path -LiteralPath $src)) { continue }
      [void]$cands.Add($src)
    }
    $profileBin = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe'
    if ((Test-Path -LiteralPath $profileBin -PathType Leaf) -and (-not ($cands -contains $profileBin))) {
      [void]$cands.Add($profileBin)
    }
  }
  $considered = @()
  foreach ($cand in $cands) {
    $exePath = [string]$cand
    $considered += $exePath
    $ext = [IO.Path]::GetExtension($exePath).ToLowerInvariant()
    if ($ext -ne '.exe') {
      $resolved = Resolve-SpikeShimTarget -ShimPath $exePath
      if ([string]::IsNullOrWhiteSpace($resolved)) { continue }
      if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { continue }
      $exePath = $resolved
    }
    $vr = Invoke-SpikeChild -FilePath $exePath -ArgumentList @('--version') -TimeoutMs 30000 -CleanEnvironment -StdinNul
    if ([bool]$vr.TimedOut) { continue }
    if ([int]$vr.ExitCode -ne 0) { continue }
    $verText = ([string]$vr.Stdout + "`n" + [string]$vr.Stderr)
    if (-not (Test-SpikeExactVersion -Text $verText -Version $WantVersion)) { continue }
    $first = ((([string]$verText -split "`r?`n") | Select-Object -First 1)).Trim()
    return [ordered]@{ Path = $exePath; VersionLine = $first; Considered = $considered }
  }
  throw ('nenhum binario com versao exata ' + $WantVersion + ' (considerados: ' + ($considered -join ' | ') + ')')
}

# ---------------------------------------------------------------------------
# Host/worker: filho DIRETO do harness (prova de parentage CIM-proven da lib)
# ---------------------------------------------------------------------------
function Initialize-LaneHost {
  $exe = ''
  try { $exe = [string](Get-Process -Id ([int]$PID) -ErrorAction Stop).Path } catch { $exe = '' }
  if ([string]::IsNullOrWhiteSpace($exe)) {
    $exe = (Join-Path $PSHOME 'powershell.exe')
  }
  $script:hostExe = $exe.Trim()
  $script:hostIsWinPs = ([IO.Path]::GetFileName($script:hostExe).ToLowerInvariant() -eq 'powershell.exe')
  $script:workerScript = Join-Path $script:workRoot 'rr-lane-worker.ps1'
  $body = @'
param(
  [string]$Mode = 'hang',
  [int]$Seconds = 300,
  [string]$ReadyFile = '',
  [string]$ActionLog = '',
  [string]$WorkFile = ''
)
$ErrorActionPreference = 'Continue'
try { [IO.File]::WriteAllText($ReadyFile, ('ready ' + $PID)) } catch { exit 9 }
$nl = [Environment]::NewLine
if ($Mode -eq 'complete') { exit 0 }
if ($Mode -eq 'hang') { Start-Sleep -Seconds $Seconds; exit 0 }
if ($Mode -eq 'idle') { Start-Sleep -Seconds $Seconds; exit 0 }
if ($Mode -eq 'sleeper') { Start-Sleep -Seconds $Seconds; exit 0 }
if ($Mode -eq 'repeat') {
  $deadline = (Get-Date).AddSeconds($Seconds)
  $leaf = [IO.Path]::GetFileName($WorkFile)
  while ((Get-Date) -lt $deadline) {
    try { [IO.File]::AppendAllText($WorkFile, ('tick ' + (Get-Date).Ticks + $nl)) } catch { }
    $line = '{"tool":"bash","args":"lane worker touch repeat fixed","target":"lane-worker-artifact-' + $leaf + '","result":"exit-0"}'
    try { [IO.File]::AppendAllText($ActionLog, ($line + $nl)) } catch { }
    Start-Sleep -Milliseconds 350
  }
  exit 0
}
if ($Mode -eq 'cycle') {
  $deadline = (Get-Date).AddSeconds($Seconds)
  $leaf = [IO.Path]::GetFileName($WorkFile)
  $i = 0
  while ((Get-Date) -lt $deadline) {
    $i++
    try { [IO.File]::AppendAllText($WorkFile, ('tick ' + (Get-Date).Ticks + $nl)) } catch { }
    if (($i % 2) -eq 1) { $step = 'a' } else { $step = 'b' }
    $line = '{"tool":"bash","args":"lane worker cycle step ' + $step + ' fixed","target":"lane-worker-artifact-' + $leaf + '","result":"exit-0"}'
    try { [IO.File]::AppendAllText($ActionLog, ($line + $nl)) } catch { }
    Start-Sleep -Milliseconds 350
  }
  exit 0
}
exit 7
'@
  [IO.File]::WriteAllText($script:workerScript, (($body -replace "`r`n", "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}

function Start-LaneWorker {
  # Filho DIRETO do processo do harness: a lib do watchdog so aceita
  # parentage provada por CIM igual ao supervisor corrente. Handle do proprio
  # spawn (nunca por PID) e atribuicao ao Job Object da lane.
  param([string]$Mode, [int]$Seconds = 300, [string]$Tag = 'w')
  $ready = Join-Path $script:workRoot ($Tag + '.ready')
  $log = Join-Path $script:workRoot ($Tag + '.actions.jsonl')
  $work = Join-Path $script:workRoot ($Tag + '.work.txt')
  foreach ($f in @($ready, $log, $work)) {
    try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch { }
  }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:hostExe
  $argLine = '-NoProfile'
  if ([bool]$script:hostIsWinPs) { $argLine = $argLine + ' -ExecutionPolicy Bypass' }
  $argLine = $argLine + ' -File "' + $script:workerScript + '" -Mode ' + $Mode + ' -Seconds ' + [string]$Seconds +
    ' -ReadyFile "' + $ready + '" -ActionLog "' + $log + '" -WorkFile "' + $work + '"'
  $psi.Arguments = $argLine
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $script:workRoot
  # S-2: ambiente MINIMO do worker. O contrato declarado ("sem credencial no
  # ambiente dos filhos") so vale se o ambiente for realmente construido, e nao
  # herdado: a lista base e a MESMA doutrina de -CleanEnvironment do
  # Invoke-SpikeChild (PATH, SystemRoot, WINDIR, ComSpec, PATHEXT, TEMP, TMP e
  # PSModulePath). Alem da base, apenas o estritamente necessario ao cenario:
  # TEMP/TMP apontados para o workRoot isolado desta execucao (o worker grava
  # apenas la). Nada de token, chave, URL de servico ou variavel do ambiente do
  # operador e repassada ao filho.
  try { $psi.EnvironmentVariables.Clear() } catch { }
  foreach ($k in @('PATH', 'SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'TEMP', 'TMP')) {
    $v = $null
    try { $v = [Environment]::GetEnvironmentVariable($k, 'Process') } catch { $v = $null }
    if ($null -eq $v) { continue }
    try { $psi.EnvironmentVariables[$k] = [string]$v } catch { }
  }
  try {
    $pm = [Environment]::GetEnvironmentVariable('PSModulePath', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($pm)) { $psi.EnvironmentVariables['PSModulePath'] = [string]$pm }
  }
  catch { }
  try { $psi.EnvironmentVariables['TEMP'] = [string]$script:workRoot } catch { }
  try { $psi.EnvironmentVariables['TMP'] = [string]$script:workRoot } catch { }
  $proc = $null
  try { $proc = [System.Diagnostics.Process]::Start($psi) }
  catch { return [ordered]@{ ok = $false; error = ('start falhou: ' + (Get-LaneSafeError $_)) } }
  $assigned = $false
  $note = ''
  if ($null -ne $script:laneJob) {
    $add = Add-RuntimeJobProcess -Job $script:laneJob -Process $proc
    if ([bool]$add.Ok) { $assigned = $true; $note = ('atribuido ao job da lane (pid ' + [int]$add.Pid + ')') }
    else { $note = ('atribuicao falhou: ' + [string]$add.Reason) }
  }
  else { $note = 'sem job (contencao ausente)' }
  return [ordered]@{
    ok = $true; mode = $Mode; proc = $proc; pid = ([int]$proc.Id)
    ready_file = $ready; action_log = $log; work_file = $work
    job_assigned = $assigned; job_note = $note
  }
}

function Wait-LaneWorkerReady($Worker, [int]$TimeoutMs = 20000) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $ok = $false
  while ($sw.ElapsedMilliseconds -lt [long]$TimeoutMs) {
    try {
      $live = Get-Process -Id ([int]$Worker.pid) -ErrorAction Stop
      if (($null -ne $live) -and (-not [string]::IsNullOrWhiteSpace([string]$live.Path))) {
        $null = ([DateTime]$live.StartTime).ToUniversalTime()
        $ok = $true
      }
    }
    catch { $ok = $false }
    if ($ok -and (Test-Path -LiteralPath ([string]$Worker.ready_file) -PathType Leaf)) { break }
    Start-Sleep -Milliseconds 200
  }
  $sw.Stop()
  return $ok
}

function Test-LanePidGone([int]$ProcessId) {
  # Fato de vida observavel, com ausencia PROVADA: 'Get-Process' recusando com
  # o erro canonico de "processo inexistente" e prova de ausencia; qualquer
  # OUTRO erro e falha de inspecao e devolve $false (fail-safe: nunca 'morto'
  # por suposicao, nunca 'vivo' por suposicao).
  try {
    $live = Get-Process -Id ([int]$ProcessId) -ErrorAction Stop
    if ($null -eq $live) { return $true }
    try { if ([bool]$live.HasExited) { return $true } } catch { return $false }
    return $false
  }
  catch {
    $fq = ''
    try { $fq = [string]$_.FullyQualifiedErrorId } catch { $fq = '' }
    $msg = ''
    try { $msg = [string]$_.Exception.Message } catch { $msg = '' }
    if ($fq -cmatch 'NoProcessFoundForGivenId') { return $true }
    if ($msg -cmatch 'Cannot find a process with the process ID') { return $true }
    if ($msg -cmatch 'No process is associated with this object') { return $true }
    return $false
  }
}

function Wait-LanePidGone([int]$ProcessId, [int]$TimeoutMs = 15000) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt [long]$TimeoutMs) {
    if (Test-LanePidGone -ProcessId $ProcessId) { return $true }
    Start-Sleep -Milliseconds 300
  }
  return (Test-LanePidGone -ProcessId $ProcessId)
}

function Wait-LaneWorkerExit($Worker, [int]$TimeoutMs = 60000) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt [long]$TimeoutMs) {
    try {
      $proc = $Worker.proc
      if ($proc.HasExited) {
        return [ordered]@{ exited = $true; exit_code = ([int]$proc.ExitCode); elapsed_ms = [long]$sw.ElapsedMilliseconds }
      }
    }
    catch { return [ordered]@{ exited = $true; exit_code = -1; elapsed_ms = [long]$sw.ElapsedMilliseconds } }
    Start-Sleep -Milliseconds 200
  }
  return [ordered]@{ exited = $false; exit_code = -1; elapsed_ms = [long]$sw.ElapsedMilliseconds }
}

# ---------------------------------------------------------------------------
# Kernel CLI (bounded, ambiente limpo, task em diretorio temporario)
# ---------------------------------------------------------------------------
function Get-LaneKernelOutcome {
  # F1: veredito de uma chamada do kernel CLI, em funcao PURA (sem spawn, sem
  # IO) para ser validavel isoladamente. 'ok' = operacao de dominio teve
  # sucesso = JSON entendido E exit 0 E sem timeout E SEM erro de dominio.
  # O caso 'exit 0 + JSON com error de dominio' e' falha: o gate depende do
  # veredito de dominio, nunca so do codigo de processo.
  param([int]$ExitCode, [bool]$TimedOut = $false, [bool]$JsonParsed = $false, [string]$DomainError = '')
  $exitOk = ([bool]$JsonParsed -and ([int]$ExitCode -eq 0) -and (-not [bool]$TimedOut))
  $domainOk = ([bool]$JsonParsed -and [string]::IsNullOrWhiteSpace([string]$DomainError))
  return [ordered]@{
    json_parsed = [bool]$JsonParsed
    exit_ok = [bool]$exitOk
    domain_ok = [bool]$domainOk
    ok = ([bool]$exitOk -and [bool]$domainOk)
  }
}

function Invoke-KernelCli {
  param([string[]]$LaneArgs, [int]$TimeoutMs = 90000)
  $cli = Join-Path $RepoRoot 'scripts\v3\task-kernel.ps1'
  $pre = @('-NoProfile', '-File', $cli)
  if ([bool]$script:hostIsWinPs) { $pre = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli) }
  $all = @($pre) + @($LaneArgs)
  $r = Invoke-SpikeChild -FilePath $script:hostExe -ArgumentList $all -TimeoutMs $TimeoutMs -CleanEnvironment -StdinNul
  # Parse da SAIDA SEMPRE que houver: o kernel imprime JSON tambem em erro de
  # dominio (exit != 0), e sem isso a evidencia perde o codigo de erro real.
  $json = $null
  $parseErr = ''
  $raw = ([string]$r.Stdout).Trim()
  if (-not [string]::IsNullOrWhiteSpace($raw)) {
    try { $json = ($raw | ConvertFrom-Json) } catch { $json = $null; $parseErr = (Get-LaneSafeError $_ -MaxChars 160) }
  }
  $err = ''
  try { $err = ([string]$r.Stderr).Trim() } catch { $err = '' }
  if ($err.Length -gt 400) { $err = $err.Substring(0, 400) }
  # M-1/F1: json_parsed (a saida foi entendida) e ok (a OPERACAO DE DOMINIO
  # teve sucesso) sao coisas distintas. Exit code != 0, timeout OU presenca de
  # error de dominio no resultado = falha, mesmo com JSON perfeito e exit 0.
  # O veredito vem de Get-LaneKernelOutcome (funcao pura) e e o MESMO no
  # retorno e na telemetria (kernel_cli_calls).
  # Sem essa separacao, um COMPLETION_GATE_FAILED chegava ao cenario 04
  $domainError = ''
  $jsonParsed = ($json -ne $null)
  if ($jsonParsed) {
    try { $domainError = ([string]$json.error).Trim() } catch { $domainError = '' }
  }
  $outcome = Get-LaneKernelOutcome -ExitCode ([int]$r.ExitCode) -TimedOut ([bool]$r.TimedOut) -JsonParsed $jsonParsed -DomainError $domainError
  $res = [ordered]@{
    args = ([string[]]$LaneArgs); exit_code = ([int]$r.ExitCode); timed_out = [bool]$r.TimedOut
    stdout_len = $raw.Length; parse_error = $parseErr
    json_parsed = [bool]$outcome.json_parsed; domain_ok = [bool]$outcome.domain_ok; domain_error = $domainError
    ok = [bool]$outcome.ok; json = $json; stderr_tail = $err
  }
  [void]$script:KernelCalls.Add([ordered]@{
    action = [string]$LaneArgs[0]; exit_code = ([int]$r.ExitCode); timed_out = [bool]$r.TimedOut
    json_parsed = [bool]$outcome.json_parsed; exit_ok = [bool]$outcome.exit_ok; domain_ok = [bool]$outcome.domain_ok
    ok = [bool]$outcome.ok; domain_error = $domainError; stdout_len = $raw.Length
  })
  return $res
}

function Get-KernelRevision([string]$TaskId, [string]$TasksDir) {
  # `-Action status` (resumo compacto) e NAO `-Action get`: a saida de get
  # passa de 4 KB depois de start-attempt e estoura o buffer do pipe antes do
  # dreno, o que trava o filho em escrita ate o timeout (deadlock observado,
  # exit -1 com JSON completo no dreno tardio) e zera a revisao lida.
  $r = Invoke-KernelCli -LaneArgs @('-Action', 'status', '-TaskId', $TaskId, '-TasksDir', $TasksDir)
  $rev = -1
  $state = ''
  try { $rev = [int]$r.json.revision; $state = [string]$r.json.state } catch { $rev = -1 }
  if ($rev -lt 0) { return [ordered]@{ revision = -1; state = ''; call = $r } }
  return [ordered]@{ revision = $rev; state = $state; call = $r }
}

# ---------------------------------------------------------------------------
# Watchdog helpers (registro com identidade real; avaliacao/enforcement reais)
# ---------------------------------------------------------------------------
function New-LaneBudget {
  param([int]$Wall, [int]$NoProgress, [int]$Steps = 64)
  # Budget do EXECUCAO supervisionada (spike real do harness), curto por
  # desenho desta lane. Nao toca no BUDGET_IMMUTABLE do kernel: as tasks reais
  # do kernel ficam com o budget resolvido pelo proprio kernel (record-only).
  # no_progress <= wall e exigido pelo validador da lib de budget; o cutoff
  # remain <= e o que dispara no cenario 06 (wall folgado + no_progress curto).
  $wallInt = [int]$Wall
  if ($wallInt -lt 1) { $wallInt = 1 }
  $npInt = [int]$NoProgress
  if ($npInt -lt 1) { $npInt = 1 }
  if ($npInt -gt $wallInt) { $npInt = $wallInt }
  return [ordered]@{
    profile = 'fast'; step_budget = $Steps; wall_clock_seconds = $wallInt
    no_progress_seconds = $npInt; repeated_action_soft_limit = 3
    repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
  }
}

function Register-LaneExecution {
  param([string]$TaskId, [string]$SessionId, $Worker, $Budget, $Role = 'coder')
  if (-not (Wait-LaneWorkerReady -Worker $Worker -TimeoutMs 20000)) {
    return [ordered]@{ ok = $false; error = 'worker nao ficou legivel (path/start)' }
  }
  $livePath = ''
  try { $livePath = ([string](Get-Process -Id ([int]$Worker.pid) -ErrorAction Stop).Path).Trim() } catch { $livePath = '' }
  $st = $null
  try { $st = ([DateTime]$Worker.proc.StartTime) } catch { $st = $null }
  if ($null -eq $st) {
    try { $st = ([DateTime](Get-Process -Id ([int]$Worker.pid) -ErrorAction Stop).StartTime) } catch { $st = $null }
  }
  $reg = Register-OrchestrationWatchdogExecution -TaskId $TaskId -AttemptN 1 -SessionId $SessionId -Role $Role `
    -Budget $Budget -StartedAtUtc ([DateTime]::UtcNow) -FlagsPath $script:repoFlags -RepoRoot $RepoRoot `
    -ProcessId ([int]$Worker.pid) -ProcessPath $livePath -ParentProcessId ([int]$PID) -ProcessStartTime $st
  return [ordered]@{
    ok = [bool]$reg.ok; error = [string]$reg.error; enforced = [bool]$reg.enforced
    registered_pid = ([int]$Worker.pid); registered_path = $livePath; start_time = ''
  }
}

function Get-LaneEvaluation([string]$TaskId, [switch]$IncludeSettlement) {
  if ([bool]$IncludeSettlement) {
    return (Get-OrchestrationWatchdogEvaluation -TaskId $TaskId -FlagsPath $script:repoFlags -RepoRoot $RepoRoot -TelemetryRoot $script:teleRoot -IncludeEnforcement)
  }
  return (Get-OrchestrationWatchdogEvaluation -TaskId $TaskId -FlagsPath $script:repoFlags -RepoRoot $RepoRoot -TelemetryRoot $script:teleRoot)
}

function Get-LaneSettlement([string]$TaskId) {
  return (Get-OrchestrationWatchdogSettlement -TaskId $TaskId -FlagsPath $script:repoFlags -RepoRoot $RepoRoot -TelemetryRoot $script:teleRoot)
}

function Read-LaneActions([string]$LogPath, [int]$Cursor) {
  # Le as acoes REAIS escritas pelo proprio processo worker (JSONL) a partir do
  # cursor informado. Devolve as acoes novas e o novo cursor (sem [ref], para
  # funcionar igual em PS 5.1 e PS7).
  $out = New-Object System.Collections.ArrayList
  $seen = 0
  try {
    if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
      $lines = @([IO.File]::ReadAllLines($LogPath, [Text.Encoding]::UTF8))
      $seen = $lines.Count
      for ($i = [int]$Cursor; $i -lt $lines.Count; $i++) {
        $ln = ([string]$lines[$i]).Trim()
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        try { $o = ($ln | ConvertFrom-Json) } catch { continue }
        if ($null -eq $o) { continue }
        $tool = ''
        try { $tool = [string]$o.tool } catch { $tool = '' }
        if ([string]::IsNullOrWhiteSpace($tool)) { continue }
        [void]$out.Add([ordered]@{
          tool = $tool
          arguments = [string]$o.args
          target = [string]$o.target
          result_class = [string]$o.result
        })
      }
    }
  }
  catch { }
  return [ordered]@{ actions = @($out.ToArray()); cursor = [int]$seen }
}

function Copy-LaneTelemetry([string]$Tag) {
  $dst = Join-Path $script:scenarioEvidenceDir ('watchdog-telemetry-' + $Tag + '.jsonl')
  try {
    $lines = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $script:teleRoot -Filter 'watchdog-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
      foreach ($ln in @([IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8))) {
        $t = ([string]$ln).Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($t.Length -gt 2000) { $t = $t.Substring(0, 2000) }
        [void]$lines.Add($t)
      }
    }
    if ($lines.Count -gt 0) {
      [IO.File]::WriteAllLines($dst, ([string[]]$lines.ToArray()), (New-Object Text.UTF8Encoding $false))
      return (Split-Path -Leaf $dst)
    }
  }
  catch { }
  return ''
}

function Resolve-LaneEvidenceDir {
  # M-2: resolucao ISOLADA e testavel do destino de evidencia. O parametro
  # -EvidenceRoot e' a autoridade e sempre vence; sem ele, o padrao datado do
  # repo. A funcao e' pura (nao cria nem escreve nada), o que permite valida-la
  # isoladamente sem executar a lane.
  param([string]$RepoRootPath, [string]$Requested = '')
  $req = ''
  try { $req = ([string]$Requested).Trim() } catch { $req = '' }
  if (-not [string]::IsNullOrWhiteSpace($req)) { return $req }
  $root = ''
  try { $root = ([string]$RepoRootPath).Trim() } catch { $root = '' }
  if ([string]::IsNullOrWhiteSpace($root)) { return '' }
  return (Join-Path $root 'evidence\v3.1\runtime-reliability\v2-lane-2026-10-04')
}

function Get-LaneSafeStateProjection {
  # F2(a): projecao SANEADA do estado da lane para serializacao. O estado em
  # memoria pode carregar o path bruto do binario e texto livre (blocked_reason,
  # verdict, gate); a projecao nao inventa nem remove campo de formao, apenas
  # substitui valores por paths relativos/placeholders e texto curto.
  $src = $script:Lane
  $out = [ordered]@{}
  foreach ($k in @($src.Keys)) {
    $key = [string]$k
    $v = $src[$k]
    if ($key -ceq 'binary') { $out[$key] = (Get-LaneSafePath -Path ([string]$v)); continue }
    if (($key -ceq 'blocked_reason') -or ($key -ceq 'verdict') -or ($key -ceq 'lane_status')) {
      $out[$key] = (Get-LaneSafeText -Text ([string]$v) -MaxChars 1200)
      continue
    }
    if ($key -ceq 'gate') {
      $g = [ordered]@{}
      try {
        $g['failed'] = (Get-LaneSafeText -Text ([string]$v['failed']) -MaxChars 600)
        $checks = New-Object System.Collections.ArrayList
        foreach ($c in @($v['checks'])) {
          $nm = ''
          $ps = $false
          $dt = ''
          try { $nm = [string]$c['name'] } catch { $nm = '' }
          try { $ps = [bool]$c['passed'] } catch { $ps = $false }
          try { $dt = [string]$c['detail'] } catch { $dt = '' }
          [void]$checks.Add([ordered]@{ name = $nm; passed = $ps; detail = (Get-LaneSafeText -Text $dt -MaxChars 400) })
        }
        $g['checks'] = @($checks.ToArray())
      }
      catch { $g['failed'] = 'gate-ilegivel'; $g['checks'] = @() }
      $out[$key] = $g
      continue
    }
    $out[$key] = $v
  }
  return $out
}

function New-ScenarioResult {
  param([string]$ScenarioId, [int]$Ordinal, [string]$Title, [string]$Status, $Observed, $Assertions, [string[]]$Notes = @(), [string]$Cause = '')
  # S-1: os detalhes das assertions sao TEXTO LIVRE (job_note, motivo de gate,
  # detalhe de verifier) e podem embutir path absoluto; persistimos uma copia
  # saneada, preservando nome/passed/lenha do formato existente.
  $safeAssertions = New-Object System.Collections.ArrayList
  foreach ($a in @($Assertions)) {
    $nm = ''
    $ps = $false
    $dt = ''
    try { $nm = [string]$a['name'] } catch { $nm = '' }
    try { $ps = [bool]$a['passed'] } catch { $ps = $false }
    try { $dt = [string]$a['detail'] } catch { $dt = '' }
    [void]$safeAssertions.Add([ordered]@{ name = $nm; passed = $ps; detail = (Get-LaneSafeText -Text $dt -MaxChars 400) })
  }
  $obj = [ordered]@{
    scenario = $ScenarioId
    ordinal = $Ordinal
    title = $Title
    date = (Get-LaneDate)
    lane = 'v3.1-watchdog-real-lane-v2'
    executor = 'RR-E2E-LANE-04-10 (coder worker)'
    binary = (Get-LaneSafePath -Path ([string]$script:Lane.binary))
    version_line = [string]$script:Lane.version_line
    attempts = 1
    status = $Status
    cause = (Get-LaneSafeText -Text $Cause)
    observed = $Observed
    assertions = @($safeAssertions.ToArray())
    notes = @($Notes)
  }
  $path = Join-Path $script:scenarioEvidenceDir ($ScenarioId.ToLowerInvariant() + '.json')
  try { Write-LaneJsonAtomic $obj $path } catch { Write-LaneText ('evidencia do cenario nao gravada: ' + (Get-LaneSafeError $_)) }
  Write-LaneText ($ScenarioId + ' => ' + $Status + $(if ($Cause -ne '') { ' (' + (Get-LaneSafeText -Text $Cause) + ')' } else { '' }))
  $script:LaneResults.Add([ordered]@{
    scenario = $ScenarioId; ordinal = $Ordinal; title = $Title; status = $Status
    cause = (Get-LaneSafeText -Text $Cause); evidence = ('watchdog/' + $ScenarioId.ToLowerInvariant() + '.json')
    assertions_passed = @($safeAssertions.ToArray() | Where-Object { [bool]$_.passed }).Count
    assertions_total = @($safeAssertions.ToArray()).Count
  })
  return $obj
}

# ---------------------------------------------------------------------------
# Cenario 04: worker normal completion sob task real do kernel
# ---------------------------------------------------------------------------
function Invoke-Scenario04 {
  $as = New-Object System.Collections.ArrayList
  $notes = New-Object System.Collections.ArrayList
  $tid = 'rr-e2e-04-worker-normal'
  $tasksDir = Join-Path $script:tasksRoot 's04'
  New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
  $criterion = 'real worker process exits zero under a real kernel task attempt'
  $observed = [ordered]@{ task_id = $tid; tasks_dir_is_temp = $true; kernel_calls = @() }

  $create = Invoke-KernelCli -LaneArgs @(
    '-Action', 'create', '-TaskId', $tid, '-Objective', 'prove a real worker attempt completes normally under a real kernel task',
    '-Actor', 'planner', '-ActorIdentitySource', 'explicit-cli',
    '-RuntimeId', 'opencode-v2', '-RuntimeGeneration', '2', '-RuntimeProfile', 'v2', '-RuntimeVersion', $PinnedVersion,
    '-TasksDir', $tasksDir, '-AcceptanceCriteria', $criterion,
    '-WriteScopes', 'scripts/ci/watchdog-real-lane-v2.ps1'
  )
  $observed['create'] = [ordered]@{ exit_code = [int]$create.exit_code; ok = [bool]$create.ok }
  [void]$as.Add([ordered]@{ name = 'kernel_task_created'; passed = [bool]$create.ok; detail = ('task-kernel.ps1 -Action create (tasks dir TEMP); rc=' + [int]$create.exit_code) })
  if (-not [bool]$create.ok) {
    return (New-ScenarioResult -ScenarioId 'RR-E2E-04' -Ordinal 4 -Title 'Worker normal completion' -Status 'failed' `
        -Observed $observed -Assertions $as -Notes $notes -Cause 'kernel create recusou a task real da lane')
  }

  $rev = (Get-KernelRevision -TaskId $tid -TasksDir $tasksDir).revision
  foreach ($step in @(@('PLANNING', 'planner', $false), @('IMPLEMENTING', 'planner', $true))) {
    $t = Invoke-KernelCli -LaneArgs @('-Action', 'transition', '-TaskId', $tid, '-ToState', [string]$step[0], '-Actor', [string]$step[1],
      '-ActorIdentitySource', 'explicit-cli', '-ExpectedRevision', [string]$rev, '-TasksDir', $tasksDir)
    $rev = (Get-KernelRevision -TaskId $tid -TasksDir $tasksDir).revision
    [void]$as.Add([ordered]@{ name = ('kernel_transition_' + [string]$step[0]); passed = [bool]$t.ok; detail = ('rc=' + [int]$t.exit_code) })
  }

  $att = Invoke-KernelCli -LaneArgs @('-Action', 'start-attempt', '-TaskId', $tid, '-AttemptRole', 'coder',
    '-SessionId', 'ses-rr-e2e-04-worker', '-Actor', 'planner', '-ActorIdentitySource', 'explicit-cli',
    '-ExpectedRevision', [string]$rev, '-TasksDir', $tasksDir)
  $observed['start_attempt'] = [ordered]@{ exit_code = [int]$att.exit_code; ok = [bool]$att.ok; error = [string]$att.json.error }
  [void]$as.Add([ordered]@{ name = 'kernel_attempt_started'; passed = [bool]$att.ok; detail = ('start-attempt real; rc=' + [int]$att.exit_code + ' error=' + [string]$att.json.error) })
  $rev = (Get-KernelRevision -TaskId $tid -TasksDir $tasksDir).revision

  $worker = Start-LaneWorker -Mode 'complete' -Seconds 60 -Tag 's04'
  $workerReady = (Wait-LaneWorkerReady -Worker $worker -TimeoutMs 20000)
  $ex = Wait-LaneWorkerExit -Worker $worker -TimeoutMs 60000
  $observed['worker'] = [ordered]@{
    mode = 'complete'; pid = [int]$worker.pid; ready = $workerReady; job_assigned = [bool]$worker.job_assigned
    exited = [bool]$ex.exited; exit_code = [int]$ex.exit_code; elapsed_ms = [long]$ex.elapsed_ms
  }
  [void]$as.Add([ordered]@{ name = 'real_worker_process_completed'; passed = ([bool]$ex.exited -and [int]$ex.exit_code -eq 0); detail = ('processo real do harness, exit=' + [int]$ex.exit_code + ' (termino normal real)') })
  # M-1: candidate_pass so e gravado quando o worker real terminou
  # NORMALMENTE e a tentativa real existe. Sem esse portao, um worker que
  # terminou com erro ainda produzia 'candidate_pass' no kernel.
  $workerCompleted = ([bool]$ex.exited -and [int]$ex.exit_code -eq 0)
  $observed['candidate_pass_recorded'] = $false
  if (-not $workerCompleted) {
    $observed['candidate_pass_gate'] = 'worker nao terminou normalmente: candidate_pass NAO gravado no kernel'
    [void]$notes.Add('candidate_pass NAO gravado: o worker real nao terminou com exit 0; o kernel nao recebeu resultado de worker algum.')
    return (New-ScenarioResult -ScenarioId 'RR-E2E-04' -Ordinal 4 -Title 'Worker normal completion' -Status 'failed' `
        -Observed $observed -Assertions $as -Notes $notes -Cause ('worker real terminou com exit ' + [string]$ex.exit_code + '; candidate_pass nao gravado'))
  }

  $rr = Invoke-KernelCli -LaneArgs @('-Action', 'record-result', '-TaskId', $tid, '-WorkerStatus', 'candidate_pass',
    '-ProducedBy', 'coder', '-ActorIdentitySource', 'explicit-cli', '-ExpectedRevision', [string]$rev,
    '-ClaimedEvidence', ('criterion:0:' + $criterion), '-TasksDir', $tasksDir)
  $observed['record_result'] = [ordered]@{ exit_code = [int]$rr.exit_code; ok = [bool]$rr.ok; domain_error = [string]$rr.domain_error; status = [string]$rr.json.worker_status }
  $observed['candidate_pass_recorded'] = [bool]$rr.ok
  [void]$as.Add([ordered]@{ name = 'kernel_candidate_pass_recorded'; passed = [bool]$rr.ok; detail = ('record-result candidate_pass; rc=' + [int]$rr.exit_code + ' domain_error=' + [string]$rr.domain_error) })
  $rev = (Get-KernelRevision -TaskId $tid -TasksDir $tasksDir).revision

  $t1 = Invoke-KernelCli -LaneArgs @('-Action', 'transition', '-TaskId', $tid, '-ToState', 'VALIDATING', '-Actor', 'coder',
    '-ActorIdentitySource', 'explicit-cli', '-ExpectedRevision', [string]$rev, '-TasksDir', $tasksDir)
  $rev = (Get-KernelRevision -TaskId $tid -TasksDir $tasksDir).revision
  $t2 = Invoke-KernelCli -LaneArgs @('-Action', 'transition', '-TaskId', $tid, '-ToState', 'REVIEWING', '-Actor', 'tester',
    '-ActorIdentitySource', 'explicit-cli', '-ExpectedRevision', [string]$rev, '-TasksDir', $tasksDir)
  $rev = (Get-KernelRevision -TaskId $tid -TasksDir $tasksDir).revision
  [void]$as.Add([ordered]@{ name = 'kernel_reaching_state_reviewing'; passed = ([bool]$t1.ok -and [bool]$t2.ok); detail = ('transicoes reais VALIDATING/REVIEWING; rc=' + [int]$t1.exit_code + '/' + [int]$t2.exit_code) })

  # verified_pass do gate de DONE: SOMENTE verifier allowlisted real.
  $verifierStatus = 'not-run'
  $verifierFile = ''
  $verifierDetail = ''
  $scopeOut = @()
  try {
    if ($null -eq (Get-Command -Name 'Test-OrchestrationWriteScope' -ErrorAction SilentlyContinue)) {
      . (Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationVerifier.ps1')
    }
    $scope = Test-OrchestrationWriteScope -RepoRoot $RepoRoot -BaseRevision 'HEAD' -WriteScopes $script:laneWriteScopes
    $scopeOut = @($scope.out_of_scope)
    if (@($scope.out_of_scope).Count -eq 0) {
      $vr = Invoke-OrchestrationVerifier -TaskId $tid -RepoRoot $RepoRoot -BaseRevision 'HEAD' -WriteScopes $script:laneWriteScopes `
        -ProfileNames @('package-consistency') -AcceptanceCriteria @($criterion)
      $verifierStatus = [string]$vr.status
      $verifierDetail = ([string]$vr.reason)
      if ([string]$vr.status -ceq 'verified_pass') {
        $verifierFile = Join-Path $script:workRoot 'verifier-result.json'
        [IO.File]::WriteAllText($verifierFile, (($vr | ConvertTo-Json -Depth 12) + "`n"), (New-Object Text.UTF8Encoding $false))
      }
    }
    else {
      $verifierStatus = 'skipped-out-of-scope'
      $verifierDetail = ('working tree com mudancas fora do write scope desta lane: ' + (@($scope.out_of_scope) -join ', '))
    }
  }
  catch {
    $verifierStatus = 'error'
    $verifierDetail = (Get-LaneSafeError $_)
  }
  $observed['verifier'] = [ordered]@{
    status = $verifierStatus; reason = $verifierDetail; out_of_scope = @($scopeOut)
    allowlisted_profile = 'package-consistency'
  }
  $verifyOk = $false
  if (-not [string]::IsNullOrWhiteSpace($verifierFile)) {
    $vf = Invoke-KernelCli -LaneArgs @('-Action', 'verify', '-TaskId', $tid, '-VerifierResultFile', $verifierFile,
      '-ActorIdentitySource', 'explicit-cli', '-ExpectedRevision', [string]$rev, '-TasksDir', $tasksDir)
    $verifyOk = [bool]$vf.ok
    $observed['verify'] = [ordered]@{ exit_code = [int]$vf.exit_code; ok = [bool]$vf.ok; domain_error = [string]$vf.domain_error }
    $rev = (Get-KernelRevision -TaskId $tid -TasksDir $tasksDir).revision
  }
  [void]$as.Add([ordered]@{
    name = 'verified_pass_from_allowlisted_verifier'
    passed = $verifyOk
    detail = ('verifier allowlisted real (profile package-consistency) => status=' + $verifierStatus + ' ' + $verifierDetail)
  })

  $review = Invoke-KernelCli -LaneArgs @('-Action', 'review', '-TaskId', $tid, '-ReviewKind', 'reviewer',
    '-ReviewStatus', 'approved', '-ReviewBy', 'tester', '-ExpectedRevision', [string]$rev, '-TasksDir', $tasksDir)
  $rev = (Get-KernelRevision -TaskId $tid -TasksDir $tasksDir).revision
  [void]$as.Add([ordered]@{ name = 'kernel_review_recorded'; passed = [bool]$review.ok; detail = ('review approved; rc=' + [int]$review.exit_code) })

  $done = Invoke-KernelCli -LaneArgs @('-Action', 'complete', '-TaskId', $tid, '-Actor', 'planner',
    '-ActorIdentitySource', 'explicit-cli', '-OrchestrationCompliance', 'COMPLIANT',
    '-ResidualRisks', 'lane evidence only - release gate untouched', '-ExpectedRevision', [string]$rev, '-TasksDir', $tasksDir)
  $final = Get-KernelRevision -TaskId $tid -TasksDir $tasksDir
  $observed['complete'] = [ordered]@{
    exit_code = [int]$done.exit_code; ok = [bool]$done.ok; domain_error = [string]$done.domain_error
    reasons = @($done.json.reasons); final_state = [string]$final.state; final_revision = [int]$final.revision
  }
  $isDone = ([string]$final.state -ceq 'DONE')
  [void]$as.Add([ordered]@{ name = 'kernel_terminal_done_via_complete'; passed = $isDone; detail = ('Complete-OrchestrationTask real; rc=' + [int]$done.exit_code + '; domain_error=' + [string]$done.domain_error + '; estado final=' + [string]$final.state + '; reasons=' + (@($done.json.reasons) -join ';')) })
  [void]$observed['kernel_calls']
  [void]$notes.Add('verified_pass do gate de DONE veio de verifier allowlisted real; nenhum status foi forjado pelo harness.')
  [void]$notes.Add('budgets do kernel intactos (record-only): o harness nunca chamou set-budget.')
  [void]$notes.Add('a task real do kernel carrega UM write scope representativo da lane: o roteamento acotado via cmd.exe recusa o separador | e o binder do PowerShell recusa o parametro repetido, entao o array completo nao atravessa a CLI. O escopo que decide o verified_pass (gate do verifier) e conferido in-process com a lista COMPLETA dos paths da lane.')
  # M-1 (b)(c): pass-real SO com TODA assertion obrigatoria verde, worker exit 0
  # e terminal real do kernel. Qualquer falha => partial/failed com a causa.
  $mandatory = @(
    'kernel_task_created', 'kernel_transition_PLANNING', 'kernel_transition_IMPLEMENTING',
    'kernel_attempt_started', 'real_worker_process_completed', 'kernel_candidate_pass_recorded',
    'kernel_reaching_state_reviewing', 'kernel_review_recorded', 'kernel_terminal_done_via_complete'
  )
  $mandatoryFailed = @($as | Where-Object { $mandatory -ccontains [string]$_['name'] } | Where-Object { -not [bool]$_['passed'] } | ForEach-Object { [string]$_['name'] })
  $observed['mandatory_failed'] = @($mandatoryFailed)
  $observed['worker_exit_code'] = [int]$ex.exit_code
  $status = 'pass-real'
  $cause = ''
  if (@($mandatoryFailed).Count -gt 0) {
    $status = 'failed'
    $cause = ('assertions obrigatorias vermelhas: ' + (@($mandatoryFailed) -join ', ') + ' (worker exit=' + [string]$ex.exit_code + '; complete rc=' + [string]$done.exit_code + ' domain_error=' + [string]$done.domain_error + ')')
  }
  elseif (-not $verifyOk) {
    $status = 'partial'
    $cause = ('DONE real alcancado sem verified_pass allowlisted no caminho desta execucao (verifier=' + $verifierStatus + ' ' + $verifierDetail + ')')
  }
  return (New-ScenarioResult -ScenarioId 'RR-E2E-04' -Ordinal 4 -Title 'Worker normal completion' -Status $status `
      -Observed $observed -Assertions $as -Notes $notes -Cause $cause)
}

# ---------------------------------------------------------------------------
# Cenario 05: worker hard hang -> HARD_TIMEOUT -> interrupt real
# ---------------------------------------------------------------------------
function Invoke-Scenario05 {
  $as = New-Object System.Collections.ArrayList
  $notes = New-Object System.Collections.ArrayList
  $tid = 'rr-e2e-05-hard-hang'
  $sid = 'ses-rr-e2e-05-hang'
  $worker = Start-LaneWorker -Mode 'hang' -Seconds 240 -Tag 's05'
  $budget = New-LaneBudget -Wall 4 -NoProgress 600
  $reg = Register-LaneExecution -TaskId $tid -SessionId $sid -Worker $worker -Budget $budget
  $observed = [ordered]@{
    task_id = $tid; worker_pid = [int]$worker.pid; job_assigned = [bool]$worker.job_assigned
    budget = $budget; registered = [ordered]@{ ok = [bool]$reg.ok; error = [string]$reg.error; enforced = [bool]$reg.enforced }
    deadline_seconds = [int]$budget['wall_clock_seconds']
  }
  [void]$as.Add([ordered]@{ name = 'watchdog_execution_bound_to_real_child'; passed = [bool]$reg.ok; detail = ('registro com identidade CIM-proven; ok=' + [string]$reg.ok + ' error=' + [string]$reg.error) })
  [void]$as.Add([ordered]@{ name = 'worker_job_containment_proved'; passed = [bool]$worker.job_assigned; detail = [string]$worker.job_note })
  if (-not [bool]$reg.ok) {
    return (New-ScenarioResult -ScenarioId 'RR-E2E-05' -Ordinal 5 -Title 'Worker hard hang' -Status 'blocked' `
        -Observed $observed -Assertions $as -Notes $notes -Cause ('registro recusado: ' + [string]$reg.error))
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $eval = $null
  while ($sw.Elapsed.TotalSeconds -lt 45) {
    Start-Sleep -Milliseconds 400
    $eval = Get-LaneEvaluation -TaskId $tid
    if ([bool]$eval.interrupted) { break }
    if (-not (Test-LanePidGone -ProcessId ([int]$worker.pid))) { continue }
    break
  }
  $sw.Stop()
  $settle = Get-LaneSettlement -TaskId $tid
  $gone = Wait-LanePidGone -ProcessId ([int]$worker.pid) -TimeoutMs 15000
  $tele = Copy-LaneTelemetry -Tag '05'
  $cls = ''
  try { $cls = [string]$eval.classification } catch { $cls = '' }
  $observed['evaluation'] = [ordered]@{
    classification = $cls; interrupted = [bool]$eval.interrupted; elapsed_s = [int]$eval.elapsed_s
    elapsed_observed_ms = [long]$sw.ElapsedMilliseconds; enforcement_reason = [string]$eval.enforcement.reason
  }
  $observed['settlement'] = [ordered]@{ settlement = [string]$settle.settlement; interrupted = [bool]$settle.interrupted; classification = [string]$settle.classification }
  $observed['pid_gone_after_interrupt'] = [bool]$gone
  $observed['telemetry_copy'] = $tele
  [void]$as.Add([ordered]@{ name = 'real_deadline_crossed'; passed = ([int]$eval.elapsed_s -ge [int]$budget['wall_clock_seconds']); detail = ('wall_clock_seconds=' + [string]$budget['wall_clock_seconds'] + '; elapsed_s real observado=' + [string]$eval.elapsed_s) })
  [void]$as.Add([ordered]@{ name = 'classification_hard_timeout'; passed = ($cls -ceq 'HARD_TIMEOUT'); detail = ('classificacao real=' + $cls) })
  [void]$as.Add([ordered]@{ name = 'interrupt_engaged'; passed = [bool]$eval.interrupted; detail = ('interrupted=' + [string]$eval.interrupted) })
  [void]$as.Add([ordered]@{ name = 'settlement_terminal'; passed = (([string]$settle.settlement -ceq 'SETTLED') -or ([string]$settle.settlement -ceq 'ALREADY_EXITED')); detail = ('settlement=' + [string]$settle.settlement) })
  [void]$as.Add([ordered]@{ name = 'hanging_pid_dead'; passed = [bool]$gone; detail = ('PID ' + [int]$worker.pid + ' observado morto apos o interrupt (resolucao fresca por PID)') })
  [void]$notes.Add('afirma apenas OUTCOMES (classificacao, interrupted, settlement, PID morto); o caminho interno do enforcement nao e inspecionado (pertence a outro worker).')
  $pass = (@($as | Where-Object { -not [bool]$_.passed }).Count -eq 0)
  return (New-ScenarioResult -ScenarioId 'RR-E2E-05' -Ordinal 5 -Title 'Worker hard hang' `
      -Status $(if ($pass) { 'pass-real' } else { 'failed' }) -Observed $observed -Assertions $as -Notes $notes)
}

# ---------------------------------------------------------------------------
# Cenario 06: no-progress stall
# ---------------------------------------------------------------------------
function Invoke-Scenario06 {
  $as = New-Object System.Collections.ArrayList
  $notes = New-Object System.Collections.ArrayList
  $tid = 'rr-e2e-06-no-progress'
  $sid = 'ses-rr-e2e-06-stall'
  $worker = Start-LaneWorker -Mode 'idle' -Seconds 240 -Tag 's06'
  $budget = New-LaneBudget -Wall 600 -NoProgress 4
  $reg = Register-LaneExecution -TaskId $tid -SessionId $sid -Worker $worker -Budget $budget
  $observed = [ordered]@{
    task_id = $tid; worker_pid = [int]$worker.pid; job_assigned = [bool]$worker.job_assigned
    budget = $budget; registered = [ordered]@{ ok = [bool]$reg.ok; error = [string]$reg.error; enforced = [bool]$reg.enforced }
    deadline_seconds = [int]$budget['no_progress_seconds']
  }
  [void]$as.Add([ordered]@{ name = 'watchdog_execution_bound_to_real_child'; passed = [bool]$reg.ok; detail = ('ok=' + [string]$reg.ok + ' error=' + [string]$reg.error) })
  [void]$as.Add([ordered]@{ name = 'worker_job_containment_proved'; passed = [bool]$worker.job_assigned; detail = [string]$worker.job_note })
  if (-not [bool]$reg.ok) {
    return (New-ScenarioResult -ScenarioId 'RR-E2E-06' -Ordinal 6 -Title 'No-progress stall' -Status 'blocked' `
        -Observed $observed -Assertions $as -Notes $notes -Cause ('registro recusado: ' + [string]$reg.error))
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $eval = $null
  while ($sw.Elapsed.TotalSeconds -lt 45) {
    Start-Sleep -Milliseconds 400
    $eval = Get-LaneEvaluation -TaskId $tid
    if ([bool]$eval.interrupted) { break }
  }
  $sw.Stop()
  $settle = Get-LaneSettlement -TaskId $tid
  $gone = Wait-LanePidGone -ProcessId ([int]$worker.pid) -TimeoutMs 15000
  $tele = Copy-LaneTelemetry -Tag '06'
  $cls = ''
  try { $cls = [string]$eval.classification } catch { $cls = '' }
  $observed['evaluation'] = [ordered]@{
    classification = $cls; interrupted = [bool]$eval.interrupted; since_progress_s = [int]$eval.since_progress_s
    steps = [int]$eval.steps; elapsed_observed_ms = [long]$sw.ElapsedMilliseconds
  }
  $observed['settlement'] = [ordered]@{ settlement = [string]$settle.settlement; interrupted = [bool]$settle.interrupted }
  $observed['pid_gone_after_interrupt'] = [bool]$gone
  $observed['telemetry_copy'] = $tele
  [void]$as.Add([ordered]@{ name = 'worker_alive_without_progress'; passed = ([int]$eval.since_progress_s -ge [int]$budget['no_progress_seconds']); detail = ('no_progress_seconds=' + [string]$budget['no_progress_seconds'] + '; since_progress_s real=' + [string]$eval.since_progress_s + '; steps=' + [string]$eval.steps) })
  [void]$as.Add([ordered]@{ name = 'classification_no_progress'; passed = ($cls -ceq 'NO_PROGRESS'); detail = ('classificacao real=' + $cls) })
  [void]$as.Add([ordered]@{ name = 'interrupt_engaged'; passed = [bool]$eval.interrupted; detail = ('interrupted=' + [string]$eval.interrupted) })
  [void]$as.Add([ordered]@{ name = 'stalled_pid_dead'; passed = [bool]$gone; detail = ('PID ' + [int]$worker.pid + ' observado morto apos o interrupt') })
  $pass = (@($as | Where-Object { -not [bool]$_.passed }).Count -eq 0)
  return (New-ScenarioResult -ScenarioId 'RR-E2E-06' -Ordinal 6 -Title 'No-progress stall' `
      -Status $(if ($pass) { 'pass-real' } else { 'failed' }) -Observed $observed -Assertions $as -Notes $notes)
}

# ---------------------------------------------------------------------------
# Cenarios 07/08: acoes REAIS do worker alimentadas ao avaliador
# ---------------------------------------------------------------------------
function Invoke-ScenarioActionLoop {
  param([string]$ScenarioId, [int]$Ordinal, [string]$Title, [string]$Mode, [string]$ExpectedClass, [string]$TaskId, [string]$SessionId)
  $as = New-Object System.Collections.ArrayList
  $notes = New-Object System.Collections.ArrayList
  $worker = Start-LaneWorker -Mode $Mode -Seconds 600 -Tag $ScenarioId.ToLowerInvariant()
  $budget = New-LaneBudget -Wall 600 -NoProgress 600
  $reg = Register-LaneExecution -TaskId $TaskId -SessionId $SessionId -Worker $worker -Budget $budget
  $observed = [ordered]@{
    task_id = $TaskId; worker_pid = [int]$worker.pid; worker_mode = $Mode; job_assigned = [bool]$worker.job_assigned
    budget = $budget; registered = [ordered]@{ ok = [bool]$reg.ok; error = [string]$reg.error; enforced = [bool]$reg.enforced }
    actions_fed = 0; action_source = 'jsonl escrito pelo proprio processo worker (acoes reais)'
  }
  [void]$as.Add([ordered]@{ name = 'watchdog_execution_bound_to_real_child'; passed = [bool]$reg.ok; detail = ('ok=' + [string]$reg.ok + ' error=' + [string]$reg.error) })
  [void]$as.Add([ordered]@{ name = 'worker_job_containment_proved'; passed = [bool]$worker.job_assigned; detail = [string]$worker.job_note })
  if (-not [bool]$reg.ok) {
    return (New-ScenarioResult -ScenarioId $ScenarioId -Ordinal $Ordinal -Title $Title -Status 'blocked' `
        -Observed $observed -Assertions $as -Notes $notes -Cause ('registro recusado: ' + [string]$reg.error))
  }
  $cursor = 0
  $fed = 0
  $cls = 'NONE'
  $interrupted = $false
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt 60) {
    Start-Sleep -Milliseconds 350
    $batch = Read-LaneActions -LogPath ([string]$worker.action_log) -Cursor $cursor
    $cursor = [int]$batch['cursor']
    foreach ($a in @($batch['actions'])) {
      $res = Add-OrchestrationWatchdogAction -TaskId $TaskId -Tool ([string]$a['tool']) -Arguments ([string]$a['arguments']) `
        -Target ([string]$a['target']) -ResultClass ([string]$a['result_class']) -HasProgress $false `
        -AttemptN 1 -SessionId $SessionId -PolicyPath $script:repoPolicy -FlagsPath $script:repoFlags `
        -RepoRoot $RepoRoot -TelemetryRoot $script:teleRoot
      $fed++
      try { $cls = [string]$res.classification } catch { }
      if ([bool]$res.interrupted) { $interrupted = $true; break }
    }
    if ([bool]$interrupted) { break }
  }
  $sw.Stop()
  $settle = Get-LaneSettlement -TaskId $TaskId
  $gone = Wait-LanePidGone -ProcessId ([int]$worker.pid) -TimeoutMs 15000
  $tele = Copy-LaneTelemetry -Tag ([string]$Ordinal)
  $observed['actions_fed'] = $fed
  $observed['classification'] = $cls
  $observed['interrupted'] = [bool]$interrupted
  $observed['elapsed_observed_ms'] = [long]$sw.ElapsedMilliseconds
  $observed['settlement'] = [ordered]@{ settlement = [string]$settle.settlement; interrupted = [bool]$settle.interrupted }
  $observed['pid_gone_after_interrupt'] = [bool]$gone
  $observed['telemetry_copy'] = $tele
  [void]$as.Add([ordered]@{ name = 'real_actions_observed_from_worker'; passed = ($fed -gt 0); detail = ('acoes reais lidas do log do processo worker e alimentadas ao avaliador: ' + [string]$fed) })
  [void]$as.Add([ordered]@{ name = ('classification_' + $ExpectedClass.ToLowerInvariant()); passed = ($cls -ceq $ExpectedClass); detail = ('classificacao real=' + $cls + ' (esperada=' + $ExpectedClass + ')') })
  [void]$as.Add([ordered]@{ name = 'interrupt_engaged'; passed = [bool]$interrupted; detail = ('interrupted=' + [string]$interrupted) })
  [void]$as.Add([ordered]@{ name = 'worker_pid_dead'; passed = [bool]$gone; detail = ('PID ' + [int]$worker.pid + ' observado morto apos o interrupt') })
  $pass = (@($as | Where-Object { -not [bool]$_.passed }).Count -eq 0)
  return (New-ScenarioResult -ScenarioId $ScenarioId -Ordinal $Ordinal -Title $Title `
      -Status $(if ($pass) { 'pass-real' } else { 'failed' }) -Observed $observed -Assertions $as -Notes $notes)
}

# ---------------------------------------------------------------------------
# Cenario 09: interrupt failure com nao-settlement INJETADA (seam da lib)
# ---------------------------------------------------------------------------
function Invoke-Scenario09 {
  $as = New-Object System.Collections.ArrayList
  $notes = New-Object System.Collections.ArrayList
  $tid = 'rr-e2e-09-interrupt-failure'
  $sid = 'ses-rr-e2e-09-nofault'
  $worker = Start-LaneWorker -Mode 'hang' -Seconds 240 -Tag 's09'
  $budget = New-LaneBudget -Wall 4 -NoProgress 600
  $reg = Register-LaneExecution -TaskId $tid -SessionId $sid -Worker $worker -Budget $budget
  $observed = [ordered]@{
    task_id = $tid; worker_pid = [int]$worker.pid; job_assigned = [bool]$worker.job_assigned
    budget = $budget; registered = [ordered]@{ ok = [bool]$reg.ok; error = [string]$reg.error; enforced = [bool]$reg.enforced }
    injection = 'nao-settlement injetado (seam de teste); interrupt e deadline reais'
    fault_inject_token = 'stop_failure'
  }
  [void]$as.Add([ordered]@{ name = 'watchdog_execution_bound_to_real_child'; passed = [bool]$reg.ok; detail = ('ok=' + [string]$reg.ok + ' error=' + [string]$reg.error) })
  [void]$as.Add([ordered]@{ name = 'worker_job_containment_proved'; passed = [bool]$worker.job_assigned; detail = [string]$worker.job_note })
  if (-not [bool]$reg.ok) {
    return (New-ScenarioResult -ScenarioId 'RR-E2E-09' -Ordinal 9 -Title 'Interrupt failure' -Status 'blocked' `
        -Observed $observed -Assertions $as -Notes $notes -Cause ('registro recusado: ' + [string]$reg.error))
  }
  # Deadline REAL: espera ate ultrapassar wall_clock_seconds (nenhum clock
  # injetado). IMPORTANTE: NENHUMA chamada de avaliador ENFORCE antes do
  # interrupt injetado - sob o gate ENFORCE, Get-OrchestrationWatchdogEvaluation
  # e Add-OrchestrationWatchdogAction JA executam o interrupt real, o que
  # consumiria a execucao antes da injecao e devolveria o resultado terminal
  # ja armazenado (sticky). O relogio e lido do registro da execucao.
  $exec = $null
  try { $exec = $script:WatchdogExecutions[$tid] } catch { $exec = $null }
  if ($null -eq $exec) {
    return (New-ScenarioResult -ScenarioId 'RR-E2E-09' -Ordinal 9 -Title 'Interrupt failure' -Status 'blocked' `
        -Observed $observed -Assertions $as -Notes $notes -Cause 'execucao registrada nao disponivel para o interrupt injetado')
  }
  $engagedEarly = $false
  try { if ($null -ne $exec['enforcement']) { $engagedEarly = $true } } catch { $engagedEarly = $true }
  $observed['enforcement_already_engaged_before_injection'] = [bool]$engagedEarly
  [void]$as.Add([ordered]@{
    name = 'no_enforcement_before_injected_interrupt'
    passed = (-not [bool]$engagedEarly)
    detail = ('nenhum interrupt real consumido antes da injecao: enforcement=' + [string]$engagedEarly)
  })
  if ($engagedEarly) {
    return (New-ScenarioResult -ScenarioId 'RR-E2E-09' -Ordinal 9 -Title 'Interrupt failure' -Status 'failed' `
        -Observed $observed -Assertions $as -Notes $notes -Cause 'enforcement ja engajada antes do interrupt injetado (a execucao nao prova nao-settlement)')
  }
  $startedAt = [DateTime]::UtcNow
  try { $startedAt = [DateTime]$exec['started_at'] } catch { $startedAt = [DateTime]::UtcNow }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ((([DateTime]::UtcNow - $startedAt).TotalSeconds) -lt ([double]$budget['wall_clock_seconds'] + 1.0)) {
    Start-Sleep -Milliseconds 300
  }
  $elapsedReal = [int]([DateTime]::UtcNow - $startedAt).TotalSeconds
  $inter = Invoke-WatchdogProcessInterrupt -TaskId $tid -Execution $exec -Classification 'HARD_TIMEOUT' `
    -ElapsedSeconds $elapsedReal -Steps 0 -TelemetryRoot $script:teleRoot `
    -RepoRoot $RepoRoot -FaultInject 'stop_failure'
  $err = [string]$inter.error
  $sw.Stop()
  $settle = Get-LaneSettlement -TaskId $tid
  $alive = (-not (Test-LanePidGone -ProcessId ([int]$worker.pid)))
  $tele = Copy-LaneTelemetry -Tag '09'
  $observed['pre_eval'] = [ordered]@{ classification = 'HARD_TIMEOUT (deadline real do registro, sem avaliador ENFORCE)'; elapsed_s = [int]$elapsedReal }
  $observed['interrupt_result'] = [ordered]@{
    ok = [bool]$inter.ok; error = $err; detail = [string]$inter.detail
    classification = [string]$inter.classification; elapsed_s = [int]$inter.elapsed_s
    real_deadline_wait_ms = [long]$sw.ElapsedMilliseconds
  }
  $observed['settlement'] = [ordered]@{ settlement = [string]$settle.settlement; interrupted = [bool]$settle.interrupted; classification = [string]$settle.classification }
  $observed['worker_still_alive'] = [bool]$alive
  $observed['telemetry_copy'] = $tele
  [void]$as.Add([ordered]@{ name = 'real_deadline_crossed_without_injected_clock'; passed = ([int]$elapsedReal -ge [int]$budget['wall_clock_seconds']); detail = ('wall=' + [string]$budget['wall_clock_seconds'] + '; elapsed_s real lido do registro da execucao=' + [string]$elapsedReal) })
  [void]$as.Add([ordered]@{ name = 'interrupt_failure_reported_structured'; passed = (($err -ceq 'WATCHDOG_INTERRUPT_FAILED') -or ($err -ceq 'WATCHDOG_INTERRUPT_REFUSED')); detail = ('erro estruturado=' + $err + '; detalhe=' + [string]$inter.detail) })
  [void]$as.Add([ordered]@{ name = 'no_settlement_truthful'; passed = (([string]$settle.settlement -ne 'SETTLED') -and ([string]$settle.settlement -ne 'ALREADY_EXITED')); detail = ('settlement=' + [string]$settle.settlement + ' (PENDING/REFUSED: nao-settlement injetado pelo seam da lib)') })
  [void]$as.Add([ordered]@{ name = 'owned_worker_survived_failed_interrupt'; passed = [bool]$alive; detail = ('PID ' + [int]$worker.pid + ' vivo apos o interrupt que nao assentou (prova de que nada foi morto)') })
  [void]$notes.Add('nao-settlement injetado (seam de teste); interrupt e deadline reais: o token stop_failure pertence ao conjunto fechado de FaultInject da propria lib do watchdog e simula a recusa do SO no stop; o harness nao forjou relogio nem resultado.')
  [void]$notes.Add('o worker que sobreviveu e reapeado pelo backstop do Job Object da lane (spawn proprio), registrado como cleanup do harness, nunca como interrupt do watchdog.')
  $pass = (@($as | Where-Object { -not [bool]$_.passed }).Count -eq 0)
  return (New-ScenarioResult -ScenarioId 'RR-E2E-09' -Ordinal 9 -Title 'Interrupt failure' `
      -Status $(if ($pass) { 'pass-real' } else { 'failed' }) -Observed $observed -Assertions $as -Notes $notes)
}

# ---------------------------------------------------------------------------
# Cenario 10: sibling completa enquanto um child hangs
# ---------------------------------------------------------------------------
function Invoke-Scenario10 {
  $as = New-Object System.Collections.ArrayList
  $notes = New-Object System.Collections.ArrayList
  $tid = 'rr-e2e-10-sibling'
  $sid = 'ses-rr-e2e-10-hang'
  $hang = Start-LaneWorker -Mode 'hang' -Seconds 240 -Tag 's10-hang'
  $sibling = Start-LaneWorker -Mode 'sleeper' -Seconds 6 -Tag 's10-sibling'
  $budget = New-LaneBudget -Wall 12 -NoProgress 600
  $reg = Register-LaneExecution -TaskId $tid -SessionId $sid -Worker $hang -Budget $budget
  $observed = [ordered]@{
    task_id = $tid
    hanging_child = [ordered]@{ pid = [int]$hang.pid; mode = 'hang'; job_assigned = [bool]$hang.job_assigned }
    completing_child = [ordered]@{ pid = [int]$sibling.pid; mode = 'sleeper-6s'; job_assigned = [bool]$sibling.job_assigned }
    budget = $budget; registered = [ordered]@{ ok = [bool]$reg.ok; error = [string]$reg.error; enforced = [bool]$reg.enforced }
  }
  [void]$as.Add([ordered]@{ name = 'two_real_children_spawned'; passed = ([bool]$hang.job_assigned -and [bool]$sibling.job_assigned); detail = ('hang pid=' + [int]$hang.pid + ' job=' + [string]$hang.job_assigned + '; sibling pid=' + [int]$sibling.pid + ' job=' + [string]$sibling.job_assigned) })
  [void]$as.Add([ordered]@{ name = 'watchdog_execution_bound_to_real_child'; passed = [bool]$reg.ok; detail = ('ok=' + [string]$reg.ok + ' error=' + [string]$reg.error) })
  if (-not [bool]$reg.ok) {
    return (New-ScenarioResult -ScenarioId 'RR-E2E-10' -Ordinal 10 -Title 'Sibling completes while one child hangs' -Status 'blocked' `
        -Observed $observed -Assertions $as -Notes $notes -Cause ('registro recusado: ' + [string]$reg.error))
  }
  # O sibling completa (sai sozinho) enquanto o hang permanece vivo.
  $hangAliveDuringSibling = $false
  $sib = $null
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt 45) {
    if ((-not (Test-LanePidGone -ProcessId ([int]$hang.pid))) -and (Test-LanePidGone -ProcessId ([int]$sibling.pid))) {
      $hangAliveDuringSibling = $true
      break
    }
    Start-Sleep -Milliseconds 300
  }
  $sib = Wait-LaneWorkerExit -Worker $sibling -TimeoutMs 30000
  $hangAliveBeforeInterrupt = (-not (Test-LanePidGone -ProcessId ([int]$hang.pid)))
  $siblingGoneBeforeInterrupt = (Test-LanePidGone -ProcessId ([int]$sibling.pid))
  $eval = $null
  $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw2.Elapsed.TotalSeconds -lt 45) {
    Start-Sleep -Milliseconds 400
    $eval = Get-LaneEvaluation -TaskId $tid
    if ([bool]$eval.interrupted) { break }
  }
  $sw2.Stop()
  $settle = Get-LaneSettlement -TaskId $tid
  $hangGone = Wait-LanePidGone -ProcessId ([int]$hang.pid) -TimeoutMs 15000
  $tele = Copy-LaneTelemetry -Tag '10'
  $cls = ''
  try { $cls = [string]$eval.classification } catch { $cls = '' }
  $observed['sibling'] = [ordered]@{
    exited = [bool]$sib.exited; exit_code = [int]$sib.exit_code; elapsed_ms = [long]$sib.elapsed_ms
    alive_while_hang_alive = [bool]$hangAliveDuringSibling
    gone_before_interrupt = [bool]$siblingGoneBeforeInterrupt
  }
  $observed['hang'] = [ordered]@{
    alive_before_interrupt = [bool]$hangAliveBeforeInterrupt; gone_after_interrupt = [bool]$hangGone
    classification = $cls; interrupted = [bool]$eval.interrupted
  }
  $observed['settlement'] = [ordered]@{ settlement = [string]$settle.settlement; interrupted = [bool]$settle.interrupted }
  $observed['telemetry_copy'] = $tele
  [void]$as.Add([ordered]@{ name = 'sibling_completed_normally_while_hang_alive'; passed = ([bool]$sib.exited -and [int]$sib.exit_code -eq 0 -and [bool]$hangAliveDuringSibling); detail = ('sibling exit=' + [int]$sib.exit_code + '; hang vivo no mesmo instante=' + [string]$hangAliveDuringSibling) })
  [void]$as.Add([ordered]@{ name = 'hanging_child_classified_hard_timeout'; passed = ($cls -ceq 'HARD_TIMEOUT'); detail = ('classificacao real=' + $cls) })
  [void]$as.Add([ordered]@{ name = 'hanging_child_dead_after_interrupt'; passed = [bool]$hangGone; detail = ('PID ' + [int]$hang.pid + ' morto apos o interrupt') })
  [void]$as.Add([ordered]@{ name = 'sibling_never_killed_by_watchdog'; passed = ([bool]$siblingGoneBeforeInterrupt -and [int]$sib.exit_code -eq 0); detail = ('sibling saiu por conta propria (exit 0) ANTES do interrupt e nunca foi morto pelo watchdog') })
  [void]$notes.Add('o watchdog foi registrado apenas no child em hang; o sibling saiu por conta propria e sua saida normal (exit 0) e anterior ao interrupt.')
  $pass = (@($as | Where-Object { -not [bool]$_.passed }).Count -eq 0)
  return (New-ScenarioResult -ScenarioId 'RR-E2E-10' -Ordinal 10 -Title 'Sibling completes while one child hangs' `
      -Status $(if ($pass) { 'pass-real' } else { 'failed' }) -Observed $observed -Assertions $as -Notes $notes)
}

# ---------------------------------------------------------------------------
# Finalizacao (memoizada): fecha o job (backstop dos proprios spawns),
# stop gracil GATED do servico e re-observacao da porta 49374.
# ---------------------------------------------------------------------------
function Finalize-Lane {
  if ($null -ne $script:finalResult) { return $script:finalResult }
  $r = [ordered]@{ job_close_ok = $false; job_close_reason = ''; members_before_close = -1; stop_attempted = $false; stopped = $false; stop_reason = 'nao tentado (gates)'; port49374_after = '' }
  if ($null -ne $script:laneJob) {
    $mc = $null
    try { $mc = Get-RuntimeJobMemberPids -Job $script:laneJob } catch { $mc = $null }
    if (($null -ne $mc) -and [bool]$mc.Ok) { $r['members_before_close'] = [int]$mc.Count }
    try {
      $jc = Close-RuntimeJobObject -Job $script:laneJob
      $r['job_close_ok'] = [bool]$jc.Ok
      $r['job_close_reason'] = [string]$jc.Reason
    }
    catch { $r['job_close_reason'] = ('fechamento lancou: ' + (Get-LaneSafeError $_)) }
    try { Start-Sleep -Milliseconds 500 } catch { }
  }
  else { $r['job_close_reason'] = 'job nao criado nesta execucao' }
  if ((-not [string]::IsNullOrWhiteSpace($script:binaryUsed)) -and [bool]$script:isolationOk -and [bool]$script:portConfigured -and $script:portUsed -gt 0 -and [bool]$script:serviceStarted) {
    try {
      $cl = Invoke-SpikeServiceStopIfOwned -FilePath $script:binaryUsed -EnvSet $script:isoEnv -EnvRemove $script:isoRemove -WorkingDirectory $script:cwdT -IsolationProved $true -PortConfigured $true -Port $script:portUsed -WarmupAttempted $true -TimeoutMs 30000 -CleanEnvironment -StdinNul
      $r['stop_attempted'] = [bool]$cl.Attempted
      $r['stopped'] = [bool]$cl.Stopped
      $r['stop_reason'] = [string]$cl.Reason
    }
    catch { $r['stop_reason'] = ('excecao no stop final: ' + (Get-LaneSafeError $_)) }
  }
  $r['port49374_after'] = Get-ListenerFact -Port 49374
  $script:finalResult = $r
  return $r
}

function Write-LaneSummary([string]$Status, [string]$Verdict) {
  $fin = Finalize-Lane
  $converted = New-Object System.Collections.ArrayList
  foreach ($s in @($script:LaneResults)) {
    if ([string]$s['status'] -ceq 'pass-real') { [void]$converted.Add([string]$s['scenario']) }
  }
  $after = [string]$fin['port49374_after']
  $inv = (($after -eq [string]$script:owner49374Before) -and ($after -ne 'QUERY_FAILED'))
  $summary = [ordered]@{
    record = 'v3.1-watchdog-real-lane-v2-2026-10-04'
    date = (Get-LaneDate)
    lane_dir_note = 'diretorio datado contratado para esta lane (v2-lane-2026-10-04); o campo date e o carimbo REAL da execucao lido do relogio, nunca um literal do script'
    executor = 'RR-E2E-LANE-04-10 (harness scripts/ci/watchdog-real-lane-v2.ps1)'
    binary = (Get-LaneSafePath -Path ([string]$script:Lane.binary))
    version_exact = $script:Lane.version_line
    lane_status = $Status
    invariants = @(
      ('49374 intocado: owner ANTES=' + [string]$script:owner49374Before + ' DEPOIS=' + $after + '; mesma leitura nos dois snapshots (QuerySucceeded obrigatoria); nunca iniciada nem alterada por esta lane'),
      ('nenhum PID preexistente ou externo terminado: os unicos alvos possiveis de parada sao os filhos PROPRIOS desta lane (spawns do harness atribuidos ao Job Object da lane) e o servico V2 parado por CLI owned com os gates de ownership'),
      'nenhuma flag ativada: o gate do watchdog foi LIDO do registro canonico (watchdog enabled=true shadow=false); o harness nao escreve flags',
      'budgets do kernel intocados e record-only: set-budget nunca foi chamado; os orcamentos curtos usados no watchdog sao os da execucao supervisionada (spikes do harness), nao os das tasks do kernel',
      'telemetria do watchdog escrita num diretorio TEMP isolado desta execucao (cache do repo intocado) e copiada sanitizeada para o diretorio de evidencia',
      'workers com ambiente MINIMO (PATH, TEMP, TMP, SystemRoot, Windir, ComSpec, PATHEXT, PSModulePath + o estritamente necessario); nenhuma credencial/variavel do ambiente do operador e herdada'
    )
    gate = [ordered]@{
      failed = (Get-LaneSafeText -Text ([string]$script:Lane.gate.failed))
      checks = @($script:Lane.gate.checks)
      policy_path = (Get-LaneSafePath -Path ([string]$script:repoPolicy))
      flags_path = (Get-LaneSafePath -Path ([string]$script:repoFlags))
    }
    job_backstop = [ordered]@{
      close_kill = [bool]$fin['job_close_ok']; close_reason = (Get-LaneSafeText -Text ([string]$fin['job_close_reason']))
      members_before_close = [int]$fin['members_before_close']
    }
    final_stop = [ordered]@{ attempted = [bool]$fin['stop_attempted']; stopped = [bool]$fin['stopped']; reason = (Get-LaneSafeText -Text ([string]$fin['stop_reason'])) }
    port49374_owner_before = [string]$script:owner49374Before
    port49374_owner_after = $after
    port49374_untouched = [bool]$inv
    kernel_cli_calls = @($script:KernelCalls)
    results = @($script:LaneResults)
    scenario_conversion = [ordered]@{
      converted_to_real_evidence = @($converted.ToArray())
      not_converted = @($script:LaneResults | Where-Object { [string]$_['status'] -cne 'pass-real' } | ForEach-Object { [string]$_['scenario'] + ': ' + [string]$_['status'] + ' (' + [string]$_['cause'] + ')' })
      still_blocked = @(
        'RR-E2E-01..03 (portas): nao pertencem a esta lane; provedores na lane de 2026-10-03',
        'RR-E2E-16..22 (persistencia/restart): exigem sessao real + restart; fora do escopo desta lane',
        'RR-E2E-32 (flag): ativacao de flag e decisao do operador (nao delegavel)'
      )
    }
    verdict = (Get-LaneSafeText -Text $Verdict -MaxChars 1200)
    no_fake_close = $true
  }
  $path = Join-Path $script:resolvedEvidenceDir 'lane-summary.json'
  try { Write-LaneJsonAtomic $summary $path } catch { Write-LaneText ('lane-summary nao gravado: ' + (Get-LaneSafeError $_)) }
  return [ordered]@{ summary = $summary; path = $path; port49374_untouched = [bool]$inv }
}

# ===========================================================================
# Execucao
# ===========================================================================
$script:bootstrapError = ''
try {
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  . (Join-Path $RepoRoot 'scripts\runtime\lib\SpikeProcess.ps1')
  . (Join-Path $RepoRoot 'scripts\runtime\lib\AgentTranslator.ps1')
  . (Join-Path $RepoRoot 'scripts\runtime\lib\RuntimePortPreflight.ps1')
  . (Join-Path $RepoRoot 'scripts\runtime\lib\RuntimeJobObject.ps1')
  . (Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationRuntimeWatchdog.ps1')
  . (Join-Path $RepoRoot 'scripts\runtime\lib\RuntimeVersions.ps1')
  $script:repoPolicy = Join-Path $RepoRoot 'source\registry\execution-budget-policy.json'
  $script:repoFlags = Join-Path $RepoRoot 'source\registry\capability-flags.json'
}
catch { $script:bootstrapError = (Get-LaneSafeError $_) }

# Pin da lane: registry unico (fail-closed; sem literal). -OpenCodeSpec
# explicito sobrepoe e, divergente do pin, e recusado.
$PinnedVersion = ''
if ([string]::IsNullOrWhiteSpace($script:bootstrapError)) {
  try {
    $pinV2 = Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $RepoRoot
    $PinnedVersion = [string]$pinV2.Version
    if ([string]::IsNullOrWhiteSpace($OpenCodeSpec)) { $OpenCodeSpec = [string]$pinV2.Spec }
  }
  catch { $script:bootstrapError = (Get-LaneSafeError $_) }
}
$m = [regex]::Match($OpenCodeSpec, '(\d+)\.(\d+)\.(\d+)')
if ($m.Success -and (($m.Groups[1].Value + '.' + $m.Groups[2].Value + '.' + $m.Groups[3].Value) -ne $PinnedVersion)) {
  if ([string]::IsNullOrWhiteSpace($script:bootstrapError)) {
    $script:bootstrapError = ('OpenCodeSpec incompativel com o pin desta lane (esperado ' + $PinnedVersion + '): ' + $OpenCodeSpec)
  }
}

$scenarioIds = @('04', '05', '06', '07', '08', '09', '10')
$selected = New-Object System.Collections.ArrayList
foreach ($s in ([string]$ScenarioFilter -split ',')) {
  $t = $s.Trim()
  if ($scenarioIds -ccontains $t) { [void]$selected.Add($t) }
}

$exitCode = 1
$laneStatus = 'blocked'
$verdictText = ''
$summaryPath = ''

if (-not [string]::IsNullOrWhiteSpace($script:bootstrapError)) {
  $script:Lane['blocked_reason'] = ('bootstrap: ' + $script:bootstrapError)
  $script:Lane['lane_status'] = 'blocked'
  $script:Lane['verdict'] = 'lane BLOCKED antes de qualquer cenario (bootstrap); nenhum cenario executado'
  $script:Lane['no_fake_close'] = $true
  if ([string]::IsNullOrWhiteSpace($script:resolvedEvidenceDir)) {
    $er = $RepoRoot
    if ([string]::IsNullOrWhiteSpace([string]$er)) { $er = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) }
    $script:resolvedEvidenceDir = Resolve-LaneEvidenceDir -RepoRootPath ([string]$er) -Requested $EvidenceRoot
  }
  try { Write-LaneJsonAtomic (Get-LaneSafeStateProjection) (Join-Path $script:resolvedEvidenceDir 'lane-summary.json') } catch { }
  Write-LaneText ('lane BLOCKED (bootstrap): ' + $script:bootstrapError)
  exit 1
}

try {
  # ---- diretorios isolados -------------------------------------------------
  if ([string]::IsNullOrWhiteSpace($TargetHome)) {
    $baseHome = $env:RUNNER_TEMP
    if ([string]::IsNullOrWhiteSpace($baseHome)) { $baseHome = $env:TEMP }
    if ([string]::IsNullOrWhiteSpace($baseHome)) { $baseHome = [IO.Path]::GetTempPath() }
    $runId = (Get-Date).ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $TargetHome = Join-Path $baseHome ('oo-wdlane-' + $runId)
  }
  # M-2: o parametro -EvidenceRoot e' a autoridade. A variavel interna tem nome
  # PROPRIO ($script:resolvedEvidenceDir): em PowerShell nomes sao
  # case-insensitive, entao um $script:evidenceRoot sobrescrevia silenciosamente
  # o parametro e um destino explicito era ignorado (risco de sobrescrever
  # evidencia historica do repo). Resolvemos UMA VEZ por Resolve-LaneEvidenceDir
  # e nenhum destino e' gravado sem essa resolucao.
  $script:resolvedEvidenceDir = Resolve-LaneEvidenceDir -RepoRootPath $RepoRoot -Requested $EvidenceRoot
  $script:scenarioEvidenceDir = Join-Path $script:resolvedEvidenceDir 'watchdog'
  New-Item -ItemType Directory -Path $script:resolvedEvidenceDir -Force | Out-Null
  New-Item -ItemType Directory -Path $script:scenarioEvidenceDir -Force | Out-Null

  if (Test-Path -LiteralPath $TargetHome) {
    throw ('TargetHome ja existe: ' + $TargetHome + ' (home EXCLUSIVO por execucao; reuso recusado)')
  }
  $xdg = Join-Path $TargetHome 'xdg'
  $xdgData = Join-Path $TargetHome 'xdg-data'
  $xdgState = Join-Path $TargetHome 'xdg-state'
  $xdgCache = Join-Path $TargetHome 'xdg-cache'
  $homeT = Join-Path $TargetHome 'home'
  $script:cwdT = Join-Path $TargetHome 'cwd'
  $script:workRoot = Join-Path $TargetHome 'work'
  $script:teleRoot = Join-Path $TargetHome 'telemetry'
  $script:tasksRoot = Join-Path $TargetHome 'tasks'
  foreach ($d in @($xdg, $xdgData, $xdgState, $xdgCache, $homeT, $script:cwdT, $script:workRoot, $script:teleRoot, $script:tasksRoot)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
  }
  $script:isoEnv = @{
    XDG_CONFIG_HOME = $xdg
    XDG_DATA_HOME = $xdgData
    XDG_STATE_HOME = $xdgState
    XDG_CACHE_HOME = $xdgCache
    HOME = $homeT
    USERPROFILE = $homeT
  }
  $script:isoRemove = @('OPENCODE_CONFIG', 'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_CONTENT')
  Initialize-LaneHost

  Write-LaneText ('RepoRoot=' + $RepoRoot)
  Write-LaneText ('TargetHome=' + $TargetHome)
  Write-LaneText ('host=' + $script:hostExe + ' (workers sao filhos DIRETOS deste processo: parentage CIM-proven exigido pela lib)')

  # ---- gate 0: arvore limpa dentro dos write scopes da lane ----------------
  # Mes EXATO mecanismo do cenario 04 (Test-OrchestrationWriteScope: git diff
  # HEAD + git status --porcelain --untracked-files=all, untracked conta). Nao
  # substituido por git status cru de proposito: a evidencia desta lane
  # (evidence/.../v2-lane-2026-10-04) e' in-scope, entao um check ingenuo
  # bloquearia a segunda execucao local. Fail-closed: modificacao fora de
  # escopo deixada por um step ANTERIOR do job (ex.: evidencia TRACKED do
  # smoke de lifecycle) faria o verificador do cenario 04 responder
  # skipped-out-of-scope => verified_pass=false => COMPLETION_GATE_FAILED.
  # Detectamos isso AQUI, antes de qualquer cenario rodar.
  if ([string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    try {
      if ($null -eq (Get-Command -Name 'Test-OrchestrationWriteScope' -ErrorAction SilentlyContinue)) {
        . (Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationVerifier.ps1')
      }
      $scope0 = Test-OrchestrationWriteScope -RepoRoot $RepoRoot -BaseRevision 'HEAD' -WriteScopes $script:laneWriteScopes
      $out0 = @($scope0.out_of_scope)
      if (-not [bool]$scope0.ok) {
        Add-LaneGate 'clean_tree_within_lane_scopes' $false ('scope check nao comprovaravel (fail-closed): ok=' + [string]$scope0.ok + ' status=' + [string]$scope0.status + ' error=' + [string]$scope0.error)
      }
      elseif ($out0.Count -gt 0) {
        $dirty = (@($out0 | ForEach-Object { Get-LaneSafePath ([string]$_) }) -join ', ')
        Add-LaneGate 'clean_tree_within_lane_scopes' $false ('working tree com mudancas FORA do write scope desta lane (' + $out0.Count + ' path(s)): ' + $dirty + ' - um step anterior do job contaminou o checkout; os write scopes desta lane nao foram ampliados para esconder isso')
      }
      else {
        Add-LaneGate 'clean_tree_within_lane_scopes' $true ('0 fora de escopo; ' + @($scope0.in_scope).Count + ' in-scope; ' + @($scope0.dirty_untracked).Count + ' untracked in-scope')
      }
    }
    catch { Add-LaneGate 'clean_tree_within_lane_scopes' $false (Get-LaneSafeError $_) }
  }

  # ---- gate 1: binario exato ----------------------------------------------
  # Mesmo guard dos gates 2..8: depois de um gate anterior falhar, nenhum gate
  # seguinte roda (evidencia nao registra check verde apos o bloqueio).
  if ([string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    try {
      $res = Resolve-LaneBinary $BinaryPath $PinnedVersion
      $script:binaryUsed = [string]$res['Path']
      $script:Lane['binary'] = $script:binaryUsed
      $script:Lane['version_line'] = [string]$res['VersionLine']
      Add-LaneGate 'version_exact' $true ('binario exato ' + $PinnedVersion + ' (pin); obtido: ' + [string]$res['VersionLine'])
      Write-LaneText ('binario: ' + $script:binaryUsed + ' (' + [string]$res['VersionLine'] + ')')
    }
    catch { Add-LaneGate 'version_exact' $false (Get-LaneSafeError $_) }
  }

  # ---- gate 2: porta 49374 ANTES (leitura pura) ---------------------------
  if ([string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    $script:owner49374Before = Get-ListenerFact -Port 49374
    Write-LaneText ('port49374 antes: ' + $script:owner49374Before)
    Add-LaneGate 'port49374_snapshot_before' ($script:owner49374Before -ne 'QUERY_FAILED') ('leitura pura antes da lane: ' + $script:owner49374Before)
  }

  # ---- gate 3: gate do watchdog ENFORCE (lido, nunca escrito) -------------
  if ([string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    $gate = Get-WatchdogGate -FlagsPath $script:repoFlags -RepoRoot $RepoRoot
    Add-LaneGate 'watchdog_gate_enforce' ($gate -ceq 'ENFORCE') ('gate lido de ' + $script:repoFlags + ' => ' + $gate + ' (nenhuma flag escrita)')
    Write-LaneText ('gate do watchdog: ' + $gate)
  }

  # ---- gate 4: config canonica + job object da lane ----------------------
  if ([string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    try {
      $cfgPath = Join-Path $xdg 'opencode\opencode.json'
      $stems = @(New-LaneConfig -ConfigPath $cfgPath -AgentsDir (Join-Path $RepoRoot 'source\agents'))
      Add-LaneGate 'config_19_workers_built' ($stems.Count -eq 19) ('opencode.json gerado via AgentTranslator com ' + $stems.Count + ' workers')
    }
    catch { Add-LaneGate 'config_19_workers_built' $false (Get-LaneSafeError $_) }
  }
  if ([string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    $laneJob = New-RuntimeJobObject
    $script:laneJob = $laneJob
    if (-not [bool]$laneJob.Ok) {
      Add-LaneGate 'lane_job_object' $false ('job object da lane NAO criado: api=' + [string]$laneJob.Api + ' reason=' + [string]$laneJob.Reason)
    }
    else {
      $flags = Get-RuntimeJobLimitFlags -Job $laneJob
      Add-LaneGate 'lane_job_object' (([bool]$flags.Ok) -and ([bool]$flags.KillOnClose)) ('job da lane com KILL_ON_JOB_CLOSE provado: ok=' + [string]$flags.Ok + ' kill_on_close=' + [string]$flags.KillOnClose)
    }
  }

  # ---- gate 5: ciclo de vida EXPLICITO do servico V2 real ----------------
  if ([string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    try {
      $dp = Invoke-SpikeChild -FilePath $script:binaryUsed -ArgumentList @('debug', 'paths') -EnvSet $script:isoEnv -EnvRemove $script:isoRemove -WorkingDirectory $script:cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
      $dpText = [string]$dp.Stdout + "`n" + [string]$dp.Stderr
      $isoOk = ((-not [bool]$dp.TimedOut) -and ([int]$dp.ExitCode -eq 0) -and ($dpText.Contains($xdg) -or $dpText.Contains(($xdg -replace '\\', '/'))))
      $script:isolationOk = [bool]$isoOk
      Add-LaneGate 'isolation_paths' ([bool]$isoOk) ('debug paths no home isolado; rc=' + [int]$dp.ExitCode + ' timeout=' + [string]$dp.TimedOut)
    }
    catch { Add-LaneGate 'isolation_paths' $false (Get-LaneSafeError $_) }
  }
  if ([string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    $freePort = 0
    for ($try = 0; $try -lt 10; $try++) {
      $cand = Get-SpikeFreePort
      if ($cand -ne 49374) { $freePort = $cand; break }
    }
    if ($freePort -eq 0) { Add-LaneGate 'port_selection' $false 'selecao de porta livre caiu 10x em 49374 (recusada); abortado' }
    else {
      $script:portUsed = $freePort
      $pf = Invoke-PreflightPort -Port $freePort -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @($script:binaryUsed) -ExpectedProfileDir $TargetHome
      Add-LaneGate 'port_preflight_free' (([string]$pf.Outcome -ceq 'PORT_FREE') -and [bool]$pf.ShouldStart) ('preflight P22 na porta ' + $freePort + ' => ' + [string]$pf.Outcome + ' should_start=' + [string]$pf.ShouldStart)
    }
  }
  if ([string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    $sp = Invoke-SpikeChild -FilePath $script:binaryUsed -ArgumentList @('service', 'set', 'port', "$script:portUsed") -EnvSet $script:isoEnv -EnvRemove $script:isoRemove -WorkingDirectory $script:cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
    $script:portConfigured = ((-not [bool]$sp.TimedOut) -and ([int]$sp.ExitCode -eq 0))
    Add-LaneGate 'service_port_configured' ([bool]$script:portConfigured) ('service set port ' + $script:portUsed + '; rc=' + [int]$sp.ExitCode)
  }
  if ([string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    $sst = Invoke-SpikeChild -FilePath $script:binaryUsed -ArgumentList @('service', 'start') -EnvSet $script:isoEnv -EnvRemove $script:isoRemove -WorkingDirectory $script:cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul -JobObject $script:laneJob
    $script:serviceStarted = ((-not [bool]$sst.TimedOut) -and ([int]$sst.ExitCode -eq 0))
    Add-LaneGate 'service_start_explicit' ([bool]$script:serviceStarted) ('service start explicito; rc=' + [int]$sst.ExitCode + ' job_assigned=' + [string]$sst.JobAssigned)
    Add-LaneGate 'service_start_job_assigned' ([bool]$sst.JobAssigned) ('spawn do service start atribuido ao job da lane: ' + [string]$sst.JobNote)
  }
  if ([string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    $obs = Wait-PrivateListenerState -Port $script:portUsed -DeadlineSeconds 30 -Mode presence
    Add-LaneGate 'service_listener_observed' ([bool]$obs['Seen']) ('listener privado observado (deadline 30s); pid=' + [string]$obs['Pid'] + ' inconclusivas=' + [string]$obs['InconclusiveCount'])
  }
  if ([string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)) {
    $stp = Invoke-SpikeChild -FilePath $script:binaryUsed -ArgumentList @('service', 'stop') -EnvSet $script:isoEnv -EnvRemove $script:isoRemove -WorkingDirectory $script:cwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
    Add-LaneGate 'service_stop_owned' ((-not [bool]$stp.TimedOut) -and ([int]$stp.ExitCode -eq 0)) ('service stop owned; rc=' + [int]$stp.ExitCode)
    $settleObs = Wait-PrivateListenerState -Port $script:portUsed -DeadlineSeconds 30 -Mode absence
    Add-LaneGate 'service_settlement' ([bool]$settleObs['Absent']) ('ausencia conclusiva do listener apos stop (deadline 30s); inconclusivas=' + [string]$settleObs['InconclusiveCount'])
  }
}
catch {
  Add-LaneGate 'lane_setup_exception' $false (Get-LaneSafeError $_)
}

# ---- veredito dos gates antes dos cenarios --------------------------------
$gateOk = [string]::IsNullOrWhiteSpace([string]$script:Lane.gate.failed)
if (-not $gateOk) {
  Write-LaneText ('lane BLOCKED nos gates: ' + [string]$script:Lane.gate.failed)
  foreach ($s in $scenarioIds) {
    [void](New-ScenarioResult -ScenarioId ('RR-E2E-' + $s) -Ordinal ([int]$s) -Title 'not-run' -Status 'not-run' `
        -Observed ([ordered]@{ note = 'lane bloqueada nos gates; cenario nao executado (max 1 tentativa, sem repeticao)' }) `
        -Assertions @() -Notes @('gate de lane falhou antes de qualquer cenario: ' + [string]$script:Lane.gate.failed) -Cause ([string]$script:Lane.gate.failed))
  }
  $fin = Finalize-Lane
  $sum = Write-LaneSummary -Status 'blocked' -Verdict ('lane BLOCKED honesta nos gates (' + [string]$script:Lane.gate.failed + '); nenhum cenario executado; sem fake-close')
  $script:Lane['lane_status'] = 'blocked'
  $script:Lane['verdict'] = $sum.summary['verdict']
  $script:Lane['no_fake_close'] = $true
  try { Write-LaneJsonAtomic (Get-LaneSafeStateProjection) (Join-Path $script:scenarioEvidenceDir 'lane-run.json') } catch { }
  Write-LaneText ('lane-summary: ' + [string]$sum.path)
  exit 1
}

# ---- cenarios (max 1 tentativa cada) --------------------------------------
$scenarioTitles = @{
  '04' = 'Worker normal completion'
  '05' = 'Worker hard hang'
  '06' = 'No-progress stall'
  '07' = 'Repeated identical action'
  '08' = 'Repeated short cycle'
  '09' = 'Interrupt failure'
  '10' = 'Sibling completes while one child hangs'
}
foreach ($s in $scenarioIds) {
  if (-not ($selected -ccontains $s)) {
    [void](New-ScenarioResult -ScenarioId ('RR-E2E-' + $s) -Ordinal ([int]$s) -Title ([string]$scenarioTitles[$s]) -Status 'not-run' `
        -Observed ([ordered]@{ note = 'fora do ScenarioFilter desta execucao' }) -Assertions @() `
        -Notes @('ScenarioFilter=' + $ScenarioFilter) -Cause 'nao selecionado nesta execucao')
    continue
  }
  $ordinal = [int]$s
  try {
    switch ($ordinal) {
      4 { [void](Invoke-Scenario04) }
      5 { [void](Invoke-Scenario05) }
      6 { [void](Invoke-Scenario06) }
      7 { [void](Invoke-ScenarioActionLoop -ScenarioId 'RR-E2E-07' -Ordinal 7 -Title ([string]$scenarioTitles['07']) -Mode 'repeat' -ExpectedClass 'REPEATED_ACTION' -TaskId 'rr-e2e-07-repeated-action' -SessionId 'ses-rr-e2e-07-repeats') }
      8 { [void](Invoke-ScenarioActionLoop -ScenarioId 'RR-E2E-08' -Ordinal 8 -Title ([string]$scenarioTitles['08']) -Mode 'cycle' -ExpectedClass 'REPEATED_CYCLE' -TaskId 'rr-e2e-08-repeated-cycle' -SessionId 'ses-rr-e2e-08-cycle') }
      9 { [void](Invoke-Scenario09) }
      10 { [void](Invoke-Scenario10) }
    }
  }
  catch {
    [void](New-ScenarioResult -ScenarioId ('RR-E2E-' + $s) -Ordinal $ordinal -Title ([string]$scenarioTitles[$s]) -Status 'failed' `
        -Observed ([ordered]@{ error = (Get-LaneSafeError $_) }) `
        -Assertions @() -Notes @('excecao do harness no cenario; uma unica tentativa, sem repeticao') -Cause ('excecao no harness: ' + (Get-LaneSafeError $_)))
  }
}

# ---- resumo final + exit code --------------------------------------------
$converted = New-Object System.Collections.ArrayList
foreach ($r in @($script:LaneResults)) {
  if ([string]$r['status'] -ceq 'pass-real') { [void]$converted.Add([string]$r['scenario']) }
}
$notPass = @($script:LaneResults | Where-Object { [string]$_['status'] -cne 'pass-real' })
$laneStatus = 'ok'
if (@($notPass).Count -gt 0) { $laneStatus = 'incompleta' }
$verdictParts = New-Object System.Collections.ArrayList
foreach ($r in @($script:LaneResults)) {
  [void]$verdictParts.Add(([string]$r['scenario'] + '=' + [string]$r['status'] + $(if ([string]$r['cause'] -ne '') { ' (' + [string]$r['cause'] + ')' } else { '' })))
}
$verdictText = ('lane ' + $laneStatus + ': ' + ($verdictParts -join ' | '))
$sum = Write-LaneSummary -Status $laneStatus -Verdict $verdictText
if ([bool]$sum['port49374_untouched']) {
  Write-LaneText ('49374 intocado: ' + [string]$script:owner49374Before + ' -> ' + [string]$sum.summary['port49374_owner_after'])
}
else {
  Write-LaneText ('ATENCAO: invariante 49374 nao confirmada (' + [string]$script:owner49374Before + ' -> ' + [string]$sum.summary['port49374_owner_after'] + ')')
  $verdictText = $verdictText + ' | INVARIANTE 49374 NAO CONFIRMADA'
  $laneStatus = 'incompleta'
  $sum = Write-LaneSummary -Status $laneStatus -Verdict $verdictText
}
Write-LaneText ('lane-summary: ' + [string]$sum.path)
$script:Lane['lane_status'] = $laneStatus
$script:Lane['verdict'] = $verdictText
$script:Lane['converted_to_real_evidence'] = @($converted.ToArray())
$script:Lane['no_fake_close'] = $true
try { Write-LaneJsonAtomic (Get-LaneSafeStateProjection) (Join-Path $script:scenarioEvidenceDir 'lane-run.json') } catch { }
Write-LaneText ('VEREDITO: ' + $verdictText)

if ($laneStatus -eq 'ok') { $exitCode = 0 } else { $exitCode = 1 }
exit $exitCode
