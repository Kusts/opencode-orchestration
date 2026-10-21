<#!
.SYNOPSIS
    Testes unitários para opencode-v2-regression-gate.ps1 (Issues #101 e #146).
.DESCRIPTION
    Valida os gates de regressão de compatibilidade, integridade concorrente,
    backoff bounded para 429 e preservação de recibos.
    Compatível com PowerShell 5.1 e PowerShell 7.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$gateScript = Join-Path $PSScriptRoot 'opencode-v2-regression-gate.ps1'

$passed = 0
$total = 0

function Assert-Gate([bool]$Condition, [string]$Message) {
    $script:total++
    if (-not $Condition) {
        throw "FAIL: $Message"
    }
    $script:passed++
    Write-Host "[PASS] $Message"
}

# 1. Execução Hermética com saída JSON
$rawJson = & $gateScript -Hermetic -AsJson
Assert-Gate (-not [string]::IsNullOrWhiteSpace($rawJson)) "Saída JSON hermética gerada com sucesso"

$report = $rawJson | ConvertFrom-Json
Assert-Gate ($report.gate_version -eq "1.0") "gate_version é 1.0"
Assert-Gate ($report.overall_status -eq "PASS") "overall_status hermético é PASS"

# 2. Verificação individual dos 5 gates
Assert-Gate ($report.gates.G1_DYNAMIC_CAPABILITY_DETECTION.status -eq "PASS") "G1 Dynamic Capability Detection é PASS"
Assert-Gate ($report.gates.G2_ASYNC_CONCURRENCY_INTEGRITY.status -eq "PASS") "G2 Async Concurrency Integrity é PASS"
Assert-Gate ($report.gates.G3_RATE_LIMIT_BOUNDED_BACKOFF.status -eq "PASS") "G3 Rate Limit Bounded Backoff é PASS"
Assert-Gate ($report.gates.G4_REPLAY_SETTLEMENT_IDEMPOTENCY.status -eq "PASS") "G4 Replay Settlement Idempotency é PASS"
Assert-Gate ($report.gates.G5_GIT_PROTECTION_BOUNDARY.status -eq "PASS") "G5 Git Protection Boundary é PASS"

# 3. Verificação da matriz de compatibilidade
Assert-Gate ($report.compatibility_matrix.Count -eq 3) "Matriz cobre exatamente 3 perfis (2.0.23, 2.0.28-2.0.32, 2.1.2)"
$pBaseline = $report.compatibility_matrix | Where-Object { $_.version -eq "2.0.23" }
Assert-Gate ($pBaseline.profile -eq "certified-baseline" -and $pBaseline.status -eq "PASS_CERTIFIED") "2.0.23 é certified-baseline"
$pActive = $report.compatibility_matrix | Where-Object { $_.version -eq "2.1.2" }
Assert-Gate ($pActive.profile -eq "active-host") "2.1.2 é active-host"

# 4. Prova de escrita de evidência durável
$testEvDir = Join-Path $env:TEMP ("gate-ev-" + [Guid]::NewGuid().ToString('N'))
try {
    & $gateScript -Hermetic -EvidenceOutDir $testEvDir
    $evFile = Join-Path $testEvDir 'v2-regression-gate-result.json'
    Assert-Gate (Test-Path -LiteralPath $evFile -PathType Leaf) "Arquivo de evidência gerado em disco"
    $evJson = [System.IO.File]::ReadAllText($evFile) | ConvertFrom-Json
    Assert-Gate ($evJson.overall_status -eq "PASS") "Evidência persistida registra status PASS"
}
finally {
    if (Test-Path -LiteralPath $testEvDir) {
        try { Remove-Item -LiteralPath $testEvDir -Recurse -Force } catch { }
    }
}

Write-Host ""
Write-Host "TEST RESULTS: $passed / $total passed (0 skipped)"
Write-Host "[SUMMARY] pass $passed fail 0"
