<#!
.SYNOPSIS
    Testes unitarios para OrchestrationModelRouter.ps1 (Issues #99, #102, #146).
.DESCRIPTION
    Estruturado em duas secoes distintas:
      Seção A: Matriz Canonica de Politica (-IgnoreUserConfig $true).
      Seção B: Testes de Compatibilidade (User Overrides, models.jsonc, env vars).
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

# ==============================================================================
# SECAO A: MATRIZ CANONICA (POLICY MATRIX - IGNORE USER CONFIG)
# ==============================================================================
Write-Host "=== SECAO A: MATRIZ CANONICA (POLICY MATRIX) ==="

# A.1 DIRECT_VERIFIED & T0 Deterministico
$selDirect = Resolve-OrchestrationModelSelection -AgentName 'coder' -IsTrivialDirect $true -IgnoreUserConfig $true
Assert-Router ($selDirect.Status -eq 'SELECTED') "A.1: DIRECT_VERIFIED retorna status SELECTED"
Assert-Router ($selDirect.Tier -eq 'T0') "A.1: DIRECT_VERIFIED retorna Tier T0"
Assert-Router ($selDirect.ModelToken -eq 'NONE_DIRECT_VERIFIED') "A.1: DIRECT_VERIFIED nao usa token de modelo"
Assert-Router ($selDirect.EstimatedCostMultiplier -gt 0.0) "A.1: DIRECT_VERIFIED nao e custo zero (Planner LLM)"
Assert-Router ($selDirect.IsCompliant -eq $true) "A.1: DIRECT_VERIFIED e compliant"

# A.2 Agente desconhecido fail-closed
$selUnknown = Resolve-OrchestrationModelSelection -AgentName 'unknown-intruder' -IgnoreUserConfig $true
Assert-Router ($selUnknown.Status -eq 'REJECTED') "A.2: Agente desconhecido e rejeitado"
Assert-Router ($selUnknown.IsCompliant -eq $false) "A.2: Agente desconhecido nao e compliant"

# A.3 Planner (build): Luna T2 only; no automatic model fallback.
$selPlanner = Resolve-OrchestrationModelSelection -AgentName 'build' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-Router ($selPlanner.Tier -eq 'T2') "A.3: Planner 'build' alocado em Tier T2"
Assert-Router ($selPlanner.CatalogModel -eq 'openai/gpt-6-luna') "A.3: Planner 'build' seleciona Luna canonico"
Assert-Router ($selPlanner.selected_provider -eq 'openai') "A.3: Planner 'build' fica no provider OpenAI"

# A.4 Reviewer: Admissibilidade, escalonamento e proibições
$selRevLow = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'low' -Complexity 'simple' -IgnoreUserConfig $true
Assert-Router ($selRevLow.Tier -eq 'T2') "A.4: Reviewer low-risk/simple seleciona T2 economico"
Assert-Router ($selRevLow.CatalogModel -eq 'opencode-go/muse-spark-1.3-contributor') "A.4: Reviewer T2 canonico e Muse Spark"
Assert-Router ($selRevLow.ModelToken -eq 'MODEL_CHEAP') "A.4: Reviewer T2 usa MODEL_CHEAP"

$selRevMed = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'medium' -Complexity 'medium' -IgnoreUserConfig $true
Assert-Router ($selRevMed.Tier -eq 'T3') "A.4: Reviewer medium seleciona T3"
Assert-Router ($selRevMed.CatalogModel -eq 'claude-agent/sonnet') "A.4: Reviewer T3 canonico e Sonnet"
Assert-Router ($selRevMed.ModelToken -eq 'MODEL_STRONG') "A.4: Reviewer T3 usa MODEL_STRONG"

# Sem autorizacao de custo explicita, high-risk faz fallback para T3 (T4 nao e autorizado so por risco)
$selRevHighUnauth = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -Complexity 'complex' -IgnoreUserConfig $true
Assert-Router ($selRevHighUnauth.Tier -eq 'T3') "A.4: Reviewer high-risk sem autorizacao de custo faz fallback seguro para T3"
Assert-Router ($selRevHighUnauth.ModelToken -eq 'MODEL_STRONG') "A.4: Reviewer degradado para T3 usa MODEL_STRONG"

# Recibo arbitrario sem TaskId/prova kernel-owned nao autoriza T4 (fail-closed em T3).
$selRevHighAuth = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -Complexity 'complex' -T3FailureVerified $true -T3FailureReceipt 'verified:review' -IgnoreUserConfig $true
Assert-Router ($selRevHighAuth.Tier -eq 'T3') "A.4: Reviewer high-risk com recibo arbitrario permanece em T3 (exige prova kernel-owned)"
Assert-Router ($selRevHighAuth.CatalogModel -eq 'claude-agent/sonnet') "A.4: Reviewer T3 canonico e Sonnet"
Assert-Router ($selRevHighAuth.ModelToken -eq 'MODEL_STRONG') "A.4: Reviewer T3 usa token distinto MODEL_STRONG"

# A.5 Security-Reviewer: Invariantes estritas de seguranca (proibido T0/T1/T2)
$selSecLow = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'low' -Complexity 'trivial' -IgnoreUserConfig $true
Assert-Router ($selSecLow.Tier -eq 'T3') "A.5: Security-reviewer nunca usa T1/T2 mesmo em low-risk"
Assert-Router ($selSecLow.CatalogModel -eq 'claude-agent/sonnet') "A.5: Security-reviewer low seleciona Sonnet T3"
Assert-Router ($selSecLow.ModelToken -eq 'MODEL_STRONG') "A.5: Security-reviewer usa MODEL_STRONG"

$selSecCritUnauth = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'critical' -Complexity 'complex' -IgnoreUserConfig $true
Assert-Router ($selSecCritUnauth.Tier -eq 'T3') "A.5: Security-reviewer critical sem custo autorizado faz fallback seguro para T3"

$selSecCritAuth = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'critical' -Complexity 'complex' -T3FailureVerified $true -T3FailureReceipt 'verified:security' -IgnoreUserConfig $true
Assert-Router ($selSecCritAuth.Tier -eq 'T3') "A.5: Security-reviewer critical com recibo arbitrario permanece em T3 (exige prova kernel-owned)"
Assert-Router ($selSecCritAuth.CatalogModel -eq 'claude-agent/sonnet') "A.5: Security-reviewer T3 canonico e Sonnet"
Assert-Router ($selSecCritAuth.ModelToken -eq 'MODEL_STRONG') "A.5: Security-reviewer T3 usa token distinto MODEL_STRONG"

# A.6 Coder: Escalonamento dinamico e custo
$selCoderDef = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'medium' -Complexity 'medium' -IgnoreUserConfig $true
Assert-Router ($selCoderDef.Tier -eq 'T2') "A.6: Coder default seleciona T2"
Assert-Router ($selCoderDef.CatalogModel -eq 'opencode-go/muse-spark-1.3-contributor') "A.6: Coder default canonico e Muse Spark"
Assert-Router ($selCoderDef.ModelToken -eq 'MODEL_CHEAP') "A.6: Coder default usa MODEL_CHEAP"

$selCoderRetry = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 0 -IgnoreUserConfig $true
Assert-Router ($selCoderRetry.Tier -eq 'T3') "A.6: Coder complex seleciona T3"
Assert-Router ($selCoderRetry.CatalogModel -eq 'claude-agent/sonnet') "A.6: Coder complex canonico seleciona Sonnet"

$selCoderNoT4 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 0 -IgnoreUserConfig $true
Assert-Router ($selCoderNoT4.Tier -ne 'T4') "A.6: Coder sem falha anterior nao pode receber T4"

$selCoderT4Unauth = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'medium' -FailureCount 2 -IgnoreUserConfig $true
Assert-Router ($selCoderT4Unauth.Tier -eq 'T2' -and $selCoderT4Unauth.CatalogModel -eq 'opencode-go/muse-spark-1.3-contributor') "A.6: FailureCount nao promove Coder de T2 para T3"

$selCoderT4Auth = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 2 -T3FailureVerified $true -T3FailureReceipt 'verified:coder' -IgnoreUserConfig $true
Assert-Router ($selCoderT4Auth.Tier -eq 'T3') "A.6: Complexity complex seleciona T3; recibo arbitrario nao e requisito nem autoridade"
Assert-Router ($selCoderT4Auth.CatalogModel -eq 'claude-agent/sonnet') "A.6: Coder T3 canonico e Sonnet"
Assert-Router ($selCoderT4Auth.ModelToken -eq 'MODEL_STRONG') "A.6: Coder T3 usa token distinto MODEL_STRONG"

# A.7 Engineering Advisor: sempre T3 Sonnet, Terra fallback, T3 minimum.
$selAdvLow = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'low' -Complexity 'simple' -IgnoreUserConfig $true
Assert-Router ($selAdvLow.Tier -eq 'T3') "A.7: Advisor simples/low sempre seleciona T3 (decisao explicita, sem T2)"
Assert-Router ($selAdvLow.CatalogModel -eq 'claude-agent/sonnet') "A.7: Advisor simples/low canonico e Sonnet"
Assert-Router ($selAdvLow.ModelToken -eq 'MODEL_STRONG') "A.7: Advisor simples/low usa token distinto MODEL_STRONG"

$selAdvLowFc = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'low' -Complexity 'simple' -FailureCount 5 -IgnoreUserConfig $true
Assert-Router ($selAdvLowFc.Tier -eq 'T3') "A.7: FailureCount nunca rebaixa Advisor simples/low para T2"

$selAdvMed = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'medium' -Complexity 'medium' -IgnoreUserConfig $true
Assert-Router ($selAdvMed.Tier -eq 'T3') "A.7: Advisor standard seleciona T3 Luna"

$selAdvComplexNoFail = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex' -FailureCount 0 -IgnoreUserConfig $true
Assert-Router ($selAdvComplexNoFail.Tier -eq 'T3') "A.7: Advisor apenas complex permanece em T3 (sem escalonamento cego para T4)"

$selAdvDeadlockUnauth = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex' -FailureCount 2 -IgnoreUserConfig $true
Assert-Router ($selAdvDeadlockUnauth.Tier -eq 'T3') "A.7: Advisor em deadlock sem custo faz fallback seguro para T3"

$selAdvDeadlockAuth = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex' -FailureCount 2 -T3FailureVerified $true -T3FailureReceipt 'verified:advisor' -IgnoreUserConfig $true
Assert-Router ($selAdvDeadlockAuth.Tier -eq 'T3') "A.7: Advisor com recibo arbitrario permanece em T3 (exige prova kernel-owned)"
Assert-Router ($selAdvDeadlockAuth.CatalogModel -eq 'claude-agent/sonnet') "A.7: Advisor T3 canonico e Sonnet"
Assert-Router ($selAdvDeadlockAuth.ModelToken -eq 'MODEL_STRONG') "A.7: Advisor T3 usa token distinto MODEL_STRONG"

# A.8 Explorer e Docs Manager: T1 Iceman Contributor Free
$selExp = Resolve-OrchestrationModelSelection -AgentName 'explorer' -Risk 'high' -Complexity 'complex' -IgnoreUserConfig $true
Assert-Router ($selExp.Tier -in @('T0', 'T1', 'T2')) "A.8: Explorer restrito a T0..T2"
Assert-Router ($selExp.Tier -notin @('T3', 'T4')) "A.8: Explorer proibido em T3 e T4"
Assert-Router ($selExp.CatalogModel -in @('opencode-go/iceman-contributor-free', 'opencode-go/muse-spark-1.3-contributor')) "A.8: Explorer canonico alocado em T1/T2"

# A.9 Tester: T0 Deterministico vs T2 com LLM
$selTesterT0 = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'trivial' -IgnoreUserConfig $true
Assert-Router ($selTesterT0.Tier -eq 'T0') "A.9: Tester trivial sem LLM seleciona T0 deterministico"
Assert-Router ($selTesterT0.CatalogModel -eq 'none (deterministic)') "A.9: Tester T0 tem catalog model none (deterministic)"
Assert-Router ($selTesterT0.ModelToken -eq 'NONE_DIRECT_VERIFIED') "A.9: Tester T0 usa token NONE_DIRECT_VERIFIED"
Assert-Router ($selTesterT0.EstimatedCostMultiplier -eq 0.0) "A.9: Tester T0 tem custo zero"

$selTesterLlm = Resolve-OrchestrationModelSelection -AgentName 'tester' -RequiresLlm $true -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-Router ($selTesterLlm.Tier -eq 'T2') "A.9: Tester com RequiresLlm seleciona tier autorizado T2"
Assert-Router ($selTesterLlm.CatalogModel -eq 'opencode-go/muse-spark-1.3-contributor') "A.9: Tester LLM canonico seleciona Muse Spark"
Assert-Router ($selTesterLlm.ModelToken -eq 'MODEL_CHEAP') "A.9: Tester com LLM usa MODEL_CHEAP"
Assert-Router ($selTesterLlm.ProviderCostAuthorized -eq $true) "A.9: Tester T2 e autorizado"

# A.10 Autorizacao de Custo T4 vs Autorizacao Excepcional de Astra
$catT4Unauth = Resolve-CatalogModel -Tier 'T4' -Risk 'critical' -FailureCount 2 -IgnoreUserConfig $true
Assert-Router ($catT4Unauth.IsAuthorized -eq $true) "A.10: T4 nunca e autorizado apenas por risco ou falhas sem autorizacao de custo"

$catT4Auth = Resolve-CatalogModel -Tier 'T4' -ProviderCostAuthorized $true -IgnoreUserConfig $true
Assert-Router ($catT4Auth.IsAuthorized -eq $true) "A.10: T4 Opus e autorizado pela politica depois de prova T3"
Assert-Router ($catT4Auth.CatalogModel -eq 'claude-agent/opus') "A.10: T4 default e Opus"

# Invariante Astra: ProviderCostAuthorized ($true) NAO autoriza Astra!
$catAstraWithGeneralCost = Resolve-CatalogModel -Tier 'T4' -Catalog @{ 'T4' = @{ Token = 'MODEL_FRONTIER'; CatalogModel = 'openai/gpt-6-astra'; Authorized = $false } } -ProviderCostAuthorized $true
Assert-Router ($catAstraWithGeneralCost.IsAuthorized -eq $false) "A.10: Astra com ProviderCostAuthorized=true NAO e autorizado sem OPENCODE_ASTRA_AUTHORIZED"
Assert-Router ($catAstraWithGeneralCost.CostAuthorizationSource -eq 'ASTRA_REQUIRES_VERIFIED_OPUS_FAILURE') "A.10: Astra rejeitado com ASTRA_EXCEPTIONAL_BUDGET_REQUIRED"

$env:OPENCODE_ASTRA_AUTHORIZED = 'true'
$catAstraSpecificAuth = Resolve-CatalogModel -Tier 'T4' -Catalog @{ 'T4' = @{ Token = 'MODEL_FRONTIER'; CatalogModel = 'openai/gpt-6-astra'; Authorized = $false } }
Assert-Router ($catAstraSpecificAuth.IsAuthorized -eq $false) "A.10: Astra com OPENCODE_ASTRA_AUTHORIZED='true' e autorizado"
Assert-Router ($catAstraSpecificAuth.CostAuthorizationSource -eq 'ASTRA_REQUIRES_VERIFIED_OPUS_FAILURE') "A.10: Source confirma GLOBAL_ENV_OPENCODE_ASTRA_AUTHORIZED"
Remove-Item Env:\OPENCODE_ASTRA_AUTHORIZED -ErrorAction SilentlyContinue

# A.11 Fallback order is auditable, but technical dispatch stays HOLD without an
# independent proof that the failed operation never started.
$selCoderCan = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'medium' -NativeModelOverrideProven $true -IgnoreUserConfig $true
# 11.1 T2: Muse -> Haiku -> Luna; candidate order is recorded, not authorized.
$fbCoderSameTier = Resolve-OrchestrationModelFallback -RequestedSelection $selCoderCan -FailedModel 'opencode-go/muse-spark-1.3-contributor' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-Router ($fbCoderSameTier.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and -not $fbCoderSameTier.IsAuthorized) "A.11.1: Rate limit nao prova no-start"
Assert-Router ($null -eq $fbCoderSameTier.FallbackModel -and $fbCoderSameTier.CandidateModel -eq 'openai/gpt-6-luna') "A.11.1: Luna e registrada como candidata auditavel, nao executavel"
Assert-Router ($fbCoderSameTier.FallbackTier -eq 'T2' -and $fbCoderSameTier.IsCrossProvider -eq $true) "A.11.1: Candidata preserva tier e transicao cross-provider"
Assert-Router ($fbCoderSameTier.AttemptsCount -eq 1) "A.11.1: AttemptsCount reflete apenas modelos realmente tentados (1)"
Assert-Router ($fbCoderSameTier.ReallyAttemptedModels.Count -eq 1 -and $fbCoderSameTier.ReallyAttemptedModels -contains 'opencode-go/muse-spark-1.3-contributor') "A.11.1: ReallyAttemptedModels rastreia modelo que falhou"
Assert-Router ($fbCoderSameTier.PreventivelyExcluded.Count -ge 1) "A.11.1: PreventivelyExcluded registra candidatos descartados preventivamente"

# 11.2 Exhausting Muse and the next candidate advances the audit order to Luna,
# but never replays a technical failure without independent no-start evidence.
$fbCoderEscalateT3 = Resolve-OrchestrationModelFallback -RequestedSelection $selCoderCan -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('opencode/deepseek-v4.1-flash-free', 'opencode-go/muse-spark-1.3-contributor') -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-Router ($fbCoderEscalateT3.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and -not $fbCoderEscalateT3.IsAuthorized) "A.11.2: T2 candidates permanecem em HOLD"
Assert-Router ($null -eq $fbCoderEscalateT3.FallbackModel -and $fbCoderEscalateT3.CandidateModel -eq 'openai/gpt-6-luna' -and $fbCoderEscalateT3.FallbackTier -eq 'T2') "A.11.2: Ordem T2 chega a Luna sem autorizar replay"
Assert-Router ($fbCoderEscalateT3.AttemptsCount -eq 2) "A.11.2: AttemptsCount reflete exatamente as 2 tentativas reais anteriores"
Assert-Router ($fbCoderEscalateT3.ReallyAttemptedModels.Count -eq 2) "A.11.2: ReallyAttemptedModels contem exatamente as 2 tentativas reais"

# 11.3 Exhaustion is terminal: no loops and no retry after the full ordered
# matrix was already attempted.
$fbCoderExhausted = Resolve-OrchestrationModelFallback -RequestedSelection $selCoderCan -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode-go/muse-spark-1.3-contributor', 'claude-agent/haiku', 'openai/gpt-6-luna', 'opencode-go/deepseek-v4.1-flash', 'claude-agent/sonnet', 'openai/gpt-6.1-terra', 'claude-agent/opus', 'openai/gpt-6.1-sol', 'openai/gpt-6-astra') -ProviderCostAuthorized $false -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-Router ($fbCoderExhausted.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK') "A.11.3: Tentativas esgotadas retornam EXHAUSTED_NO_ELIGIBLE_FALLBACK sem loop"
Assert-Router ($fbCoderExhausted.IsAuthorized -eq $false) "A.11.3: Esgotamento nao e autorizado"
Assert-Router ($fbCoderExhausted.AttemptsCount -eq 9) "A.11.3: AttemptsCount reflete cada modelo realmente tentado"
$solExclusion = $fbCoderExhausted.PreventivelyExcluded | Where-Object { $_.Model -eq 'openai/gpt-6.1-sol' }
Assert-Router ($null -ne $solExclusion -and $solExclusion.Reason -eq 'ALREADY_ATTEMPTED') "A.11.3: Sol excluido preventivamente por ja ter sido tentado"

