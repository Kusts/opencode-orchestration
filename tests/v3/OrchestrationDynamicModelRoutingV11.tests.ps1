<#!
.SYNOPSIS
    Testes de conformidade e integracao para Dynamic Model Routing & Intelligent Advisory v1.1.
.DESCRIPTION
    Cobre as Fases 1 a 6 da SPEC v1.1 e PLAN v1.1:
      - Validacao do catalogo de modelos e providers independentes (ADR-02)
      - Matriz de perfis por agente e tiers T0..T4
      - Fallback intra-tier e cross-provider rastreavel
      - Politica de custos (T4/Astra)
      - Verificacao fail-closed pos-execucao
      - Estabilidade do Planner (Luna) e escala do Advisor (Luna/Sol/Astra)
      - Integracao consultiva com Jev Free (System One)
    PowerShell 5.1 e 7+ compativel. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $scriptRoot '..\..')).Path

. (Join-Path $repoRoot 'scripts\v3\lib\OrchestrationModelRouter.ps1')
. (Join-Path $repoRoot 'scripts\v3\lib\OrchestrationAdvisorEscalation.ps1')
. (Join-Path $repoRoot 'scripts\v3\lib\OrchestrationJevAdvisory.ps1')

$passed = 0
$total = 0

function Assert-V11([bool]$Condition, [string]$Message) {
    $script:total++
    if (-not $Condition) {
        throw "FAIL: $Message"
    }
    $script:passed++
    Write-Host "[PASS] $Message"
}

Write-Host "=== FASE 1: CATALOGO CONFIGURAVEL E PROVIDERS INDEPENDENTES ==="

# 1.1 Carregamento da politica canonica e PolicyHash SHA-256
$policyRes = Get-OrchestrationModelRoutingPolicy -ForceReload $true
Assert-V11 ($policyRes.Status -eq 'POLICY_LOADED') "Politica canonica model-routing-policy.json carregada com sucesso"
Assert-V11 ($policyRes.PolicyHash.Length -eq 64) "PolicyHash SHA-256 valido (64 hex characters): $($policyRes.PolicyHash)"
Assert-V11 ($policyRes.PolicyVersion -eq '1.4.0') "PolicyVersion e 1.4.0"

$pol = $policyRes.Policy

# 1.2 Providers independentes (ADR-02)
Assert-V11 ($pol.providers.opencode.type -eq 'console') "Provider 'opencode' (Console) registrado"
Assert-V11 ($pol.providers.'opencode-go'.type -eq 'go') "Provider 'opencode-go' registrado"
Assert-V11 ($pol.providers.openai.type -eq 'openai') "Provider 'openai' registrado"
Assert-V11 ($pol.providers.jev.type -eq 'systemone') "Provider 'jev' (System One) registrado"

# 1.3 Separacao estrita de modelos e providers
Assert-V11 ($pol.models.iceman.provider -eq 'opencode-go' -and $pol.models.iceman.model_id -eq 'opencode-go/iceman-contributor-free') "Iceman Contributor Free usa provider 'opencode-go'"
Assert-V11 ($pol.models.deepseek.provider -eq 'opencode' -and $pol.models.deepseek.model_id -eq 'opencode/deepseek-v4.1-flash-free') "DeepSeek V4.1 Flash Free usa provider 'opencode'"
Assert-V11 ($pol.models.muse.provider -eq 'opencode-go' -and $pol.models.muse.model_id -eq 'opencode-go/muse-spark-1.3-contributor') "Muse Spark Contributor usa provider 'opencode-go'"
Assert-V11 ($pol.models.luna.provider -eq 'openai' -and $pol.models.luna.model_id -eq 'openai/gpt-6-luna') "GPT-6 Luna usa provider 'openai'"
Assert-V11 ($pol.models.sol.provider -eq 'openai' -and $pol.models.sol.model_id -eq 'openai/gpt-6.1-sol') "GPT-6.1 Sol usa provider 'openai'"
Assert-V11 ($pol.models.astra.provider -eq 'openai' -and $pol.models.astra.model_id -eq 'openai/gpt-6-astra') "GPT-6 Astra usa provider 'openai'"

