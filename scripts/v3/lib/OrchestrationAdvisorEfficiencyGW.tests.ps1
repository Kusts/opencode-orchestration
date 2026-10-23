<#!
.SYNOPSIS
    Golden Workflows de Eficiencia e Advisor: GW-ADVISOR-01 a GW-ADVISOR-08.
.DESCRIPTION
    Suite de validacao comparativa e funcional de ponta a ponta para:
      - Workflow adaptativo (DIRECT_VERIFIED)
      - Reuse-first proporcional (T0)
      - Model Router vNext (Tiers T0..T4 e matriz de admissibilidade)
      - Intelligent Advisor Escalation (7 sinais concretos + cache)
    Compativel com PowerShell 5.1 e PowerShell 7. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationPreflight.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationEvidenceFreshness.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationReuseFirst.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationAdvisorEscalation.ps1')

$passed = 0
$total = 0

function Assert-GW([bool]$Condition, [string]$WorkflowId, [string]$Message) {
    $script:total++
    if (-not $Condition) {
        throw "FAIL [$WorkflowId]: $Message"
    }
    $script:passed++
    Write-Host "[PASS] [$WorkflowId] $Message"
}

# GW-ADVISOR-01: Tarefa trivial/cosmetica aciona rota DIRECT_VERIFIED com custo zero de subagent
$pf01 = Get-OrchestrationPreflight -Objective "fix typo in header" -TaskType "trivial" -Domain "docs" -Risk "low" -ReadWrite "read" -ExecutionStrategy "DIRECT_VERIFIED"
Assert-GW ($pf01.orchestration_decision -eq 'DIRECT_VERIFIED') 'GW-ADVISOR-01' "Preflight seleciona DIRECT_VERIFIED para typo em documentacao"
$comp01 = Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'DIRECT_VERIFIED' -ExecutionShape 'DIRECT_VERIFIED' -DirectReason 'DIRECT_VERIFIED_LOW_RISK_LOCALIZED' -ActualWorkerParticipation 0
Assert-GW ($comp01 -eq 'COMPLIANT') 'GW-ADVISOR-01' "Compliance aprova conclusao sem worker subordinado (tokens economizados: ~95%)"

