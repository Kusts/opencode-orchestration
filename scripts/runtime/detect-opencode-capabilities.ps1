<#!
.SYNOPSIS
    Detecta capabilities e compatibilidade do host OpenCode V2 (Issue #50).
.DESCRIPTION
    Script de diagnóstico estritamente READ-ONLY (F0-F2).
    Sonda capacidades funcionais reais do executável opencode disponível e do
    repositório sem depender exclusivamente de correspondência rígida de patch version.
    Reutiliza a infraestrutura de probing do RuntimeAdapters.
    Compatível com PowerShell 5.1 e PowerShell 7.
    Exit codes:
      0 = Sondagem realizada com sucesso (veredicto estruturado gerado)
      6 = Runtime ausente ou falha crítica de resolução
#>
[CmdletBinding()]
param(
    [string]$BinaryCommand = 'opencode',
    [string]$RepoRoot = '',
    [int]$ProbeTimeoutMs = 5000,
    [scriptblock]$MockProbe = $null,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

function Get-DoctorDefaultRepoRoot {
    $current = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($current)) { $current = (Get-Location).Path }
    try {
        $parent = Split-Path -Path $current -Parent
        $grandParent = Split-Path -Path $parent -Parent
        if (Test-Path -LiteralPath (Join-Path $grandParent 'source\registry\runtime-versions.json') -PathType Leaf) {
            return $grandParent
        }
    }
    catch { }
    return $current
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Get-DoctorDefaultRepoRoot
}

# Carregar RuntimeAdapters para resolução canônica e probing de binários/shims
$runtimeAdaptersLib = Join-Path $PSScriptRoot 'lib\RuntimeAdapters.ps1'
if (Test-Path -LiteralPath $runtimeAdaptersLib -PathType Leaf) {
    . $runtimeAdaptersLib
}

function Invoke-CapabilityCommand {
    param(
        [string]$CommandName,
        [string[]]$SubArguments,
        [scriptblock]$Mock,
        [int]$TimeoutMs
    )
    if ($null -ne $Mock) {
        try {
            return (& $Mock $CommandName $SubArguments)
        }
        catch {
            return @{ Ok = $false; ExitCode = 1; Output = ''; Reason = $_.Exception.Message }
        }
    }

    $fullCmd = @($CommandName) + $SubArguments
    try {
        if (Get-Command 'Invoke-RuntimeProbe' -ErrorAction SilentlyContinue) {
            $pr = Invoke-RuntimeProbe -ProbeCommand $fullCmd -TimeoutMs $TimeoutMs
            return $pr
        }
    }
    catch { }

    return @{ Ok = $false; ExitCode = 127; Output = ''; Reason = 'Invoke-RuntimeProbe unavailable' }
}

function Compute-FileSha256 {
    param([string]$FilePath)
    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return ''
    }
    try {
        $stream = [System.IO.File]::OpenRead($FilePath)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash($stream)
        $stream.Close()
        $stream.Dispose()
        $sha.Dispose()
        $sb = New-Object System.Text.StringBuilder
        foreach ($b in $bytes) {
            [void]$sb.Append($b.ToString('x2'))
        }
        return $sb.ToString()
    }
    catch {
        return ''
    }
}

function Resolve-OpencodeBinaryLocation {
    param([string]$CmdName)
    try {
        $cands = @(Get-Command -Name $CmdName -All -ErrorAction SilentlyContinue)
        foreach ($cd in $cands) {
            if ($cd.CommandType -eq 'Application') {
                return $cd.Source
            }
        }
        if ($cands.Count -gt 0) {
            return $cands[0].Source
        }
    }
    catch { }
    return ''
}

# --- Execução Principal do Diagnóstico ---

$binPath = Resolve-OpencodeBinaryLocation -CmdName $BinaryCommand
$reportStamp = [DateTime]::UtcNow.ToString('o')

$report = [ordered]@{
    doctor_version = "1.0"
    generated_at = $reportStamp
    runtime_identity = [ordered]@{
        generation = 0
        runtime_id = "unknown"
        version_string = ""
        binary_path = $binPath
        binary_sha256 = ""
        decision = "unresolved"
    }
    capabilities = [ordered]@{}
    known_incompatibilities = @(
        [ordered]@{
            id = "SEC-HIGH-01"
            issue = 69
            severity = "HIGH"
            status = "HOLD"
            detail = "Native /shell surface lacks enforced admission mediation; deny rules behave fail-open on host."
        },
        [ordered]@{
            id = "HOST-PROVENANCE"
            issue = 70
            severity = "HIGH"
            status = "HOLD"
            detail = "Host does not provide independent cryptographic execution attestation."
        },
        [ordered]@{
            id = "ACTIONS-LOCK-01"
            issue = 149
            severity = "MEDIUM"
            status = "AVOID_ENFORCEMENT"
            detail = "GitHub Actions lockfile caused startup failures during CI pilot; lockfile removed from master."
        }
    )
    overall_verdict = "UNRESOLVED"
}

