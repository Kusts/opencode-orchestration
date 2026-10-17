#!>
#<#
# .SYNOPSIS
#     Lane runtime-real de cross-session (RR-E2E-16..22) + probes de capabilities
#     V2-native (8 features do registry) contra o binario V2 EXATO do pin vigente.
# .DESCRIPTION
#     Harness de evidencia da closure V3.1 (2026-10-05). NAO e produto: e
#     test harness/evidence tooling especifico, seguindo o precedente da lane
#     watchdog (scripts/ci/watchdog-real-lane-v2.ps1).
#
#     Cenarios executados em runtime REAL (servico gerenciado V2 iniciado
#     explicitamente: set port -> start -> listener observado -> stop owned ->
#     settlement; backstop de Job Object criado ANTES do start):
#
#       RR-E2E-16  root session real fechada no meio da task: task persistida,
#                  estado nao desaparece, nenhuma conclusao falsa, recuperacao.
#       RR-E2E-17  restart real do OpenCode (stop owned + settlement + start)
#                  com task ativa: comportamento observado apos o restart.
#       RR-E2E-18  child real (parentID) reconciliado apos restart real,
#                  com observacao derivada de probes REST reais.
#       RR-E2E-19  child ausente: ausencia PROVADA por probe conclusivo;
#                  SESSION_LOST exige prova; ausencia desconhecida nunca
#                  vira sucesso (controle negativo com AbsenceProven=false).
#       RR-E2E-20  Continuation Envelope: sessao antiga -> estado persistido ->
#                  sessao substituta REAL -> envelope consumido por processo
#                  fresco -> retomada correta (rebind + estado preservado).
#       RR-E2E-21  estado da task preservado atraves da substituicao de sessao.
#       RR-E2E-22  V1 real: binario do pin, superficie sem resume nativo
#                  (observada), plano fresh-session (native_resume=false).
#
#     Resultados por cenario: pass-real | fail | blocked. blocked nunca e pass
#     e sempre carrega o motivo. Falta de infraestrutura NUNCA converte em
#     PASS. Evidencia sanitizada (nenhum password/URL/host), atomica, com
#     timeout por cenario e cleanup de estado temporario no finally.
#
#     Probes V2-native (-SkipCapabilityProbes para pular): read/test-oriented,
#     contra a config da lane; cada probe registra command/config usado,
#     expected, observed e classificacao honesta
#     supported|unsupported|ambiguous. A coleta NUNCA habilita feature:
#     nenhum registro de v2-native-evidence.json e escrito aqui; a decisao de
#     gravar registros exatos e do operator/Planner apos revisao.
#
#     Seguranca: home isolado EXCLUSIVO em TEMP; -CleanEnvironment nos
#     filhos; OPENCODE_PASSWORD lido de service.json e usado apenas como env
#     dos filhos, nunca logado; nenhum PID externo e terminado (o Job Object
#     so contem o processo do service start desta lane); 49374 recusada.
#     Opt-in de modelo (operator-owned, harness-only): -ModelKeyEnvName
#     recebe o NOME de uma variavel de ambiente (nunca o valor; default ''
#     = desligado, comportamento atual intacto). Quando preenchido E a env
#     existir no chamador, o valor e repassado pontualmente (passthrough)
#     SOMENTE aos filhos 'opencode run' das pernas model-dependent 18/20/21,
#     via EnvSet isolado; logs e telemetria registram apenas o NOME e
#     Get-LaneSafeText tambem redige padroes NOME=valor. Env ausente/vazia
#     => pernas seguem blocked (fail-closed; nenhum PASS forjado). Ex.
#     operator-owned: -ModelKeyEnvName 'OPENCODE_GO_API_KEY' com o modelo
#     opencode-go/muse-spark-1.3-contributor (verificado em 2026-10-08).
#     Com opt-in, a lane importa o credential store do usuario (somente
#     auth.json,account.json de XDG_DATA e kv.json,model.json,service.json
#     de XDG_STATE) para o perfil isolado antes dos turnos 18/20/21, via
#     Import-LaneSessionCredentialStore; sem opt-in ou sem arquivos, nada
#     e copiado e os turnos model seguem blocked (fail-closed).
#     Cada turn 'opencode run' recebe um Job Object proprio com KILL_ON_JOB_CLOSE
#     (contencao POS-SPAWN + rejeicao de resultado sem atribuicao comprovada;
#     NAO e contencao pre-execucao: rc sem atribuicao nao conta como ok; job
#     indisponivel => turn recusado, fail-closed).
#     Falha de turn (rc!=0/timeout) persiste excerpt sanitizado (cap 1200) como
#     proof 'model-turn-output' (diag informativa ok=true; veredito intacto).
#     O turn da fresh session V1 (22) segue operator-owned, sem mudanca de
#     veredito nesta lane.
#     PowerShell 5.1 compativel; ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$BinaryPath = '',
    [string]$ExpectedVersion = '',
    [string]$EvidenceDir = '',
    [string]$TargetHome = '',
    [int]$ScenarioTimeoutSeconds = 240, # janela nominal por cenario; enforcement ativo nos pontos pesados (ex.: secao V1 do cenario 22)
    [int]$ApiTimeoutMs = 20000,
    [string[]]$ScenarioFilter = @(),
    [switch]$SkipCapabilityProbes,
    [string]$V1BinaryPath = '',
    [switch]$InstallV1IfMissing,
    [string]$V1NpmSpec = '',
    [int]$KernelTimeoutMs = 90000,
    [string]$ModelKeyEnvName = '',
    [string]$TurnModel = 'opencode-go/muse-spark-1.3-contributor'
)
$ErrorActionPreference = 'Stop'

# ---------- opt-in de model-key (operator-owned; NOME apenas, nunca valor) ----------
# Validacao estrita do NOME (charset de env; ate 64 chars). Nome invalido ou
# vazio => opt-in desligado (fail-closed; pernas model-dependent seguem blocked).
$script:ModelKeyEnvNameClean = ''
try {
    $candKeyName = ([string]$ModelKeyEnvName).Trim()
    if (($candKeyName.Length -gt 0) -and ($candKeyName.Length -le 64) -and ($candKeyName -cmatch '^[A-Za-z_][A-Za-z0-9_]*$')) { $script:ModelKeyEnvNameClean = $candKeyName }
    $candKeyName = ''
} catch { $script:ModelKeyEnvNameClean = '' }

# ---------- modelo dos turns (operator-owned; default = baseline validado) ----------
# -TurnModel vazio/invalido => default (fail-closed para o baseline).
$script:TurnModelClean = 'opencode-go/muse-spark-1.3-contributor'
try {
    $candModel = ([string]$TurnModel).Trim()
    if (($candModel.Length -gt 0) -and ($candModel.Length -le 128) -and ($candModel -cmatch '^[A-Za-z0-9][A-Za-z0-9_./-]*$')) { $script:TurnModelClean = $candModel }
    $candModel = ''
} catch { $script:TurnModelClean = 'opencode-go/muse-spark-1.3-contributor' }

# ---------- bootstrap ----------
function Get-LaneRepoRoot {
    try { return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) } catch { return (Get-Location).Path }
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-LaneRepoRoot }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$libDir = Join-Path $RepoRoot 'scripts\runtime\lib'
$v3LibDir = Join-Path $RepoRoot 'scripts\v3\lib'
foreach ($lib in @(
        (Join-Path $libDir 'RuntimeVersions.ps1'),
        (Join-Path $libDir 'SpikeProcess.ps1'),
        (Join-Path $libDir 'RuntimePortPreflight.ps1'),
        (Join-Path $libDir 'RuntimeJobObject.ps1'),
        (Join-Path $libDir 'AgentTranslator.ps1'),
        (Join-Path $v3LibDir 'OrchestrationSessionReconciler.ps1'),
        (Join-Path $v3LibDir 'CapabilitySanitize.ps1'))) {
    if (-not (Test-Path -LiteralPath $lib -PathType Leaf)) {
        Write-Error ('lane bootstrap: lib ausente: ' + $lib)
        exit 1
    }
    . $lib
}
if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
    $v2pin = $null
    try { $v2pin = Get-OrchestrationRuntimeVersion -Name 'v2' -RepoRoot $RepoRoot } catch { Write-Error ('pin v2 irresolvivel: ' + $_.Exception.Message); exit 1 }
    if ($null -eq $v2pin -or [string]::IsNullOrWhiteSpace([string]$v2pin.version)) { Write-Error 'pin v2 ausente no registry.'; exit 1 }
    $ExpectedVersion = [string]$v2pin.version
}

# ---------- sanitizacao / evidencia ----------
function Get-LaneSafeText {
    [CmdletBinding()] param($Value, [int]$Max = 200)
    try {
        if ($null -eq $Value) { return '' }
        $v = [string]$Value
        $v = $v -replace '(?i)sk-[A-Za-z0-9_-]+', '[REDACTED]'
        $v = $v -replace '(?i)(password|token|secret|authorization)\s*[=:]\s*[^\s,;"]+', '$1=[REDACTED]'
        try {
            # opt-in: redige tambem padroes NOME=valor da env configurada
            # (registra-se apenas o NOME; o valor nunca transita em strings de log)
            if (-not [string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean)) {
                $escKeyName = [regex]::Escape($script:ModelKeyEnvNameClean)
                $v = $v -replace ('(?i)' + $escKeyName + '\s*[=:]\s*[^\s,;"]+'), ($script:ModelKeyEnvNameClean + '=[REDACTED]')
            }
        } catch { }
        $v = $v -replace '(?i)https?://[^\s"]+', '[REDACTED-URL]'
        $v = $v -replace '[\x00-\x1f]', ' '
        $v = $v.Trim()
        if ($v.Length -gt $Max) { $v = $v.Substring(0, $Max) }
        return $v
    } catch { return '' }
}
function Write-LaneJson {
    [CmdletBinding()] param($Object, [string]$Path)
    try {
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $tmp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($tmp, ((($Object | ConvertTo-Json -Depth 12).TrimEnd() + "`n") -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
        return $true
    } catch { return $false }
}
function Get-LaneTimestampUtc {
    return ([DateTime]::UtcNow.ToString('o'))
}

# ---------- trilha F2 (lifecycle, advisory-only; nunca gate) ----------
# Vocabulario: LANE_START, SERVICE_START_REQUESTED/STARTED,
# SERVICE_STOP_REQUESTED/STOPPED, EXPECTED_TEST_RESTART (classification no
# proprio evento, emitido por Write-LaneServiceCycleTrail nos 5 pontos de
# restart), PID_CHANGED (quando antes/depois observados divergem),
# MODEL_TURN_STARTED/FINISHED, SERVICE_UNRESPONSIVE, EXPECTED_TEST_STOP,
# LANE_FINISHED, LANE_CLEANUP. UNEXPECTED_EXIT permanece NOT_OBSERVED
# (todos os stops desta lane sao solicitados; sem deteccao de saida
# inesperada nesta trilha). Nenhum evento aqui decide PASS/FAIL: a trilha
# e evidencia auxiliar; lane-summary.json segue sendo a obrigatoria.
$script:LaneTrailMaxBytes = 262144
function Get-LaneTrailPath {
    # Caminho confinado: evidence da lane quando disponivel; senao
    # cache/v3/telemetry sob o RepoRoot. Nunca lanca; '' = desligada.
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:EvidenceDir)) { return (Join-Path $script:EvidenceDir 'lane-lifecycle-trail.jsonl') }
        $rr = ''
        try { $rr = [string]$RepoRoot } catch { $rr = '' }
        if ([string]::IsNullOrWhiteSpace($rr)) { return '' }
        return (Join-Path $rr 'cache\v3\telemetry\session-lane-lifecycle-trail.jsonl')
    } catch { return '' }
}
function Get-LaneCurrentListenerPid {
    # Snapshot pontual do OwningPID (fail-closed; 0 = desconhecido).
    # Uso exclusivo da trilha; nunca decide gate. Nunca lanca.
    try {
        if ([int]$script:Port -le 0) { return 0 }
        $ln = $null
        try { $ln = Get-PreflightNetTCPListenerBounded -Port ([int]$script:Port) -TimeoutMs 5000 } catch { return 0 }
        if (($null -ne $ln) -and ([bool]$ln.QuerySucceeded) -and ([bool]$ln.Exists) -and ($null -ne $ln.OwningPID)) {
            return ([int]$ln.OwningPID)
        }
        return 0
    } catch { return 0 }
}
function Write-LaneTrailEvent {
    # Append JSONL advisory-only: confinado, bounded, sanitizado, fail-closed.
    # Retorna $true/$false; nunca lanca; falha silenciosa (a evidencia
    # obrigatoria continua sendo lane-summary.json).
    [CmdletBinding()] param([string]$Event = '', [hashtable]$Fields = $null)
    try {
        $evName = ''
        try { $evName = (Get-LaneSafeText $Event 64) } catch { $evName = '' }
        if ([string]::IsNullOrWhiteSpace($evName)) { return $false }
        $trailPath = ''
        try { $trailPath = Get-LaneTrailPath } catch { $trailPath = '' }
        if ([string]::IsNullOrWhiteSpace($trailPath)) { return $false }
        $full = ''
        try { $full = [IO.Path]::GetFullPath($trailPath) } catch { return $false }
        $okConfine = $false
        try {
            $sep = [string][IO.Path]::DirectorySeparatorChar
            $cands = @()
            try { if (-not [string]::IsNullOrWhiteSpace($script:EvidenceDir)) { $cands += ([IO.Path]::GetFullPath([string]$script:EvidenceDir)) } } catch { }
            try {
                $rrloc = ''
                try { $rrloc = [string]$RepoRoot } catch { $rrloc = '' }
                if (-not [string]::IsNullOrWhiteSpace($rrloc)) { $cands += ([IO.Path]::GetFullPath((Join-Path $rrloc 'cache\v3\telemetry'))) }
            } catch { }
            foreach ($base in @($cands)) {
                if ([string]::IsNullOrWhiteSpace($base)) { continue }
                $b = ([string]$base).TrimEnd('\', '/')
                if (($full + $sep).StartsWith(($b + $sep), [StringComparison]::OrdinalIgnoreCase)) { $okConfine = $true; break }
            }
        } catch { return $false }
        if (-not [bool]$okConfine) { return $false }
        $maxBytes = 262144
        try { if ($null -ne $script:LaneTrailMaxBytes -and ([int]$script:LaneTrailMaxBytes -gt 0)) { $maxBytes = [int]$script:LaneTrailMaxBytes } } catch { }
        try {
            $fi = $null
            try { $fi = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue } catch { $fi = $null }
            if (($null -ne $fi) -and ([long]$fi.Length -gt [long]$maxBytes)) { return $false }
        } catch { }
        $parent = ''
        try { $parent = Split-Path -Parent $full } catch { return $false }
        if ([string]::IsNullOrWhiteSpace($parent)) { return $false }
        try { if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null } } catch { return $false }
        $row = [ordered]@{ ts = ''; lane = 'session-real-lane-v2'; advisory_only = $true; event = $evName }
        try { $row.ts = (Get-LaneTimestampUtc) } catch { $row.ts = '' }
        if ($null -ne $Fields) {
            foreach ($k in @($Fields.Keys)) {
                $ks = ''
                try { $ks = ([string]$k -replace '[^A-Za-z0-9_]', '_') } catch { $ks = '' }
                if ([string]::IsNullOrWhiteSpace($ks)) { continue }
                if ($ks.Length -gt 32) { $ks = $ks.Substring(0, 32) }
                $fv = $Fields[$k]
                if (($fv -is [int]) -or ($fv -is [long]) -or ($fv -is [bool])) { $row[$ks] = $fv }
                else {
                    $sv = ''
                    try { $sv = (Get-LaneSafeText ([string]$fv) 200) } catch { $sv = '' }
                    $row[$ks] = $sv
                }
            }
        }
        $json = ''
        try { $json = ($row | ConvertTo-Json -Depth 6 -Compress) } catch { return $false }
        if ([string]::IsNullOrWhiteSpace($json)) { return $false }
        # Teto preciso em bytes UTF-8 incluindo o newline: recusa quando o
        # tamanho atual + bytes da linha ultrapassa o teto (o pre-check acima
        # so barra arquivo ja acima do teto; arquivo exatamente no teto ou
        # proximo dele ainda escreveria e estouraria sem este gate).
        try {
            $lineText = ($json + "`n")
            $lineBytes = [long]0
            try { $lineBytes = [long](New-Object Text.UTF8Encoding $false).GetByteCount($lineText) } catch { $lineBytes = [long]0 }
            if ([long]$lineBytes -le 0) { return $false }
            $curLen = [long]0
            try {
                $fiNow = $null
                try { $fiNow = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue } catch { $fiNow = $null }
                if ($null -ne $fiNow) { $curLen = [long]$fiNow.Length }
            } catch { $curLen = [long]0 }
            if (([long]$curLen + [long]$lineBytes) -gt [long]$maxBytes) { return $false }
        } catch { return $false }
        try { [IO.File]::AppendAllText($full, ($json + "`n"), (New-Object Text.UTF8Encoding $false)) } catch { return $false }
        return $true
    } catch { return $false }
}
function Write-LaneServiceCycleTrail {
    # Emite o ciclo stop->start de UM ponto de restart como linhas
    # advisory-only, na ordem real das operacoes (bloco stop antes do bloco
    # start; EXPECTED_TEST_RESTART por ultimo; PID_CHANGED quando aplicavel).
    # Cada bloco sai SOMENTE junto a operacao correspondente: sem $StopResult
    # (caminhos somente-start como post17-gate/pre19-gate) nenhum evento de
    # stop e emitido; sem $StartResult nenhum evento de start e emitido.
    # REQUESTED = tentativa (operacao invocada, sempre que o resultado da
    # operacao existe); STOPPED/STARTED = conclusao observada (STOPPED so
    # com settlement Absent=true; STARTED so com presence Seen=true).
    # Tentativa sem observacao positiva (timeout, Absent=false, Seen=false
    # ou Settle/Presence $null) emite so REQUESTED, sem evento conclusivo.
    # $StopResult/$StartResult: resultados de Invoke-SpikeChild (ExitCode/
    # TimedOut/JobAssigned); $Settle/$Presence: resultados de
    # Wait-LaneListener (Absent/Seen/OwningPID). Ausente ($null) vira
    # 'NOT_OBSERVED' nos campos; operacao ausente omite o bloco inteiro.
    # PID_CHANGED sai quando antes/depois divergem.
    [CmdletBinding()] param([string]$Site = '', [int]$PidBefore = 0, $StopResult = $null, $StartResult = $null, $Settle = $null, $Presence = $null)
    try {
        $siteSafe = ''
        try { $siteSafe = (Get-LaneSafeText $Site 64) } catch { $siteSafe = '' }
        if ([string]::IsNullOrWhiteSpace($siteSafe)) { $siteSafe = 'unknown-site' }
        $stopRc = 'NOT_OBSERVED'; $stopTo = 'NOT_OBSERVED'
        try { if ($null -ne $StopResult) { $stopRc = [int]$StopResult.ExitCode; $stopTo = [bool]$StopResult.TimedOut } } catch { }
        $startRc = 'NOT_OBSERVED'; $startJob = 'NOT_OBSERVED'
        try { if ($null -ne $StartResult) { $startRc = [int]$StartResult.ExitCode; $startJob = [bool]$StartResult.JobAssigned } } catch { }
        $settled = 'NOT_OBSERVED'; $seenAfter = 'NOT_OBSERVED'; $pidAfter = 0
        try { if ($null -ne $Settle) { $settled = [bool]$Settle.Absent } } catch { }
        try {
            if ($null -ne $Presence) {
                $seenAfter = [bool]$Presence.Seen
                try { if ($null -ne $Presence.OwningPID) { $pidAfter = [int]$Presence.OwningPID } } catch { $pidAfter = 0 }
            }
        } catch { }
        $portNum = 0
        try { $portNum = [int]$script:Port } catch { $portNum = 0 }
        $hasStop = ($null -ne $StopResult)
        $hasStart = ($null -ne $StartResult)
        $stopConclusive = $false
        try { $stopConclusive = ((($null -ne $Settle) -and ([bool]$Settle.Absent -eq $true))) } catch { $stopConclusive = $false }
        $startConclusive = $false
        try { $startConclusive = ((($null -ne $Presence) -and ([bool]$Presence.Seen -eq $true))) } catch { $startConclusive = $false }
        if ([bool]$hasStop) {
            [void](Write-LaneTrailEvent -Event 'SERVICE_STOP_REQUESTED' -Fields @{ site = $siteSafe; pid_before = [int]$PidBefore; port = $portNum })
            if ([bool]$stopConclusive) {
                [void](Write-LaneTrailEvent -Event 'SERVICE_STOPPED' -Fields @{ site = $siteSafe; stop_rc = $stopRc; stop_timeout = $stopTo; settlement = $settled })
            }
        }
        if ([bool]$hasStart) {
            [void](Write-LaneTrailEvent -Event 'SERVICE_START_REQUESTED' -Fields @{ site = $siteSafe; port = $portNum })
            if ([bool]$startConclusive) {
                [void](Write-LaneTrailEvent -Event 'SERVICE_STARTED' -Fields @{ site = $siteSafe; start_rc = $startRc; job_assigned = $startJob; pid_after = $pidAfter; presence_seen = $seenAfter })
            }
        }
        [void](Write-LaneTrailEvent -Event 'EXPECTED_TEST_RESTART' -Fields @{ site = $siteSafe; classification = 'EXPECTED_TEST_RESTART'; pid_before = [int]$PidBefore; pid_after = $pidAfter; port = $portNum; job_assigned = $startJob; stop_rc = $stopRc; stop_timeout = $stopTo; start_rc = $startRc; settlement = $settled; presence_seen = $seenAfter })
        try {
            if (([int]$PidBefore -gt 0) -and ([int]$pidAfter -gt 0) -and ([int]$PidBefore -ne [int]$pidAfter)) {
                [void](Write-LaneTrailEvent -Event 'PID_CHANGED' -Fields @{ site = $siteSafe; pid_before = [int]$PidBefore; pid_after = $pidAfter })
            }
        } catch { }
        return $true
    } catch { return $false }
}

# ---------- estado da lane ----------
$script:LaneStarted = Get-LaneTimestampUtc
$script:ExitDone = $false
$script:LaneChecks = New-Object System.Collections.ArrayList
$script:LaneNotes = New-Object System.Collections.ArrayList
$script:ScenarioResults = New-Object System.Collections.ArrayList
$script:ProbeResults = New-Object System.Collections.ArrayList
$script:svcJob = $null
$script:Exe = ''
$script:Port = 0
$script:IsoEnv = @{}
$script:IsoRemove = @('OPENCODE_CONFIG', 'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_CONTENT')
$script:HomeT = ''
$script:CwdT = ''
$script:AuthEnv = @{}
$script:KernelTasksDir = ''
$script:EnvelopeDir = ''
$script:OpenApiPaths = $null
$script:owner49374Before = 'UNSET'
$script:LaneStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Add-LaneCheck([string]$Name, [bool]$Ok, [string]$Detail) {
    [void]$script:LaneChecks.Add([ordered]@{ check = $Name; ok = [bool]$Ok; detail = (Get-LaneSafeText $Detail 400) })
}
function Add-LaneNote([string]$Text) {
    [void]$script:LaneNotes.Add((Get-LaneSafeText $Text 400))
}
function Set-ScenarioResult([string]$Id, [string]$Status, [string]$Detail, $Proofs, $Coverage) {
    $row = [ordered]@{
        scenario_id = $Id
        status      = $Status
        detail      = (Get-LaneSafeText $Detail 500)
        proofs      = @($Proofs)
        coverage    = @($Coverage)
        at          = (Get-LaneTimestampUtc)
    }
    $replaced = $false
    for ($i = 0; $i -lt $script:ScenarioResults.Count; $i++) {
        if ([string]$script:ScenarioResults[$i]['scenario_id'] -ceq $Id) { $script:ScenarioResults[$i] = $row; $replaced = $true; break }
    }
    if (-not $replaced) { [void]$script:ScenarioResults.Add($row) }
    Write-Host ('[session-lane] ' + $Id + ' => ' + $Status + ' :: ' + (Get-LaneSafeText $Detail 120))
}
function Add-ScenarioProof($Proofs, [string]$Name, [bool]$Ok, [string]$Detail) {
    [void]$Proofs.Add([ordered]@{ proof = $Name; ok = [bool]$Ok; detail = (Get-LaneSafeText $Detail 300) })
    return $Proofs
}
function Fail-Lane([string]$Message) {
    $summary = New-LaneSummary -Status 'failed' -Reason $Message
    $main = Join-Path $script:EvidenceDir 'lane-summary.json'
    [void](Write-LaneJson $summary $main)
    try { [void](Write-LaneJson $summary ($main + '.cleanup.json')) } catch { }
    Write-Host ('[session-lane] FALHA: ' + (Get-LaneSafeText $Message 200))
    Write-Host ('[session-lane] evidencia (failed) em ' + $main)
    $script:ExitDone = $true
    exit 1
}

function New-LaneSummary([string]$Status, [string]$Reason) {
    $scen = @()
    foreach ($r in @($script:ScenarioResults)) { $scen += $r }
    $probe = @()
    foreach ($p in @($script:ProbeResults)) { $probe += $p }
    $pass = @($scen | Where-Object { [string]$_['status'] -ceq 'pass-real' }).Count
    $fail = @($scen | Where-Object { [string]$_['status'] -ceq 'fail' }).Count
    $blocked = @($scen | Where-Object { [string]$_['status'] -ceq 'blocked' }).Count
    return [ordered]@{
        lane                 = 'session-real-lane-v2'
        purpose              = 'V3.1 closure: RR-E2E-16..22 runtime-real + V2-native capability probes'
        date                 = ([DateTime]::UtcNow.ToString('yyyy-MM-dd'))
        started_at           = $script:LaneStarted
        finished_at          = (Get-LaneTimestampUtc)
        status               = $Status
        reason               = (Get-LaneSafeText $Reason 400)
        runtime_pin          = $ExpectedVersion
        binary               = (Get-LaneSafeText $script:ExeForEvidence 240)
        service_port         = $script:Port
        scenarios            = $scen
        scenario_counts      = [ordered]@{ pass_real = $pass; fail = $fail; blocked = $blocked }
        capability_probes    = $probe
        probes_skipped       = [bool]$SkipCapabilityProbes
        model_key_env        = (Get-LaneModelKeyLogToken)
        checks               = @($script:LaneChecks)
        notes                = @($script:LaneNotes)
        isolation            = 'XDG_CONFIG/DATA/STATE/CACHE + HOME/USERPROFILE no TargetHome exclusivo; -CleanEnvironment nos filhos; cwd no TargetHome; stdin fechado; password do service.json nunca logado'
        job_backstop         = 'Job Object com KILL_ON_JOB_CLOSE criado antes do service start; contem somente o processo desta lane'
        port49374_owner_before = $script:owner49374Before
    }
}

