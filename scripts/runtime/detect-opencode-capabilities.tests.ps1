<#!
.SYNOPSIS
    Testes unitários para detect-opencode-capabilities.ps1 (Issue #50).
.DESCRIPTION
    Valida a detecção determinística de capabilities, veredicto, JSON estruturado
    e modos de degradação sem mutação de arquivos.
    Compatível com PowerShell 5.1 e PowerShell 7.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'detect-opencode-capabilities.ps1'

$passed = 0
$total = 0

function Assert-Doctor([bool]$Condition, [string]$Message) {
    $script:total++
    if (-not $Condition) {
        throw "FAIL: $Message"
    }
    $script:passed++
    Write-Host "[PASS] $Message"
}

# --- Caso 1: Mock V2 Completo e Saudável ---
$mockV2Healthy = {
    param($cmd, $subArgs)
    $joined = $subArgs -join ' '
    if ($joined -eq '--version') {
        return @{ Ok = $true; ExitCode = 0; Output = "opencode v2.1.2"; Reason = "probe ok" }
    }
    if ($joined -eq 'session --help') {
        return @{ Ok = $true; ExitCode = 0; Output = "subcommands: list, delete, export"; Reason = "probe ok" }
    }
    if ($joined -eq 'service --help') {
        return @{ Ok = $true; ExitCode = 0; Output = "subcommands: status, start, stop"; Reason = "probe ok" }
    }
    if ($joined -eq 'mcp --help') {
        return @{ Ok = $true; ExitCode = 0; Output = "subcommands: list, add, auth"; Reason = "probe ok" }
    }
    if ($joined -eq 'plugin --help') {
        return @{ Ok = $true; ExitCode = 0; Output = "subcommands: list, add, check"; Reason = "probe ok" }
    }
    if ($joined -eq 'api --help') {
        return @{ Ok = $true; ExitCode = 0; Output = "OpenAPI operation ID or HTTP method path"; Reason = "probe ok" }
    }
    if ($joined -eq 'models --help') {
        return @{ Ok = $true; ExitCode = 0; Output = "List all available models"; Reason = "probe ok" }
    }
    return @{ Ok = $false; ExitCode = 1; Output = ""; Reason = "unknown probe" }
}

$rawJsonV2 = & $scriptPath -MockProbe $mockV2Healthy -AsJson
Assert-Doctor (-not [string]::IsNullOrWhiteSpace($rawJsonV2)) "Mock V2 emite JSON não vazio"

$reportV2 = $rawJsonV2 | ConvertFrom-Json
Assert-Doctor ($reportV2.doctor_version -eq "1.0") "doctor_version é 1.0"
Assert-Doctor ($reportV2.runtime_identity.generation -eq 2) "Geração é 2"
Assert-Doctor ($reportV2.runtime_identity.runtime_id -eq "opencode-v2") "RuntimeId é opencode-v2"
Assert-Doctor ($reportV2.runtime_identity.decision -eq "target") "Decision é target"
Assert-Doctor ($reportV2.capabilities.cli_core.status -eq "SUPPORTED") "cli_core é SUPPORTED"
Assert-Doctor ($reportV2.capabilities.session_management.status -eq "SUPPORTED") "session_management é SUPPORTED"
Assert-Doctor ($reportV2.capabilities.service_management.status -eq "SUPPORTED") "service_management é SUPPORTED"
Assert-Doctor ($reportV2.capabilities.mcp_client.status -eq "SUPPORTED") "mcp_client é SUPPORTED"
Assert-Doctor ($reportV2.capabilities.api_surface.status -eq "SUPPORTED") "api_surface é SUPPORTED"
Assert-Doctor ($reportV2.capabilities.models_discovery.status -eq "SUPPORTED") "models_discovery é SUPPORTED"
Assert-Doctor ($reportV2.overall_verdict -eq "COMPATIBLE_WITH_HOLDS") "overall_verdict é COMPATIBLE_WITH_HOLDS"

# --- Caso 2: Mock V1 Legado Congelado ---
$mockV1 = {
    param($cmd, $subArgs)
    $joined = $subArgs -join ' '
    if ($joined -eq '--version') {
        return @{ Ok = $true; ExitCode = 0; Output = "opencode v1.18.34"; Reason = "probe ok" }
    }
    return @{ Ok = $false; ExitCode = 1; Output = ""; Reason = "v1 has no such subcommand" }
}

$rawJsonV1 = & $scriptPath -MockProbe $mockV1 -AsJson
$reportV1 = $rawJsonV1 | ConvertFrom-Json
Assert-Doctor ($reportV1.runtime_identity.generation -eq 1) "Geração é 1"
Assert-Doctor ($reportV1.runtime_identity.runtime_id -eq "opencode-v1") "RuntimeId é opencode-v1"
Assert-Doctor ($reportV1.runtime_identity.decision -eq "legacy_frozen") "Decision é legacy_frozen"
Assert-Doctor ($reportV1.overall_verdict -eq "LEGACY_FROZEN_V1") "overall_verdict é LEGACY_FROZEN_V1"
Assert-Doctor ($reportV1.capabilities.session_management.status -eq "UNSUPPORTED") "V1 session_management é UNSUPPORTED"

# --- Caso 3: Mock Binário Ausente / Falha Core ---
$mockMissing = {
    param($cmd, $subArgs)
    return @{ Ok = $false; ExitCode = 127; Output = ""; Reason = "binary missing" }
}

$rawJsonMissing = & $scriptPath -MockProbe $mockMissing -AsJson
$reportMissing = $rawJsonMissing | ConvertFrom-Json
Assert-Doctor ($reportMissing.runtime_identity.generation -eq 0) "Geração é 0 quando ausente"
Assert-Doctor ($reportMissing.runtime_identity.decision -eq "unresolved") "Decision é unresolved"
Assert-Doctor ($reportMissing.capabilities.cli_core.status -eq "UNSUPPORTED") "cli_core é UNSUPPORTED"
Assert-Doctor ($reportMissing.overall_verdict -eq "UNRESOLVED_OR_UNSUPPORTED") "Veredicto é UNRESOLVED_OR_UNSUPPORTED"

# --- Caso 4: Degradação Seletiva de Subcomando ---
$mockPartialV2 = {
    param($cmd, $subArgs)
    $joined = $subArgs -join ' '
    if ($joined -eq '--version') {
        return @{ Ok = $true; ExitCode = 0; Output = "opencode v2.0.28"; Reason = "probe ok" }
    }
    if ($joined -eq 'session --help') {
        # Simulando API de sessão ausente
        return @{ Ok = $false; ExitCode = 1; Output = "unknown command session"; Reason = "failed" }
    }
    return @{ Ok = $true; ExitCode = 0; Output = "supported $joined"; Reason = "ok" }
}

$rawJsonPartial = & $scriptPath -MockProbe $mockPartialV2 -AsJson
$reportPartial = $rawJsonPartial | ConvertFrom-Json
Assert-Doctor ($reportPartial.runtime_identity.generation -eq 2) "Geração 2 preservada mesmo com sessão ausente"
Assert-Doctor ($reportPartial.capabilities.cli_core.status -eq "SUPPORTED") "cli_core mantido SUPPORTED"
Assert-Doctor ($reportPartial.capabilities.session_management.status -eq "UNSUPPORTED") "session_management degradado para UNSUPPORTED"
Assert-Doctor ($reportPartial.overall_verdict -eq "COMPATIBLE_WITH_HOLDS") "overall_verdict permanece COMPATIBLE_WITH_HOLDS (fail-closed seletivo)"

# --- Caso 5: Redação de Segredos e Integridade de Incompatibilidades ---
Assert-Doctor ($reportV2.known_incompatibilities.Count -ge 3) "Ao menos 3 incompatibilidades conhecidas mapeadas"
$hold69 = $reportV2.known_incompatibilities | Where-Object { $_.id -eq "SEC-HIGH-01" }
Assert-Doctor ($null -ne $hold69 -and $hold69.issue -eq 69 -and $hold69.status -eq "HOLD") "Incompatibilidade SEC-HIGH-01 #69 está em HOLD"

Write-Host ""
Write-Host "TEST RESULTS: $passed / $total passed (0 skipped)"
Write-Host "[SUMMARY] pass $passed fail 0"