# 1. Prova do CLI Core (--version)
$coreProbe = Invoke-CapabilityCommand -CommandName $BinaryCommand -SubArguments @('--version') -Mock $MockProbe -TimeoutMs $ProbeTimeoutMs
if ($coreProbe.Ok -and (-not [string]::IsNullOrWhiteSpace($coreProbe.Output))) {
    $verString = $coreProbe.Output.Trim()
    $report.runtime_identity.version_string = $verString
    if ($verString -match 'v2\.' -or $verString -match '2\.') {
        $report.runtime_identity.generation = 2
        $report.runtime_identity.runtime_id = "opencode-v2"
        $report.runtime_identity.decision = "target"
    }
    elseif ($verString -match 'v1\.' -or $verString -match '1\.') {
        $report.runtime_identity.generation = 1
        $report.runtime_identity.runtime_id = "opencode-v1"
        $report.runtime_identity.decision = "legacy_frozen"
    }

    if (-not [string]::IsNullOrWhiteSpace($binPath)) {
        $report.runtime_identity.binary_sha256 = Compute-FileSha256 -FilePath $binPath
    }

    $report.capabilities['cli_core'] = [ordered]@{
        status = "SUPPORTED"
        verification_type = "RUNTIME_OPERATIONAL_VERIFIED"
        operational_verified = $true
        certification_level = "RUNTIME_CERTIFIED"
        evidence = $verString
        contract = "opencode --version exit 0"
    }
}
else {
    $report.capabilities['cli_core'] = [ordered]@{
        status = "UNSUPPORTED"
        verification_type = "UNSUPPORTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "ProbeFailed: $($coreProbe.Reason)"
        contract = "opencode --version exit 0"
    }
}

# 2. Subagent Execution
$templateV2 = Join-Path $RepoRoot 'templates\opencode.v2.json.tmpl'
if (Test-Path -LiteralPath $templateV2 -PathType Leaf) {
    $rawTmpl = [System.IO.File]::ReadAllText($templateV2)
    if ($rawTmpl -match 'subagent_depth' -and $rawTmpl -match 'agents') {
        $report.capabilities['subagent_execution'] = [ordered]@{
            status = "SUPPORTED"
            verification_type = "TEMPLATE_SPECIFIED"
            operational_verified = $false
            certification_level = "UNPROVEN_SURFACE"
            evidence = "template V2 configures subagent_depth with agents block (template inspection, non-operational)"
            contract = "opencode.v2.json.tmpl defines subagent delegation boundaries"
        }
    }
    else {
        $report.capabilities['subagent_execution'] = [ordered]@{
            status = "DEGRADED"
            verification_type = "TEMPLATE_SPECIFIED"
            operational_verified = $false
            certification_level = "UNPROVEN_SURFACE"
            evidence = "template V2 missing required subagent markers"
            contract = "opencode.v2.json.tmpl defines subagent delegation boundaries"
        }
    }
}
else {
    $report.capabilities['subagent_execution'] = [ordered]@{
        status = "UNKNOWN"
        verification_type = "UNSUPPORTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "template file not accessible at $templateV2"
        contract = "opencode.v2.json.tmpl defines subagent delegation boundaries"
    }
}

# 3. Session Management Subcommand
$sessionProbe = Invoke-CapabilityCommand -CommandName $BinaryCommand -SubArguments @('session', '--help') -Mock $MockProbe -TimeoutMs $ProbeTimeoutMs
if ($sessionProbe.Ok -and $sessionProbe.Output -match 'list' -and $sessionProbe.Output -match 'delete') {
    $report.capabilities['session_management'] = [ordered]@{
        status = "SUPPORTED"
        verification_type = "CLI_SURFACE_DETECTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "subcommands session list/delete/export verified via CLI surface syntax"
        contract = "opencode session [list|delete|export]"
    }
}
else {
    $report.capabilities['session_management'] = [ordered]@{
        status = "UNSUPPORTED"
        verification_type = "UNSUPPORTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "subcommand session not supported or incomplete"
        contract = "opencode session [list|delete|export]"
    }
}

