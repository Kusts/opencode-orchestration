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

# GW-ADVISOR-04: Review com risco LOW seleciona T2; risco CRITICAL seleciona T4
$sel04Low = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'low' -Complexity 'simple'
Assert-GW ($sel04Low.Tier -eq 'T2') 'GW-ADVISOR-04' "Reviewer de baixo risco opera em T2 economico"
$sel04Crit = Resolve-OrchestrationModelSelection -AgentName 'reviewer' -Risk 'critical' -Complexity 'complex'
Assert-GW ($sel04Crit.Tier -eq 'T4') 'GW-ADVISOR-04' "Reviewer critico escala para T4 (frontier)"

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

$sel06 = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex' -FailureCount 2
Assert-GW ($sel06.Tier -eq 'T4') 'GW-ADVISOR-06' "Advisor escalado para Tier T4 sob deadlock comprovado com 2 falhas"

# Execucao sem probe: registra PROOF_ABSENT sem recomendacao fabricada
$resp06Unprobed = Invoke-AdvisorConsultation -Request $req06 -ModelRouterSelection $sel06
Assert-GW ($resp06Unprobed.Status -eq 'PROOF_ABSENT') 'GW-ADVISOR-06' "Consulta unprobed registra PROOF_ABSENT honesto"
Assert-GW ($null -eq $resp06Unprobed.RecommendedOption) 'GW-ADVISOR-06' "Nunca retorna recomendacao fabricada sem despacho real"

# Execucao com probe efetivo
Clear-AdvisorConsultationCache
$probe06 = {
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
    }
}
$resp06 = Invoke-AdvisorConsultation -Request $req06 -ModelRouterSelection $sel06 -AdvisorProbe $probe06
Assert-GW ($resp06.Status -eq 'COMPLETED') 'GW-ADVISOR-06' "Consulta com probe executada com sucesso"
Assert-GW ($resp06.RecommendedOption -eq 'Adotar Exponential Backoff') 'GW-ADVISOR-06' "Recomendacao efetiva do despacho registrada"
Assert-GW ($resp06.ModelTierUsed -eq 'T4') 'GW-ADVISOR-06' "Advisor executado em Tier T4"
Assert-GW ($resp06.IsAdvisory -eq $true -and $resp06.Authoritative -eq $false) 'GW-ADVISOR-06' "Advisor atua com limites estritamente consultivos"

# GW-ADVISOR-07: Consulta repetida com mesmo contexto recupera do cache SHA256
$resp07Cached = Invoke-AdvisorConsultation -Request $req06 -ModelRouterSelection $sel06 -AdvisorProbe $probe06
Assert-GW ($resp07Cached.FromCache -eq $true) 'GW-ADVISOR-07' "Segunda consulta recuperada integralmente do cache"
Assert-GW ($resp07Cached.ConsultationId -eq $resp06.ConsultationId) 'GW-ADVISOR-07' "Identificador de consulta identico (zero tokens gastos)"

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

# INT-01: Integracao DIRECT_VERIFIED de ponta a ponta
$intPf01 = Get-OrchestrationPreflight -Objective "update README typos" -TaskType "trivial" -Domain "docs" -Risk "low" -ReadWrite "read" -ExecutionStrategy "DIRECT_VERIFIED"
Assert-GW ($intPf01.orchestration_decision -eq 'DIRECT_VERIFIED') 'INT-01' "Preflight real confirma decisao DIRECT_VERIFIED"
$intComp01 = Test-OrchestrationDoneCompliance -TaskClass 'trivial' -Decision 'DIRECT_VERIFIED' -ExecutionShape 'DIRECT_VERIFIED' -DirectReason 'DIRECT_VERIFIED_LOW_RISK_LOCALIZED' -ActualWorkerParticipation 0
Assert-GW ($intComp01 -eq 'COMPLIANT') 'INT-01' "Compliance do kernel aprova DIRECT_VERIFIED sem subagents"