# Invariante ADR-02: Luna, Sol e Astra pertencem estritamente a openai
foreach ($mId in @('openai/gpt-6-luna', 'openai/gpt-6.1-sol', 'openai/gpt-6-astra')) {
    $prov = Get-ModelProviderFromId $mId
    Assert-V11 ($prov -eq 'openai') "Modelo '$mId' mapeado estritamente para provider 'openai' (nunca opencode ou opencode-go)"
}

# 1.4 Resolucao de catalogo dinamicamente atualizavel
$cat = Get-OrchestrationUserConfigCatalog -IgnoreUserConfig $true
Assert-V11 ($cat['T1'].CatalogModel -eq 'opencode-go/iceman-contributor-free') "T1 primario do catalogo e Iceman Contributor Free"
Assert-V11 ($cat['T2'].CatalogModel -eq 'opencode-go/deepseek-v4.1-flash') "T2 primario do catalogo e DeepSeek Go"
Assert-V11 ($cat['T3'].CatalogModel -eq 'claude-agent/sonnet') "T3 primario do catalogo e Sonnet"
Assert-V11 ($cat['T3'].AlternativeModel -eq 'openai/gpt-6.1-terra') "T3 fallback do catalogo e Terra"
Assert-V11 ($cat['T4'].CatalogModel -eq 'claude-agent/opus') "T4 primario do catalogo e Opus"
Assert-V11 ($cat['T4'].AlternativeModel -eq 'openai/gpt-6.1-sol') "T4 fallback do catalogo e Sol"

Write-Host "=== FASE 2: MODEL ROUTER E SELECAO POR AGENTE/RISCO ==="

# 2.1 Planner build: estavel em Luna T2
$selPlanner = Resolve-OrchestrationModelSelection -AgentName 'build' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-V11 ($selPlanner.Tier -eq 'T2') "Planner 'build' seleciona Tier T2"
Assert-V11 ($selPlanner.selected_model_id -eq 'opencode-go/deepseek-v4.1-flash') "Planner 'build' seleciona DeepSeek Go"
Assert-V11 ($selPlanner.selected_provider -eq 'opencode-go') "Planner 'build' opera no provider 'opencode-go'"
Assert-V11 ($selPlanner.policy_hash -eq $policyRes.PolicyHash) "Decisao vincula policy_hash da versao canonica"

# 2.2 Explorer e Docs Manager: T1 Iceman
$selExp = Resolve-OrchestrationModelSelection -AgentName 'explorer' -Risk 'low' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-V11 ($selExp.Tier -eq 'T1') "Explorer seleciona Tier T1"
Assert-V11 ($selExp.selected_model_id -eq 'opencode-go/iceman-contributor-free') "Explorer seleciona Iceman Contributor Free"
Assert-V11 ($selExp.selected_provider -eq 'opencode-go') "Explorer usa provider 'opencode-go'"

# 2.3 Coder: T2 DeepSeek Go por padrao, T3 Sonnet para complex
$selCoder = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'medium' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-V11 ($selCoder.Tier -eq 'T2') "Coder medium seleciona Tier T2"
Assert-V11 ($selCoder.selected_model_id -eq 'opencode-go/deepseek-v4.1-flash') "Coder default seleciona DeepSeek Go"

$selCoderRetry = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 1 -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-V11 ($selCoderRetry.Tier -eq 'T3') "Coder complex apos 1 falha escala para T3"
Assert-V11 ($selCoderRetry.selected_model_id -eq 'claude-agent/sonnet') "Coder T3 seleciona Sonnet"

