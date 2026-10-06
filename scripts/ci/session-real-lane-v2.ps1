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
    [int]$KernelTimeoutMs = 90000
)
$ErrorActionPreference = 'Stop'

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
        checks               = @($script:LaneChecks)
        notes                = @($script:LaneNotes)
        isolation            = 'XDG_CONFIG/DATA/STATE/CACHE + HOME/USERPROFILE no TargetHome exclusivo; -CleanEnvironment nos filhos; cwd no TargetHome; stdin fechado; password do service.json nunca logado'
        job_backstop         = 'Job Object com KILL_ON_JOB_CLOSE criado antes do service start; contem somente o processo desta lane'
        port49374_owner_before = $script:owner49374Before
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

    $sst = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'start') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul -JobObject $svcJob
    if ([bool]$sst.TimedOut) { Fail-Lane 'service start: TIMEOUT 30s.' }
    if ([int]$sst.ExitCode -ne 0) { Fail-Lane ('service start: exit ' + $sst.ExitCode) }
    if (-not [bool]$sst.JobAssigned) { Fail-Lane ('atribuicao ao job NAO comprovada (nota=' + [string]$sst.JobNote + ')') }
    Add-LaneCheck 'service_start_explicit_job_assigned' $true ('service start rc=0; job_assigned=true; nota=' + [string]$sst.JobNote)

    function Wait-LaneListener([int]$DeadlineSeconds, [ValidateSet('presence', 'absence')][string]$Mode) {
        $deadline = [DateTime]::UtcNow.AddSeconds($DeadlineSeconds)
        $seen = $false; $absent = $false; $inconclusive = 0
        while ([DateTime]::UtcNow -lt $deadline) {
            $remainingMs = [int]([DateTime]::UtcNow - $deadline).TotalMilliseconds * -1
            if ($remainingMs -gt 10000) { $remainingMs = 10000 }
            if ($remainingMs -lt 500) { $remainingMs = 500 }
            $ln = Get-PreflightNetTCPListenerBounded -Port $script:Port -TimeoutMs $remainingMs
            if ($null -ne $ln -and [bool]$ln.QuerySucceeded) {
                if ([bool]$ln.Exists -and $null -ne $ln.OwningPID) { $seen = $true; if ($Mode -eq 'presence') { break } }
                elseif ([bool]$ln.Exists) { $inconclusive++ }
                else { $absent = $true; if ($Mode -eq 'absence') { break } }
            } else { $inconclusive++ }
            Start-Sleep -Milliseconds 1000
        }
        return [ordered]@{ Seen = $seen; Absent = $absent; Inconclusive = $inconclusive }
    }
    $obs = Wait-LaneListener -DeadlineSeconds 30 -Mode 'presence'
    if (-not [bool]$obs.Seen) { Fail-Lane ('service start: sem listener na porta ' + $freePort + ' apos 30s.') }
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
    $presCheck = Wait-LaneListener -DeadlineSeconds 5 -Mode 'presence'
    if (-not [bool]$presCheck.Seen) {
        $sst3 = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'start') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul -JobObject $svcJob
        $presCheck = Wait-LaneListener -DeadlineSeconds 30 -Mode 'presence'
        if (-not [bool]$presCheck.Seen) { Fail-Lane 'servico indisponivel apos cenarios 16/17; lane abortada.' }
        Add-LaneNote 'service re-iniciado apos restart do cenario 17'
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
                    $stp = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'stop') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
                    $settle = Wait-LaneListener -DeadlineSeconds 30 -Mode 'absence'
                    $sst2 = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'start') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul -JobObject $svcJob
                    $pres = Wait-LaneListener -DeadlineSeconds 30 -Mode 'presence'
                    $restartOk = (([int]$stp.ExitCode -eq 0) -and ([bool]$settle.Absent) -and ([int]$sst2.ExitCode -eq 0) -and ([bool]$sst2.JobAssigned) -and ([bool]$pres.Seen))
                    [void](Add-ScenarioProof $proofs 'restart-real' $restartOk ('stop+settlement+start+listener'))
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
                            [void](Add-ScenarioProof $proofs 'completed-leg-recovered' $false ('BLOCKED sem modelo: ' + $completionEvidence))
                        }
                        [void]$coverage.Add('exercitado: child real (parentID) + restart real + reconciliacao com observacao real')
                        [void]$coverage.Add('perna completed-session: so observavel com turn de modelo; plano §10 (persistence) lista como perna distinta de "running child reattached" (exercitada aqui em runtime real)')
                        $allOk = $true
                        $completedLegOk = $false
                        foreach ($p in @($proofs)) {
                            if ([string]$p['proof'] -ceq 'completed-leg-recovered') { $completedLegOk = [bool]$p['ok']; continue }
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
        $null = (Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'start') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul -JobObject $svcJob)
        $presCheck = Wait-LaneListener -DeadlineSeconds 30 -Mode 'presence'
        if (-not [bool]$presCheck.Seen) { Fail-Lane 'servico indisponivel antes do cenario 19.' }
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
                        $stp19 = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'stop') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul
                        $settle19 = Wait-LaneListener -DeadlineSeconds 30 -Mode 'absence'
                        $sst19 = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'start') -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -TimeoutMs 30000 -CleanEnvironment -StdinNul -JobObject $svcJob
                        $pres19 = Wait-LaneListener -DeadlineSeconds 30 -Mode 'presence'
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
                        if ([bool]$srepl.ok) {
                            $inj = Invoke-Api -Method 'POST' -Path ('/api/session/' + [string]$srepl.id + '/synthetic') -Data '{"text":"RECOVERY lane20: task=lane20 state=PLANNING next=resume via envelope lane20-envelope.json"}'
                            [void](Add-ScenarioProof $proofs 'envelope-injection-attempt' $true ('POST /synthetic rc=' + [int]$inj.exit + ' (observacao; plano §10 permite fallback "supply on next Planner turn")'))
                            if ([bool]$inj.ok) {
                                $msgRepl = Invoke-Api -Method 'GET' -Path ('/api/session/' + [string]$srepl.id + '/message')
                                if ([bool]$msgRepl.ok -and ($msgRepl.body -match 'RECOVERY lane20')) {
                                    $injectionSupported = $true
                                }
                            }
                        }
                        # REV2 (fail-closed): a prova segue a realidade - ok apenas
                        # quando a injecao nativa foi confirmada na sessao
                        # substituta; sem injecao, o consumo PELO Planner
                        # substituto (turn) depende de provider de modelo
                        [void](Add-ScenarioProof $proofs 'envelope-received-by-replacement' $injectionSupported ('injecao_runtime_native=' + $injectionSupported + $(if (-not $injectionSupported) { '; consumo pelo Planner substituto (turn) exige provider de modelo - perna nao provada aqui' } else { '' })))
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
                        foreach ($p in @($proofs)) { if (([string]$p['proof'] -cne 'envelope-received-by-replacement') -and (-not [bool]$p['ok'])) { $hardFail20 = $true; break } }
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
            $t = New-LaneTask -TaskId 'lane21' -Objective 'RR-E2E-21: estado da task preservado na substituicao de sessao'
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
                    [void]$coverage.Add('substituicao real: estado re-lido do disco pela lane (kernel-side) preservado (state/objective/history) sem mutacao indevida; a releitura PELO substituto (turn do Planner) exige provider de modelo e nao e exercitada nesta lane')
                    # REV2 (fail-closed): o required_activation pede re-leitura PELO
                    # substituto; o que a lane prova kernel-side e a preservacao do
                    # estado apos substituicao real - logo o cenario e blocked-parcial
                    # enquanto a perna do turn nao existir
                    $hardFail21 = $false
                    foreach ($p in @($proofs)) { if (-not [bool]$p['ok']) { $hardFail21 = $true; break } }
                    Set-ScenarioResult 'RR-E2E-21' $(if ($hardFail21) { 'fail' } else { 'blocked' }) $(if ($hardFail21) { 'provas com falha' } else { 'parcial provado: substituicao de sessao real (detach+rebind) + estado/historico preservados e re-lidos kernel-side; releitura pelo proprio substituto (turn) exige provider de modelo - required_activation integral nao exercitado aqui' }) $proofs $coverage
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
                $rem22 = [int]($v1DeadlineUtc.Subtract([DateTime]::UtcNow).TotalMilliseconds)
                $help = Invoke-SpikeChild -FilePath $v1exe -ArgumentList @('--help') -TimeoutMs ([Math]::Max(5000, [Math]::Min(60000, $rem22))) -CleanEnvironment -StdinNul
                $rem22 = [int]($v1DeadlineUtc.Subtract([DateTime]::UtcNow).TotalMilliseconds)
                if ([bool]$help.TimedOut -and ($rem22 -ge 5000)) {
                    # retry 1: ambiente isolado da lane (help pode consultar config/paths)
                    $help = Invoke-SpikeChild -FilePath $v1exe -ArgumentList @('--help') -TimeoutMs ([Math]::Max(5000, [Math]::Min(120000, $rem22))) -EnvSet $script:IsoEnv -EnvRemove $script:IsoRemove -WorkingDirectory $script:CwdT -CleanEnvironment -StdinNul
                }
                $rem22 = [int]($v1DeadlineUtc.Subtract([DateTime]::UtcNow).TotalMilliseconds)
                if ([bool]$help.TimedOut -and ($rem22 -ge 5000)) {
                    # retry 2 (ultimo): ambiente herdado + cwd isolado; probe read-only
                    # de superficie, sem execucao de scripts; REV2: a denylist
                    # sensivel (token/keys) e aplicada tambem neste caminho
                    $help = Invoke-SpikeChild -FilePath $v1exe -ArgumentList @('--help') -EnvRemove $script:SensitiveEnvRemove -WorkingDirectory $script:CwdT -StdinNul -TimeoutMs 60000
                }
                $helpText = ([string]$help.Stdout + "`n" + [string]$help.Stderr)
                # fail-closed: help indisponivel NAO e prova negativa
                $helpUsable = ((-not [bool]$help.TimedOut) -and ([int]$help.ExitCode -eq 0) -and ($helpText.Trim().Length -gt 40))
                if (-not $helpUsable) {
                    [void](Add-ScenarioProof $proofs 'v1-no-native-resume-observed' $false ('--help indisponivel (timedout=' + [bool]$help.TimedOut + ' rc=' + [int]$help.ExitCode + '); ausencia NAO observada'))
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