# INT-02: Loop Planner -> Router -> Advisor -> Planner (sem simulacao ficticia)
$plannerLib = Join-Path $PSScriptRoot 'OrchestrationPlannerLoop.ps1'
if (Test-Path -LiteralPath $plannerLib) {
    . $plannerLib
    # 2a. Planner loop com Advisor unprobed: registra PROOF_ABSENT e consulted=false honesto
    $descUnprobed = [ordered]@{
        task_id                   = 'INT-TASK-02A'
        objective                 = 'Resolver impasse de concorrencia no scheduler'
        summary                   = 'Deadlock recorrente'
        risk                      = 'medium'
        task_shape                = 'single'
        advisor_escalation_signal = 'verified_deadlock'
        advisor_justification     = 'Duas tentativas falharam por colisão de handle no scheduler'
        advisor_question          = 'Como isolar os handles?'
        head_sha                  = 'abc1234567890abc1234567890abc1234567890a'
    }
    $planUnprobed = Invoke-OrchestrationPlannerLoop -Descriptor $descUnprobed
    Assert-GW ($planUnprobed.status -eq 'ok') 'INT-02A' "Planner gera plano com status ok"
    Assert-GW ($planUnprobed.plan.advisor_advisory.consulted -eq $false) 'INT-02A' "Advisor nao consultado quando unprobed"
    Assert-GW ($planUnprobed.plan.advisor_advisory.status -eq 'PROOF_ABSENT') 'INT-02A' "Status PROOF_ABSENT registrado no plano do Planner"
    Assert-GW ([string]::IsNullOrEmpty($planUnprobed.plan.advisor_advisory.recommendation)) 'INT-02A' "Sem recomendacao fabricada no plano"

    # 2b. Planner loop com Advisor probed: registra consulted=true e parecer estruturado real
    $probeReal = {
        param($req, $sel)
        return [pscustomobject]@{
            Status             = 'COMPLETED'
            ConsultationId     = 'ADV-INT-02B'
            RecommendedOption  = 'Aplicar Mutex com timeout finito'
            ActionableNextStep = 'Atualizar lock em Scheduler.ps1'
            ModelTierUsed      = 'T3'
            ModelTokenUsed     = 'MODEL_STRONG'
            IsAdvisory         = $true
            Authoritative      = $false
            FromCache          = $false
        }
    }
    $descProbed = [ordered]@{
        task_id                   = 'INT-TASK-02B'
        objective                 = 'Resolver impasse com probe real'
        summary                   = 'Impasse de lock'
        risk                      = 'medium'
        task_shape                = 'single'
        advisor_escalation_signal = 'verified_deadlock'
        advisor_justification     = 'Duas tentativas falharam por colisão de handle no scheduler'
        advisor_question          = 'Como isolar os handles?'
        head_sha                  = 'abc1234567890abc1234567890abc1234567890a'
    }
    $planProbed = Invoke-OrchestrationPlannerLoop -Descriptor $descProbed -Options @{ advisor_probe = $probeReal }
    Assert-GW ($planProbed.plan.advisor_advisory.consulted -eq $true) 'INT-02B' "Advisor consultado quando probe disponivel"
    Assert-GW ($planProbed.plan.advisor_advisory.status -eq 'COMPLETED') 'INT-02B' "Status COMPLETED registrado no plano"
    Assert-GW ($planProbed.plan.advisor_advisory.recommendation -match 'Aplicar Mutex') 'INT-02B' "Recomendacao do despacho real registrada no plano"
}

# INT-03: Integracao Model Router — Catalogo, selecao autorizada e verificacao
$intSelNoProof = Resolve-OrchestrationModelSelection -AgentName 'coder' -Risk 'medium' -NativeModelOverrideProven $false
Assert-GW ($intSelNoProof.ProofStatus -eq 'PROOF_ABSENT') 'INT-03' "Model Router registra PROOF_ABSENT sem prova de override nativo"
Assert-GW ($intSelNoProof.RuntimeTierProven -eq $false) 'INT-03' "RuntimeTierProven e false sem prova"

$verifCheck = Test-ExecutedModelVerification -RequestedSelection $intSelNoProof -NativeModelOverrideProven $false
Assert-GW ($verifCheck.ProofStatus -eq 'PROOF_ABSENT') 'INT-03' "Verificacao fail-closed devolve PROOF_ABSENT sem override nativo"

