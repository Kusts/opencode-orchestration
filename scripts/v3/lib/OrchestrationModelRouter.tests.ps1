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
Assert-Router ($selDirect.EstimatedCostMultiplier -eq 0.0) "A.1: DIRECT_VERIFIED tem custo zero"
Assert-Router ($selDirect.IsCompliant -eq $true) "A.1: DIRECT_VERIFIED e compliant"

# A.2 Agente desconhecido fail-closed
$selUnknown = Resolve-OrchestrationModelSelection -AgentName 'unknown-intruder' -IgnoreUserConfig $true
Assert-Router ($selUnknown.Status -eq 'REJECTED') "A.2: Agente desconhecido e rejeitado"
Assert-Router ($selUnknown.IsCompliant -eq $false) "A.2: Agente desconhecido nao e compliant"

# A.3 Planner (build): Fixado estritamente em GPT-6 Luna (T3 / openai)
$selPlanner = Resolve-OrchestrationModelSelection -AgentName 'build' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-Router ($selPlanner.Tier -eq 'T3') "A.3: Planner 'build' alocado em Tier T3"
Assert-Router ($selPlanner.CatalogModel -eq 'openai/gpt-6-luna') "A.3: Planner 'build' seleciona GPT-6 Luna canonico"
Assert-Router ($selPlanner.selected_provider -eq 'openai') "A.3: Planner 'build' isolado no provider 'openai'"

# A.4 Reviewer: Admissibilidade, escalonamento e proibições
$selRevLow = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'low' -Complexity 'simple' -IgnoreUserConfig $true
Assert-Router ($selRevLow.Tier -eq 'T2') "A.4: Reviewer low-risk/simple seleciona T2 economico"
Assert-Router ($selRevLow.CatalogModel -eq 'opencode/deepseek-v4.1-flash-free') "A.4: Reviewer T2 canonico e DeepSeek"
Assert-Router ($selRevLow.ModelToken -eq 'MODEL_CHEAP') "A.4: Reviewer T2 usa MODEL_CHEAP"

$selRevMed = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'medium' -Complexity 'medium' -IgnoreUserConfig $true
Assert-Router ($selRevMed.Tier -eq 'T3') "A.4: Reviewer medium seleciona T3"
Assert-Router ($selRevMed.CatalogModel -eq 'openai/gpt-6-luna') "A.4: Reviewer T3 canonico e GPT-6 Luna"
Assert-Router ($selRevMed.ModelToken -eq 'MODEL_STRONG') "A.4: Reviewer T3 usa MODEL_STRONG"

# Sem autorizacao de custo explicita, high-risk faz fallback para T3 (T4 nao e autorizado so por risco)
$selRevHighUnauth = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -Complexity 'complex' -IgnoreUserConfig $true
Assert-Router ($selRevHighUnauth.Tier -eq 'T3') "A.4: Reviewer high-risk sem autorizacao de custo faz fallback seguro para T3"
Assert-Router ($selRevHighUnauth.ModelToken -eq 'MODEL_STRONG') "A.4: Reviewer degradado para T3 usa MODEL_STRONG"

# Com autorizacao explicita de custo, reviewer high-risk recebe T4 Sol
$selRevHighAuth = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -Complexity 'complex' -ProviderCostAuthorized $true -IgnoreUserConfig $true
Assert-Router ($selRevHighAuth.Tier -eq 'T4') "A.4: Reviewer high-risk com autorizacao de custo seleciona T4"
Assert-Router ($selRevHighAuth.CatalogModel -eq 'openai/gpt-6.1-sol') "A.4: Reviewer T4 canonico seleciona GPT-6.1 Sol"
Assert-Router ($selRevHighAuth.ModelToken -eq 'MODEL_FRONTIER') "A.4: Reviewer T4 usa token distinto MODEL_FRONTIER"

