<#!
.SYNOPSIS
    Etapa 3 REAL — sinal consumido + consultor REAL acionado + retomada.
.DESCRIPTION
    Hermetico: temp dirs, sem rede/spawn. Cenario: fixture com Task que
    falha 3x por falta de contexto (stagnation 3). GREEN: consumo classifica
    missing-context e aciona o consultor via -ConsultantExecutor injetavel
    (probe registra chamadas e retorna recommendation); o retorno e
    incorporado ao planejamento (failed_strategies + contexto) e a execucao
    retoma com progresso. Sem executor injetado, o executor real default
    interno coleta evidencia filesystem. PS 5.1, ASCII-only.
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

function New-ICProbe {
    $sb = {
        param($Consultant, $Intervention, $FailureKind, $TaskRisk)
        $script:icCalls = @($script:icCalls) + @(@{ consultant = ([string]$Consultant); intervention = ([string]$Intervention); failure_kind = ([string]$FailureKind); task_risk = ([string]$TaskRisk) })
        return @{ evidence = ('probe-evidence:' + ([string]$Consultant)); recommendation = ('probe-recommendation:' + ([string]$Intervention)); recommendation_only = $false; error = '' }
    }
    return $sb
}

function Get-ICVal {
    param($Object, [string]$Name)
    try {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $null
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $null
    } catch { return $null }
}

