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
    Dispatch real e opcional via -DispatchExecutor (scriptblock chamado UMA VEZ como
      & $DispatchExecutor -Model <effective> -Agent <agent> -TaskId <id>
    e deve retornar objeto com .Model observado). -DispatchExecutor e um
    seam SOMENTE-TESTE: nenhuma chamada real ocorre fora dos testes.
    Nenhum retry/fallback automatico existe nesta seam. Sem executor e sem evento
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

function Get-MEErrorCode {
    param($Raw, [string]$Fallback = 'DISPATCH_FAILED')
    try {
        $s = ([string]$Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $Fallback }
        if ($s.Length -gt 64) { $s = $s.Substring(0, 64) }
        if ($s -cmatch '^[A-Z][A-Z0-9_]{1,63}$') { return $s }
        if ($s -cmatch '^[A-Za-z][A-Za-z0-9_.-]{1,63}$') { return $s.ToUpperInvariant() }
        return $Fallback
    } catch { return $Fallback }
}

function Get-MEUsageCost {
    param($Event)
    $out = [ordered]@{ usage_present = $false; usage_input = 'UNKNOWN'; usage_output = 'UNKNOWN'; usage_reasoning = 'UNKNOWN'; cost = 'UNKNOWN' }
    try {
        if ($null -eq $Event) { return $out }
        $tok = Get-MEValue $Event 'tokens' $null
        if ($null -eq $tok) { $tok = Get-MEValue $Event 'usage' $null }
        if ($null -ne $tok) {
            $n = 0
            $ti = Get-MEValue $tok 'input' $null
            if (($null -ne $ti) -and ([int]::TryParse(([string]$ti).Trim(), [ref]$n)) -and ($n -ge 0)) { $out.usage_input = $n; $out.usage_present = $true }
            $n = 0
            $to = Get-MEValue $tok 'output' $null
            if (($null -ne $to) -and ([int]::TryParse(([string]$to).Trim(), [ref]$n)) -and ($n -ge 0)) { $out.usage_output = $n; $out.usage_present = $true }
            $n = 0
            $tr = Get-MEValue $tok 'reasoning' $null
            if (($null -ne $tr) -and ([int]::TryParse(([string]$tr).Trim(), [ref]$n)) -and ($n -ge 0)) { $out.usage_reasoning = $n; $out.usage_present = $true }
        }
        $cRaw = Get-MEValue $Event 'cost' $null
        if ($null -eq $cRaw) { $cRaw = Get-MEValue $Event 'Cost' $null }
        if ($null -ne $cRaw) {
            $cs = ([string]$cRaw).Trim()
            if ((-not [string]::IsNullOrWhiteSpace($cs)) -and ($cs -cne 'UNKNOWN')) {
                $dd = 0.0
                if ([double]::TryParse($cs, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dd) -and ($dd -ge 0.0)) {
                    $out.cost = $dd
                }
            }
        }
    } catch { }
    return $out
}