# A.5 Security-Reviewer: Invariantes estritas de seguranca (proibido T0/T1/T2)
$selSecLow = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'low' -Complexity 'trivial' -IgnoreUserConfig $true
Assert-Router ($selSecLow.Tier -eq 'T3') "A.5: Security-reviewer nunca usa T1/T2 mesmo em low-risk"
Assert-Router ($selSecLow.CatalogModel -eq 'openai/gpt-6-luna') "A.5: Security-reviewer low seleciona Luna T3"
Assert-Router ($selSecLow.ModelToken -eq 'MODEL_STRONG') "A.5: Security-reviewer usa MODEL_STRONG"

$selSecCritUnauth = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'critical' -Complexity 'complex' -IgnoreUserConfig $true
Assert-Router ($selSecCritUnauth.Tier -eq 'T3') "A.5: Security-reviewer critical sem custo autorizado faz fallback seguro para T3"

$selSecCritAuth = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'critical' -Complexity 'complex' -ProviderCostAuthorized $true -IgnoreUserConfig $true
Assert-Router ($selSecCritAuth.Tier -eq 'T4') "A.5: Security-reviewer critical autorizado seleciona T4 Sol"
Assert-Router ($selSecCritAuth.CatalogModel -eq 'openai/gpt-6.1-sol') "A.5: Security-reviewer T4 canonico seleciona Sol"
Assert-Router ($selSecCritAuth.ModelToken -eq 'MODEL_FRONTIER') "A.5: Security-reviewer T4 usa token distinto MODEL_FRONTIER"

# A.6 Coder: Escalonamento dinamico e custo
$selCoderDef = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'medium' -Complexity 'medium' -IgnoreUserConfig $true
Assert-Router ($selCoderDef.Tier -eq 'T2') "A.6: Coder default seleciona T2"
Assert-Router ($selCoderDef.CatalogModel -eq 'opencode/deepseek-v4.1-flash-free') "A.6: Coder default canonico e DeepSeek Flash Free"
Assert-Router ($selCoderDef.ModelToken -eq 'MODEL_CHEAP') "A.6: Coder default usa MODEL_CHEAP"

$selCoderRetry = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 0 -IgnoreUserConfig $true
Assert-Router ($selCoderRetry.Tier -eq 'T3') "A.6: Coder complex seleciona T3"
Assert-Router ($selCoderRetry.CatalogModel -eq 'openai/gpt-6-luna') "A.6: Coder complex canonico seleciona GPT-6 Luna"

$selCoderNoT4 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 0 -IgnoreUserConfig $true
Assert-Router ($selCoderNoT4.Tier -ne 'T4') "A.6: Coder sem falha anterior nao pode receber T4"

$selCoderT4Unauth = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 2 -IgnoreUserConfig $true
Assert-Router ($selCoderT4Unauth.Tier -eq 'T3') "A.6: Coder com 2 falhas sem autorizacao de custo faz fallback para T3"

$selCoderT4Auth = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 2 -ProviderCostAuthorized $true -IgnoreUserConfig $true
Assert-Router ($selCoderT4Auth.Tier -eq 'T4') "A.6: Coder com 2 falhas e autorizacao de custo escala para T4 Sol"
Assert-Router ($selCoderT4Auth.CatalogModel -eq 'openai/gpt-6.1-sol') "A.6: Coder T4 canonico seleciona Sol"
Assert-Router ($selCoderT4Auth.ModelToken -eq 'MODEL_FRONTIER') "A.6: Coder T4 usa token distinto MODEL_FRONTIER"

# A.7 Engineering Advisor: Escalonamento e autorizacao
$selAdvLow = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'low' -Complexity 'simple' -IgnoreUserConfig $true
Assert-Router ($selAdvLow.Tier -eq 'T2') "A.7: Advisor simples seleciona T2 economico"

$selAdvMed = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'medium' -Complexity 'medium' -IgnoreUserConfig $true
Assert-Router ($selAdvMed.Tier -eq 'T3') "A.7: Advisor standard seleciona T3 Luna"