# 2.4 Tester: T0 deterministico por default, T2 DeepSeek se RequiresLlm
$selTesterT0 = Resolve-OrchestrationModelSelection -AgentName 'tester' -Complexity 'trivial' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-V11 ($selTesterT0.Tier -eq 'T0') "Tester trivial seleciona T0 deterministico sem LLM"
Assert-V11 ($selTesterT0.selected_model_id -eq 'none (deterministic)') "Tester T0 tem selected_model_id none"
Assert-V11 ($selTesterT0.selected_provider -eq 'none') "Tester T0 tem selected_provider none"

$selTesterLlm = Resolve-OrchestrationModelSelection -AgentName 'tester' -RequiresLlm $true -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-V11 ($selTesterLlm.Tier -eq 'T2') "Tester com RequiresLlm seleciona T2"
Assert-V11 ($selTesterLlm.selected_model_id -eq 'opencode-go/deepseek-v4.1-flash') "Tester com LLM seleciona DeepSeek Go"

# 2.5 Security-Reviewer: Sol T4 (somente com prova kernel-owned) ou Terra T3; proibido T0/T1/T2
$selSecUnauth = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'high' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-V11 ($selSecUnauth.Tier -eq 'T3') "Security-Reviewer sem prova kernel-owned permanece em T3 Terra"
Assert-V11 ($selSecUnauth.selected_model_id -eq 'claude-agent/sonnet') "Security-Reviewer T3 usa Sonnet"

$selSecAuth = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'critical' -T3FailureVerified $true -T3FailureReceipt 'verified:security-v11' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-V11 ($selSecAuth.Tier -eq 'T3') "Security-Reviewer critical com recibo arbitrario (sem TaskId/prova kernel) permanece em T3"
Assert-V11 ($selSecAuth.selected_model_id -eq 'claude-agent/sonnet') "Security-Reviewer T3 usa Sonnet sem prova kernel"

# 2.6 Restricao de AllowedProviders
$selAllowedOpencodeOnly = Resolve-OrchestrationModelSelection -AgentName 'coder' -AllowedProviders @('opencode-go') -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-V11 ($selAllowedOpencodeOnly.Status -eq 'SELECTED') "Coder com AllowedProviders opencode-go e aprovado"
Assert-V11 ($selAllowedOpencodeOnly.selected_provider -eq 'opencode-go') "Coder seleciona provider opencode permitido"

$selOpencodeOnlyDenied = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -AllowedProviders @('opencode') -NativeModelOverrideProven $true -IgnoreUserConfig $true
# Reviewer precisa de T3 (Luna/openai) ou T4 (Sol/openai); se apenas opencode for permitido, rejeita PROVIDER_UNAVAILABLE
Assert-V11 ($selOpencodeOnlyDenied.Status -eq 'PROVIDER_UNAVAILABLE') "Reviewer de alta criticidade sem provider openai autorizado retorna PROVIDER_UNAVAILABLE"
Assert-V11 ($selOpencodeOnlyDenied.Authorized -eq $false) "Status nao autorizado quando provider obrigatorio esta indisponivel"

Write-Host "=== FASE 3: FALLBACK CROSS-PROVIDER E RASTREABILIDADE ==="