# ---------- model-key opt-in: helpers (NOME em logs; valor so em EnvSet) ----------
function Get-LaneModelKeyLogToken {
    # Token para logs/telemetria: contem apenas o NOME configurado, nunca o valor.
    if ([string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean)) { return 'model-key-env=<unset>' }
    return ('model-key-env=' + $script:ModelKeyEnvNameClean)
}
function Test-LaneModelKeyAvailable {
    # Fail-closed: true somente com NOME valido E valor presente no chamador.
    try {
        if ([string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean)) { return $false }
        $val = [Environment]::GetEnvironmentVariable($script:ModelKeyEnvNameClean, 'Process')
        return (-not [string]::IsNullOrWhiteSpace($val))
    } catch { return $false }
}
function Get-LaneModelChildEnv {
    # Passthrough pontual: copia do env base + valor da model-key, SOMENTE para
    # filhos 'opencode run' das pernas 18/20/21. O valor nunca e serializado
    # em string de log; quem loga usa Get-LaneModelKeyLogToken (NOME apenas).
    [CmdletBinding()] param($BaseEnv = $null)
    $out = @{}
    try {
        if ($null -ne $BaseEnv) { foreach ($k in @($BaseEnv.Keys)) { $out[[string]$k] = [string]$BaseEnv[$k] } }
    } catch { }
    try {
        if (Test-LaneModelKeyAvailable) {
            $out[$script:ModelKeyEnvNameClean] = [Environment]::GetEnvironmentVariable($script:ModelKeyEnvNameClean, 'Process')
        }
    } catch { }
    return $out
}
function Import-LaneSessionCredentialStore {
    # Importacao pos-gate de opt-in do credential store do usuario para o
    # perfil isolado (espelha Import-LaneProfileCredentials da MCP lane).
    # Chamar SOMENTE com Test-LaneModelKeyAvailable == $true, nos setups
    # 18/20/21 antes dos turnos. Copia APENAS os 5 nomes fixos (XDG_DATA
    # opencode/auth.json,account.json + XDG_STATE opencode/kv.json,
    # model.json,service.json, com fallback USERPROFILE/.local quando XDG_
    # vazio) para o xdg isolado sob TargetRoot. Retorna bool (true se copiou
    # ao menos 1). Valores nunca vao para log (so bool); segredos morrem
    # com TargetRoot. Sem opt-in ou sem arquivos => $false sem copiar nada;
    # a perna model segue blocked (fail-closed, sem inventar auth).
    [CmdletBinding()] param([string]$TargetRoot = '', [string]$UserDataRoot = '', [string]$UserStateRoot = '', $ReasonOut = $null)
    try {
        # Confinamento TEMP (sec): o cleanup da lane cobre SOMENTE TEMP e
        # RUNNER_TEMP; fora delas as credenciais persistiriam. Normaliza
        # (GetFullPath resolve '..') e exige prefixo por limite (base mais
        # separador, case-insensitive): irmao com prefixo parecido e escape
        # '..' sao recusados. Fora => $false SEM copiar, com reason explicito
        # via ReasonOut (opcional; sem ele, so o bool).
        $root = [string]$TargetRoot
        if ([string]::IsNullOrWhiteSpace($root)) { return $false }
        $nt = ''
        try { $nt = ([IO.Path]::GetFullPath($root)).TrimEnd('\', '/') } catch { $nt = '' }
        if ([string]::IsNullOrWhiteSpace($nt)) { return $false }
        $sep = [string][IO.Path]::DirectorySeparatorChar
        $inTemp = $false
        $tmpBase = [IO.Path]::GetTempPath()
        $runTemp = [Environment]::GetEnvironmentVariable('RUNNER_TEMP', 'Process')
        foreach ($base in @($tmpBase, $runTemp)) {
            if ([string]::IsNullOrWhiteSpace($base)) { continue }
            $nb = ''
            try { $nb = ([IO.Path]::GetFullPath($base)).TrimEnd('\', '/') } catch { $nb = '' }
            if ([string]::IsNullOrWhiteSpace($nb)) { continue }
            if (($nt + $sep).StartsWith(($nb + $sep), [StringComparison]::OrdinalIgnoreCase)) { $inTemp = $true; break }
        }
        if (-not $inTemp) {
            try { if ($ReasonOut -is [System.Management.Automation.PSReference]) { $ReasonOut.Value = 'credstore-target-fora-do-temp' } } catch { }
            return $false
        }
        if (-not (Test-LaneModelKeyAvailable)) { return $false }
        $xdgData = Join-Path $root 'xdg-data'
        $xdgState = Join-Path $root 'xdg-state'
        $userData = [string]$UserDataRoot
        if ([string]::IsNullOrWhiteSpace($userData)) {
            $userData = [Environment]::GetEnvironmentVariable('XDG_DATA_HOME', 'Process')
            if ([string]::IsNullOrWhiteSpace($userData)) { $userData = Join-Path ([Environment]::GetEnvironmentVariable('USERPROFILE', 'Process')) '.local\share' }
        }
        $userOpDir = Join-Path ([string]$userData) 'opencode'
        $profOpData = Join-Path $xdgData 'opencode'
        if (-not (Test-Path -LiteralPath $profOpData -PathType Container)) { New-Item -ItemType Directory -Path $profOpData -Force | Out-Null }
        $copiedAny = $false
        foreach ($af in @('auth.json', 'account.json')) {
            try {
                $src = Join-Path $userOpDir $af
                if (Test-Path -LiteralPath $src -PathType Leaf) {
                    Copy-Item -LiteralPath $src -Destination (Join-Path $profOpData $af) -Force
                    $copiedAny = $true
                }
            } catch { }
        }
        $userState = [string]$UserStateRoot
        if ([string]::IsNullOrWhiteSpace($userState)) {
            $userState = [Environment]::GetEnvironmentVariable('XDG_STATE_HOME', 'Process')
            if ([string]::IsNullOrWhiteSpace($userState)) { $userState = Join-Path ([Environment]::GetEnvironmentVariable('USERPROFILE', 'Process')) '.local\state' }
        }
        $userOpState = Join-Path ([string]$userState) 'opencode'
        $profOpState = Join-Path $xdgState 'opencode'
        if (-not (Test-Path -LiteralPath $profOpState -PathType Container)) { New-Item -ItemType Directory -Path $profOpState -Force | Out-Null }
        foreach ($sf in @('kv.json', 'model.json', 'service.json')) {
            try {
                $src = Join-Path $userOpState $sf
                if (Test-Path -LiteralPath $src -PathType Leaf) {
                    Copy-Item -LiteralPath $src -Destination (Join-Path $profOpState $sf) -Force
                    $copiedAny = $true
                }
            } catch { }
        }
        return [bool]$copiedAny
    } catch { return $false }
}
function Get-LaneModelTurnOutputExcerpt {
    # Excerpt diagnostico do output de um turn de modelo: stdout+stderr com
    # pre-redacao LOCAL de credenciais com aspas (NOME="v", NOME='v',
    # "NOME": "v", 'NOME': 'v', NOME=v) e depois Get-LaneSafeText com cap
    # default 1200 e teto 4000 (truncagem sempre DEPOIS da redacao). Uso: proof
    # 'model-turn-output' (ok=true, diag informativa) SOMENTE em falha do
    # turn; sucesso mantem output_excerpt=''. Get-LaneSafeText e
    # compartilhada e permanece intocada. Saida vazia vira placeholder
    # ASCII (nunca string vazia). Nao altera veredito, gate, timeout ou flag.
    [CmdletBinding()] param([string]$Stdout = '', [string]$Stderr = '', [int]$Max = 1200)
    try {
        if ($Max -le 0) { $Max = 1200 }
        if ($Max -gt 4000) { $Max = 4000 }
        $raw = (([string]$Stdout) + "`n" + ([string]$Stderr))
        # Lista fechada: credenciais relevantes do SensitiveEnvRemove da lane
        # + NOME da model-key opt-in (dinamico) + formato generico para chaves
        # desconhecidas com cara de segredo. Get-LaneSafeText nao cobre
        # valores com aspas (o valor comeca com " ou ' e o padrao sem aspas
        # nao casa); por isso a pre-redacao local, antes do cap. Valores
        # reconhecem escapes (\" nao fecha o valor) e nomes genericos exatos
        # ("password", 'token') casam com prefixo vazio/delimitador.
        $credNames = @(
            'OPENCODE_PASSWORD', 'OPENCODE_API_KEY', 'JEV_API_KEY',
            'AIMEMORY_REMOTE_TOKEN', 'AI_MEMORY_TOKEN',
            'GITHUB_TOKEN', 'GH_TOKEN', 'GIT_TOKEN',
            'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY',
            'AZURE_CLIENT_SECRET', 'GOOGLE_APPLICATION_CREDENTIALS',
            'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'ZAI_API_KEY', 'Z_AI_API_KEY',
            'NPM_TOKEN', 'npm_token'
        )
        try {
            if (-not [string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean)) { $credNames += [string]$script:ModelKeyEnvNameClean }
        } catch { }
        $esc = @()
        foreach ($k in @($credNames)) {
            if (-not [string]::IsNullOrWhiteSpace($k)) { $esc += [regex]::Escape([string]$k) }
        }
        $nameRx = '(?:' + (($esc -join '|') + '|(?<=^|[\s{[,:\x22\x27])(?:[A-Za-z_][A-Za-z0-9_]*?)?(?:password|token|secret|credential|authorization|api[_-]?key)[A-Za-z0-9_]*\b') + ')'
        $dqV = '\x22(?:[^\x22\x5c\r\n]|\x5c.)*\x22'
        $sqV = '\x27(?:[^\x27\x5c\r\n]|\x5c.)*\x27'
        $v = $raw
        try {
            $v = $v -replace ('(?i)\b(' + $nameRx + ')\s*=\s*(' + $dqV + '|' + $sqV + '|[^\s,;"\x27]+)'), '$1=[REDACTED]'
            $v = $v -replace ('(?i)\x22(' + $nameRx + ')\x22\s*:\s*(' + $dqV + '|' + $sqV + '|[^\s,;"\x27}]+)'), '"$1": "[REDACTED]"'
            $v = $v -replace ('(?i)\x27(' + $nameRx + ')\x27\s*:\s*(' + $dqV + '|' + $sqV + '|[^\s,;"\x27}]+)'), '"$1": "[REDACTED]"'
        } catch { $v = $raw }
        $safe = Get-LaneSafeText $v $Max
        if ([string]::IsNullOrWhiteSpace($safe)) { return '(sem saida capturada)' }
        return $safe
    } catch { return '(sem saida capturada)' }
}
function Test-LaneNeedsPost17Gate {
    # Predicado puro (isolamento pos-16/17, mesmo padrao F1-FIX-01, sem
    # spawn/rede/estado): o gate 'servico no ar apos 16/17' executa SOMENTE
    # quando algum cenario posterior que precisa do servico sera executado
    # (filtro vazio = lane integral, ou filtro contendo 18/19/20/21/22).
    # Filtro so com 16/17 (ex. so-16) pula o gate sem falha por ele.
    # Erro => true (fail-closed: mantem o comportamento anterior).
    [CmdletBinding()] param([string[]]$Filter = @())
    try {
        if (@($Filter).Count -eq 0) { return $true }
        foreach ($id in @($Filter)) {
            if (@('18', '19', '20', '21', '22') -ccontains [string]$id) { return $true }
        }
        return $false
    } catch { return $true }
}
function Test-LaneModelUnavailableOutput {
    # Classificador puro da classe retentavel do fallback de modelo: true
    # somente para a frase 'Model unavailable' (case-insensitive, com
    # word-boundary; vale com ':'/' '/fim ou outro separador apos a frase).
    # Sequencias ANSI CSI (ESC [ params letra, ex. [0m SGR) sao stripadas
    # ANTES do match: no output real o reset termina em letra colada no M
    # de Model ([0mModel unavailable) e mataria o \b. ESC via [char]27, sem
    # byte literal (ASCII-only). Falso para vazio, timeout, rc0 e outros
    # erros sem a frase. Sem rede/spawn/estado; nao altera veredito, gate,
    # timeout ou flag.
    [CmdletBinding()] param([string]$Text = '')
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
        $esc = [string][char]27
        $plain = ([string]$Text -replace ($esc + '\[[0-9;]*[A-Za-z]'), '')
        return ($plain -match '(?i)\bmodel\s+unavailable\b')
    } catch { return $false }
}
function New-LaneModelTurnOutcome {
    # Decisao pura do fallback de modelo (sem spawn/rede/estado): a partir do
    # resultado da 1a tentativa (e, quando executado, do retry) decide se o
    # retry era devido, monta os arg arrays (retry sem --model), conta as
    # chamadas com resultado e emite a proof de fallback. Invoke-LaneModelTurn
    # delega a ele em 3 fases (args -> decisao -> desfecho); testes offline
    # cobrem todos os ramos com fixtures sinteticas, sem mocks de processo.
    # Campos lidos de cada resultado: ExitCode, TimedOut, Stdout, Stderr,
    # JobAssigned, JobNote (hashtable ou objeto; ausente = default fail-closed).
    # retry recusado/sem resultado nao soma e a 1a prevalece (fail-closed).
    # retryDue = classe (rc!=0, sem timeout, Model unavailable), sem olhar assign.
    # shouldRetry = retryDue E 1a com JobAssigned provado (mitigacao
    # ORFS-SPAWN-CONTAINMENT-ADV; 1a sem assign => sem retry, terminal).
    # calls conta 1a + retry quando usado; fallbackProof (model-fallback-default
    # ok=true) so existe quando o retry foi usado, com rc/job do resultado
    # final (fail do retry segue fail; vereditos dos cenarios intactos).
    # noFallbackReason/refusedProof (model-fallback-refused ok=true, diag)
    # existem quando devido-mas-sem-fallback: 1a sem assign
    # (job-unassigned-no-fallback), job do retry indisponivel
    # (retry-job-unavailable) ou retry sem resultado (retry-no-result).
    # No objeto de gate (pre-retry) esses valores sao provisorios; a lane so
    # le reason/proof do desfecho pos-branch.
    # Nativa (ORFS-LANE-NATIVETURN): params NativeAttempted/NativeOk/
    # NativeProof opcionais e saidas nativeAttempted/nativeOk/nativeProof/
    # nativeCalls aditivas; callers antigos (sem nativa) mantem calls/proofs.
    [CmdletBinding()] param($FirstResult = $null, $RetryResult = $null, [bool]$RetryRefused = $false, [string]$SessionId = '', [string]$SafePrompt = 'lane-model-turn-probe', [string]$Model = 'opencode-go/muse-spark-1.3-contributor', [bool]$NativeAttempted = $false, [bool]$NativeOk = $false, $NativeProof = $null)
    # CLI do pin (2.0.23): 'opencode run' aceita '--format json' (mesmo uso
    # provado na lane agent-mcp-integration-lane-v2.ps1, linhas de run com
    # '--format','json' + closure 2026-10-14). O matcher Test-LaneTurnEvidence
    # exige unidade estrutural com role/sender assistant|tool (evento CLI sem
    # role nunca vale; ver Get-LaneTurnUnitText). --session/--model/proofs
    # intactos.
    $firstArgs = @('run', '--session', [string]$SessionId, '--model', [string]$Model, '--format', 'json', [string]$SafePrompt)
    $out = [ordered]@{
        shouldRetry     = $false
        retryDue        = $false
        fallback        = $false
        calls           = 0
        firstArgs       = $firstArgs
        retryArgs       = $null
        final           = $null
        ok              = $false
        fallbackProof   = $null
        noFallbackReason = ''
        refusedProof    = $null
        proofs          = @()
        nativeAttempted = $false
        nativeOk        = $false
        nativeProof     = $null
        nativeCalls     = 0
    }
    try {
        if ($null -eq $FirstResult) { return $out }
        $fExit = -1
        $fTimedOut = $false
        $fOut = ''
        $fJob = $false
        try { $fTimedOut = [bool]$FirstResult.TimedOut } catch { $fTimedOut = $false }
        try { if ($null -ne $FirstResult.ExitCode) { $fExit = [int]$FirstResult.ExitCode } } catch { $fExit = -1 }
        try { $fOut = (([string]$FirstResult.Stdout) + "`n" + ([string]$FirstResult.Stderr)) } catch { $fOut = '' }
        try { $fJob = [bool]$FirstResult.JobAssigned } catch { $fJob = $false }
        $due = (((-not $fTimedOut) -and ($fExit -ne 0)) -and (Test-LaneModelUnavailableOutput -Text $fOut))
        $out.retryDue = [bool]$due
        $should = (([bool]$due) -and ([bool]$fJob))
        $out.shouldRetry = [bool]$should
        if ([bool]$should) { $out.retryArgs = @('run', '--session', [string]$SessionId, '--format', 'json', [string]$SafePrompt) }
        $used = (([bool]$should) -and (-not [bool]$RetryRefused) -and ($null -ne $RetryResult))
        $out.fallback = [bool]$used
        if ([bool]$used) { $out.final = $RetryResult } else { $out.final = $FirstResult }
        $out.calls = 1
        if ([bool]$used) { $out.calls = 2 }
        if ([bool]$NativeAttempted) {
            $out.nativeAttempted = $true
            $out.nativeProof = $NativeProof
            $out.nativeCalls = 1
            if ([bool]$NativeOk) { $out.nativeOk = $true }
            if ([int]$out.calls -lt 3) { $out.calls = [int]$out.calls + 1 }
            if ([int]$out.calls -gt 3) { $out.calls = 3 }
        }
        $eExit = -1
        $eTo = $true
        $eJob = $false
        try { if ($null -ne $out.final.ExitCode) { $eExit = [int]$out.final.ExitCode } } catch { $eExit = -1 }
        try { $eTo = [bool]$out.final.TimedOut } catch { $eTo = $true }
        try { $eJob = [bool]$out.final.JobAssigned } catch { $eJob = $false }
        $out.ok = (((-not $eTo) -and ($eExit -eq 0)) -and ([bool]$eJob))
        if ([bool]$used) {
            $fp = [ordered]@{ proof = 'model-fallback-default'; ok = $true; detail = ('retry sem --model (default do servico) apos Model unavailable; rc=' + $eExit + ' job=' + [bool]$eJob) }
            $out.fallbackProof = $fp
            $out.proofs = @($fp)
        }
        if ((([bool]$due) -and (-not [bool]$used))) {
            if (-not [bool]$fJob) { $out.noFallbackReason = 'job-unassigned-no-fallback: 1a sem JobAssigned provado; retry recusado (fail-closed)' }
            elseif ([bool]$RetryRefused) { $out.noFallbackReason = 'retry-job-unavailable: job do retry indisponivel; 1a prevalece (fail-closed)' }
            else { $out.noFallbackReason = 'retry-no-result: retry sem resultado; 1a prevalece (fail-closed)' }
            $rp = [ordered]@{ proof = 'model-fallback-refused'; ok = $true; detail = ([string]$out.noFallbackReason + '; rc=' + $eExit + ' job=' + [bool]$eJob) }
            $out.refusedProof = $rp
            $out.proofs = @($rp)
        }
        return $out
    } catch { return $out }
}
function Parse-NativeTurnMessages {
    # Parser puro das mensagens do turno nativo (sem rede/spawn/estado):
    # aceita lista nua, {data:[...]}, {messages:[...]} e
    # {data:{messages:[...]}}; conta textos de resposta com papel assistant
    # (role/type/sender), em partes content[] com type text ou em content
    # string. ok=true = shape de lista valido (mesmo com count 0); ok=false
    # = vazio/invalido/sem-lista (fail-closed, sem excecao). next =
    # cursor.next quando presente (paginacao com mesmo type pelo chamador).
    # dedupKeys: chave paralela a texts (id da mensagem quando houver,
    # senao o proprio texto); a perna conta so a primeira ocorrencia de
    # cada chave (sem dupla contagem entre paginas).
    # Leitura por acesso direto a propriedade (preserva arrays de 1 item no
    # PS 5.1 em todos os niveis; passar colecao por & de scriptblock ou por
    # PSObject.Properties[].Value desembrulha singletons). $null seguro;
    # nunca lanca (o try externo fecha sem excecao).
    [CmdletBinding()] param([string]$Body = '')
    $out = [ordered]@{ ok = $false; count = 0; texts = @(); dedupKeys = @(); next = ''; error = '' }
    try {
        if ([string]::IsNullOrWhiteSpace($Body)) { $out.error = 'empty-body'; return $out }
        $j = $null
        try { $j = ConvertFrom-Json $Body } catch { $j = $null }
        if ($null -eq $j) { $out.error = 'json-invalido'; return $out }
        $list = $null
        $cursorNext = ''
        if ($j -is [System.Array]) { $list = @($j) }
        else {
            $dataNode = $null
            $msgNode = $null
            try { $dataNode = $j.data } catch { $dataNode = $null }
            try { $msgNode = $j.messages } catch { $msgNode = $null }
            if (($null -ne $dataNode) -and ($dataNode -is [System.Array])) { $list = @($dataNode) }
            elseif (($null -ne $msgNode) -and ($msgNode -is [System.Array])) { $list = @($msgNode) }
            elseif ($null -ne $dataNode) {
                $nested = $null
                try { $nested = $dataNode.messages } catch { $nested = $null }
                if (($null -ne $nested) -and ($nested -is [System.Array])) { $list = @($nested) }
            }
            # Cursor tri-state (finding MEDIUM): AUSENTE (sem chave ou valor
            # null, em qualquer das 4 posicoes) ou terminal valido (next null
            # ou "" explicito, ou objeto cursor VAZIO {} conforme o contrato
            # do pin 2.0.23) => completo; PRESENTE-mas-malformado (cursor
            # nao-objeto como string/numero/array, {} NAO-vazio sem next,
            # next com tipo errado como numero/bool/array/objeto) =>
            # cursor-malformado. top/data next string e tolerado (mesmo type
            # implicito).
            $curVal = $null
            $curKind = ''
            try { $t = $j.cursor; if ($null -ne $t) { $curVal = $t; $curKind = 'cursor' } } catch { }
            if ($null -eq $curVal) { try { $t = $j.next; if ($null -ne $t) { $curVal = $t; $curKind = 'next' } } catch { } }
            if (($null -eq $curVal) -and ($null -ne $dataNode) -and (-not ($dataNode -is [System.Array]))) {
                try { $t = $dataNode.cursor; if ($null -ne $t) { $curVal = $t; $curKind = 'cursor' } } catch { }
                if ($null -eq $curVal) { try { $t = $dataNode.next; if ($null -ne $t) { $curVal = $t; $curKind = 'next' } } catch { } }
            }
            if ($null -eq $curVal) { $cursorNext = '' }
            elseif ($curKind -ceq 'cursor') {
                if (($curVal -is [System.Array]) -or ($curVal -is [string]) -or ($curVal -is [System.ValueType])) {
                    $out.error = 'cursor-malformado'; return $out
                }
                $hasNextKey = $false
                try { $hasNextKey = (([string[]]@($curVal.PSObject.Properties.Name)) -contains 'next') } catch { $hasNextKey = $false }
                if (-not $hasNextKey) {
                    # cursor:{} vazio e terminal do contrato (fim de paginas);
                    # objeto NAO-vazio sem next segue malformado (fail-closed).
                    $propCount = 0
                    try { $propCount = @($curVal.PSObject.Properties).Count } catch { $propCount = -1 }
                    if ([int]$propCount -eq 0) { $cursorNext = '' }
                    else { $out.error = 'cursor-malformado'; return $out }
                } else {
                    $nx = $null
                    try { $nx = $curVal.next } catch { $nx = $null }
                    if ($null -eq $nx) { $cursorNext = '' }
                    elseif ($nx -is [string]) { $cursorNext = [string]$nx }
                    else { $out.error = 'cursor-malformado'; return $out }
                }
            } else {
                if ($curVal -is [string]) { $cursorNext = [string]$curVal }
                else { $out.error = 'cursor-malformado'; return $out }
            }
            if ($null -eq $list) {
                # PS7 desembrulha array-nuo de 1 item no topo: mensagem direta
                # vira objeto; embrulha de volta quando tem cara de mensagem
                # (role/sender/content). Objeto sem esses campos segue sem-lista.
                $jr = $null
                $js = $null
                $jc = $null
                try { $jr = $j.role } catch { $jr = $null }
                try { $js = $j.sender } catch { $js = $null }
                try { $jc = $j.content } catch { $jc = $null }
                if (($null -ne $jr) -or ($null -ne $js) -or ($null -ne $jc)) { $list = @($j) }
            }
        }
        if ($null -eq $list) { $out.error = 'sem-lista'; return $out }
        $texts = New-Object System.Collections.ArrayList
        $keys = New-Object System.Collections.ArrayList
        foreach ($m in @($list)) {
            if ($null -eq $m) { continue }
            $role = $null
            try { $role = $m.role } catch { $role = $null }
            if ($null -eq $role) { try { $role = $m.type } catch { $role = $null } }
            if ($null -eq $role) { try { $role = $m.sender } catch { $role = $null } }
            if ([string]$role -ine 'assistant') { continue }
            $mid = $null
            try { $mid = $m.id } catch { $mid = $null }
            $content = $null
            try { $content = $m.content } catch { $content = $null }
            if ($content -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace([string]$content)) {
                    [void]$texts.Add([string]$content)
                    $kk = 'tx:' + [string]$content
                    if (-not [string]::IsNullOrWhiteSpace([string]$mid)) { $kk = 'id:' + [string]$mid }
                    [void]$keys.Add($kk)
                }
            } elseif ($content -is [System.Array]) {
                foreach ($part in @($content)) {
                    if ($null -eq $part) { continue }
                    if ($part -is [string]) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$part)) {
                            [void]$texts.Add([string]$part)
                            $kk = 'tx:' + [string]$part
                            if (-not [string]::IsNullOrWhiteSpace([string]$mid)) { $kk = 'id:' + [string]$mid }
                            [void]$keys.Add($kk)
                        }
                        continue
                    }
                    $ptype = $null
                    try { $ptype = $part.type } catch { $ptype = $null }
                    if ([string]$ptype -ine 'text') { continue }
                    $tv = $null
                    try { $tv = $part.text } catch { $tv = $null }
                    if ($null -eq $tv) { try { $tv = $part.value } catch { $tv = $null } }
                    if ($null -eq $tv) { try { $tv = $part.content } catch { $tv = $null } }
                    if ($null -eq $tv) { try { $tv = $part.data } catch { $tv = $null } }
                    if (-not [string]::IsNullOrWhiteSpace([string]$tv)) {
                        [void]$texts.Add([string]$tv)
                        $kk = 'tx:' + [string]$tv
                        if (-not [string]::IsNullOrWhiteSpace([string]$mid)) { $kk = 'id:' + [string]$mid }
                        [void]$keys.Add($kk)
                    }
                }
            } else {
                $tv = $null
                try { $tv = $m.text } catch { $tv = $null }
                if ($null -eq $tv) { try { $tv = $m.body } catch { $tv = $null } }
                if ($null -eq $tv) { try { $tv = $m.message } catch { $tv = $null } }
                if (-not [string]::IsNullOrWhiteSpace([string]$tv)) {
                    [void]$texts.Add([string]$tv)
                    $kk = 'tx:' + [string]$tv
                    if (-not [string]::IsNullOrWhiteSpace([string]$mid)) { $kk = 'id:' + [string]$mid }
                    [void]$keys.Add($kk)
                }
            }
        }
        $out.ok = $true
        $out.count = @($texts).Count
        $out.texts = @($texts)
        $out.dedupKeys = @($keys)
        $out.next = [string]$cursorNext
        return $out
    } catch { $out.error = 'parser-throw'; return $out }
}
function Invoke-LaneNativeTurn {
    # Perna REST nativa do turno (prompt -> wait -> messages), ULTIMO fallback
    # apos as tentativas CLI. Sem host fixo: usa RequestFn injetado
    # (Method/Path/Body/TimeoutMs -> StatusCode/Body/TimedOut) ou HTTP direto
    # contra BaseUrl injetado. Sem auth nova e sem dado sensivel: 401/403 e
    # qualquer divergencia => fail-closed sem excecao. ok exige prompt 200
    # com inbox item valido (envelope sem erro significativo + objeto com
    # id -is [string] nao-vazio e sem erro significativo)
    # + wait 204 (sem body) + ao menos 1 texto assistant novo (totais
    # antes/depois dedupados; sem relogio fragil). Paginacao por cursor.next
    # com mesmo type, ate 5 paginas por lado: cursor ausente/terminal segue,
    # presente-malformado recusa; repetido => erro, cap com pendencia =>
    # erro (leitura incompleta); cada chave (id, ou texto sem id) conta uma
    # unica vez por lado. Paths: prompt sem prefixo experimental, wait COM
    # o prefixo experimental do contrato V2, messages sem prefixo. Falha com
    # attempt=true gera proof diag model-native-failed ok=true com detail =
    # reason estavel (sem body).
    [CmdletBinding()] param([string]$SessionId = '', [string]$SafePrompt = 'lane-model-turn-probe', [int]$TimeoutMs = 180000, [string]$BaseUrl = '', $RequestFn = $null)
    $res = [ordered]@{ attempted = $false; ok = $false; wait204 = $false; beforeCount = 0; afterCount = 0; textsNew = 0; promptStatus = -1; waitStatus = -1; messagesStatus = -1; reason = ''; proof = $null }
    try {
        if ([string]::IsNullOrWhiteSpace($SessionId)) { $res.reason = 'empty-session'; return $res }
        if ([string]::IsNullOrWhiteSpace($SafePrompt)) { $SafePrompt = 'lane-model-turn-probe' }
        if ([int]$TimeoutMs -le 0) { $TimeoutMs = 180000 }
        $useFn = ($null -ne $RequestFn)
        $useHttp = ((-not $useFn) -and (-not [string]::IsNullOrWhiteSpace($BaseUrl)))
        if ((-not $useFn) -and (-not $useHttp)) { $res.reason = 'native-transport-unavailable'; return $res }
        $res.attempted = $true
        $call = {
            param($Method, $Path, $Body)
            $o = @{ StatusCode = -1; Body = ''; TimedOut = $false }
            try {
                if ($useFn) {
                    $rr = $null
                    try { $rr = & $RequestFn -Method $Method -Path $Path -Body ([string]$Body) -TimeoutMs $TimeoutMs } catch { $rr = $null }
                    if ($null -eq $rr) { return $o }
                    try { $o.StatusCode = [int](Get-JsonProp $rr 'StatusCode' -1) } catch { }
                    try { $o.Body = [string](Get-JsonProp $rr 'Body' '') } catch { }
                    try { $o.TimedOut = [bool](Get-JsonProp $rr 'TimedOut' $false) } catch { }
                    return $o
                }
                $url = ([string]$BaseUrl).TrimEnd('/') + [string]$Path
                $req = [System.Net.HttpWebRequest]([System.Net.WebRequest]::Create($url))
                $req.Method = [string]$Method
                $req.Timeout = [int]$TimeoutMs
                try { $req.ReadWriteTimeout = [int]$TimeoutMs } catch { }
                try { $req.Proxy = $null } catch { }
                if ($Method -ceq 'POST') {
                    $payload = [string]$Body
                    if ([string]::IsNullOrEmpty($payload)) { $req.ContentLength = 0 }
                    else {
                        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
                        $req.ContentType = 'application/json'
                        $req.ContentLength = $bytes.Length
                        $ws = $req.GetRequestStream()
                        try { $ws.Write($bytes, 0, $bytes.Length) } finally { try { $ws.Close() } catch { } }
                    }
                }
                try {
                    $resp = $req.GetResponse()
                    try {
                        $o.StatusCode = [int]$resp.StatusCode
                        try {
                            $sr = New-Object IO.StreamReader ($resp.GetResponseStream(), [Text.Encoding]::UTF8)
                            try { $o.Body = $sr.ReadToEnd() } finally { try { $sr.Close() } catch { } }
                        } catch { $o.Body = '' }
                    } finally { try { $resp.Close() } catch { } }
                } catch {
                    # PS5.1 embrulha a WebException em MethodInvocationException:
                    # desembrulha a cadeia ate achar a WebException real, senao
                    # 404/500/503 viram -1 e timeout vira status (evidencia
                    # errada, ainda que fail-closed). PS7 nao embrulha; o
                    # loop e inofensivo la.
                    $we = $null
                    $scan = $_.Exception
                    $sdepth = 0
                    while (($null -ne $scan) -and ($sdepth -lt 4)) {
                        if ($scan -is [System.Net.WebException]) { $we = $scan; break }
                        try { $scan = $scan.InnerException } catch { $scan = $null }
                        $sdepth++
                    }
                    if ($null -ne $we) {
                        if ($we.Status -eq ([System.Net.WebExceptionStatus]::Timeout)) { $o.TimedOut = $true; return $o }
                        try {
                            $er = $we.Response
                            if ($null -ne $er) {
                                $o.StatusCode = [int]$er.StatusCode
                                try {
                                    $sr2 = New-Object IO.StreamReader ($er.GetResponseStream(), [Text.Encoding]::UTF8)
                                    try { $o.Body = $sr2.ReadToEnd() } finally { try { $sr2.Close() } catch { } }
                                } catch { }
                                try { $er.Close() } catch { }
                            }
                        } catch { }
                    }
                }
                return $o
            } catch { return $o }
        }
        # pin 2.0.23: 'Cursor cannot be combined with order' - a pagina
        # inicial leva order=asc; as seguintes levam cursor SEM order
        # (type=assistant mantido nas duas, exigido pelo contrato).
        $msgBase = '/api/session/' + [string]$SessionId + '/message?type=assistant&order=asc'
        $msgFollowBase = '/api/session/' + [string]$SessionId + '/message?type=assistant'
        $promptPath = '/api/session/' + [string]$SessionId + '/prompt'
        $waitPath = '/api/experimental/session/' + [string]$SessionId + '/wait'
        $beforeTotal = 0
        $cursorB = ''
        $pagesB = 0
        $pathB = $msgBase
        $seenKeyB = New-Object System.Collections.ArrayList
        $seenCurB = New-Object System.Collections.ArrayList
        while ($pagesB -lt 5) {
            $br = & $call -Method 'GET' -Path $pathB -Body ''
            if ([bool]$br.TimedOut) { $res.reason = 'messages-before-timeout'; $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
            $res.messagesStatus = [int]$br.StatusCode
            $pb = Parse-NativeTurnMessages -Body ([string]$br.Body)
            if (([int]$br.StatusCode -ne 200) -or (-not [bool]$pb.ok)) {
                if ([string]$pb.error -ceq 'cursor-malformado') { $res.reason = 'messages-before-cursor-invalid' } else { $res.reason = 'messages-before-invalid' }
                $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }
                return $res
            }
            $dkB = $pb['dedupKeys']
            if ($null -ne $dkB) {
                foreach ($k in @($dkB)) {
                    $ks = [string]$k
                    if (-not $seenKeyB.Contains($ks)) { [void]$seenKeyB.Add($ks); $beforeTotal++ }
                }
            }
            $cursorB = [string]$pb.next
            if ([string]::IsNullOrWhiteSpace($cursorB)) { break }
            if ($seenCurB.Contains($cursorB)) { $res.reason = 'messages-before-cursor-repeat'; $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
            [void]$seenCurB.Add($cursorB)
            $pathB = $msgFollowBase + '&cursor=' + [Uri]::EscapeDataString($cursorB)
            $pagesB++
        }
        if (-not [string]::IsNullOrWhiteSpace($cursorB)) { $res.reason = 'messages-before-truncated'; $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
        $res.beforeCount = $beforeTotal
        $esc = ([string]$SafePrompt -replace '\\', '\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n')
        $promptBody = '{"text":"' + $esc + '"}'
        $pr = & $call -Method 'POST' -Path $promptPath -Body $promptBody
        if ([bool]$pr.TimedOut) { $res.reason = 'prompt-timeout'; $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
        $res.promptStatus = [int]$pr.StatusCode
        if ([int]$pr.StatusCode -ne 200) { $res.reason = ('prompt-status-' + [int]$pr.StatusCode); $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
        # Tipo raiz ANTES do desembrulho (finding MEDIUM, v2): o parse aceita
        # comentarios e o PS7 desembrulha array singleton, entao nem o check
        # de '[' nem o -is Array barram '/*c*/[...]' ; o texto apos trim tem
        # que comecar com '{', qualquer outro inicio ([, comentario, string,
        # numero) => recusa direta com prompt-invalid-shape, sem proof.
        if (-not ([string]$pr.Body).Trim().StartsWith('{')) { $res.reason = 'prompt-invalid-shape'; return $res }
        $pj = $null
        try { $pj = ConvertFrom-Json ([string]$pr.Body) } catch { $pj = $null }
        if ($null -eq $pj) { $res.reason = 'prompt-invalid'; $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
        # Schema minimo do inbox item (finding HIGH, v2): envelope objeto
        # SEM erro significativo + item (nu ou sob data) objeto com id
        # -is [string] nao-vazio e SEM erro significativo. Benigno = ausente,
        # null, "" , [] , $false e 0; resto (string/array/objeto/numero/bool
        # significativos) recusa. Recusa {"error":...}+id valido (erro externo
        # nao descartado), id numerico/bool/array, {} , array e string;
        # qualquer divergencia => fail-closed sem proof.
        $inboxOk = $false
        try {
            $envNode = $pj
            if (($null -ne $envNode) -and (-not ($envNode -is [System.Array]))) {
                $envErr = $null
                try { $envErr = $envNode.error } catch { $envErr = $null }
                $envBad = $false
                if ($null -eq $envErr) { $envBad = $false }
                elseif ($envErr -is [string]) { $envBad = (-not [string]::IsNullOrWhiteSpace([string]$envErr)) }
                elseif ($envErr -is [System.Array]) { $envBad = (@($envErr).Count -gt 0) }
                elseif ($envErr -is [bool]) { $envBad = [bool]$envErr }
                else {
                    $envZero = $false
                    try { $envZero = ([double]$envErr -eq 0) } catch { $envZero = $false }
                    $envBad = (-not $envZero)
                }
                $inboxNode = $envNode
                $inboxData = $null
                try { $inboxData = $envNode.data } catch { $inboxData = $null }
                if ($null -ne $inboxData) { $inboxNode = $inboxData }
                if (($null -ne $inboxNode) -and (-not ($inboxNode -is [System.Array]))) {
                    $inboxId = $null
                    $inboxErr = $null
                    try { $inboxId = $inboxNode.id } catch { $inboxId = $null }
                    try { $inboxErr = $inboxNode.error } catch { $inboxErr = $null }
                    $itemBad = $false
                    if ($null -eq $inboxErr) { $itemBad = $false }
                    elseif ($inboxErr -is [string]) { $itemBad = (-not [string]::IsNullOrWhiteSpace([string]$inboxErr)) }
                    elseif ($inboxErr -is [System.Array]) { $itemBad = (@($inboxErr).Count -gt 0) }
                    elseif ($inboxErr -is [bool]) { $itemBad = [bool]$inboxErr }
                    else {
                        $itemZero = $false
                        try { $itemZero = ([double]$inboxErr -eq 0) } catch { $itemZero = $false }
                        $itemBad = (-not $itemZero)
                    }
                    $idOk = (($inboxId -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$inboxId)))
                    if ((-not $envBad) -and (-not $itemBad) -and ([bool]$idOk)) { $inboxOk = $true }
                }
            }
        } catch { $inboxOk = $false }
        if (-not [bool]$inboxOk) { $res.reason = 'prompt-invalid-shape'; $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
        $wr = & $call -Method 'POST' -Path $waitPath -Body ''
        if ([bool]$wr.TimedOut) { $res.reason = 'wait-timeout'; $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
        $res.waitStatus = [int]$wr.StatusCode
        if ([int]$wr.StatusCode -ne 204) { $res.reason = ('wait-status-' + [int]$wr.StatusCode); $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
        $res.wait204 = $true
        $afterTotal = 0
        $cursorA = ''
        $pagesA = 0
        $pathA = $msgBase
        $seenKeyA = New-Object System.Collections.ArrayList
        $seenCurA = New-Object System.Collections.ArrayList
        while ($pagesA -lt 5) {
            $ar = & $call -Method 'GET' -Path $pathA -Body ''
            if ([bool]$ar.TimedOut) { $res.reason = 'messages-after-timeout'; $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
            $res.messagesStatus = [int]$ar.StatusCode
            $pa = Parse-NativeTurnMessages -Body ([string]$ar.Body)
            if (([int]$ar.StatusCode -ne 200) -or (-not [bool]$pa.ok)) {
                if ([string]$pa.error -ceq 'cursor-malformado') { $res.reason = 'messages-after-cursor-invalid' } else { $res.reason = 'messages-after-invalid' }
                $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }
                return $res
            }
            $dkA = $pa['dedupKeys']
            if ($null -ne $dkA) {
                foreach ($k in @($dkA)) {
                    $ks = [string]$k
                    if (-not $seenKeyA.Contains($ks)) { [void]$seenKeyA.Add($ks); $afterTotal++ }
                }
            }
            $cursorA = [string]$pa.next
            if ([string]::IsNullOrWhiteSpace($cursorA)) { break }
            if ($seenCurA.Contains($cursorA)) { $res.reason = 'messages-after-cursor-repeat'; $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
            [void]$seenCurA.Add($cursorA)
            $pathA = $msgFollowBase + '&cursor=' + [Uri]::EscapeDataString($cursorA)
            $pagesA++
        }
        if (-not [string]::IsNullOrWhiteSpace($cursorA)) { $res.reason = 'messages-after-truncated'; $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
        $res.afterCount = $afterTotal
        $newN = $afterTotal - $beforeTotal
        if ([int]$newN -lt 1) { $res.reason = ('no-new-text (antes=' + $beforeTotal + ' depois=' + $afterTotal + ')'); $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
        $res.textsNew = [int]$newN
        $res.ok = $true
        $res.proof = [ordered]@{ proof = 'model-native-prompt'; ok = $true; detail = ('prompt 200 + wait 204 + textos novos=' + $newN + ' (antes=' + $beforeTotal + ' depois=' + $afterTotal + ')') }
        return $res
    } catch { $res.reason = 'native-throw'; $res.proof = [ordered]@{ proof = 'model-native-failed'; ok = $true; detail = ([string]$res.reason) }; return $res }
}
function Get-LaneTurnUnitText {
    # Extrai o texto de UMA unidade candidata (paridade com
    # Parse-NativeTurnMessages): content string | content[] (string ou parte
    # {type:text,...}) | campos text|body|message. Retorna '' sem texto;
    # nunca lanca.
    [CmdletBinding()] param($Unit = $null)
    try {
        if ($null -eq $Unit) { return '' }
        $parts = New-Object System.Collections.ArrayList
        $content = $null
        try { $content = $Unit.content } catch { $content = $null }
        if ($content -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace([string]$content)) { [void]$parts.Add([string]$content) }
        } elseif ($content -is [System.Array]) {
            foreach ($part in @($content)) {
                if ($null -eq $part) { continue }
                if ($part -is [string]) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$part)) { [void]$parts.Add([string]$part) }
                    continue
                }
                if (($part -is [System.Array]) -or ($part -is [System.ValueType])) { continue }
                $pt = $null
                try { $pt = $part.type } catch { $pt = $null }
                if ([string]$pt -ine 'text') { continue }
                $tv = $null
                try { $tv = $part.text } catch { $tv = $null }
                if ($null -eq $tv) { try { $tv = $part.value } catch { $tv = $null } }
                if ($null -eq $tv) { try { $tv = $part.content } catch { $tv = $null } }
                if ($null -eq $tv) { try { $tv = $part.data } catch { $tv = $null } }
                if (-not [string]::IsNullOrWhiteSpace([string]$tv)) { [void]$parts.Add([string]$tv) }
            }
        } else {
            foreach ($fn in @('text', 'body', 'message')) {
                $fv = $null
                try { $fv = $Unit.$fn } catch { $fv = $null }
                if (-not [string]::IsNullOrWhiteSpace([string]$fv)) { [void]$parts.Add([string]$fv); break }
            }
        }
        return (@($parts) -join "`n")
    } catch { return '' }
}
function Test-LaneSignificantError {
    # Semantica pura de erro significativo (contrato existente da perna
    # nativa, sem mudanca): benigno = ausente/null/""/[]/$false/0; resto
    # significativo (inclui {} e objetos). Nunca lanca; excecao =>
    # significativo (fail-closed: nega unidade/documento).
    [CmdletBinding()] param($Value = $null)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [string]) { return (-not [string]::IsNullOrWhiteSpace([string]$Value)) }
        if ($Value -is [System.Array]) { return (@($Value).Count -gt 0) }
        if ($Value -is [bool]) { return [bool]$Value }
        $z = $false
        try { $z = ([double]$Value -eq 0) } catch { $z = $false }
        if ([bool]$z) { return $false }
        return $true
    } catch { return $true }
}
function Test-LaneTurnEvidence {
    # Matcher estrutural da evidencia de resposta de um turno (reviewer+sec):
    # aplica os MESMOS criterios ao stdout do turno e ao corpo GET message
    # (equivalencia por construcao). Parseia JSON/JSONL e extrai texto
    # SOMENTE de unidade elegivel: role/sender explicito assistant|tool, sem
    # erro significativo. Canario+state sao literais avaliados na MESMA
    # unidade elegivel (user tokens + assistant negativa nao combinam).
    # Nega user/error/envelopes ambiguos; linhas nao-JSON sao ignoradas, nunca
    # casadas. Shapes repo-grounded: envelopes do GET (lista nua,
    # {data:[...]}, {messages:[...]}, {data:{messages:[...]}}, mensagem direta
    # com role) e docs JSON por linha do stdout CLI. Evento CLI sem role
    # (step_start, {"type":"text",...} nu) NAO tem proveniencia e nunca vale
    # role (sem aceitacao ampla: o --format json real do pin mistura
    # transcript TUI; a decisao usa o GET ?type=assistant). Token vazio =>
    # criterio falso (fail-closed). Nunca lanca.
    [CmdletBinding()] param([string]$Text = '', [string]$CanaryToken = '', [string]$StateToken = '')
    $out = [ordered]@{ role = $false; canary = $false; state = $false }
    try {
        $docs = New-Object System.Collections.ArrayList
        $whole = $null
        try { $whole = ConvertFrom-Json ([string]$Text) } catch { $whole = $null }
        if ($null -ne $whole) { [void]$docs.Add($whole) }
        else {
            foreach ($ln in ([string]$Text -split "`r?`n")) {
                $t = ''
                try { $t = ([string]$ln).Trim() } catch { $t = '' }
                if ([string]::IsNullOrWhiteSpace($t)) { continue }
                if ((-not $t.StartsWith('{')) -and (-not $t.StartsWith('['))) { continue }
                $d = $null
                try { $d = ConvertFrom-Json $t } catch { $d = $null }
                if ($null -ne $d) { [void]$docs.Add($d) }
            }
        }
        $units = New-Object System.Collections.ArrayList
        foreach ($doc in @($docs)) {
            if ($doc -is [System.Array]) { foreach ($m in @($doc)) { [void]$units.Add($m) } }
            elseif (($doc -is [string]) -or ($doc -is [System.ValueType])) { continue }
            else {
                # Erro significativo no doc raiz descarta o documento e os
                # descendentes (nao herdam elegibilidade do envelope).
                $rootBad = $false
                try {
                    $re = $null
                    try { $re = $doc.error } catch { $re = $null }
                    try { $rootBad = [bool](Test-LaneSignificantError -Value $re) } catch { $rootBad = $true }
                } catch { $rootBad = $true }
                if ([bool]$rootBad) { continue }
                $dataNode = $null
                $msgNode = $null
                try { $dataNode = $doc.data } catch { $dataNode = $null }
                try { $msgNode = $doc.messages } catch { $msgNode = $null }
                if (($null -ne $dataNode) -and ($dataNode -is [System.Array])) { foreach ($m in @($dataNode)) { [void]$units.Add($m) } }
                elseif (($null -ne $msgNode) -and ($msgNode -is [System.Array])) { foreach ($m in @($msgNode)) { [void]$units.Add($m) } }
                elseif ($null -ne $dataNode) {
                    $nested = $null
                    try { $nested = $dataNode.messages } catch { $nested = $null }
                    if (($null -ne $nested) -and ($nested -is [System.Array])) {
                        # Intermediario data.error tambem descarta (mesma
                        # semantica; sem recursao generica).
                        $dataBad = $false
                        try {
                            $de = $null
                            try { $de = $dataNode.error } catch { $de = $null }
                            try { $dataBad = [bool](Test-LaneSignificantError -Value $de) } catch { $dataBad = $true }
                        } catch { $dataBad = $true }
                        if (-not [bool]$dataBad) { foreach ($m in @($nested)) { [void]$units.Add($m) } }
                    }
                    else { [void]$units.Add($doc) }
                }
                else { [void]$units.Add($doc) }
            }
        }
        $wantBoth = ((-not [string]::IsNullOrWhiteSpace($CanaryToken)) -and (-not [string]::IsNullOrWhiteSpace($StateToken)))
        $roleFound = $false
        $sameFound = $false
        foreach ($m in @($units)) {
            if ($null -eq $m) { continue }
            if (($m -is [string]) -or ($m -is [System.ValueType]) -or ($m -is [System.Array])) { continue }
            # Erro significativo proprio (mesma semantica pura) => inelegivel.
            $bad = $false
            try {
                $e = $null
                try { $e = $m.error } catch { $e = $null }
                try { $bad = [bool](Test-LaneSignificantError -Value $e) } catch { $bad = $true }
            } catch { $bad = $true }
            if ([bool]$bad) { continue }
            $rv = $null
            try { $rv = $m.role } catch { $rv = $null }
            if ($null -eq $rv) { try { $rv = $m.sender } catch { $rv = $null } }
            if ((([string]$rv -ieq 'assistant') -or ([string]$rv -ieq 'tool'))) { }
            else { continue }
            $tx = ''
            try { $tx = Get-LaneTurnUnitText -Unit $m } catch { $tx = '' }
            if ([string]::IsNullOrWhiteSpace($tx)) { continue }
            $roleFound = $true
            if ([bool]$wantBoth) {
                $low = $tx.ToLowerInvariant()
                if (($low.Contains(([string]$CanaryToken).ToLowerInvariant())) -and ($low.Contains(([string]$StateToken).ToLowerInvariant()))) { $sameFound = $true }
            }
        }
        $out.role = [bool]$roleFound
        $out.canary = [bool]$sameFound
        $out.state = [bool]$sameFound
        return $out
    } catch { return [ordered]@{ role = $false; canary = $false; state = $false } }
}
function Invoke-LaneModelTurn {
    # Turn de modelo bounded via filho 'opencode run --session' (conecta no
    # service isolado da lane). So executa com model-key disponivel; fora
    # disso retorna attempted=false e a perna segue blocked (fail-closed).
    # Decisao do fallback delegada a New-LaneModelTurnOutcome (pura): 1a
    # tentativa com --model do pin; se devida (rc!=0, sem timeout, Model
    # unavailable, 1a com JobAssigned provado), UMA retentativa com args do
    # helper (sem --model, default do servico). 1a sem assign => sem retry,
    # terminal, reason job-unassigned-no-fallback + proof diag
    # (veredito intacto: ok so com retry exit 0 + job assigned).
    # BOTREV-01/B3: o filho recebe Job Object proprio com KILL_ON_JOB_CLOSE
    # (contencao POS-SPAWN + rejeicao de resultado sem atribuicao comprovada;
    # NAO e contencao pre-execucao); job indisponivel => turn recusado
    # (fail-closed).
    [CmdletBinding()] param([string]$SessionId = '', [string]$Prompt = 'lane-model-turn-probe', [string]$Model = 'opencode-go/muse-spark-1.3-contributor', [int]$TimeoutMs = 180000, [string]$NativeBaseUrl = '', $NativeRequestFn = $null)
    $res = [ordered]@{ attempted = $false; ok = $false; substantive = $false; exit = -1; timedout = $false; out_chars = 0; output_excerpt = ''; turn_stdout_safe = ''; turn_output_safe = '(turno sem saida: spawn sem resultado)'; job_assigned = $false; job_note = ''; fallback = $false; fallbackProof = $null; refusedProof = $null; calls = 0; native = $false; nativeProof = $null; nativeCalls = 0; nativeTrigger = ''; nativeTriggerProof = $null; reason = '' }
    try {
        if (-not (Test-LaneModelKeyAvailable)) { $res.reason = ('model-key indisponivel; ' + (Get-LaneModelKeyLogToken)); return $res }
        if ([string]::IsNullOrWhiteSpace($SessionId)) { $res.reason = 'session vazia'; return $res }
        if ([string]::IsNullOrWhiteSpace($Model)) { $Model = 'opencode-go/muse-spark-1.3-contributor' }
        $safePrompt = (([string]$Prompt) -replace '[&|<>\^%!"''();$`\{\}\[\]\r\n]', '-').Trim()
        if ([string]::IsNullOrWhiteSpace($safePrompt)) { $safePrompt = 'lane-model-turn-probe' }
        if ($safePrompt.Length -gt 200) { $safePrompt = $safePrompt.Substring(0, 200) }
        $turnJob = $null
        try { $turnJob = New-RuntimeJobObject } catch { $turnJob = $null }
        if (($null -eq $turnJob) -or (-not [bool]$turnJob.Ok)) { $res.reason = 'job object do turn indisponivel (fail-closed; turn recusado sem contencao provada)'; return $res }
        $turnFlags = $null
        try { $turnFlags = Get-RuntimeJobLimitFlags -Job $turnJob } catch { $turnFlags = $null }
        if (($null -eq $turnFlags) -or (-not [bool]$turnFlags.Ok) -or (-not [bool]$turnFlags.KillOnClose)) {
            try { [void](Close-RuntimeJobObject -Job $turnJob) } catch { }
            $res.reason = 'job do turn sem KILL_ON_JOB_CLOSE provado (fail-closed; turn recusado)'
            return $res
        }
        $modelEnv = Get-LaneModelChildEnv -BaseEnv $script:IsoEnv
        $modelRemove = @($script:IsoRemove + ($script:SensitiveEnvRemove | Where-Object { $_ -cne $script:ModelKeyEnvNameClean }))
        $res.attempted = $true
        $plan = New-LaneModelTurnOutcome -SessionId $SessionId -SafePrompt $safePrompt -Model $Model
        $r = $null
        try {
            $r = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList $plan.firstArgs -EnvSet $modelEnv -EnvRemove $modelRemove -WorkingDirectory $script:CwdT -TimeoutMs $TimeoutMs -CleanEnvironment -StdinNul -JobObject $turnJob
        } finally {
            try { [void](Close-RuntimeJobObject -Job $turnJob) } catch { }
        }
        if ($null -eq $r) { $res.reason = 'spawn do turn sem resultado (fail-closed)'; $res.output_excerpt = Get-LaneModelTurnOutputExcerpt -Stdout '' -Stderr ''; return $res }
        $gate = New-LaneModelTurnOutcome -FirstResult $r -SessionId $SessionId -SafePrompt $safePrompt -Model $Model
        if ([bool]$gate.shouldRetry) {
            # Contencao padrao P26: assign imediato pos-spawn via -JobObject +
            # resultado recusado sem JobAssigned provado + backstop
            # KILL_ON_JOB_CLOSE; a janela residual spawn-antes-assign vive no
            # SpikeProcess compartilhado (fora deste escopo). create-suspended
            # exigiria slice dedicada com architect + regressao total.
            $fbJob = $null
            try { $fbJob = New-RuntimeJobObject } catch { $fbJob = $null }
            $fbUsable = (($null -ne $fbJob) -and ([bool]$fbJob.Ok))
            if ($fbUsable) {
                try {
                    $fbFlags = Get-RuntimeJobLimitFlags -Job $fbJob
                    $fbUsable = (($null -ne $fbFlags) -and ([bool]$fbFlags.Ok) -and ([bool]$fbFlags.KillOnClose))
                } catch { $fbUsable = $false }
            }
            $outcome = $null
            if ($fbUsable) {
                $r2 = $null
                try {
                    $r2 = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList $gate.retryArgs -EnvSet $modelEnv -EnvRemove $modelRemove -WorkingDirectory $script:CwdT -TimeoutMs $TimeoutMs -CleanEnvironment -StdinNul -JobObject $fbJob
                } finally {
                    try { [void](Close-RuntimeJobObject -Job $fbJob) } catch { }
                }
                $outcome = New-LaneModelTurnOutcome -FirstResult $r -RetryResult $r2 -SessionId $SessionId -SafePrompt $safePrompt -Model $Model
            } else {
                try { [void](Close-RuntimeJobObject -Job $fbJob) } catch { }
                $outcome = New-LaneModelTurnOutcome -FirstResult $r -RetryRefused $true -SessionId $SessionId -SafePrompt $safePrompt -Model $Model
            }
            $r = $outcome.final
            $res.fallback = [bool]$outcome.fallback
            $res.fallbackProof = $outcome.fallbackProof
            $res.calls = [int]$outcome.calls
            $final = $outcome
        } else {
            $final = $gate
        }
        if (-not [bool]$res.fallback) {
            if ([string]$final.noFallbackReason -ne '') { $res.reason = [string]$final.noFallbackReason }
            if ($null -ne $final.refusedProof) { $res.refusedProof = $final.refusedProof }
        }
        $res.exit = [int]$r.ExitCode
        $res.timedout = [bool]$r.TimedOut
        $res.job_assigned = [bool]$r.JobAssigned
        $res.job_note = [string]$r.JobNote
        $so = Get-LaneSafeText (([string]$r.Stdout + "`n" + [string]$r.Stderr)) 160
        $res.out_chars = $so.Length
        # STDOUT+STDERR sanitizado integral do turno para diagnostico
        # (sempre preenchido com $r presente, sucesso ou falha; cap 4000 via
        # excerpt-helper (mesma redacao do matcher). So alimenta
        # a proof diag model-turn-stdout (ok=true); vereditos/gates intactos.
        $res.turn_output_safe = Get-LaneModelTurnOutputExcerpt -Stdout ([string]$r.Stdout) -Stderr ([string]$r.Stderr) -Max 4000
        # STDOUT sanitizado SOMENTE com gate CLI integral (rc==0, sem timeout,
        # JobAssigned provado): stdout de tentativa recusada nunca vira
        # evidencia (se a nativa decidir depois, cenarios usam GET ou evidencia
        # da propria perna, nunca este campo). Sanitizacao identica a do
        # excerpt via helper (credenciais redigidas, cap 1200); truncagem erra
        # fail-closed. output_excerpt segue falha-somente (turndiag trava).
        $res.turn_stdout_safe = ''
        if (((-not [bool]$r.TimedOut) -and ([int]$r.ExitCode -eq 0) -and ([bool]$r.JobAssigned))) {
            try { $res.turn_stdout_safe = Get-LaneModelTurnOutputExcerpt -Stdout ([string]$r.Stdout) -Stderr '' } catch { $res.turn_stdout_safe = '' }
        }
        $res.ok = ((-not [bool]$r.TimedOut) -and ([int]$r.ExitCode -eq 0) -and ([bool]$r.JobAssigned))
        # ORFS-HOLLOW-NATIVE: flag pura de resposta substantiva = ok CLI E
        # stdout com marcadores (mesmo matcher dos cenarios 18/21, sem
        # canario/state no nivel do turno: so role). rc=0 SEM texto (ex. ack
        # de child session) mantem ok=true (GLOBAL INTACTO) mas substantive
        # fica false, e a perna nativa ganha sua chance no gate abaixo.
        # Nunca lanca; duvida => false (fail-closed).
        $res.substantive = $false
        try {
            $subEv = Test-LaneTurnEvidence -Text ([string]$res.turn_stdout_safe)
            if (([bool]$res.ok) -and ([bool]$subEv.role)) { $res.substantive = $true }
        } catch { $res.substantive = $false }
        # ORFS-LANE-NATIVETURN: perna REST nativa (prompt -> wait -> messages)
        # como ULTIMO recurso do turno: executa com desfecho CLI nao-ok OU
        # com hollow-ok (ok SEM marcadores no stdout), e com transporte
        # injetado pelo chamador (NativeRequestFn autenticado
        # nos cenarios; NativeBaseUrl segue existindo para testes/offline,
        # onde HTTP direto sem auth falha fechado). Sem transporte a perna e
        # pulada e o veredito CLI prevalece.
        # Teto de 3 tentativas por turno (2 CLI + 1 nativa). Divergencia fecha
        # sem excecao; a proof model-native-prompt so existe quando a perna
        # decide o turno.
        $nativeBase = [string]$NativeBaseUrl
        $nativeDue = (((-not [bool]$res.ok) -or (([bool]$res.ok) -and (-not [bool]$res.substantive))))
        if ([bool]$nativeDue -and ((-not [string]::IsNullOrWhiteSpace($nativeBase)) -or ($null -ne $NativeRequestFn))) {
            $res.nativeCalls = 1
            $nativeTurn = $null
            try { $nativeTurn = Invoke-LaneNativeTurn -SessionId $SessionId -SafePrompt $safePrompt -TimeoutMs $TimeoutMs -BaseUrl $nativeBase -RequestFn $NativeRequestFn } catch { $nativeTurn = $null }
            if (($null -ne $nativeTurn) -and ([bool]$nativeTurn['attempted'])) {
                $res.native = $true
                if ([bool]$res.ok) { $res.nativeTrigger = 'native-after-hollow' } else { $res.nativeTrigger = 'native-after-fail' }
                $res.nativeTriggerProof = [ordered]@{ proof = 'model-native-trigger'; ok = $true; detail = ('gatilho=' + [string]$res.nativeTrigger + ' (turn ' + $(if ([string]$res.nativeTrigger -ceq 'native-after-hollow') { 'rc=0 sem marcadores no stdout, substantive=false' } else { 'CLI nao-ok' }) + '; nativa como ultimo recurso)') }
                if ($null -ne $nativeTurn['proof']) { $res.nativeProof = $nativeTurn['proof'] }
                if ([bool]$nativeTurn['ok']) {
                    $res.ok = $true
                    $res.reason = ''
                }
            }
            $cliCalls = 1
            try { if ([bool]$res.fallback) { $cliCalls = [int]$res.calls } } catch { $cliCalls = 1 }
            if ([int]$cliCalls -lt 1) { $cliCalls = 1 }
            if ([int]$cliCalls -gt 2) { $cliCalls = 2 }
            $res.calls = ($cliCalls + 1)
        }
        if (([bool]$res.attempted) -and (-not [bool]$res.ok)) {
            try { $res.output_excerpt = Get-LaneModelTurnOutputExcerpt -Stdout ([string]$r.Stdout) -Stderr ([string]$r.Stderr) } catch { $res.output_excerpt = '(sem saida capturada)' }
        }
        if ((-not [bool]$r.JobAssigned) -and ($res.ok -eq $false) -and ([int]$r.ExitCode -eq 0) -and (-not [bool]$r.TimedOut)) {
            $res.reason = 'turn rc=0 mas atribuicao ao job NAO comprovada (contencao nao provada; resultado nao conta como ok)'
        }
        return $res
    } catch {
        $res.reason = (Get-LaneSafeText $_.Exception.Message 160)
        if (([bool]$res.attempted) -and ([string]::IsNullOrWhiteSpace([string]$res.output_excerpt))) { $res.output_excerpt = '(sem saida capturada)' }
        return $res
    }
}

# ---------- kernel CLI (processo real separado) ----------
# powershell.exe resolvido de forma fixa: $PSHOME aponta para o diretorio do
# HOST (no PS7 da Store nao existe powershell.exe la).
$script:WindowsPowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $script:WindowsPowerShellExe -PathType Leaf)) {
    $candPs = Get-Command powershell.exe -ErrorAction SilentlyContinue
    $script:WindowsPowerShellExe = $(if ($null -ne $candPs) { [string]$candPs.Source } else { '' })
}
if ([string]::IsNullOrWhiteSpace($script:WindowsPowerShellExe)) {
    $candPw = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $script:WindowsPowerShellExe = $(if ($null -ne $candPw) { [string]$candPw.Source } else { (Join-Path $PSHOME 'pwsh.exe') })
}
# npm resolvido no processo da lane (PATH completo). npm.cmd vive sob
# 'C:\Program Files\nodejs\' (espacos): o cmd /c com aspas quebra (quirk
# observado), entao a lane invoca node.exe + npm-cli.js diretamente.
$script:NpmCmd = ''
$script:NodeExe = ''
$script:NpmCliJs = ''
    $candNpm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if ($null -eq $candNpm) { $candNpm = Get-Command npm -ErrorAction SilentlyContinue }
if ($null -ne $candNpm) {
    $script:NpmCmd = [string]$candNpm.Source
    $npmDir = Split-Path -Parent $script:NpmCmd
    $nodeCand = Join-Path $npmDir 'node.exe'
    $cliCand = Join-Path (Join-Path (Join-Path $npmDir 'node_modules') 'npm') 'bin\npm-cli.js'
    if ((Test-Path -LiteralPath $nodeCand -PathType Leaf) -and (Test-Path -LiteralPath $cliCand -PathType Leaf)) {
        $script:NodeExe = $nodeCand
        $script:NpmCliJs = $cliCand
    }
}
# denylist de ambiente para os filhos via bounded exe (o helper herda o env
# do pai; removemos as variaveis sensiveis conhecidas antes do spawn)
$script:SensitiveEnvRemove = @(
    'OPENCODE_PASSWORD', 'OPENCODE_API_KEY', 'JEV_API_KEY', 'JEVDATA_DIR',
    'AIMEMORY_REMOTE_TOKEN', 'AI_MEMORY_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN',
    'GIT_TOKEN', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY',
    'AZURE_CLIENT_SECRET', 'GOOGLE_APPLICATION_CREDENTIALS',
    'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'ZAI_API_KEY', 'Z_AI_API_KEY',
    'NODE_OPTIONS', 'NODE_ENV', 'npm_config_userconfig', 'npm_config__auth',
    'NPM_TOKEN', 'npm_token', 'NODE_EXTRA_CA_CERTS'
)
function Invoke-KernelCli {
    [CmdletBinding()] param([string[]]$KernelArgs, [int]$TimeoutMs = 0)
    if ($TimeoutMs -le 0) { $TimeoutMs = $KernelTimeoutMs }
    # transporte via Invoke-PreflightBoundedExe: o SpikeChild so drena stdout
    # DEPOIS do WaitForExit, e outputs do kernel acima do buffer do pipe
    # (observado: get = 4237 bytes > 4096) bloqueiam o filho ate o timeout.
    # O bounded exe drena concorrente (provado no fetch do openapi de 251KB).
    # o guard StdinNul recusa args com shell-meta; texto livre (objetivo)
    # e sanitizado para o charset seguro, sem alterar IDs/numeros
    $safeArgs = @()
    foreach ($a in @($KernelArgs)) {
        $s = [string]$a
        $s = $s -replace '[&|<>\^%!"''();$`\{\}\[\]\r\n]', '-'
        if ($s -match '\s') { $s = '"' + $s + '"' }
        $safeArgs += , $s
    }
    $argsLine = '-NoProfile -ExecutionPolicy Bypass -NonInteractive -File "' + (Join-Path $RepoRoot 'scripts\v3\task-kernel.ps1') + '" ' + ($safeArgs -join ' ')
    try {
        $r = Invoke-PreflightBoundedExe -File $script:WindowsPowerShellExe -ArgsLine $argsLine -WorkDir $RepoRoot -EnvTable $script:IsoEnv -EnvRemove ($script:IsoRemove + $script:SensitiveEnvRemove) -TimeoutMs $TimeoutMs -MaxChars 262144
        $text = [string]$r.Output
        $json = $null
        if (([bool]$r.Finished) -and (-not [string]::IsNullOrWhiteSpace($text))) {
            try { $json = ConvertFrom-Json $text } catch { $json = $null }
        }
        return [ordered]@{
            exit     = [int]$r.ExitCode
            timedout = [bool]$r.TimedOut
            finished = [bool]$r.Finished
            truncated = [bool]$r.Truncated
            json     = $json
            stdout   = (Get-LaneSafeText $text 1200)
            stderr   = ''
        }
    } catch {
        return [ordered]@{ exit = -1; timedout = $false; finished = $false; truncated = $false; json = $null; stdout = ''; stderr = ('throw: ' + (Get-LaneSafeText $_.Exception.Message 200)) }
    }
}
function Get-JsonProp($Object, [string]$Name, $Default = $null) {
    try {
        if ($null -eq $Object) { return $Default }
        # hashtables/ordered dicts: PSObject.Properties NAO expoe as chaves no PS 5.1
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -eq $p) { return $Default }
        return $p.Value
    } catch { return $Default }
}
function Test-KernelOk($KernelResult) {
    if ($null -eq $KernelResult) { return $false }
    if ([int]$KernelResult.exit -ne 0) { return $false }
    if ($KernelResult.Contains('finished') -and -not [bool]$KernelResult['finished']) { return $false }
    if ($KernelResult.Contains('truncated') -and [bool]$KernelResult['truncated']) { return $false }
    if ($null -eq $KernelResult['json']) { return $false }
    $err = Get-JsonProp $KernelResult.json 'error' ''
    return ([string]::IsNullOrWhiteSpace([string]$err))
}

# ---------- REST (opencode api) ----------
function Invoke-Api {
    [CmdletBinding()] param([string]$Method, [string]$Path, [string]$Data = '', [int]$TimeoutMs = 0, [int]$MaxChars = 524288)
    if ($TimeoutMs -le 0) { $TimeoutMs = $ApiTimeoutMs }
    $line = 'api --server http://127.0.0.1:' + $script:Port + ' ' + $Method + ' ' + $Path
    if (-not [string]::IsNullOrEmpty($Data)) {
        $esc = $Data -replace '"', '\"'
        $line += ' --data "' + $esc + '"'
    }
    try {
        # preserva OPENCODE_PASSWORD (adicionado de proposito no AuthEnv);
        # o resto da denylist sensivel continua sendo removido
        $apiRemove = @($script:IsoRemove + ($script:SensitiveEnvRemove | Where-Object { $_ -cne 'OPENCODE_PASSWORD' }))
        $r = Invoke-PreflightBoundedExe -File $script:Exe -ArgsLine $line -WorkDir $script:CwdT -EnvTable $script:AuthEnv -EnvRemove $apiRemove -TimeoutMs $TimeoutMs -MaxChars $MaxChars
        return [ordered]@{
            ok        = (([bool]$r.Finished) -and ([int]$r.ExitCode -eq 0) -and (-not [bool]$r.Truncated))
            exit      = [int]$r.ExitCode
            truncated = [bool]$r.Truncated
            finished  = [bool]$r.Finished
            body      = [string]$r.Output
        }
    } catch {
        return [ordered]@{ ok = $false; exit = -1; truncated = $false; finished = $false; body = ('throw: ' + (Get-LaneSafeText $_.Exception.Message 200)) }
    }
}
function New-LaneNativeApiRequestFn {
    # Fabrica o RequestFn da perna nativa sobre o transporte AUTENTICADO
    # Invoke-Api (opencode api --server + OPENCODE_PASSWORD do AuthEnv do
    # escopo; nenhum segredo transita aqui: o scriptblock recebe so
    # Method/Path/Body/TimeoutMs). Mapeamento para o contrato RequestFn
    # (StatusCode/Body/TimedOut), fail-closed em qualquer duvida:
    # finished=false => TimedOut; truncated ou !ok => StatusCode -1;
    # ok com corpo vazio => 204; ok com corpo => 200. Heuristica honesta:
    # o CLI nao expoe o status HTTP exato; vazio significa 204 (sem body)
    # e corpo significa 200; erro de transporte vira -1/timeout.
    [CmdletBinding()] param()
    $fn = {
        param($Method, $Path, $Body, $TimeoutMs)
        $o = @{ StatusCode = -1; Body = ''; TimedOut = $false }
        try {
            $ms = 0
            try { $ms = [int]$TimeoutMs } catch { $ms = 0 }
            $r = $null
            try { $r = Invoke-Api -Method ([string]$Method) -Path ([string]$Path) -Data ([string]$Body) -TimeoutMs $ms } catch { $r = $null }
            if ($null -eq $r) { return $o }
            $finished = $false
            try { $finished = [bool]$r.finished } catch { $finished = $false }
            if (-not $finished) { $o.TimedOut = $true; return $o }
            $trunc = $false
            try { $trunc = [bool]$r.truncated } catch { $trunc = $false }
            if ($trunc) { return $o }
            $ok = $false
            try { $ok = [bool]$r.ok } catch { $ok = $false }
            if (-not $ok) { return $o }
            $b = ''
            try { $b = [string]$r.body } catch { $b = '' }
            $o.Body = $b
            if ([string]::IsNullOrWhiteSpace($b)) { $o.StatusCode = 204 } else { $o.StatusCode = 200 }
            return $o
        } catch { return $o }
    }
    return $fn
}
function Convert-ApiJson([string]$Body) {
    try {
        if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
        return (ConvertFrom-Json $Body)
    } catch { return $null }
}
function New-RealSession([string]$ParentId = '') {
    $data = '{}'
    if (-not [string]::IsNullOrWhiteSpace($ParentId)) { $data = '{"parentID":"' + $ParentId + '"}' }
    $r = Invoke-Api -Method 'POST' -Path '/api/session' -Data $data
    if (-not [bool]$r.ok) { return [ordered]@{ ok = $false; reason = ('post-failed:exit=' + [int]$r.exit + ' trunc=' + [bool]$r.truncated + ' ' + (Get-LaneSafeText $r.body 200)); id = '' } }
    $j = Convert-ApiJson $r.body
    # a API real aninha a sessao sob "data"
    $node = Get-JsonProp $j 'data' $j
    $sid = [string](Get-JsonProp $node 'id' '')
    if ([string]::IsNullOrWhiteSpace($sid)) { return [ordered]@{ ok = $false; reason = ('no-id: ' + (Get-LaneSafeText $r.body 200)); id = '' } }
    if ($sid -cmatch '^[A-Za-z0-9._-]{4,128}$') {
        return [ordered]@{ ok = $true; reason = ''; id = $sid }
    }
    return [ordered]@{ ok = $false; reason = 'session-id-fora-do-charset-do-kernel'; id = $sid }
}
function Probe-SessionExists([string]$SessionId, [int]$DeadlineSeconds = 10) {
    # Probe conclusivo: consulta que responde (ok) decide; falha de consulta
    # e inconclusiva e NUNCA decide. Marcadores de erro de auth/transporte
    # tornam a consulta inconclusiva (nunca ausencia).
    $deadline = [DateTime]::UtcNow.AddSeconds($DeadlineSeconds)
    $lastBody = ''
    while ([DateTime]::UtcNow -lt $deadline) {
        $r = Invoke-Api -Method 'GET' -Path ('/api/session/' + $SessionId) -TimeoutMs 10000
        if ([bool]$r.finished) {
            if ([int]$r.exit -eq 0) { return [ordered]@{ state = 'present'; body = $r.body } }
            $lower = ($r.body).ToLowerInvariant()
            $authOrTransport = (($lower -match 'unauthorized') -or ($lower -match 'forbidden') -or ($lower -match 'econnrefused') -or ($lower -match 'etimedout') -or ($lower -match 'socket hang up') -or ($lower -match 'fetch failed'))
            if ($authOrTransport) { return [ordered]@{ state = 'inconclusive'; body = $r.body } }
            if (($lower -match 'no session') -or ($lower -match 'session not found') -or ($lower -match 'unknown session') -or ($lower -match 'not found') -or ($lower -match '404')) {
                return [ordered]@{ state = 'absent'; body = $r.body }
            }
            return [ordered]@{ state = 'inconclusive'; body = $r.body }
        }
        Start-Sleep -Milliseconds 800
    }
    return [ordered]@{ state = 'inconclusive'; body = $lastBody }
}
function Test-SessionListed([string]$SessionId) {
    $r = Invoke-Api -Method 'GET' -Path '/api/session'
    if (-not [bool]$r.ok) { return [ordered]@{ decided = $false; listed = $false } }
    $j = Convert-ApiJson $r.body
    # a listagem real pode vir nua ou aninhada sob "data"
    $arr = @(Get-JsonProp $j 'data' $j)
    $ids = @()
    foreach ($item in @($arr)) { $ids += , [string](Get-JsonProp $item 'id' '') }
    return [ordered]@{ decided = $true; listed = ($ids -ccontains $SessionId) }
}
function Close-RealSession([string]$SessionId) {
    if ($null -eq $script:OpenApiPaths) { return [ordered]@{ ok = $false; reason = 'openapi-indisponivel' } }
    $hasDelete = $false
    try {
        # o template real do 2.0.23 e /api/session/{sessionID}; qualquer
        # variante '/api/session/{...}' com delete e aceita (dado observado)
        foreach ($p in @($script:OpenApiPaths.PSObject.Properties)) {
            if (($p.Name -like '/api/session/{*}') -and ($null -ne $p.Value.PSObject.Properties['delete'])) { $hasDelete = $true; break }
        }
    } catch { $hasDelete = $false }
    if (-not $hasDelete) { return [ordered]@{ ok = $false; reason = 'sem-path-DELETE-real-no-runtime' } }
    $r = Invoke-Api -Method 'DELETE' -Path ('/api/session/' + $SessionId)
    if ([bool]$r.ok) { return [ordered]@{ ok = $true; reason = '' } }
    return [ordered]@{ ok = $false; reason = ('delete-failed:exit=' + [int]$r.exit + ' ' + (Get-LaneSafeText $r.body 160)) }
}

# ---------- reconciler helpers ----------
function Get-Reconciliation {
    [CmdletBinding()] param($Runs, $Observations, [int]$StaleAfterSeconds = 3600)
    $bindings = @()
    foreach ($run in @($Runs)) {
        $bindings += , @{
            run_id          = [string](Get-JsonProp $run 'run_id' '')
            root_session    = [string](Get-JsonProp $run 'root_session' '')
            worker_sessions = @([string[]]@((Get-JsonProp $run 'worker_sessions' @())))
            bound_at        = [string](Get-JsonProp $run 'bound_at' '')
        }
    }
    $obs = @()
    foreach ($o in @($Observations)) { $obs += , $o }
    return (Get-OrchestrationSessionReconciliation -Bindings $bindings -Observations $obs -StaleAfterSeconds $StaleAfterSeconds)
}

# ---------- inicializacao de dirs ----------
$tempRoot = [IO.Path]::GetTempPath()
if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $tempRoot = $env:RUNNER_TEMP }
if ([string]::IsNullOrWhiteSpace($TargetHome)) {
    $TargetHome = Join-Path $tempRoot ('oo-sesslane-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}
if (Test-Path -LiteralPath $TargetHome) {
    Write-Error ('TargetHome ja existe: ' + $TargetHome + ' (home EXCLUSIVO por execucao).')
    exit 1
}
if ([string]::IsNullOrWhiteSpace($EvidenceDir)) {
    $EvidenceDir = Join-Path $RepoRoot ('evidence\v3.1\runtime-reliability\session-lane-' + [DateTime]::UtcNow.ToString('yyyy-MM-dd'))
}
$script:EvidenceDir = $EvidenceDir
try {
    New-Item -ItemType Directory -Path $TargetHome -Force | Out-Null
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
} catch { Write-Error ('falha ao criar dirs: ' + $_.Exception.Message); exit 1 }
# F2: trilha advisory-only abre aqui (LANE_START nunca decide gate).
try { [void](Write-LaneTrailEvent -Event 'LANE_START' -Fields @{ scenario_filter_count = @($ScenarioFilter).Count }) } catch { }

$xdg = Join-Path $TargetHome 'xdg'
$xdgData = Join-Path $TargetHome 'xdg-data'
$xdgState = Join-Path $TargetHome 'xdg-state'
$xdgCache = Join-Path $TargetHome 'xdg-cache'
$script:HomeT = Join-Path $TargetHome 'home'
$script:CwdT = Join-Path $TargetHome 'cwd'
$script:KernelTasksDir = Join-Path $TargetHome 'kernel-tasks'
$script:EnvelopeDir = Join-Path $TargetHome 'envelopes'
foreach ($d in @($xdg, $xdgData, $xdgState, $xdgCache, $script:HomeT, $script:CwdT, $script:KernelTasksDir, $script:EnvelopeDir)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
$script:IsoEnv = @{
    XDG_CONFIG_HOME = $xdg
    XDG_DATA_HOME   = $xdgData
    XDG_STATE_HOME  = $xdgState
    XDG_CACHE_HOME  = $xdgCache
    HOME            = $script:HomeT
    USERPROFILE     = $script:HomeT
}

try {
    # ---------- 1. binario exato ----------
    $cands = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($BinaryPath)) {
        if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) { Fail-Lane ('-BinaryPath inexistente: ' + $BinaryPath) }
        [void]$cands.Add($BinaryPath)
    } else {
        foreach ($c in @(Get-Command -Name 'opencode' -All -ErrorAction SilentlyContinue)) {
            $src = ''
            try { $src = [string]$c.Source } catch { $src = '' }
            if (-not [string]::IsNullOrWhiteSpace($src) -and (Test-Path -LiteralPath $src)) { [void]$cands.Add($src) }
        }
        $profileBin = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe'
        if ((Test-Path -LiteralPath $profileBin -PathType Leaf) -and (-not ($cands -contains $profileBin))) { [void]$cands.Add($profileBin) }
    }
    foreach ($cand in @($cands)) {
        $exePath = [string]$cand
        $ext = [IO.Path]::GetExtension($exePath).ToLowerInvariant()
        if ($ext -ne '.exe') {
            $resolved = ''
            try { $resolved = Resolve-SpikeShimTarget -ShimPath $exePath } catch { $resolved = '' }
            if ([string]::IsNullOrWhiteSpace($resolved) -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) { continue }
            $exePath = $resolved
        }
        $vr = Invoke-SpikeChild -FilePath $exePath -ArgumentList @('--version') -TimeoutMs 30000 -CleanEnvironment -StdinNul
        if ([bool]$vr.TimedOut) { continue }
        if ([int]$vr.ExitCode -ne 0) { continue }
        $verText = ([string]$vr.Stdout + "`n" + [string]$vr.Stderr)
        $exact = $false
        try { $exact = Test-SpikeExactVersion -Text $verText -Version $ExpectedVersion } catch { $exact = $false }
        if (-not $exact) { continue }
        $script:Exe = $exePath
        break
    }
    if ([string]::IsNullOrWhiteSpace($script:Exe)) { Fail-Lane ('nenhum binario V2 com versao exata ' + $ExpectedVersion + ' (PATH e perfil V2 considerados).') }
    # sanitizacao de caminho do operador na evidencia (o binario pode viver sob o home real)
    $script:ExeForEvidence = ([string]$script:Exe)
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $script:ExeForEvidence = $script:ExeForEvidence.Replace($env:USERPROFILE, '~') }
    } catch { }
    Add-LaneCheck 'version_exact' $true ('cmd: <bin> --version (-CleanEnvironment); Test-SpikeExactVersion ' + $ExpectedVersion)

    # ---------- 2. config com 19 workers + overlay de probes ----------
    $agentsDir = Join-Path $RepoRoot 'source\agents'
    $cfgPath = Join-Path $xdg 'opencode\opencode.json'
    $files = @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File | Sort-Object Name)
    if ($files.Count -eq 0) { Fail-Lane ('nenhum .md canonico em ' + $agentsDir) }
    $agents = [ordered]@{}
    $stems = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        [void]$stems.Add($stem)
        $parsed = $null
        try { $parsed = Read-AgentFileCanonical -Path $f.FullName } catch { Fail-Lane ('parse canonico falhou (' + $stem + '): ' + $_.Exception.Message) }
        $c = $parsed.Canonical
        $rules = New-Object System.Collections.ArrayList
        if ([bool]$c.EditPresent) { [void]$rules.Add([ordered]@{ action = 'edit'; resource = '*'; effect = [string]$c.Edit }) }
        foreach ($r in @(Get-OrderedV2ShellRules -Canonical $c)) { [void]$rules.Add([ordered]@{ action = [string]$r.Action; resource = [string]$r.Resource; effect = [string]$r.Effect }) }
        foreach ($r in @(Get-OrderedV2TaskRules -Canonical $c)) { [void]$rules.Add([ordered]@{ action = [string]$r.Action; resource = [string]$r.Resource; effect = [string]$r.Effect }) }
        $agents[$stem] = [ordered]@{ mode = [string]$c.Mode; permissions = @($rules) }
    }
    $buildRules = New-Object System.Collections.ArrayList
    [void]$buildRules.Add([ordered]@{ action = 'subagent'; resource = '*'; effect = 'deny' })
    foreach ($s in ($stems | Sort-Object)) { [void]$buildRules.Add([ordered]@{ action = 'subagent'; resource = [string]$s; effect = 'allow' }) }
    # Overlay do probe session-permission-narrowing (config declarada na evidencia):
    # comando-marcador negado no build; eco-marcador nao casado fica sob as regras base.
    [void]$buildRules.Add([ordered]@{ action = 'shell'; resource = 'cmd /c echo DeniedProbe*'; effect = 'deny' })
    $orderedAgents = [ordered]@{ build = [ordered]@{ mode = 'primary'; permissions = @($buildRules) } }
    foreach ($s in ($stems | Sort-Object)) { $orderedAgents[[string]$s] = $agents[[string]$s] }
    $cfg = [ordered]@{
        default_agent = 'build'
        agents        = $orderedAgents
        experimental  = [ordered]@{ subagent_depth = 1 }
    }
    $cfgParent = Split-Path -Parent $cfgPath
    if (-not (Test-Path -LiteralPath $cfgParent -PathType Container)) { New-Item -ItemType Directory -Path $cfgParent -Force | Out-Null }
    [IO.File]::WriteAllText($cfgPath, ((($cfg | ConvertTo-Json -Depth 8).TrimEnd() + "`n") -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
    Add-LaneCheck 'config_19_workers_built' ($stems.Count -eq 19) ('opencode.json da lane com ' + $stems.Count + ' workers + overlay deny shell marker (probe narrowing)')

    # ---------- 3. isolamento ----------
    $dp = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('debug', 'paths') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
    if ([bool]$dp.TimedOut) { Fail-Lane 'debug paths: TIMEOUT 30s.' }
    if ([int]$dp.ExitCode -ne 0) { Fail-Lane ('debug paths: exit ' + $dp.ExitCode) }
    $dpText = ([string]$dp.Stdout + "`n" + [string]$dp.Stderr)
    if (-not ($dpText.Contains($xdg) -or $dpText.Contains(($xdg -replace '\\', '/')))) { Fail-Lane 'debug paths: config nao resolve dentro do home isolado.' }
    Add-LaneCheck 'isolation_paths' $true 'cmd: <bin> debug paths (isolado); config resolve no TargetHome'
    if ((-not [string]::IsNullOrWhiteSpace([string]$ModelKeyEnvName)) -and ([string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean))) {
        Add-LaneNote '-ModelKeyEnvName rejeitado (charset de env); opt-in desligado, pernas model-dependent seguem blocked'
    } elseif (-not [string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean)) {
        Add-LaneNote (('model-key opt-in ativo (' + (Get-LaneModelKeyLogToken) + '); passthrough pontual SOMENTE aos filhos opencode run das pernas 18/20/21'))
    }

    # ---------- 4. porta + invariante 49374 ----------
    $script:owner49374Before = 'QUERY_FAILED'
    try {
        $ln49374 = Get-PreflightNetTCPListenerBounded -Port 49374 -TimeoutMs 5000
        if ($null -ne $ln49374 -and [bool]$ln49374.QuerySucceeded) {
            if ([bool]$ln49374.Exists -and $null -ne $ln49374.OwningPID) {
                $idt = Get-PreflightProcessIdentity -OwnerPID ([int]$ln49374.OwningPID)
                $script:owner49374Before = ([string]$idt.Name + ':' + [string]$ln49374.OwningPID)
            } else { $script:owner49374Before = 'FREE' }
        }
    } catch { $script:owner49374Before = 'QUERY_FAILED' }
    $freePort = 0
    for ($try = 0; $try -lt 10; $try++) {
        $candPort = Get-SpikeFreePort
        if ($candPort -ne 49374) { $freePort = $candPort; break }
    }
    if ($freePort -eq 0) { Fail-Lane 'selecao de porta livre caiu 10x em 49374 (recusada).' }
    $script:Port = $freePort
    $pf = Invoke-PreflightPort -Port $freePort -ExpectedProcessNames @('opencode') -ExpectedProcessPaths @($script:Exe) -ExpectedProfileDir $TargetHome
    if (([string]$pf.Outcome -ne 'PORT_FREE') -or (-not [bool]$pf.ShouldStart)) { Fail-Lane ('preflight porta ' + $freePort + ': ' + [string]$pf.Outcome + ' should_start=' + [bool]$pf.ShouldStart) }
    Add-LaneCheck 'port_preflight_free' $true ('porta ' + $freePort + ' => PORT_FREE should_start=true')

    # ---------- 5. servico: set port -> job -> start -> listener ----------
    $sp = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'set', 'port', "$freePort") -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
    if ([bool]$sp.TimedOut) { Fail-Lane 'service set port: TIMEOUT 30s.' }
    if ([int]$sp.ExitCode -ne 0) { Fail-Lane ('service set port: exit ' + $sp.ExitCode) }
    Add-LaneCheck 'service_port_configured' $true ('service set port => ' + $freePort)

    $svcJob = New-RuntimeJobObject
    $script:svcJob = $svcJob
    if (-not [bool]$svcJob.Ok) { Fail-Lane ('job object NAO criado (fail-closed antes do start): ' + [string]$svcJob.Reason) }
    $jobFlags = Get-RuntimeJobLimitFlags -Job $svcJob
    if ((-not [bool]$jobFlags.Ok) -or (-not [bool]$jobFlags.KillOnClose)) { Fail-Lane ('job sem KILL_ON_JOB_CLOSE provado (fail-closed antes do start)') }
    Add-LaneCheck 'job_object_created_before_start' $true ('limit_flags=0x' + ([uint32]$jobFlags.LimitFlags).ToString('x'))

    try { [void](Write-LaneTrailEvent -Event 'SERVICE_START_REQUESTED' -Fields @{ site = 'lane-init'; port = ([int]$script:Port) }) } catch { }
    $sst = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'start') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul -JobObject $svcJob
    if ([bool]$sst.TimedOut) { Fail-Lane 'service start: TIMEOUT 30s.' }
    if ([int]$sst.ExitCode -ne 0) { Fail-Lane ('service start: exit ' + $sst.ExitCode) }
    if (-not [bool]$sst.JobAssigned) { Fail-Lane ('atribuicao ao job NAO comprovada (nota=' + [string]$sst.JobNote + ')') }
    Add-LaneCheck 'service_start_explicit_job_assigned' $true ('service start rc=0; job_assigned=true; nota=' + [string]$sst.JobNote)

    function Wait-LaneListener([int]$DeadlineSeconds, [ValidateSet('presence', 'absence')][string]$Mode) {
        $deadline = [DateTime]::UtcNow.AddSeconds($DeadlineSeconds)
        $seen = $false; $absent = $false; $inconclusive = 0
        # F2: captura do OwningPID (aditivo; Seen/Absent/Inconclusive intactos).
        $ownPid = 0
        while ([DateTime]::UtcNow -lt $deadline) {
            $remainingMs = [int]([DateTime]::UtcNow - $deadline).TotalMilliseconds * -1
            if ($remainingMs -gt 10000) { $remainingMs = 10000 }
            if ($remainingMs -lt 500) { $remainingMs = 500 }
            $ln = Get-PreflightNetTCPListenerBounded -Port $script:Port -TimeoutMs $remainingMs
            if ($null -ne $ln -and [bool]$ln.QuerySucceeded) {
                if ([bool]$ln.Exists -and $null -ne $ln.OwningPID) { $seen = $true; try { $ownPid = [int]$ln.OwningPID } catch { }; if ($Mode -eq 'presence') { break } }
                elseif ([bool]$ln.Exists) { $inconclusive++ }
                else { $absent = $true; if ($Mode -eq 'absence') { break } }
            } else { $inconclusive++ }
            Start-Sleep -Milliseconds 1000
        }
        return [ordered]@{ Seen = $seen; Absent = $absent; Inconclusive = $inconclusive; OwningPID = $ownPid }
    }
    $obs = Wait-LaneListener -DeadlineSeconds 30 -Mode 'presence'
    $obsPidInit = 0
    try { if ($null -ne $obs.OwningPID) { $obsPidInit = [int]$obs.OwningPID } } catch { $obsPidInit = 0 }
    if (-not [bool]$obs.Seen) {
        try { [void](Write-LaneTrailEvent -Event 'SERVICE_UNRESPONSIVE' -Fields @{ site = 'lane-init'; port = ([int]$script:Port) }) } catch { }
        Fail-Lane ('service start: sem listener na porta ' + $freePort + ' apos 30s.')
    }
    try { [void](Write-LaneTrailEvent -Event 'SERVICE_STARTED' -Fields @{ site = 'lane-init'; job_assigned = $true; pid_after = $obsPidInit; presence_seen = $true }) } catch { }
    Add-LaneCheck 'service_listener_observed' $true ('listener porta ' + $freePort + ' observado (fato P22)')

    # ---------- 5b. auth REST ----------
    $svcJsonPath = Join-Path (Join-Path $xdg 'opencode') 'service.json'
    $script:AuthEnv = @{}
    foreach ($k in @($script:IsoEnv.Keys)) { $script:AuthEnv[[string]$k] = [string]$script:IsoEnv[$k] }
    try {
        $svcRaw = [IO.File]::ReadAllText($svcJsonPath, [Text.Encoding]::UTF8)
        $svcJson = ($svcRaw | ConvertFrom-Json)
        $pw = [string](Get-JsonProp $svcJson 'password' '')
        if (-not [string]::IsNullOrWhiteSpace($pw)) { $script:AuthEnv['OPENCODE_PASSWORD'] = $pw }
        $pw = ''
    } catch { Add-LaneNote 'service.json sem password legivel; api segue sem OPENCODE_PASSWORD (endpoints podem recusar).' }
    Add-LaneCheck 'rest_auth_from_service_json' $true ('password lida de service.json do perfil isolado (valor nunca logado)')

    # ---------- 5c. openapi real (uma vez) ----------
    $specResp = Invoke-Api -Method 'GET' -Path '/openapi.json' -TimeoutMs 30000
    if ([bool]$specResp.ok) {
        $specJson = Convert-ApiJson $specResp.body
        if ($null -ne $specJson) { $script:OpenApiPaths = Get-JsonProp $specJson 'paths' $null }
    }
    $openApiOk = ($null -ne $script:OpenApiPaths)
    Add-LaneCheck 'openapi_real_parsed' $openApiOk ('spec real carregada (' + $(if ($openApiOk) { 'paths disponiveis' } else { 'indisponivel; cenarios dependentes viram blocked honesto' }) + ')')

    # ---------- helpers de task ----------
    function New-LaneTask {
        [CmdletBinding()] param([string]$TaskId, [string]$Objective)
        return (Invoke-KernelCli -KernelArgs @('-Action', 'create', '-TaskId', $TaskId, '-Objective', $Objective, '-RuntimeGeneration', '2', '-RuntimeVersion', $ExpectedVersion, '-RuntimeProfile', 'v2', '-TasksDir', $script:KernelTasksDir, '-Actor', 'session-lane'))
    }
    function Get-LaneTask {
        [CmdletBinding()] param([string]$TaskId)
        return (Invoke-KernelCli -KernelArgs @('-Action', 'get', '-TaskId', $TaskId, '-TasksDir', $script:KernelTasksDir))
    }
    function Get-LaneTaskBindings {
        [CmdletBinding()] param([string]$TaskId)
        return (Invoke-KernelCli -KernelArgs @('-Action', 'get-bindings', '-TaskId', $TaskId, '-TasksDir', $script:KernelTasksDir))
    }
    function Get-LaneTaskFileHash {
        [CmdletBinding()] param([string]$TaskId)
        $f = Join-Path $script:KernelTasksDir ($TaskId + '.json')
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return '' }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($f)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    }
    function New-TaskAssertions {
        [CmdletBinding()] param([string]$TaskId)
        $g = Get-LaneTask -TaskId $TaskId
        $rec = $g.json
        $state = [string](Get-JsonProp $rec 'state' '')
        $rev = [int](Get-JsonProp $rec 'revision' -1)
        $terminal = (($state -ceq 'DONE') -or ($state -ceq 'EXHAUSTED') -or ($state -ceq 'CANCELLED'))
        return [ordered]@{ ok = (Test-KernelOk $g); state = $state; revision = $rev; terminal = $terminal; record = $rec; exit = [int]$g.exit; timedout = [bool]$g.timedout; stdout = [string]$g.stdout; stderr = [string]$g.stderr }
    }

    $laneActiveStates = @('DISCOVERING', 'PLANNING', 'IMPLEMENTING', 'VALIDATING', 'REVIEWING', 'FIXING', 'BLOCKED')

    # ==================================================================
    # RR-E2E-16: fechar root session real no meio da task
    # ==================================================================
    if ((@($ScenarioFilter).Count -eq 0) -or (@($ScenarioFilter) -ccontains '16')) {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $s = New-RealSession
            if (-not [bool]$s.ok) {
                [void](Add-ScenarioProof $proofs 'real-session-created' $false $s.reason)
                Set-ScenarioResult 'RR-E2E-16' 'blocked' ('sessao real indisponivel: ' + $s.reason) $proofs $coverage
            } else {
                $sid = [string]$s.id
                [void](Add-ScenarioProof $proofs 'real-session-created' $true ('id=' + $sid))
                $t = New-LaneTask -TaskId 'lane16' -Objective 'RR-E2E-16: fechar root session real com task ativa (lane de closure)'
                if (-not (Test-KernelOk $t)) {
                    [void](Add-ScenarioProof $proofs 'task-created' $false ('exit=' + [int]$t.exit + ' timedout=' + [bool]$t.timedout + ' stderr=' + $t.stderr + ' stdout=' + $t.stdout))
                    Set-ScenarioResult 'RR-E2E-16' 'fail' ('kernel create falhou: exit=' + [int]$t.exit + ' out=' + $t.stdout + ' err=' + $t.stderr) $proofs $coverage
                } else {
                    $rev0 = [int](Get-JsonProp $t.json 'revision' -1)
                    $tr = Invoke-KernelCli -KernelArgs @('-Action', 'transition', '-TaskId', 'lane16', '-ToState', 'PLANNING', '-Actor', 'session-lane', '-ExpectedRevision', "$rev0", '-TasksDir', $script:KernelTasksDir)
                    if (-not (Test-KernelOk $tr)) {
                        [void](Add-ScenarioProof $proofs 'task-transitioned-active' $false $tr.stderr)
                        Set-ScenarioResult 'RR-E2E-16' 'fail' ('transition PLANNING falhou: ' + $tr.stderr) $proofs $coverage
                    } else {
                        [void](Add-ScenarioProof $proofs 'task-transitioned-active' $true 'DISCOVERING->PLANNING')
                        $bd = Invoke-KernelCli -KernelArgs @('-Action', 'bind-session', '-TaskId', 'lane16', '-RunId', 'lane16-run', '-SessionId', $sid, '-ExpectedRevision', ([string](Get-JsonProp $tr.json 'revision' '0')), '-TasksDir', $script:KernelTasksDir, '-RootSessionId', $sid)
                        if (-not (Test-KernelOk $bd)) {
                            [void](Add-ScenarioProof $proofs 'session-bound' $false $bd.stderr)
                            Set-ScenarioResult 'RR-E2E-16' 'fail' ('bind-session falhou: ' + $bd.stderr) $proofs $coverage
                        } else {
                            [void](Add-ScenarioProof $proofs 'session-bound' $true ('run=lane16-run root=' + $sid))
                            $pre = Probe-SessionExists -SessionId $sid
                            [void](Add-ScenarioProof $proofs 'session-present-before-close' (($pre.state -ceq 'present')) ('probe=' + $pre.state))
                            $cl = Close-RealSession -SessionId $sid
                            if (-not [bool]$cl.ok) {
                                Set-ScenarioResult 'RR-E2E-16' 'blocked' ('fechamento real indisponivel: ' + $cl.reason) $proofs $coverage
                            } else {
                                [void](Add-ScenarioProof $proofs 'session-closed-real' $true 'DELETE /api/session/{id} rc=0')
                                $post = Probe-SessionExists -SessionId $sid -DeadlineSeconds 15
                                [void](Add-ScenarioProof $proofs 'absence-proven-after-close' (($post.state -ceq 'absent')) ('probe=' + $post.state))
                                $listed = Test-SessionListed -SessionId $sid
                                if ([bool]$listed.decided) { [void](Add-ScenarioProof $proofs 'absent-from-list' (-not [bool]$listed.listed) ('listado=' + [bool]$listed.listed)) }
                                $a1 = New-TaskAssertions -TaskId 'lane16'
                                [void](Add-ScenarioProof $proofs 'task-persisted' ([bool]$a1.ok) ('state=' + $a1.state + ' rev=' + $a1.revision + ' exit=' + $a1.exit + ' timedout=' + $a1.timedout + ' out=' + $a1.stdout + ' err=' + $a1.stderr))
                                [void](Add-ScenarioProof $proofs 'no-false-completion' ((-not [bool]$a1.terminal)) ('state=' + $a1.state + ' (nao-terminal)'))
                                $gb = Get-LaneTaskBindings -TaskId 'lane16'
                                $runRow = $null
                                foreach ($rr in @(Get-JsonProp (Get-JsonProp $gb.json 'bindings' $null) 'runs' @())) {
                                    if ([string](Get-JsonProp $rr 'run_id' '') -ceq 'lane16-run') { $runRow = $rr; break }
                                }
                                [void](Add-ScenarioProof $proofs 'binding-record-preserved' ($null -ne $runRow) ('status=' + $(if ($null -ne $runRow) { [string](Get-JsonProp $runRow 'status' '') } else { 'run-ausente' })))
                                $s2 = New-RealSession
                                if (-not [bool]$s2.ok) {
                                    [void](Add-ScenarioProof $proofs 'recovery-new-session' $false $s2.reason)
                                    Set-ScenarioResult 'RR-E2E-16' 'fail' ('nova sessao para recovery falhou: ' + $s2.reason) $proofs $coverage
                                } else {
                                    $revB = [int](Get-JsonProp (Get-LaneTask -TaskId 'lane16').json 'revision' -1)
                                    $dt = Invoke-KernelCli -KernelArgs @('-Action', 'detach-session', '-TaskId', 'lane16', '-SessionId', $sid, '-ExpectedRevision', "$revB", '-TasksDir', $script:KernelTasksDir)
                                    if (-not (Test-KernelOk $dt)) {
                                        [void](Add-ScenarioProof $proofs 'recovery-detach' $false ('revB=' + $revB + ' exit=' + [int]$dt.exit + ' stderr=' + $dt.stderr + ' stdout=' + $dt.stdout))
                                        Set-ScenarioResult 'RR-E2E-16' 'fail' ('detach falhou: ' + $dt.stderr) $proofs $coverage
                                    } else {
                                        $revC = [int](Get-JsonProp (Get-LaneTask -TaskId 'lane16').json 'revision' -1)
                                        $rb = Invoke-KernelCli -KernelArgs @('-Action', 'rebind-session', '-TaskId', 'lane16', '-RunId', 'lane16-run', '-SessionId', [string]$s2.id, '-ExpectedRevision', "$revC", '-TasksDir', $script:KernelTasksDir)
                                        [void](Add-ScenarioProof $proofs 'recovery-rebind' (Test-KernelOk $rb) $(if (Test-KernelOk $rb) { ('root=' + [string]$s2.id) } else { $rb.stderr }))
                                        $a2 = New-TaskAssertions -TaskId 'lane16'
                                        [void](Add-ScenarioProof $proofs 'recovery-state-intact' (([bool]$a2.ok) -and ($a2.state -ceq 'PLANNING') -and (-not [bool]$a2.terminal)) ('state=' + $a2.state))
                                        $allOk = $true
                                        foreach ($p in @($proofs)) { if (-not [bool]$p['ok']) { $allOk = $false; break } }
                                        [void]$coverage.Add('required_activation: root session real fechada com task ativa - exercitado')
                                        [void]$coverage.Add('task persistida / sem conclusao falsa / recuperacao - provado')
                                        Set-ScenarioResult 'RR-E2E-16' $(if ($allOk) { 'pass-real' } else { 'fail' }) $(if ($allOk) { 'cadeia completa provada em runtime real' } else { 'provas com falha - ver proofs' }) $proofs $coverage
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            Set-ScenarioResult 'RR-E2E-16' 'fail' ('excecao: ' + $_.Exception.Message) $proofs $coverage
        }
    }

    # ==================================================================
    # RR-E2E-17: restart real com task ativa
    # ==================================================================
    if ((@($ScenarioFilter).Count -eq 0) -or (@($ScenarioFilter) -ccontains '17')) {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $s = New-RealSession
            $t = New-LaneTask -TaskId 'lane17' -Objective 'RR-E2E-17: restart real do OpenCode com task ativa (lane de closure)'
            if ((-not [bool]$s.ok) -or (-not (Test-KernelOk $t))) {
                Set-ScenarioResult 'RR-E2E-17' 'blocked' ('pre-requisitos: sessao=' + [bool]$s.ok + ' task=' + (Test-KernelOk $t)) $proofs $coverage
            } else {
                $sid = [string]$s.id
                $rev0 = [int](Get-JsonProp $t.json 'revision' -1)
                $tr = Invoke-KernelCli -KernelArgs @('-Action', 'transition', '-TaskId', 'lane17', '-ToState', 'PLANNING', '-Actor', 'session-lane', '-ExpectedRevision', "$rev0", '-TasksDir', $script:KernelTasksDir)
                $bd = Invoke-KernelCli -KernelArgs @('-Action', 'bind-session', '-TaskId', 'lane17', '-RunId', 'lane17-run', '-SessionId', $sid, '-ExpectedRevision', ([string](Get-JsonProp $tr.json 'revision' '0')), '-TasksDir', $script:KernelTasksDir, '-RootSessionId', $sid)
                if ((-not (Test-KernelOk $tr)) -or (-not (Test-KernelOk $bd))) {
                    Set-ScenarioResult 'RR-E2E-17' 'fail' ('setup: transition/bind falharam') $proofs $coverage
                } else {
                    [void](Add-ScenarioProof $proofs 'task-active-bound' $true ('state=PLANNING root=' + $sid))
                    $hashPre = Get-LaneTaskFileHash -TaskId 'lane17'
                    # restart REAL: stop owned -> settlement -> start -> presence
                    # F2: snapshot do PID antes do stop (trilha apenas; sem gate).
                    $pidBefore17 = 0
                    try { $pidBefore17 = Get-LaneCurrentListenerPid } catch { $pidBefore17 = 0 }
                    $stp = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'stop') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
                    $stopOk = ((-not [bool]$stp.TimedOut) -and ([int]$stp.ExitCode -eq 0))
                    [void](Add-ScenarioProof $proofs 'restart-stop-owned' $stopOk ('rc=' + [int]$stp.ExitCode))
                    $settle = Wait-LaneListener -DeadlineSeconds 30 -Mode 'absence'
                    [void](Add-ScenarioProof $proofs 'restart-settlement-observed' ([bool]$settle.Absent) ('absente_conclusiva=' + [bool]$settle.Absent + ' inconclusivas=' + [int]$settle.Inconclusive))
                    $sst2 = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'start') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul -JobObject $svcJob
                    $startOk = ((-not [bool]$sst2.TimedOut) -and ([int]$sst2.ExitCode -eq 0) -and [bool]$sst2.JobAssigned)
                    [void](Add-ScenarioProof $proofs 'restart-start-owned' $startOk ('rc=' + [int]$sst2.ExitCode + ' job=' + [bool]$sst2.JobAssigned))
                    $pres = Wait-LaneListener -DeadlineSeconds 30 -Mode 'presence'
                    [void](Add-ScenarioProof $proofs 'restart-listener-observed' ([bool]$pres.Seen) ('presenca=' + [bool]$pres.Seen))
                    # F2: trilha EXPECTED_TEST_RESTART do ponto 17 (advisory-only).
                    try { [void](Write-LaneServiceCycleTrail -Site 'RR-E2E-17' -PidBefore $pidBefore17 -StopResult $stp -StartResult $sst2 -Settle $settle -Presence $pres) } catch { }
                    # re-auth (novo service.json pode ter password nova)
                    try {
                        $svcRaw2 = [IO.File]::ReadAllText($svcJsonPath, [Text.Encoding]::UTF8)
                        $svcJson2 = ($svcRaw2 | ConvertFrom-Json)
                        $pw2 = [string](Get-JsonProp $svcJson2 'password' '')
                        if (-not [string]::IsNullOrWhiteSpace($pw2)) { $script:AuthEnv['OPENCODE_PASSWORD'] = $pw2 }
                        $pw2 = ''
                    } catch { }
                    if ($stopOk -and $startOk -and ([bool]$settle.Absent) -and ([bool]$pres.Seen)) {
                        $a1 = New-TaskAssertions -TaskId 'lane17'
                        [void](Add-ScenarioProof $proofs 'task-state-preserved' (([bool]$a1.ok) -and ($a1.state -ceq 'PLANNING')) ('state=' + $a1.state + ' rev=' + $a1.revision))
                        $hashPost = Get-LaneTaskFileHash -TaskId 'lane17'
                        [void](Add-ScenarioProof $proofs 'task-bytes-unchanged' ($hashPre -ceq $hashPost) ('sha256_igual=' + ($hashPre -ceq $hashPost)))
                        $postProbe = Probe-SessionExists -SessionId $sid -DeadlineSeconds 10
                        $observed = 'missing'
                        if ($postProbe.state -ceq 'present') { $observed = 'running' }
                        [void](Add-ScenarioProof $proofs 'session-after-restart-observed' (($postProbe.state -ne 'inconclusive')) ('observado=' + $observed + ' probe=' + $postProbe.state))
                        $gb = Get-LaneTaskBindings -TaskId 'lane17'
                        $runs = @(Get-JsonProp (Get-JsonProp $gb.json 'bindings' $null) 'runs' @())
                        [void](Add-ScenarioProof $proofs 'bindings-read-for-reconciler' ((@($runs).Count -gt 0) -and (Test-KernelOk $gb)) ('runs=' + @($runs).Count + ' gb_exit=' + [int]$gb.exit))
                        $obs = @()
                        if ($postProbe.state -ne 'inconclusive') {
                            $obs += , @{ session_id = $sid; observed = $observed; last_seen = (Get-LaneTimestampUtc) }
                        }
                        $rec = Get-Reconciliation -Runs $runs -Observations $obs
                        $actionOk = $false
                        $actionDetail = ''
                        foreach ($act in @(Get-JsonProp $rec 'recommended_actions' @())) {
                            $actionDetail = ([string](Get-JsonProp $act 'action' '') + '/' + $sid)
                            if (($observed -ceq 'running') -and ([string](Get-JsonProp $act 'action' '') -ceq 'reattach')) { $actionOk = $true }
                            if (($observed -ceq 'missing') -and ([string](Get-JsonProp $act 'action' '') -ceq 'mark_SESSION_LOST')) { $actionOk = $true }
                        }
                        [void](Add-ScenarioProof $proofs 'reconciler-matches-real-observation' $actionOk ('observado=' + $observed + ' acao=' + $actionDetail + ' rows=' + @(@(Get-JsonProp $rec 'runs' @())).Count + ' actions=' + @(@(Get-JsonProp $rec 'recommended_actions' @())).Count + ' runs_in=' + @($runs).Count + ' obs_in=' + @($obs).Count + ' root_in=' + [string](Get-JsonProp $runs[0] 'root_session' '') + ' probed=' + [bool](Get-JsonProp $rec 'probed' $false)))
                        [void]$coverage.Add('comportamento apos restart real: task persistida + observacao real reconciliada')
                        $allOk = $true
                        foreach ($p in @($proofs)) { if (-not [bool]$p['ok']) { $allOk = $false; break } }
                        Set-ScenarioResult 'RR-E2E-17' $(if ($allOk) { 'pass-real' } else { 'fail' }) $(if ($allOk) { 'stop owned + settlement + start + estado preservado + reconciliador consumiu observacao real' } else { 'provas com falha' }) $proofs $coverage
                    } else {
                        Set-ScenarioResult 'RR-E2E-17' 'fail' 'ciclo de restart incompleto (stop/start/settlement/listener)' $proofs $coverage
                    }
                }
            }
        } catch {
            Set-ScenarioResult 'RR-E2E-17' 'fail' ('excecao: ' + $_.Exception.Message) $proofs $coverage
        }
    }

    # serviço pode ter sido re-iniciado: garantir que segue no ar para os proximos cenarios
    # (isolamento pos-16/17, mesmo padrao F1-FIX-01: somente quando algum
    # cenario posterior sera executado; filtro sem 18-22 pula sem falha)
    if (Test-LaneNeedsPost17Gate -Filter $ScenarioFilter) {
        $presCheck = Wait-LaneListener -DeadlineSeconds 5 -Mode 'presence'
        if (-not [bool]$presCheck.Seen) {
            # F2: ausencia ja provada pelo gate; pid_before=0 sem snapshot.
            $sst3 = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'start') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul -JobObject $svcJob
            $presCheck = Wait-LaneListener -DeadlineSeconds 30 -Mode 'presence'
            try { [void](Write-LaneServiceCycleTrail -Site 'post17-gate' -PidBefore 0 -StopResult $null -StartResult $sst3 -Settle $null -Presence $presCheck) } catch { }
            if (-not [bool]$presCheck.Seen) {
                try { [void](Write-LaneTrailEvent -Event 'SERVICE_UNRESPONSIVE' -Fields @{ site = 'post17-gate'; port = ([int]$script:Port) }) } catch { }
                Fail-Lane 'servico indisponivel apos cenarios 16/17; lane abortada.'
            }
            Add-LaneNote 'service re-iniciado apos restart do cenario 17'
        }
    }

    # ==================================================================
    # RR-E2E-18: child real reconciliado apos restart
    # ==================================================================
    if ((@($ScenarioFilter).Count -eq 0) -or (@($ScenarioFilter) -ccontains '18')) {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $spec = $script:OpenApiPaths
            $parentSupported = $false
            try {
                $pp = $spec.PSObject.Properties['/api/session']
                $body = Get-JsonProp (Get-JsonProp (Get-JsonProp $pp.Value 'post' $null) 'requestBody' $null) 'content' $null
                if ($null -ne $body) {
                    $txt = (ConvertTo-Json -InputObject $body -Compress -Depth 8)
                    $parentSupported = ($txt -match 'parentID')
                }
            } catch { $parentSupported = $false }
            $s = New-RealSession
            $t = New-LaneTask -TaskId 'lane18' -Objective 'RR-E2E-18: child real reconciliado apos restart real'
            if ((-not [bool]$s.ok) -or (-not (Test-KernelOk $t))) {
                Set-ScenarioResult 'RR-E2E-18' 'blocked' ('pre-requisitos: sessao=' + [bool]$s.ok + ' task=' + (Test-KernelOk $t)) $proofs $coverage
            } elseif (-not $parentSupported) {
                [void](Add-ScenarioProof $proofs 'child-creation-supported-by-runtime' $false 'openapi real sem parentID no schema de criacao')
                Set-ScenarioResult 'RR-E2E-18' 'blocked' 'criacao de child (parentID) nao suportada pelo runtime real do pin' $proofs $coverage
            } else {
                $rootId = [string]$s.id
                $rev0 = [int](Get-JsonProp $t.json 'revision' -1)
                $null = (Invoke-KernelCli -KernelArgs @('-Action', 'transition', '-TaskId', 'lane18', '-ToState', 'PLANNING', '-Actor', 'session-lane', '-ExpectedRevision', "$rev0", '-TasksDir', $script:KernelTasksDir))
                $ch = New-RealSession -ParentId $rootId
                if (-not [bool]$ch.ok) {
                    [void](Add-ScenarioProof $proofs 'child-created-real' $false $ch.reason)
                    Set-ScenarioResult 'RR-E2E-18' 'blocked' ('criacao de child real falhou: ' + $ch.reason) $proofs $coverage
                } else {
                    $childId = [string]$ch.id
                    [void](Add-ScenarioProof $proofs 'child-created-real' $true ('child=' + $childId + ' parent=' + $rootId))
                    $chGet = Invoke-Api -Method 'GET' -Path ('/api/session/' + $childId)
                    $chJson = Convert-ApiJson $chGet.body
                    $chNode = Get-JsonProp $chJson 'data' $chJson
                    $observedParent = [string](Get-JsonProp $chNode 'parentID' (Get-JsonProp $chNode 'parent_id' ''))
                    # provenance nativa: o create com parentID foi ACEITO pelo runtime (fato);
                    # o eco do parentID no GET e observado como informacao (2.0.23 pode nao ecoar)
                    [void](Add-ScenarioProof $proofs 'child-provenance-native' (($chGet.ok)) ('create-com-parentID-aceito; parentID_no_get_response=' + $observedParent))
                    # bind do child como root do run proprio (provenance parent_id = root real)
                    $revB = [int](Get-JsonProp (Get-LaneTask -TaskId 'lane18').json 'revision' -1)
                    $bd = Invoke-KernelCli -KernelArgs @('-Action', 'bind-session', '-TaskId', 'lane18', '-RunId', 'lane18-child-run', '-SessionId', $childId, '-ExpectedRevision', "$revB", '-TasksDir', $script:KernelTasksDir, '-ParentSessionId', $rootId, '-RootSessionId', $rootId)
                    [void](Add-ScenarioProof $proofs 'child-bound-to-task' (Test-KernelOk $bd) ('run=lane18-child-run parent_provenance=' + $rootId + ' exit=' + [int]$bd.exit + ' err=' + $bd.stderr + ' out=' + $bd.stdout))
                    # restart real
                    # F2: snapshot do PID antes do stop (trilha apenas; sem gate).
                    $pidBefore18 = 0
                    try { $pidBefore18 = Get-LaneCurrentListenerPid } catch { $pidBefore18 = 0 }
                    $stp = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'stop') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
                    $settle = Wait-LaneListener -DeadlineSeconds 30 -Mode 'absence'
                    $sst2 = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'start') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul -JobObject $svcJob
                    $pres = Wait-LaneListener -DeadlineSeconds 30 -Mode 'presence'
                    $restartOk = (([int]$stp.ExitCode -eq 0) -and ([bool]$settle.Absent) -and ([int]$sst2.ExitCode -eq 0) -and ([bool]$sst2.JobAssigned) -and ([bool]$pres.Seen))
                    [void](Add-ScenarioProof $proofs 'restart-real' $restartOk ('stop+settlement+start+listener'))
                    # F2: trilha EXPECTED_TEST_RESTART do ponto 18 (advisory-only).
                    try { [void](Write-LaneServiceCycleTrail -Site 'RR-E2E-18' -PidBefore $pidBefore18 -StopResult $stp -StartResult $sst2 -Settle $settle -Presence $pres) } catch { }
                    try {
                        $svcRaw2 = [IO.File]::ReadAllText($svcJsonPath, [Text.Encoding]::UTF8)
                        $svcJson2 = ($svcRaw2 | ConvertFrom-Json)
                        $pw2 = [string](Get-JsonProp $svcJson2 'password' '')
                        if (-not [string]::IsNullOrWhiteSpace($pw2)) { $script:AuthEnv['OPENCODE_PASSWORD'] = $pw2 }
                        $pw2 = ''
                    } catch { }
                    if (-not $restartOk) {
                        Set-ScenarioResult 'RR-E2E-18' 'fail' 'restart real incompleto' $proofs $coverage
                    } else {
                        $postProbe = Probe-SessionExists -SessionId $childId -DeadlineSeconds 10
                        $observed = 'missing'
                        if ($postProbe.state -ceq 'present') { $observed = 'running' }
                        [void](Add-ScenarioProof $proofs 'child-observed-after-restart' (($postProbe.state -ne 'inconclusive')) ('child=' + $childId + ' observado=' + $observed))
                        $gb = Get-LaneTaskBindings -TaskId 'lane18'
                        $runs = @(Get-JsonProp (Get-JsonProp $gb.json 'bindings' $null) 'runs' @())
                        $obs = @(, @{ session_id = $childId; observed = $observed; last_seen = (Get-LaneTimestampUtc) })
                        $rec = Get-Reconciliation -Runs $runs -Observations $obs
                        $actionOk = $false
                        foreach ($act in @(Get-JsonProp $rec 'recommended_actions' @())) {
                            if (($observed -ceq 'running') -and ([string](Get-JsonProp $act 'action' '') -ceq 'reattach')) { $actionOk = $true }
                            if (($observed -ceq 'missing') -and ([string](Get-JsonProp $act 'action' '') -ceq 'mark_SESSION_LOST')) { $actionOk = $true }
                        }
                        [void](Add-ScenarioProof $proofs 'reconciler-child-action-correct' $actionOk ('observado=' + $observed))
                        $a1 = New-TaskAssertions -TaskId 'lane18'
                        [void](Add-ScenarioProof $proofs 'task-intact-after-restart' (([bool]$a1.ok) -and (-not [bool]$a1.terminal)) ('state=' + $a1.state))
                        # perna completed: tentativa BOUNDED via endpoint runtime-native
                        # /synthetic (o plano exige 'completed child recovered'; sem
                        # modelo, so o runtime pode produzir uma completacao real)
                        $synth = Invoke-Api -Method 'POST' -Path ('/api/session/' + $childId + '/synthetic') -Data '{}'
                        [void](Add-ScenarioProof $proofs 'synthetic-endpoint-attempt' $true ('POST /synthetic rc=' + [int]$synth.exit + ' (observacao; status nao convertido em saude)'))
                        $msg = Invoke-Api -Method 'GET' -Path ('/api/session/' + $childId + '/message')
                        $completionObservable = $false
                        $completionEvidence = ''
                        if ([bool]$msg.ok) {
                            $msgText = $msg.body
                            if (($msgText -match '"role"\s*:\s*"assistant"') -or ($msgText -match '"role"\s*:\s*"tool"')) {
                                $completionObservable = $true
                                $completionEvidence = 'mensagens de resposta presentes na sessao child (runtime-native)'
                            } else {
                                $completionEvidence = 'sem mensagens de resposta (sem modelo, o runtime nao produz turn completo)'
                            }
                        } else {
                            $completionEvidence = ('GET message indisponivel: exit=' + [int]$msg.exit)
                        }
                        if ($completionObservable) {
                            $obsC = @(, @{ session_id = $childId; observed = 'completed'; binding_session_id = $childId; last_seen = (Get-LaneTimestampUtc) })
                            $recC = Get-Reconciliation -Runs $runs -Observations $obsC
                            $recoverOk = $false
                            foreach ($act in @(Get-JsonProp $recC 'recommended_actions' @())) {
                                if ([string](Get-JsonProp $act 'action' '') -ceq 'recover-output') { $recoverOk = $true }
                            }
                            [void](Add-ScenarioProof $proofs 'completed-leg-recovered' $recoverOk ('acao=recover-output; ' + $completionEvidence))
                        } else {
                            $modelRecovered18 = $false
                            $modelDetail18 = ('BLOCKED sem modelo (' + (Get-LaneModelKeyLogToken) + '): ' + $completionEvidence)
                            if (Test-LaneModelKeyAvailable) {
                                $credImport18 = $false
                                $credWhy18 = ''
                                try { $credImport18 = Import-LaneSessionCredentialStore -TargetRoot $TargetHome -ReasonOut ([ref]$credWhy18) } catch { $credImport18 = $false }
                                [void](Add-ScenarioProof $proofs 'credstore-import' $true ('store do usuario -> perfil isolado (auth/account/kv/model/service): importado=' + [bool]$credImport18 + ' motivo=' + [string]$credWhy18 + '; sem import a perna model segue blocked'))
                                 try { [void](Write-LaneTrailEvent -Event 'MODEL_TURN_STARTED' -Fields @{ site = 'RR-E2E-18'; timeout_ms = 180000 }) } catch { }
                                 $turn18 = Invoke-LaneModelTurn -SessionId $childId -Prompt 'RECOVERY-lane18-child-completion-probe-respond-briefly' -Model ([string]$script:TurnModelClean) -TimeoutMs 180000 -NativeRequestFn (New-LaneNativeApiRequestFn)
                                 try { [void](Write-LaneTrailEvent -Event 'MODEL_TURN_FINISHED' -Fields @{ site = 'RR-E2E-18'; rc = [int]$turn18.exit; timedout = [bool]$turn18.timedout; job_assigned = [bool]$turn18.job_assigned; ok = [bool]$turn18.ok }) } catch { }
                                [void](Add-ScenarioProof $proofs 'model-turn-attempt' ([bool]$turn18.attempted) ('opencode run --session child --model (' + (Get-LaneModelKeyLogToken) + ') rc=' + [int]$turn18.exit + ' timedout=' + [bool]$turn18.timedout + ' job=' + [bool]$turn18.job_assigned))
                                if ([bool]$turn18.attempted) { [void]$proofs.Add([ordered]@{ proof = 'model-turn-stdout'; ok = $true; detail = ([string]$turn18.turn_output_safe) }) }
                                if ($null -ne $turn18.fallbackProof) { [void]$proofs.Add($turn18.fallbackProof) }
                                if ($null -ne $turn18.refusedProof) { [void]$proofs.Add($turn18.refusedProof) }
                                if ($null -ne $turn18.nativeProof) { [void]$proofs.Add($turn18.nativeProof) }
                                if ($null -ne $turn18.nativeTriggerProof) { [void]$proofs.Add($turn18.nativeTriggerProof) }
                                $hollow18 = (([bool]$turn18.ok) -and (-not [bool]$turn18.substantive))
                                if ([bool]$turn18.ok) {
                                    # Equivalencia stdout-OU-GET (documentada): o stdout do
                                    # proprio turno (--format json) carrega o mesmo event
                                    # stream do GET message; antes o veredito ficava refem
                                    # do servico (turno rc=0 + servico morto depois + GET
                                    # falho => blocked). Mesmos criterios nos dois lados;
                                    # GET consultado so quando o stdout nao contem.
                                    # Ausencia nos dois => blocked (sem afrouxamento).
                                    # stdout so vale sem nativa decidindo (gate abaixo):
                                    # stdout de CLI recusada nunca prova resposta.
                                    $stdSrc18 = ''
                                    if (-not [bool]$turn18.native) { $stdSrc18 = [string]$turn18.turn_stdout_safe }
                                    $stdEv18 = Test-LaneTurnEvidence -Text $stdSrc18
                                    $evSrc18 = ''
                                    if ([bool]$stdEv18.role) { $evSrc18 = 'stdout' }
                                    else {
                                        $msg18b = Invoke-Api -Method 'GET' -Path ('/api/session/' + $childId + '/message')
                                        if ([bool]$msg18b.ok) {
                                            $body18b = [string]$msg18b.body
                                            if ([bool](Test-LaneTurnEvidence -Text $body18b).role) { $evSrc18 = 'message' }
                                            elseif ([bool]$hollow18) { $modelDetail18 = ('hollow-ok (rc=0 sem marcadores no stdout, substantive=false) e GET message sem evidencia de resposta; perna segue blocked (' + (Get-LaneModelKeyLogToken) + ')') }
                                            else { $modelDetail18 = ('model-turn rc=0 mas sem mensagem de resposta observavel no stdout nem no GET message (' + (Get-LaneModelKeyLogToken) + ')') }
                                        } else {
                                            if ([bool]$hollow18) { $modelDetail18 = ('hollow-ok (rc=0 sem marcadores no stdout, substantive=false); stdout sem role e GET message indisponivel: exit=' + [int]$msg18b.exit + ' (' + (Get-LaneModelKeyLogToken) + '); perna segue blocked') }
                                            else { $modelDetail18 = ('model-turn rc=0, stdout sem role e GET message indisponivel: exit=' + [int]$msg18b.exit + ' (' + (Get-LaneModelKeyLogToken) + ')') }
                                        }
                                    }
                                    if ($evSrc18 -ne '') {
                                        $obsC2 = @(, @{ session_id = $childId; observed = 'completed'; binding_session_id = $childId; last_seen = (Get-LaneTimestampUtc) })
                                        $recC2 = Get-Reconciliation -Runs $runs -Observations $obsC2
                                        foreach ($act in @(Get-JsonProp $recC2 'recommended_actions' @())) {
                                            if ([string](Get-JsonProp $act 'action' '') -ceq 'recover-output') { $modelRecovered18 = $true }
                                        }
                                        $modelDetail18 = ('acao=recover-output via model-turn opt-in (' + (Get-LaneModelKeyLogToken) + '); completion observada via ' + $evSrc18)
                                    }
                                } else {
                                    $modelDetail18 = ('model-turn opt-in falhou: rc=' + [int]$turn18.exit + ' timedout=' + [bool]$turn18.timedout + ' (' + (Get-LaneModelKeyLogToken) + '); perna segue blocked')
                                    if ([bool]$turn18.attempted) { [void]$proofs.Add([ordered]@{ proof = 'model-turn-output'; ok = $true; detail = ([string]$turn18.output_excerpt) }) }
                                }
                            }
                            [void](Add-ScenarioProof $proofs 'completed-leg-recovered' $modelRecovered18 $modelDetail18)
                        }
                        [void]$coverage.Add('exercitado: child real (parentID) + restart real + reconciliacao com observacao real')
                        [void]$coverage.Add('perna completed-session: so observavel com turn de modelo; plano §10 (persistence) lista como perna distinta de "running child reattached" (exercitada aqui em runtime real)')
                        $allOk = $true
                        $completedLegOk = $false
                        foreach ($p in @($proofs)) {
                            if ([string]$p['proof'] -ceq 'completed-leg-recovered') { $completedLegOk = [bool]$p['ok']; continue }
                            if ([string]$p['proof'] -ceq 'model-turn-attempt') { continue }
                            if (-not [bool]$p['ok']) { $allOk = $false }
                        }
                        Set-ScenarioResult 'RR-E2E-18' $(if ($allOk -and $completedLegOk) { 'pass-real' } elseif ($allOk) { 'blocked' } else { 'fail' }) $(if ($allOk -and $completedLegOk) { 'child real reconciliado apos restart real, incluindo perna completed' } elseif ($allOk) { 'perna running runtime-real; perna completed bloqueada sem modelo (provas parciais gravadas; plano lista as duas pernas como testes distintos)' } else { 'provas com falha' }) $proofs $coverage
                    }
                }
            }
        } catch {
            Set-ScenarioResult 'RR-E2E-18' 'fail' ('excecao: ' + $_.Exception.Message) $proofs $coverage
        }
    }

    # garantir servico no ar para 19+
    $presCheck = Wait-LaneListener -DeadlineSeconds 5 -Mode 'presence'
    if (-not [bool]$presCheck.Seen) {
        # F2: captura do resultado do start (trilha apenas; sem gate).
        $pre19Start = (Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'start') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul -JobObject $svcJob)
        $presCheck = Wait-LaneListener -DeadlineSeconds 30 -Mode 'presence'
        try { [void](Write-LaneServiceCycleTrail -Site 'pre19-gate' -PidBefore 0 -StopResult $null -StartResult $pre19Start -Settle $null -Presence $presCheck) } catch { }
        if (-not [bool]$presCheck.Seen) {
            try { [void](Write-LaneTrailEvent -Event 'SERVICE_UNRESPONSIVE' -Fields @{ site = 'pre19-gate'; port = ([int]$script:Port) }) } catch { }
            Fail-Lane 'servico indisponivel antes do cenario 19.'
        }
        Add-LaneNote 'service re-iniciado antes do cenario 19'
    }

    # ==================================================================
    # RR-E2E-19: child ausente realmente identificado por probe
    # ==================================================================
    if ((@($ScenarioFilter).Count -eq 0) -or (@($ScenarioFilter) -ccontains '19')) {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $s = New-RealSession
            $t = New-LaneTask -TaskId 'lane19' -Objective 'RR-E2E-19: child ausente identificado por probe real (sem falso sucesso)'
            if ((-not [bool]$s.ok) -or (-not (Test-KernelOk $t))) {
                Set-ScenarioResult 'RR-E2E-19' 'blocked' ('pre-requisitos: sessao=' + [bool]$s.ok + ' task=' + (Test-KernelOk $t)) $proofs $coverage
            } else {
                $rootId = [string]$s.id
                $rev0 = [int](Get-JsonProp $t.json 'revision' -1)
                $null = (Invoke-KernelCli -KernelArgs @('-Action', 'transition', '-TaskId', 'lane19', '-ToState', 'PLANNING', '-Actor', 'session-lane', '-ExpectedRevision', "$rev0", '-TasksDir', $script:KernelTasksDir))
                $ch = New-RealSession -ParentId $rootId
                if (-not [bool]$ch.ok) {
                    Set-ScenarioResult 'RR-E2E-19' 'blocked' ('child real falhou: ' + $ch.reason) $proofs $coverage
                } else {
                    $childId = [string]$ch.id
                    $revB = [int](Get-JsonProp (Get-LaneTask -TaskId 'lane19').json 'revision' -1)
                    $bd19 = Invoke-KernelCli -KernelArgs @('-Action', 'bind-session', '-TaskId', 'lane19', '-RunId', 'lane19-child-run', '-SessionId', $childId, '-ExpectedRevision', "$revB", '-TasksDir', $script:KernelTasksDir, '-ParentSessionId', $rootId, '-RootSessionId', $rootId)
                    [void](Add-ScenarioProof $proofs 'child-created-and-bound' ((Test-KernelOk $bd19)) ('child=' + $childId + ' bind_exit=' + [int]$bd19.exit + ' err=' + $bd19.stderr))
                    $cl = Close-RealSession -SessionId $childId
                    if (-not [bool]$cl.ok) { Set-ScenarioResult 'RR-E2E-19' 'blocked' ('remocao real do child indisponivel: ' + $cl.reason) $proofs $coverage }
                    else {
                        # o contrato exige ausencia APOS um restart real: restart agora
                        # F2: snapshot do PID antes do stop (trilha apenas; sem gate).
                        $pidBefore19 = 0
                        try { $pidBefore19 = Get-LaneCurrentListenerPid } catch { $pidBefore19 = 0 }
                        $stp19 = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'stop') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
                        $settle19 = Wait-LaneListener -DeadlineSeconds 30 -Mode 'absence'
                        $sst19 = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'start') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul -JobObject $svcJob
                        $pres19 = Wait-LaneListener -DeadlineSeconds 30 -Mode 'presence'
                        $restart19Ok = (([int]$stp19.ExitCode -eq 0) -and ([bool]$settle19.Absent) -and ([int]$sst19.ExitCode -eq 0) -and ([bool]$sst19.JobAssigned) -and ([bool]$pres19.Seen))
                        [void](Add-ScenarioProof $proofs 'restart-real-before-absence' $restart19Ok ('stop+settlement+start+listener'))
                        # F2: trilha EXPECTED_TEST_RESTART do ponto 19 (advisory-only).
                        try { [void](Write-LaneServiceCycleTrail -Site 'RR-E2E-19' -PidBefore $pidBefore19 -StopResult $stp19 -StartResult $sst19 -Settle $settle19 -Presence $pres19) } catch { }
                        $restart19Ok = (([int]$stp19.ExitCode -eq 0) -and ([bool]$settle19.Absent) -and ([int]$sst19.ExitCode -eq 0) -and ([bool]$sst19.JobAssigned) -and ([bool]$pres19.Seen))
                        [void](Add-ScenarioProof $proofs 'restart-real-before-absence' $restart19Ok ('stop+settlement+start+listener'))
                        try {
                            $svcRaw19 = [IO.File]::ReadAllText($svcJsonPath, [Text.Encoding]::UTF8)
                            $svcJson19 = ($svcRaw19 | ConvertFrom-Json)
                            $pw19 = [string](Get-JsonProp $svcJson19 'password' '')
                            if (-not [string]::IsNullOrWhiteSpace($pw19)) { $script:AuthEnv['OPENCODE_PASSWORD'] = $pw19 }
                            $pw19 = ''
                        } catch { }
                        $postProbe = Probe-SessionExists -SessionId $childId -DeadlineSeconds 15
                        $absenceProven = ($postProbe.state -ceq 'absent')
                        [void](Add-ScenarioProof $proofs 'absence-proven-by-probe' $absenceProven ('probe=' + $postProbe.state + ' apos restart real (consulta conclusiva decide; falha e inconclusiva e NUNCA ausencia)'))
                        $listed = Test-SessionListed -SessionId $childId
                        if ([bool]$listed.decided) { [void](Add-ScenarioProof $proofs 'absent-from-session-list' (-not [bool]$listed.listed) ('listado=' + [bool]$listed.listed)) }
                        $gb = Get-LaneTaskBindings -TaskId 'lane19'
                        $runs = @(Get-JsonProp (Get-JsonProp $gb.json 'bindings' $null) 'runs' @())
                        $obs = @(, @{ session_id = $childId; observed = 'missing'; binding_session_id = $childId; last_seen = (Get-LaneTimestampUtc) })
                        $rec = Get-Reconciliation -Runs $runs -Observations $obs
                        $rowStatus = ''
                        $rowRequiresProof = $false
                        foreach ($rw in @(Get-JsonProp $rec 'runs' @())) {
                            if ([string](Get-JsonProp $rw 'session_id' '') -ceq $childId) { $rowStatus = [string](Get-JsonProp $rw 'status' '') }
                        }
                        foreach ($act in @(Get-JsonProp $rec 'recommended_actions' @())) {
                            if ([string](Get-JsonProp $act 'action' '') -ceq 'mark_SESSION_LOST') { $rowRequiresProof = [bool](Get-JsonProp $act 'requires_absence_proof' $false) }
                        }
                        [void](Add-ScenarioProof $proofs 'reconciler-classifies-missing' (($rowStatus -ceq 'missing')) ('status=' + $rowStatus))
                        [void](Add-ScenarioProof $proofs 'session-lost-requires-absence-proof' $rowRequiresProof ('requires_absence_proof=' + $rowRequiresProof))
                        $attempt = $null
                        if ($absenceProven) {
                            $bindingRow = @{ task_id = 'lane19'; run_id = 'lane19-child-run'; session_id = $childId }
                            $attempt = New-OrchestrationSessionLostAttemptResult -Binding $bindingRow -Observation ($obs[0]) -AbsenceProven $true -TimestampUtc (Get-LaneTimestampUtc)
                        }
                        $lostOk = ($null -ne $attempt -and ([string](Get-JsonProp $attempt 'status' '') -ceq 'SESSION_LOST') -and ([bool](Get-JsonProp $attempt 'task_state_mutated' $true) -eq $false))
                        [void](Add-ScenarioProof $proofs 'session-lost-attempt-shaped' $lostOk ('status=' + $(if ($null -ne $attempt) { [string](Get-JsonProp $attempt 'status' '') } else { 'nao-gerado' }) + ' task_state_mutated=false'))
                        # controle negativo: ausencia DESCONHECIDA nunca gera SESSION_LOST
                        $neg = New-OrchestrationSessionLostAttemptResult -Binding @{ task_id = 'lane19'; run_id = 'lane19-child-run'; session_id = $childId } -Observation ($obs[0]) -AbsenceProven $false -TimestampUtc (Get-LaneTimestampUtc)
                        [void](Add-ScenarioProof $proofs 'unknown-absence-never-success' (([string](Get-JsonProp $neg 'error' '') -ceq 'SESSION_LOST_NOT_PROVEN')) ('error=' + [string](Get-JsonProp $neg 'error' '')))
                        $a1 = New-TaskAssertions -TaskId 'lane19'
                        [void](Add-ScenarioProof $proofs 'task-not-falsely-completed' (([bool]$a1.ok) -and (-not [bool]$a1.terminal)) ('state=' + $a1.state))
                        [void]$coverage.Add('ausencia PROVADA por probe conclusivo + classificacao missing + SESSION_LOST com prova')
                        $allOk = $true
                        foreach ($p in @($proofs)) { if (-not [bool]$p['ok']) { $allOk = $false; break } }
                        Set-ScenarioResult 'RR-E2E-19' $(if ($allOk) { 'pass-real' } else { 'fail' }) $(if ($allOk) { 'ausencia real provada; nenhuma ausencia desconhecida vira sucesso' } else { 'provas com falha' }) $proofs $coverage
                    }
                }
            }
        } catch {
            Set-ScenarioResult 'RR-E2E-19' 'fail' ('excecao: ' + $_.Exception.Message) $proofs $coverage
        }
    }

    # ==================================================================
    # RR-E2E-20: envelope consumido por Planner substituto real
    # ==================================================================
    if ((@($ScenarioFilter).Count -eq 0) -or (@($ScenarioFilter) -ccontains '20')) {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $s = New-RealSession
            $t = New-LaneTask -TaskId 'lane20' -Objective 'RR-E2E-20: envelope de continuacao consumido por Planner substituto real'
            if ((-not [bool]$s.ok) -or (-not (Test-KernelOk $t))) {
                Set-ScenarioResult 'RR-E2E-20' 'blocked' ('pre-requisitos: sessao=' + [bool]$s.ok + ' task=' + (Test-KernelOk $t)) $proofs $coverage
            } else {
                $sid = [string]$s.id
                $rev0 = [int](Get-JsonProp $t.json 'revision' -1)
                $tr = Invoke-KernelCli -KernelArgs @('-Action', 'transition', '-TaskId', 'lane20', '-ToState', 'PLANNING', '-Actor', 'session-lane', '-ExpectedRevision', "$rev0", '-TasksDir', $script:KernelTasksDir, '-Reason', 'lane-20-active')
                $bd = Invoke-KernelCli -KernelArgs @('-Action', 'bind-session', '-TaskId', 'lane20', '-RunId', 'lane20-run', '-SessionId', $sid, '-ExpectedRevision', ([string](Get-JsonProp $tr.json 'revision' '0')), '-TasksDir', $script:KernelTasksDir, '-RootSessionId', $sid)
                if ((-not (Test-KernelOk $bd))) {
                    Set-ScenarioResult 'RR-E2E-20' 'fail' ('bind falhou: ' + $bd.stderr) $proofs $coverage
                } else {
                    $cl = Close-RealSession -SessionId $sid
                    if (-not [bool]$cl.ok) { Set-ScenarioResult 'RR-E2E-20' 'blocked' ('fechamento da sessao antiga indisponivel: ' + $cl.reason) $proofs $coverage }
                    else {
                        $postProbe = Probe-SessionExists -SessionId $sid -DeadlineSeconds 15
                        [void](Add-ScenarioProof $proofs 'old-session-closed-proven' (($postProbe.state -ceq 'absent')) ('probe=' + $postProbe.state))
                        # envelope a partir do estado REAL persistido
                        $rec = (Get-LaneTask -TaskId 'lane20').json
                        $decisions = @()
                        foreach ($ac in @(Get-JsonProp $rec 'acceptance_criteria' @())) { $decisions += , [string]$ac }
                        $envelope = New-OrchestrationContinuationEnvelope -TaskId 'lane20' `
                            -Objective ([string](Get-JsonProp $rec 'objective' '')) `
                            -UserIntent 'lane closure RR-E2E-20' `
                            -Decisions $decisions `
                            -NextMove ('resume at state ' + [string](Get-JsonProp $rec 'state' '')) `
                            -TimestampUtc (Get-LaneTimestampUtc)
                        $envOk = ($null -ne $envelope -and [string](Get-JsonProp $envelope 'task_id' '') -ceq 'lane20')
                        [void](Add-ScenarioProof $proofs 'envelope-from-real-state' $envOk ('task_id=' + $(if ($null -ne $envelope) { [string](Get-JsonProp $envelope 'task_id' '') } else { 'null' })))
                        $envPath = Join-Path $script:EnvelopeDir 'lane20-envelope.json'
                        $envWritten = $false
                        if ($envOk) { $envWritten = Write-LaneJson $envelope $envPath }
                        [void](Add-ScenarioProof $proofs 'envelope-persisted' $envWritten ('path dentro do TargetHome isolado'))
                        # sessao substituta REAL
                        $srepl = New-RealSession
                        [void](Add-ScenarioProof $proofs 'replacement-session-real' ([bool]$srepl.ok) ('id=' + [string]$srepl.id))
                        # plano §10: "If supported, inject a compact recovered event/result
                        # into the new Planner session; otherwise supply on next Planner
                        # turn" - tentativa bounded de injecao runtime-native (texto compacto)
                        $injectionSupported = $false
                        $recvHow20 = 'unproven'
                        if ([bool]$srepl.ok) {
                            $inj = Invoke-Api -Method 'POST' -Path ('/api/session/' + [string]$srepl.id + '/synthetic') -Data '{"text":"RECOVERY lane20: task=lane20 state=PLANNING next=resume via envelope lane20-envelope.json"}'
                            [void](Add-ScenarioProof $proofs 'envelope-injection-attempt' $true ('POST /synthetic rc=' + [int]$inj.exit + ' (observacao; plano §10 permite fallback "supply on next Planner turn")'))
                            if ([bool]$inj.ok) {
                                $msgRepl = Invoke-Api -Method 'GET' -Path ('/api/session/' + [string]$srepl.id + '/message')
                                if ([bool]$msgRepl.ok -and ($msgRepl.body -match 'RECOVERY lane20')) {
                                    $injectionSupported = $true
                                    $recvHow20 = 'synthetic-echo'
                                }
                            }
                            if ((-not $injectionSupported) -and (Test-LaneModelKeyAvailable)) {
                                # BOTREV-01/B1: snapshot pre-turn + canario exclusivo da
                                # execucao (id da sessao substituta). So conta mensagem
                                # NOVA com papel de resposta: canario ausente antes e
                                # presente depois, com role assistant/tool depois. Eco
                                # tardio da injecao /synthetic ou do proprio prompt nao
                                # conta (fail-closed => blocked, nunca pass forjado).
                                $preTurn20 = Invoke-Api -Method 'GET' -Path ('/api/session/' + [string]$srepl.id + '/message')
                                $preBody20 = $(if ([bool]$preTurn20.ok) { [string]$preTurn20.body } else { '' })
                                $canary20 = ('lane20-' + [string]$srepl.id)
                                $canaryEsc20 = [regex]::Escape($canary20)
                                $credImport20 = $false
                                $credWhy20 = ''
                                try { $credImport20 = Import-LaneSessionCredentialStore -TargetRoot $TargetHome -ReasonOut ([ref]$credWhy20) } catch { $credImport20 = $false }
                                [void](Add-ScenarioProof $proofs 'credstore-import' $true ('store do usuario -> perfil isolado (auth/account/kv/model/service): importado=' + [bool]$credImport20 + ' motivo=' + [string]$credWhy20 + '; sem import a perna model segue blocked'))
                                 try { [void](Write-LaneTrailEvent -Event 'MODEL_TURN_STARTED' -Fields @{ site = 'RR-E2E-20'; timeout_ms = 180000 }) } catch { }
                                 $turn20 = Invoke-LaneModelTurn -SessionId ([string]$srepl.id) -Prompt ('RECOVERY-' + $canary20 + '-resume-via-envelope-lane20-envelope-json') -Model ([string]$script:TurnModelClean) -TimeoutMs 180000 -NativeRequestFn (New-LaneNativeApiRequestFn)
                                 try { [void](Write-LaneTrailEvent -Event 'MODEL_TURN_FINISHED' -Fields @{ site = 'RR-E2E-20'; rc = [int]$turn20.exit; timedout = [bool]$turn20.timedout; job_assigned = [bool]$turn20.job_assigned; ok = [bool]$turn20.ok }) } catch { }
                                [void](Add-ScenarioProof $proofs 'model-turn-attempt' ([bool]$turn20.attempted) ('opencode run --session substituta --model (' + (Get-LaneModelKeyLogToken) + ') rc=' + [int]$turn20.exit + ' timedout=' + [bool]$turn20.timedout + ' job=' + [bool]$turn20.job_assigned))
                                if ([bool]$turn20.attempted) { [void]$proofs.Add([ordered]@{ proof = 'model-turn-stdout'; ok = $true; detail = ([string]$turn20.turn_output_safe) }) }
                                if (([bool]$turn20.attempted) -and (-not [bool]$turn20.ok)) { [void]$proofs.Add([ordered]@{ proof = 'model-turn-output'; ok = $true; detail = ([string]$turn20.output_excerpt) }) }
                                if ($null -ne $turn20.fallbackProof) { [void]$proofs.Add($turn20.fallbackProof) }
                                if ($null -ne $turn20.refusedProof) { [void]$proofs.Add($turn20.refusedProof) }
                                if ($null -ne $turn20.nativeProof) { [void]$proofs.Add($turn20.nativeProof) }
                                if ([bool]$turn20.ok) {
                                    $msgRepl2 = Invoke-Api -Method 'GET' -Path ('/api/session/' + [string]$srepl.id + '/message')
                                    $postBody20 = $(if ([bool]$msgRepl2.ok) { [string]$msgRepl2.body } else { '' })
                                    $canaryNew20 = (([bool]$msgRepl2.ok) -and (($preBody20 -notmatch $canaryEsc20) -and ($postBody20 -match $canaryEsc20)))
                                    $rolePost20 = (([bool]$msgRepl2.ok) -and (($postBody20 -match '"role"\s*:\s*"assistant"') -or ($postBody20 -match '"role"\s*:\s*"tool"')))
                                    if ($canaryNew20 -and $rolePost20) {
                                        $injectionSupported = $true
                                        $recvHow20 = 'model-turn-novel(canary_new+role_post)'
                                    }
                                    [void](Add-ScenarioProof $proofs 'turn-novelty-detail' $true ('canary_new=' + $canaryNew20 + ' role_post=' + $rolePost20 + ' job=' + [bool]$turn20.job_assigned))
                                }
                            }
                        }
                        # REV2 (fail-closed): a prova segue a realidade - ok apenas
                        # quando a injecao nativa foi confirmada na sessao
                        # substituta; sem injecao, o consumo PELO Planner
                        # substituto (turn) depende de provider de modelo
                        [void](Add-ScenarioProof $proofs 'envelope-received-by-replacement' $injectionSupported ('injecao_runtime_native=' + $injectionSupported + ' how=' + $recvHow20 + $(if (-not $injectionSupported) { '; consumo pelo Planner substituto (turn) exige provider de modelo - perna nao provada aqui' } else { '' })))
                        # consumo por processo FRESCO: powershell novo le o envelope persistido e constroi o plano
                        # (script gravado em arquivo: o guard StdinNul recusa -Command com shell-meta)
                        $consumePath = Join-Path $script:EnvelopeDir 'consume-lane20.ps1'
                        $consumeText = ". '" + (Join-Path $v3LibDir 'OrchestrationSessionReconciler.ps1') + "'`n" + `
                            "`$e = ConvertFrom-Json ([IO.File]::ReadAllText('" + $envPath + "'))`n" + `
                            "`$p = New-OrchestrationContinuationPlan -Envelope `$e -Runtime '2' -EnvelopeRef 'lane20-envelope.json'`n" + `
                            "`$p | ConvertTo-Json -Depth 6`n"
                        [IO.File]::WriteAllText($consumePath, $consumeText, (New-Object Text.UTF8Encoding $false))
                        $cr = Invoke-SpikeChild -FilePath $script:WindowsPowerShellExe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $consumePath) -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 60000 -CleanEnvironment -StdinNul
                        $plan = $null
                        try { $plan = ConvertFrom-Json ([string]$cr.Stdout) } catch { $plan = $null }
                        $consumeOk = ((-not [bool]$cr.TimedOut) -and ([int]$cr.ExitCode -eq 0) -and ($null -ne $plan) -and ([string](Get-JsonProp $plan 'task_id' '') -ceq 'lane20'))
                        [void](Add-ScenarioProof $proofs 'envelope-consumed-by-fresh-process' $consumeOk ('mode=' + $(if ($null -ne $plan) { [string](Get-JsonProp $plan 'mode' '') } else { 'null' }) + ' task_id=' + $(if ($null -ne $plan) { [string](Get-JsonProp $plan 'task_id' '') } else { 'null' })))
                        # retomada: rebind da run para a sessao substituta
                        if ([bool]$srepl.ok) {
                            $revD = [int](Get-JsonProp (Get-LaneTask -TaskId 'lane20').json 'revision' -1)
                            $dt = Invoke-KernelCli -KernelArgs @('-Action', 'detach-session', '-TaskId', 'lane20', '-SessionId', $sid, '-ExpectedRevision', "$revD", '-TasksDir', $script:KernelTasksDir)
                            $revE = [int](Get-JsonProp (Get-LaneTask -TaskId 'lane20').json 'revision' -1)
                            $rb = Invoke-KernelCli -KernelArgs @('-Action', 'rebind-session', '-TaskId', 'lane20', '-RunId', 'lane20-run', '-SessionId', [string]$srepl.id, '-ExpectedRevision', "$revE", '-TasksDir', $script:KernelTasksDir)
                            [void](Add-ScenarioProof $proofs 'retomada-rebind-replacement' ((Test-KernelOk $dt) -and (Test-KernelOk $rb)) ('root=' + [string]$srepl.id))
                            $gb = Get-LaneTaskBindings -TaskId 'lane20'
                            $rootNow = ''
                            foreach ($rr in @(Get-JsonProp (Get-JsonProp $gb.json 'bindings' $null) 'runs' @())) {
                                if ([string](Get-JsonProp $rr 'run_id' '') -ceq 'lane20-run') { $rootNow = [string](Get-JsonProp $rr 'root_session' '') }
                            }
                            [void](Add-ScenarioProof $proofs 'retomada-binding-correct' ($rootNow -ceq [string]$srepl.id) ('root_now=' + $rootNow))
                            $a1 = New-TaskAssertions -TaskId 'lane20'
                            [void](Add-ScenarioProof $proofs 'retomada-state-correct' (([bool]$a1.ok) -and ($a1.state -ceq 'PLANNING') -and (-not [bool]$a1.terminal)) ('state=' + $a1.state))
                        }
                        [void]$coverage.Add('cadeia: sessao antiga -> estado persistido -> envelope -> processo fresco consome -> sessao substituta real retoma')
                        # REV2: a perna "replacement Planner session consuming the
                        # envelope" (required_activation) so vale com injecao nativa
                        # confirmada; sem ela o cenario e blocked-parcial (as pernas
                        # kernel-side permanecem provadas), nunca pass-real
                        $hardFail20 = $false
                        foreach ($p in @($proofs)) { if (([string]$p['proof'] -cne 'envelope-received-by-replacement') -and ([string]$p['proof'] -cne 'model-turn-attempt') -and (-not [bool]$p['ok'])) { $hardFail20 = $true; break } }
                        Set-ScenarioResult 'RR-E2E-20' `
                            $(if ($hardFail20) { 'fail' } elseif ($injectionSupported) { 'pass-real' } else { 'blocked' }) `
                            $(if ($hardFail20) { 'provas com falha' } elseif ($injectionSupported) { 'envelope recebido pelo Planner substituto em runtime (injecao nativa confirmada)' } else { 'parcial provado: envelope do estado real persistido + consumo kernel-side por processo fresco + substituicao real com rebind; consumo PELO Planner substituto (turn) exige provider de modelo - required_activation integral nao exercitado aqui' }) `
                            $proofs $coverage
                    }
                }
            }
        } catch {
            Set-ScenarioResult 'RR-E2E-20' 'fail' ('excecao: ' + $_.Exception.Message) $proofs $coverage
        }
    }

    # ==================================================================
    # RR-E2E-21: estado da task preservado atraves da substituicao
    # ==================================================================
    if ((@($ScenarioFilter).Count -eq 0) -or (@($ScenarioFilter) -ccontains '21')) {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $s = New-RealSession
            # Desafio fresco por execucao persistido no ARQUIVO da task
            # (objective; campo apropriado ja existente, sem schema novo):
            # token aleatorio de teste (NAO segredo de usuario), nunca
            # revelado no prompt. So a leitura real do arquivo pelo
            # substituto produz o desafio na resposta (anti-eco).
            $challenge21 = ('CHAL21-' + ([guid]::NewGuid().ToString('N').Substring(0, 12).ToUpperInvariant()))
            $t = New-LaneTask -TaskId 'lane21' -Objective ('RR-E2E-21: estado da task preservado na substituicao de sessao ' + $challenge21)
            if ((-not [bool]$s.ok) -or (-not (Test-KernelOk $t))) {
                Set-ScenarioResult 'RR-E2E-21' 'blocked' ('pre-requisitos: sessao=' + [bool]$s.ok + ' task=' + (Test-KernelOk $t)) $proofs $coverage
            } else {
                $sid = [string]$s.id
                $rev0 = [int](Get-JsonProp $t.json 'revision' -1)
                $tr = Invoke-KernelCli -KernelArgs @('-Action', 'transition', '-TaskId', 'lane21', '-ToState', 'PLANNING', '-Actor', 'session-lane', '-ExpectedRevision', "$rev0", '-TasksDir', $script:KernelTasksDir)
                $rev1 = [int](Get-JsonProp $tr.json 'revision' '0')
                $bd = Invoke-KernelCli -KernelArgs @('-Action', 'bind-session', '-TaskId', 'lane21', '-RunId', 'lane21-run', '-SessionId', $sid, '-ExpectedRevision', "$rev1", '-TasksDir', $script:KernelTasksDir, '-RootSessionId', $sid)
                $rev2 = [int](Get-JsonProp (Get-LaneTask -TaskId 'lane21').json 'revision' -1)
                # start-attempt e planner/build-only; REV2: o invariante
                # BUDGET_WIDEN_DENIED e provado KERNEL-SIDE nos testes do kernel
                # (a lane nao invoca start-attempt e nao o exercita em runtime);
                # a lane registra resultado de worker (permitido) e prova a historia
                $revR = [int](Get-JsonProp (Get-LaneTask -TaskId 'lane21').json 'revision' -1)
                $rr = Invoke-KernelCli -KernelArgs @('-Action', 'record-result', '-TaskId', 'lane21', '-WorkerStatus', 'candidate_pass', '-ProducedBy', 'session-lane-coder', '-ExpectedRevision', "$revR", '-ClaimedEvidence', 'lane21/proof', '-TasksDir', $script:KernelTasksDir)
                $recordOk = (Test-KernelOk $rr)
                [void](Add-ScenarioProof $proofs 'task-has-worker-result' ($recordOk) ('candidate_pass=' + $recordOk + ' exit=' + [int]$rr.exit))
                $pre = (Get-LaneTask -TaskId 'lane21').json
                $preState = [string](Get-JsonProp $pre 'state' '')
                $preObjective = [string](Get-JsonProp $pre 'objective' '')
                $preResults = @(Get-JsonProp $pre 'worker_result' $null)
                $preAttempts = @(Get-JsonProp $pre 'attempts' @())
                $s2 = New-RealSession
                if ((-not [bool]$s2.ok) -or (-not (Test-KernelOk $bd))) {
                    Set-ScenarioResult 'RR-E2E-21' 'fail' ('substituicao indisponivel: nova_sessao=' + [bool]$s2.ok) $proofs $coverage
                } else {
                    $rev3 = [int](Get-JsonProp (Get-LaneTask -TaskId 'lane21').json 'revision' -1)
                    $dt = Invoke-KernelCli -KernelArgs @('-Action', 'detach-session', '-TaskId', 'lane21', '-SessionId', $sid, '-ExpectedRevision', "$rev3", '-TasksDir', $script:KernelTasksDir)
                    $rev4 = [int](Get-JsonProp (Get-LaneTask -TaskId 'lane21').json 'revision' -1)
                    $rb = Invoke-KernelCli -KernelArgs @('-Action', 'rebind-session', '-TaskId', 'lane21', '-RunId', 'lane21-run', '-SessionId', [string]$s2.id, '-ExpectedRevision', "$rev4", '-TasksDir', $script:KernelTasksDir)
                    $substOk = ((Test-KernelOk $dt) -and (Test-KernelOk $rb))
                    [void](Add-ScenarioProof $proofs 'session-replacement-real' $substOk ('old=' + $sid + ' new=' + [string]$s2.id))
                    # estado re-lido do disco pela lane (kernel-side); a releitura
                    # PELO substituto (turn do Planner) exige provider de modelo
                    # e nao e exercitada nesta lane (ver required_activation)
                    $post = (Get-LaneTask -TaskId 'lane21').json
                    $postState = [string](Get-JsonProp $post 'state' '')
                    $postObjective = [string](Get-JsonProp $post 'objective' '')
                    $postResults = @(Get-JsonProp $post 'worker_result' $null)
                    $postAttempts = @(Get-JsonProp $post 'attempts' @())
                    $preHasResult = ($null -ne (Get-JsonProp $pre 'worker_result' $null))
                    $postHasResult = ($null -ne (Get-JsonProp $post 'worker_result' $null))
                    [void](Add-ScenarioProof $proofs 'state-preserved' (($postState -ceq $preState) -and ($postObjective -ceq $preObjective)) ('state=' + $preState + '->' + $postState))
                    [void](Add-ScenarioProof $proofs 'history-preserved' (($preHasResult -eq $postHasResult) -and ($postHasResult) -and (@($postAttempts).Count -ge @($preAttempts).Count) -and (@($postAttempts).Count -gt 0)) ('worker_result_preservado=' + $postHasResult + ' attempts=' + @($postAttempts).Count))
                    $a1 = New-TaskAssertions -TaskId 'lane21'
                    [void](Add-ScenarioProof $proofs 'no-false-terminal' (-not [bool]$a1.terminal) ('state=' + $a1.state))
                    [void]$coverage.Add('substituicao real: estado re-lido do disco pela lane (kernel-side) preservado (state/objective/history) sem mutacao indevida; a releitura PELO substituto (turn do Planner) usa o opt-in -ModelKeyEnvName quando disponivel')
                    # REV2 (fail-closed): o required_activation pede re-leitura PELO
                    # substituto; sem model-key opt-in a lane prova kernel-side e o
                    # cenario e blocked-parcial; com opt-in, um turn 'opencode run'
                    # bounded e tentado na sessao substituta e o pass-real exige
                    # resposta observavel do substituto (nunca forjado)
                    $substituteTurnOk21 = $false
                    if (Test-LaneModelKeyAvailable) {
                        # Desafio persistido (reviewer+sec): o prompt NAO revela canario
                        # nem estado; o substituto so produz desafio+estado lendo
                        # de fato o arquivo da task. Eco do prompt nao contem o
                        # desafio (fail-closed); expectativa independente abaixo.
                        $credImport21 = $false
                        $credWhy21 = ''
                        try { $credImport21 = Import-LaneSessionCredentialStore -TargetRoot $TargetHome -ReasonOut ([ref]$credWhy21) } catch { $credImport21 = $false }
                        [void](Add-ScenarioProof $proofs 'credstore-import' $true ('store do usuario -> perfil isolado (auth/account/kv/model/service): importado=' + [bool]$credImport21 + ' motivo=' + [string]$credWhy21 + '; sem import a perna model segue blocked'))
                        # Prompt: so caminho relativo explicito do task file +
                        # instrucao de reportar objective/state/history (sem
                        # desafio, sem estado; curto e sem shell-meta).
                         try { [void](Write-LaneTrailEvent -Event 'MODEL_TURN_STARTED' -Fields @{ site = 'RR-E2E-21'; timeout_ms = 180000 }) } catch { }
                         $turn21 = Invoke-LaneModelTurn -SessionId ([string]$s2.id) -Prompt 'RECOVERY-read-file-../kernel-tasks/lane21.json-report-objective-state-history-brief-direct-answer-no-delegation' -Model ([string]$script:TurnModelClean) -TimeoutMs 180000 -NativeRequestFn (New-LaneNativeApiRequestFn)
                         try { [void](Write-LaneTrailEvent -Event 'MODEL_TURN_FINISHED' -Fields @{ site = 'RR-E2E-21'; rc = [int]$turn21.exit; timedout = [bool]$turn21.timedout; job_assigned = [bool]$turn21.job_assigned; ok = [bool]$turn21.ok }) } catch { }
                        [void](Add-ScenarioProof $proofs 'model-turn-attempt' ([bool]$turn21.attempted) ('opencode run --session substituta --model (' + (Get-LaneModelKeyLogToken) + ') rc=' + [int]$turn21.exit + ' timedout=' + [bool]$turn21.timedout + ' job=' + [bool]$turn21.job_assigned))
                        if ([bool]$turn21.attempted) { [void]$proofs.Add([ordered]@{ proof = 'model-turn-stdout'; ok = $true; detail = ([string]$turn21.turn_output_safe) }) }
                        if (([bool]$turn21.attempted) -and (-not [bool]$turn21.ok)) { [void]$proofs.Add([ordered]@{ proof = 'model-turn-output'; ok = $true; detail = ([string]$turn21.output_excerpt) }) }
                        if ($null -ne $turn21.fallbackProof) { [void]$proofs.Add($turn21.fallbackProof) }
                        if ($null -ne $turn21.refusedProof) { [void]$proofs.Add($turn21.refusedProof) }
                        if ($null -ne $turn21.nativeProof) { [void]$proofs.Add($turn21.nativeProof) }
                        if ($null -ne $turn21.nativeTriggerProof) { [void]$proofs.Add($turn21.nativeTriggerProof) }
                        $hollow21 = (([bool]$turn21.ok) -and (-not [bool]$turn21.substantive))
                        if ([bool]$turn21.ok) {
                            # Equivalencia stdout-OU-GET (idem 18): mesmos criterios
                            # estruturais (unidade assistant|tool com desafio do
                            # arquivo + state token na MESMA unidade) no stdout
                            # OU no GET (fallback). Ausencia nos dois =>
                            # blocked. O desafio nunca esteve no prompt, entao
                            # eco/narrativa sem leitura nao passa.
                            # stdout so vale sem nativa decidindo (gate abaixo).
                            $stdSrc21 = ''
                            if (-not [bool]$turn21.native) { $stdSrc21 = [string]$turn21.turn_stdout_safe }
                            $stdEv21 = Test-LaneTurnEvidence -Text $stdSrc21 -CanaryToken $challenge21 -StateToken $preState
                            $stdRead21 = (([bool]$stdEv21.role) -and ([bool]$stdEv21.canary) -and ([bool]$stdEv21.state))
                            $msgRead21 = $false
                            if (-not $stdRead21) {
                                # GET filtrado por type=assistant: o eco do proprio
                                # prompt (mensagem user) NAO entra no corpo; mesmo
                                # com filtro, o gate estrutural exige desafio+state
                                # na mesma unidade assistant (eco sem leitura nao
                                # contem o desafio). Mesma forma do contrato da
                                # perna nativa.
                                $msg21 = Invoke-Api -Method 'GET' -Path ('/api/session/' + [string]$s2.id + '/message?type=assistant')
                                $body21 = [string]$msg21.body
                                $msgEv21 = Test-LaneTurnEvidence -Text $body21 -CanaryToken $challenge21 -StateToken $preState
                                $msgRead21 = (([bool]$msg21.ok) -and ([bool]$msgEv21.role) -and ([bool]$msgEv21.canary) -and ([bool]$msgEv21.state))
                            }
                            $substituteTurnOk21 = (([bool]$stdRead21) -or ([bool]$msgRead21))
                            $evSrc21 = 'nenhuma'
                            if (([bool]$stdRead21) -and ([bool]$msgRead21)) { $evSrc21 = 'stdout+message' }
                            elseif ([bool]$stdRead21) { $evSrc21 = 'stdout' }
                            elseif ([bool]$msgRead21) { $evSrc21 = 'message' }
                            $rereadDetail21 = ('resposta do substituto observada=' + $substituteTurnOk21 + ' fonte=' + $evSrc21 + ' job=' + [bool]$turn21.job_assigned + ' (' + (Get-LaneModelKeyLogToken) + ')')
                            if (([bool]$hollow21) -and (-not [bool]$substituteTurnOk21)) { $rereadDetail21 = ('hollow-ok (rc=0 sem marcadores no stdout, substantive=false) + GET sem evidencia; perna segue blocked; ' + $rereadDetail21) }
                            [void](Add-ScenarioProof $proofs 'substitute-reread-turn' $substituteTurnOk21 $rereadDetail21)
                        } else {
                            [void](Add-ScenarioProof $proofs 'substitute-reread-turn' $false ('model-turn falhou: rc=' + [int]$turn21.exit + ' timedout=' + [bool]$turn21.timedout + ' job=' + [bool]$turn21.job_assigned))
                        }
                    }
                    $hardFail21 = $false
                    foreach ($p in @($proofs)) {
                        $pn21 = [string]$p['proof']
                        if (($pn21 -ceq 'model-turn-attempt') -or ($pn21 -ceq 'substitute-reread-turn')) { continue }
                        if (-not [bool]$p['ok']) { $hardFail21 = $true; break }
                    }
                    Set-ScenarioResult 'RR-E2E-21' $(if ($hardFail21) { 'fail' } elseif ($substituteTurnOk21) { 'pass-real' } else { 'blocked' }) $(if ($hardFail21) { 'provas com falha' } elseif ($substituteTurnOk21) { 'substituicao real + estado preservado + releitura observavel PELO substituto via model-turn opt-in (runtime real)' } else { 'parcial provado: substituicao de sessao real (detach+rebind) + estado/historico preservados e re-lidos kernel-side; releitura pelo proprio substituto (turn) exige provider de modelo via -ModelKeyEnvName - required_activation integral nao exercitado sem o opt-in' }) $proofs $coverage
                }
            }
        } catch {
            Set-ScenarioResult 'RR-E2E-21' 'fail' ('excecao: ' + $_.Exception.Message) $proofs $coverage
        }
    }

    # ==================================================================
    # RR-E2E-22: V1 real - fresh-session fallback sem resume nativo
    # ==================================================================
    if ((@($ScenarioFilter).Count -eq 0) -or (@($ScenarioFilter) -ccontains '22')) {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $v1pin = $null
            $wantV1 = ''
            try { $v1pin = Get-OrchestrationRuntimeVersion -Name 'v1' -RepoRoot $RepoRoot } catch { $v1pin = $null }
            if ($null -eq $v1pin -or [string]::IsNullOrWhiteSpace([string]$v1pin.version)) {
                [void](Add-ScenarioProof $proofs 'v1-pin-resolved' $false 'registry runtime-versions.json nao resolveu o pin v1 (fail-closed)')
                Set-ScenarioResult 'RR-E2E-22' 'blocked' 'pin V1 irresolvivel (registry ausente/invalido); nada e executado' $proofs $coverage
            } else {
                $wantV1 = [string]$v1pin.version
            }
            if ((-not [string]::IsNullOrWhiteSpace($wantV1)) -and (-not [string]::IsNullOrWhiteSpace($V1NpmSpec)) -and ($V1NpmSpec -notmatch '^[A-Za-z0-9@/._-]+$')) {
                [void](Add-ScenarioProof $proofs 'v1-spec-charset' $false '-V1NpmSpec fora do charset permitido (recusado sem executar)')
                Set-ScenarioResult 'RR-E2E-22' 'blocked' '-V1NpmSpec invalido (charset permitido: A-Za-z0-9@/._-)' $proofs $coverage
                $wantV1 = ''
            }
            if (-not [string]::IsNullOrWhiteSpace($wantV1)) {
                $v1exe = ''
                # REV2: deadline nominal do cenario (param ScenarioTimeoutSeconds)
                # limita as operacoes pesadas desta secao: cada chamada recebe
                # no maximo o tempo RESTANTE da janela (piso 5s; fail-closed)
                $v1DeadlineUtc = [DateTime]::UtcNow.AddSeconds([Math]::Max(60, $ScenarioTimeoutSeconds))
            $v1cands = New-Object System.Collections.ArrayList
            if (-not [string]::IsNullOrWhiteSpace($V1BinaryPath)) {
                if (Test-Path -LiteralPath $V1BinaryPath -PathType Leaf) { [void]$v1cands.Add($V1BinaryPath) }
            }
            foreach ($c in @(Get-Command -Name 'opencode-ai' -All -ErrorAction SilentlyContinue)) {
                $src = ''
                try { $src = [string]$c.Source } catch { $src = '' }
                if (-not [string]::IsNullOrWhiteSpace($src) -and (Test-Path -LiteralPath $src)) { [void]$v1cands.Add($src) }
            }
            $npmPrefix = ''
            try {
                if ([string]::IsNullOrWhiteSpace($script:NodeExe)) { throw 'npm-indisponivel' }
                $np = Invoke-PreflightBoundedExe -File $script:NodeExe -ArgsLine ('"' + $script:NpmCliJs + '" prefix -g') -WorkDir $script:CwdT -EnvTable $script:IsoEnv -EnvRemove ($script:IsoRemove + $script:SensitiveEnvRemove) -TimeoutMs 20000 -MaxChars 2000
                if (([bool]$np.Finished) -and ([int]$np.ExitCode -eq 0)) { $npmPrefix = ((([string]$np.Output).Trim()) -split "`r?`n" | Select-Object -First 1) }
            } catch { $npmPrefix = '' }
            if (-not [string]::IsNullOrWhiteSpace($npmPrefix)) {
                foreach ($rel in @('node_modules\opencode-ai\bin\opencode.exe', 'node_modules\opencode-ai\bin\opencode', 'opencode-ai.cmd')) {
                    $p = Join-Path $npmPrefix $rel
                    if (Test-Path -LiteralPath $p -PathType Leaf) { [void]$v1cands.Add($p) }
                }
            }
            foreach ($cand in @($v1cands)) {
                $exePath = [string]$cand
                $ext = [IO.Path]::GetExtension($exePath).ToLowerInvariant()
                if ($ext -ne '.exe') {
                    $resolved = ''
                    try { $resolved = Resolve-SpikeShimTarget -ShimPath $exePath } catch { $resolved = '' }
                    if ([string]::IsNullOrWhiteSpace($resolved)) { continue }
                    $exePath = $resolved
                }
                if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { continue }
                $rem22 = [int]($v1DeadlineUtc.Subtract([DateTime]::UtcNow).TotalMilliseconds)
                if ($rem22 -lt 5000) { break }
                $vr = Invoke-SpikeChild -FilePath $exePath -ArgumentList @('--version') -TimeoutMs ([Math]::Max(5000, [Math]::Min(90000, $rem22))) -CleanEnvironment -StdinNul
                if ([bool]$vr.TimedOut -or [int]$vr.ExitCode -ne 0) { continue }
                $vt = ([string]$vr.Stdout + "`n" + [string]$vr.Stderr)
                # V1 imprime so '1.18.34' (sem o prefixo 'opencode v' do V2);
                # compara por token exato de versao em vez de Test-SpikeExactVersion
                $exact1 = ($vt -cmatch ('(^|\s)(opencode\s+)?v?' + [regex]::Escape($wantV1) + '(\s|$)'))
                if ($exact1) { $v1exe = $exePath; break }
            }
            $rem22 = [int]($v1DeadlineUtc.Subtract([DateTime]::UtcNow).TotalMilliseconds)
            $deadlineHit22 = ($rem22 -lt 15000)
            if ($deadlineHit22) { [void](Add-ScenarioProof $proofs 'scenario-deadline-exceeded' $false ('janela nominal do cenario (' + $ScenarioTimeoutSeconds + 's) sem tempo util restante; operacoes pesadas restantes puladas')) }
            if ([string]::IsNullOrWhiteSpace($v1exe) -and $InstallV1IfMissing -and (-not $deadlineHit22) -and (-not [string]::IsNullOrWhiteSpace($script:NodeExe))) {
                # Instalacao ISOLADA do pin V1 (prefixo dentro do TargetHome; nada global).
                $v1Prefix = Join-Path $TargetHome 'v1-runtime'
                $spec = $V1NpmSpec
                if ([string]::IsNullOrWhiteSpace($spec)) { $spec = ('opencode-ai@' + $wantV1) }
                try {
                    $inst = Invoke-PreflightBoundedExe -File $script:NodeExe -ArgsLine ('"' + $script:NpmCliJs + '" install --prefix "' + $v1Prefix + '" ' + $spec + ' --no-audit --no-fund') -WorkDir $script:CwdT -EnvTable $script:IsoEnv -EnvRemove ($script:IsoRemove + $script:SensitiveEnvRemove) -TimeoutMs ([Math]::Max(5000, [Math]::Min(180000, $rem22))) -MaxChars 20000
                    $instOk = (([bool]$inst.Finished) -and ([int]$inst.ExitCode -eq 0) -and (-not [bool]$inst.Truncated))
                    [void](Add-ScenarioProof $proofs 'v1-isolated-install' $instOk ('cmd: npm install --prefix <TargetHome>/v1-runtime ' + $spec + ' rc=' + [int]$inst.ExitCode + ' out=' + (Get-LaneSafeText ([string]$inst.Output) 160)))
                    if ($instOk) {
                        $candExe = Join-Path $v1Prefix 'node_modules\opencode-ai\bin\opencode.exe'
                        if (Test-Path -LiteralPath $candExe -PathType Leaf) {
                            # primeira execucao a frio de um binario novo pode passar de 30s
                            # (scan do antivirus); deadline 90s com uma retry
                            foreach ($attempt in 1, 2) {
                                $rem22 = [int]($v1DeadlineUtc.Subtract([DateTime]::UtcNow).TotalMilliseconds)
                                if ($rem22 -lt 5000) { break }
                                $vr = Invoke-SpikeChild -FilePath $candExe -ArgumentList @('--version') -TimeoutMs ([Math]::Max(5000, [Math]::Min(90000, $rem22))) -CleanEnvironment -StdinNul
                                if ([bool]$vr.TimedOut) { continue }
                                if ([int]$vr.ExitCode -ne 0) { continue }
                                $vt = ([string]$vr.Stdout + "`n" + [string]$vr.Stderr)
                                $exact1 = ($vt -cmatch ('(^|\s)(opencode\s+)?v?' + [regex]::Escape($wantV1) + '(\s|$)'))
                                if ($exact1) { $v1exe = $candExe; break }
                            }
                        }
                    }
                } catch {
                    [void](Add-ScenarioProof $proofs 'v1-isolated-install' $false ('throw: ' + $_.Exception.Message))
                }
            }
            if ([string]::IsNullOrWhiteSpace($v1exe)) {
                [void](Add-ScenarioProof $proofs 'v1-binary-pinned-found' $false ('nenhum binario V1 ' + $wantV1 + ' (param, PATH opencode-ai, npm prefix -g' + $(if ($InstallV1IfMissing) { ', install isolado' } else { '' }) + ')'))
                Set-ScenarioResult 'RR-E2E-22' 'blocked' ('runtime V1 real do pin ' + $wantV1 + ' indisponivel neste host (instalacao operator-owned; rode com -InstallV1IfMissing)') $proofs $coverage
            } else {
                [void](Add-ScenarioProof $proofs 'v1-binary-pinned-found' $true ('path-sanitizado, versao=' + $wantV1))
                # REV3: nenhuma chamada de help escapa da janela - a primeira
                # so executa com >= 5s restantes; retries 1/2 reavaliam o
                # restante e recebem no maximo esse tempo (fail-closed)
                $rem22 = [int]($v1DeadlineUtc.Subtract([DateTime]::UtcNow).TotalMilliseconds)
                $help = $null
                if ($rem22 -ge 5000) {
                    $help = Invoke-SpikeChild -FilePath $v1exe -ArgumentList @('--help') -TimeoutMs ([Math]::Min(60000, $rem22)) -CleanEnvironment -StdinNul
                }
                if ($null -ne $help) { $rem22 = [int]($v1DeadlineUtc.Subtract([DateTime]::UtcNow).TotalMilliseconds) }
                if (($null -ne $help) -and [bool]$help.TimedOut -and ($rem22 -ge 5000)) {
                    # retry 1: ambiente isolado da lane (help pode consultar config/paths)
                    $help = Invoke-SpikeChild -FilePath $v1exe -ArgumentList @('--help') -TimeoutMs ([Math]::Min(120000, $rem22)) -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -CleanEnvironment -StdinNul
                }
                if ($null -ne $help) { $rem22 = [int]($v1DeadlineUtc.Subtract([DateTime]::UtcNow).TotalMilliseconds) }
                if (($null -ne $help) -and [bool]$help.TimedOut -and ($rem22 -ge 5000)) {
                    # retry 2 (ultimo): ambiente herdado + cwd isolado; probe read-only
                    # de superficie, sem execucao de scripts; REV2: a denylist
                    # sensivel (token/keys) e aplicada tambem neste caminho
                    $help = Invoke-SpikeChild -FilePath $v1exe -ArgumentList @('--help') -EnvRemove $script:SensitiveEnvRemove -WorkingDirectory $script:CwdT -StdinNul -TimeoutMs ([Math]::Min(60000, $rem22))
                }
                $helpTimedOut = $(if ($null -ne $help) { [bool]$help.TimedOut } else { $true })
                $helpRc = $(if ($null -ne $help) { [int]$help.ExitCode } else { -1 })
                $helpText = $(if ($null -ne $help) { ([string]$help.Stdout + "`n" + [string]$help.Stderr) } else { '' })
                # fail-closed: help indisponivel NAO e prova negativa
                $helpUsable = (($helpTimedOut -eq $false) -and ($helpRc -eq 0) -and ($helpText.Trim().Length -gt 40))
                if (-not $helpUsable) {
                    [void](Add-ScenarioProof $proofs 'v1-no-native-resume-observed' $false ('--help indisponivel (timedout=' + $helpTimedOut + ' rc=' + $helpRc + '); ausencia NAO observada'))
                    Set-ScenarioResult 'RR-E2E-22' 'blocked' 'superficie de comandos do V1 indisponivel; nada e inferido' $proofs $coverage
                } else {
                    # superficie de COMANDOS top-level (linhas 'opencode <cmd>');
                    # tokens soltos no texto (ex.: descricao de upgrade) nao contam
                    $cmdNames = @()
                    foreach ($ln in ($helpText -split "`r?`n")) {
                        if ($ln -cmatch '^\s*opencode\s+([a-z][a-z0-9-]*)') { $cmdNames += $Matches[1].ToLowerInvariant() }
                    }
                    $resumeCmds = @($cmdNames | Where-Object { $_ -in @('resume', 'restore', 'continue', 'reopen') })
                    [void](Add-ScenarioProof $proofs 'v1-no-native-resume-observed' ((@($resumeCmds).Count -eq 0) -and (@($cmdNames).Count -gt 3)) ('comandos-observados=' + (($cmdNames | Select-Object -First 16) -join ',') + '; comandos-de-resume=' + (@($resumeCmds) -join ',')))
                # task real V2 para gerar envelope persistido real
                $t = New-LaneTask -TaskId 'lane22' -Objective 'RR-E2E-22: fresh-session fallback V1 sem resume nativo'
                if (-not (Test-KernelOk $t)) {
                    Set-ScenarioResult 'RR-E2E-22' 'fail' ('kernel create LANE22 falhou') $proofs $coverage
                } else {
                    $rec = (Get-LaneTask -TaskId 'lane22').json
                    $envelope = New-OrchestrationContinuationEnvelope -TaskId 'lane22' `
                        -Objective ([string](Get-JsonProp $rec 'objective' '')) `
                        -UserIntent 'lane closure RR-E2E-22' `
                        -NextMove 'fresh V1 session consumes this envelope' `
                        -TimestampUtc (Get-LaneTimestampUtc)
                    $envPath = Join-Path $script:EnvelopeDir 'lane22-envelope.json'
                    $envOk = (($null -ne $envelope) -and (Write-LaneJson $envelope $envPath))
                    [void](Add-ScenarioProof $proofs 'envelope-persisted' $envOk 'lane22-envelope.json')
                    $consumePath = Join-Path $script:EnvelopeDir 'consume-lane22.ps1'
                    $consumeText = ". '" + (Join-Path $v3LibDir 'OrchestrationSessionReconciler.ps1') + "'`n" + `
                        "`$e = ConvertFrom-Json ([IO.File]::ReadAllText('" + $envPath + "'))`n" + `
                        "`$p = New-OrchestrationContinuationPlan -Envelope `$e -Runtime '1' -EnvelopeRef 'lane22-envelope.json'`n" + `
                        "`$p | ConvertTo-Json -Depth 6`n"
                    [IO.File]::WriteAllText($consumePath, $consumeText, (New-Object Text.UTF8Encoding $false))
                    $cr = Invoke-SpikeChild -FilePath $script:WindowsPowerShellExe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $consumePath) -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 60000 -CleanEnvironment -StdinNul
                    $plan = $null
                    try { $plan = ConvertFrom-Json ([string]$cr.Stdout) } catch { $plan = $null }
                    $planOk = (($null -ne $plan) -and ([string](Get-JsonProp $plan 'mode' '') -ceq 'fresh-session') -and (-not [bool](Get-JsonProp $plan 'native_resume' $true)) -and ([string](Get-JsonProp $plan 'task_id' '') -ceq 'lane22'))
                    [void](Add-ScenarioProof $proofs 'fresh-session-fallback-plan' $planOk ('mode=' + $(if ($null -ne $plan) { [string](Get-JsonProp $plan 'mode' '') } else { 'null' }) + ' native_resume=' + $(if ($null -ne $plan) { [string](Get-JsonProp $plan 'native_resume' '') } else { 'null' })))
                    [void]$coverage.Add('V1 real: binario do pin executado + superficie sem resume nativo observada + fallback fresh-session provado (native_resume=false)')
                    [void]$coverage.Add('sessao V1 via server REST nao exercitada nesta lane (escopo: fallback fresh-session; instalacao/sessao completas de V1 seguem operator-owned)')
                    $allOk = $true
                    foreach ($p in @($proofs)) { if (-not [bool]$p['ok']) { $allOk = $false; break } }
                    # REV2 (fail-closed): o required_activation integral ("Real V1
                    # runtime fresh-session continuation") inclui o turn da fresh
                    # session (provider de modelo). A lane prova o PLANO
                    # (native_resume=false) e a superficie de comandos; o turn nunca
                    # e exercitado aqui - pass-real e inalcancavel nesta lane
                    Set-ScenarioResult 'RR-E2E-22' $(if ($allOk) { 'blocked' } else { 'fail' }) $(if ($allOk) { 'parcial provado: V1 real do pin + superficie sem resume nativo observada + plano fresh-session provado (native_resume=false); o turn da fresh session exige provider de modelo' } else { 'provas com falha' }) $proofs $coverage
                    }
                }
            }
            }
        } catch {
            Set-ScenarioResult 'RR-E2E-22' 'fail' ('excecao: ' + $_.Exception.Message) $proofs $coverage
        }
    }

    # ==================================================================
    # Probes V2-native (8 features) - read/test oriented
    # ==================================================================
    if (-not $SkipCapabilityProbes) {
        function Add-ProbeResult {
            [CmdletBinding()] param([string]$Capability, [string]$Probe, [string]$CommandConfig, [string]$Expected, [string]$Observed, [string]$Classification, [string]$PolicyHonored, [string]$PolicyIgnored, [string]$FailMode, [string]$Note)
            [void]$script:ProbeResults.Add([ordered]@{
                    capability     = $Capability
                    probe          = $Probe
                    command_config = (Get-LaneSafeText $CommandConfig 300)
                    expected       = (Get-LaneSafeText $Expected 300)
                    observed       = (Get-LaneSafeText $Observed 400)
                    classification = $Classification
                    policy_honored = (Get-LaneSafeText $PolicyHonored 200)
                    policy_ignored = (Get-LaneSafeText $PolicyIgnored 200)
                    fail_mode      = (Get-LaneSafeText $FailMode 120)
                    note           = (Get-LaneSafeText $Note 300)
                    at             = (Get-LaneTimestampUtc)
                })
            Write-Host ('[session-lane][probe] ' + $Capability + ' => ' + $Classification)
        }

        # 1. session-hierarchy-provenance (reaproveita evidencia real do cenario 18 quando executado)
        try {
            $rootP = New-RealSession
            if ([bool]$rootP.ok) {
                $chP = New-RealSession -ParentId ([string]$rootP.id)
                if ([bool]$chP.ok) {
                    $g = Invoke-Api -Method 'GET' -Path ('/api/session/' + [string]$chP.id)
                    $gj = Convert-ApiJson $g.body
                    $par = [string](Get-JsonProp $gj 'parentID' (Get-JsonProp $gj 'parent_id' ''))
                    if (([bool]$g.ok) -and ($par -ceq [string]$rootP.id)) {
                        Add-ProbeResult -Capability 'session-hierarchy-provenance' -Probe 'create child com parentID + GET child' `
                            -CommandConfig 'POST /api/session {"parentID":"<root>"}; GET /api/session/{child}' `
                            -Expected 'child expõe provenance do parent nativamente' -Observed ('parentID retornado = ' + $par) `
                            -Classification 'supported' -PolicyHonored 'n/a (observacional)' -PolicyIgnored 'nada observado' -FailMode 'n/a' -Note 'provenance nativa visível na API real'
                    } else {
                        Add-ProbeResult -Capability 'session-hierarchy-provenance' -Probe 'create child com parentID + GET child' `
                            -CommandConfig 'POST /api/session {"parentID":"<root>"}; GET /api/session/{child}' `
                            -Expected 'child expõe provenance do parent nativamente' -Observed ('GET ok=' + [bool]$g.ok + ' parentID=' + $par) `
                            -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'nada observado' -FailMode 'n/a' -Note 'provenance não confirmada no response (campo pode existir em outra forma)'
                    }
                } else {
                    Add-ProbeResult -Capability 'session-hierarchy-provenance' -Probe 'create child com parentID' -CommandConfig 'POST /api/session {"parentID":...}' -Expected 'child criado com parent' -Observed $chP.reason -Classification 'unsupported' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'criação de child recusada/indisponível no pin'
                }
            } else {
                Add-ProbeResult -Capability 'session-hierarchy-provenance' -Probe 'create root' -CommandConfig 'POST /api/session' -Expected 'sessao real' -Observed $rootP.reason -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'infra de sessão indisponível nesta execução'
            }
        } catch {
            Add-ProbeResult -Capability 'session-hierarchy-provenance' -Probe 'excecao' -CommandConfig '' -Expected '' -Observed $_.Exception.Message -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'probe falhou; nada é inferido'
        }

        # 2. session-permission-narrowing (overlay de config real + permissions por sessao no create)
        try {
            $sN = New-RealSession
            if ([bool]$sN.ok) {
                $allowResp = Invoke-Api -Method 'POST' -Path ('/api/session/' + [string]$sN.id + '/shell') -Data '{"command":"echo NarrowingProbeOk"}'
                $denyResp = Invoke-Api -Method 'POST' -Path ('/api/session/' + [string]$sN.id + '/shell') -Data '{"command":"cmd /c echo DeniedProbe"}'
                $allowOk = [bool]$allowResp.ok
                $denyBlocked = (-not [bool]$denyResp.ok)
                # segunda perna: permissions declaradas no PROPRIO create da sessao
                $denyBody = '{"permissions":[{"action":"shell","resource":"cmd /c echo DeniedProbe*","effect":"deny"}]}'
                $r2 = Invoke-Api -Method 'POST' -Path '/api/session' -Data $denyBody
                $sessPermObserved = ''
                $sessDenyBlocked = $false
                if ([bool]$r2.ok) {
                    $j2 = Convert-ApiJson $r2.body
                    $node2 = Get-JsonProp $j2 'data' $j2
                    $sid2 = [string](Get-JsonProp $node2 'id' '')
                    if (-not [string]::IsNullOrWhiteSpace($sid2)) {
                        $d2 = Invoke-Api -Method 'POST' -Path ('/api/session/' + $sid2 + '/shell') -Data '{"command":"cmd /c echo DeniedProbe"}'
                        $sessDenyBlocked = (-not [bool]$d2.ok)
                        $sessPermObserved = ('create-com-permissions aceito (id retornado); shell sob deny por-sessao recusado=' + $sessDenyBlocked)
                    } else {
                        $sessPermObserved = 'create com permissions retornou sem id'
                    }
                } else {
                    $sessPermObserved = ('create com permissions recusado: exit=' + [int]$r2.exit + ' ' + (Get-LaneSafeText $r2.body 120))
                }
                if ($allowOk -and $denyBlocked) {
                    Add-ProbeResult -Capability 'session-permission-narrowing' -Probe 'shell permitido vs shell sob deny do overlay' `
                        -CommandConfig 'agents.build.permissions += {action:shell, resource:cmd /c echo DeniedProbe*, effect:deny} (lane opencode.json)' `
                        -Expected 'comando permitido executa; comando sob deny e recusado pelo runtime' `
                        -Observed ('echo permitido rc=0; cmd negado rc=' + [int]$denyResp.exit + '; por-sessao: ' + $sessPermObserved) `
                        -Classification 'supported' -PolicyHonored 'deny do overlay aplicado pelo runtime' -PolicyIgnored 'nada observado' -FailMode 'fail-closed (deny recusa)' -Note 'restricao por sessao observada'
                } elseif ($allowOk -and (-not $denyBlocked)) {
                    $cls = 'unsupported'
                    if ($sessDenyBlocked) { $cls = 'ambiguous' }
                    Add-ProbeResult -Capability 'session-permission-narrowing' -Probe 'shell permitido vs shell sob deny (overlay de config + permissions por sessao)' `
                        -CommandConfig 'agents.build.permissions deny-overlay; POST /api/session {"permissions":[{"action":"shell","resource":"cmd /c echo DeniedProbe*","effect":"deny"}]}' `
                        -Expected 'deny recusa o comando marcado (config e/ou por-sessao)' `
                        -Observed ('overlay: deny NAO recusou via POST /shell (rc=' + [int]$denyResp.exit + '); por-sessao: ' + $sessPermObserved) `
                        -Classification $cls -PolicyHonored $(if ($sessDenyBlocked) { 'honrado apenas no create por-sessao' } else { 'nao honrado em nenhum caminho observado' }) -PolicyIgnored 'deny do overlay ignorado no caminho /shell' -FailMode 'fail-open observado via /shell' -Note 'resultado real; gating kernel-side continua obrigatorio'
                } else {
                    Add-ProbeResult -Capability 'session-permission-narrowing' -Probe 'shell permitido vs negado' -CommandConfig 'idem acima' -Expected 'par permitido/negado observavel' -Observed ('allow_ok=' + $allowOk + ' deny_blocked=' + $denyBlocked + '; por-sessao: ' + $sessPermObserved) -Classification 'ambiguous' -PolicyHonored 'inconclusivo' -PolicyIgnored 'inconclusivo' -FailMode 'n/a' -Note 'sem modelo o caminho de execucao pode diferir do modo interativo'
                }
            } else {
                Add-ProbeResult -Capability 'session-permission-narrowing' -Probe 'criar sessao' -CommandConfig '' -Expected '' -Observed $sN.reason -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'infra indisponivel'
            }
        } catch {
            Add-ProbeResult -Capability 'session-permission-narrowing' -Probe 'excecao' -CommandConfig '' -Expected '' -Observed $_.Exception.Message -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'probe falhou'
        }

        # 3. experimental-policies-hard-deny (mesma via do narrowing; politica experimental nao configurada => honesto)
        try {
            $hasExpPolicies = $false
            try {
                $expProps = Get-JsonProp $cfg 'experimental' $null
                $hasExpPolicies = ($null -ne (Get-JsonProp $expProps 'policies' $null))
            } catch { $hasExpPolicies = $false }
            if (-not $hasExpPolicies) {
                Add-ProbeResult -Capability 'experimental-policies-hard-deny' -Probe 'config sem experimental.policies ativo' `
                    -CommandConfig 'lane opencode.json: experimental = {subagent_depth:1} apenas' `
                    -Expected 'só é possível provar hard-deny com política experimental declarada e violada' `
                    -Observed 'lane não declara experimental.policies; probe de violação exigiria config de política específica do pin' `
                    -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'não inventado: sem política declarada não há deny a observar; probe específico fica para coleta com config operator-owned'
            }
        } catch {
            Add-ProbeResult -Capability 'experimental-policies-hard-deny' -Probe 'excecao' -CommandConfig '' -Expected '' -Observed $_.Exception.Message -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'probe falhou'
        }

        # 4/5. dependentes de inferencia
        Add-ProbeResult -Capability 'native-step-limits' -Probe 'limites nativos de passo' -CommandConfig 'n/a nesta lane' -Expected 'step limit nativo derivado de budget' -Observed 'execução de passos requer inferência de modelo (provider ausente no ambiente da lane)' -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'não decidível sem modelo; nenhum resultado inferido'
        Add-ProbeResult -Capability 'background-subagents-bounded' -Probe 'subagents em background com concorrencia limitada' -CommandConfig 'n/a nesta lane' -Expected 'spawn bounded observável' -Observed 'spawn de subagente requer inferência de modelo (provider ausente)' -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'não decidível sem modelo; limites continuam kernel-side'

        # 6. plugin-storage-index
        try {
            $dataDirs = @((Join-Path $xdgData 'opencode'), (Join-Path $xdgState 'opencode'), (Join-Path $xdgCache 'opencode'))
            $found = @()
            foreach ($dd in @($dataDirs)) {
                if (Test-Path -LiteralPath $dd) {
                    foreach ($d2 in @(Get-ChildItem -LiteralPath $dd -Directory -ErrorAction SilentlyContinue)) {
                        if ([string]$d2.Name -match 'plugin|storage') { $found += ($d2.FullName.Substring($TargetHome.Length)) }
                    }
                }
            }
            if (@($found).Count -gt 0) {
                Add-ProbeResult -Capability 'plugin-storage-index' -Probe 'storage de plugin presente sob XDG isolado' -CommandConfig 'listagem de dirs sob XDG_DATA/STATE/CACHE do perfil isolado' -Expected 'runtime cria storage de plugin como índice' -Observed ('dirs: ' + (@($found) -join ',')) -Classification 'supported' -PolicyHonored 'n/a (observacional)' -PolicyIgnored 'nada observado' -FailMode 'n/a' -Note 'presença observada; nunca-autoritativo segue invariante kernel-side'
            } else {
                Add-ProbeResult -Capability 'plugin-storage-index' -Probe 'storage de plugin sob XDG isolado' -CommandConfig 'idem' -Expected 'storage presente após uso' -Observed 'nenhum dir plugin/storage encontrado' -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'sem atividade de plugin nesta lane; nada inferido'
            }
        } catch {
            Add-ProbeResult -Capability 'plugin-storage-index' -Probe 'excecao' -CommandConfig '' -Expected '' -Observed $_.Exception.Message -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'probe falhou'
        }

        # 7. snapshots-auxiliary
        try {
            $snapDirs = @()
            foreach ($root2 in @((Join-Path $xdgData 'opencode'), (Join-Path $xdgState 'opencode'), (Join-Path $xdgCache 'opencode'), (Join-Path $script:HomeT '.opencode'))) {
                if (Test-Path -LiteralPath $root2) {
                    foreach ($d2 in @(Get-ChildItem -LiteralPath $root2 -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue)) {
                        if ([string]$d2.Name -match 'snapshot') { $snapDirs += ($d2.FullName.Substring($TargetHome.Length)) }
                    }
                }
            }
            if (@($snapDirs).Count -gt 0) {
                Add-ProbeResult -Capability 'snapshots-auxiliary' -Probe 'snapshot dirs sob perfil isolado' -CommandConfig 'listagem recursiva (depth 2) de dirs snapshot' -Expected 'runtime materializa snapshots como material auxiliar' -Observed ('dirs: ' + (@($snapDirs) | Select-Object -First 5) -join ',') -Classification 'supported' -PolicyHonored 'n/a' -PolicyIgnored 'nada observado' -FailMode 'n/a' -Note 'presença observada; subordinação a Git/worktree segue invariante kernel-side'
            } else {
                Add-ProbeResult -Capability 'snapshots-auxiliary' -Probe 'snapshot dirs' -CommandConfig 'idem' -Expected 'snapshot materializado' -Observed 'nenhum dir snapshot encontrado' -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'sem atividade que dispare snapshot; nada inferido'
            }
        } catch {
            Add-ProbeResult -Capability 'snapshots-auxiliary' -Probe 'excecao' -CommandConfig '' -Expected '' -Observed $_.Exception.Message -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'probe falhou'
        }

        # 8. durable-event-log-replay (durabilidade atravessando o restart real do cenario 17/18)
        try {
            $eventFiles = @()
            foreach ($root2 in @((Join-Path $xdgData 'opencode'), (Join-Path $xdgState 'opencode'))) {
                if (Test-Path -LiteralPath $root2) {
                    foreach ($f2 in @(Get-ChildItem -LiteralPath $root2 -File -Recurse -Depth 3 -ErrorAction SilentlyContinue)) {
                        if ([string]$f2.Name -match 'event|message|session' -and [string]$f2.Extension -match 'json|jsonl') { $eventFiles += ($f2.FullName.Substring($TargetHome.Length)) }
                    }
                }
            }
            if (@($eventFiles).Count -gt 0) {
                Add-ProbeResult -Capability 'durable-event-log-replay' -Probe 'arquivos de evento/sessao sob XDG apos ciclos com restart real' -CommandConfig 'listagem de arquivos event/message/session (json/jsonl)' -Expected 'log de eventos persistido sobrevive a restarts' -Observed ('arquivos: ' + ((@($eventFiles) | Select-Object -First 5) -join ',')) -Classification 'supported' -PolicyHonored 'n/a' -PolicyIgnored 'nada observado' -FailMode 'n/a' -Note 'durabilidade observada; replay-experimental segue contrato (nunca quebra recuperação)'
            } else {
                Add-ProbeResult -Capability 'durable-event-log-replay' -Probe 'arquivos de evento' -CommandConfig 'idem' -Expected 'log persistido' -Observed 'nenhum arquivo de evento localizado' -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'formato de persistência pode ser DB interno; nada inferido'
            }
        } catch {
            Add-ProbeResult -Capability 'durable-event-log-replay' -Probe 'excecao' -CommandConfig '' -Expected '' -Observed $_.Exception.Message -Classification 'ambiguous' -PolicyHonored 'n/a' -PolicyIgnored 'n/a' -FailMode 'n/a' -Note 'probe falhou'
        }
        Add-LaneNote 'probes V2-native sao observacionais: nenhum registro de v2-native-evidence.json foi escrito aqui'
    }

    # ---------- finalizacao: stop owned + settlement + job + 49374 ----------
    # F2: snapshot do PID antes do stop final (trilha apenas; sem gate).
    $pidBeforeFinal = 0
    try { $pidBeforeFinal = Get-LaneCurrentListenerPid } catch { $pidBeforeFinal = 0 }
    try { [void](Write-LaneTrailEvent -Event 'SERVICE_STOP_REQUESTED' -Fields @{ site = 'lane-final'; pid_before = $pidBeforeFinal; port = ([int]$script:Port) }) } catch { }
    $stpF = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'stop') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
    $stopFOk = ((-not [bool]$stpF.TimedOut) -and ([int]$stpF.ExitCode -eq 0))
    Add-LaneCheck 'service_stop_owned' $stopFOk ('rc=' + [int]$stpF.ExitCode)
    $settleF = Wait-LaneListener -DeadlineSeconds 30 -Mode 'absence'
    $settledF = [bool]$settleF.Absent
    if (-not $settledF) {
        $stopJob = Stop-RuntimeJobObject -Job $svcJob -TimeoutMs 15000
        $postF = Wait-LaneListener -DeadlineSeconds 20 -Mode 'absence'
        $settledF = [bool]$postF.Absent
        Add-LaneNote ('backstop de job acionado: ok=' + [string]$stopJob.Ok + ' settled=' + [string]$stopJob.Settled)
    }
    Add-LaneCheck 'service_settlement' $settledF ('ausencia conclusiva do listener apos stop owned')
    # F2: trilha EXPECTED_TEST_STOP do encerramento (advisory-only; os gates
    # acima seguem decidindo so pelos checks criticos).
    $pidAfterFinal = 0
    try {
        if ($settledF) { $pidAfterFinal = 0 }
        else {
            $lnF = $null
            try { $lnF = Get-PreflightNetTCPListenerBounded -Port ([int]$script:Port) -TimeoutMs 5000 } catch { $lnF = $null }
            if (($null -ne $lnF) -and ([bool]$lnF.QuerySucceeded) -and ([bool]$lnF.Exists) -and ($null -ne $lnF.OwningPID)) { $pidAfterFinal = [int]$lnF.OwningPID }
        }
    } catch { $pidAfterFinal = 0 }
    # F2: SERVICE_STOPPED conclusivo so com settlement (fail-closed em erro).
    if ([bool]$settledF) {
        try { [void](Write-LaneTrailEvent -Event 'SERVICE_STOPPED' -Fields @{ site = 'lane-final'; stop_rc = [int]$stpF.ExitCode; stop_timeout = [bool]$stpF.TimedOut; settlement = [bool]$settledF }) } catch { }
    }
    try { [void](Write-LaneTrailEvent -Event 'EXPECTED_TEST_STOP' -Fields @{ site = 'lane-final'; classification = 'EXPECTED_TEST_STOP'; pid_before = $pidBeforeFinal; pid_after = $pidAfterFinal; port = ([int]$script:Port); stop_rc = [int]$stpF.ExitCode; stop_timeout = [bool]$stpF.TimedOut; settlement = [bool]$settledF }) } catch { }
    $finClose = Close-RuntimeJobObject -Job $svcJob
    $script:JobClosedByLane = [bool]$finClose.Ok
    Add-LaneCheck 'job_object_closed' ([bool]$finClose.Ok) ('reason=' + [string]$finClose.Reason)
    $owner49374After = 'QUERY_FAILED'
    try {
        $ln2 = Get-PreflightNetTCPListenerBounded -Port 49374 -TimeoutMs 5000
        if ($null -ne $ln2 -and [bool]$ln2.QuerySucceeded) {
            if ([bool]$ln2.Exists -and $null -ne $ln2.OwningPID) {
                $idt2 = Get-PreflightProcessIdentity -OwnerPID ([int]$ln2.OwningPID)
                $owner49374After = ([string]$idt2.Name + ':' + [string]$ln2.OwningPID)
            } else { $owner49374After = 'FREE' }
        }
    } catch { $owner49374After = 'QUERY_FAILED' }
    $inv49374 = (($owner49374After -ceq $script:owner49374Before) -and ($owner49374After -ne 'QUERY_FAILED') -and ($owner49374After -ne 'UNSET'))
    Add-LaneCheck 'port49374_untouched' $inv49374 ('antes=' + $script:owner49374Before + ' depois=' + $owner49374After)

    # ---------- resumo + codigo de saida ----------
    $failCount = @(@($script:ScenarioResults) | Where-Object { [string]$_['status'] -ceq 'fail' }).Count
    $blockedCount = @(@($script:ScenarioResults) | Where-Object { [string]$_['status'] -ceq 'blocked' }).Count
    $probeAmbiguous = @(@($script:ProbeResults) | Where-Object { [string]$_['classification'] -ceq 'ambiguous' }).Count
    if (-not $inv49374) { Fail-Lane 'invariante 49374 violada no encerramento.' }
    # checks criticos de encerramento sao GATE: stop owned, settlement e
    # fechamento do job comprovados; falha em qualquer um => lane failed
    foreach ($cc in @('service_stop_owned', 'service_settlement', 'job_object_closed')) {
        $row = $null
        foreach ($c in @($script:LaneChecks)) { if ([string]$c['check'] -ceq $cc) { $row = $c; break } }
        if (($null -eq $row) -or (-not [bool]$row['ok'])) {
            Fail-Lane ('check critico de encerramento ausente ou falso: ' + $cc)
        }
    }
    $status = 'ok'
    if ($failCount -gt 0) { $status = 'failed' }
    elseif ($blockedCount -gt 0) { $status = 'ok-with-blocked' }
    # F2: LANE_FINISHED carrega so o veredito ja decidido acima (sem gate).
    try { [void](Write-LaneTrailEvent -Event 'LANE_FINISHED' -Fields @{ status = $status; fail_count = [int]$failCount; blocked_count = [int]$blockedCount }) } catch { }
    $summary = New-LaneSummary -Status $status -Reason $(if ($failCount -gt 0) { 'cenarios com fail' } elseif ($blockedCount -gt 0) { 'cenarios blocked (motivos nos rows)' } else { '' })
    $summary['port49374_owner_after'] = $owner49374After
    $main = Join-Path $script:EvidenceDir 'lane-summary.json'
    $summaryWritten = Write-LaneJson $summary $main
    if (-not $summaryWritten) { Fail-Lane 'falha ao gravar lane-summary.json (evidencia obrigatoria)' }
    foreach ($r in @($script:ScenarioResults)) {
        if (-not (Write-LaneJson $r (Join-Path $script:EvidenceDir ('rr-e2e-' + ([string]$r['scenario_id'] -replace 'RR-E2E-', '') + '.json')))) {
            Fail-Lane ('falha ao gravar evidencia do cenario ' + [string]$r['scenario_id'])
        }
    }
    if (@($script:ProbeResults).Count -gt 0) {
        $probeDoc = [ordered]@{
            lane    = 'session-real-lane-v2'
            purpose = 'V2-native capability probes (observational; no evidence records written)'
            pin     = $ExpectedVersion
            date    = ([DateTime]::UtcNow.ToString('yyyy-MM-dd'))
            probes  = @($script:ProbeResults)
            note    = 'companheiro de coleta; registros exatos em v2-native-evidence.json so apos decisao do operator'
        }
        if (-not (Write-LaneJson -Object $probeDoc -Path (Join-Path $script:EvidenceDir 'v2-native-probes.json'))) {
            Fail-Lane 'falha ao gravar v2-native-probes.json'
        }
    }
    Write-Host ('[session-lane] resumo: ' + $main)
    Write-Host ('[session-lane] cenarios: pass-real=' + (@(@($script:ScenarioResults) | Where-Object { [string]$_['status'] -ceq 'pass-real' }).Count) + ' fail=' + $failCount + ' blocked=' + $blockedCount + '; probes ambiguous=' + $probeAmbiguous)
    if ($failCount -gt 0) { exit 1 }
    if ($blockedCount -gt 0) { exit 2 }
    exit 0
} finally {
    # F2: LANE_CLEANUP na saida (advisory-only; cleanup existente intacto).
    try { [void](Write-LaneTrailEvent -Event 'LANE_CLEANUP' -Fields @{ job_closed_by_lane = [bool]$script:JobClosedByLane }) } catch { }
    # cleanup de processo e estado temporario; o job e o backstop primordial:
    # Stop-RuntimeJobObject encerra a arvore propria (kill-on-close), e a
    # remocao do home so ocorre depois do encerramento bounded
    if ($null -ne $script:svcJob -and [bool]$script:svcJob.Ok -and -not [bool]$script:JobClosedByLane) {
        try { $null = Stop-RuntimeJobObject -Job $script:svcJob -TimeoutMs 10000 } catch { }
        try { $null = Close-RuntimeJobObject -Job $script:svcJob } catch { }
        try {
            if (($script:Port -gt 0) -and ($null -ne (Get-Command Wait-LaneListener -ErrorAction SilentlyContinue))) {
                $null = Wait-LaneListener -DeadlineSeconds 8 -Mode 'absence'
            }
        } catch { }
    }
    try {
        $homeOk = $false
        try { $homeOk = ((Test-Path -LiteralPath $TargetHome) -and ($TargetHome.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase))) } catch { $homeOk = $false }
        if (-not $homeOk) {
            try { if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $homeOk = ((Test-Path -LiteralPath $TargetHome) -and ($TargetHome.StartsWith($env:RUNNER_TEMP, [StringComparison]::OrdinalIgnoreCase))) } } catch { $homeOk = $false }
        }
        if ($homeOk) { Remove-Item -LiteralPath $TargetHome -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
}
