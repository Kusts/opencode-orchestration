<#!
.SYNOPSIS
    Mandatory orchestration preflight CLI: trivial/direct vs delegated vs deterministic fallback.
.DESCRIPTION
    Thin CLI over lib/OrchestrationPreflight.ps1. Reads a task inline
    (-Objective/-TaskType/-Domain/-Risk/-ReadWrite/-SecondaryDomains) or
    from a JSON TaskFile, prints the preflight decision as JSON, exit 0
    on valid use, exit 2 on invalid use. Never executes MCP, never loads
    skills, never changes flags/authority/allowlist/permissions/registry.
    PowerShell 5.1. ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$TaskFile,
    [string]$Objective,
    [string]$TaskType,
    [string]$Domain,
    [string]$Risk,
    [string]$ReadWrite,
    [string[]]$SecondaryDomains,
    [string]$RouterHealthy,
    [string]$RegistryFresh,
    [string]$RegistryOk
)

$ErrorActionPreference = 'Stop'

$v3root = $PSScriptRoot
. (Join-Path $v3root 'lib\OrchestrationPreflight.ps1')

function Write-PreflightCliError {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
}

$hasFile = -not [string]::IsNullOrWhiteSpace($TaskFile)
$hasInline = (-not [string]::IsNullOrWhiteSpace($Objective)) -or (-not [string]::IsNullOrWhiteSpace($TaskType)) -or (-not [string]::IsNullOrWhiteSpace($Domain))
if ($hasFile -and $hasInline) {
    Write-PreflightCliError 'Uso: -TaskFile <json> OU parametros inline; nao ambos.'
    exit 2
}
if ((-not $hasFile) -and (-not $hasInline)) {
    Write-PreflightCliError 'Uso: orchestration-preflight.ps1 -TaskFile <json>  OU  orchestration-preflight.ps1 -Objective "..." [-TaskType ...] [-Domain ...] [-Risk ...] [-ReadWrite read|write] [-SecondaryDomains ...].'
    exit 2
}

$objective = $Objective
$taskType = $TaskType
$domain = $Domain
$risk = $Risk
$readWrite = $ReadWrite
$sec = @()
if ($null -ne $SecondaryDomains) { $sec = @($SecondaryDomains) }
$flagRouterHealthy = $true
$flagRegistryFresh = $true
$flagRegistryOk = $true

function Convert-PreflightCliBool {
    param([string]$Text, [bool]$Default)
    # Absent signal keeps the caller default; a MALFORMED value is
    # untrusted input and fails closed to $false (deterministic fallback).
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Default }
    $s = ([string]$Text).Trim().ToLowerInvariant()
    if (($s -ceq 'false') -or ($s -ceq '0') -or ($s -ceq 'no')) { return $false }
    if (($s -ceq 'true') -or ($s -ceq '1') -or ($s -ceq 'yes')) { return $true }
    return $false
}

if ($hasFile) {
    if (-not (Test-Path -LiteralPath $TaskFile -PathType Leaf)) {
        Write-PreflightCliError ("TaskFile nao encontrado: {0}" -f $TaskFile)
        exit 2
    }
    $raw = ''
    try { $raw = [IO.File]::ReadAllText($TaskFile, [Text.UTF8Encoding]::new($false)) }
    catch {
        Write-PreflightCliError ("TaskFile ilegivel: {0}" -f $_.Exception.Message)
        exit 2
    }
    $doc = $null
    try { $doc = $raw | ConvertFrom-Json }
    catch {
        Write-PreflightCliError ("TaskFile JSON invalido: {0}" -f $_.Exception.Message)
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
        if ($null -ne $doc.secondary_domains) { $sec = @($doc.secondary_domains) }
        elseif ($null -ne $doc.secondaryDomains) { $sec = @($doc.secondaryDomains) }
        if ($null -ne $doc.router_healthy) { $flagRouterHealthy = Convert-PreflightCliBool -Text ([string]$doc.router_healthy) -Default $true }
        elseif ($null -ne $doc.routerHealthy) { $flagRouterHealthy = Convert-PreflightCliBool -Text ([string]$doc.routerHealthy) -Default $true }
        if ($null -ne $doc.registry_fresh) { $flagRegistryFresh = Convert-PreflightCliBool -Text ([string]$doc.registry_fresh) -Default $true }
        elseif ($null -ne $doc.registryFresh) { $flagRegistryFresh = Convert-PreflightCliBool -Text ([string]$doc.registryFresh) -Default $true }
        if ($null -ne $doc.registry_ok) { $flagRegistryOk = Convert-PreflightCliBool -Text ([string]$doc.registry_ok) -Default $true }
        elseif ($null -ne $doc.registryOk) { $flagRegistryOk = Convert-PreflightCliBool -Text ([string]$doc.registryOk) -Default $true }
    }
    catch {
        Write-PreflightCliError ("TaskFile com campos ilegiveis: {0}" -f $_.Exception.Message)
        exit 2
    }
}
else {
    $flagRouterHealthy = Convert-PreflightCliBool -Text $RouterHealthy -Default $true
    $flagRegistryFresh = Convert-PreflightCliBool -Text $RegistryFresh -Default $true
    $flagRegistryOk = Convert-PreflightCliBool -Text $RegistryOk -Default $true
}

if ([string]::IsNullOrWhiteSpace($risk)) { $risk = 'unknown' }

try {
    $res = Get-OrchestrationPreflight -Objective $objective -TaskType $taskType -Domain $domain -Risk $risk -ReadWrite $readWrite -SecondaryDomains $sec -RouterHealthy $flagRouterHealthy -RegistryFresh $flagRegistryFresh -RegistryOk $flagRegistryOk
    $out = [ordered]@{
        tool                   = 'orchestration-preflight.ps1'
        preflight_version      = 1
        orchestration_decision = [string]$res.orchestration_decision
        task_class             = [string]$res.task_class
        direct_reason          = [string]$res.direct_reason
        selected_agents        = @($res.selected_agents)
        fallback_reason        = [string]$res.fallback_reason
        bypass_verdict         = [string]$res.bypass_verdict
        post_execution_check   = [string]$res.post_execution_check
        evidence_hint          = 'evidence/v3/orchestration/preflight-decisions.jsonl'
    }
    Write-Output ($out | ConvertTo-Json -Depth 6)
    exit 0
}
catch {
    try {
        $fallback = [ordered]@{
            tool                   = 'orchestration-preflight.ps1'
            preflight_version      = 1
            orchestration_decision = 'DETERMINISTIC_FALLBACK'
            task_class             = 'non_trivial'
            direct_reason          = ''
            selected_agents        = @()
            fallback_reason        = 'preflight_internal_error'
            bypass_verdict         = 'PENDING_DETERMINISTIC_OWNER'
            post_execution_check   = 'Test-OrchestrationDoneCompliance -TaskClass non_trivial -Decision DETERMINISTIC_FALLBACK -DeterministicOwnerExecuted $<owner_ran>'
            evidence_hint          = 'evidence/v3/orchestration/preflight-decisions.jsonl'
        }
        Write-Output ($fallback | ConvertTo-Json -Depth 6)
        exit 0
    }
    catch {
        Write-PreflightCliError 'orchestration-preflight.ps1: falha interna contida.'
        exit 0
    }
}