try {
    # IC1: consumo ok + impasse + explorer via executor injetavel
    $script:icCalls = @()
    $sig = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low' -FailureKind 'missing-context' -History @() -MaxInterventions 3 -ConsultantExecutor (New-ICProbe)
    Assert-IC ([bool]$sig.ok) '[IC1] consumo ok' ([string]$sig.reason)
    Assert-IC ([bool]$sig.impasse) '[IC1] impasse detectado' ''
    Assert-IC (([string]$sig.consultant -ceq 'explorer')) '[IC1] missing-context => explorer' ([string]$sig.consultant)
    Assert-IC (([string]$sig.intervention -ceq 'gather-context')) '[IC1] intervention gather-context' ([string]$sig.intervention)
    Assert-IC (-not [bool]$sig.grants_authority) '[IC1] sem autoridade' ''

    # IC2: consultor acionado via executor injetavel + retorno incorporavel
    Assert-IC ((@($script:icCalls).Count -eq 1)) '[IC2] consultor acionado 1x' ([string]@($script:icCalls).Count)
    $cons2 = Get-ICVal $sig 'consultation'
    $rec2 = [string](Get-ICVal $cons2 'recommendation')
    Assert-IC ((-not [string]::IsNullOrWhiteSpace($rec2))) '[IC2] retorno incorporavel' $rec2

    # IC3: duplicata suprimida, executor NAO reacioniado, orcamento preservado
    $before3 = @($script:icCalls).Count
    $history = @(@{ failure_kind = 'missing-context'; consultant = 'explorer' })
    $sig2 = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low' -FailureKind 'missing-context' -History $history -MaxInterventions 3 -ConsultantExecutor (New-ICProbe)
    Assert-IC ([bool]$sig2.dedup_skipped) '[IC3] duplicata suprimida (sem fan-out)' ([string]$sig2.reason)
    Assert-IC (([int]$sig2.budget_remaining -eq 2)) '[IC3] orcamento preservado' ([string]$sig2.budget_remaining)
    Assert-IC ((@($script:icCalls).Count -eq $before3)) '[IC3] executor nao reacioniado' ''

    # IC4: tecnico => debugger via executor injetavel
    $script:icCalls = @()
    $t = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low' -FailureKind 'technical-reproducible' -History @() -MaxInterventions 3 -ConsultantExecutor (New-ICProbe)
    Assert-IC (([string]$t.consultant -ceq 'debugger')) '[IC4] tecnico => debugger' ([string]$t.consultant)
    Assert-IC ((@($script:icCalls).Count -eq 1) -and ([string]$script:icCalls[0].consultant -ceq 'debugger')) '[IC4] executor recebeu debugger' ''

    # IC5: model-limitation high => advisor via executor injetavel
    $script:icCalls = @()
    $m = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'high' -FailureKind 'model-limitation' -History @() -MaxInterventions 3 -ConsultantExecutor (New-ICProbe)
    Assert-IC (([string]$m.consultant -ceq 'advisor')) '[IC5] model high => advisor' ([string]$m.consultant)
    Assert-IC ((@($script:icCalls).Count -eq 1) -and ([string]$script:icCalls[0].consultant -ceq 'advisor')) '[IC5] executor recebeu advisor' ''

    # IC6: legit-block sem consultor, executor nao chamado
    $script:icCalls = @()
    $l = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low' -FailureKind 'legit-block' -History @() -MaxInterventions 3 -ConsultantExecutor (New-ICProbe)
    Assert-IC (([string]$l.consultant -ceq 'none') -and ([string]$l.intervention -ceq 'wait-legit')) '[IC6] legit-block sem consultor' ([string]$l.intervention)
    Assert-IC ((@($script:icCalls).Count -eq 0)) '[IC6] executor nao chamado' ''

    # IC7: orcamento esgotado => blocked, executor nao chamado
    $script:icCalls = @()
    $full = @(@{failure_kind='a';consultant='x'},@{failure_kind='b';consultant='y'},@{failure_kind='c';consultant='z'})
    $b = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low' -FailureKind 'technical-reproducible' -History $full -MaxInterventions 3 -ConsultantExecutor (New-ICProbe)
    Assert-IC (([string]$b.intervention -ceq 'blocked-budget') -and ([string]$b.consultant -ceq 'none')) '[IC7] budget esgotado bloqueia' ([string]$b.reason)
    Assert-IC ((@($script:icCalls).Count -eq 0)) '[IC7] executor nao chamado' ''

    # IC8: sem impasse => nenhum consultor, executor nao chamado
    $script:icCalls = @()
    $n = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 0; meaningful = $true; reason = '' } -TaskRisk 'low' -FailureKind 'missing-context' -History @() -MaxInterventions 3 -ConsultantExecutor (New-ICProbe)
    Assert-IC ((-not [bool]$n.impasse) -and ([string]$n.consultant -ceq 'none')) '[IC8] sem impasse sem consultor' ''
    Assert-IC ((@($script:icCalls).Count -eq 0)) '[IC8] executor nao chamado' ''

    # IC9: executor chamado exatamente 1x com consultant correto + recommendation incorporada
    $script:icCalls = @()
    $r9 = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low' -FailureKind 'missing-context' -History @() -MaxInterventions 3 -ConsultantExecutor (New-ICProbe)
    $cons9 = Get-ICVal $r9 'consultation'
    $rec9 = [string](Get-ICVal $cons9 'recommendation')
    $ev9 = [string](Get-ICVal $cons9 'evidence')
    Assert-IC ((@($script:icCalls).Count -eq 1)) '[IC9] executor chamado exatamente 1x' ([string]@($script:icCalls).Count)
    Assert-IC ((@($script:icCalls).Count -eq 1) -and ([string]$script:icCalls[0].consultant -ceq 'explorer')) '[IC9] consultant correto no executor' ([string]$script:icCalls[0].consultant)
    Assert-IC ((-not [string]::IsNullOrWhiteSpace($rec9)) -and (-not [string]::IsNullOrWhiteSpace($ev9))) '[IC9] consultation com evidence+recommendation' ($ev9 + ' | ' + $rec9)
    Assert-IC ((-not [bool]$r9.grants_authority) -and (-not [bool](Get-ICVal $r9 'done_approved'))) '[IC9] sem grants_authority/done_approved' ''

    # IC10 negativo: probe que lanca => ok=false ou consultation com erro, sem grants e sem fan-out
    $badProbe = {
        param($Consultant, $Intervention, $FailureKind, $TaskRisk)
        throw 'probe-boom'
    }
    $r10 = Invoke-OrchestrationImpasseConsumption -ProgressDelta @{ stagnation_count = 3; meaningful = $false; reason = 'no-change' } -TaskRisk 'low' -FailureKind 'missing-context' -History @() -MaxInterventions 3 -ConsultantExecutor $badProbe
    $cons10 = Get-ICVal $r10 'consultation'
    $err10 = [string](Get-ICVal $cons10 'error')
    $negOk = ((-not [bool]$r10.ok) -or (-not [string]::IsNullOrWhiteSpace($err10)))
    Assert-IC ($negOk) '[IC10] falha do executor contida' ([string]$r10.reason)
    Assert-IC (-not [bool]$r10.grants_authority) '[IC10] sem grants_authority' ''
    $singleConsultant = ($r10.consultant -is [string]) -and ([string]$r10.consultant -ceq 'explorer')
    Assert-IC ($singleConsultant) '[IC10] sem fan-out (consultor unico)' ([string]$r10.consultant)

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
