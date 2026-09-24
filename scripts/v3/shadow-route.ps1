<#!
.SYNOPSIS
    Bridge shadow-only do Planner para o Router V1 (Phase 9). Somente shadow.
.DESCRIPTION
    CLI executavel de live shadow: le um TaskFile minimo, aplica o kill
    switch estrito (capability_router.shadow precisa ser boolean $true),
    valida e sanitiza o contexto (task_id por regex, objective truncado em
    500 com redacao de segredos, hints/skills limitados a IDs canonicos),
    aplica dedupe por subtarefa (TTL 60s por task_id, -AllowRepeat forca),
    consulta o Router V1 por DEFAULT em processo isolado com timeout rigido
    (contexto por STDIN, sem arquivo temporario com objective; kill no
    timeout) e emite um JSON compacto. Com -InProcess (opt-in, testes de
    velocidade), consulta no mesmo processo SEM timeout rigido. -RouterProcess
    e alias legado do modo isolado (default atual). Fail-safe:
    nunca lanca e nunca bloqueia (exit 0 em qualquer resultado operacional;
    exit 2 apenas em erro de uso ou escrita fora do diretorio permitido).

    Uso:
      shadow-route.ps1 -TaskFile <json> [-TimeoutSeconds 20]
        [-InProcess] [-AllowRepeat] [-RouterPath ...] [-RegistryPath ...]
        [-PolicyPath ...] [-FlagsPath ...] [-ConfigPath ...]
        [-TelemetryPath ...] [-NoTelemetry]

    TaskFile (minimo; nunca enviar historico, dumps, secrets, skill content
    ou schemas):
      {task_id, objective, task_type, domain_hints[], risk, read_write_mode,
       constraints[], current_route:{agent,skills[]}, expected_agent?}

    Saida: JSON {router_version, task_id, proposed_agent, proposed_skills[],
    proposed_capability_classes[], filters_applied[], reason,
    confidence_class, fallback_used, warnings[], comparison, status,
    router_latency_ms, bridge_overhead_ms, deduped} onde status e um de
    success|failed|timeout|disabled|degraded|deduped e comparison e um de
    EQUAL|V3_BETTER|V3_WORSE|UNCLEAR|NOT_COMPARABLE. EQUAL/V3_BETTER/V3_WORSE
    somente com status success e proposed_agent presente; falha/timeout/
    disabled/degraded/deduped ou proposta ausente => NOT_COMPARABLE
    (nunca V3_WORSE/BETTER). Registry stale => degraded com
    proposed_agent=null, fallback_used=true e warning 'registry stale'.

    Guard: nao ativa nada; nao altera config, agentes, adapters ou flags;
    apenas anexa telemetria JSONL sanitizada em cache/v3/telemetry
    (fail-closed, DTO estavel com arrays como arrays, so IDs/hashes).
    Nunca carrega skills nem executa propostas.
    PowerShell 5.1 compativel (`powershell -NoProfile -File`). ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$TaskFile,
    [int]$TimeoutSeconds = 20,
    [switch]$RouterProcess,
    [switch]$InProcess,
    [switch]$AllowRepeat,
    [string]$RouterPath,
    [string]$RegistryPath,
    [string]$PolicyPath,
    [string]$FlagsPath,
    [string]$ConfigPath,
    [string]$TelemetryPath,
    [switch]$NoTelemetry
)

$ErrorActionPreference = 'Stop'

$v3root = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $v3root)
. (Join-Path $v3root 'lib\CapabilityShadow.ps1')

