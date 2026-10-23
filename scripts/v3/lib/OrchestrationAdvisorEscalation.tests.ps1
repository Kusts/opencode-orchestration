<#!
.SYNOPSIS
    Testes unitarios para OrchestrationAdvisorEscalation.ps1 (Issue #60, Adendo 2026-10-21).
.DESCRIPTION
    Valida a politica de escalonamento baseada em sinais concretos, rejeicao de
    anti-padrao 'complex', contratos estruturados, cache delimitado e limites advisory.
    Compativel com PowerShell 5.1 e PowerShell 7. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationAdvisorEscalation.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1')

$passed = 0
$total = 0

function Assert-Advisor([bool]$Condition, [string]$Message) {
    $script:total++
    if (-not $Condition) {
        throw "FAIL: $Message"
    }
    $script:passed++
    Write-Host "[PASS] $Message"
}

# 1. Anti-padrao: rejeitar escalonamento apenas por ser 'complex'
$antiCheck = Test-AdvisorEscalationSignal -Signal 'complex' -Justification 'Tarefa e muito complexa'
Assert-Advisor ($antiCheck.Admitted -eq $false) "Escalonamento baseado puramente em 'complex' e rejeitado"
Assert-Advisor ($antiCheck.Reason -match 'Anti-pattern') "Mensagem explicita de anti-padrao"

# 2. Informacao faltando: rejeitar escalonamento, exigir recuperacao via T0/T2
$infoCheck = Test-AdvisorEscalationSignal -Signal 'conflicting_evidence' -Justification 'Faltam logs do teste' -InformationMissing $true
Assert-Advisor ($infoCheck.Admitted -eq $false) "Informacao ausente rejeita escalonamento para Advisor"
Assert-Advisor ($infoCheck.Reason -match 'retrieve evidence via T0/T2') "Instrui recuperar evidencia antes de escalar"

# 3. Validacao dos 7 sinais concretos
$validSignals = @(
    'consequential_alternatives',
    'repeated_failure_no_new_info',
    'conflicting_evidence',
    'reasoning_gap',
    'complex_cross_component_decision',
    'verified_deadlock',
    'risk_asymmetry'
)

foreach ($sig in $validSignals) {
    $chk = Test-AdvisorEscalationSignal -Signal $sig -Justification "Justificativa factual suficiente para $sig"
    Assert-Advisor ($chk.Admitted -eq $true) "Sinal concreto admitido: $sig"
}

# 4. Sinal desconhecido
$badSig = Test-AdvisorEscalationSignal -Signal 'random_guess' -Justification 'Nao sei o que fazer'
Assert-Advisor ($badSig.Admitted -eq $false) "Sinal nao homologado e rejeitado"

# 5. Justificativa vazia ou curta demais
$shortJust = Test-AdvisorEscalationSignal -Signal 'verified_deadlock' -Justification 'curto'
Assert-Advisor ($shortJust.Admitted -eq $false) "Justificativa muito curta e rejeitada"

# 6. Invocacao do Advisor sem probe: Fail-Closed com PROOF_ABSENT (sem recomendacao ficticia)
Clear-AdvisorConsultationCache

$req = @{
    task_id               = 'TASK-TEST-001'
    trigger_signal        = 'verified_deadlock'
    justification         = 'Dois workers falharam com IOException concorrente sem nova hipotese'
    question              = 'Devemos adotar FileShare.ReadWrite ou mutex nomeado de processo?'
    context_summary       = 'Concorrencia entre processos no Windows bloqueia handle'
    alternatives_evaluated = @('FileShare.ReadWrite', 'Global Mutex')
    constraints           = @('Compativel com PS 5.1 e PS 7')
    known_evidence        = @('IOException line 42')
    head_sha              = 'abcdef1234567890abcdef1234567890abcdef12'
}

$modelSel = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex'
$resp = Invoke-AdvisorConsultation -Request $req -ModelRouterSelection $modelSel -DisableNativeExecutor

Assert-Advisor ($resp.Status -eq 'PROOF_ABSENT') "Consulta sem despacho nativo retorna PROOF_ABSENT honesto"
Assert-Advisor ($null -eq $resp.RecommendedOption) "Nunca retorna recomendacao fabricada sem consulta real"
Assert-Advisor ($null -eq $resp.ActionableNextStep) "Sem acao acionavel sem consulta real"
Assert-Advisor ($resp.Reason -in @('NATIVE_DISPATCH_UNAVAILABLE', 'MODEL_PROVIDER_CREDENTIAL_ABSENT')) "Motivo explicita indisponibilidade de despacho nativo ou credencial ausente"
Assert-Advisor ($resp.IsAdvisory -eq $true) "Advisor e estritamente advisory"
Assert-Advisor ($resp.Authoritative -eq $false) "Advisor nunca e autoritativo"
Assert-Advisor ($resp.FromCache -eq $false) "Primeira consulta nao vem do cache"

# 6b. Invocacao do Advisor com Probe/Executor efetivo
Clear-AdvisorConsultationCache
$mockProbe = {
    param($r, $m)
    return [pscustomobject]@{
        Status               = 'COMPLETED'
        ConsultationId       = "ADV-PROBE-001"
        RecommendedOption    = "Adotar Exponential Backoff"
        ActionableNextStep   = "Aplicar fix delimitado em Concurrency.ps1"
        ModelTierUsed        = $m.Tier
        ModelTokenUsed       = $m.ModelToken
        IsAdvisory           = $true
        Authoritative        = $false
        FromCache            = $false
    }
}
$probedResp = Invoke-AdvisorConsultation -Request $req -ModelRouterSelection $modelSel -AdvisorProbe $mockProbe
Assert-Advisor ($probedResp.Status -eq 'COMPLETED') "Consulta com probe retorna Status COMPLETED"
Assert-Advisor ($probedResp.RecommendedOption -eq 'Adotar Exponential Backoff') "Retorna opcao recomendada efetiva"
Assert-Advisor ($probedResp.ActionableNextStep -eq 'Aplicar fix delimitado em Concurrency.ps1') "Retorna proxima acao acionavel"
Assert-Advisor ($probedResp.FromCache -eq $false) "Primeira consulta nao vem do cache"

# 7. Cache delimitado de consultas (evita duplicacao de tokens)
$respCached = Invoke-AdvisorConsultation -Request $req -ModelRouterSelection $modelSel -AdvisorProbe $mockProbe
Assert-Advisor ($respCached.FromCache -eq $true) "Segunda consulta com mesmos parametros vem do cache"
Assert-Advisor ($respCached.ConsultationId -eq $probedResp.ConsultationId) "Mesmo ConsultationId recuperado do cache"

# 8. Rejeicao quando sinal for invalido no fluxo completo
$badReq = @{
    task_id        = 'TASK-TEST-002'
    trigger_signal = 'complex'
    justification  = 'complexidade alta apenas'
    question       = 'Como fazer?'
}
$badResp = Invoke-AdvisorConsultation -Request $badReq
Assert-Advisor ($badResp.Status -eq 'REJECTED') "Requisicao com sinal invalido e rejeitada no fluxo completo"
Assert-Advisor ($badResp.FromCache -eq $false) "Requisicao rejeitada nao vem do cache"

Write-Host "Total: $total | Passed: $passed | Failed: 0"
