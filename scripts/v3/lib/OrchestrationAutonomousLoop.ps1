<#!
.SYNOPSIS
    Autonomous loop honesto: UM passo por chamada + driver limitado com checkpoints.
.DESCRIPTION
    Dot-sourceable library (no execution on load). PS 5.1 compatible,
    ASCII-only, no network, no process spawn, no secrets. Never throws on
    operational paths: every failure is an envelope with ok=$false and a
    machine-readable reason.

    Regra central aplicada: TASK_DONE / WAVE_DONE / PHASE_DONE / PR_CREATED
    != OBJECTIVE_DONE. Somente `Set-OrchestrationGoalState` -> COMPLETED,
    com criterios verificados (progress.satisfied >= total, total > 0),
    termina o objetivo. Resultado de worker (candidate_pass) nunca completa
    o goal por si so; conclusao de task nao move progress.

    `Invoke-OrchestrationObjectiveStep` executa UM passo da maquina
    (reconcile -> next-move -> dispatch OU intent para o Planner -> ou
    finalizacao) e sempre persiste checkpoint via GoalCheckpoint existente.
    Sem busy polling, sem loop interno infinito. Finalizacao: goal ja
    COMPLETED e reconhecido sem mutacao (idempotente); ACTIVE com
    criterios verificados so conclui via Set-OrchestrationGoalStatePersisted
    (CAS com fencing, nunca so em memoria) - F4.

    `Invoke-OrchestrationAutonomousObjective` e um driver LIMITADO que repete
    steps ate COMPLETE/BLOCKED/EXHAUSTED ou esgotar MaxSteps/Budget. Cada
    step tem checkpoint. Watchdog e apenas referenciado (leitura/registro,
    sem kill) via Get-OrchestrationAdapterWatchdogReference-style. Resume de
    checkpoint existente nao duplica efeitos (recibos da Tarefa 1 +
    Test-OrchestrationCheckpointResume).

    Holds preservados: este modulo nao despacha sozinho; com Executor ele
    despacha via recibos idempotentes; sem Executor retorna `dispatch_intent`
    para o Planner executar via subagent (V2) / task (V1).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $ALLibDir = $PSScriptRoot
    foreach ($ALLib in @('OrchestrationGoalKernel.ps1', 'OrchestrationGoalCheckpoint.ps1', 'OrchestrationObjectiveController.ps1', 'OrchestrationNativeDispatch.ps1', 'OrchestrationRuntimeAdapterContract.ps1', 'OrchestrationValidationPolicy.ps1')) {
        $ALPath = Join-Path $ALLibDir $ALLib
        if (Test-Path -LiteralPath $ALPath -PathType Leaf) { . $ALPath }
    }
}
catch { }

function Get-ALValue {
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

function Get-ALWatchdogReference {
    try {
        $cmd = Get-Command Get-OrchestrationAdapterWatchdogReference -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { return (Get-OrchestrationAdapterWatchdogReference) }
        return [pscustomobject]@{ signals = @('NO_PROGRESS', 'HARD_TIMEOUT'); mode = 'referenced-not-driven'; drives_watchdog = $false; grants_authority = $false; done_approved = $false }
    }
    catch {
        return [pscustomobject]@{ signals = @('NO_PROGRESS', 'HARD_TIMEOUT'); mode = 'referenced-not-driven'; drives_watchdog = $false; grants_authority = $false; done_approved = $false }
    }
}

function Test-ObjectiveCompletionAllowed {
    <#
    .SYNOPSIS
        Regra central: so criterios verificados autorizam COMPLETED.
    #>
    [CmdletBinding()]
    param($Goal = $null)
    try {
        if ($null -eq $Goal) {
            return [pscustomobject]@{ allowed = $false; reason = 'invalid-goal' }
        }
        $prog = Get-ALValue $Goal 'progress' $null
        $sat = [long](Get-ALValue $prog 'satisfied' -1)
        $tot = [long](Get-ALValue $prog 'total' -1)
        if (($tot -le 0) -or ($sat -lt 0) -or ($sat -lt $tot)) {
            return [pscustomobject]@{ allowed = $false; reason = 'criteria-unverified' }
        }
        $state = (([string](Get-ALValue $Goal 'state' '')).Trim().ToUpperInvariant())
        $tCmd = Get-Command Test-OrchestrationGoalTransition -ErrorAction SilentlyContinue
        if ($null -ne $tCmd) {
            $legal = $false
            try { $legal = [bool](Test-OrchestrationGoalTransition -From $state -To 'COMPLETED') } catch { $legal = $false }
            if (-not $legal) {
                return [pscustomobject]@{ allowed = $false; reason = 'illegal-transition' }
            }
        }
        elseif (@('COMPLETED', 'EXHAUSTED', 'CANCELLED') -ccontains $state) {
            return [pscustomobject]@{ allowed = $false; reason = 'goal-terminal' }
        }
        return [pscustomobject]@{ allowed = $true; reason = '' }
    }
    catch {
        return [pscustomobject]@{ allowed = $false; reason = 'invalid-goal' }
    }
}

function Save-ALStepCheckpoint {
    param($Goal = $null, [string]$CheckpointDir = '')
    try {
        $nCmd = Get-Command New-OrchestrationGoalCheckpoint -ErrorAction SilentlyContinue
        $sCmd = Get-Command Save-OrchestrationGoalCheckpoint -ErrorAction SilentlyContinue
        if (($null -eq $nCmd) -or ($null -eq $sCmd)) {
            return [pscustomobject]@{ ok = $false; reason = 'checkpoint-unavailable'; checkpoint_id = '' }
        }
        $dir = ([string]$CheckpointDir).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) {
            $dCmd = Get-Command Get-OrchestrationGoalCheckpointStoreDir -ErrorAction SilentlyContinue
            if ($null -ne $dCmd) { $dir = Get-OrchestrationGoalCheckpointStoreDir }
        }
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'checkpoint-dir-unresolvable'; checkpoint_id = '' }
        }
        $ckpt = $null
        try { $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $Goal } catch { $ckpt = $null }
        if ($null -eq $ckpt) {
            return [pscustomobject]@{ ok = $false; reason = 'checkpoint-invalid'; checkpoint_id = '' }
        }
        $slot = $null
        try { $slot = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $dir } catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-ALValue $slot 'ok' $false))) {
            $why = 'checkpoint-write-failed'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-ALValue $slot 'reason' ''))) { $why = ([string](Get-ALValue $slot 'reason' '')) } } catch { }
            return [pscustomobject]@{ ok = $false; reason = $why; checkpoint_id = '' }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; checkpoint_id = ([string](Get-ALValue $slot 'checkpoint_id' '')) }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'checkpoint-failed'; checkpoint_id = '' }
    }
}

function New-ALStepEnvelope {
    param([bool]$Ok = $false, [string]$Action = 'invalid', [string]$Reason = '', $Goal = $null, $NextMove = $null, $Intent = $null, $Dispatch = $null, [string]$CheckpointId = '', [bool]$CheckpointOk = $false, $Watchdog = $null)
    return [pscustomobject][ordered]@{
        ok            = [bool]$Ok
        action        = ([string]$Action)
        reason        = ([string]$Reason)
        goal          = $Goal
        next_move     = $NextMove
        dispatch_intent = $Intent
        dispatch      = $Dispatch
        checkpoint_id = ([string]$CheckpointId)
        checkpoint_ok = [bool]$CheckpointOk
        watchdog      = $Watchdog
    }
}

function Invoke-ALObjectiveCompletion {
    <#
    .SYNOPSIS
        Conclusao do objetivo via CAS (F4+R4), sem checkpoint e sem envelope.
    .DESCRIPTION
        Fatorado do ramo COMPLETE de Invoke-OrchestrationObjectiveStep para
        reuso pela continuacao pos-settlement (S3a): rele leitura canonica
        viva, reconhece COMPLETED idempotente sem mutacao, exige gate
        global e finaliza via Set-OrchestrationGoalStatePersisted (CAS com
        fencing, nunca so em memoria). Devolve @{ok, action, reason, goal}
        com action em {completed, blocked} e os mesmos motivos do step.
        Nao persiste checkpoint; o chamador decide. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Goal = $null, [string]$GoalStoreDir = '', $Authorization = $null)
    try {
        $liveGoal = $Goal
        $gidLive = ([string](Get-ALValue $Goal 'goal_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($gidLive)) {
            return [pscustomobject][ordered]@{ ok = $false; action = 'blocked'; reason = 'goal-id-missing'; goal = $Goal }
        }
        $liveReadOk = $false
        try {
            $gCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
            if ($null -ne $gCmd) {
                $gs = Get-OrchestrationGoal -GoalId $gidLive -StoreDir $GoalStoreDir
                if (($null -ne $gs) -and [bool](Get-ALValue $gs 'ok' $false)) {
                    $liveGoal = Get-ALValue $gs 'goal' $Goal
                    $liveReadOk = $true
                }
            }
        }
        catch { $liveReadOk = $false }
        if (-not $liveReadOk) {
            return [pscustomobject][ordered]@{ ok = $false; action = 'blocked'; reason = 'goal-reread-failed'; goal = $Goal }
        }
        $liveState = (([string](Get-ALValue $liveGoal 'state' '')).Trim().ToUpperInvariant())
        if ($liveState -ceq 'COMPLETED') {
            return [pscustomobject][ordered]@{ ok = $true; action = 'completed'; reason = 'already-completed-idempotent'; goal = $liveGoal }
        }
        $gate = Test-ObjectiveCompletionAllowed -Goal $liveGoal
        if (-not [bool](Get-ALValue $gate 'allowed' $false)) {
            return [pscustomobject][ordered]@{ ok = $true; action = 'blocked'; reason = ([string](Get-ALValue $gate 'reason' 'criteria-unverified')); goal = $liveGoal }
        }
        $ownId = ([string](Get-ALValue $Authorization 'owner' '')).Trim()
        $ownGen = [long](Get-ALValue $Authorization 'generation' 0)
        if ([string]::IsNullOrWhiteSpace($gidLive) -or [string]::IsNullOrWhiteSpace($ownId) -or ($ownGen -lt 1)) {
            return [pscustomobject][ordered]@{ ok = $false; action = 'blocked'; reason = 'completion-auth-missing'; goal = $liveGoal }
        }
        $persistCmd = Get-Command Set-OrchestrationGoalStatePersisted -ErrorAction SilentlyContinue
        if ($null -eq $persistCmd) {
            return [pscustomobject][ordered]@{ ok = $false; action = 'blocked'; reason = 'completion-persist-unavailable'; goal = $liveGoal }
        }
        $liveRev = [long](Get-ALValue $liveGoal 'revision' 0)
        $finSlot = $null
        try { $finSlot = Set-OrchestrationGoalStatePersisted -GoalId $gidLive -ToState 'COMPLETED' -ExpectedRevision $liveRev -StoreDir $GoalStoreDir -OwnerId $ownId -OwnershipGeneration $ownGen } catch { $finSlot = $null }
        if (($null -eq $finSlot) -or (-not [bool](Get-ALValue $finSlot 'ok' $false))) {
            $why = 'finalize-failed'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-ALValue $finSlot 'reason' ''))) { $why = ('finalize-failed:' + [string](Get-ALValue $finSlot 'reason' '')) } } catch { }
            return [pscustomobject][ordered]@{ ok = $false; action = 'blocked'; reason = $why; goal = $liveGoal }
        }
        $final = Get-ALValue $finSlot 'goal' $liveGoal
        return [pscustomobject][ordered]@{ ok = $true; action = 'completed'; reason = 'objective-completed-verified'; goal = $final }
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; action = 'blocked'; reason = 'completion-internal-error'; goal = $Goal }
    }
}

