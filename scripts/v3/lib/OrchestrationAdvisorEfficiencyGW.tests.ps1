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

# GW-ADVISOR-06: Impasse comprovado (verified_deadlock) escala para engineering-advisor em T4
$req06 = @{
    task_id        = 'GW-06-DEADLOCK'
    trigger_signal = 'verified_deadlock'
    justification  = 'Falha repetida de concorrência com FileShare.None e thread lock'
    question       = 'Como estruturar o lock de concorrência cross-process no Windows?'
}
$sel06 = Resolve-OrchestrationModelSelection -AgentName 'engineering-advisor' -Complexity 'complex'
$resp06 = Invoke-AdvisorConsultation -Request $req06 -ModelRouterSelection $sel06
Assert-GW ($resp06.Status -eq 'COMPLETED') 'GW-ADVISOR-06' "Consulta de deadlock concluida com sucesso"
Assert-GW ($resp06.ModelTierUsed -eq 'T4') 'GW-ADVISOR-06' "Advisor escalado para Tier T4"
Assert-GW ($resp06.IsAdvisory -eq $true -and $resp06.Authoritative -eq $false) 'GW-ADVISOR-06' "Advisor atua com limites estritamente consultivos"

# GW-ADVISOR-07: Consulta repetida com mesmo contexto recupera do cache SHA256
$resp07Cached = Invoke-AdvisorConsultation -Request $req06 -ModelRouterSelection $sel06
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

Write-Host "`nGolden Workflows GW-ADVISOR-01 a GW-ADVISOR-08: PASS ($passed / $total assertions)"