$selAdvComplexNoFail = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex' -FailureCount 0 -IgnoreUserConfig $true
Assert-Router ($selAdvComplexNoFail.Tier -eq 'T3') "A.7: Advisor apenas complex permanece em T3 (sem escalonamento cego para T4)"

$selAdvDeadlockUnauth = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex' -FailureCount 2 -IgnoreUserConfig $true
Assert-Router ($selAdvDeadlockUnauth.Tier -eq 'T3') "A.7: Advisor em deadlock sem custo faz fallback seguro para T3"

$selAdvDeadlockAuth = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex' -FailureCount 2 -ProviderCostAuthorized $true -IgnoreUserConfig $true
Assert-Router ($selAdvDeadlockAuth.Tier -eq 'T4') "A.7: Advisor em deadlock e custo autorizado escala para T4 Sol"
Assert-Router ($selAdvDeadlockAuth.CatalogModel -eq 'openai/gpt-6.1-sol') "A.7: Advisor T4 canonico seleciona Sol"
Assert-Router ($selAdvDeadlockAuth.ModelToken -eq 'MODEL_FRONTIER') "A.7: Advisor T4 usa token distinto MODEL_FRONTIER"

# A.8 Explorer e Docs Manager: T1 Beam Free
$selExp = Resolve-OrchestrationModelSelection -AgentName 'explorer' -Risk 'high' -Complexity 'complex' -IgnoreUserConfig $true
Assert-Router ($selExp.Tier -in @('T0', 'T1', 'T2')) "A.8: Explorer restrito a T0..T2"
Assert-Router ($selExp.Tier -notin @('T3', 'T4')) "A.8: Explorer proibido em T3 e T4"
Assert-Router ($selExp.CatalogModel -in @('opencode/beam-free', 'opencode/deepseek-v4.1-flash-free')) "A.8: Explorer canonico alocado em T1/T2"

# A.9 Tester: T0 Deterministico vs T2 com LLM
$selTesterT0 = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'trivial' -IgnoreUserConfig $true
Assert-Router ($selTesterT0.Tier -eq 'T0') "A.9: Tester trivial sem LLM seleciona T0 deterministico"
Assert-Router ($selTesterT0.CatalogModel -eq 'none (deterministic)') "A.9: Tester T0 tem catalog model none (deterministic)"
Assert-Router ($selTesterT0.ModelToken -eq 'NONE_DIRECT_VERIFIED') "A.9: Tester T0 usa token NONE_DIRECT_VERIFIED"
Assert-Router ($selTesterT0.EstimatedCostMultiplier -eq 0.0) "A.9: Tester T0 tem custo zero"

$selTesterLlm = Resolve-OrchestrationModelSelection -AgentName 'tester' -RequiresLlm $true -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-Router ($selTesterLlm.Tier -eq 'T2') "A.9: Tester com RequiresLlm seleciona tier autorizado T2"
Assert-Router ($selTesterLlm.CatalogModel -eq 'opencode/deepseek-v4.1-flash-free') "A.9: Tester LLM canonico seleciona DeepSeek"
Assert-Router ($selTesterLlm.ModelToken -eq 'MODEL_CHEAP') "A.9: Tester com LLM usa MODEL_CHEAP"
Assert-Router ($selTesterLlm.ProviderCostAuthorized -eq $true) "A.9: Tester T2 e autorizado"

# A.10 Autorizacao de Custo T4 vs Autorizacao Excepcional de Astra
$catT4Unauth = Resolve-CatalogModel -Tier 'T4' -Risk 'critical' -FailureCount 2 -IgnoreUserConfig $true
Assert-Router ($catT4Unauth.IsAuthorized -eq $false) "A.10: T4 nunca e autorizado apenas por risco ou falhas sem autorizacao de custo"

