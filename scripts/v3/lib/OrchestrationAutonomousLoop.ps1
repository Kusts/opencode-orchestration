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
    foreach ($ALLib in @('OrchestrationGoalKernel.ps1', 'OrchestrationGoalCheckpoint.ps1', 'OrchestrationObjectiveController.ps1', 'OrchestrationNativeDispatch.ps1', 'OrchestrationRuntimeAdapterContract.ps1')) {
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
        [string]$ControllerPath = ''
    )
    try {
        $watchdog = Get-ALWatchdogReference
        if ($null -eq $Goal) {
            return (New-ALStepEnvelope -Ok $false -Action 'invalid' -Reason 'goal-missing' -Watchdog $watchdog)
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
                # F4+R4: reconhecimento idempotente de terminal vs conclusao
                # persistida. Goal ja COMPLETED -> completed sem mutacao.
                # ACTIVE com criterios satisfeitos -> transicao CAS via
                # Set-OrchestrationGoalStatePersisted (nunca so em memoria).
                # R4: COMPLETED so e anunciado com leitura canonica viva
                # bem-sucedida do store; fallback em memoria com leitura
                # ausente/corrompida bloqueia, nunca anuncia completed.
                $liveGoal = $Goal
                $gidLive = ([string](Get-ALValue $Goal 'goal_id' '')).Trim()
                if ([string]::IsNullOrWhiteSpace($gidLive)) {
                    $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
                    return (New-ALStepEnvelope -Ok $false -Action 'blocked' -Reason 'goal-id-missing' -Goal $Goal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
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
                    $ckpt = Save-ALStepCheckpoint -Goal $Goal -CheckpointDir $CheckpointDir
                    return (New-ALStepEnvelope -Ok $false -Action 'blocked' -Reason 'goal-reread-failed' -Goal $Goal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
                }
                $liveState = (([string](Get-ALValue $liveGoal 'state' '')).Trim().ToUpperInvariant())
                if ($liveState -ceq 'COMPLETED') {
                    $ckpt = Save-ALStepCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir
                    return (New-ALStepEnvelope -Ok $true -Action 'completed' -Reason 'already-completed-idempotent' -Goal $liveGoal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
                }
                $gate = Test-ObjectiveCompletionAllowed -Goal $liveGoal
                if (-not [bool](Get-ALValue $gate 'allowed' $false)) {
                    $ckpt = Save-ALStepCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir
                    return (New-ALStepEnvelope -Ok $true -Action 'blocked' -Reason ([string](Get-ALValue $gate 'reason' 'criteria-unverified')) -Goal $liveGoal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
                }
                $ownId = ([string](Get-ALValue $Authorization 'owner' '')).Trim()
                $ownGen = [long](Get-ALValue $Authorization 'generation' 0)
                if ([string]::IsNullOrWhiteSpace($gidLive) -or [string]::IsNullOrWhiteSpace($ownId) -or ($ownGen -lt 1)) {
                    $ckpt = Save-ALStepCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir
                    return (New-ALStepEnvelope -Ok $false -Action 'blocked' -Reason 'completion-auth-missing' -Goal $liveGoal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
                }
                $persistCmd = Get-Command Set-OrchestrationGoalStatePersisted -ErrorAction SilentlyContinue
                if ($null -eq $persistCmd) {
                    $ckpt = Save-ALStepCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir
                    return (New-ALStepEnvelope -Ok $false -Action 'blocked' -Reason 'completion-persist-unavailable' -Goal $liveGoal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
                }
                $liveRev = [long](Get-ALValue $liveGoal 'revision' 0)
                $finSlot = $null
                try { $finSlot = Set-OrchestrationGoalStatePersisted -GoalId $gidLive -ToState 'COMPLETED' -ExpectedRevision $liveRev -StoreDir $GoalStoreDir -OwnerId $ownId -OwnershipGeneration $ownGen } catch { $finSlot = $null }
                if (($null -eq $finSlot) -or (-not [bool](Get-ALValue $finSlot 'ok' $false))) {
                    $why = 'finalize-failed'
                    try { if (-not [string]::IsNullOrWhiteSpace([string](Get-ALValue $finSlot 'reason' ''))) { $why = ('finalize-failed:' + [string](Get-ALValue $finSlot 'reason' '')) } } catch { }
                    $ckpt = Save-ALStepCheckpoint -Goal $liveGoal -CheckpointDir $CheckpointDir
                    return (New-ALStepEnvelope -Ok $false -Action 'blocked' -Reason $why -Goal $liveGoal -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
                }
                $final = Get-ALValue $finSlot 'goal' $liveGoal
                $ckpt = Save-ALStepCheckpoint -Goal $final -CheckpointDir $CheckpointDir
                return (New-ALStepEnvelope -Ok $true -Action 'completed' -Reason 'objective-completed-verified' -Goal $final -NextMove $move -CheckpointId ([string](Get-ALValue $ckpt 'checkpoint_id' '')) -CheckpointOk ([bool](Get-ALValue $ckpt 'ok' $false)) -Watchdog $watchdog)
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
