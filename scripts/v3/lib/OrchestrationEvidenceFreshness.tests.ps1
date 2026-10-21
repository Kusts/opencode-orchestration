<#!
.SYNOPSIS
    Testes unitários para OrchestrationEvidenceFreshness.ps1 (Issue #106).
.DESCRIPTION
    Valida as regras de frescor de evidência, detecção de head-drift e bloqueio
    de falso DONE com evidências obsoletas.
    Compatível com PowerShell 5.1 e PowerShell 7. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationEvidenceFreshness.ps1')

$passed = 0
$total = 0

function Assert-Freshness([bool]$Condition, [string]$Message) {
    $script:total++
    if (-not $Condition) {
        throw "FAIL: $Message"
    }
    $script:passed++
    Write-Host "[PASS] $Message"
}

$nowIso = "2026-10-21T18:00:00Z"
$headA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
$headB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# 1. Evidência Recente e Coincidente
$evFresh = @{
    head_sha  = $headA
    timestamp = "2026-10-21T17:55:00Z" # 5 min atrás
    type      = "test-verification"
}
$resFresh = Test-OrchestrationEvidenceFreshness -Evidence $evFresh -CurrentHeadSha $headA -MaxAgeSeconds 3600 -NowUtc $nowIso
Assert-Freshness ($resFresh.ok -eq $true) "Evidência recente e no mesmo HEAD é ok=true"
Assert-Freshness ($resFresh.verdict -eq 'fresh') "Verdict é 'fresh'"
Assert-Freshness ($resFresh.refresh_required -eq $false) "refresh_required é false"

# 2. Divergência de HEAD (Head Drift)
$resDrift = Test-OrchestrationEvidenceFreshness -Evidence $evFresh -CurrentHeadSha $headB -MaxAgeSeconds 3600 -NowUtc $nowIso
Assert-Freshness ($resDrift.ok -eq $false) "Evidência com HEAD divergente é ok=false"
Assert-Freshness ($resDrift.verdict -eq 'stale-head-mismatch') "Verdict é 'stale-head-mismatch'"
Assert-Freshness ($resDrift.refresh_required -eq $true) "refresh_required é true para head mismatch"

# 3. Excesso de Idade (Age Exceeded)
$evOld = @{
    head_sha  = $headA
    timestamp = "2026-10-21T12:00:00Z" # 6 horas atrás
    type      = "test-verification"
}
$resOld = Test-OrchestrationEvidenceFreshness -Evidence $evOld -CurrentHeadSha $headA -MaxAgeSeconds 3600 -NowUtc $nowIso
Assert-Freshness ($resOld.ok -eq $false) "Evidência com idade expirada é ok=false"
Assert-Freshness ($resOld.verdict -eq 'stale-age-exceeded') "Verdict é 'stale-age-exceeded'"
Assert-Freshness ($resOld.refresh_required -eq $true) "refresh_required é true para age exceeded"

# 4. Evidência Explicitamente Substituída (Superseded)
$evSuperseded = @{
    head_sha   = $headA
    timestamp  = "2026-10-21T17:59:00Z"
    superseded = $true
}
$resSuperseded = Test-OrchestrationEvidenceFreshness -Evidence $evSuperseded -CurrentHeadSha $headA -MaxAgeSeconds 3600 -NowUtc $nowIso
Assert-Freshness ($resSuperseded.ok -eq $false) "Evidência substituída é ok=false"
Assert-Freshness ($resSuperseded.verdict -eq 'stale-superseded') "Verdict é 'stale-superseded'"

# 5. Evidência Nula ou Inválida
$resNull = Test-OrchestrationEvidenceFreshness -Evidence $null -CurrentHeadSha $headA
Assert-Freshness ($resNull.ok -eq $false -and $resNull.verdict -eq 'invalid-evidence') "Evidência nula retorna invalid-evidence"

# 6. Gate de DONE (Test-OrchestrationDoneAllowedByEvidence)
$emptyDone = Test-OrchestrationDoneAllowedByEvidence -EvidenceItems @()
Assert-Freshness ($emptyDone.allowed -eq $false -and $emptyDone.reason -eq 'no-evidence-provided') "Lista vazia não autoriza DONE"

$mixedItems = @($evFresh, $evOld)
$blockedDone = Test-OrchestrationDoneAllowedByEvidence -EvidenceItems $mixedItems -CurrentHeadSha $headA -MaxAgeSeconds 3600 -NowUtc $nowIso
Assert-Freshness ($blockedDone.allowed -eq $false) "Presença de item stale bloqueia DONE"
Assert-Freshness ($blockedDone.reason -eq 'EVIDENCE_STALE_BLOCKED') "Motivo do bloqueio é EVIDENCE_STALE_BLOCKED"
Assert-Freshness ($blockedDone.stale_items.Count -eq 1) "Exatamente 1 item stale reportado"

$allFreshItems = @($evFresh, @{ head_sha = $headA; timestamp = "2026-10-21T17:50:00Z" })
$allowedDone = Test-OrchestrationDoneAllowedByEvidence -EvidenceItems $allFreshItems -CurrentHeadSha $headA -MaxAgeSeconds 3600 -NowUtc $nowIso
Assert-Freshness ($allowedDone.allowed -eq $true) "Conjunto 100% fresco autoriza DONE"
Assert-Freshness ($allowedDone.reason -eq 'all-evidence-fresh') "Motivo é all-evidence-fresh"

Write-Host ""
Write-Host "TEST RESULTS: $passed / $total passed (0 skipped)"
Write-Host "[SUMMARY] pass $passed fail 0"