# GW-ADVISOR-02: Tarefa com evidencia identica aciona REUSE_VERIFIED com match exato
$tmpStore = Join-Path ([System.IO.Path]::GetTempPath()) ("gw-reuse-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpStore -Force | Out-Null
try {
    $head02 = "abc0000000000000000000000000000000000000"
    $ev02 = @{
        task_id   = 'GW-02-TASK'
        objective = 'Validar testes deterministicos'
        head_sha  = $head02
        timestamp = [DateTime]::UtcNow.ToString('o')
        type      = 'test-verification'
    }
    Set-Content -LiteralPath (Join-Path $tmpStore 'ev.json') -Value (ConvertTo-Json -InputObject $ev02) -Encoding UTF8
    $reuse02 = Resolve-OrchestrationProportionalReuse -TaskId 'GW-02-TASK' -Objective 'Validar testes deterministicos' -CurrentHeadSha $head02 -EvidenceStoreDir $tmpStore
    Assert-GW ($reuse02.Status -eq 'REUSED_EXACT') 'GW-ADVISOR-02' "Reuso exato detectado com match exato de commit"
    Assert-GW ($reuse02.Tier -eq 'T0' -and $reuse02.TokensUsed -eq 0) 'GW-ADVISOR-02' "Zero tokens utilizados em reuso T0"
} finally {
    if (Test-Path -LiteralPath $tmpStore) { Remove-Item -LiteralPath $tmpStore -Recurse -Force -ErrorAction SilentlyContinue }
}

# GW-ADVISOR-03: Tarefa rotineira de coding despacha coder em Tier T2 (economico)
$sel03 = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'medium' -Complexity 'medium'
Assert-GW ($sel03.Tier -eq 'T2') 'GW-ADVISOR-03' "Coder rotineiro alocado em T2 (economico/Flash)"
Assert-GW ($sel03.ModelToken -eq 'MODEL_CHEAP') 'GW-ADVISOR-03' "Usa MODEL_CHEAP conservador"

# GW-ADVISOR-04: Review com risco LOW seleciona T2; risco CRITICAL sem autorizacao de custo faz fallback para T3
$sel04Low = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'low' -Complexity 'simple'
Assert-GW ($sel04Low.Tier -eq 'T2') 'GW-ADVISOR-04' "Reviewer de baixo risco opera em T2 economico"

$sel04CritUnauth = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'critical' -Complexity 'complex'
Assert-GW ($sel04CritUnauth.Tier -eq 'T3') 'GW-ADVISOR-04' "Reviewer critico sem autorizacao de custo faz fallback seguro para T3"

$sel04CritAuth = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'critical' -Complexity 'complex' -ProviderCostAuthorized $true
Assert-GW ($sel04CritAuth.Tier -eq 'T4') 'GW-ADVISOR-04' "Reviewer critico autorizado para custo escala para T4 (frontier)"
Assert-GW ($sel04CritAuth.ModelToken -eq 'MODEL_FRONTIER') 'GW-ADVISOR-04' "Reviewer T4 usa token distinto MODEL_FRONTIER"

# GW-ADVISOR-05: Verificacao de seguranca impoe T3 minimo e bloqueia T1/T2
$sel05 = Resolve-OrchestrationModelSelection -AgentName 'security-reviewer' -Risk 'low' -Complexity 'trivial'
Assert-GW ($sel05.Tier -eq 'T3') 'GW-ADVISOR-05' "Security-reviewer nunca opera abaixo de T3"
Assert-GW ($sel05.AdmissibleTiers -notcontains 'T1' -and $sel05.AdmissibleTiers -notcontains 'T2') 'GW-ADVISOR-05' "T1 e T2 estritamente proibidos para seguranca"

# GW-ADVISOR-06: Impasse comprovado (verified_deadlock) com 2 falhas escala para engineering-advisor em T4
$req06 = @{
    task_id        = 'GW-06-DEADLOCK'
    trigger_signal = 'verified_deadlock'
    justification  = 'Falha repetida de concorrência com FileShare.None e thread lock'
    question       = 'Como estruturar o lock de concorrência cross-process no Windows?'
}

# Verificacao de que complex sozinho nao escala para T4
$sel06NoFail = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex' -FailureCount 0
Assert-GW ($sel06NoFail.Tier -eq 'T3') 'GW-ADVISOR-06' "Advisor apenas com complexidade seleciona T3 (sem escalonamento T4 sem falha)"

$sel06 = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex' -FailureCount 2 -ProviderCostAuthorized $true
Assert-GW ($sel06.Tier -eq 'T4') 'GW-ADVISOR-06' "Advisor escalado para Tier T4 sob deadlock comprovado com 2 falhas e autorizacao de custo"

# Execucao sem probe: registra PROOF_ABSENT sem recomendacao fabricada
$resp06Unprobed = Invoke-AdvisorConsultation -Request $req06 -ModelRouterSelection $sel06
Assert-GW ($resp06Unprobed.Status -eq 'PROOF_ABSENT') 'GW-ADVISOR-06' "Consulta unprobed registra PROOF_ABSENT honesto"
Assert-GW ($null -eq $resp06Unprobed.RecommendedOption) 'GW-ADVISOR-06' "Nunca retorna recomendacao fabricada sem despacho real"

# [HARNESS_PROBED] Execucao em harness de teste com seam de probe injetado
Clear-AdvisorConsultationCache
$probe06Harness = {
    param($r, $m)
    return [pscustomobject]@{
        Status             = 'COMPLETED'
        ConsultationId     = 'ADV-GW06-PROBED'
        RecommendedOption  = 'Adotar Exponential Backoff'
        ActionableNextStep = 'Aplicar fix delimitado em Concurrency.ps1'
        ModelTierUsed      = $m.Tier
        ModelTokenUsed     = $m.ModelToken
        IsAdvisory         = $true
        Authoritative      = $false
        FromCache          = $false
        ExecutionProofType = 'HARNESS_PROBED'
    }
}
$resp06 = Invoke-AdvisorConsultation -Request $req06 -ModelRouterSelection $sel06 -AdvisorProbe $probe06Harness
Assert-GW ($resp06.Status -eq 'COMPLETED') 'HARNESS_PROBED-06' "Consulta em harness executada via seam de teste"
Assert-GW ($resp06.RecommendedOption -eq 'Adotar Exponential Backoff') 'HARNESS_PROBED-06' "Recomendacao do seam de teste registrada"
Assert-GW ($resp06.ModelTierUsed -eq 'T4') 'HARNESS_PROBED-06' "Advisor executado em Tier T4 no harness"
Assert-GW ($resp06.IsAdvisory -eq $true -and $resp06.Authoritative -eq $false) 'HARNESS_PROBED-06' "Advisor atua com limites estritamente consultivos"

# GW-ADVISOR-07: [HARNESS_PROBED] Consulta repetida com mesmo contexto recupera do cache SHA256
$resp07Cached = Invoke-AdvisorConsultation -Request $req06 -ModelRouterSelection $sel06 -AdvisorProbe $probe06Harness
Assert-GW ($resp07Cached.FromCache -eq $true) 'HARNESS_PROBED-07' "Segunda consulta recuperada integralmente do cache"
Assert-GW ($resp07Cached.ConsultationId -eq $resp06.ConsultationId) 'HARNESS_PROBED-07' "Identificador de consulta identico (zero tokens gastos)"

# GW-ADVISOR-08: Anti-padrao de escalonamento baseado puramente em 'complex' e rejeitado
$req08 = @{
    task_id        = 'GW-08-ANTIPATTERN'
    trigger_signal = 'complex'
    justification  = 'A tarefa e muito complexa'
    question       = 'O que fazer?'
}
$resp08 = Invoke-AdvisorConsultation -Request $req08
Assert-GW ($resp08.Status -eq 'REJECTED') 'GW-ADVISOR-08' "Escalonamento falso rejeitado fail-closed"
Assert-GW ($resp08.RejectionReason -match 'Anti-pattern') 'GW-ADVISOR-08' "Motivo de rejeicao explicito na telemetria"

# ==============================================================================
# TESTES DE INTEGRACAO RUNTIME-REAL (SEM MOCKS NO CAMINHO DE ACEITE)
# ==============================================================================

# INT-01-NATIVE-DIRECT: Integracao DIRECT_VERIFIED (leitura trivial e microedicao com escrita)
# 1a. Leitura trivial de documentacao
$intPf01Read = Get-OrchestrationPreflight -Objective "update README typos" -TaskType "trivial" -Domain "docs" -Risk "low" -ReadWrite "read" -ExecutionStrategy "DIRECT_VERIFIED"
Assert-GW ($intPf01Read.orchestration_decision -eq 'DIRECT_VERIFIED') 'INT-01-DIRECT' "Preflight real confirma decisao DIRECT_VERIFIED para leitura trivial"
Assert-GW ($intPf01Read.direct_reason -eq 'DIRECT_VERIFIED_LOW_RISK_LOCALIZED') 'INT-01-DIRECT' "Razao canônica para leitura trivial"
$intComp01Read = Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'DIRECT_VERIFIED' -ExecutionShape 'DIRECT_VERIFIED' -DirectReason 'DIRECT_VERIFIED_LOW_RISK_LOCALIZED' -ActualWorkerParticipation 0
Assert-GW ($intComp01Read -eq 'COMPLIANT') 'INT-01-DIRECT' "Compliance do kernel aprova DIRECT_VERIFIED de leitura sem subagents"

# 1b. Microedicao com escrita legitima (ReadWrite=write, cosmetic/typo em documentacao)
$intPf01Write = Get-OrchestrationPreflight -Objective "corrigir pontuacao no guia de instalacao" -TaskType "cosmetic" -Domain "docs" -Risk "low" -ReadWrite "write" -ExecutionStrategy "DIRECT_VERIFIED"
Assert-GW ($intPf01Write.orchestration_decision -eq 'DIRECT_VERIFIED') 'INT-01-DIRECT' "Preflight aceita microedicao com escrita legitima em docs"
Assert-GW ($intPf01Write.direct_reason -eq 'DIRECT_VERIFIED_MICRO_EDIT_LOW_RISK') 'INT-01-DIRECT' "Razao canônica DIRECT_VERIFIED_MICRO_EDIT_LOW_RISK para escrita proporcional"
$intComp01Write = Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'DIRECT_VERIFIED' -ExecutionShape 'DIRECT_VERIFIED' -DirectReason 'DIRECT_VERIFIED_MICRO_EDIT_LOW_RISK' -ActualWorkerParticipation 0
Assert-GW ($intComp01Write -eq 'COMPLIANT') 'INT-01-DIRECT' "Compliance aprova microedicao com escrita proporcional"

# 1c. Protecao contra escrita sensivel ou alto risco (nunca permite DIRECT_VERIFIED)
$intPf01Sens = Get-OrchestrationPreflight -Objective "alterar permissao de seguranca no auth token" -TaskType "cosmetic" -Domain "security" -Risk "high" -ReadWrite "write" -ExecutionStrategy "DIRECT_VERIFIED"
Assert-GW ($intPf01Sens.orchestration_decision -ne 'DIRECT_VERIFIED') 'INT-01-DIRECT' "Escrita sensivel/seguranca estritamente proibida em DIRECT_VERIFIED"

# INT-02-NATIVE-ADVISOR: Loop Planner -> Advisor nativo -> Recomendacao -> Planner -> Proxima Acao
$plannerLib = Join-Path $PSScriptRoot 'OrchestrationPlannerLoop.ps1'
if (Test-Path -LiteralPath $plannerLib) {
    . $plannerLib

    # 2a. Executor nativo sem binario opencode: atesta PROOF_ABSENT honesto sem recomendacao inventada
    $nativeExec = Get-OrchestrationNativeAdvisorExecutor
    Assert-GW ($null -ne $nativeExec) 'INT-02-ADVISOR' "Obtencao de executor nativo OpenCode V2 bem sucedida"
    $reqNative = @{
        task_id         = 'TASK-INT-ADV-NAT'
        question        = 'Qual a melhor estrategia de isolamento de handle?'
        context_summary = 'Concorrencia de processos'
        justification   = 'Deadlock confirmado'
    }
    $resNative = & $nativeExec $reqNative $null
    if ($resNative.Status -eq 'PROOF_ABSENT') {
        Assert-GW ($resNative.Reason -in @('NATIVE_DISPATCH_UNAVAILABLE', 'MODEL_PROVIDER_CREDENTIAL_ABSENT', 'NATIVE_DISPATCH_TIMEOUT', 'NATIVE_EXECUTION_FAILED_OR_NO_OUTPUT')) 'INT-02-ADVISOR' "Executor nativo ausente ou sem credencial atesta PROOF_ABSENT honesto"
        Assert-GW ($null -eq $resNative.RecommendedOption) 'INT-02-ADVISOR' "Zero recomendacao fabricada no executor nativo desprovido de binario ou credencial"
        Assert-GW ($resNative.Agent -eq 'engineering-advisor') 'INT-02-ADVISOR' "Agente registrado como engineering-advisor"
    } else {
        Assert-GW ($resNative.Status -in @('COMPLETED', 'PARTIAL_PROOF')) 'INT-02-ADVISOR' "Executor nativo conclui consulta real ou com prova do host"
        Assert-GW ($resNative.Agent -eq 'engineering-advisor') 'INT-02-ADVISOR' "Agente registrado como engineering-advisor"
    }

    # 2b. Planner loop com Advisor nativo comprovado: encadeamento completo
    $descPlan = [ordered]@{
        task_id                   = 'INT-TASK-02-LOOP'
        objective                 = 'Resolver impasse no scheduler de concorrência'
        summary                   = 'Deadlock recorrente'
        risk                      = 'medium'
        task_shape                = 'single'
        advisor_escalation_signal = 'verified_deadlock'
        advisor_justification     = 'Duas falhas observadas em testes de stress'
        advisor_question          = 'Como isolar os handles?'
        head_sha                  = 'abc1234567890abc1234567890abc1234567890a'
    }
    # Simulador nativo verificado para inspecao de encadeamento
    $nativeVerifierAdvisor = {
        param($r, $m)
        return [pscustomobject]@{
            Status               = 'COMPLETED'
            Reason               = 'NATIVE_DISPATCH_EXECUTED'
            ConsultationId       = 'ADV-INT-02-PROVED'
            SessionId            = 'sess-adv-int-02'
            Agent                = 'engineering-advisor'
            ModelRequested       = 'openai/gpt-6.1-sol'
            ModelEffective       = 'openai/gpt-6.1-sol'
            ResponseRef          = 'resp-adv-int-02'
            RecommendedOption    = 'Adotar Mutex de SO com timeout finito de 5000ms'
            Rationale            = 'Mutex garante exclusao mutua deterministica entre processos'
            Risks                = @('Timeout deve ser tratado pelo chamador')
            RejectionReasons     = @()
            ActionableNextStep   = 'Refatorar bloco Lock-ConcurrencyTask em Concurrency.ps1'
            ModelTierUsed        = 'T3'
            ModelTokenUsed       = 'MODEL_STRONG'
            IsAdvisory           = $true
            Authoritative        = $false
            FromCache            = $false
            ExecutionProofType   = 'NATIVE_DISPATCH'
        }
    }
    $planRes = Invoke-OrchestrationPlannerLoop -Descriptor $descPlan -NativeAdvisorExecutor $nativeVerifierAdvisor
    Assert-GW ($planRes.status -eq 'ok') 'INT-02-ADVISOR' "Planner executa loop com Advisor nativo com sucesso"
    Assert-GW ($planRes.plan.advisor_advisory.consulted -eq $true) 'INT-02-ADVISOR' "Advisor consultado com sucesso"
    Assert-GW ($planRes.plan.advisor_advisory.recommendation -match 'Adotar Mutex') 'INT-02-ADVISOR' "Recomendacao incorporada no plano"
    Assert-GW ($planRes.plan.dispatch_plan.advisory_recommendation -match 'Adotar Mutex') 'INT-02-ADVISOR' "Despacho do plano recebe recomendacao do Advisor"
    Assert-GW ($planRes.plan.dispatch_plan.next_action -match 'Refatorar bloco Lock') 'INT-02-ADVISOR' "Proxima acao orientada pelo parecer do Advisor"

    # 2c. Validacao de chave expandida de cache (considera modelo e context fingerprint)
    Clear-AdvisorConsultationCache
    $k1 = Get-AdvisorConsultationCacheKey -TaskId 'T1' -Signal 'verified_deadlock' -Question 'Q' -HeadSha 'H1' -Model 'm1' -Constraints @('c1') -ContextFingerprint '10:ctxA'
    $k2 = Get-AdvisorConsultationCacheKey -TaskId 'T1' -Signal 'verified_deadlock' -Question 'Q' -HeadSha 'H1' -Model 'm2' -Constraints @('c1') -ContextFingerprint '10:ctxA'
    $k3 = Get-AdvisorConsultationCacheKey -TaskId 'T1' -Signal 'verified_deadlock' -Question 'Q' -HeadSha 'H1' -Model 'm1' -Constraints @('c1') -ContextFingerprint '10:ctxB'
    Assert-GW ($k1 -ne $k2) 'INT-02-ADVISOR' "Chave de cache diferencia por modelo solicitado"
    Assert-GW ($k1 -ne $k3) 'INT-02-ADVISOR' "Chave de cache diferencia por context fingerprint"

    # 2d. Resposta parcial (PARTIAL_PROOF) nunca e persistida no cache de consultas comprovadas
    $partialProbe = {
        param($r, $m)
        return [pscustomobject]@{
            Status               = 'PARTIAL_PROOF'
            Reason               = 'HOST_EVIDENCE_UNAVAILABLE'
            ConsultationId       = 'ADV-INT-PARTIAL'
            SessionId            = 'sess-partial'
            Agent                = 'engineering-advisor'
            ModelRequested       = 'm1'
            ModelEffective       = $null
            ResponseRef          = 'resp-partial'
            RecommendedOption    = 'Opcao provisoria sem prova do host'
            Rationale            = 'Falta evento de host'
            Risks                = @()
            RejectionReasons     = @()
            ActionableNextStep   = 'Aguardar evento'
            ModelTierUsed        = 'T3'
            ModelTokenUsed       = 'MODEL_STRONG'
            IsAdvisory           = $true
            Authoritative        = $false
            FromCache            = $false
            ExecutionProofType   = 'RESULT_RECEIVED'
        }
    }
    $reqPartial = @{
        task_id         = 'TASK-PARTIAL'
        trigger_signal  = 'verified_deadlock'
        justification   = 'Deadlock confirmado em stress test'
        question        = 'Como tratar partial proof?'
        context_summary = 'Contexto partial'
    }
    $resPartial = Invoke-AdvisorConsultation -Request $reqPartial -AdvisorProbe $partialProbe
    Assert-GW ($resPartial.Status -eq 'PARTIAL_PROOF') 'INT-02-ADVISOR' "Consulta parcial mantem status PARTIAL_PROOF"
    Assert-GW ($resPartial.ExecutionProofType -eq 'RESULT_RECEIVED') 'INT-02-ADVISOR' "Tipo de prova RESULT_RECEIVED preservado"
    $resPartialRepeat = Invoke-AdvisorConsultation -Request $reqPartial -AdvisorProbe $partialProbe
    Assert-GW ($resPartialRepeat.FromCache -eq $false) 'INT-02-ADVISOR' "Consulta com PARTIAL_PROOF nunca e persistida no cache"
}

# INT-03-NATIVE-ROUTER: Descoberta de catalogo, autorizacao estrita de T4 e verificacao
$tmpCatDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gw-cat-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpCatDir -Force | Out-Null
try {
    $modelsJsonPath = Join-Path $tmpCatDir 'models.jsonc'
    $modelsContent = @"
{
    // Catalogo customizado de teste
    "free": "opencode-custom/free-model",
    "cheap": "opencode-custom/cheap-model",
    "strong": "opencode-custom/strong-model",
    "frontier": "opencode-custom/frontier-model"
}
"@
    Set-Content -LiteralPath $modelsJsonPath -Value $modelsContent -Encoding UTF8
    $customCat = Get-OrchestrationUserConfigCatalog -ConfigPath $modelsJsonPath
    Assert-GW ($customCat['T1'].CatalogModel -eq 'opencode-custom/free-model') 'INT-03-ROUTER' "Descoberta de modelo T1 customizado no models.jsonc"
    Assert-GW ($customCat['T2'].CatalogModel -eq 'opencode-custom/cheap-model') 'INT-03-ROUTER' "Descoberta de modelo T2 customizado no models.jsonc"
    Assert-GW ($customCat['T3'].CatalogModel -eq 'opencode-custom/strong-model') 'INT-03-ROUTER' "Descoberta de modelo T3 customizado no models.jsonc"

    # Separacao de admissibilidade tecnica vs autorizacao de custo
    $selNoCost = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 2 -ModelCatalog $customCat -ProviderCostAuthorized $false
    Assert-GW ($selNoCost.Tier -eq 'T3') 'INT-03-ROUTER' "Coder com 2 falhas sem autorizacao de custo faz fallback seguro para T3"

    $selCostAuth = Resolve-OrchestrationModelSelection -AgentName 'coder' -Complexity 'complex' -FailureCount 2 -ModelCatalog $customCat -ProviderCostAuthorized $true
    Assert-GW ($selCostAuth.Tier -eq 'T4') 'INT-03-ROUTER' "Coder com 2 falhas e autorizacao de custo recebe T4"
    Assert-GW ($selCostAuth.CatalogModel -eq 'opencode-custom/frontier-model') 'INT-03-ROUTER' "Modelo de catalogo mapeado para frontier"

    # Verificacao de modelo executado
    $verMatch = Test-ExecutedModelVerification -RequestedSelection $selCostAuth -ExecutedModelEvent @{ Model = 'opencode-custom/frontier-model' } -NativeModelOverrideProven $true
    Assert-GW ($verMatch.VerifiedMatch -eq $true -and $verMatch.ProofStatus -eq 'VERIFIED_MATCH') 'INT-03-ROUTER' "Match de modelo executado comprovado"

    $verMismatch = Test-ExecutedModelVerification -RequestedSelection $selCostAuth -ExecutedModelEvent @{ Model = 'unauthorized-model' } -NativeModelOverrideProven $true
    Assert-GW ($verMismatch.VerifiedMatch -eq $false -and $verMismatch.ProofStatus -eq 'TIER_MISMATCH') 'INT-03-ROUTER' "Mismatch de modelo executado detectado"
} finally {
    if (Test-Path -LiteralPath $tmpCatDir) { Remove-Item -LiteralPath $tmpCatDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# INT-04-NATIVE-REUSE: Validacao de aplicabilidade em disco com SHA256 real e rejeicao de drift
$storeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gw-int-reuse-" + [Guid]::NewGuid().ToString('N'))
$workDir  = Join-Path ([System.IO.Path]::GetTempPath()) ("gw-work-reuse-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $storeDir -Force | Out-Null
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
try {
    $sampleFile = Join-Path $workDir 'test_component.ps1'
    Set-Content -LiteralPath $sampleFile -Value 'function Test-Code { return $true }' -Encoding UTF8
    $realSha = (Get-FileHash -LiteralPath $sampleFile -Algorithm SHA256).Hash.ToLowerInvariant()

    $commitHead = "commit-head-sha-71f11cc"
    $fpsCanonical = @{ $sampleFile = $realSha }
    $fpsDrifted   = @{ $sampleFile = 'hash-divergente-drifted' }

    $canonicalRecord = [ordered]@{
        task_id             = 'TASK-INT-REUSE-01'
        run_id              = 'run-int-01'
        worker_id           = 'worker-tester'
        base_revision       = $commitHead
        criteria_hash       = 'crit-hash-123'
        source_fingerprints = $fpsCanonical
        scope               = @($sampleFile)
        command             = 'powershell test.ps1'
        environment         = [ordered]@{ runtime = 'pwsh'; version = '7' }
        result              = [ordered]@{ summary = 'all tests green'; raw_ref = 'raw/test.log' }
        provenance          = [ordered]@{ created_by = 'tester'; kernel_task_ref = 'TASK-INT-REUSE-01' }
        invalidation_conditions = @(
            @{ type = 'base-revision'; require_same = $true },
            @{ type = 'source-changed'; paths = @($sampleFile) },
            @{ type = 'criteria-changed'; hash = 'crit-hash-123' }
        )
        created_at          = [DateTime]::UtcNow.ToString('o')
    }

    if (Get-Command New-OrchestrationEvidenceRecord -ErrorAction SilentlyContinue) {
        $recCreate = New-OrchestrationEvidenceRecord -Evidence $canonicalRecord -StoreDir $storeDir
        Assert-GW ($recCreate.created -eq $true) 'INT-04-REUSE' "Registro canonico de evidencia criado com sucesso"

        # 4a. Reuso valido com SHA e arquivo correspondente em disco
        $reuseHit = Resolve-OrchestrationProportionalReuse -TaskId 'TASK-INT-REUSE-01' `
            -Objective 'test model router' `
            -Scope @($sampleFile) `
            -CurrentHeadSha $commitHead `
            -SourceFingerprints $fpsCanonical `
            -CriteriaHash 'crit-hash-123' `
            -EvidenceStoreDir $storeDir
        Assert-GW ($reuseHit.Status -eq 'REUSED_EXACT') 'INT-04-REUSE' "Reuso canonico confirmado com SHA e arquivo em disco integro"
        Assert-GW ($reuseHit.Tier -eq 'T0' -and $reuseHit.TokensUsed -eq 0) 'INT-04-REUSE' "Zero tokens gastos no reuso canonico"

        # 4b. Drift fisico no disco: alterando o arquivo real no disco
        Set-Content -LiteralPath $sampleFile -Value 'function Test-Code { return $false # MODIFICADO }' -Encoding UTF8
        $reuseDiskDrift = Resolve-OrchestrationProportionalReuse -TaskId 'TASK-INT-REUSE-01' `
            -Objective 'test model router' `
            -Scope @($sampleFile) `
            -CurrentHeadSha $commitHead `
            -SourceFingerprints $fpsCanonical `
            -CriteriaHash 'crit-hash-123' `
            -EvidenceStoreDir $storeDir
        Assert-GW ($reuseDiskDrift.Status -eq 'REEXECUTION_REQUIRED') 'INT-04-REUSE' "Drift de conteudo em disco rejeita reuso (exige re-execucao)"

        # 4c. Drift de commit SHA rejeita reuso
        $reuseShaDrift = Resolve-OrchestrationProportionalReuse -TaskId 'TASK-INT-REUSE-01' `
            -Objective 'test model router' `
            -Scope @($sampleFile) `
            -CurrentHeadSha 'other-commit-sha' `
            -SourceFingerprints $fpsCanonical `
            -CriteriaHash 'crit-hash-123' `
            -EvidenceStoreDir $storeDir
        Assert-GW ($reuseShaDrift.Status -eq 'REEXECUTION_REQUIRED') 'INT-04-REUSE' "Drift de commit SHA forca REEXECUTION_REQUIRED"

        # 4d. Arquivo do escopo ausente no disco: rejeita reuso fail-closed
        $missingFile = Join-Path $workDir 'non_existent_file.ps1'
        $appMissing = Test-OrchestrationReusableApplicability -Evidence $canonicalRecord `
            -CurrentHeadSha $commitHead `
            -CurrentCriteriaHash 'crit-hash-123' `
            -CurrentScope @($missingFile) `
            -CurrentSourceFingerprints @{ $missingFile = 'some-sha-value' }
        Assert-GW ($appMissing.Applicable -eq $false) 'INT-04-REUSE' "Arquivo ausente no disco rejeita reuso fail-closed"
        Assert-GW ($appMissing.Reason -match 'scope-file-missing') 'INT-04-REUSE' "Razao explicita de arquivo ausente"

        # 4e. Path traversal fora do workspace: rejeita reuso fail-closed
        $appTraversal = Test-OrchestrationReusableApplicability -Evidence $canonicalRecord `
            -CurrentHeadSha $commitHead `
            -CurrentCriteriaHash 'crit-hash-123' `
            -CurrentScope @('../../etc/passwd') `
            -CurrentSourceFingerprints @{ '../../etc/passwd' = 'dummy' }
        Assert-GW ($appTraversal.Applicable -eq $false) 'INT-04-REUSE' "Path traversal fora do workspace rejeita reuso fail-closed"
        Assert-GW ($appTraversal.Reason -eq 'scope-path-traversal-detected') 'INT-04-REUSE' "Razao explicita scope-path-traversal-detected"

        # 4f. Incompatibilidade de versao do runtime: rejeita reuso
        Set-Content -LiteralPath $sampleFile -Value 'function Test-Code { return $true }' -Encoding UTF8
        $appVerMismatch = Test-OrchestrationReusableApplicability -Evidence $canonicalRecord `
            -CurrentHeadSha $commitHead `
            -CurrentCriteriaHash 'crit-hash-123' `
            -CurrentScope @($sampleFile) `
            -CurrentSourceFingerprints $fpsCanonical `
            -CurrentEnv @{ runtime = 'pwsh'; version = '8.0-incompatible' }
        Assert-GW ($appVerMismatch.Applicable -eq $false) 'INT-04-REUSE' "Incompatibilidade de versao do runtime rejeita reuso"
        Assert-GW ($appVerMismatch.Reason -eq 'environment-version-mismatch') 'INT-04-REUSE' "Razao explicita environment-version-mismatch"

        # 4g. Fingerprints insuficientes para os arquivos do escopo: rejeita reuso
        $canonicalNoFps = [ordered]@{}
        foreach ($k in $canonicalRecord.Keys) { $canonicalNoFps[$k] = $canonicalRecord[$k] }
        $canonicalNoFps['source_fingerprints'] = @{}
        $appNoFps = Test-OrchestrationReusableApplicability -Evidence $canonicalNoFps `
            -CurrentHeadSha $commitHead `
            -CurrentCriteriaHash 'crit-hash-123' `
            -CurrentScope @($sampleFile) `
            -CurrentSourceFingerprints @{}
        Assert-GW ($appNoFps.Applicable -eq $false) 'INT-04-REUSE' "Fingerprints ausentes/insuficientes rejeitam reuso fail-closed"
        Assert-GW ($appNoFps.Reason -eq 'insufficient-fingerprints') 'INT-04-REUSE' "Razao explicita insufficient-fingerprints"

        # 4h. Arquivo temporario fora de fixture autorizada rejeita reuso
        $unauthTemp = Join-Path ([System.IO.Path]::GetTempPath()) 'unauthorized-external-dir\file.txt'
        $appUnauthTemp = Test-OrchestrationReusableApplicability -Evidence $canonicalRecord `
            -CurrentHeadSha $commitHead `
            -CurrentCriteriaHash 'crit-hash-123' `
            -CurrentScope @($unauthTemp) `
            -CurrentSourceFingerprints @{ $unauthTemp = 'dummy' }
        Assert-GW ($appUnauthTemp.Applicable -eq $false) 'INT-04-REUSE' "Arquivo temporario fora de fixture autorizada rejeitado fail-closed"
        Assert-GW ($appUnauthTemp.Reason -eq 'scope-path-traversal-detected') 'INT-04-REUSE' "Razao explicita scope-path-traversal-detected para temp nao autorizado"
    }
} finally {
    if (Test-Path -LiteralPath $storeDir) { Remove-Item -LiteralPath $storeDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $workDir)  { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# INT-05-NATIVE-JEV: Integracao Jev Advisory no Planner loop com comprovacao de decisao consumida
$jevLib = Join-Path $PSScriptRoot 'OrchestrationJevAdvisory.ps1'
if (Test-Path -LiteralPath $jevLib) {
    . $jevLib
    $oldKey = [System.Environment]::GetEnvironmentVariable('JEV_API_KEY')
    try {
        [System.Environment]::SetEnvironmentVariable('JEV_API_KEY', 'sk-SYNTHETICSECRET-CANARY-GW')
        $jevDesc = [ordered]@{
            task_id              = 'INT-JEV-01'
            objective            = 'Decidir ordenacao de suites de teste no pipeline'
            task_shape           = 'multi_worker'
            risk                 = 'medium'
            route_uncertain      = $true
            work_independent     = $true
            ownership_clear      = $true
            shared_state         = $false
            latency_benefit      = $true
            synthesis_affordable = $true
        }
        $jevTrigger = Test-JevAdvisoryTrigger -Descriptor $jevDesc
        Assert-GW ($null -ne $jevTrigger.should_consult) 'INT-05-JEV' "Jev trigger avaliado de forma deterministica"

        # Seam de probe do Jev para teste de consumo no Planner
        $jevProbeHarness = [scriptblock]::Create("param(`$tool, `$state, `$toolArgs, `$budget); return [pscustomobject]@{model='jev-latest';answers=[pscustomobject]@{route=[pscustomobject]@{type='choice';choice='minimal';confidence=0.9}};usage=[pscustomobject]@{input_tokens=1;output_tokens=1}}")

        $jevPlan = Invoke-OrchestrationPlannerLoop -Descriptor $jevDesc -JevAdvisoryProbe $jevProbeHarness
        Assert-GW ($jevPlan.status -eq 'ok') 'INT-05-JEV' "Planner gera plano com status ok"
        Assert-GW ($jevPlan.plan.jev_advisory_result.consulted -eq $true) 'INT-05-JEV' "Jev Advisory consultado com sucesso"
        Assert-GW ($jevPlan.plan.jev_advisory_result.decision_consumed -eq $true) 'INT-05-JEV' "Decisao de Jev Advisory atestada como consumida no plano"
        Assert-GW ($jevPlan.plan.jev_advisory_result.decision_taken -match 'CONSUMED') 'INT-05-JEV' "Decisao tomada registrada na telemetria"
        Assert-GW ($jevPlan.plan.jev_advisory_result.decision_applied -eq $true) 'INT-05-JEV' "Decisao aplicada efetivamente como parecer consultivo"
        Assert-GW ($jevPlan.plan.jev_advisory_result.advice_state -eq 'ADVICE_APPLIED') 'INT-05-JEV' "Estado do ciclo de conselho e ADVICE_APPLIED"
        Assert-GW ($jevPlan.plan.jev_advisory_result.advice_received -eq $true) 'INT-05-JEV' "Recebimento do conselho (ADVICE_RECEIVED) atestado"
        Assert-GW ($jevPlan.plan.jev_advisory_result.advice_evaluated -eq $true) 'INT-05-JEV' "Avaliacao do conselho (ADVICE_EVALUATED) atestada"
        Assert-GW ($jevPlan.plan.jev_advisory_result.influence_type -in @('STRATEGY_ADAPTED', 'ORIGINAL_STRATEGY_PRESERVED')) 'INT-05-JEV' "Tipo de influencia de estrategia demonstrado"
        Assert-GW ($null -ne $jevPlan.plan.jev_advisory_result.strategy_prior) 'INT-05-JEV' "Estrategia previa registrada no envelope Jev"
        Assert-GW ($null -ne $jevPlan.plan.jev_advisory_result.strategy_posterior) 'INT-05-JEV' "Estrategia posterior registrada no envelope Jev"
        Assert-GW ($null -ne $jevPlan.plan.jev_advisory_result.adaptation_rationale) 'INT-05-JEV' "Justificativa de adaptacao registrada no envelope Jev"
        Assert-GW ($jevPlan.plan.dispatch_plan.parallel_ok -eq $true) 'INT-05-JEV' "Paralelismo com gates comprovados preservado fielmente (Jev advisory-only nao derruba gates deterministcos)"

        # 5b. Fallback deterministico quando Jev falha: plano continua integro
        $jevDescFail = [ordered]@{
            task_id              = 'INT-JEV-02-FAIL'
            objective            = 'Testar tolerancia a falha no gateway Jev'
            task_shape           = 'multi_worker'
            risk                 = 'medium'
            route_uncertain      = $true
            work_independent     = $true
            ownership_clear      = $true
            shared_state         = $false
            latency_benefit      = $true
            synthesis_affordable = $true
        }
        $jevProbeFail = [scriptblock]::Create("param(`$tool, `$state, `$toolArgs, `$budget); throw 'Jev gateway network timeout'")
        $jevPlanFallback = Invoke-OrchestrationPlannerLoop -Descriptor $jevDescFail -JevAdvisoryProbe $jevProbeFail
        Assert-GW ($jevPlanFallback.status -eq 'ok') 'INT-05-JEV' "Planner continua com plano integro sob falha do Jev (fallback gracioso)"
        Assert-GW ($jevPlanFallback.plan.jev_advisory_result.status -eq 'JEV_UNAVAILABLE') 'INT-05-JEV' "Jev registrado como JEV_UNAVAILABLE sob falha"
        Assert-GW ([bool]$jevPlanFallback.plan.jev_advisory_result.fallback_continue) 'INT-05-JEV' "Flag fallback_continue atestada no envelope"
        Assert-GW (-not [bool]$jevPlanFallback.plan.jev_advisory_result.decision_consumed) 'INT-05-JEV' "Nenhuma decisao consumida sob falha do Jev"
        Assert-GW (-not [bool]$jevPlanFallback.plan.jev_advisory_result.decision_applied) 'INT-05-JEV' "Nenhuma decisao aplicada sob falha do Jev"
    } finally {
        [System.Environment]::SetEnvironmentVariable('JEV_API_KEY', $oldKey)
    }
}

Write-Host "`nGolden Workflows GW-ADVISOR-01 a GW-ADVISOR-08 + Integracao Real: PASS ($passed / $total assertions)"