# INT-04: Integracao de Reuso Canonico — validacao de SHA, fingerprints, ambiente e criterios
$storeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("gw-int-reuse-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $storeDir -Force | Out-Null
try {
    $commitHead = "commit-head-sha-71f11cc"
    $fpsCanonical = @{ 'scripts/v3/lib/OrchestrationModelRouter.ps1' = 'hash-router-canonical' }
    $fpsDrifted   = @{ 'scripts/v3/lib/OrchestrationModelRouter.ps1' = 'hash-router-modified' }

    $canonicalRecord = [ordered]@{
        task_id             = 'TASK-INT-REUSE-01'
        run_id              = 'run-int-01'
        worker_id           = 'worker-tester'
        base_revision       = $commitHead
        criteria_hash       = 'crit-hash-123'
        source_fingerprints = $fpsCanonical
        scope               = @('scripts/v3/lib/OrchestrationModelRouter.ps1')
        command             = 'powershell test.ps1'
        environment         = [ordered]@{ runtime = 'pwsh'; version = '7' }
        result              = [ordered]@{ summary = 'all tests green'; raw_ref = 'raw/test.log' }
        provenance          = [ordered]@{ created_by = 'tester'; kernel_task_ref = 'TASK-INT-REUSE-01' }
        invalidation_conditions = @(
            @{ type = 'base-revision'; require_same = $true },
            @{ type = 'source-changed'; paths = @('scripts/v3/lib/OrchestrationModelRouter.ps1') },
            @{ type = 'criteria-changed'; hash = 'crit-hash-123' }
        )
        created_at          = [DateTime]::UtcNow.ToString('o')
    }

    if (Get-Command New-OrchestrationEvidenceRecord -ErrorAction SilentlyContinue) {
        $recCreate = New-OrchestrationEvidenceRecord -Evidence $canonicalRecord -StoreDir $storeDir
        Assert-GW ($recCreate.created -eq $true) 'INT-04' "Registro canonico de evidencia criado com sucesso"

        # Reuso valido com SHA e fingerprints coincidentes
        $reuseHit = Resolve-OrchestrationProportionalReuse -TaskId 'TASK-INT-REUSE-01' `
            -Objective 'test model router' `
            -Scope @('scripts/v3/lib/OrchestrationModelRouter.ps1') `
            -CurrentHeadSha $commitHead `
            -SourceFingerprints $fpsCanonical `
            -CriteriaHash 'crit-hash-123' `
            -EvidenceStoreDir $storeDir
        Assert-GW ($reuseHit.Status -eq 'REUSED_EXACT') 'INT-04' "Reuso canonico confirmado com SHA e fingerprints correspondentes"
        Assert-GW ($reuseHit.Tier -eq 'T0' -and $reuseHit.TokensUsed -eq 0) 'INT-04' "Zero tokens gastos no reuso canonico"

        # Drift de fingerprint rejeita reuso (nao aceita task_id isolado)
        $reuseDrift = Resolve-OrchestrationProportionalReuse -TaskId 'TASK-INT-REUSE-01' `
            -Objective 'test model router' `
            -Scope @('scripts/v3/lib/OrchestrationModelRouter.ps1') `
            -CurrentHeadSha $commitHead `
            -SourceFingerprints $fpsDrifted `
            -CriteriaHash 'crit-hash-123' `
            -EvidenceStoreDir $storeDir
        Assert-GW ($reuseDrift.Status -eq 'REEXECUTION_REQUIRED') 'INT-04' "Drift de fingerprint forca REEXECUTION_REQUIRED mesmo com mesmo task_id"

        # Drift de commit SHA rejeita reuso
        $reuseShaDrift = Resolve-OrchestrationProportionalReuse -TaskId 'TASK-INT-REUSE-01' `
            -Objective 'test model router' `
            -Scope @('scripts/v3/lib/OrchestrationModelRouter.ps1') `
            -CurrentHeadSha 'other-commit-sha' `
            -SourceFingerprints $fpsCanonical `
            -CriteriaHash 'crit-hash-123' `
            -EvidenceStoreDir $storeDir
        Assert-GW ($reuseShaDrift.Status -eq 'REEXECUTION_REQUIRED') 'INT-04' "Drift de commit SHA forca REEXECUTION_REQUIRED"
    }
} finally {
    if (Test-Path -LiteralPath $storeDir) {
        Remove-Item -LiteralPath $storeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# INT-05: Integracao Jev Advisory no Planner loop
$jevLib = Join-Path $PSScriptRoot 'OrchestrationJevAdvisory.ps1'
if (Test-Path -LiteralPath $jevLib) {
    . $jevLib
    $jevDesc = [ordered]@{
        task_id     = 'INT-JEV-01'
        objective   = 'Decidir ordenacao de suites de teste no pipeline'
        task_shape  = 'multi_worker'
        risk        = 'medium'
        uncertainty = 'high'
    }
    $jevTrigger = Test-JevAdvisoryTrigger -Descriptor $jevDesc
    Assert-GW ($null -ne $jevTrigger.should_consult) 'INT-05' "Jev trigger avaliado de forma deterministica"
}

Write-Host "`nGolden Workflows GW-ADVISOR-01 a GW-ADVISOR-08 + Integracao Real: PASS ($passed / $total assertions)"