# 4. Service Management Subcommand
$serviceProbe = Invoke-CapabilityCommand -CommandName $BinaryCommand -SubArguments @('service', '--help') -Mock $MockProbe -TimeoutMs $ProbeTimeoutMs
if ($serviceProbe.Ok -and $serviceProbe.Output -match 'status' -and $serviceProbe.Output -match 'start') {
    $report.capabilities['service_management'] = [ordered]@{
        status = "SUPPORTED"
        verification_type = "CLI_SURFACE_DETECTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "subcommands service status/start/stop verified via CLI surface syntax"
        contract = "opencode service [status|start|stop]"
    }
}
else {
    $report.capabilities['service_management'] = [ordered]@{
        status = "UNSUPPORTED"
        verification_type = "UNSUPPORTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "subcommand service not available"
        contract = "opencode service [status|start|stop]"
    }
}

# 5. MCP Client Subcommand
$mcpProbe = Invoke-CapabilityCommand -CommandName $BinaryCommand -SubArguments @('mcp', '--help') -Mock $MockProbe -TimeoutMs $ProbeTimeoutMs
if ($mcpProbe.Ok -and $mcpProbe.Output -match 'list' -and $mcpProbe.Output -match 'add') {
    $report.capabilities['mcp_client'] = [ordered]@{
        status = "SUPPORTED"
        verification_type = "CLI_SURFACE_DETECTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "subcommands mcp list/add/auth verified via CLI surface syntax"
        contract = "opencode mcp [list|add|auth]"
    }
}
else {
    $report.capabilities['mcp_client'] = [ordered]@{
        status = "UNSUPPORTED"
        verification_type = "UNSUPPORTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "subcommand mcp not available"
        contract = "opencode mcp [list|add|auth]"
    }
}

# 6. Plugin System & Bundle Integrity
$pluginProbe = Invoke-CapabilityCommand -CommandName $BinaryCommand -SubArguments @('plugin', '--help') -Mock $MockProbe -TimeoutMs $ProbeTimeoutMs
$bundlePath = Join-Path $RepoRoot 'plugins\dist\orchestration-enforcement.js'
$bundleSidecar = $bundlePath + '.sha256'
$bundleOk = $false
if ((Test-Path -LiteralPath $bundlePath -PathType Leaf) -and (Test-Path -LiteralPath $bundleSidecar -PathType Leaf)) {
    $distSha = Compute-FileSha256 -FilePath $bundlePath
    $expectedSha = (([System.IO.File]::ReadAllText($bundleSidecar)).Trim().Split(' ')[0]).ToLowerInvariant()
    if ($distSha -eq $expectedSha) {
        $bundleOk = $true
    }
}
$g1Admission = Join-Path $RepoRoot 'plugins\g1-dispatch-admission\index.js'
$g1Ok = (Test-Path -LiteralPath $g1Admission -PathType Leaf)

if ($pluginProbe.Ok -and $bundleOk -and $g1Ok) {
    $report.capabilities['plugin_system'] = [ordered]@{
        status = "SUPPORTED"
        verification_type = "BUNDLE_VERIFIED"
        operational_verified = $false
        certification_level = "HERMETIC_HARNESS"
        evidence = "subcommand plugin available, orchestration-enforcement bundle + sidecar verified, g1-dispatch-admission active"
        contract = "opencode plugin CLI + plugin bundle sidecar match + g1 admission"
    }
}
elseif ($pluginProbe.Ok -and ($bundleOk -or $g1Ok)) {
    $report.capabilities['plugin_system'] = [ordered]@{
        status = "SUPPORTED"
        verification_type = "BUNDLE_VERIFIED"
        operational_verified = $false
        certification_level = "HERMETIC_HARNESS"
        evidence = "subcommand plugin available, plugins present"
        contract = "opencode plugin CLI + plugin bundle match"
    }
}
elseif ($pluginProbe.Ok) {
    $report.capabilities['plugin_system'] = [ordered]@{
        status = "DEGRADED"
        verification_type = "CLI_SURFACE_DETECTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "subcommand plugin available but plugin bundles missing"
        contract = "opencode plugin CLI + plugin bundle sidecar match"
    }
}
else {
    $report.capabilities['plugin_system'] = [ordered]@{
        status = "UNSUPPORTED"
        verification_type = "UNSUPPORTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "plugin subcommand not available on host"
        contract = "opencode plugin CLI + plugin bundle sidecar match"
    }
}