function Invoke-OrchestrationObjectiveStep {
    <#
    .SYNOPSIS
        Executa UM passo do objetivo. Sem loop interno, sem polling.
    .DESCRIPTION
        reconcile (le Goal) -> next-move (Get-OrchestrationGoalNextMove) ->
        CONTINUE/RETRY: produz DispatchIntent (New-OrchestrationNativeDispatchIntent
          via -DispatchSpec) e, com -Executor, despacha via recibos; sem
          Executor retorna dispatch_intent para o Planner (subagent/task).
        COMPLETE com OBJECTIVE_COMPLETED + criterios verificados: finaliza
          via Set-OrchestrationGoalState -> COMPLETED. Qualquer outro
          COMPLETE (policy, blocker, autoridade) NAO completa o goal:
          action=blocked. TASK_DONE de worker nunca completa o objetivo.
        Sempre persiste checkpoint (best-effort, reportado em checkpoint_ok).
    #>
    [CmdletBinding()]
    param(
        $Goal = $null,
        [string]$CheckpointDir = '',
        $Executor = $null,
        $Authorization = $null,
        $DispatchSpec = $null,
        [string]$GoalStoreDir = '',
        [string]$EvidenceStoreDir = '',
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$ControllerPath = '',
        [string]$SettledKey = '',
        $NextIntent = $null,
        [string]$SessionId = ''
    )
    try {
        $watchdog = Get-ALWatchdogReference
        if ($null -eq $Goal) {
            return (New-ALStepEnvelope -Ok $false -Action 'invalid' -Reason 'goal-missing' -Watchdog $watchdog)
        }
        # S3a: com SettledKey explicita, encaminha UMA vez para a
        # continuacao pos-settlement e retorna o envelope dela. Sem
        # SettledKey, o comportamento legado abaixo segue inalterado.
        $settledForward = ([string]$SettledKey).Trim()
        if (-not [string]::IsNullOrWhiteSpace($settledForward)) {
            $gidForward = ([string](Get-ALValue $Goal 'goal_id' '')).Trim()
            return (Invoke-OrchestrationSettledContinuation -GoalId $gidForward -SettledKey $settledForward -Authorization $Authorization -SessionId ([string]$SessionId).Trim() -CheckpointDir $CheckpointDir -GoalStoreDir $GoalStoreDir -EvidenceStoreDir $EvidenceStoreDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot -TasksDir $TasksDir -FlagsPath $FlagsPath -ControllerPath $ControllerPath -NextIntent $NextIntent)
        }
        $nextCmd = Get-Command Get-OrchestrationGoalNextMove -ErrorAction SilentlyContinue
        if ($null -eq $nextCmd) {
            $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
            return (New-ALStepEnvelope -Ok $false -Action 'invalid' -Reason 'controller-unavailable' -Goal $Goal -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
        }
        $moveSlot = $null
        try {
            if ([string]::IsNullOrWhiteSpace(([string]$ControllerPath).Trim())) { $moveSlot = Get-OrchestrationGoalNextMove -Goal $Goal }
            else { $moveSlot = Get-OrchestrationGoalNextMove -Goal $Goal -ControllerPath ([string]$ControllerPath).Trim() }
        }
        catch { $moveSlot = $null }
        if (($null -eq $moveSlot) -or (-not [bool](Get-ALValue $moveSlot 'ok' $false))) {
            $why = 'next-move-failed'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-ALValue $moveSlot 'reason' ''))) { $why = ([string](Get-ALValue $moveSlot 'reason' '')) } } catch { }
            $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
            return (New-ALStepEnvelope -Ok $false -Action 'invalid' -Reason $why -Goal $Goal -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
        }
        $move = Get-ALValue $moveSlot 'next_move' $null
        $moveName = (([string](Get-ALValue $move 'move' '')).Trim().ToUpperInvariant())
        if ($moveName -ceq 'COMPLETE') {
            $stop = (([string](Get-ALValue $move 'stop_reason' '')).Trim().ToUpperInvariant())
            if ($stop -ceq 'OBJECTIVE_COMPLETED') {
                # F4+R4 via helper fatorado (leitura viva -> gate global ->
                # CAS com fencing; ver Invoke-ALObjectiveCompletion).
                # Comportamento identico ao ramo anterior, sem duplicar.
                $fin = Invoke-ALObjectiveCompletion -Goal $Goal -GoalStoreDir $GoalStoreDir -Authorization $Authorization
                $finGoal = Get-ALValue $fin 'goal' $Goal
                $ckpt = Save-ALStepCheckpoint -Goal $finGoal -CheckpointDir $CheckpointDir
                return (New-ALStepEnvelope -Ok ([bool](Get-ALValue $fin 'ok' $false)) -Action ([string](Get-ALValue $fin 'action' 'blocked')) -Reason ([string](Get-ALValue $fin 'reason' 'finalize-failed')) -Goal $finGoal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
            }
            $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
            return (New-ALStepEnvelope -Ok $true -Action 'blocked' -Reason ('stop:' + $stop) -Goal $Goal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
        }
        if (($moveName -ceq 'CONTINUE') -or ($moveName -ceq 'RETRY')) {
            if ($null -eq $DispatchSpec) {
                $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
                return (New-ALStepEnvelope -Ok $false -Action 'needs-dispatch-spec' -Reason 'dispatch-spec-missing' -Goal $Goal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
            }
            $spec = $DispatchSpec
            if ($DispatchSpec -is [scriptblock]) {
                try { $spec = & $DispatchSpec $Goal $move } catch { $spec = $null }
                if ($null -eq $spec) {
                    $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
                    return (New-ALStepEnvelope -Ok $false -Action 'needs-dispatch-spec' -Reason 'dispatch-spec-failed' -Goal $Goal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
                }
            }
            $intentSlot = $null
            try {
                $intentSlot = New-OrchestrationNativeDispatchIntent `
                    -TaskId ([string](Get-ALValue $spec 'task_id' '')) `
                    -TaskExpectedRevision ([long](Get-ALValue $spec 'task_expected_revision' 0)) `
                    -Agent ([string](Get-ALValue $spec 'agent' '')) `
                    -PromptHash ([string](Get-ALValue $spec 'prompt_hash' '')) `
                    -Scope @((Get-ALValue $spec 'scope' @())) `
                    -AcceptanceCriteria @((Get-ALValue $spec 'acceptance_criteria' @())) `
                    -IdempotencyKey ([string](Get-ALValue $spec 'idempotency_key' '')) `
                    -Owner ([string](Get-ALValue $spec 'owner' '')) `
                    -OwnershipGeneration ([long](Get-ALValue $spec 'ownership_generation' 0)) `
                    -BaseRevision ([string](Get-ALValue $spec 'base_revision' '')) `
                    -ExternalIdempotent ([bool](Get-ALValue $spec 'external_idempotent' $false)) `
                    -ExternalIdempotencyProof ([string](Get-ALValue $spec 'external_idempotency_proof' ''))
            }
            catch { $intentSlot = $null }
            if (($null -eq $intentSlot) -or (-not [bool](Get-ALValue $intentSlot 'ok' $false))) {
                $why = 'invalid-dispatch-intent'
                try { if (-not [string]::IsNullOrWhiteSpace([string](Get-ALValue $intentSlot 'reason' ''))) { $why = ([string](Get-ALValue $intentSlot 'reason' '')) } } catch { }
                $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
                return (New-ALStepEnvelope -Ok $false -Action 'needs-dispatch-spec' -Reason $why -Goal $Goal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
            }
            $intent = Get-ALValue $intentSlot 'intent' $null
            if ($null -eq $Executor) {
                $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
                return (New-ALStepEnvelope -Ok $true -Action 'dispatch_intent' -Reason 'planner-executes-via-subagent' -Goal $Goal -NextMove $move -Intent $intent -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
            }
            $disp = $null
            try {
                $disp = Invoke-OrchestrationNativeDispatch -Intent $intent -Executor $Executor -Authorization $Authorization -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot -GoalStoreDir $GoalStoreDir -EvidenceStoreDir $EvidenceStoreDir -TasksDir $TasksDir -FlagsPath $FlagsPath
            }
            catch { $disp = $null }
            if ($null -eq $disp) {
                $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
                return (New-ALStepEnvelope -Ok $false -Action 'dispatched' -Reason 'dispatch-failed' -Goal $Goal -NextMove $move -Intent $intent -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
            }
            $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
            return (New-ALStepEnvelope -Ok ([bool](Get-ALValue $disp 'ok' $false)) -Action 'dispatched' -Reason ([string](Get-ALValue $disp 'reason' '')) -Goal $Goal -NextMove $move -Intent $intent -Dispatch $disp -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
        }
        $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
        return (New-ALStepEnvelope -Ok $true -Action 'replan' -Reason ('move:' + $moveName) -Goal $Goal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
    }
    catch {
        return (New-ALStepEnvelope -Ok $false -Action 'invalid' -Reason 'step-internal-error' -Watchdog (Get-ALWatchdogReference))
    }
}

function Invoke-OrchestrationAutonomousObjective {
    <#
    .SYNOPSIS
        Driver LIMITADO: repete steps ate COMPLETE/BLOCKED/EXHAUSTED ou budget.
    .DESCRIPTION
        -MaxSteps limita o numero de steps; -MaxDispatches limita despachos
        com efeito (F5: saldo verificado ANTES do dispatch; 0 = zero
        efeitos; R6: todo dispatch com executor_calls >= 1 e contabilizado
        em dispatches ANTES de avaliar sucesso - efeito ocorrido e
        reportado com contagem + razao; so duplicata idempotente com
        0 calls nao consome budget; dispatch malsucedido/recusado
        interrompe com erro explicito, nunca avanca silenciosamente
        para ok=true exhausted). Rele o Goal vivo a cada step quando -GoalId +
        -GoalStoreDir sao dados (multifase); senao usa -Goal em memoria.
        Resume: com -ResumeCheckpointId, valida via
        Test-OrchestrationCheckpointResume antes de avancar (recibos impedem
        duplicacao de efeitos de qualquer forma). Sem polling: cada step e
        sincrono e limitado; o driver nunca gira infinito.
    #>
    [CmdletBinding()]
    param(
        $Goal = $null,
        [string]$GoalId = '',
        [string]$GoalStoreDir = '',
        [int]$MaxSteps = 5,
        [int]$MaxDispatches = 5,
        [string]$CheckpointDir = '',
        $Executor = $null,
        $Authorization = $null,
        $DispatchSpec = $null,
        [string]$ResumeCheckpointId = '',
        [string]$EvidenceStoreDir = '',
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$ControllerPath = ''
    )
    try {
        $watchdog = Get-ALWatchdogReference
        $steps = [int]$MaxSteps
        if ($steps -lt 1) { $steps = 1 }
        if ($steps -gt 100) { $steps = 100 }
        $budget = [int]$MaxDispatches
        if ($budget -lt 0) { $budget = 0 }
        if ($budget -gt 100) { $budget = 100 }
        $gid = ([string]$GoalId).Trim()
        $liveGoal = $Goal
        if (-not [string]::IsNullOrWhiteSpace($gid)) {
            $gCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
            if ($null -eq $gCmd) {
                return [pscustomobject][ordered]@{ ok = $false; outcome = 'invalid'; reason = 'goal-store-unavailable'; steps_taken = 0; dispatches = 0; checkpoints = @(); watchdog = $watchdog }
            }
        }
        elseif ($null -eq $liveGoal) {
            return [pscustomobject][ordered]@{ ok = $false; outcome = 'invalid'; reason = 'goal-missing'; steps_taken = 0; dispatches = 0; checkpoints = @(); watchdog = $watchdog }
        }
        if (-not [string]::IsNullOrWhiteSpace(([string]$ResumeCheckpointId).Trim())) {
            $rCmd = Get-Command Test-OrchestrationCheckpointResume -ErrorAction SilentlyContinue
            $lCmd = Get-Command Load-OrchestrationGoalCheckpoint -ErrorAction SilentlyContinue
            if (($null -eq $rCmd) -or ($null -eq $lCmd)) {
                return [pscustomobject][ordered]@{ ok = $false; outcome = 'invalid'; reason = 'resume-unavailable'; steps_taken = 0; dispatches = 0; checkpoints = @(); watchdog = $watchdog }
            }
            $load = $null
            try { $load = Load-OrchestrationGoalCheckpoint -CheckpointId ([string]$ResumeCheckpointId).Trim() -StoreDir $CheckpointDir } catch { $load = $null }
            if (($null -eq $load) -or (-not [bool](Get-ALValue $load 'ok' $false))) {
                return [pscustomobject][ordered]@{ ok = $false; outcome = 'invalid'; reason = 'resume-checkpoint-not-found'; steps_taken = 0; dispatches = 0; checkpoints = @(); watchdog = $watchdog }
            }
            $resume = $null
            try { $resume = Test-OrchestrationCheckpointResume -Checkpoint (Get-ALValue $load 'checkpoint' $null) -GoalStoreDir $GoalStoreDir } catch { $resume = $null }
            if (($null -eq $resume) -or (-not [bool](Get-ALValue $resume 'resumable' $false))) {
                return [pscustomobject][ordered]@{ ok = $false; outcome = 'invalid'; reason = 'resume-not-resumable'; steps_taken = 0; dispatches = 0; checkpoints = @(); watchdog = $watchdog }
            }
        }
        $taken = 0
        $dispatched = 0
        $ckptIds = New-Object System.Collections.ArrayList
        $lastAction = ''
        $lastReason = ''
        # F5: saldo verificado ANTES de cada dispatch; MaxDispatches=0
        # significa zero efeitos (retorno imediato, sem steps).
        if ($budget -le 0) {
            return [pscustomobject][ordered]@{ ok = $true; outcome = 'exhausted'; reason = 'dispatch-budget-zero'; steps_taken = 0; dispatches = 0; checkpoints = @(); watchdog = $watchdog }
        }
        for ($i = 1; $i -le $steps; $i++) {
            if ($dispatched -ge $budget) {
                return [pscustomobject][ordered]@{ ok = $true; outcome = 'exhausted'; reason = 'dispatch-budget-spent'; steps_taken = $taken; dispatches = $dispatched; checkpoints = @($ckptIds.ToArray()); watchdog = $watchdog }
            }
            if (-not [string]::IsNullOrWhiteSpace($gid)) {
                $slot = $null
                try { $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir } catch { $slot = $null }
                if (($null -eq $slot) -or (-not [bool](Get-ALValue $slot 'ok' $false))) {
                    return [pscustomobject][ordered]@{ ok = $false; outcome = 'blocked'; reason = 'goal-reread-failed'; steps_taken = $taken; dispatches = $dispatched; checkpoints = @($ckptIds.ToArray()); watchdog = $watchdog }
                }
                $liveGoal = Get-ALValue $slot 'goal' $null
            }
            $spec = $DispatchSpec
            if ($DispatchSpec -is [scriptblock]) {
                $stepSpec = $null
                try { $stepSpec = & $DispatchSpec $taken $liveGoal } catch { $stepSpec = $null }
                $spec = $stepSpec
            }
            $step = Invoke-OrchestrationObjectiveStep -Goal $liveGoal -CheckpointDir $CheckpointDir -Executor $Executor -Authorization $Authorization -DispatchSpec $spec -GoalStoreDir $GoalStoreDir -EvidenceStoreDir $EvidenceStoreDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot -TasksDir $TasksDir -FlagsPath $FlagsPath -ControllerPath $ControllerPath
            $taken = $i
            $cid = ([string](Get-ALValue $step 'checkpoint_id' ''))
            if (-not [string]::IsNullOrWhiteSpace($cid)) { [void]$ckptIds.Add($cid) }
            $action = ([string](Get-ALValue $step 'action' 'invalid'))
            $lastAction = $action
            $lastReason = ([string](Get-ALValue $step 'reason' ''))
            if ($action -ceq 'dispatched') {
                # F5+R6: efeito real (executor_calls >= 1) e contabilizado
                # ANTES de avaliar sucesso: dispatch que executou e falhou
                # reporta o efeito ocorrido (contagem + razao), nunca
                # dispatches=0 silencioso. Duplicata idempotente (0 calls)
                # nao consome budget. Dispatch malsucedido/recusado
                # interrompe o driver com erro explicito: nunca avanca
                # silenciosamente para ok=true.
                $d = Get-ALValue $step 'dispatch' $null
                $calls = 0
                try { $calls = [int](Get-ALValue $d 'executor_calls' 0) } catch { $calls = 0 }
                if ($calls -ge 1) {
                    $dispatched++
                }
                if (($null -eq $d) -or (-not [bool](Get-ALValue $d 'ok' $false))) {
                    $why = 'dispatch-failed'
                    try { if (($null -ne $d) -and (-not [string]::IsNullOrWhiteSpace([string](Get-ALValue $d 'reason' '')))) { $why = ('dispatch-failed:' + [string](Get-ALValue $d 'reason' '')) } } catch { }
                    return [pscustomobject][ordered]@{ ok = $false; outcome = 'blocked'; reason = $why; steps_taken = $taken; dispatches = $dispatched; checkpoints = @($ckptIds.ToArray()); watchdog = $watchdog }
                }
            }
            if ($action -ceq 'completed') {
                return [pscustomobject][ordered]@{ ok = $true; outcome = 'completed'; reason = $lastReason; steps_taken = $taken; dispatches = $dispatched; checkpoints = @($ckptIds.ToArray()); watchdog = $watchdog }
            }
            if (($action -ceq 'blocked') -or ($action -ceq 'invalid')) {
                return [pscustomobject][ordered]@{ ok = ([bool](Get-ALValue $step 'ok' $false)); outcome = 'blocked'; reason = $lastReason; steps_taken = $taken; dispatches = $dispatched; checkpoints = @($ckptIds.ToArray()); watchdog = $watchdog }
            }
            if ($action -ceq 'dispatch_intent') {
                return [pscustomobject][ordered]@{ ok = $true; outcome = 'awaits-planner'; reason = $lastReason; steps_taken = $taken; dispatches = $dispatched; checkpoints = @($ckptIds.ToArray()); dispatch_intent = (Get-ALValue $step 'dispatch_intent' $null); watchdog = $watchdog }
            }
            if ($dispatched -ge $budget) {
                return [pscustomobject][ordered]@{ ok = $true; outcome = 'exhausted'; reason = 'dispatch-budget-spent'; steps_taken = $taken; dispatches = $dispatched; checkpoints = @($ckptIds.ToArray()); watchdog = $watchdog }
            }
        }
        return [pscustomobject][ordered]@{ ok = $true; outcome = 'exhausted'; reason = 'max-steps-spent'; steps_taken = $taken; dispatches = $dispatched; checkpoints = @($ckptIds.ToArray()); last_action = $lastAction; last_reason = $lastReason; watchdog = $watchdog }
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; outcome = 'invalid'; reason = 'loop-internal-error'; steps_taken = 0; dispatches = 0; checkpoints = @(); watchdog = (Get-ALWatchdogReference) }
    }
}

# ------------------------------------------------------------------
# S3a: continuacao pos-settlement (fixture-only).
#
# Invoke-OrchestrationSettledContinuation consome UMA liquidacao
# canonica (recibo phase=settled) e, sem executar worker, compoe:
# prova do settlement + gates de verificacao/review + decisao do
# Controller + ND-ADVANCE + checkpoint correlacionado. Termina em
# PREPARED, REPLAN_REQUIRED, BLOCKED ou COMPLETED.
#
# Regras duras:
# - ok = processamento valido, NAO objetivo concluido. So
#   action=completed (CAS confirmado no GoalKernel) afirma conclusao.
# - Recusa antes do ADVANCE = zero PREPARE/CLAIM/SETTLE/execucao/CAS.
# - Depois de PREPARE confirmado, falha de checkpoint NAO e
#   zero-efeito: devolve prepared=true com a chave vinculada.
# - executor_calls e sempre 0: nada aqui executa worker.
# - Nunca confia em verified/approved/task_done do chamador: tudo e
#   relido dos stores canonicos (recibo settled + evidencia + kernel).
# ------------------------------------------------------------------

function New-SCEnvelope {
    [CmdletBinding()]
    param(
        [bool]$Ok = $false,
        [string]$Action = 'invalid',
        [string]$Reason = '',
        [string]$CauseReason = '',
        [string]$GoalId = '',
        [string]$SettledKey = '',
        [string]$EvidenceId = '',
        [long]$CandidateRevision = -1,
        [string]$Move = '',
        [string]$StopReason = '',
        [string]$AdvanceRecordRef = '',
        [string]$NextIdempotencyKey = '',
        [string]$NextReference = '',
        [bool]$Prepared = $false,
        [string]$CheckpointId = '',
        [bool]$CheckpointOk = $false
    )
    return [pscustomobject][ordered]@{
        ok                   = [bool]$Ok
        action               = ([string]$Action)
        reason               = ([string]$Reason)
        cause_reason         = ([string]$CauseReason)
        goal_id              = ([string]$GoalId)
        settled_key          = ([string]$SettledKey)
        evidence_id          = ([string]$EvidenceId)
        candidate_revision   = [long]$CandidateRevision
        move                 = ([string]$Move)
        stop_reason          = ([string]$StopReason)
        advance_record_ref   = ([string]$AdvanceRecordRef)
        next_idempotency_key = ([string]$NextIdempotencyKey)
        next_reference       = ([string]$NextReference)
        prepared             = [bool]$Prepared
        checkpoint_id        = ([string]$CheckpointId)
        checkpoint_ok        = [bool]$CheckpointOk
        executor_calls       = 0
    }
}

function New-SCRefusal {
    [CmdletBinding()]
    param([string]$Reason = '', [string]$Cause = '', [string]$GoalId = '', [string]$SettledKey = '', [string]$Action = 'blocked')
    return (New-SCEnvelope -Ok $false -Action $Action -Reason $Reason -CauseReason $Cause -GoalId $GoalId -SettledKey $SettledKey)
}

function Test-SCEvidenceIdContained {
    <#
    .SYNOPSIS
        Contencao do evidence_id antes de compor caminho (F6).
    .DESCRIPTION
        Puro, nunca lanca. Recusa id com raiz, separador (GetFileName
        diverge do original) ou parent ('..'): impede escape do diretorio
        do evidence store via Join-Path. Nao afirma existencia.
    #>
    [CmdletBinding()]
    param([string]$EvidenceId = '')
    try {
        $id = ([string]$EvidenceId).Trim()
        if ([string]::IsNullOrWhiteSpace($id)) { return $false }
        if ([IO.Path]::IsPathRooted($id)) { return $false }
        if (([IO.Path]::GetFileName($id) -cne $id)) { return $false }
        if ($id.Contains('..')) { return $false }
        return $true
    }
    catch { return $false }
}

function Get-SCSettlementProof {
    <#
    .SYNOPSIS
        Prova do settlement a partir do recibo duravel settled + evidencia.
    .DESCRIPTION
        Read-only, nunca lanca. Exige recibo legivel em phase=settled do
        MESMO goal, integridade semantica valida, worker_result persistido
        no kernel compativel campo a campo (Test-NDCandidateResultMatch) e
        evidencia existente e correlacionada (arquivo + ids + run=chave).
        Falha de transporte/leitura => uncertain; falha de conteudo =>
        unproven; divergencia kernel => task-result-mismatch.
    #>
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$SettledKey = '', [string]$GoalStoreDir = '', [string]$EvidenceStoreDir = '', [string]$ReceiptDir = '', [string]$RepoRoot = '', [string]$TasksDir = '')
    $denyReason = ''
    $denyCause = ''
    try {
        $gid = ([string]$GoalId).Trim()
        $sk = ([string]$SettledKey).Trim().ToLowerInvariant()
        $rdCmd = Get-Command Get-OrchestrationDispatchReceiptDir -ErrorAction SilentlyContinue
        if ($null -eq $rdCmd) { $denyReason = 'continuation-settlement-uncertain'; $denyCause = 'receipt-dir-unavailable'; throw 'sc-deny' }
        $root = ''
        try { $root = Get-OrchestrationDispatchReceiptDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot } catch { $root = '' }
        if ([string]::IsNullOrWhiteSpace($root)) { $denyReason = 'continuation-settlement-uncertain'; $denyCause = 'receipt-dir-unresolvable'; throw 'sc-deny' }
        $rsCmd = Get-Command Resolve-NDGoalReceiptDir -ErrorAction SilentlyContinue
        if ($null -eq $rsCmd) { $denyReason = 'continuation-settlement-uncertain'; $denyCause = 'receipt-dir-unavailable'; throw 'sc-deny' }
        $rState = $null
        try { $rState = Resolve-NDGoalReceiptDir -RootDir $root -GoalId $gid } catch { $rState = $null }
        if (($null -eq $rState) -or (-not [bool](Get-ALValue $rState 'ok' $false))) {
            $denyCause = 'receipt-dir-unresolvable'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-ALValue $rState 'reason' ''))) { $denyCause = ([string](Get-ALValue $rState 'reason' '')) } } catch { }
            $denyReason = 'continuation-settlement-uncertain'; throw 'sc-deny'
        }
        $rDir = ([string](Get-ALValue $rState 'dir' ''))
        $rIdent = ([string](Get-ALValue $rState 'created_utc' ''))
        $rdRead = Get-Command Read-NDReceipt -ErrorAction SilentlyContinue
        if ($null -eq $rdRead) { $denyReason = 'continuation-settlement-uncertain'; $denyCause = 'receipt-read-unavailable'; throw 'sc-deny' }
        $read = $null
        try { $read = Read-NDReceipt -Dir $rDir -Key $sk -Expected $rIdent -AllowHandoffPhases } catch { $read = $null }
        if (($null -eq $read) -or (-not [bool](Get-ALValue $read 'ok' $false))) {
            $denyCause = 'receipt-unreadable'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-ALValue $read 'reason' ''))) { $denyCause = ([string](Get-ALValue $read 'reason' '')) } } catch { }
            $denyReason = 'continuation-settlement-uncertain'; throw 'sc-deny'
        }
        $rec = Get-ALValue $read 'receipt' $null
        if ($null -eq $rec) { $denyReason = 'continuation-settlement-uncertain'; $denyCause = 'receipt-empty'; throw 'sc-deny' }
        $phase = (([string](Get-ALValue $rec 'phase' '')).Trim().ToLowerInvariant())
        if ($phase -cne 'settled') { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'phase-not-settled'; throw 'sc-deny' }
        if (([string](Get-ALValue $rec 'goal_id' '')).Trim() -cne $gid) { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'goal-mismatch'; throw 'sc-deny' }
        $evId = ([string](Get-ALValue $rec 'settle_evidence_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($evId)) { $evId = ([string](Get-ALValue $rec 'evidence_id' '')).Trim() }
        if ([string]::IsNullOrWhiteSpace($evId)) { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'evidence-missing'; throw 'sc-deny' }
        # F6: contencao do evidence_id antes de compor qualquer caminho.
        if (-not (Test-SCEvidenceIdContained -EvidenceId $evId)) { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'evidence-id-invalid'; throw 'sc-deny' }
        $integCmd = Get-Command Test-NDReceiptSemanticIntegrity -ErrorAction SilentlyContinue
        if ($null -eq $integCmd) { $denyReason = 'continuation-settlement-uncertain'; $denyCause = 'integrity-check-unavailable'; throw 'sc-deny' }
        $integ = $null
        try { $integ = Test-NDReceiptSemanticIntegrity -Receipt $rec -GoalId $gid -IdempotencyKey $sk } catch { $integ = $null }
        if (($null -eq $integ) -or (-not [bool](Get-ALValue $integ 'ok' $false))) { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'receipt-integrity-invalid'; throw 'sc-deny' }
        $tid = ([string](Get-ALValue $rec 'task_id' '')).Trim()
        if ([string]::IsNullOrWhiteSpace($tid)) { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'task-id-missing'; throw 'sc-deny' }
        $settleStatus = (([string](Get-ALValue $rec 'settle_status' '')).Trim().ToLowerInvariant())
        $settleRefs = @((Get-ALValue $rec 'settle_claimed_evidence' @()))
        $wrNode = Get-ALValue $rec 'worker_result' $null
        if ([string]::IsNullOrWhiteSpace($settleStatus) -and ($null -ne $wrNode)) {
            $settleStatus = (([string](Get-ALValue $wrNode 'status' '')).Trim().ToLowerInvariant())
        }
        if ((@($settleRefs).Count -eq 0) -and ($null -ne $wrNode)) {
            $settleRefs = @((Get-ALValue $wrNode 'claimed_evidence' @()))
        }
        if ([string]::IsNullOrWhiteSpace($settleStatus)) { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'settle-status-missing'; throw 'sc-deny' }
        # F5: a revisao esperada pelo recibo settled ancora o worker_result
        # que a prova pode consumir: sem ela nao ha como saber se o
        # resultado persistido e o desta liquidacao ou de outra posterior.
        $recExpected = [long]-1
        try { $recExpected = [long](Get-ALValue $rec 'task_expected_revision' -1) } catch { $recExpected = [long]-1 }
        if ($recExpected -lt 1) { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'receipt-task-revision-missing'; throw 'sc-deny' }
        $taskCmd = Get-Command Get-OrchestrationTask -ErrorAction SilentlyContinue
        if ($null -eq $taskCmd) { $denyReason = 'continuation-settlement-uncertain'; $denyCause = 'taskkernel-unavailable'; throw 'sc-deny' }
        $task = $null
        try { $task = Get-OrchestrationTask -TaskId $tid -TasksDir $TasksDir -RepoRoot $RepoRoot } catch { $task = $null }
        if ($null -eq $task) { $denyReason = 'continuation-settlement-uncertain'; $denyCause = 'task-unreadable'; throw 'sc-deny' }
        $taskErr = ''
        try {
            if ($task -is [System.Collections.IDictionary]) { if ($task.Contains('error')) { $taskErr = ([string]$task['error']) } }
            else { $ep = $task.PSObject.Properties['error']; if ($null -ne $ep) { $taskErr = ([string]$ep.Value) } }
        }
        catch { $taskErr = '' }
        if (-not [string]::IsNullOrWhiteSpace($taskErr)) {
            if ($taskErr -ceq 'NOT_FOUND') { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'task-not-found'; throw 'sc-deny' }
            $denyReason = 'continuation-settlement-uncertain'; $denyCause = ('task-unreadable:' + $taskErr); throw 'sc-deny'
        }
        $wrk = Get-ALValue $task 'worker_result' $null
        if ($null -eq $wrk) { $denyReason = 'continuation-task-result-mismatch'; $denyCause = 'worker-result-missing'; throw 'sc-deny' }
        $wStatus = (([string](Get-ALValue $wrk 'status' '')).Trim().ToLowerInvariant())
        $wRefs = @((Get-ALValue $wrk 'claimed_evidence' @()))
        $wRev = [long]-1
        try { $wRev = [long](Get-ALValue $wrk 'revision' -1) } catch { $wRev = [long]-1 }
        $matchCmd = Get-Command Test-NDCandidateResultMatch -ErrorAction SilentlyContinue
        if ($null -eq $matchCmd) { $denyReason = 'continuation-settlement-uncertain'; $denyCause = 'match-helper-unavailable'; throw 'sc-deny' }
        $match = $false
        try { $match = [bool](Test-NDCandidateResultMatch -Status $settleStatus -Refs @($settleRefs) -OtherStatus $wStatus -OtherRefs @($wRefs)) } catch { $match = $false }
        if (-not $match) { $denyReason = 'continuation-task-result-mismatch'; $denyCause = 'worker-result-divergent'; throw 'sc-deny' }
        # F5: mesmo status/refs iguais, um worker_result de outra liquidacao
        # (revisao avancada alem da esperada por este recibo) nao autoriza:
        # a aprovacao do candidato novo nao herda a do antigo.
        if (($recExpected + 1) -ne $wRev) { $denyReason = 'continuation-task-result-mismatch'; $denyCause = 'worker-result-superseded'; throw 'sc-deny' }
        if ([string]::IsNullOrWhiteSpace($EvidenceStoreDir)) { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'evidence-store-missing'; throw 'sc-deny' }
        $evPath = Join-Path ([string]$EvidenceStoreDir).Trim() ($evId + '.json')
        if (-not (Test-Path -LiteralPath $evPath -PathType Leaf)) { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'evidence-file-missing'; throw 'sc-deny' }
        # F3: falha de leitura/parse da evidencia e estado incerto (nao
        # prova de ausencia): quem sumiu ou corrompeu o arquivo nao se
        # distingue aqui; zero efeito em ambos os casos.
        $evText = $null
        $evReadOk = $true
        try { $evText = [IO.File]::ReadAllText($evPath, [Text.Encoding]::UTF8) } catch { $evReadOk = $false; $evText = $null }
        if (-not $evReadOk) { $denyReason = 'continuation-settlement-uncertain'; $denyCause = 'evidence-unreadable'; throw 'sc-deny' }
        $evRaw = $null
        try { $evRaw = ConvertFrom-Json $evText } catch { $evRaw = $null }
        if ($null -eq $evRaw) { $denyReason = 'continuation-settlement-uncertain'; $denyCause = 'evidence-unreadable'; throw 'sc-deny' }
        if (([string](Get-ALValue $evRaw 'evidence_id' '')).Trim() -cne $evId) { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'evidence-id-mismatch'; throw 'sc-deny' }
        if (([string](Get-ALValue $evRaw 'task_id' '')).Trim() -cne $tid) { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'evidence-task-mismatch'; throw 'sc-deny' }
        if (([string](Get-ALValue $evRaw 'run_id' '')).Trim().ToLowerInvariant() -cne $sk) { $denyReason = 'continuation-settlement-unproven'; $denyCause = 'evidence-key-mismatch'; throw 'sc-deny' }
        return [pscustomobject][ordered]@{
            ok = $true; reason = ''; cause = ''; receipt = $rec; task = $task; evidence_id = $evId
            worker_status = $wStatus; worker_refs = @($wRefs); worker_revision = $wRev
            task_id = $tid; task_state = (([string](Get-ALValue $task 'state' '')).Trim().ToUpperInvariant())
            task_risk = (([string](Get-ALValue $task 'risk' '')).Trim().ToLowerInvariant())
            task_objective = ([string](Get-ALValue $task 'objective' ''))
            task_type = (([string](Get-ALValue $task 'task_type' '')).Trim())
            task_scopes = @(@((Get-ALValue $task 'read_scopes' @())) + @((Get-ALValue $task 'write_scopes' @())))
            task_project = ([string](Get-ALValue $task 'project' ''))
            verification = (Get-ALValue $task 'verification' $null)
            review = (Get-ALValue $task 'review' $null)
            security_review = (Get-ALValue $task 'security_review' $null)
        }
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($denyReason)) { $denyReason = 'continuation-settlement-uncertain'; $denyCause = 'proof-internal-error' }
        return [pscustomobject][ordered]@{
            ok = $false; reason = $denyReason; cause = $denyCause; receipt = $null; task = $null; evidence_id = ''
            worker_status = ''; worker_refs = @(); worker_revision = [long]-1
            task_id = ''; task_state = ''; task_risk = ''
            task_objective = ''; task_type = ''; task_scopes = @(); task_project = ''
            verification = $null; review = $null; security_review = $null
        }
    }
}

