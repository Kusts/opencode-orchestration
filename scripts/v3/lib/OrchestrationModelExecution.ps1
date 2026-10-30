<#!
.SYNOPSIS
    Etapa 4 FULL_DELIVERY - modelo selecionado efetivamente utilizado.
.DESCRIPTION
    Dot-sourceable, sem execucao no load. PS 5.1, ASCII-only, sem rede/spawn.
    Reutiliza OrchestrationModelRouter.ps1; nao cria config concorrente com
    Agent Config (nunca escreve concorrente, nunca edita perfil de agente).
    Taxonomia honesta de status (sem nova maquina de estados):
      SELECTED         - selecao OK, sem dispatch.
      DISPATCHED       - modelo passado a interface real, sem verificacao.
      EXECUTED_VERIFIED - verificacao Test-ExecutedModelVerification com
                         evento real => EXACT_MATCH ou AUTHORIZED_FALLBACK.
      PROOF_ABSENT     - sem prova (sem override provado e sem evento real)
                         => fallback conservador, fail-closed.
    NUNCA retorna reason='executed' sem execucao real verificada.
    Dispatch real e opcional via -DispatchExecutor (scriptblock chamado como
      & $DispatchExecutor -Model <effective> -Agent <agent> -TaskId <id>
    e deve retornar objeto com .Model observado). Sem executor e sem evento
    real => PROOF_ABSENT com effective=fallback conservador.
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