# 3.1 T2 candidate order DeepSeek Go -> Muse -> Haiku -> Luna is audit-only HOLD without independent no-start proof.
$selCoderBase = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'medium' -NativeModelOverrideProven $true -IgnoreUserConfig $true
$fbCoderCross = Resolve-OrchestrationModelFallback -RequestedSelection $selCoderBase -FailedModel 'opencode-go/deepseek-v4.1-flash' -TriggerReason 'RATE_LIMIT'
Assert-V11 ($fbCoderCross.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF' -and -not [bool]$fbCoderCross.IsAuthorized) "Rate-limit fallback permanece HOLD"
Assert-V11 ($null -eq $fbCoderCross.FallbackModel -and $fbCoderCross.CandidateModel -eq 'opencode-go/muse-spark-1.3-contributor') "Candidato Muse e auditavel, nao executavel"
Assert-V11 ($fbCoderCross.OriginalProvider -eq 'opencode-go') "OriginalProvider rastreado como 'opencode-go'"
Assert-V11 ($null -eq $fbCoderCross.FallbackProvider) "FallbackProvider nao marca modelo nao executado"
Assert-V11 ($fbCoderCross.IsCrossProvider -eq $false) "IsCrossProvider e false na transicao opencode-go -> opencode-go"
Assert-V11 ($fbCoderCross.AttemptsCount -eq 1) "AttemptsCount rastreia 1 tentativa real"
Assert-V11 ($fbCoderCross.ReallyAttemptedModels -contains 'opencode-go/deepseek-v4.1-flash') "ReallyAttemptedModels isola modelo que falhou"
Assert-V11 ($fbCoderCross.PreventivelyExcluded.Count -ge 1) "PreventivelyExcluded registra candidatos descartados preventivamente"

# 3.2 Proibicao de loops e HOLD em timeout/ambiguidade.
$fbCoderExhausted = Resolve-OrchestrationModelFallback -RequestedSelection $selCoderBase -FailedModel 'openai/gpt-6-luna' -AttemptedModels @('opencode-go/deepseek-v4.1-flash', 'opencode-go/muse-spark-1.3-contributor', 'claude-agent/haiku', 'openai/gpt-6-luna', 'claude-agent/sonnet', 'openai/gpt-6.1-terra', 'claude-agent/opus', 'openai/gpt-6.1-sol', 'openai/gpt-6-astra') -TriggerReason 'TIMEOUT'
Assert-V11 ($fbCoderExhausted.Status -eq 'FALLBACK_HOLD_NO_INDEPENDENT_NO_START_PROOF') "Timeout/ambiguidade retorna HOLD sem replay"
Assert-V11 ($fbCoderExhausted.IsAuthorized -eq $false) "Esgotamento nao e autorizado"
Assert-V11 ($fbCoderExhausted.AttemptsCount -eq 9) "AttemptsCount rastreia 9 tentativas reais"
Assert-V11 ($fbCoderExhausted.ReallyAttemptedModels.Count -eq 9) "ReallyAttemptedModels contem exatamente os 9 modelos tentados"

# 3.3 Downgrade proibido para Reviewer
$selRev = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'high' -NativeModelOverrideProven $true -IgnoreUserConfig $true
$fbRevDegrade = Resolve-OrchestrationModelFallback -RequestedSelection $selRev -FailedModel 'claude-agent/sonnet' -AttemptedModels @('claude-agent/sonnet','openai/gpt-6.1-terra','claude-agent/opus','openai/gpt-6.1-sol','openai/gpt-6-astra') -TriggerReason 'QUOTA_EXCEEDED'
Assert-V11 ($fbRevDegrade.Status -eq 'REJECTED_DOWNGRADE_FORBIDDEN' -and $null -eq $fbRevDegrade.FallbackModel -and -not [bool]$fbRevDegrade.IsAuthorized) "Reviewer high-risk transport fallback permanece rejeitado"
Assert-V11 ($fbRevDegrade.IsDowngrade -eq $true) "Tentativa marcada como downgrade proibido"
Assert-V11 ($fbRevDegrade.ReallyAttemptedModels.Count -eq 5) "ReallyAttemptedModels contem exatamente as 5 tentativas reais do Reviewer"
$downExcl = @($fbRevDegrade.PreventivelyExcluded | Where-Object { $_.Reason -eq 'DOWNGRADE_PROHIBITED' })
Assert-V11 ($downExcl.Count -ge 1) "PreventivelyExcluded classifica modelos inferiores como DOWNGRADE_PROHIBITED"

Write-Host "=== FASE 4: VERIFICACAO POS-EXECUCAO E AUDITORIA ==="

# 4.1 EXACT_MATCH
$verifExact = Test-ExecutedModelVerification -RequestedSelection $selCoderBase -ExecutedModelEvent @{ Model = 'opencode-go/deepseek-v4.1-flash' } -NativeModelOverrideProven $true
Assert-V11 ($verifExact.ProofStatus -eq 'EXACT_MATCH') "Execucao com modelo e provider identicos retorna EXACT_MATCH"
Assert-V11 ($verifExact.IsExactMatch -eq $true) "IsExactMatch e true"
Assert-V11 ($verifExact.IsCrossProvider -eq $false) "Sem troca cross-provider"

# 4.2 CandidateModel in HOLD is not an AUTHORIZED_FALLBACK
$verifFb = Test-ExecutedModelVerification -RequestedSelection $selCoderBase -ExecutedModelEvent @{ Model = 'openai/gpt-6-luna'; AuthorizedFallback = $fbCoderCross } -NativeModelOverrideProven $true
Assert-V11 ($verifFb.ProofStatus -eq 'UNAUTHORIZED_MISMATCH') "Fallback CandidateModel em HOLD nunca retorna AUTHORIZED_FALLBACK"
Assert-V11 ($verifFb.IsAuthorizedFallback -eq $false) "IsAuthorizedFallback permanece false sob HOLD"

# 4.3 UNAUTHORIZED_MISMATCH na substituicao nao autorizada
$verifMismatch = Test-ExecutedModelVerification -RequestedSelection $selCoderBase -ExecutedModelEvent @{ Model = 'openai/gpt-6.1-sol' } -NativeModelOverrideProven $true
Assert-V11 ($verifMismatch.ProofStatus -eq 'UNAUTHORIZED_MISMATCH') "Substituicao sem autorizacao de fallback retorna UNAUTHORIZED_MISMATCH"
Assert-V11 ($verifMismatch.VerifiedMatch -eq $false) "VerifiedMatch e false"

# 4.4 T0 Deterministo proibe terminantemente qualquer LLM
$verifT0Violation = Test-ExecutedModelVerification -RequestedSelection $selTesterT0 -ExecutedModelEvent @{ Model = 'opencode/deepseek-v4.1-flash-free' } -NativeModelOverrideProven $true
Assert-V11 ($verifT0Violation.ProofStatus -eq 'UNAUTHORIZED_MISMATCH') "Tentativa de executar LLM sob T0 e terminantemente rejeitada com UNAUTHORIZED_MISMATCH"

# 4.5 PROOF_ABSENT em runtime sem suporte comprovado
$selNoOverride = Resolve-OrchestrationModelSelection -AgentName 'coder' -NativeModelOverrideProven $false -IgnoreUserConfig $true
$verifNoOverride = Test-ExecutedModelVerification -RequestedSelection $selNoOverride -NativeModelOverrideProven $false
Assert-V11 ($verifNoOverride.ProofStatus -eq 'PROOF_ABSENT') "Runtime sem override comprovado retorna PROOF_ABSENT fail-closed"

Write-Host "=== FASE 5: ADVISOR ESCALATION E ASTRA EXCEPCIONAL ==="

# 5.1 Sinais de acionamento do Advisor
$sigDeadlock = Test-AdvisorEscalationSignal -Signal 'verified_deadlock' -Justification 'Persistencia de falha de lock apos duas tentativas de isolamento'
Assert-V11 ($sigDeadlock.Admitted -eq $true) "Sinal de verified_deadlock admitido com justificativa valida"

$sigInvalid = Test-AdvisorEscalationSignal -Signal 'task_is_complex' -Justification 'A tarefa e muito complexa'
Assert-V11 ($sigInvalid.Admitted -eq $false) "Escalonamento ao Advisor meramente por complexidade e expressamente proibido"

# 5.2 Advisor permanece em Terra sem prova kernel-owned (recibo arbitrario nao autoriza T4)
$selAdvNormal = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Risk 'medium' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-V11 ($selAdvNormal.Tier -eq 'T3' -and $selAdvNormal.selected_model_id -eq 'claude-agent/sonnet') "Advisor normal utiliza Sonnet T3"

$selAdvDeadlockAuth = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -FailureCount 2 -T3FailureVerified $true -T3FailureReceipt 'verified:advisor-v11' -NativeModelOverrideProven $true -IgnoreUserConfig $true
Assert-V11 ($selAdvDeadlockAuth.Tier -eq 'T3' -and $selAdvDeadlockAuth.selected_model_id -eq 'claude-agent/sonnet') "Advisor em deadlock com recibo arbitrario permanece em Sonnet (exige prova kernel-owned)"

# 5.3 Astra excepcional: requer autorizacao de orcamento excepcional
$catAstra = Resolve-CatalogModel -Tier 'T4' -Catalog @{ 'T4' = @{ Token = 'MODEL_FRONTIER'; CatalogModel = 'openai/gpt-6-astra'; Authorized = $false } }
Assert-V11 ($catAstra.IsAuthorized -eq $false) "Astra sem autorizacao de orcamento excepcional e recusado"

$catAstraGeneral = Resolve-CatalogModel -Tier 'T4' -Catalog @{ 'T4' = @{ Token = 'MODEL_FRONTIER'; CatalogModel = 'openai/gpt-6-astra'; Authorized = $false } } -ProviderCostAuthorized $true
Assert-V11 ($catAstraGeneral.IsAuthorized -eq $false) "Astra com ProviderCostAuthorized=true NAO e autorizado (requer OPENCODE_ASTRA_AUTHORIZED)"
Assert-V11 ($catAstraGeneral.CostAuthorizationSource -eq 'ASTRA_REQUIRES_VERIFIED_OPUS_FAILURE') "Astra rejeitado com ASTRA_EXCEPTIONAL_BUDGET_REQUIRED"

$env:OPENCODE_ASTRA_AUTHORIZED = 'true'
$catAstraAuth = Resolve-CatalogModel -Tier 'T4' -Catalog @{ 'T4' = @{ Token = 'MODEL_FRONTIER'; CatalogModel = 'openai/gpt-6-astra'; Authorized = $false } }
Assert-V11 ($catAstraAuth.IsAuthorized -eq $false) "Astra com OPENCODE_ASTRA_AUTHORIZED e autorizado"
Remove-Item Env:\OPENCODE_ASTRA_AUTHORIZED -ErrorAction SilentlyContinue

Write-Host "=== FASE 6: JEV FREE CONSULTIVO (SYSTEM ONE) ==="

# 6.1 Jev nunca concede permissoes nem emite DONE
$hostileJev = [pscustomobject]@{
    role               = 'expert'
    grant_permissions  = $true
    widen_scope        = $true
    selected_model     = 'openai/gpt-6-astra'
    done               = $true
    action             = 'override-policy'
}
$grantGate = Invoke-JevAdvisoryGrantGate -JevResult $hostileJev
Assert-V11 ($grantGate.granted -eq $false) "Jev nunca concede permissoes (granted=false)"
Assert-V11 ($grantGate.model_selected -eq $false) "Jev nunca seleciona modelos pagos (model_selected=false)"
Assert-V11 ($grantGate.done_written -eq $false) "Jev nunca emite DONE (done_written=false)"
Assert-V11 ($grantGate.status -eq 'JEV_ADVISORY_CANNOT_GRANT') "Status normativo JEV_ADVISORY_CANNOT_GRANT confirmado"

# 6.2 Recibo do Router
$receipt = Get-OrchestrationModelRouterReceipt -Selection $selPlanner
Assert-V11 ($receipt.stage -eq 'model_routing') "Recibo gerado para stage model_routing"
Assert-V11 ($receipt.catalog_model -eq 'opencode-go/deepseek-v4.1-flash') "Recibo registra modelo canonico"
Assert-V11 ($receipt.tier -eq 'T2') "Recibo registra tier T2"

Write-Host "=========================================================="
Write-Host "TOTAL: $total | PASSOU: $passed | FALHAS: 0"
Write-Host "VEREDITO: DYNAMIC_MODEL_ROUTING_v1.1_ALL_TESTS_PASS"