function Test-SCContinueGate {
    <#
    .SYNOPSIS
        Gate de verificacao/review para o move CONTINUE (records vivos).
    .DESCRIPTION
        Nivel efetivo da policy real (source/registry/validation-policy.json
        via Get-OrchestrationValidationLevel) sobre o descritor canonico da
        task (risco + tipo + projeto + objetivo/escopos) AMPLIADO com o
        contexto canonico do goal vivo (objective + criteria): um goal
        "payments/auth" com task generica tambem eleva a L3. Hard triggers
        do texto (auth/credentials/payments/...) elevam a L3. Risco/level
        desconhecido ou policy ilegivel => policy-unavailable (fail-closed,
        nunca assume L0). L0/L1/L2 exigem verificacao passada e fresca +
        review aprovado e fresco (o reviewer exigido pelo DONE); L3 exige
        ainda security-review aprovado e fresco. Nada de descritor livre do
        caller: tudo e lido dos registros vivos (task + goal).
        manual_verification_required chega como passed=$false e bloqueia.
    #>
    [CmdletBinding()]
    param($Proof = $null, $Policy = $null, $Goal = $null)
    try {
        if ($null -eq $Proof) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-verification-required'; cause = 'proof-missing'; level = '' }
        }
        $wStatus = ([string](Get-ALValue $Proof 'worker_status' ''))
        if ($wStatus -cne 'candidate_pass') {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-task-result-mismatch'; cause = ('worker-status:' + $wStatus); level = '' }
        }
        $wRev = [long](Get-ALValue $Proof 'worker_revision' -1)
        $lvlCmd = Get-Command Get-OrchestrationValidationLevel -ErrorAction SilentlyContinue
        if ($null -eq $lvlCmd) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-policy-unavailable'; cause = 'level-helper-unavailable'; level = '' }
        }
        # F1: descritor montado dos REGISTROS CANONICOS (nunca do caller):
        # task (risco + tipo + projeto + objetivo/escopos) + goal vivo
        # (objective + criteria). Goal "payments/auth" com task generica
        # tambem eleva a L3.
        $risk = ([string](Get-ALValue $Proof 'task_risk' ''))
        $goalObj = ([string](Get-ALValue $Goal 'objective' ''))
        $goalCrit = ((@(Get-ALValue $Goal 'criteria' @())) -join ' ')
        $descSummary = ($goalObj + ' ' + $goalCrit + ' ' + ([string](Get-ALValue $Proof 'task_objective' '')) + ' ' + ((@(Get-ALValue $Proof 'task_scopes' @())) -join ' '))
        $desc = @{
            risk      = $risk
            operation = ([string](Get-ALValue $Proof 'task_type' ''))
            domain    = ([string](Get-ALValue $Proof 'task_project' ''))
            summary   = $descSummary
        }
        $verdict = $null
        try { $verdict = Get-OrchestrationValidationLevel -Descriptor $desc -Policy $Policy } catch { $verdict = $null }
        $level = ''
        $vStatus = 'unknown'
        try { $level = ([string](Get-ALValue $verdict 'level' '')) } catch { }
        try { $vStatus = ([string](Get-ALValue $verdict 'status' '')) } catch { }
        if ((($vStatus -ceq 'policy-unavailable') -or ($vStatus -ceq 'unknown-risk')) -or (@('L0', 'L1', 'L2', 'L3') -cnotcontains $level)) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-policy-unavailable'; cause = ('validation-level:' + $vStatus); level = '' }
        }
        $ver = Get-ALValue $Proof 'verification' $null
        if ($null -eq $ver) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-verification-required'; cause = 'verification-missing'; level = $level }
        }
        $vPassed = $false
        try { $vPassed = [bool](Get-ALValue $ver 'passed' $false) } catch { $vPassed = $false }
        if (-not $vPassed) {
            $vs = (([string](Get-ALValue $ver 'status' '')).Trim())
            return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-verification-required'; cause = ('verification-not-passed:' + $vs); level = $level }
        }
        $vCand = [long]-2
        try { $vCand = [long](Get-ALValue $ver 'candidate_revision' -2) } catch { $vCand = [long]-2 }
        if ($vCand -ne $wRev) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-verification-required'; cause = 'verification-stale'; level = $level }
        }
        $revw = Get-ALValue $Proof 'review' $null
        if ($null -eq $revw) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-review-required'; cause = 'review-missing'; level = $level }
        }
        $rStatus = (([string](Get-ALValue $revw 'status' '')).Trim().ToLowerInvariant())
        if ($rStatus -ceq 'changes_required') {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-changes-required'; cause = 'review-changes-required'; level = $level }
        }
        if ($rStatus -cne 'approved') {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-review-required'; cause = 'review-not-approved'; level = $level }
        }
        $rCand = [long]-2
        try { $rCand = [long](Get-ALValue $revw 'candidate_revision' -2) } catch { $rCand = [long]-2 }
        if ($rCand -lt $wRev) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-review-required'; cause = 'review-stale'; level = $level }
        }
        if ($level -ceq 'L3') {
            $sec = Get-ALValue $Proof 'security_review' $null
            if ($null -eq $sec) {
                return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-review-required'; cause = 'security-review-missing'; level = $level }
            }
            $sStatus = (([string](Get-ALValue $sec 'status' '')).Trim().ToLowerInvariant())
            if ($sStatus -ceq 'changes_required') {
                return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-changes-required'; cause = 'security-changes-required'; level = $level }
            }
            if ($sStatus -cne 'approved') {
                return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-review-required'; cause = 'security-review-not-approved'; level = $level }
            }
            $sCand = [long]-2
            try { $sCand = [long](Get-ALValue $sec 'candidate_revision' -2) } catch { $sCand = [long]-2 }
            if ($sCand -lt $wRev) {
                return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-review-required'; cause = 'security-review-stale'; level = $level }
            }
        }
        return [pscustomobject][ordered]@{ ok = $true; reason = ''; cause = ''; level = $level }
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'continuation-policy-unavailable'; cause = 'gate-internal-error'; level = '' }
    }
}

