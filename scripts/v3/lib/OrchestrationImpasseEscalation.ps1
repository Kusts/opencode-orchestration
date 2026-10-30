<#!
.SYNOPSIS
    Etapa 3 FULL_DELIVERY — geracao automatica de sinal de impasse.
.DESCRIPTION
    Modulo puro (PS 5.1, sem side effects) que, dado um delta de progresso
    (OrchestrationGoalProgress) e o estado da tarefa, gera um sinal de
    impasse estruturado para escalonamento automatico de Debugger, Jev,
    Advisor e Model Router. Nao executa nada, nao concede autoridade, nao
    escreve DONE. A decisao final de escalonamento permanece com o Planner
    (control plane); este modulo apenas produz o sinal e a recomendacao.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-IEFieldValue {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    }
    catch { return $Default }
}

function Test-IEImpasseSignal {
    <#
    .SYNOPSIS
        Decide se ha impasse a partir do delta de progresso e do estado.
    .DESCRIPTION
        Retorna um envelope com impasse=$true quando:
          - stagnation_count >= threshold (default 3), OU
          - a ultima falha foi terminal, OU
          - houve regressao (meaningful=$false com reason 'regressed').
        Caso contrario, impasse=$false.
    #>
    [CmdletBinding()]
    param(
        $ProgressDelta = $null,
        [int]$StagnationThreshold = 3,
        [string]$LastFailure = '',
        [string]$TaskRisk = 'low'
    )
    try {
        $stagnation = 0
        try { $stagnation = [int](Get-IEFieldValue $ProgressDelta 'stagnation_count' 0) } catch { $stagnation = 0 }
        $meaningful = $true
        try { $meaningful = [bool](Get-IEFieldValue $ProgressDelta 'meaningful' $true) } catch { $meaningful = $true }
        $reason = ''
        try { $reason = [string](Get-IEFieldValue $ProgressDelta 'reason' '') } catch { $reason = '' }

        $risk = ([string]$TaskRisk).Trim().ToLowerInvariant()
        if ($risk -notin @('low','medium','high','critical')) { $risk = 'medium' }

        $isImpasse = $false
        $impasseReason = ''
        $modelAction = 'hold-tier'
        if ($stagnation -ge $StagnationThreshold -and $StagnationThreshold -gt 0) {
            $isImpasse = $true
            $impasseReason = 'stagnation-threshold'
        }
        elseif ($LastFailure -ceq 'terminal') {
            $isImpasse = $true
            $impasseReason = 'terminal-failure'
        }
        elseif ((-not $meaningful) -and ($reason -ceq 'regressed')) {
            $isImpasse = $true
            $impasseReason = 'regression'
        }

        if ($isImpasse -and ($risk -in @('high','critical'))) {
            $modelAction = 'escalate-tier'
        }

        return [pscustomobject]@{
            impasse = [bool]$isImpasse
            reason = [string]$impasseReason
            stagnation_count = [int]$stagnation
            meaningful = [bool]$meaningful
            task_risk = [string]$risk
            # Escalonamento recomendado (advisory, nao autoridade)
            debugger_recommended = [bool]$isImpasse
            jev_recommended = [bool]$isImpasse
            advisor_recommended = [bool]($isImpasse -and ($risk -in @('medium','high','critical')))
            model_router_action = [string]$modelAction
            grants_authority = $false
            done_approved = $false
            verified_pass = $false
        }
    }
    catch {
        return [pscustomobject]@{
            impasse = $false; reason = 'internal-error'; stagnation_count = 0
            meaningful = $false; task_risk = 'medium'
            debugger_recommended = $false; jev_recommended = $false
            advisor_recommended = $false; model_router_action = 'hold-tier'
            grants_authority = $false; done_approved = $false; verified_pass = $false
        }
    }
}