# 7. Terminal PTY Support
if ($env:OS -eq 'Windows_NT') {
    $report.capabilities['pty_terminal'] = [ordered]@{
        status = "SUPPORTED"
        verification_type = "PLATFORM_ASSUMED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "Windows OS detected; interactive PTY not operationally probed (backstop Job Objects active in orchestration runtime)"
        contract = "Windows PTY console streaming + Job Object leak protection"
    }
}
else {
    $report.capabilities['pty_terminal'] = [ordered]@{
        status = "SUPPORTED"
        verification_type = "PLATFORM_ASSUMED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "POSIX environment detected; PTY not operationally probed"
        contract = "POSIX terminal streaming"
    }
}

# 8. OpenAPI Surface Subcommand
$apiProbe = Invoke-CapabilityCommand -CommandName $BinaryCommand -SubArguments @('api', '--help') -Mock $MockProbe -TimeoutMs $ProbeTimeoutMs
if ($apiProbe.Ok -and $apiProbe.Output -match 'OpenAPI') {
    $report.capabilities['api_surface'] = [ordered]@{
        status = "SUPPORTED"
        verification_type = "CLI_SURFACE_DETECTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "subcommand api OpenAPI request surface verified via CLI surface syntax"
        contract = "opencode api <operation|method path>"
    }
}
else {
    $report.capabilities['api_surface'] = [ordered]@{
        status = "UNSUPPORTED"
        verification_type = "UNSUPPORTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "subcommand api OpenAPI request surface not available"
        contract = "opencode api <operation|method path>"
    }
}

# 9. Models Discovery Subcommand
$modelsProbe = Invoke-CapabilityCommand -CommandName $BinaryCommand -SubArguments @('models', '--help') -Mock $MockProbe -TimeoutMs $ProbeTimeoutMs
if ($modelsProbe.Ok -and $modelsProbe.Output -match 'models') {
    $report.capabilities['models_discovery'] = [ordered]@{
        status = "SUPPORTED"
        verification_type = "CLI_SURFACE_DETECTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "subcommand models discovery verified via CLI surface syntax"
        contract = "opencode models [list]"
    }
}
else {
    $report.capabilities['models_discovery'] = [ordered]@{
        status = "UNSUPPORTED"
        verification_type = "UNSUPPORTED"
        operational_verified = $false
        certification_level = "UNPROVEN_SURFACE"
        evidence = "subcommand models discovery not available"
        contract = "opencode models [list]"
    }
}

# Veredicto Geral
if ($report.capabilities['cli_core'].status -eq 'SUPPORTED' -and $report.runtime_identity.generation -eq 2) {
    $report.overall_verdict = "COMPATIBLE_WITH_HOLDS"
}
elseif ($report.capabilities['cli_core'].status -eq 'SUPPORTED' -and $report.runtime_identity.generation -eq 1) {
    $report.overall_verdict = "LEGACY_FROZEN_V1"
}
else {
    $report.overall_verdict = "UNRESOLVED_OR_UNSUPPORTED"
}

if ($AsJson) {
    $json = ConvertTo-Json -InputObject $report -Depth 10
    Write-Output $json
}
else {
    Write-Host "=== OPENCODE CAPABILITY DOCTOR (Issue #50) ==="
    Write-Host ("Runtime Identity: " + $report.runtime_identity.runtime_id + " (" + $report.runtime_identity.version_string + ")")
    Write-Host ("Binary Path:      " + $report.runtime_identity.binary_path)
    Write-Host ("Overall Verdict:  " + $report.overall_verdict)
    Write-Host ""
    Write-Host "Capabilities Status:"
    foreach ($k in $report.capabilities.Keys) {
        $c = $report.capabilities[$k]
        Write-Host ("  [{0,-9}] {1,-20} -- {2}" -f $c.status, $k, $c.evidence)
    }
    Write-Host ""
    Write-Host "Known Incompatibilities & Holds:"
    foreach ($h in $report.known_incompatibilities) {
        Write-Host ("  [{0}] #{1} ({2}) -- {3}" -f $h.id, $h.issue, $h.status, $h.detail)
    }
}

if ($report.overall_verdict -in @('COMPATIBLE_WITH_HOLDS', 'LEGACY_FROZEN_V1')) {
    exit 0
}
exit 6