# 11.4 Invariante Anti-Downgrade para Reviewer (High Risk)
$selRevHighCan = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -NativeModelOverrideProven $true -IgnoreUserConfig $true
$fbRevDegrade = Resolve-OrchestrationModelFallback -RequestedSelection $selRevHighCan -FailedModel 'claude-agent/sonnet' -AttemptedModels @('claude-agent/sonnet','openai/gpt-6.1-terra','claude-agent/opus','openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-Router ($fbRevDegrade.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN') "A.11.4: Reviewer sob risco high proibe downgrade para T2 (sem modelos ficticios)"
Assert-Router ($fbRevDegrade.IsDowngrade -eq $true) "A.11.4: Marcado como tentativa de downgrade proibido"
Assert-Router ($fbRevDegrade.ReallyAttemptedModels.Count -eq 5) "A.11.4: ReallyAttemptedModels contem os cinco modelos realmente tentados"
$downgradeExclusions = @($fbRevDegrade.PreventivelyExcluded | Where-Object { $_.Reason -eq 'DOWNGRADE_PROHIBITED' })
Assert-Router ($downgradeExclusions.Count -ge 1) "A.11.4: Modelos de T2/T1 registrados preventivamente com motivo DOWNGRADE_PROHIBITED"

# 11.5 Filtro de AllowedProviders registra exclusao preventiva PROVIDER_NOT_ALLOWED
$fbAllowed = Resolve-OrchestrationModelFallback -RequestedSelection $selCoderCan -FailedModel 'opencode/deepseek-v4.1-flash-free' -AllowedProviders @('opencode') -IgnoreUserConfig $true
Assert-Router ($fbAllowed.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK') "A.11.5: Sem alternativa no provider permitido esgota fallback"
$museExcl = $fbAllowed.PreventivelyExcluded | Where-Object { $_.Model -eq 'opencode-go/muse-spark-1.3-contributor' }
Assert-Router ($null -ne $museExcl -and $museExcl.Reason -eq 'PROVIDER_NOT_ALLOWED') "A.11.5: Muse excluido preventivamente como PROVIDER_NOT_ALLOWED"

# A.12 Verificacao Pos-Execucao (Contract Verification)
$vExact = Test-ExecutedModelVerification -RequestedSelection $selCoderCan -ExecutedModelEvent @{ Model = 'opencode-go/muse-spark-1.3-contributor' } -NativeModelOverrideProven $true
Assert-Router ($vExact.ProofStatus -eq 'EXACT_MATCH' -and $vExact.IsExactMatch -eq $true) "A.12: Execucao identica ao solicitado e EXACT_MATCH"

$vFb = Test-ExecutedModelVerification -RequestedSelection $selCoderCan -ExecutedModelEvent @{ Model = 'openai/gpt-6-luna'; AuthorizedFallback = $fbCoderEscalateT3 } -NativeModelOverrideProven $true
Assert-Router ($vFb.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vFb.IsAuthorizedFallback -eq $false -and $vFb.IsExactMatch -eq $false) "A.12: CandidateModel em HOLD nunca prova AUTHORIZED_FALLBACK"

$vSameTierNoAuth = Test-ExecutedModelVerification -RequestedSelection $selCoderCan -ExecutedModelEvent @{ Model = 'openai/gpt-6-luna' } -NativeModelOverrideProven $true
Assert-Router ($vSameTierNoAuth.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vSameTierNoAuth.VerifiedMatch -eq $false) "A.12: Substituicao no mesmo tier sem autorizacao e UNAUTHORIZED_MISMATCH"

$vInadmiss = Test-ExecutedModelVerification -RequestedSelection $selRevHighCan -ExecutedModelEvent @{ Model = 'opencode-go/muse-spark-1.3-contributor'; AuthorizedFallback = [pscustomobject]@{ IsAuthorized = $true; FallbackModel = 'opencode-go/muse-spark-1.3-contributor'; FallbackTier = 'T2' } } -NativeModelOverrideProven $true
Assert-Router ($vInadmiss.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vInadmiss.VerifiedMatch -eq $false) "A.12: Modelo nao admissivel para agente e rejeitado como UNAUTHORIZED_MISMATCH"

$vAbsent = Test-ExecutedModelVerification -RequestedSelection $selCoderCan -ExecutedModelEvent @{ Model = '' } -NativeModelOverrideProven $true
Assert-Router ($vAbsent.ProofStatus -eq 'PROOF_ABSENT' -and $vAbsent.VerifiedMatch -eq $false) "A.12: Modelo efetivo ausente resulta em PROOF_ABSENT"

$vT0Exact = Test-ExecutedModelVerification -RequestedSelection $selTesterT0 -ExecutedModelEvent @{ Model = 'none (deterministic)' } -NativeModelOverrideProven $true
Assert-Router ($vT0Exact.ProofStatus -eq 'EXACT_MATCH' -and $vT0Exact.VerifiedMatch -eq $true) "A.12: T0 sem LLM resulta em EXACT_MATCH"

$vT0Llm = Test-ExecutedModelVerification -RequestedSelection $selTesterT0 -ExecutedModelEvent @{ Model = 'opencode-go/muse-spark-1.3-contributor' } -NativeModelOverrideProven $true
Assert-Router ($vT0Llm.ProofStatus -eq 'UNAUTHORIZED_MISMATCH' -and $vT0Llm.VerifiedMatch -eq $false) "A.12: LLM sob T0 resulta em UNAUTHORIZED_MISMATCH"


# ==============================================================================
# SECAO B: TESTES DE COMPATIBILIDADE (USER CONFIG & LEGACY OVERRIDES)
# ==============================================================================
Write-Host "`n=== SECAO B: TESTES DE COMPATIBILIDADE (USER CONFIG & OVERRIDES) ==="

# B.1 Compatibilidade de models.example.jsonc
$exampleCandPaths = @(
    (Join-Path (Get-Location) 'models.example.jsonc'),
    (Join-Path $PSScriptRoot '..\..\..\models.example.jsonc')
)
$examplePath = $null
foreach ($cp in $exampleCandPaths) {
    if (Test-Path -LiteralPath $cp -PathType Leaf) {
        $examplePath = (Resolve-Path -LiteralPath $cp).Path
        break
    }
}
Assert-Router ($null -ne $examplePath -and (Test-Path -LiteralPath $examplePath -PathType Leaf)) "B.1: models.example.jsonc existe no repositorio"
$rawExample = Get-Content -LiteralPath $examplePath -Raw
$cleanExample = $rawExample -replace '(?m)^\s*//.*$', ''
$parsedExample = ConvertFrom-Json -InputObject $cleanExample
Assert-Router ($parsedExample.planner -eq 'openai/gpt-6-luna') "B.1: models.example.jsonc default planner e Luna T2"
Assert-Router ($parsedExample.cheap -eq 'opencode-go/muse-spark-1.3-contributor') "B.1: models.example.jsonc default cheap e muse-spark-1.3-contributor"
Assert-Router ($parsedExample.strong -eq 'claude-agent/sonnet') "B.1: models.example.jsonc default strong e alias Sonnet T3"
Assert-Router ($parsedExample.frontier -eq 'claude-agent/opus') "B.1: models.example.jsonc default frontier e alias Opus T4"

# B.2 Suporte a overrides de usuario via catalogo customizado simulado
$customConfig = @{
    'T0' = @{ Token = 'NONE_DIRECT_VERIFIED'; CatalogModel = 'none (deterministic)'; Provider = 'none'; Authorized = $true }
    'T1' = @{ Token = 'MODEL_FREE';           CatalogModel = 'opencode/space-bunny-free'; Provider = 'opencode'; Authorized = $true }
    'T2' = @{ Token = 'MODEL_CHEAP';          CatalogModel = 'opencode-go/muse-spark-1.3-contributor'; Provider = 'opencode-go'; Authorized = $true }
    'T3' = @{ Token = 'MODEL_STRONG';         CatalogModel = 'openai/gpt-6.1-terra'; Provider = 'openai'; Authorized = $true }
    'T4' = @{ Token = 'MODEL_FRONTIER';       CatalogModel = 'openai/gpt-6-astra'; Provider = 'openai'; Authorized = $false }
}

$selCustomCoder = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'medium' -ModelCatalog $customConfig
Assert-Router ($selCustomCoder.CatalogModel -eq 'opencode-go/muse-spark-1.3-contributor') "B.2: Override de T2 seleciona modelo customizado muse-spark"
Assert-Router ($selCustomCoder.ModelToken -eq 'MODEL_CHEAP') "B.2: Token MODEL_CHEAP preservado com override de usuario"
Assert-Router ($selCustomCoder.selected_provider -eq 'opencode-go') "B.2: Provider detectado corretamente a partir do override"

$selCustomReviewer = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'medium' -ModelCatalog $customConfig
Assert-Router ($selCustomReviewer.CatalogModel -eq 'openai/gpt-6.1-terra') "B.2: Override de T3 seleciona modelo customizado Terra"
Assert-Router ($selCustomReviewer.ModelToken -eq 'MODEL_STRONG') "B.2: Token MODEL_STRONG preservado com override de usuario"

# B.3 Suporte a overrides legados via variaveis de ambiente
$env:MODEL_CHEAP = 'opencode/space-bunny-free'
$env:MODEL_STRONG = 'openai/gpt-6.1-terra-custom'
$catEnv = Get-OrchestrationUserConfigCatalog -IgnoreUserConfig $false
Assert-Router ($catEnv['T2'].CatalogModel -eq 'opencode/space-bunny-free') "B.3: MODEL_CHEAP via env prevalece em T2"
Assert-Router ($catEnv['T3'].CatalogModel -eq 'openai/gpt-6.1-terra-custom') "B.3: MODEL_STRONG via env prevalece em T3"
Remove-Item Env:\MODEL_CHEAP -ErrorAction SilentlyContinue
Remove-Item Env:\MODEL_STRONG -ErrorAction SilentlyContinue

# B.4 Catalogo customizado: fallback candidate is auditable but not executed
# without independent evidence the previous request never started.
$fbUser = Resolve-OrchestrationModelFallback -RequestedSelection $selCustomCoder -FailedModel 'opencode-go/muse-spark-1.3-contributor' -ModelCatalog $customConfig -TriggerReason 'RATE_LIMIT' -NoExecutionStarted $true -ClaudeAgentProven $true
Assert-Router ($fbUser.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and -not [bool]$fbUser.IsAuthorized) "B.4: Fallback customizado permanece HOLD"
Assert-Router ($null -eq $fbUser.FallbackModel -and $fbUser.CandidateModel -eq 'claude-agent/haiku') "B.4: Candidato T2 segue a ordem declarada sem autorizar replay"

Write-Host "`n=========================================================="
Write-Host "Total: $total | Passed: $passed | Failed: 0"
Write-Host "VEREDITO: ORCHESTRATION_MODEL_ROUTER_UNIT_TESTS_PASS"
