<#!
.SYNOPSIS
    Testes unitarios para OrchestrationModelRouter.ps1 (Issues #99, #102, #146).
.DESCRIPTION
    Valida a selecao dinamica de tiers T0..T4, matriz de admissibilidade dos 19 agentes,
    invariantes de seguranca e fallback fail-closed.
    Compativel com PowerShell 5.1 e PowerShell 7. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')

$passed = 0
$total = 0

function Assert-Router([bool]$Condition, [string]$Message) {
    $script:total++
    if (-not $Condition) {
        throw "FAIL: $Message"
    }
    $script:passed++
    Write-Host "[PASS] $Message"
}

# 1. DIRECT_VERIFIED & T0
$sel = Resolve-OrchestrationModelSelection -AgentName 'coder' -IsTrivialDirect $true
Assert-Router ($sel.Status -eq 'SELECTED') "DIRECT_VERIFIED retorna status SELECTED"
Assert-Router ($sel.Tier -eq 'T0') "DIRECT_VERIFIED retorna Tier T0"
Assert-Router ($sel.ModelToken -eq 'NONE_DIRECT_VERIFIED') "DIRECT_VERIFIED nao usa token de modelo"
Assert-Router ($sel.EstimatedCostMultiplier -eq 0.0) "DIRECT_VERIFIED tem custo zero"
Assert-Router ($sel.IsCompliant -eq $true) "DIRECT_VERIFIED e compliant"

# 2. Agente desconhecido
$selUnknown = Resolve-OrchestrationModelSelection -AgentName 'unknown-intruder'
Assert-Router ($selUnknown.Status -eq 'REJECTED') "Agente desconhecido e rejeitado"
Assert-Router ($selUnknown.IsCompliant -eq $false) "Agente desconhecido nao e compliant"

# 3. Reviewer: admissibilidade e escalonamento
$selRevLow = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'low' -Complexity 'simple'
Assert-Router ($selRevLow.Tier -eq 'T2') "Reviewer low-risk/simple seleciona T2 economico"
Assert-Router ($selRevLow.ModelToken -eq 'MODEL_CHEAP') "Reviewer T2 usa MODEL_CHEAP"

$selRevMed = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'medium' -Complexity 'medium'
Assert-Router ($selRevMed.Tier -eq 'T3') "Reviewer medium seleciona T3"
Assert-Router ($selRevMed.ModelToken -eq 'MODEL_STRONG') "Reviewer T3 usa MODEL_STRONG"

# Sem autorizacao de custo explicita, high-risk faz fallback para T3 (T4 nao e autorizado so por risco)
$selRevHighUnauth = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -Complexity 'complex'
Assert-Router ($selRevHighUnauth.Tier -eq 'T3') "Reviewer high-risk sem autorizacao de custo faz fallback seguro para T3"
Assert-Router ($selRevHighUnauth.ModelToken -eq 'MODEL_STRONG') "Reviewer degradado para T3 usa MODEL_STRONG"

# Com autorizacao explicita de custo, reviewer high-risk recebe T4 com token MODEL_FRONTIER
$selRevHighAuth = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -Complexity 'complex' -ProviderCostAuthorized $true
Assert-Router ($selRevHighAuth.Tier -eq 'T4') "Reviewer high-risk com autorizacao de custo seleciona T4"
Assert-Router ($selRevHighAuth.ModelToken -eq 'MODEL_FRONTIER') "Reviewer T4 usa token distinto MODEL_FRONTIER"

# 4. Security Reviewer: invariantes de seguranca
$selSecLow = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'low' -Complexity 'trivial'
Assert-Router ($selSecLow.Tier -eq 'T3') "Security-reviewer nunca usa T1/T2 mesmo em low-risk"
Assert-Router ($selSecLow.ModelToken -eq 'MODEL_STRONG') "Security-reviewer usa MODEL_STRONG"

$selSecCritUnauth = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'critical' -Complexity 'complex'
Assert-Router ($selSecCritUnauth.Tier -eq 'T3') "Security-reviewer critical sem autorizacao de custo faz fallback seguro para T3"

$selSecCritAuth = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'critical' -Complexity 'complex' -ProviderCostAuthorized $true
Assert-Router ($selSecCritAuth.Tier -eq 'T4') "Security-reviewer critical autorizado seleciona T4"
Assert-Router ($selSecCritAuth.ModelToken -eq 'MODEL_FRONTIER') "Security-reviewer T4 usa token distinto MODEL_FRONTIER"

# 5. Coder: escalonamento e invariante de custo
$selCoderDef = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'medium' -Complexity 'medium'
Assert-Router ($selCoderDef.Tier -eq 'T2') "Coder default seleciona T2"
Assert-Router ($selCoderDef.ModelToken -eq 'MODEL_CHEAP') "Coder default usa MODEL_CHEAP"

$selCoderRetry = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 0
Assert-Router ($selCoderRetry.Tier -eq 'T3') "Coder complex seleciona T3"

$selCoderNoT4 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 0
Assert-Router ($selCoderNoT4.Tier -ne 'T4') "Coder sem falha anterior nao pode receber T4"

$selCoderT4Unauth = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 2
Assert-Router ($selCoderT4Unauth.Tier -eq 'T3') "Coder com 2 falhas sem autorizacao de custo faz fallback para T3"

$selCoderT4Auth = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 2 -ProviderCostAuthorized $true
Assert-Router ($selCoderT4Auth.Tier -eq 'T4') "Coder com 2 falhas e autorizacao de custo escala para T4"
Assert-Router ($selCoderT4Auth.ModelToken -eq 'MODEL_FRONTIER') "Coder T4 usa token distinto MODEL_FRONTIER"

# 6. Engineering Advisor: escalonamento dinamico
$selAdvLow = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'low' -Complexity 'simple'
Assert-Router ($selAdvLow.Tier -eq 'T2') "Advisor simples seleciona T2 economico"

$selAdvMed = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'medium' -Complexity 'medium'
Assert-Router ($selAdvMed.Tier -eq 'T3') "Advisor standard seleciona T3"

$selAdvComplexNoFail = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex' -FailureCount 0
Assert-Router ($selAdvComplexNoFail.Tier -eq 'T3') "Advisor apenas com rotulo complex permanece em T3 (sem escalonamento cego para T4)"

$selAdvDeadlockUnauth = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex' -FailureCount 2
Assert-Router ($selAdvDeadlockUnauth.Tier -eq 'T3') "Advisor com deadlock sem autorizacao de custo faz fallback seguro para T3"

$selAdvDeadlockAuth = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex' -FailureCount 2 -ProviderCostAuthorized $true
Assert-Router ($selAdvDeadlockAuth.Tier -eq 'T4') "Advisor com deadlock e autorizacao de custo escala para T4"
Assert-Router ($selAdvDeadlockAuth.ModelToken -eq 'MODEL_FRONTIER') "Advisor T4 usa token distinto MODEL_FRONTIER"

# 7. Explorer: limites estritos
$selExp = Resolve-OrchestrationModelSelection -AgentName 'explorer' -Risk 'high' -Complexity 'complex'
Assert-Router ($selExp.Tier -in @('T0', 'T1', 'T2')) "Explorer restrito a T0..T2"
Assert-Router ($selExp.Tier -notin @('T3', 'T4')) "Explorer proibido em T3 e T4"

# 8. Tratamento de flag de override nativo e PROOF_ABSENT
$selNoProof = Resolve-OrchestrationModelSelection -AgentName 'coder' -NativeModelOverrideProven $false
Assert-Router ($selNoProof.ProofStatus -eq 'PROOF_ABSENT') "ProofStatus e PROOF_ABSENT quando override e unproven"
Assert-Router ($selNoProof.RuntimeTierProven -eq $false) "RuntimeTierProven e false quando override e unproven"
Assert-Router ($selNoProof.OverrideNote -match 'unproven') "Nota de fallback quando override e unproven"

$selProof = Resolve-OrchestrationModelSelection -AgentName 'coder' -NativeModelOverrideProven $true
Assert-Router ($selProof.ProofStatus -eq 'PROVEN') "ProofStatus e PROVEN quando override e comprovado"
Assert-Router ($selProof.RuntimeTierProven -eq $true) "RuntimeTierProven e true quando comprovado"
Assert-Router ($selProof.OverrideNote -eq '') "Sem nota quando override e proven"

# 9. Resolucao por catalogo e selecao autorizada
$catT2 = Resolve-CatalogModel -Tier 'T2'
Assert-Router ($catT2.CatalogModel -in @('opencode-go/muse-spark-1.3-contributor', 'openai/gpt-6-luna')) "Catalogo mapeia T2 para modelo economico"
Assert-Router ($catT2.IsAuthorized -eq $true) "T2 e autorizado por padrao"

$catT4Unauth = Resolve-CatalogModel -Tier 'T4' -Risk 'critical' -FailureCount 2
Assert-Router ($catT4Unauth.IsAuthorized -eq $false) "T4 nunca e autorizado apenas por risco ou falhas sem autorizacao de custo"

$catT4Auth = Resolve-CatalogModel -Tier 'T4' -ProviderCostAuthorized $true
Assert-Router ($catT4Auth.IsAuthorized -eq $true) "T4 e autorizado sob autorizacao explicita de custo"

# 10. Verificacao do modelo efetivamente executado
$verifAbsent = Test-ExecutedModelVerification -RequestedSelection $selNoProof -NativeModelOverrideProven $false
Assert-Router ($verifAbsent.ProofStatus -eq 'PROOF_ABSENT') "Verificacao sem override nativo retorna PROOF_ABSENT"

$verifMatch = Test-ExecutedModelVerification -RequestedSelection $selProof -ExecutedModelEvent @{ Model = $selProof.CatalogModel } -NativeModelOverrideProven $true
Assert-Router ($verifMatch.VerifiedMatch -eq $true) "Verificacao confirma match exato do modelo executado"
Assert-Router ($verifMatch.ProofStatus -in @('EXACT_MATCH', 'VERIFIED_MATCH')) "ProofStatus EXACT_MATCH comprovado"

$verifMismatch = Test-ExecutedModelVerification -RequestedSelection $selProof -ExecutedModelEvent @{ Model = 'other-unauthorized-model' } -NativeModelOverrideProven $true
Assert-Router ($verifMismatch.VerifiedMatch -eq $false) "Verificacao detecta modelo divergente"
Assert-Router ($verifMismatch.ProofStatus -in @('UNAUTHORIZED_MISMATCH', 'TIER_MISMATCH')) "ProofStatus UNAUTHORIZED_MISMATCH registrado"

# 11. Tester: Invariante T0 (sem LLM) vs T2 autorizado (com LLM) e verificacao
$selTesterT0 = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'trivial'
Assert-Router ($selTesterT0.Tier -eq 'T0') "Tester trivial sem LLM seleciona T0 deterministico"
Assert-Router ($selTesterT0.CatalogModel -eq 'none (deterministic)') "Tester T0 tem catalog model none (deterministic)"
Assert-Router ($selTesterT0.ModelToken -eq 'NONE_DIRECT_VERIFIED') "Tester T0 usa token NONE_DIRECT_VERIFIED"
Assert-Router ($selTesterT0.EstimatedCostMultiplier -eq 0.0) "Tester T0 tem custo zero"

$selTesterLlm = Resolve-OrchestrationModelSelection -AgentName 'tester' -RequiresLlm $true -NativeModelOverrideProven $true
Assert-Router ($selTesterLlm.Tier -eq 'T2') "Tester com RequiresLlm seleciona tier autorizado T2"
Assert-Router ($selTesterLlm.ModelToken -eq 'MODEL_CHEAP') "Tester com LLM usa MODEL_CHEAP"
Assert-Router ($selTesterLlm.ProviderCostAuthorized -eq $true) "Tester T2 e autorizado"

$selTesterMed = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'medium'
Assert-Router ($selTesterMed.Tier -eq 'T2') "Tester medium seleciona tier autorizado T2"

$verifTesterMatch = Test-ExecutedModelVerification -RequestedSelection $selTesterLlm -ExecutedModelEvent @{ model = $selTesterLlm.CatalogModel } -NativeModelOverrideProven $true
Assert-Router ($verifTesterMatch.VerifiedMatch -eq $true) "Executed model match para tester LLM retorna true"
Assert-Router ($verifTesterMatch.ProofStatus -in @('EXACT_MATCH', 'VERIFIED_MATCH')) "Executed model match para tester retorna EXACT_MATCH"

$verifT0Mismatch = Test-ExecutedModelVerification -RequestedSelection $selTesterT0 -ExecutedModelEvent @{ model = 'opencode-go/muse-spark-1.3-contributor' } -NativeModelOverrideProven $true
Assert-Router ($verifT0Mismatch.VerifiedMatch -eq $false) "Tester T0 com modelo LLM executado resulta em UNAUTHORIZED_MISMATCH"
Assert-Router ($verifT0Mismatch.ProofStatus -in @('UNAUTHORIZED_MISMATCH', 'TIER_MISMATCH')) "Tester T0 rejeita execucao LLM como UNAUTHORIZED_MISMATCH"

# 12. P0-01 e P0-02: Testes obrigatorios de Fallback Autorizado e Verificacao de Modelo
# 12.1 Modelo solicitado igual ao efetivo -> EXACT_MATCH
$vExact = Test-ExecutedModelVerification -RequestedSelection $selProof -ExecutedModelEvent @{ Model = $selProof.CatalogModel } -NativeModelOverrideProven $true
Assert-Router ($vExact.ProofStatus -eq 'EXACT_MATCH' -and $vExact.IsExactMatch -eq $true) "P0-01: Modelo solicitado igual ao efetivo e EXACT_MATCH"

# 12.2 Modelo diferente, mas com fallback autorizado pelo Router -> AUTHORIZED_FALLBACK
$fbCoder = Resolve-OrchestrationModelFallback -RequestedSelection $selProof -FailedModel $selProof.CatalogModel -TriggerReason 'RATE_LIMIT'
Assert-Router ($fbCoder.Status -eq 'AUTHORIZED' -and $fbCoder.IsAuthorized -eq $true) "P0-02: Fallback autorizado para Coder sob rate limit"
$vFb = Test-ExecutedModelVerification -RequestedSelection $selProof -ExecutedModelEvent @{ Model = $fbCoder.FallbackModel; AuthorizedFallback = $fbCoder } -NativeModelOverrideProven $true
Assert-Router ($vFb.ProofStatus -eq 'AUTHORIZED_FALLBACK' -and $vFb.IsAuthorizedFallback -eq $true -and $vFb.IsExactMatch -eq $false) "P0-01: Modelo diferente com fallback autorizado e AUTHORIZED_FALLBACK (nao exact)"

# 12.3 Modelo do mesmo tier sem autorizacao de substituicao -> UNAUTHORIZED_MISMATCH (nunca exact match!)
$altModelNoAuth = if ($selProof.CatalogModel -eq 'opencode-go/muse-spark-1.3-contributor') { 'openai/gpt-6-luna' } else { 'opencode-go/muse-spark-1.3-contributor' }
$vSameTierNoAuth = Test-ExecutedModelVerification -RequestedSelection $selProof -ExecutedModelEvent @{ Model = $altModelNoAuth } -NativeModelOverrideProven $true
Assert-Router ($vSameTierNoAuth.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vSameTierNoAuth.VerifiedMatch -eq $false) "P0-01: Modelo do mesmo tier sem autorizacao e UNAUTHORIZED_MISMATCH"

# 12.4 Modelo nao admissivel para o agente (downgrade proibido de Reviewer/Security-Reviewer)
$selRevHigh = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -NativeModelOverrideProven $true
$fbRevDegrade = Resolve-OrchestrationModelFallback -RequestedSelection $selRevHigh -FailedModel $selRevHigh.CatalogModel -AttemptedModels @('opencode-custom/strong-model') -TriggerReason 'RATE_LIMIT'
Assert-Router ($fbRevDegrade.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN') "P0-02: Reviewer sob risco high proibe downgrade para T2"
$fakeFb = [pscustomobject]@{ IsAuthorized = $true; FallbackModel = 'opencode-go/muse-spark-1.3-contributor'; FallbackTier = 'T2'; TriggerReason = 'RATE_LIMIT' }
$vInadmiss = Test-ExecutedModelVerification -RequestedSelection $selRevHigh -ExecutedModelEvent @{ Model = 'opencode-go/muse-spark-1.3-contributor'; AuthorizedFallback = $fakeFb } -NativeModelOverrideProven $true
Assert-Router ($vInadmiss.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vInadmiss.VerifiedMatch -eq $false) "P0-01: Modelo nao admissivel para agente e rejeitado como UNAUTHORIZED_MISMATCH"

# 12.5 Modelo efetivo ausente -> PROOF_ABSENT
$vAbsent = Test-ExecutedModelVerification -RequestedSelection $selProof -ExecutedModelEvent @{ Model = '' } -NativeModelOverrideProven $true
Assert-Router ($vAbsent.ProofStatus -eq 'PROOF_ABSENT' -and $vAbsent.VerifiedMatch -eq $false) "P0-01: Modelo efetivo ausente resulta em PROOF_ABSENT"

# 12.6 Modelo T4 sem autorizacao aplicavel -> UNAUTHORIZED_MISMATCH
$fbT4NoAuth = [pscustomobject]@{ IsAuthorized = $true; FallbackModel = 'openai/gpt-6.1-sol-fast'; FallbackTier = 'T4'; ProviderCostAuthorized = $false; TriggerReason = 'DEADLOCK' }
$vT4NoAuth = Test-ExecutedModelVerification -RequestedSelection $selProof -ExecutedModelEvent @{ Model = 'openai/gpt-6.1-sol-fast'; AuthorizedFallback = $fbT4NoAuth } -NativeModelOverrideProven $true
Assert-Router ($vT4NoAuth.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vT4NoAuth.VerifiedMatch -eq $false) "P0-01: T4 sem autorizacao de custo e UNAUTHORIZED_MISMATCH"

# 12.7 Modelo T0 sem LLM -> EXACT_MATCH
$vT0Exact = Test-ExecutedModelVerification -RequestedSelection $selTesterT0 -ExecutedModelEvent @{ Model = 'none (deterministic)' } -NativeModelOverrideProven $true
Assert-Router ($vT0Exact.ProofStatus -eq 'EXACT_MATCH' -and $vT0Exact.VerifiedMatch -eq $true) "P0-01: T0 sem LLM resulta em EXACT_MATCH"

# 12.8 Tentativa de registrar uma LLM como T0 -> UNAUTHORIZED_MISMATCH
$vT0Llm = Test-ExecutedModelVerification -RequestedSelection $selTesterT0 -ExecutedModelEvent @{ Model = 'opencode-go/muse-spark-1.3-contributor' } -NativeModelOverrideProven $true
Assert-Router ($vT0Llm.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vT0Llm.VerifiedMatch -eq $false) "P0-01: LLM como T0 resulta em UNAUTHORIZED_MISMATCH"

Write-Host "Total: $total | Passed: $passed | Failed: 0"