$catT4Auth = Resolve-CatalogModel -Tier 'T4' -ProviderCostAuthorized $true -IgnoreUserConfig $true
Assert-Router ($catT4Auth.IsAuthorized -eq $true) "A.10: T4 Sol e autorizado sob autorizacao explicita de custo"
Assert-Router ($catT4Auth.CatalogModel -eq 'openai/gpt-6.1-sol') "A.10: T4 default e Sol"

# Invariante Astra: ProviderCostAuthorized ($true) NAO autoriza Astra!
$catAstraWithGeneralCost = Resolve-CatalogModel -Tier 'T4' -Catalog @{ 'T4' = @{ Token = 'MODEL_FRONTIER'; CatalogModel = 'openai/gpt-6-astra'; Authorized = $false } } -ProviderCostAuthorized $true
Assert-Router ($catAstraWithGeneralCost.IsAuthorized -eq $false) "A.10: Astra com ProviderCostAuthorized=true NAO e autorizado sem OPENCODE_ASTRA_AUTHORIZED"
Assert-Router ($catAstraWithGeneralCost.CostAuthorizationSource -eq 'ASTRA_EXCEPTIONAL_BUDGET_REQUIRED') "A.10: Astra rejeitado com ASTRA_EXCEPTIONAL_BUDGET_REQUIRED"

$env:OPENCODE_ASTRA_AUTHORIZED = 'true'
$catAstraSpecificAuth = Resolve-CatalogModel -Tier 'T4' -Catalog @{ 'T4' = @{ Token = 'MODEL_FRONTIER'; CatalogModel = 'openai/gpt-6-astra'; Authorized = $false } }
Assert-Router ($catAstraSpecificAuth.IsAuthorized -eq $true) "A.10: Astra com OPENCODE_ASTRA_AUTHORIZED='true' e autorizado"
Assert-Router ($catAstraSpecificAuth.CostAuthorizationSource -eq 'GLOBAL_ENV_OPENCODE_ASTRA_AUTHORIZED') "A.10: Source confirma GLOBAL_ENV_OPENCODE_ASTRA_AUTHORIZED"
Remove-Item Env:\OPENCODE_ASTRA_AUTHORIZED -ErrorAction SilentlyContinue

# A.11 Fallback Canonico e Rastreamento de Tentativas (Sem candidatos ficticios)
$selCoderCan = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'medium' -NativeModelOverrideProven $true -IgnoreUserConfig $true
# 11.1 Fallback no mesmo tier T2: DeepSeek -> Muse Spark
$fbCoderSameTier = Resolve-OrchestrationModelFallback -RequestedSelection $selCoderCan -FailedModel 'opencode/deepseek-v4.1-flash-free' -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-Router ($fbCoderSameTier.Status -eq 'AUTHORIZED') "A.11.1: Fallback autorizado para Coder sob rate limit"
Assert-Router ($fbCoderSameTier.FallbackModel -eq 'opencode-go/muse-spark-1.3-contributor') "A.11.1: Fallback seleciona Muse Spark (sem candidato ficticio)"
Assert-Router ($fbCoderSameTier.FallbackTier -eq 'T2') "A.11.1: Fallback ocorre dentro do Tier T2"
Assert-Router ($fbCoderSameTier.IsCrossProvider -eq $true) "A.11.1: Transicao cross-provider opencode -> opencode-go rastreada"

# 11.2 Esgotamento do Tier T2 -> Escalonamento para T3 Luna
$fbCoderEscalateT3 = Resolve-OrchestrationModelFallback -RequestedSelection $selCoderCan -FailedModel 'opencode-go/muse-spark-1.3-contributor' -AttemptedModels @('opencode/deepseek-v4.1-flash-free', 'opencode-go/muse-spark-1.3-contributor') -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-Router ($fbCoderEscalateT3.Status -eq 'AUTHORIZED') "A.11.2: Quando T2 se esgota, Coder escala para T3"
Assert-Router ($fbCoderEscalateT3.FallbackModel -eq 'openai/gpt-6-luna') "A.11.2: Escala para GPT-6 Luna canonico"
Assert-Router ($fbCoderEscalateT3.FallbackTier -eq 'T3') "A.11.2: FallbackTier rastreado como T3"

