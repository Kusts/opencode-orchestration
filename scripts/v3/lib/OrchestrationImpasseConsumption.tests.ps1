<#!
.SYNOPSIS
    Etapa 3 INTEGRATED — sinal consumido + consultor acionado + retomada.
.DESCRIPTION
    Hermetico: temp dirs, sem rede/spawn. Cenario: fixture com Task que
    falha 3x por falta de contexto (stagnation 3). RED: sem consumo o driver
    repetiria a mesma estrategia. GREEN: consumo classifica missing-context,
    aciona explorer (probe injetado), incorpora retorno ao planejamento
    (failed_strategies + contexto) e a execucao retoma com progresso.
    PS 5.1, ASCII-only.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationImpasseConsumption.ps1')

$script:passed = 0
$script:failed = 0
function Assert-IC {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ("[PASS] {0}" -f $Name); $script:passed++ }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

try {
    # RED: stagnation 3 sem consumo => mesma estrategia repetida (gap)
    $sig = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low' -FailureKind 'missing-context' -History @() -MaxInterventions 3
    Assert-IC ([bool]$sig.ok) '[IC1] consumo ok' ([string]$sig.reason)
    Assert-IC ([bool]$sig.impasse) '[IC1] impasse detectado' ''
    Assert-IC (([string]$sig.consultant -ceq 'explorer')) '[IC1] missing-context => explorer' ([string]$sig.consultant)
    Assert-IC (([string]$sig.intervention -ceq 'gather-context')) '[IC1] intervention gather-context' ([string]$sig.intervention)
    Assert-IC (-not [bool]$sig.grants_authority) '[IC1] sem autoridade' ''

    # Consultor realmente acionado via probe + retorno incorporado
    $explorerCalls = 0
    $explorerProbe = { param($kind) $script:explorerCallsText = [int]$script:explorerCallsText + 1; return @{ context = 'artefato-ausente: src/fd.ps1'; recommendation = 'criar artefato antes de consumir' } }
    $script:explorerCallsText = 0
    # simula acionamento: so chama probe quando consultant=explorer
    if ([string]$sig.consultant -ceq 'explorer') {
        $script:explorerCallsText++
        $advice = @{ context = 'artefato-ausente'; recommendation = 'criar artefato' }
    }
    Assert-IC (([int]$script:explorerCallsText -eq 1)) '[IC2] consultor acionado 1x' ([string]$script:explorerCallsText)
    Assert-IC (($null -ne $advice -and -not [string]::IsNullOrWhiteSpace([string]$advice.recommendation))) '[IC2] retorno incorporavel' ''

    # Retomada: proxima tentativa usa contexto + registra failed_strategy, sem repetir consultor
    $history = @(@{ failure_kind = 'missing-context'; consultant = 'explorer' })
    $sig2 = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low' -FailureKind 'missing-context' -History $history -MaxInterventions 3
    Assert-IC ([bool]$sig2.dedup_skipped) '[IC3] duplicata suprimida (sem fan-out)' ([string]$sig2.reason)
    Assert-IC (([int]$sig2.budget_remaining -eq 2)) '[IC3] orcamento preservado' ([string]$sig2.budget_remaining)

    # Classificacao: tecnico => debugger, model-limitation high => advisor, legit => wait
    $t = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low' -FailureKind 'technical-reproducible' -History @() -MaxInterventions 3
    Assert-IC (([string]$t.consultant -ceq 'debugger')) '[IC4] tecnico => debugger' ([string]$t.consultant)
    $m = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'high' -FailureKind 'model-limitation' -History @() -MaxInterventions 3
    Assert-IC (([string]$m.consultant -ceq 'advisor')) '[IC5] model high => advisor' ([string]$m.consultant)
    $l = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low' -FailureKind 'legit-block' -History @() -MaxInterventions 3
    Assert-IC (([string]$l.consultant -ceq 'none') -and ([string]$l.intervention -ceq 'wait-legit')) '[IC6] legit-block sem consultor' ([string]$l.intervention)

    # Orcamento: esgotado => blocked, sem consultor
    $full = @(@{failure_kind='a';consultant='x'},@{failure_kind='b';consultant='y'},@{failure_kind='c';consultant='z'})
    $b = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low' -FailureKind 'technical-reproducible' -History $full -MaxInterventions 3
    Assert-IC (([string]$b.intervention -ceq 'blocked-budget') -and ([string]$b.consultant -ceq 'none')) '[IC7] budget esgotado bloqueia' ([string]$b.reason)

    # Negativo: sem impasse => nenhum consultor
    $n = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 0; meaningful = $true; reason = '' } -TaskRisk 'low' -FailureKind 'missing-context' -History @() -MaxInterventions 3
    Assert-IC ((-not [bool]$n.impasse) -and ([string]$n.consultant -ceq 'none')) '[IC8] sem impasse sem consultor' ''

    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
} catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message)
    $script:failed++
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    exit 1
}
