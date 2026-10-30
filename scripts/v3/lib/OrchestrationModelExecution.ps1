<#!
.SYNOPSIS
    Etapa 4 FULL_DELIVERY — modelo selecionado efetivamente utilizado.
.DESCRIPTION
    Dot-sourceable, sem execucao no load. PS 5.1, ASCII-only, sem rede/spawn.
    Reutiliza OrchestrationModelRouter.ps1; nao cria config concorrente com
    Agent Config (nunca escreve models.jsonc, nunca edita AgentProfile).
    Invoke-OrchestrationModelExecution resolve a selecao, emite recibo
    (agente, tarefa, modelo solicitado/efetivo, tier, motivo, fallback),
    projeta o parametro `model` oficialmente suportado pelo subagent do
    OpenCode V2 e verifica via Test-ExecutedModelVerification.
    Regras: barato por padrao; escala so com FailureCount>=2 e custo
    autorizado; falha de contexto (missing-context) nunca escala por si so;
    override de modelo desabilitado e recusado; sem prova de override nativo
    o efetivo e o fallback conservador (PROOF_ABSENT, fail-closed).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

function Get-MEValue {
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

function Invoke-OrchestrationModelExecution {
    [CmdletBinding()]
    param(
        [string]$AgentName = '',
        [string]$TaskId = '',
        [string]$Risk = 'low',
        [string]$Complexity = 'simple',
        [int]$FailureCount = 0,
        [bool]$ProviderCostAuthorized = $false,
        [bool]$IsContextFailure = $false,
        [string]$RequestedModelOverride = '',
        [bool]$NativeModelOverrideProven = $false,
        $ExecutedModelEvent = $null,
        $AuthorizedFallback = $null
    )
    try {
        $lib = Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1'
        if (Test-Path -LiteralPath $lib) { . $lib }
        $agent = ([string]$AgentName).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($agent)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-agent'; grants_authority = $false }
        }
        # Falha de contexto nao e incapacidade do modelo: nunca escala so por ela.
        $fc = $FailureCount
        if ($IsContextFailure) { $fc = 0 }
        # Override desabilitado recusado via politica (ex: deepseek disabled).
        if (-not [string]::IsNullOrWhiteSpace($RequestedModelOverride)) {
            $pol = Get-OrchestrationModelRoutingPolicy
            $polObj = if ($pol.Status -eq 'POLICY_LOADED') { $pol.Policy } else { $null }
            if ($null -ne $polObj) {
                foreach ($prop in @($polObj.models.PSObject.Properties)) {
                    $mid = [string]$prop.Value.model_id
                    if ($mid -ceq ([string]$RequestedModelOverride).Trim()) {
                        if (-not [bool]$prop.Value.enabled) {
                            return [pscustomobject]@{ ok = $false; reason = 'model-disabled'; requested_model = $RequestedModelOverride; grants_authority = $false }
                        }
                    }
                }
            }
        }
        $sel = $null
        try {
            $sel = Resolve-OrchestrationModelSelection -AgentName $agent -Risk $Risk -Complexity $Complexity -FailureCount $fc -ProviderCostAuthorized $ProviderCostAuthorized -IgnoreUserConfig $true -NativeModelOverrideProven $NativeModelOverrideProven
        } catch { $sel = $null }
        if ($null -eq $sel) {
            return [pscustomobject]@{ ok = $false; reason = 'selection-failed'; grants_authority = $false }
        }
        if ([string](Get-MEValue $sel 'Status' '') -ne 'SELECTED') {
            return [pscustomobject]@{ ok = $false; reason = ([string](Get-MEValue $sel 'Status' 'rejected')); selection = $sel; grants_authority = $false }
        }
        # T4 sem custo autorizado nunca e executado: degradado ja aplicado pelo Router; reafirma aqui.
        if (([string]$sel.Tier -ceq 'T4') -and (-not [bool]$sel.ProviderCostAuthorized)) {
            return [pscustomobject]@{ ok = $false; reason = 'unauthorized-escalation-refused'; selection = $sel; grants_authority = $false }
        }
        $receipt = $null
        try { $receipt = Get-OrchestrationModelRouterReceipt -Selection $sel } catch { $receipt = $null }
        if ($null -eq $receipt) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-invariant-violation'; selection = $sel; grants_authority = $false }
        }
        # Parametro oficialmente suportado pelo subagent OpenCode V2: `model`.
        $effective = [string]$sel.CatalogModel
        if (-not $NativeModelOverrideProven) { $effective = [string]$sel.FallbackToken }
        $ver = $null
        try { $ver = Test-ExecutedModelVerification -RequestedSelection $sel -ExecutedModelEvent $ExecutedModelEvent -NativeModelOverrideProven $NativeModelOverrideProven -AuthorizedFallback $AuthorizedFallback } catch { $ver = $null }
        $log = [ordered]@{
            agent = $agent; task_id = ([string]$TaskId).Trim()
            requested_model = [string]$sel.CatalogModel; effective_model = $effective
            tier = [string]$sel.Tier; reason = [string]$sel.SelectionReason
            fallback_tier = [string]$sel.FallbackTier; cost_authorized = [bool]$sel.ProviderCostAuthorized
            proof_status = if ($null -ne $ver) { [string]$ver.ProofStatus } else { 'PROOF_ABSENT' }
        }
        return [pscustomobject]@{
            ok = $true; reason = 'executed'; selection = $sel; receipt = $receipt
            subagent_model_param = $effective; execution_log = $log; verification = $ver
            grants_authority = $false; done_approved = $false
        }
    } catch {
        return [pscustomobject]@{ ok = $false; reason = 'execution-internal-error'; grants_authority = $false }
    }
}