function Write-MEModelEvidence {
    param($EvidenceDir, $Record)
    try {
        if ([string]::IsNullOrWhiteSpace([string]$EvidenceDir)) { return }
        $dir = [string]$EvidenceDir
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][System.IO.Directory]::CreateDirectory($dir)
            }
        } catch { return }
        $line = ($Record | ConvertTo-Json -Compress -Depth 6)
        $target = Join-Path $dir 'model-execution.jsonl'
        [System.IO.File]::AppendAllText($target, $line + [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
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
        $AuthorizedFallback = $null,
        [scriptblock]$DispatchExecutor = $null,
        [string]$EvidenceDir = ''
    )
    try {
        $lib = Join-Path $PSScriptRoot 'OrchestrationModelRouter.ps1'
        if (Test-Path -LiteralPath $lib) { . $lib }
        $agent = ([string]$AgentName).Trim().ToLowerInvariant()
        $taskTrim = ([string]$TaskId).Trim()
        if ([string]::IsNullOrWhiteSpace($agent)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-agent'; status = 'PROOF_ABSENT'; grants_authority = $false }
        }
        $fc = $FailureCount
        if ($IsContextFailure) { $fc = 0 }
        if (-not [string]::IsNullOrWhiteSpace($RequestedModelOverride)) {
            $pol = Get-OrchestrationModelRoutingPolicy
            $polObj = if ($pol.Status -eq 'POLICY_LOADED') { $pol.Policy } else { $null }
            if ($null -ne $polObj) {
                foreach ($prop in @($polObj.models.PSObject.Properties)) {
                    $mid = [string]$prop.Value.model_id
                    if ($mid -ceq ([string]$RequestedModelOverride).Trim()) {
                        if (-not [bool]$prop.Value.enabled) {
                            return [pscustomobject]@{ ok = $false; reason = 'model-disabled'; status = 'PROOF_ABSENT'; requested_model = $RequestedModelOverride; grants_authority = $false }
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
            return [pscustomobject]@{ ok = $false; reason = 'selection-failed'; status = 'PROOF_ABSENT'; grants_authority = $false }
        }
        if ([string](Get-MEValue $sel 'Status' '') -ne 'SELECTED') {
            return [pscustomobject]@{ ok = $false; reason = ([string](Get-MEValue $sel 'Status' 'rejected')); status = 'PROOF_ABSENT'; selection = $sel; grants_authority = $false }
        }
        if (([string]$sel.Tier -ceq 'T4') -and (-not [bool]$sel.ProviderCostAuthorized)) {
            return [pscustomobject]@{ ok = $false; reason = 'unauthorized-escalation-refused'; status = 'PROOF_ABSENT'; selection = $sel; grants_authority = $false }
        }
        $receipt = $null
        try { $receipt = Get-OrchestrationModelRouterReceipt -Selection $sel } catch { $receipt = $null }
        if ($null -eq $receipt) {
            return [pscustomobject]@{ ok = $false; reason = 'receipt-invariant-violation'; status = 'PROOF_ABSENT'; selection = $sel; grants_authority = $false }
        }
        $effective = [string]$sel.CatalogModel
        if (-not $NativeModelOverrideProven) { $effective = [string]$sel.FallbackToken }

        if ($null -ne $DispatchExecutor) {
            $dispatchEvent = $null
            $dispatchErr = ''
            try {
                $dispatchEvent = & $DispatchExecutor -Model $effective -Agent $agent -TaskId $taskTrim
            } catch {
                $dispatchErr = $_.Exception.Message
                $dispatchEvent = $null
            }
            if ($null -eq $dispatchEvent) {
                $logF = [ordered]@{
                    agent = $agent; task_id = $taskTrim
                    requested_model = [string]$sel.CatalogModel; effective_model = $effective
                    tier = [string]$sel.Tier; reason = [string]$sel.SelectionReason
                    fallback_tier = [string]$sel.FallbackTier; cost_authorized = [bool]$sel.ProviderCostAuthorized
                    proof_status = 'PROOF_ABSENT'
                }
                Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'PROOF_ABSENT'; reason = 'dispatch-failed'; effective_model = $effective; error = $dispatchErr })
                return [pscustomobject]@{
                    ok = $false; reason = 'dispatch-failed'; status = 'PROOF_ABSENT'
                    selection = $sel; receipt = $receipt
                    subagent_model_param = $effective; execution_log = $logF; verification = $null
                    grants_authority = $false; done_approved = $false
                }
            }
            $observed = [string](Get-MEValue $dispatchEvent 'Model' $null)
            if ([string]::IsNullOrWhiteSpace($observed)) { $observed = [string](Get-MEValue $dispatchEvent 'model' '') }
            if ([string]::IsNullOrWhiteSpace($observed)) {
                $logD = [ordered]@{
                    agent = $agent; task_id = $taskTrim
                    requested_model = [string]$sel.CatalogModel; effective_model = $effective
                    tier = [string]$sel.Tier; reason = [string]$sel.SelectionReason
                    fallback_tier = [string]$sel.FallbackTier; cost_authorized = [bool]$sel.ProviderCostAuthorized
                    proof_status = 'DISPATCHED_UNVERIFIED'
                }
                Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'DISPATCHED'; reason = 'dispatched-unverified'; effective_model = $effective })
                return [pscustomobject]@{
                    ok = $true; reason = 'dispatched-unverified'; status = 'DISPATCHED'
                    selection = $sel; receipt = $receipt
                    subagent_model_param = $effective; execution_log = $logD; verification = $null
                    dispatch_event = $dispatchEvent
                    grants_authority = $false; done_approved = $false
                }
            }
            $ver = $null
            try { $ver = Test-ExecutedModelVerification -RequestedSelection $sel -ExecutedModelEvent $dispatchEvent -NativeModelOverrideProven $true -AuthorizedFallback $AuthorizedFallback } catch { $ver = $null }
            $proof = if ($null -ne $ver) { [string]$ver.ProofStatus } else { 'PROOF_ABSENT' }
            $logV = [ordered]@{
                agent = $agent; task_id = $taskTrim
                requested_model = [string]$sel.CatalogModel; effective_model = $effective
                tier = [string]$sel.Tier; reason = [string]$sel.SelectionReason
                fallback_tier = [string]$sel.FallbackTier; cost_authorized = [bool]$sel.ProviderCostAuthorized
                proof_status = $proof
            }
            if (($proof -ceq 'EXACT_MATCH') -or ($proof -ceq 'AUTHORIZED_FALLBACK')) {
                Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'EXECUTED_VERIFIED'; reason = 'executed-verified'; effective_model = $effective; observed_model = $observed; proof_status = $proof })
                return [pscustomobject]@{
                    ok = $true; reason = 'executed-verified'; status = 'EXECUTED_VERIFIED'
                    selection = $sel; receipt = $receipt
                    subagent_model_param = $effective; execution_log = $logV; verification = $ver
                    dispatch_event = $dispatchEvent
                    grants_authority = $false; done_approved = $false
                }
            }
            $rsn = 'proof-absent-mismatch'
            if ($proof -ceq 'UNAUTHORIZED_MISMATCH') { $rsn = 'unauthorized-mismatch' }
            Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'PROOF_ABSENT'; reason = $rsn; effective_model = $effective; observed_model = $observed; proof_status = $proof })
            return [pscustomobject]@{
                ok = $false; reason = $rsn; status = 'PROOF_ABSENT'
                selection = $sel; receipt = $receipt
                subagent_model_param = $effective; execution_log = $logV; verification = $ver
                dispatch_event = $dispatchEvent
                grants_authority = $false; done_approved = $false
            }
        }

        $hasEvent = ($null -ne $ExecutedModelEvent)
        $obsDirect = ''
        if ($hasEvent) {
            $obsDirect = [string](Get-MEValue $ExecutedModelEvent 'Model' $null)
            if ([string]::IsNullOrWhiteSpace($obsDirect)) { $obsDirect = [string](Get-MEValue $ExecutedModelEvent 'model' '') }
        }
        if ($hasEvent -and (-not [string]::IsNullOrWhiteSpace($obsDirect))) {
            $ver2 = $null
            try { $ver2 = Test-ExecutedModelVerification -RequestedSelection $sel -ExecutedModelEvent $ExecutedModelEvent -NativeModelOverrideProven $NativeModelOverrideProven -AuthorizedFallback $AuthorizedFallback } catch { $ver2 = $null }
            $proof2 = if ($null -ne $ver2) { [string]$ver2.ProofStatus } else { 'PROOF_ABSENT' }
            $log2 = [ordered]@{
                agent = $agent; task_id = $taskTrim
                requested_model = [string]$sel.CatalogModel; effective_model = $effective
                tier = [string]$sel.Tier; reason = [string]$sel.SelectionReason
                fallback_tier = [string]$sel.FallbackTier; cost_authorized = [bool]$sel.ProviderCostAuthorized
                proof_status = $proof2
            }
            if ((($proof2 -ceq 'EXACT_MATCH') -or ($proof2 -ceq 'AUTHORIZED_FALLBACK')) -and $NativeModelOverrideProven) {
                Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'EXECUTED_VERIFIED'; reason = 'executed-verified'; effective_model = $effective; observed_model = $obsDirect; proof_status = $proof2 })
                return [pscustomobject]@{
                    ok = $true; reason = 'executed-verified'; status = 'EXECUTED_VERIFIED'
                    selection = $sel; receipt = $receipt
                    subagent_model_param = $effective; execution_log = $log2; verification = $ver2
                    grants_authority = $false; done_approved = $false
                }
            }
            $rsn2 = 'proof-absent-fallback'
            if ($proof2 -ceq 'UNAUTHORIZED_MISMATCH') { $rsn2 = 'unauthorized-mismatch' }
            Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'PROOF_ABSENT'; reason = $rsn2; effective_model = $effective; observed_model = $obsDirect; proof_status = $proof2 })
            return [pscustomobject]@{
                ok = $false; reason = $rsn2; status = 'PROOF_ABSENT'
                selection = $sel; receipt = $receipt
                subagent_model_param = $effective; execution_log = $log2; verification = $ver2
                grants_authority = $false; done_approved = $false
            }
        }

        if ($NativeModelOverrideProven) {
            $logS = [ordered]@{
                agent = $agent; task_id = $taskTrim
                requested_model = [string]$sel.CatalogModel; effective_model = $effective
                tier = [string]$sel.Tier; reason = [string]$sel.SelectionReason
                fallback_tier = [string]$sel.FallbackTier; cost_authorized = [bool]$sel.ProviderCostAuthorized
                proof_status = 'SELECTED_PENDING_DISPATCH'
            }
            Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'SELECTED'; reason = 'selected'; effective_model = $effective })
            return [pscustomobject]@{
                ok = $true; reason = 'selected'; status = 'SELECTED'
                selection = $sel; receipt = $receipt
                subagent_model_param = $effective; execution_log = $logS; verification = $null
                grants_authority = $false; done_approved = $false
            }
        }

        $ver0 = $null
        try { $ver0 = Test-ExecutedModelVerification -RequestedSelection $sel -ExecutedModelEvent $null -NativeModelOverrideProven $false -AuthorizedFallback $AuthorizedFallback } catch { $ver0 = $null }
        $log0 = [ordered]@{
            agent = $agent; task_id = $taskTrim
            requested_model = [string]$sel.CatalogModel; effective_model = $effective
            tier = [string]$sel.Tier; reason = [string]$sel.SelectionReason
            fallback_tier = [string]$sel.FallbackTier; cost_authorized = [bool]$sel.ProviderCostAuthorized
            proof_status = if ($null -ne $ver0) { [string]$ver0.ProofStatus } else { 'PROOF_ABSENT' }
        }
        Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'PROOF_ABSENT'; reason = 'proof-absent-fallback'; effective_model = $effective })
        return [pscustomobject]@{
            ok = $false; reason = 'proof-absent-fallback'; status = 'PROOF_ABSENT'
            selection = $sel; receipt = $receipt
            subagent_model_param = $effective; execution_log = $log0; verification = $ver0
            grants_authority = $false; done_approved = $false
        }
    } catch {
        return [pscustomobject]@{ ok = $false; reason = 'execution-internal-error'; status = 'PROOF_ABSENT'; grants_authority = $false }
    }
}