function Write-ShadowCliError {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Test-ShadowConfinedTelemetry {
    [CmdletBinding()]
    param([string]$Path, [string]$AllowedDir, [string]$Repo)
    try {
        $full = ''
        if ([IO.Path]::IsPathRooted($Path)) { $full = [IO.Path]::GetFullPath($Path) }
        else { $full = [IO.Path]::GetFullPath((Join-Path $Repo $Path)) }
        $base = [IO.Path]::GetFullPath($AllowedDir)
        $sep = $base.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($sep, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    catch { }
    return $false
}

function Test-ShadowPathHasReparsePoint {
    <#
    .SYNOPSIS
        True se o caminho ou QUALQUER ancestor existente for reparse
        point/junction. Replica Test-AuthorityPathHasReparsePoint
        (CapabilityAuthority.ps1): ReparsePoint attribute OR LinkType
        diferente de HardLink. HardLink NAO e reparse (permitido).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = $null
    try { $current = [IO.Path]::GetFullPath($Path) } catch { $current = $Path }
    $guard = 0
    while (-not [string]::IsNullOrWhiteSpace($current) -and $guard -lt 128) {
        $guard++
        if (Test-Path -LiteralPath $current) {
            try {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
                try {
                    $linkType = [string]$item.LinkType
                    if ($item.PSObject.Properties['LinkType'] -and -not [string]::IsNullOrWhiteSpace($linkType) -and $linkType -ine 'HardLink') { return $true }
                } catch { }
            } catch { }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
    return $false
}

function Get-ShadowFullPath {
    param([string]$Path, [string]$Repo)
    try {
        if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
        return [IO.Path]::GetFullPath((Join-Path $Repo $Path))
    }
    catch { return $Path }
}

if ([string]::IsNullOrWhiteSpace($TaskFile)) {
    Write-ShadowCliError 'Uso: shadow-route.ps1 -TaskFile <json> [-TimeoutSeconds 20] [-InProcess] [-AllowRepeat].'
    exit 2
}
if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 60) {
    Write-ShadowCliError 'shadow-route.ps1: -TimeoutSeconds deve estar entre 1 e 60.'
    exit 2
}
$resolvedTelemetry = $TelemetryPath
if (-not [string]::IsNullOrWhiteSpace($resolvedTelemetry) -and -not $NoTelemetry) {
    $allowedTel = Join-Path $repoRoot 'cache\v3\telemetry'
    if (-not (Test-ShadowConfinedTelemetry -Path $resolvedTelemetry -AllowedDir $allowedTel -Repo $repoRoot)) {
        Write-ShadowCliError ("shadow-route.ps1: -TelemetryPath fora de cache\v3\telemetry (negado): {0}" -f $resolvedTelemetry)
        exit 2
    }
    if (Test-ShadowPathHasReparsePoint -Path (Get-ShadowFullPath -Path $resolvedTelemetry -Repo $repoRoot)) {
        Write-ShadowCliError ("shadow-route.ps1: -TelemetryPath com reparse point/junction em ancestor (negado): {0}" -f $resolvedTelemetry)
        exit 2
    }
}

try {
    $params = @{
        TaskFile       = $TaskFile
        TimeoutSeconds = $TimeoutSeconds
        RepoRoot       = $repoRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($RouterPath)) { $params['RouterPath'] = $RouterPath }
    if (-not [string]::IsNullOrWhiteSpace($RegistryPath)) { $params['RegistryPath'] = $RegistryPath }
    if (-not [string]::IsNullOrWhiteSpace($PolicyPath)) { $params['PolicyPath'] = $PolicyPath }
    if (-not [string]::IsNullOrWhiteSpace($FlagsPath)) { $params['FlagsPath'] = $FlagsPath }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $params['ConfigPath'] = $ConfigPath }
    if (-not [string]::IsNullOrWhiteSpace($TelemetryPath)) { $params['TelemetryPath'] = $TelemetryPath }
    if ($NoTelemetry) { $params['NoTelemetry'] = $true }
    if ($RouterProcess) { $params['RouterProcess'] = $true }
    if ($InProcess) { $params['InProcess'] = $true }
    if ($AllowRepeat) { $params['AllowRepeat'] = $true }
    $result = Invoke-CapabilityShadow @params
    Write-Output ($result | ConvertTo-Json -Depth 10)
    exit 0
}
catch {
    try {
        $fallback = [PSCustomObject]@{
            router_version              = '1'
            task_id                     = ''
            proposed_agent              = $null
            proposed_skills             = @()
            proposed_capability_classes = @()
            filters_applied             = @()
            reason                      = 'shadow erro interno contido (fail-safe; sem bloquear)'
            confidence_class            = 'low'
            fallback_used               = $false
            warnings                    = @('shadow unavailable: interno')
            comparison                  = 'NOT_COMPARABLE'
            status                      = 'failed'
            router_latency_ms           = 0
            bridge_overhead_ms          = 0
            deduped                     = $false
        }
        Write-Output ($fallback | ConvertTo-Json -Depth 10)
        exit 0
    }
    catch {
        Write-ShadowCliError 'shadow-route.ps1: falha interna contida.'
        exit 0
    }
}