function Save-SCContinuationCheckpoint {
    <#
    .SYNOPSIS
        Checkpoint padrao + sidecar de correlacao (retrocompativel).
    .DESCRIPTION
        Persiste o checkpoint canonico do goal (Save-ALStepCheckpoint,
        schema existente, sem extensao) e, no mesmo diretorio, um sidecar
        `<checkpoint_id>.settled-continuation.json` correlacionando
        settled_key + referencia do advance record + sucessor. O sidecar e
        projecao aditiva: nunca altera o schema do checkpoint.
    #>
    [CmdletBinding()]
    param($Goal = $null, [string]$CheckpointDir = '', [string]$SettledKey = '', [string]$Move = '', [string]$StopReason = '', [string]$AdvanceRecordRef = '', [string]$NextIdempotencyKey = '', [string]$NextReference = '', [bool]$Prepared = $false)
    try {
        $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
        $cid = ([string](Get-ALValue $ckpt 'checkpoint_id' ''))
        if ((-not [bool](Get-ALValue $ckpt 'ok' $false)) -or ([string]::IsNullOrWhiteSpace($cid))) {
            return [pscustomobject][ordered]@{ ok = $false; checkpoint_id = $cid; checkpoint_ok = $false }
        }
        $dir = ([string]$CheckpointDir).Trim()
        try {
            $dCmd = Get-Command Get-OrchestrationGoalCheckpointStoreDir -ErrorAction SilentlyContinue
            if ($null -ne $dCmd) { $dir = ([string](Get-OrchestrationGoalCheckpointStoreDir -StoreDir $CheckpointDir)).Trim() }
        }
        catch { }
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject][ordered]@{ ok = $false; checkpoint_id = $cid; checkpoint_ok = $false }
        }
        $sidecar = [ordered]@{
            schema_version        = 1
            goal_id               = ([string](Get-ALValue $Goal 'goal_id' ''))
            settled_key           = ([string]$SettledKey).Trim().ToLowerInvariant()
            move                  = ([string]$Move)
            stop_reason           = ([string]$StopReason)
            advance_record_ref    = ([string]$AdvanceRecordRef)
            next_idempotency_key  = ([string]$NextIdempotencyKey)
            next_reference        = ([string]$NextReference)
            prepared              = [bool]$Prepared
            checkpoint_id         = $cid
            recorded_at           = ([DateTime]::UtcNow.ToString('o'))
        }
        try {
            [IO.File]::WriteAllText((Join-Path $dir ($cid + '.settled-continuation.json')), (ConvertTo-Json -InputObject $sidecar -Depth 8 -Compress), [Text.Encoding]::UTF8)
        }
        catch {
            return [pscustomobject][ordered]@{ ok = $false; checkpoint_id = $cid; checkpoint_ok = $false }
        }
        return [pscustomobject][ordered]@{ ok = $true; checkpoint_id = $cid; checkpoint_ok = $true }
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; checkpoint_id = ''; checkpoint_ok = $false }
    }
}

