<#!
.SYNOPSIS
    Etapa 3 FULL_DELIVERY — consumo automatico do sinal de impasse.
.DESCRIPTION
    Dot-sourceable library (no execution on load). PS 5.1, ASCII-only,
    no network, no spawn. Reutiliza OrchestrationImpasseEscalation.ps1
    (Test-IEImpasseSignal) sem nova maquina de estados.

    Invoke-OrchestrationImpasseConsumption recebe progresso + historico +
    orcamento e devolve UMA intervencao (nunca fan-out). Classifica causa:
      missing-context -> gather-context (Explorer)
      technical-reproducible -> debug-reproduce (Debugger)
      model-limitation -> advisory-consult (Advisor/Jev, escalate-tier se high/critical)
      legit-block -> wait-legit (nenhum consultor, sem custo)
    Dedup: mesma (failure_kind + consultant) ja presente em History => skipped.
    Orcamento: MaxInterventions esgotado => blocked sem consultor.
    Consultores fornecem evidencia/recomendacao; grants_authority=false sempre.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

function Get-ICCValue {
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
    } catch { return $Default }
}

function Invoke-OrchestrationImpasseConsumption {
    [CmdletBinding()]
    param(
        $ProgressDelta = $null,
        [string]$LastFailure = '',
        [string]$TaskRisk = 'low',
        [string]$FailureKind = '',
        $History = @(),
        [int]$MaxInterventions = 3,
        [int]$StagnationThreshold = 3
    )
    try {
        $lib = Join-Path $PSScriptRoot 'OrchestrationImpasseEscalation.ps1'
        if (Test-Path -LiteralPath $lib) { . $lib }
        $cmd = Get-Command Test-IEImpasseSignal -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            return [pscustomobject]@{ ok = $false; reason = 'impasse-signal-unavailable'; impasse = $false; consultant = 'none'; grants_authority = $false }
        }
        $sig = $null
        try { $sig = Test-IEImpasseSignal -ProgressDelta $ProgressDelta -StagnationThreshold $StagnationThreshold -LastFailure $LastFailure -TaskRisk $TaskRisk } catch { $sig = $null }
        if ($null -eq $sig) {
            return [pscustomobject]@{ ok = $false; reason = 'impasse-signal-failed'; impasse = $false; consultant = 'none'; grants_authority = $false }
        }
        if (-not [bool](Get-ICCValue $sig 'impasse' $false)) {
            return [pscustomobject]@{ ok = $true; reason = 'no-impasse'; impasse = $false; consultant = 'none'; intervention = 'none'; signal = $sig; budget_remaining = $MaxInterventions; dedup_skipped = $false; grants_authority = $false; done_approved = $false }
        }
        $kind = ([string]$FailureKind).Trim().ToLowerInvariant()
        if ($kind -notin @('missing-context','technical-reproducible','model-limitation','legit-block')) {
            $kind = 'technical-reproducible'
        }
        $consultant = 'none'
        $intervention = 'none'
        switch ($kind) {
            'missing-context' { $consultant = 'explorer'; $intervention = 'gather-context' }
            'technical-reproducible' { $consultant = 'debugger'; $intervention = 'debug-reproduce' }
            'model-limitation' {
                if (([string]$TaskRisk).Trim().ToLowerInvariant() -in @('high','critical')) { $consultant = 'advisor'; $intervention = 'advisory-consult-escalate' }
                else { $consultant = 'jev'; $intervention = 'advisory-consult' }
            }
            'legit-block' { $consultant = 'none'; $intervention = 'wait-legit' }
        }
        if ($intervention -ceq 'wait-legit') {
            return [pscustomobject]@{ ok = $true; reason = 'legit-block-no-consult'; impasse = $true; consultant = 'none'; intervention = $intervention; failure_kind = $kind; signal = $sig; budget_remaining = $MaxInterventions; dedup_skipped = $false; grants_authority = $false; done_approved = $false; verified_pass = $false }
        }
        $used = 0
        try { $used = @($History).Count } catch { $used = 0 }
        if ($used -ge $MaxInterventions) {
            return [pscustomobject]@{ ok = $true; reason = 'budget-exhausted'; impasse = $true; consultant = 'none'; intervention = 'blocked-budget'; failure_kind = $kind; signal = $sig; budget_remaining = 0; dedup_skipped = $false; grants_authority = $false; done_approved = $false }
        }
        $dup = $false
        foreach ($h in @($History)) {
            $hk = ([string](Get-ICCValue $h 'failure_kind' '')).Trim().ToLowerInvariant()
            $hc = ([string](Get-ICCValue $h 'consultant' '')).Trim().ToLowerInvariant()
            if (($hk -ceq $kind) -and ($hc -ceq $consultant)) { $dup = $true; break }
        }
        if ($dup) {
            return [pscustomobject]@{ ok = $true; reason = 'duplicate-suppressed'; impasse = $true; consultant = $consultant; intervention = $intervention; failure_kind = $kind; signal = $sig; budget_remaining = ($MaxInterventions - $used); dedup_skipped = $true; grants_authority = $false; done_approved = $false }
        }
        $entry = [ordered]@{ failure_kind = $kind; consultant = $consultant; intervention = $intervention; at = ([DateTime]::UtcNow.ToString('o')) }
        return [pscustomobject]@{
            ok = $true; reason = 'consult'; impasse = $true; consultant = $consultant; intervention = $intervention
            failure_kind = $kind; signal = $sig; history_entry = $entry
            budget_remaining = ($MaxInterventions - $used - 1); dedup_skipped = $false
            grants_authority = $false; done_approved = $false; verified_pass = $false
        }
    } catch {
        return [pscustomobject]@{ ok = $false; reason = 'consumption-internal-error'; impasse = $false; consultant = 'none'; grants_authority = $false }
    }
}
