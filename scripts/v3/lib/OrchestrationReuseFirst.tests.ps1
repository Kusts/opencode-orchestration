<#!
.SYNOPSIS
    Testes unitarios para OrchestrationReuseFirst.ps1 (P2, Issues #4, #106, #146).
.DESCRIPTION
    Valida a hierarquia proporcional de reuso: correspondencia exata (T0),
    consulta de contexto em AI Memory, e fallback para reexecucao.
    Compativel com PowerShell 5.1 e PowerShell 7. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationEvidenceFreshness.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationReuseFirst.ps1')

$passed = 0
$total = 0

function Assert-Reuse([bool]$Condition, [string]$Message) {
    $script:total++
    if (-not $Condition) {
        throw "FAIL: $Message"
    }
    $script:passed++
    Write-Host "[PASS] $Message"
}

$tmpStore = Join-Path ([System.IO.Path]::GetTempPath()) ("reuse-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpStore -Force | Out-Null

try {
    $headSha = "1234567890abcdef1234567890abcdef12345678"
    $staleHeadSha = "ffffffffffffffffffffffffffffffffffffffff"

    # Criar uma evidencia valida no store temporario
    $validEv = @{
        task_id   = 'TASK-REUSE-001'
        head_sha  = $headSha
        timestamp = [DateTime]::UtcNow.ToString('o')
        type      = 'test-verification'
        verdict   = 'passed'
    }
    $validEvPath = Join-Path $tmpStore 'evidence-001.json'
    Set-Content -LiteralPath $validEvPath -Value (ConvertTo-Json -InputObject $validEv) -Encoding UTF8

    # 1. Correspondencia exata (T0 - Zero tokens)
    $resExact = Resolve-OrchestrationProportionalReuse -TaskId 'TASK-REUSE-001' -Objective 'Verificar suite' -CurrentHeadSha $headSha -EvidenceStoreDir $tmpStore
    Assert-Reuse ($resExact.Status -eq 'REUSED_EXACT') "Status e REUSED_EXACT para match perfeito"
    Assert-Reuse ($resExact.Tier -eq 'T0') "Reuso exato tem Tier T0"
    Assert-Reuse ($resExact.TokensUsed -eq 0) "Zero tokens gastos em reuso exato"
    Assert-Reuse ($resExact.Strategy -eq 'REUSE_VERIFIED') "Estrategia e REUSE_VERIFIED"

    # 2. Invalidação por Head Drift (Commit diferente)
    $resDrift = Resolve-OrchestrationProportionalReuse -TaskId 'TASK-REUSE-001' -Objective 'Verificar suite' -CurrentHeadSha $staleHeadSha -EvidenceStoreDir $tmpStore
    Assert-Reuse ($resDrift.Status -eq 'REEXECUTION_REQUIRED') "Head drift forca REEXECUTION_REQUIRED"
    Assert-Reuse ($null -eq $resDrift.ReusedEvidence) "Nenhuma evidencia reutilizada apos drift"

    # 3. Consulta consultiva ao AI Memory quando nao ha correspondencia exata
    $probeMem = {
        param($tid, $obj)
        return @("Decisao anterior: manter lock em FileShare.None e tratar IOException.")
    }
    $resMem = Resolve-OrchestrationProportionalReuse -TaskId 'TASK-REUSE-NEW' -Objective 'Nova tarefa sem cache' -CurrentHeadSha $headSha -EvidenceStoreDir $tmpStore -AiMemoryProbe $probeMem
    Assert-Reuse ($resMem.Status -eq 'REEXECUTION_REQUIRED') "Nova tarefa exige reexecucao"
    Assert-Reuse ($resMem.MemoryConsulted -eq $true) "AI Memory consultado como contexto"
    Assert-Reuse ($resMem.MemoryAdvisoryNotes.Count -gt 0) "Notas consultivas recuperadas"

}
finally {
    if (Test-Path -LiteralPath $tmpStore) {
        Remove-Item -LiteralPath $tmpStore -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Total: $total | Passed: $passed | Failed: 0"