function Test-SCCompletionAuthorization {
    <#
    .SYNOPSIS
        Autorizacao viva antes de qualquer CAS de conclusao (F4).
    .DESCRIPTION
        Read-only, nunca lanca. Exige goal_id da autorizacao igual ao goal
        da continuacao e veredito admitido do helper autoridade do ND
        (`Test-NativeDispatchAuthorization`): explicit_allow real,
        source diferente de test-callback, goal nao terminal, ownership
        viva. Nao confia em owner/generation presentes por si sos.
    #>
    [CmdletBinding()]
    param([string]$GoalId = '', $Authorization = $null, [string]$GoalStoreDir = '')
    try {
        $gid = ([string]$GoalId).Trim()
        $authGoal = ''
        try { $authGoal = ([string](Get-ALValue $Authorization 'goal_id' '')).Trim() } catch { $authGoal = '' }
        if ([string]::IsNullOrWhiteSpace($authGoal) -or ($authGoal -cne $gid)) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'auth-goal-mismatch' }
        }
        $authCmd = Get-Command Test-NativeDispatchAuthorization -ErrorAction SilentlyContinue
        if ($null -eq $authCmd) {
            return [pscustomobject][ordered]@{ ok = $false; reason = 'auth-check-unavailable' }
        }
        $slot = $null
        try { $slot = Test-NativeDispatchAuthorization -Authorization $Authorization -GoalStoreDir $GoalStoreDir } catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-ALValue $slot 'admitted' $false))) {
            $why = 'authorization-denied'
            try { if (-not [string]::IsNullOrWhiteSpace([string](Get-ALValue $slot 'reason' ''))) { $why = ([string](Get-ALValue $slot 'reason' '')) } } catch { }
            return [pscustomobject][ordered]@{ ok = $false; reason = $why }
        }
        return [pscustomobject][ordered]@{ ok = $true; reason = '' }
    }
    catch {
        return [pscustomobject][ordered]@{ ok = $false; reason = 'auth-check-unavailable' }
    }
}

