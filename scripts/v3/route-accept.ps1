<#!
.SYNOPSIS
    Stage-1 controlled agent-routing entrypoint (Phase 15): accept Router route or fall back deterministically.
.DESCRIPTION
    CLI do EXECUTOR atras de capability_router.active. Le as flags reais
    (source/registry/capability-flags.json), e:

      - active=false (kill switch): rota deterministica (expected agent),
        fallback_used=true, fallback_reason=router_inactive. O Router nao decide.
      - active=true: roda o Router V1 e aplica o envelope Stage 1 (categoria
        permitida + sem hard exclusion + candidato valido + confidence gate +
        sem conflito fraco com a expectativa). Aceita a rota do Router quando
        tudo passa; caso contrario cai em DETERMINISTIC_FALLBACK.

    O retorno e DADO: nunca executa MCP, nunca carrega skill, nunca altera
    flags/authority/permissao/allowlist. Security/authority/destructive/
    credentials/migration/control-plane/MCP-execution sao deterministic-first.
    Telemetria sanitizada (ids/hashes/enums/bools/ints) e anexada em
    cache/v3/telemetry/acceptance-YYYYMMDD.jsonl (fail-closed; -NoTelemetry
    desativa). Fail-safe: nunca lanca na tarefa (exit 0); exit 2 apenas em uso
    ou escrita fora do diretorio permitido. PowerShell 5.1. ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$TaskFile,
    [string]$Objective,
    [string]$TaskType,
    [string]$Domain,
    [string]$Risk,
    [string]$ReadWrite,
    [string]$Project,
    [string]$TaskId,
    [string[]]$SecondaryDomains,
    [string]$RegistryPath,
    [string]$PolicyPath,
    [string]$FlagsPath,
    [string]$ConfigPath,
    [string]$TelemetryPath,
    [switch]$NoTelemetry,
    [int]$MaxAgeSeconds = -1
)

$ErrorActionPreference = 'Stop'

$v3root = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $v3root)
. (Join-Path $v3root 'lib\CapabilityRouter.ps1')
. (Join-Path $v3root 'lib\CapabilityAcceptance.ps1')