function New-MEExecutionLog {
    param($Selection, [string]$Agent = '', [string]$TaskId = '', [string]$EffectiveModel = '', [string]$ProofStatus = '', $Event = $null, $FallbackDecision = $null, $AttemptedModels = @())
    $log = [ordered]@{}
    try {
        $reqModel = [string](Get-MEValue $Selection 'CatalogModel' '')
        $reqProv = [string](Get-MEValue $Selection 'selected_provider' '')
        if ([string]::IsNullOrWhiteSpace($reqProv)) { $reqProv = [string](Get-MEValue $Selection 'Provider' '') }
        if ([string]::IsNullOrWhiteSpace($reqProv)) { $reqProv = [string](Get-MEValue $Selection 'selected_provider' 'unknown') }
        $tier = [string](Get-MEValue $Selection 'Tier' '')
        $fbTier = [string](Get-MEValue $Selection 'FallbackTier' '')
        if ([string]::IsNullOrWhiteSpace($fbTier)) { $fbTier = $tier }
        $polHash = [string](Get-MEValue $Selection 'policy_hash' '')
        $polVer = [string](Get-MEValue $Selection 'policy_version' '')
        $selReason = [string](Get-MEValue $Selection 'SelectionReason' '')
        if ([string]::IsNullOrWhiteSpace($selReason)) { $selReason = [string](Get-MEValue $Selection 'selection_reason' '') }
        $log.agent = $Agent
        $log.task_id = $TaskId
        $log.requested_model = $reqModel
        $log.requested_provider = $reqProv
        $log.effective_model = $EffectiveModel
        try { $log.executed_provider = (Get-ModelProviderFromId $EffectiveModel) } catch { $log.executed_provider = 'unknown' }
        if ([string]::IsNullOrWhiteSpace([string]$log.executed_provider)) { $log.executed_provider = 'unknown' }
        $log.tier = $tier
        $log.effective_tier = $tier
        $log.fallback_tier = $fbTier
        $log.reason = $selReason
        $log.fallback_reason = ''
        try {
            if ($null -ne $FallbackDecision) {
                $fr = [string](Get-MEValue $FallbackDecision 'Reason' '')
                if ([string]::IsNullOrWhiteSpace($fr)) { $fr = [string](Get-MEValue $FallbackDecision 'TriggerReason' '') }
                if ($fr.Length -gt 128) { $fr = $fr.Substring(0, 128) }
                $log.fallback_reason = $fr
            }
        } catch { $log.fallback_reason = '' }
        $log.attempted_models = @($AttemptedModels)
        $log.cost_authorized = [bool](Get-MEValue $Selection 'ProviderCostAuthorized' $false)
        $log.proof_status = $ProofStatus
        $log.policy_hash = $polHash
        $log.policy_version = $polVer
        $uc = Get-MEUsageCost -Event $Event
        if ([bool]$uc.usage_present) {
            $log.usage_input = $uc.usage_input
            $log.usage_output = $uc.usage_output
            $log.usage_reasoning = $uc.usage_reasoning
        }
        $log.cost = $uc.cost
    } catch { }
    return $log
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
        [bool]$T3FailureVerified = $false,
        [string]$T3FailureReceipt = '',
        [bool]$ProviderCostAuthorized = $false,
        [bool]$IsContextFailure = $false,
        [string]$RequestedModelOverride = '',
        [bool]$NativeModelOverrideProven = $false,
        $ExecutedModelEvent = $null,
        $AuthorizedFallback = $null,
        [scriptblock]$DispatchExecutor = $null,
        [string]$EvidenceDir = '',
        [string]$TasksDir = '',
        [string]$RepoRoot = '',
        [string]$PolicyPath = ''
    )
    # DEPRECATED_UNTRUSTED: T3FailureVerified/T3FailureReceipt are IGNORED.
    # Escalation uses kernel-owned proof for TaskId/TasksDir/RepoRoot only.
    # Test-only DispatchExecutor seam: EXACTLY ONE call, no retry, no automatic
    # fallback. NoExecutionStarted/FailureClass received from this seam are
    # caller-supplied signals, NOT kernel proof that execution did not start;
    # a transport-failure signal without an independent observed Model yields
    # PROOF_ABSENT (hold), never a retry and never EXECUTED_VERIFIED.
    # Real pre-dispatch native fallback is NOT implemented (HOLD): no typed
    # safe pre-execution fallback exists yet. Native production path is Planner ->
    # task-kernel model-select -> native subagent.model -> result refs ->
    # task-kernel verify-run -> model-attempt -> model-proof.
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
            $sel = Resolve-OrchestrationModelSelection -AgentName $agent -TaskId $taskTrim -TasksDir $TasksDir -RepoRoot $RepoRoot -PolicyPath $PolicyPath -Risk $Risk -Complexity $Complexity -FailureCount $fc -ProviderCostAuthorized $ProviderCostAuthorized -IgnoreUserConfig $true -NativeModelOverrideProven $NativeModelOverrideProven
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
            $routeFallback = $AuthorizedFallback
            $attemptedModels = @()
            # SINGLE-CALL seam: exactly one dispatch attempt. No retry and no
            # automatic fallback resolution here. NoExecutionStarted is an
            # untrusted caller signal, never proof of non-execution.
            # Telemetry (issue #208): the single model passed to the seam is
            # the one attempted model, recorded before invocation.
            if (-not [string]::IsNullOrWhiteSpace($effective)) { $attemptedModels = @($effective) }
            try {
                $dispatchEvent = & $DispatchExecutor -Model $effective -Agent $agent -TaskId $taskTrim
            } catch {
                $dispatchErr = Get-MEErrorCode -Raw $_.Exception.Message -Fallback 'DISPATCH_FAILED'
                $dispatchEvent = $null
            }
            if ($null -eq $dispatchEvent) {
                $logF = New-MEExecutionLog -Selection $sel -Agent $agent -TaskId $taskTrim -EffectiveModel $effective -ProofStatus 'PROOF_ABSENT' -Event $null -FallbackDecision $routeFallback -AttemptedModels $attemptedModels
                $evErrF = Get-MEErrorCode -Raw $dispatchErr -Fallback 'DISPATCH_FAILED'
                Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'PROOF_ABSENT'; reason = 'dispatch-failed'; effective_model = $effective; error = $evErrF; policy_hash = [string]$sel.policy_hash; policy_version = [string]$sel.policy_version; requested_provider = [string]$sel.selected_provider; effective_tier = [string]$sel.Tier; fallback_tier = [string]$sel.FallbackTier; attempted_models = @($attemptedModels); cost = 'UNKNOWN' })
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
                $failureSignal = [string](Get-MEValue $dispatchEvent 'FailureClass' '')
                if (-not [string]::IsNullOrWhiteSpace($failureSignal)) {
                    $evCodeT = Get-MEErrorCode -Raw $failureSignal -Fallback 'DISPATCH_FAILED'
                    $logT = New-MEExecutionLog -Selection $sel -Agent $agent -TaskId $taskTrim -EffectiveModel $effective -ProofStatus 'PROOF_ABSENT' -Event $null -FallbackDecision $routeFallback -AttemptedModels $attemptedModels
                    Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'PROOF_ABSENT'; reason = 'transport-failure-no-proof'; effective_model = $effective; error = $evCodeT; policy_hash = [string]$sel.policy_hash; policy_version = [string]$sel.policy_version; requested_provider = [string]$sel.selected_provider; effective_tier = [string]$sel.Tier; fallback_tier = [string]$sel.FallbackTier; attempted_models = @($attemptedModels); cost = 'UNKNOWN' })
                    return [pscustomobject]@{
                        ok = $false; reason = 'transport-failure-no-proof'; status = 'PROOF_ABSENT'
                        selection = $sel; receipt = $receipt
                        subagent_model_param = $effective; execution_log = $logT; verification = $null
                        dispatch_event = $dispatchEvent
                        grants_authority = $false; done_approved = $false
                    }
                }
                $logD = New-MEExecutionLog -Selection $sel -Agent $agent -TaskId $taskTrim -EffectiveModel $effective -ProofStatus 'DISPATCHED_UNVERIFIED' -Event $dispatchEvent -FallbackDecision $routeFallback -AttemptedModels $attemptedModels
                Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'DISPATCHED'; reason = 'dispatched-unverified'; effective_model = $effective; policy_hash = [string]$sel.policy_hash; policy_version = [string]$sel.policy_version; requested_provider = [string]$sel.selected_provider; effective_tier = [string]$sel.Tier; fallback_tier = [string]$sel.FallbackTier; attempted_models = @($attemptedModels); cost = 'UNKNOWN' })
                return [pscustomobject]@{
                    ok = $true; reason = 'dispatched-unverified'; status = 'DISPATCHED'
                    selection = $sel; receipt = $receipt
                    subagent_model_param = $effective; execution_log = $logD; verification = $null
                    dispatch_event = $dispatchEvent
                    grants_authority = $false; done_approved = $false
                }
            }
            $ver = $null
            try { $ver = Test-ExecutedModelVerification -RequestedSelection $sel -ExecutedModelEvent $dispatchEvent -NativeModelOverrideProven $true -AuthorizedFallback $routeFallback } catch { $ver = $null }
            $proof = if ($null -ne $ver) { [string]$ver.ProofStatus } else { 'PROOF_ABSENT' }
            $logV = New-MEExecutionLog -Selection $sel -Agent $agent -TaskId $taskTrim -EffectiveModel $effective -ProofStatus $proof -Event $dispatchEvent -FallbackDecision $routeFallback -AttemptedModels $attemptedModels
            if (($proof -ceq 'EXACT_MATCH') -or ($proof -ceq 'AUTHORIZED_FALLBACK')) {
                $ucV = Get-MEUsageCost -Event $dispatchEvent
                $evV = [ordered]@{ task_id = $taskTrim; agent = $agent; status = 'EXECUTED_VERIFIED'; reason = 'executed-verified'; effective_model = $effective; observed_model = $observed; proof_status = $proof; policy_hash = [string]$sel.policy_hash; policy_version = [string]$sel.policy_version; requested_provider = [string]$sel.selected_provider; effective_tier = [string]$sel.Tier; fallback_tier = [string]$sel.FallbackTier; attempted_models = @($attemptedModels); cost = $ucV.cost }
                if ([bool]$ucV.usage_present) { $evV.usage_input = $ucV.usage_input; $evV.usage_output = $ucV.usage_output; $evV.usage_reasoning = $ucV.usage_reasoning }
                Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record $evV
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
            $ucM = Get-MEUsageCost -Event $dispatchEvent
            $evM = [ordered]@{ task_id = $taskTrim; agent = $agent; status = 'PROOF_ABSENT'; reason = $rsn; effective_model = $effective; observed_model = $observed; proof_status = $proof; policy_hash = [string]$sel.policy_hash; policy_version = [string]$sel.policy_version; requested_provider = [string]$sel.selected_provider; effective_tier = [string]$sel.Tier; fallback_tier = [string]$sel.FallbackTier; attempted_models = @($attemptedModels); cost = $ucM.cost }
            if ([bool]$ucM.usage_present) { $evM.usage_input = $ucM.usage_input; $evM.usage_output = $ucM.usage_output; $evM.usage_reasoning = $ucM.usage_reasoning }
            Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record $evM
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
            $log2 = New-MEExecutionLog -Selection $sel -Agent $agent -TaskId $taskTrim -EffectiveModel $effective -ProofStatus $proof2 -Event $ExecutedModelEvent -FallbackDecision $AuthorizedFallback -AttemptedModels @()
            if ((($proof2 -ceq 'EXACT_MATCH') -or ($proof2 -ceq 'AUTHORIZED_FALLBACK')) -and $NativeModelOverrideProven) {
                $uc2 = Get-MEUsageCost -Event $ExecutedModelEvent
                $ev2 = [ordered]@{ task_id = $taskTrim; agent = $agent; status = 'EXECUTED_VERIFIED'; reason = 'executed-verified'; effective_model = $effective; observed_model = $obsDirect; proof_status = $proof2; policy_hash = [string]$sel.policy_hash; policy_version = [string]$sel.policy_version; requested_provider = [string]$sel.selected_provider; effective_tier = [string]$sel.Tier; fallback_tier = [string]$sel.FallbackTier; cost = $uc2.cost }
                if ([bool]$uc2.usage_present) { $ev2.usage_input = $uc2.usage_input; $ev2.usage_output = $uc2.usage_output; $ev2.usage_reasoning = $uc2.usage_reasoning }
                Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record $ev2
                return [pscustomobject]@{
                    ok = $true; reason = 'executed-verified'; status = 'EXECUTED_VERIFIED'
                    selection = $sel; receipt = $receipt
                    subagent_model_param = $effective; execution_log = $log2; verification = $ver2
                    grants_authority = $false; done_approved = $false
                }
            }
            $rsn2 = 'proof-absent-fallback'
            if ($proof2 -ceq 'UNAUTHORIZED_MISMATCH') { $rsn2 = 'unauthorized-mismatch' }
            $uc2b = Get-MEUsageCost -Event $ExecutedModelEvent
            $ev2b = [ordered]@{ task_id = $taskTrim; agent = $agent; status = 'PROOF_ABSENT'; reason = $rsn2; effective_model = $effective; observed_model = $obsDirect; proof_status = $proof2; policy_hash = [string]$sel.policy_hash; policy_version = [string]$sel.policy_version; requested_provider = [string]$sel.selected_provider; effective_tier = [string]$sel.Tier; fallback_tier = [string]$sel.FallbackTier; cost = $uc2b.cost }
            if ([bool]$uc2b.usage_present) { $ev2b.usage_input = $uc2b.usage_input; $ev2b.usage_output = $uc2b.usage_output; $ev2b.usage_reasoning = $uc2b.usage_reasoning }
            Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record $ev2b
            return [pscustomobject]@{
                ok = $false; reason = $rsn2; status = 'PROOF_ABSENT'
                selection = $sel; receipt = $receipt
                subagent_model_param = $effective; execution_log = $log2; verification = $ver2
                grants_authority = $false; done_approved = $false
            }
        }

        if ($NativeModelOverrideProven) {
            $logS = New-MEExecutionLog -Selection $sel -Agent $agent -TaskId $taskTrim -EffectiveModel $effective -ProofStatus 'SELECTED_PENDING_DISPATCH' -Event $null -FallbackDecision $AuthorizedFallback -AttemptedModels @()
            Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'SELECTED'; reason = 'selected'; effective_model = $effective; policy_hash = [string]$sel.policy_hash; policy_version = [string]$sel.policy_version; requested_provider = [string]$sel.selected_provider; effective_tier = [string]$sel.Tier; fallback_tier = [string]$sel.FallbackTier; cost = 'UNKNOWN' })
            return [pscustomobject]@{
                ok = $true; reason = 'selected'; status = 'SELECTED'
                selection = $sel; receipt = $receipt
                subagent_model_param = $effective; execution_log = $logS; verification = $null
                grants_authority = $false; done_approved = $false
            }
        }

        $ver0 = $null
        try { $ver0 = Test-ExecutedModelVerification -RequestedSelection $sel -ExecutedModelEvent $null -NativeModelOverrideProven $false -AuthorizedFallback $AuthorizedFallback } catch { $ver0 = $null }
        $proof0 = if ($null -ne $ver0) { [string]$ver0.ProofStatus } else { 'PROOF_ABSENT' }
        $log0 = New-MEExecutionLog -Selection $sel -Agent $agent -TaskId $taskTrim -EffectiveModel $effective -ProofStatus $proof0 -Event $null -FallbackDecision $AuthorizedFallback -AttemptedModels @()
        Write-MEModelEvidence -EvidenceDir $EvidenceDir -Record ([ordered]@{ task_id = $taskTrim; agent = $agent; status = 'PROOF_ABSENT'; reason = 'proof-absent-fallback'; effective_model = $effective; policy_hash = [string]$sel.policy_hash; policy_version = [string]$sel.policy_version; requested_provider = [string]$sel.selected_provider; effective_tier = [string]$sel.Tier; fallback_tier = [string]$sel.FallbackTier; cost = 'UNKNOWN' })
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