function Invoke-OrchestrationSettledContinuation {
    <#
    .SYNOPSIS
        Continuacao pos-settlement (S3a, fixture-only): UMA sucessao causal.
    .DESCRIPTION
        Entradas (referencias, nunca provas): GoalId, SettledKey,
        Authorization, SessionId, diretorios de goal/task/receipt/evidence/
        checkpoint, NextIntent (somente com sucessor autorizado),
        ControllerPath opcional. Saida: envelope compacto ok/action/reason/
        cause_reason/goal_id/settled_key/evidence_id/candidate_revision/
        move/stop_reason/advance_record_ref/next_idempotency_key/
        next_reference/prepared/checkpoint_id/checkpoint_ok/executor_calls.
        Ordem fail-closed: goal vivo -> advance record (idempotencia) ->
        prova do settlement -> Controller (puro) -> gates do move ->
        ND-ADVANCE (sem FinalizeGoalOnComplete) -> CAS (so COMPLETE
        valido) -> checkpoint. executor_calls e sempre 0.
    #>
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$SettledKey = '',
        $Authorization = $null,
        [string]$SessionId = '',
        [string]$CheckpointDir = '',
        [string]$GoalStoreDir = '',
        [string]$EvidenceStoreDir = '',
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$TasksDir = '',
        [string]$FlagsPath = '',
        [string]$ControllerPath = '',
        $NextIntent = $null
    )
    try {
        $gid = ([string]$GoalId).Trim()
        $sk = ([string]$SettledKey).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($gid)) {
            return (New-SCRefusal -Reason 'continuation-goal-invalid' -Action 'invalid' -GoalId $gid -SettledKey $sk)
        }
        if ($sk -cnotmatch '^[a-f0-9]{32}$') {
            return (New-SCRefusal -Reason 'continuation-key-invalid' -Action 'invalid' -GoalId $gid -SettledKey $sk)
        }
        # (1) goal vivo: COMPLETED reconhece idempotente; fora de ACTIVE
        # nao autoriza (nunca reativa).
        $gCmd = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
        if ($null -eq $gCmd) {
            return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'goal-store-unavailable' -GoalId $gid -SettledKey $sk)
        }
        $gSlot = $null
        try { $gSlot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir } catch { $gSlot = $null }
        if (($null -eq $gSlot) -or (-not [bool](Get-ALValue $gSlot 'ok' $false))) {
            return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'goal-reread-failed' -GoalId $gid -SettledKey $sk)
        }
        $liveGoal = Get-ALValue $gSlot 'goal' $null
        if ($null -eq $liveGoal) {
            return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'goal-reread-failed' -GoalId $gid -SettledKey $sk)
        }
        $liveState = (([string](Get-ALValue $liveGoal 'state' '')).Trim().ToUpperInvariant())
        if ($liveState -ceq 'COMPLETED') {
            $ckDone = Save-SCContinuationCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir -SettledKey $sk -Move '' -StopReason '' -AdvanceRecordRef '' -NextIdempotencyKey '' -NextReference '' -Prepared $false
            return (New-SCEnvelope -Ok $true -Action 'completed' -Reason 'already-completed-idempotent' -GoalId $gid -SettledKey $sk -CheckpointId ([string](Get-ALValue $ckDone 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckDone 'checkpoint_ok' $false)))
        }
        if ($liveState -cne 'ACTIVE') {
            return (New-SCRefusal -Reason 'advance-stale-goal' -Cause ('goal-not-active:' + $liveState) -GoalId $gid -SettledKey $sk)
        }
        # (2) advance record antes de tudo com efeito: no maximo UM sucessor
        # por (goal_id, settled_key); nunca gera chave na recuperacao.
        $rrCmd = Get-Command Get-OrchestrationDispatchReceiptDir -ErrorAction SilentlyContinue
        $adCmd = Get-Command Get-NDAdvanceDir -ErrorAction SilentlyContinue
        $rdAdvCmd = Get-Command Read-NDAdvanceRecord -ErrorAction SilentlyContinue
        if (($null -eq $rrCmd) -or ($null -eq $adCmd) -or ($null -eq $rdAdvCmd)) {
            return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'advance-read-unavailable' -GoalId $gid -SettledKey $sk)
        }
        $recRoot = ''
        try { $recRoot = Get-OrchestrationDispatchReceiptDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot } catch { $recRoot = '' }
        if ([string]::IsNullOrWhiteSpace($recRoot)) {
            return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'receipt-dir-unresolvable' -GoalId $gid -SettledKey $sk)
        }
        $advDirState = $null
        try { $advDirState = Get-NDAdvanceDir -RootDir $recRoot -GoalId $gid } catch { $advDirState = $null }
        if (($null -eq $advDirState) -or (-not [bool](Get-ALValue $advDirState 'ok' $false))) {
            return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'advance-dir-unresolvable' -GoalId $gid -SettledKey $sk)
        }
        $advDir = ([string](Get-ALValue $advDirState 'dir' ''))
        $advRecPath = Join-Path $advDir ($sk + '.advance.json')
        $prior = $null
        try { $prior = Read-NDAdvanceRecord -AdvanceDir $advDir -Key $sk } catch { $prior = $null }
        $advRecExists = $false
        try { $advRecExists = Test-Path -LiteralPath $advRecPath -PathType Leaf } catch { $advRecExists = $false }
        if (($null -eq $prior) -and $advRecExists) {
            return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'advance-record-unreadable' -GoalId $gid -SettledKey $sk)
        }
        if ($null -ne $prior) {
            $pGoal = ([string](Get-ALValue $prior 'goal_id' '')).Trim()
            $pKey = ([string](Get-ALValue $prior 'settled_key' '')).Trim().ToLowerInvariant()
            if (($pGoal -cne $gid) -or ($pKey -cne $sk)) {
                return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'advance-record-mismatch' -GoalId $gid -SettledKey $sk)
            }
            $pMove = (([string](Get-ALValue $prior 'move' '')).Trim().ToUpperInvariant())
            $pOk = [bool](Get-ALValue $prior 'ok' $false)
            $pPrepared = [bool](Get-ALValue $prior 'prepared' $false)
            $pReason = ([string](Get-ALValue $prior 'reason' ''))
            $pMoveReason = ([string](Get-ALValue $prior 'move_reason' ''))
            $pStop = ([string](Get-ALValue $prior 'stop_reason' ''))
            $pNextKey = ([string](Get-ALValue $prior 'next_idempotency_key' '')).Trim().ToLowerInvariant()
            $pNextRef = ([string](Get-ALValue $prior 'next_reference' ''))
            $replayReason = $pReason
            if ([string]::IsNullOrWhiteSpace($replayReason)) { $replayReason = $pMoveReason }
            if ([string]::IsNullOrWhiteSpace($replayReason)) { $replayReason = 'advance-record-replay' }
            if ($pPrepared) {
                # Replay: mesmo sucessor, sem re-preparar. Checkpoint e
                # reescrito (projecao); se falhar, prepared=true com a
                # chave vinculada (pos-PREPARE nao e zero-efeito).
                $ckRep = Save-SCContinuationCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir -SettledKey $sk -Move $pMove -StopReason $pStop -AdvanceRecordRef $advRecPath -NextIdempotencyKey $pNextKey -NextReference $pNextRef -Prepared $true
                $repWhy = $replayReason
                if ([string]::IsNullOrWhiteSpace($pReason)) { $repWhy = 'continuation-replay-prepared' }
                if (-not [bool](Get-ALValue $ckRep 'ok' $false)) { $repWhy = 'continuation-checkpoint-required' }
                return (New-SCEnvelope -Ok $true -Action 'prepared' -Reason $repWhy -CauseReason 'advance-record-replay' -GoalId $gid -SettledKey $sk -Move $pMove -StopReason $pStop -AdvanceRecordRef $advRecPath -NextIdempotencyKey $pNextKey -NextReference $pNextRef -Prepared $true -CheckpointId ([string](Get-ALValue $ckRep 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckRep 'checkpoint_ok' $false)))
            }
            if ((@('REPLAN', 'BLOCKED', 'COMPLETE') -ccontains $pMove)) {
                if ($pMove -ceq 'COMPLETE') {
                    # Replay de COMPLETE: so conclui com stop valido; stop
                    # de politica nunca completa.
                    if ($pStop -cne 'OBJECTIVE_COMPLETED') {
                        $ckBlk = Save-SCContinuationCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir -SettledKey $sk -Move $pMove -StopReason $pStop -AdvanceRecordRef $advRecPath -NextIdempotencyKey '' -NextReference '' -Prepared $false
                        return (New-SCEnvelope -Ok $true -Action 'blocked' -Reason ('stop:' + $pStop) -CauseReason 'advance-record-replay' -GoalId $gid -SettledKey $sk -Move $pMove -StopReason $pStop -AdvanceRecordRef $advRecPath -CheckpointId ([string](Get-ALValue $ckBlk 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckBlk 'checkpoint_ok' $false)))
                    }
                    # F4: autorizacao viva antes de qualquer CAS (zero CAS
                    # sem admissao do helper autoridade do ND).
                    $authzRep = Test-SCCompletionAuthorization -GoalId $gid -Authorization $Authorization -GoalStoreDir $GoalStoreDir
                    if (-not [bool](Get-ALValue $authzRep 'ok' $false)) {
                        $ckAuthRep = Save-SCContinuationCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir -SettledKey $sk -Move $pMove -StopReason $pStop -AdvanceRecordRef $advRecPath -NextIdempotencyKey '' -NextReference '' -Prepared $false
                        return (New-SCEnvelope -Ok $false -Action 'blocked' -Reason 'continuation-completion-unproven' -CauseReason ('authorization:' + [string](Get-ALValue $authzRep 'reason' '')) -GoalId $gid -SettledKey $sk -Move $pMove -StopReason $pStop -AdvanceRecordRef $advRecPath -CheckpointId ([string](Get-ALValue $ckAuthRep 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckAuthRep 'checkpoint_ok' $false)))
                    }
                    $finRep = Invoke-ALObjectiveCompletion -Goal $liveGoal -GoalStoreDir $GoalStoreDir -Authorization $Authorization
                    $finRepGoal = Get-ALValue $finRep 'goal' $liveGoal
                    $ckRep2 = Save-SCContinuationCheckpoint -Goal $finRepGoal -CheckpointDir $CheckpointDir -SettledKey $sk -Move $pMove -StopReason $pStop -AdvanceRecordRef $advRecPath -NextIdempotencyKey '' -NextReference '' -Prepared $false
                    if (([string](Get-ALValue $finRep 'action' 'blocked') -ceq 'completed') -and [bool](Get-ALValue $finRep 'ok' $false)) {
                        return (New-SCEnvelope -Ok $true -Action 'completed' -Reason ([string](Get-ALValue $finRep 'reason' '')) -CauseReason 'advance-record-replay' -GoalId $gid -SettledKey $sk -Move $pMove -StopReason $pStop -AdvanceRecordRef $advRecPath -CheckpointId ([string](Get-ALValue $ckRep2 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckRep2 'checkpoint_ok' $false)))
                    }
                    return (New-SCEnvelope -Ok $false -Action 'blocked' -Reason 'continuation-completion-unproven' -CauseReason ([string](Get-ALValue $finRep 'reason' '')) -GoalId $gid -SettledKey $sk -Move $pMove -StopReason $pStop -AdvanceRecordRef $advRecPath -CheckpointId ([string](Get-ALValue $ckRep2 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckRep2 'checkpoint_ok' $false)))
                }
                $repAction = 'blocked'
                if ($pMove -ceq 'REPLAN') { $repAction = 'replan_required' }
                $ckTerm = Save-SCContinuationCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir -SettledKey $sk -Move $pMove -StopReason $pStop -AdvanceRecordRef $advRecPath -NextIdempotencyKey '' -NextReference '' -Prepared $false
                return (New-SCEnvelope -Ok $pOk -Action $repAction -Reason $replayReason -CauseReason 'advance-record-replay' -GoalId $gid -SettledKey $sk -Move $pMove -StopReason $pStop -AdvanceRecordRef $advRecPath -CheckpointId ([string](Get-ALValue $ckTerm 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckTerm 'checkpoint_ok' $false)))
            }
            # Pendente (CONTINUE/RETRY nao preparado): a S3a nao recupera
            # sozinha; S4/manual reconcilia. Zero novo efeito.
            return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'advance-record-pending' -GoalId $gid -SettledKey $sk)
        }
        # (3) prova do settlement (recibo settled + evidencia + kernel).
        # Nao reutiliza a prova `claimed` do SETTLE: rele recibo settled.
        $proof = Get-SCSettlementProof -GoalId $gid -SettledKey $sk -GoalStoreDir $GoalStoreDir -EvidenceStoreDir $EvidenceStoreDir -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot -TasksDir $TasksDir
        if (-not [bool](Get-ALValue $proof 'ok' $false)) {
            return (New-SCRefusal -Reason ([string](Get-ALValue $proof 'reason' 'continuation-settlement-unproven')) -Cause ([string](Get-ALValue $proof 'cause' '')) -GoalId $gid -SettledKey $sk)
        }
        $evIdP = ([string](Get-ALValue $proof 'evidence_id' ''))
        $wRevP = [long](Get-ALValue $proof 'worker_revision' -1)
        # (4) Controller (puro, sem efeitos). Com ControllerPath, a
        # definicao vale neste escopo e no ADVANCE abaixo.
        $ctlPath = ([string]$ControllerPath).Trim()
        if (-not [string]::IsNullOrWhiteSpace($ctlPath)) {
            if (-not (Test-Path -LiteralPath $ctlPath -PathType Leaf)) {
                return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'controller-unavailable' -GoalId $gid -SettledKey $sk)
            }
            try { . $ctlPath } catch {
                return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'controller-unavailable' -GoalId $gid -SettledKey $sk)
            }
        }
        $ctlCmd = Get-Command Get-OrchestrationNextMove -ErrorAction SilentlyContinue
        if ($null -eq $ctlCmd) {
            $sibling = Join-Path $PSScriptRoot 'OrchestrationObjectiveController.ps1'
            if (Test-Path -LiteralPath $sibling -PathType Leaf) { try { . $sibling } catch { } }
            $ctlCmd = Get-Command Get-OrchestrationNextMove -ErrorAction SilentlyContinue
        }
        if ($null -eq $ctlCmd) {
            return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'controller-unavailable' -GoalId $gid -SettledKey $sk)
        }
        # (4b) status: derivado do goal vivo + falha provada (failed =>
        # recoverable, blocked => terminal). completed vem do gate global,
        # nunca do estado (goal COMPLETED saiu no passo 1).
        $gateNow = Test-ObjectiveCompletionAllowed -Goal $liveGoal
        $completedNow = [bool](Get-ALValue $gateNow 'allowed' $false)
        $remaining = New-Object System.Collections.ArrayList
        try {
            foreach ($t in @((Get-ALValue $liveGoal 'active_tasks' @()))) { [void]$remaining.Add(([string]$t)) }
        }
        catch { }
        $crit = @((Get-ALValue $liveGoal 'criteria' @()))
        $sat = [long]0
        try { $sat = [long](Get-ALValue (Get-ALValue $liveGoal 'progress' $null) 'satisfied' 0) } catch { $sat = [long]0 }
        if ($sat -lt 0) { $sat = 0 }
        if ($sat -gt @($crit).Count) { $sat = @($crit).Count }
        for ($i = $sat; $i -lt @($crit).Count; $i++) { [void]$remaining.Add(('criterion:' + [string]$crit[$i])) }
        $wStatusNow = ([string](Get-ALValue $proof 'worker_status' ''))
        $failFlag = $null
        if ($wStatusNow -ceq 'failed') { $failFlag = 'recoverable' }
        elseif ($wStatusNow -ceq 'blocked') { $failFlag = 'terminal' }
        $scStatus = @{
            objective_completed     = [bool]$completedNow
            remaining_work          = [string[]]$remaining.ToArray()
            authorized              = $true
            blocker_kind            = ''
            progress_possible       = $true
            strategy_change         = $false
            context_degraded        = $false
            last_failure            = $failFlag
            terminal_blocker        = $null
            consecutive_no_progress = [long]0
        }
        $moveObj = $null
        try { $moveObj = Get-OrchestrationNextMove -Status $scStatus } catch { $moveObj = $null }
        if ($null -eq $moveObj) {
            return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'controller-move-failed' -GoalId $gid -SettledKey $sk)
        }
        $moveName = (([string](Get-ALValue $moveObj 'move' '')).Trim().ToUpperInvariant())
        $moveReason = ([string](Get-ALValue $moveObj 'reason' ''))
        $stopName = (([string](Get-ALValue $moveObj 'stop_reason' '')).Trim().ToUpperInvariant())
        # (5) gates do move, ANTES de qualquer efeito.
        $nextForAdvance = $null
        if (($moveName -ceq 'CONTINUE') -or ($moveName -ceq 'RETRY')) {
            if ($null -eq $NextIntent) {
                return (New-SCRefusal -Reason 'continuation-next-intent-missing' -Action 'invalid' -GoalId $gid -SettledKey $sk)
            }
            $realNext = Get-ALValue $NextIntent 'intent' $null
            if ($null -eq $realNext) { $realNext = $NextIntent }
            $nextKey = (([string](Get-ALValue $realNext 'idempotency_key' '')).Trim().ToLowerInvariant())
            if ($nextKey -cnotmatch '^[a-f0-9]{32}$') {
                return (New-SCRefusal -Reason 'continuation-next-intent-missing' -Cause 'next-intent-key-invalid' -Action 'invalid' -GoalId $gid -SettledKey $sk)
            }
            if ($nextKey -ceq $sk) {
                return (New-SCRefusal -Reason 'continuation-task-result-mismatch' -Cause 'next-key-reuses-settlement' -GoalId $gid -SettledKey $sk)
            }
            $nextForAdvance = $NextIntent
        }
        if ($moveName -ceq 'CONTINUE') {
            $cg = Test-SCContinueGate -Proof $proof -Policy $null -Goal $liveGoal
            if (-not [bool](Get-ALValue $cg 'ok' $false)) {
                return (New-SCRefusal -Reason ([string](Get-ALValue $cg 'reason' '')) -Cause ([string](Get-ALValue $cg 'cause' '')) -GoalId $gid -SettledKey $sk)
            }
            $taskStateNow = ([string](Get-ALValue $proof 'task_state' ''))
            if ($taskStateNow -cne 'DONE') {
                return (New-SCRefusal -Reason 'continuation-verification-required' -Cause 'task-not-done' -GoalId $gid -SettledKey $sk)
            }
        }
        if ($moveName -ceq 'RETRY') {
            $taskStateNow = ([string](Get-ALValue $proof 'task_state' ''))
            if ($taskStateNow -ceq 'DONE') {
                return (New-SCRefusal -Reason 'continuation-task-result-mismatch' -Cause 'task-already-done' -GoalId $gid -SettledKey $sk)
            }
            $wFailed = ($wStatusNow -ceq 'failed')
            $verNode = Get-ALValue $proof 'verification' $null
            $verFreshFailed = $false
            $verFreshPassed = $false
            if ($null -ne $verNode) {
                $vc = [long]-2
                try { $vc = [long](Get-ALValue $verNode 'candidate_revision' -2) } catch { $vc = [long]-2 }
                $vFresh = ($vc -eq $wRevP)
                $vPass = $false
                try { $vPass = [bool](Get-ALValue $verNode 'passed' $false) } catch { $vPass = $false }
                if ($vFresh -and (-not $vPass)) { $verFreshFailed = $true }
                if ($vFresh -and $vPass) { $verFreshPassed = $true }
            }
            if ($wFailed -and $verFreshPassed) {
                return (New-SCRefusal -Reason 'continuation-task-result-mismatch' -Cause 'verification-contradicts-failure' -GoalId $gid -SettledKey $sk)
            }
            if ((-not $wFailed) -and (-not $verFreshFailed)) {
                if ($wStatusNow -cne 'candidate_pass') {
                    return (New-SCRefusal -Reason 'continuation-task-result-mismatch' -Cause ('worker-status:' + $wStatusNow) -GoalId $gid -SettledKey $sk)
                }
                return (New-SCRefusal -Reason 'continuation-verification-required' -Cause 'no-failure-proven' -GoalId $gid -SettledKey $sk)
            }
        }
        if (($moveName -ceq 'COMPLETE') -and ($stopName -ceq 'OBJECTIVE_COMPLETED')) {
            $gateLive = Test-ObjectiveCompletionAllowed -Goal $liveGoal
            if (-not [bool](Get-ALValue $gateLive 'allowed' $false)) {
                return (New-SCRefusal -Reason 'continuation-completion-unproven' -Cause ([string](Get-ALValue $gateLive 'reason' 'criteria-unverified')) -GoalId $gid -SettledKey $sk)
            }
        }
        # (6) ND-ADVANCE (sem FinalizeGoalOnComplete: a S3a finaliza via
        # CAS proprio). Decisao REPLAN/BLOCKED/COMPLETE nao prepara.
        $advCmd = Get-Command Invoke-OrchestrationNativeDispatchAdvance -ErrorAction SilentlyContinue
        if ($null -eq $advCmd) {
            return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'advance-unavailable' -GoalId $gid -SettledKey $sk)
        }
        $adv = $null
        try {
            if ($null -ne $nextForAdvance) {
                $adv = Invoke-OrchestrationNativeDispatchAdvance -GoalId $gid -SettledKey $sk -Authorization $Authorization -ObjectiveStatus $scStatus -NextIntent $nextForAdvance -SessionId ([string]$SessionId).Trim() -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot -GoalStoreDir $GoalStoreDir -TasksDir $TasksDir -FlagsPath $FlagsPath
            }
            else {
                $adv = Invoke-OrchestrationNativeDispatchAdvance -GoalId $gid -SettledKey $sk -Authorization $Authorization -ObjectiveStatus $scStatus -SessionId ([string]$SessionId).Trim() -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot -GoalStoreDir $GoalStoreDir -TasksDir $TasksDir -FlagsPath $FlagsPath
            }
        }
        catch { $adv = $null }
        if ($null -eq $adv) {
            return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'advance-exception' -GoalId $gid -SettledKey $sk)
        }
        $advMove = (([string](Get-ALValue $adv 'move' '')).Trim().ToUpperInvariant())
        $advOk = [bool](Get-ALValue $adv 'ok' $false)
        $advReason = ([string](Get-ALValue $adv 'reason' ''))
        $advCause = ([string](Get-ALValue $adv 'move_reason' ''))
        $advRef = ([string](Get-ALValue $adv 'record_path' ''))
        $advNextKey = ([string](Get-ALValue $adv 'idempotency_key' '')).Trim().ToLowerInvariant()
        $advNextRef = ([string](Get-ALValue $adv 'reference' ''))
        $advStop = (([string](Get-ALValue $adv 'stop_reason' '')).Trim().ToUpperInvariant())
        # F2: o PREPARE e efeito mesmo quando o ADVANCE devolve ok=false
        # (ex.: advance-record-write-failed apos preparar). Le `prepared`
        # independente de `ok` e preserva o efeito em vez de colapsar em
        # recusa sem efeito. Move divergente continua recusado.
        $advPrepared = [bool](Get-ALValue $adv 'prepared' $false)
        if (((@('CONTINUE', 'RETRY') -ccontains $advMove)) -and $advPrepared) {
            if ($advMove -cne $moveName) {
                return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'advance-move-diverged' -GoalId $gid -SettledKey $sk)
            }
            # Pos-PREPARE confirmado: falha de checkpoint NAO e zero-efeito.
            $ckPrep = Save-SCContinuationCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir -SettledKey $sk -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -NextIdempotencyKey $advNextKey -NextReference $advNextRef -Prepared $true
            if ($advOk) {
                $prepWhy = 'prepared'
                $ckPrepOk = [bool](Get-ALValue $ckPrep 'checkpoint_ok' $false)
                if (-not [bool](Get-ALValue $ckPrep 'ok' $false)) { $prepWhy = 'continuation-checkpoint-required' }
                return (New-SCEnvelope -Ok $true -Action 'prepared' -Reason $prepWhy -CauseReason $advCause -GoalId $gid -SettledKey $sk -EvidenceId $evIdP -CandidateRevision $wRevP -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -NextIdempotencyKey $advNextKey -NextReference $advNextRef -Prepared $true -CheckpointId ([string](Get-ALValue $ckPrep 'checkpoint_id' '')) -CheckpointOk $ckPrepOk)
            }
            return (New-SCEnvelope -Ok $false -Action 'prepared' -Reason 'continuation-settlement-uncertain' -CauseReason $advReason -GoalId $gid -SettledKey $sk -EvidenceId $evIdP -CandidateRevision $wRevP -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -NextIdempotencyKey $advNextKey -NextReference $advNextRef -Prepared $true -CheckpointId ([string](Get-ALValue $ckPrep 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckPrep 'checkpoint_ok' $false)))
        }
        if ($advOk -and ($advMove -ceq 'REPLAN')) {
            $replanWhy = $advCause
            if ([string]::IsNullOrWhiteSpace($replanWhy)) { $replanWhy = 'replan-recorded' }
            $ckReplan = Save-SCContinuationCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir -SettledKey $sk -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -NextIdempotencyKey '' -NextReference '' -Prepared $false
            return (New-SCEnvelope -Ok $true -Action 'replan_required' -Reason $replanWhy -GoalId $gid -SettledKey $sk -EvidenceId $evIdP -CandidateRevision $wRevP -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -CheckpointId ([string](Get-ALValue $ckReplan 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckReplan 'checkpoint_ok' $false)))
        }
        if ($advOk -and ($advMove -ceq 'COMPLETE')) {
            if ($advStop -cne 'OBJECTIVE_COMPLETED') {
                $ckStop = Save-SCContinuationCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir -SettledKey $sk -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -NextIdempotencyKey '' -NextReference '' -Prepared $false
                return (New-SCEnvelope -Ok $true -Action 'blocked' -Reason ('stop:' + $advStop) -CauseReason $advCause -GoalId $gid -SettledKey $sk -EvidenceId $evIdP -CandidateRevision $wRevP -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -CheckpointId ([string](Get-ALValue $ckStop 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckStop 'checkpoint_ok' $false)))
            }
            # F4: autorizacao viva antes de qualquer CAS (zero CAS sem
            # admissao do helper autoridade do ND).
            $authzFin = Test-SCCompletionAuthorization -GoalId $gid -Authorization $Authorization -GoalStoreDir $GoalStoreDir
            if (-not [bool](Get-ALValue $authzFin 'ok' $false)) {
                $ckAuthFin = Save-SCContinuationCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir -SettledKey $sk -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -NextIdempotencyKey '' -NextReference '' -Prepared $false
                return (New-SCEnvelope -Ok $false -Action 'blocked' -Reason 'continuation-completion-unproven' -CauseReason ('authorization:' + [string](Get-ALValue $authzFin 'reason' '')) -GoalId $gid -SettledKey $sk -EvidenceId $evIdP -CandidateRevision $wRevP -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -CheckpointId ([string](Get-ALValue $ckAuthFin 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckAuthFin 'checkpoint_ok' $false)))
            }
            $fin = Invoke-ALObjectiveCompletion -Goal $liveGoal -GoalStoreDir $GoalStoreDir -Authorization $Authorization
            $finGoal = Get-ALValue $fin 'goal' $liveGoal
            $ckFin = Save-SCContinuationCheckpoint -Goal $finGoal -CheckpointDir $CheckpointDir -SettledKey $sk -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -NextIdempotencyKey '' -NextReference '' -Prepared $false
            if (([string](Get-ALValue $fin 'action' 'blocked') -ceq 'completed') -and [bool](Get-ALValue $fin 'ok' $false)) {
                return (New-SCEnvelope -Ok $true -Action 'completed' -Reason ([string](Get-ALValue $fin 'reason' '')) -GoalId $gid -SettledKey $sk -EvidenceId $evIdP -CandidateRevision $wRevP -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -CheckpointId ([string](Get-ALValue $ckFin 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckFin 'checkpoint_ok' $false)))
            }
            return (New-SCEnvelope -Ok $false -Action 'blocked' -Reason 'continuation-completion-unproven' -CauseReason ([string](Get-ALValue $fin 'reason' '')) -GoalId $gid -SettledKey $sk -EvidenceId $evIdP -CandidateRevision $wRevP -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -CheckpointId ([string](Get-ALValue $ckFin 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckFin 'checkpoint_ok' $false)))
        }
        # Qualquer outra recusa do ADVANCE: zero-efeito preservado; os
        # codigos advance-* sao expostos com a causa separada.
        $blkWhy = $advReason
        if ([string]::IsNullOrWhiteSpace($blkWhy)) { $blkWhy = 'advance-refused' }
        return (New-SCEnvelope -Ok $false -Action 'blocked' -Reason $blkWhy -CauseReason $advCause -GoalId $gid -SettledKey $sk -EvidenceId $evIdP -CandidateRevision $wRevP -Move $advMove -StopReason $advStop -AdvanceRecordRef $advRef -CheckpointId '' -CheckpointOk $false)
    }
    catch {
        return (New-SCRefusal -Reason 'continuation-settlement-uncertain' -Cause 'continuation-internal-error' -GoalId ([string]$GoalId).Trim() -SettledKey ([string]$SettledKey).Trim())
    }
}