function Write-AcceptCliError {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Get-AcceptCliDefaultPath {
    param([string]$Given, [string]$Relative)
    if (-not [string]::IsNullOrWhiteSpace($Given)) { return $Given }
    return (Join-Path $repoRoot $Relative)
}

if ([string]::IsNullOrWhiteSpace($TaskFile)) {
    $inline = (-not [string]::IsNullOrWhiteSpace($Objective)) -or (-not [string]::IsNullOrWhiteSpace($TaskType)) -or (-not [string]::IsNullOrWhiteSpace($Domain))
    if (-not $inline) {
        Write-AcceptCliError 'Uso: route-accept.ps1 -TaskFile <json>  OU  route-accept.ps1 -Objective "..." [-TaskType ...] [-Domain ...] [-Risk ...] [-ReadWrite read|write] [-TaskId ...].'
        exit 2
    }
}
elseif ((-not [string]::IsNullOrWhiteSpace($Objective)) -or (-not [string]::IsNullOrWhiteSpace($TaskType)) -or (-not [string]::IsNullOrWhiteSpace($Domain))) {
    Write-AcceptCliError 'Uso: -TaskFile <json> OU parametros inline; nao ambos.'
    exit 2
}

$objective = $Objective
$taskType = $TaskType
$domain = $Domain
$risk = $Risk
$readWrite = $ReadWrite
$project = $Project
$explicit = @()
$categories = @()
$tags = @()
if (-not [string]::IsNullOrWhiteSpace($TaskFile)) {
    if (-not (Test-Path -LiteralPath $TaskFile -PathType Leaf)) {
        Write-AcceptCliError ("TaskFile nao encontrado: {0}" -f $TaskFile)
        exit 2
    }
    $raw = ''
    try { $raw = [IO.File]::ReadAllText($TaskFile, [Text.UTF8Encoding]::new($false)) }
    catch {
        Write-AcceptCliError ("TaskFile ilegivel: {0}" -f $_.Exception.Message)
        exit 2
    }
    $doc = $null
    try { $doc = $raw | ConvertFrom-Json }
    catch {
        Write-AcceptCliError ("TaskFile JSON invalido: {0}" -f $_.Exception.Message)
        exit 2
    }
    try {
        if ($null -ne $doc.objective) { $objective = [string]$doc.objective }
        if ($null -ne $doc.task_type) { $taskType = [string]$doc.task_type }
        elseif ($null -ne $doc.taskType) { $taskType = [string]$doc.taskType }
        if ($null -ne $doc.domain) { $domain = [string]$doc.domain }
        if ($null -ne $doc.risk) { $risk = [string]$doc.risk }
        if ($null -ne $doc.read_write) { $readWrite = [string]$doc.read_write }
        elseif ($null -ne $doc.readWrite) { $readWrite = [string]$doc.readWrite }
        if ($null -ne $doc.project) { $project = [string]$doc.project }
        if ($null -ne $doc.task_id) { $TaskId = [string]$doc.task_id }
        elseif ($null -ne $doc.taskId) { $TaskId = [string]$doc.taskId }
        if ($null -ne $doc.explicit_triggers) { $explicit = @($doc.explicit_triggers) }
        elseif ($null -ne $doc.explicitTriggers) { $explicit = @($doc.explicitTriggers) }
        if ($null -ne $doc.categories) { $categories = @($doc.categories) }
        if ($null -ne $doc.tags) { $tags = @($doc.tags) }
        if ($null -ne $doc.secondary_domains) { $SecondaryDomains = @($doc.secondary_domains) }
        elseif ($null -ne $doc.secondaryDomains) { $SecondaryDomains = @($doc.secondaryDomains) }
    }
    catch {
        Write-AcceptCliError ("TaskFile com campos ilegiveis: {0}" -f $_.Exception.Message)
        exit 2
    }
}
if ([string]::IsNullOrWhiteSpace($risk)) { $risk = 'unknown' }

$resolvedPolicy = Get-AcceptCliDefaultPath -Given $PolicyPath -Relative 'source\registry\capability-policy.json'
$resolvedRegistry = Get-AcceptCliDefaultPath -Given $RegistryPath -Relative 'cache\v3\capability-registry.json'
$resolvedFlags = Get-AcceptCliDefaultPath -Given $FlagsPath -Relative 'source\registry\capability-flags.json'

if (-not [string]::IsNullOrWhiteSpace($TelemetryPath)) {
    $allowedTel = Join-Path $repoRoot 'cache\v3\telemetry'
    if (-not (Test-AcceptanceConfinedPath -Path $TelemetryPath -AllowedDir $allowedTel -RepoRoot $repoRoot)) {
        Write-AcceptCliError ("route-accept.ps1: -TelemetryPath fora de cache\v3\telemetry (negado): {0}" -f $TelemetryPath)
        exit 2
    }
    $telFull = ''
    if ([IO.Path]::IsPathRooted($TelemetryPath)) { $telFull = [IO.Path]::GetFullPath($TelemetryPath) } else { $telFull = [IO.Path]::GetFullPath((Join-Path $repoRoot $TelemetryPath)) }
    if (Test-AcceptancePathHasReparsePoint -Path $telFull) {
        Write-AcceptCliError ("route-accept.ps1: -TelemetryPath com reparse point/junction em ancestor (negado): {0}" -f $TelemetryPath)
        exit 2
    }
}

try {
    $task = New-RouterTask -Objective $objective -TaskType $taskType -Domain $domain -Risk $risk -ReadWrite $readWrite -Project $project -ExplicitTriggers $explicit -Categories $categories -Tags $tags -SecondaryDomains $SecondaryDomains
    $params = @{
        Task          = $task
        PolicyPath    = $resolvedPolicy
        RegistryPath  = $resolvedRegistry
        FlagsPath     = $resolvedFlags
        RepoRoot      = $repoRoot
        MaxAgeSeconds = $MaxAgeSeconds
        TaskId        = $TaskId
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $params['ConfigPath'] = $ConfigPath }
    if (-not [string]::IsNullOrWhiteSpace($TelemetryPath)) { $params['TelemetryPath'] = $TelemetryPath }
    if ($NoTelemetry) { $params['NoTelemetry'] = $true }
    $res = Invoke-CapabilityAcceptance @params
    $d = $res.decision
    $out = [ordered]@{
        tool             = 'route-accept.ps1'
        router_version   = '1'
        mode             = [string]$d.mode
        accepted         = [bool]$d.accepted
        selected_agent   = [string]$d.selected_agent
        blocked          = [bool]$d.blocked
        router_candidate = [string]$d.router_candidate
        expected_agent   = [string]$d.expected_agent
        direct           = [bool]$d.direct
        fallback_used    = [bool]$d.fallback_used
        fallback_reason  = [string]$d.fallback_reason
        envelope         = [ordered]@{
            stage     = [string]$d.envelope_stage
            allowed   = [bool]$d.envelope_allowed
            category  = [string]$d.envelope_category
            exclusion = [string]$d.envelope_exclusion
        }
        confidence_class = [string]$d.confidence_class
        confidence_gate  = [string]$d.confidence_gate
        disagreement     = [bool]$d.disagreement
        hard_gate        = $d.hard_gate
        signals          = $d.signals
        reason           = [string]$d.reason
        latency          = $res.latency
        registry_fresh   = [bool]$res.registry_fresh
        registry_ok      = [bool]$res.registry_ok
        policy_available = [bool]$res.policy_available
        warnings         = @()
    }
    Write-Output ($out | ConvertTo-Json -Depth 10)
    exit 0
}
catch {
    try {
        $expected = ''
        try { $expected = Get-RouterExpectedAgent -Task (New-RouterTask -Objective $objective -TaskType $taskType -Domain $domain -Risk $risk -ReadWrite $readWrite) } catch { $expected = '' }
        $fallback = [ordered]@{
            tool             = 'route-accept.ps1'
            router_version   = '1'
            mode             = 'fallback'
            accepted         = $false
            selected_agent   = ''
            blocked          = $true
            router_candidate = ''
            expected_agent   = $expected
            direct           = $false
            fallback_used    = $true
            fallback_reason  = 'acceptance_internal_error'
            envelope         = [ordered]@{ stage = 'stage1'; allowed = $false; category = ''; exclusion = 'acceptance_internal_error' }
            confidence_class = 'unknown'
            confidence_gate  = 'insufficient'
            disagreement     = $false
            hard_gate        = [ordered]@{ security_required = $false; authority_required = $false; destructive = $false; mcp_execution = $false }
            signals          = [ordered]@{ hard_filter_pass = $false; allowlisted = $false; available = $false; role_compatible = $false; fresh = $false }
            reason           = 'acceptance_internal_error'
            latency          = [ordered]@{ registry_load_ms = 0; router_ms = 0; total_ms = 0 }
            registry_fresh   = $false
            registry_ok      = $false
            policy_available = $false
            warnings         = @('route-accept erro interno contido (fail-safe)')
        }
        Write-Output ($fallback | ConvertTo-Json -Depth 10)
        exit 0
    }
    catch {
        Write-AcceptCliError 'route-accept.ps1: falha interna contida.'
        exit 0
    }
}