# 11.3 Esgotamento de T2 e T3 sem autorizacao de T4 -> EXHAUSTED_NO_ELIGIBLE_FALLBACK
$fbCoderExhausted = Resolve-OrchestrationModelFallback -RequestedSelection $selCoderCan -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode/deepseek-v4.1-flash-free', 'opencode-go/muse-spark-1.3-contributor', 'openai/gpt-6-luna') -ProviderCostAuthorized $false -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-Router ($fbCoderExhausted.Status -eq 'EXHAUSTED_NO_ELIGIBLE_FALLBACK') "A.11.3: Tentativas esgotadas retornam EXHAUSTED_NO_ELIGIBLE_FALLBACK sem loop"
Assert-Router ($fbCoderExhausted.IsAuthorized -eq $false) "A.11.3: Esgotamento nao e autorizado"

# 11.4 Invariante Anti-Downgrade para Reviewer (High Risk)
$selRevHighCan = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -NativeModelOverrideProven $true -IgnoreUserConfig $true
$fbRevDegrade = Resolve-OrchestrationModelFallback -RequestedSelection $selRevHighCan -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('openai/gpt-6-luna', 'openai/gpt-6.1-sol') -TriggerReason 'RATE_LIMIT' -IgnoreUserConfig $true
Assert-Router ($fbRevDegrade.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN') "A.11.4: Reviewer sob risco high proibe downgrade para T2 (sem modelos ficticios)"
Assert-Router ($fbRevDegrade.IsDowngrade -eq $true) "A.11.4: Marcado como tentativa de downgrade proibido"

# A.12 Verificacao Pos-Execucao (Contract Verification)
$vExact = Test-ExecutedModelVerification -RequestedSelection $selCoderCan -ExecutedModelEvent @{ Model = 'opencode/deepseek-v4.1-flash-free' } -NativeModelOverrideProven $true
Assert-Router ($vExact.ProofStatus -eq 'EXACT_MATCH' -and $vExact.IsExactMatch -eq $true) "A.12: Execucao identica ao solicitado e EXACT_MATCH"

$vFb = Test-ExecutedModelVerification -RequestedSelection $selCoderCan -ExecutedModelEvent @{ Model = 'opencode-go/muse-spark-1.3-contributor'; AuthorizedFallback = $fbCoderSameTier } -NativeModelOverrideProven $true
Assert-Router ($vFb.ProofStatus -eq 'AUTHORIZED_FALLBACK' -and $vFb.IsAuthorizedFallback -eq $true -and $vFb.IsExactMatch -eq $false) "A.12: Fallback autorizado e AUTHORIZED_FALLBACK (nao exact)"

$vSameTierNoAuth = Test-ExecutedModelVerification -RequestedSelection $selCoderCan -ExecutedModelEvent @{ Model = 'opencode-go/muse-spark-1.3-contributor' } -NativeModelOverrideProven $true
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
$examplePath = Join-Path (Get-Location) 'models.example.jsonc'
Assert-Router (Test-Path -LiteralPath $examplePath -PathType Leaf) "B.1: models.example.jsonc existe no repositorio"
$rawExample = Get-Content -LiteralPath $examplePath -Raw
$cleanExample = $rawExample -replace '(?m)^\s*//.*$', ''
$parsedExample = ConvertFrom-Json -InputObject $cleanExample
Assert-Router ($parsedExample.planner -eq 'openai/gpt-6-luna') "B.1: models.example.jsonc default planner e gpt-6-luna"
Assert-Router ($parsedExample.cheap -eq 'opencode/deepseek-v4.1-flash-free') "B.1: models.example.jsonc default cheap e deepseek-v4.1-flash-free"
Assert-Router ($parsedExample.strong -eq 'openai/gpt-6-luna') "B.1: models.example.jsonc default strong e gpt-6-luna"
Assert-Router ($parsedExample.frontier -eq 'openai/gpt-6.1-sol') "B.1: models.example.jsonc default frontier e gpt-6.1-sol"

# B.2 Suporte a overrides de usuario via catalogo customizado simulado
$customConfig = @{
    'T0' = @{ Token = 'NONE_DIRECT_VERIFIED'; CatalogModel = 'none (deterministic)'; Provider = 'none'; Authorized = $true }
    'T1' = @{ Token = 'MODEL_FREE';           CatalogModel = 'opencode/space-bunny-free'; Provider = 'opencode'; Authorized = $true }
    'T2' = @{ Token = 'MODEL_CHEAP';          CatalogModel = 'opencode-go/muse-spark-1.3-contributor'; Provider = 'opencode-go'; Authorized = $true }
    'T3' = @{ Token = 'MODEL_STRONG';         CatalogModel = 'openai/gpt-6.1-sol'; Provider = 'openai'; Authorized = $true }
    'T4' = @{ Token = 'MODEL_FRONTIER';       CatalogModel = 'openai/gpt-6-astra'; Provider = 'openai'; Authorized = $false }
}

$selCustomCoder = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'medium' -ModelCatalog $customConfig
Assert-Router ($selCustomCoder.CatalogModel -eq 'opencode-go/muse-spark-1.3-contributor') "B.2: Override de T2 seleciona modelo customizado muse-spark"
Assert-Router ($selCustomCoder.ModelToken -eq 'MODEL_CHEAP') "B.2: Token MODEL_CHEAP preservado com override de usuario"
Assert-Router ($selCustomCoder.selected_provider -eq 'opencode-go') "B.2: Provider detectado corretamente a partir do override"

$selCustomReviewer = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'medium' -ModelCatalog $customConfig
Assert-Router ($selCustomReviewer.CatalogModel -eq 'openai/gpt-6.1-sol') "B.2: Override de T3 seleciona modelo customizado gpt-6.1-sol"
Assert-Router ($selCustomReviewer.ModelToken -eq 'MODEL_STRONG') "B.2: Token MODEL_STRONG preservado com override de usuario"

# B.3 Suporte a overrides legados via variaveis de ambiente
$env:MODEL_CHEAP = 'opencode/space-bunny-free'
$env:MODEL_STRONG = 'openai/gpt-6.1-sol-legacy'
$catEnv = Get-OrchestrationUserConfigCatalog -IgnoreUserConfig $false
Assert-Router ($catEnv['T2'].CatalogModel -eq 'opencode/space-bunny-free') "B.3: MODEL_CHEAP via env prevalece em T2"
Assert-Router ($catEnv['T3'].CatalogModel -eq 'openai/gpt-6.1-sol-legacy') "B.3: MODEL_STRONG via env prevalece em T3"
Remove-Item Env:\MODEL_CHEAP -ErrorAction SilentlyContinue
Remove-Item Env:\MODEL_STRONG -ErrorAction SilentlyContinue

# B.4 Fallback resiliente com catalogo do usuario integrado
$fbUser = Resolve-OrchestrationModelFallback -RequestedSelection $selCustomCoder -FailedModel 'opencode-go/muse-spark-1.3-contributor' -ModelCatalog $customConfig -TriggerReason 'RATE_LIMIT'
Assert-Router ($fbUser.Status -eq 'AUTHORIZED') "B.4: Fallback sob catalogo customizado e autorizado"
Assert-Router ($fbUser.FallbackModel -in @('opencode/deepseek-v4.1-flash-free', 'openai/gpt-6-luna')) "B.4: Fallback escolhe alternativa valida"

Write-Host "`n=========================================================="
Write-Host "Total: $total | Passed: $passed | Failed: 0"
Write-Host "VEREDITO: ORCHESTRATION_MODEL_ROUTER_UNIT_TESTS_PASS"
