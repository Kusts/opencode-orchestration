<#!
.SYNOPSIS
    Skill execution bridge CLI: proposta do Router V1 -> CAPABILITY_CONTEXT (Phase 10).
.DESCRIPTION
    CLI read-only do Planner para a Skill execution bridge (Phase 10).
    Le um TaskFile minimo (mesmo formato da shadow: task_id, objective,
    task_type, domain_hints, risk, read_write_mode, constraints) mais a
    proposta de skills do Router V1 (via -ProposedSkills, via campo
    proposed_skills do TaskFile, OU via -RouteFile com proposed_skills /
    route.skills) e emite JSON com o bloco CAPABILITY_CONTEXT canonico
    pronto para anexar ao Dispatch Contract.

    Uso:
      skill-bridge.ps1 [-TaskFile <json>] [-ProposedSkills <id...>]
        [-RouteFile <json>] [-RegistryPath ...] [-PolicyPath ...]
        [-FlagsPath ...] [-MaxSkills 1..5]

    Kill switch: se skill_routing.enabled nao for boolean $true, retorna
    {skills:[], status:'disabled'} SEM CAPABILITY_CONTEXT (null), exit 0.
    Quando habilitado e sem skill valida: {skills:[],
    fallback_used:true, blocked:false}, exit 0. Nunca lanca, nunca
    bloqueia (exit 0 em qualquer resultado operacional; exit 2 apenas em
    erro de uso). Nao escreve arquivos, nao carrega skills, nao executa
    nada. O carregamento e nativo no worker pela via nativa.
    PowerShell 5.1 compativel (`powershell -NoProfile -File`). ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$TaskFile,
    [string[]]$ProposedSkills,
    [string]$RouteFile,
    [string]$RegistryPath,
    [string]$PolicyPath,
    [string]$FlagsPath,
    [int]$MaxSkills = -1
)

$ErrorActionPreference = 'Stop'

$v3root = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $v3root)
. (Join-Path $v3root 'lib\CapabilitySkillBridge.ps1')

function Write-SkillBridgeCliError {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
}

if ((-not [string]::IsNullOrWhiteSpace($TaskFile)) -and (-not (Test-Path -LiteralPath $TaskFile -PathType Leaf))) {
    Write-SkillBridgeCliError ("skill-bridge.ps1: -TaskFile nao encontrado: {0}" -f $TaskFile)
    exit 2
}
if ((-not [string]::IsNullOrWhiteSpace($RouteFile)) -and (-not (Test-Path -LiteralPath $RouteFile -PathType Leaf))) {
    Write-SkillBridgeCliError ("skill-bridge.ps1: -RouteFile nao encontrado: {0}" -f $RouteFile)
    exit 2
}
if ([string]::IsNullOrWhiteSpace($TaskFile) -and [string]::IsNullOrWhiteSpace($RouteFile) -and (($null -eq $ProposedSkills) -or (@($ProposedSkills).Count -eq 0))) {
    Write-SkillBridgeCliError 'Uso: skill-bridge.ps1 [-TaskFile <json>] [-ProposedSkills <id...>] [-RouteFile <json>]. Informe ao menos uma entrada.'
    exit 2
}
if ($MaxSkills -ne -1 -and ($MaxSkills -lt 1 -or $MaxSkills -gt 5)) {
    Write-SkillBridgeCliError 'skill-bridge.ps1: -MaxSkills deve estar entre 1 e 5.'
    exit 2
}

try {
    $params = @{ RepoRoot = $repoRoot }
    if (-not [string]::IsNullOrWhiteSpace($TaskFile)) { $params['TaskFile'] = $TaskFile }
    if ($null -ne $ProposedSkills -and @($ProposedSkills).Count -gt 0) { $params['ProposedSkills'] = @($ProposedSkills) }
    if (-not [string]::IsNullOrWhiteSpace($RouteFile)) { $params['RouteFile'] = $RouteFile }
    if (-not [string]::IsNullOrWhiteSpace($RegistryPath)) { $params['RegistryPath'] = $RegistryPath }
    if (-not [string]::IsNullOrWhiteSpace($PolicyPath)) { $params['PolicyPath'] = $PolicyPath }
    if (-not [string]::IsNullOrWhiteSpace($FlagsPath)) { $params['FlagsPath'] = $FlagsPath }
    if ($MaxSkills -ne -1) { $params['MaxSkillsOverride'] = $MaxSkills }
    $result = Invoke-CapabilitySkillBridge @params
    Write-Output ($result | ConvertTo-Json -Depth 10)
    exit 0
}
catch {
    try {
        $fallback = [PSCustomObject]@{
            bridge_version          = '1'
            task_id                 = ''
            skills                  = @()
            capability_context      = $null
            capability_context_text = ''
            reason                  = 'fallback: erro interno contido (fail-safe; sem bloquear)'
            source                  = 'skill-bridge'
            fallback_used           = $true
            blocked                 = $false
            warnings                = @('skill bridge unavailable: interno')
            status                  = 'fallback'
        }
        Write-Output ($fallback | ConvertTo-Json -Depth 10)
        exit 0
    }
    catch {
        Write-SkillBridgeCliError 'skill-bridge.ps1: falha interna contida.'
        exit 0
    }
}
