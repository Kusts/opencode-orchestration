<#!
.SYNOPSIS
    Etapa 6D GH-WAKE controller handoff driver (single-shot, fail-closed).
.DESCRIPTION
    Single-shot CLI, dot-source safe. Consumes ONE next_action envelope
    produced by github-wake.ps1 (Invoke-GitHubWake) and hands it to the
    real controller through the existing contracts only:

      - validation: Invoke-GHWakeControllerHandoff (defined in
        github-wake.ps1, dot-sourced here; never reimplemented here);
      - controller read path: Get-OrchestrationGoalNextMove
        (GoalKernel + ObjectiveController, read-only);
      - settlement (Planner-attested only): Set-GHWakeDispatchSettlement
        (Claim + Settle of the prepared receipt with the REAL child
        session id). PS cannot spawn a native worker outside the
        Planner LLM (subagent/task). Without an Executor the honest
        outcome is intent-ready awaits-planner-dispatch: the Planner
        executes the dispatch via subagent, then completes the loop by
        re-invoking this driver with -SettleSessionId (plus
        -SettleResultOk/-SettleResultSummary). This driver never
        synthesizes a dispatch and never treats a probe-positive as
        execution.

    IMPLEMENTING alone is never execution: the Kernel transition
    BLOCKED->IMPLEMENTING only unblocks the task; executed=$true appears
    solely when Set-GHWakeDispatchSettlement completes the productive
    Claim + Settle chain with a Planner-attested session id. A bare
    IMPLEMENTING task with no handoff envelope yields no-next-action,
    a positive controller probe is only a controller-responded signal
    (marker stays claimed, dispatched stays false), and a prepared
    receipt without settle params is only intent-ready
    (awaits-planner-dispatch) until the Planner settles it.

    Authority: never merges, pushes, deploys, completes tasks, issues
    grants, or reads tokens. No daemon, no watcher, no loop, no sleep,
    no background work: one pass, then exit. Idempotent: a repeated call
    with the same event_id returns not-dispatched duplicate-noop without
    replaying any task effect (wait applied_events + handoff marker).

    Usage (envelope file from a wake tick):
      powershell -NoProfile -File github-wake-controller.ps1 `
        -WakeEnvelopeFile <wake.json> -WaitsDir <dir> -TasksDir <dir> `
        -GoalStoreDir <dir> -CheckpointDir <dir> -FlagsPath <flags>

    Usage (inline next_action JSON):
      powershell -NoProfile -File github-wake-controller.ps1 `
        -NextActionJson '<json>' -WaitsDir <dir> -TasksDir <dir> `
        -GoalStoreDir <dir> -CheckpointDir <dir>

    Usage (Planner settle after a real subagent run):
      powershell -NoProfile -File github-wake-controller.ps1 `
        -NextActionFile <next-action.json> -WaitsDir <dir> -TasksDir <dir> `
        -GoalStoreDir <dir> -CheckpointDir <dir> -FlagsPath <flags> `
        -SettleSessionId <child-session-id> -SettleResultOk $true `
        -SettleResultSummary '<short summary>'

    Exit 0 = handoff evaluated (dispatched or HOLD are data, not
    failure). Exit 1 = handoff could not be evaluated. Exit 2 = args.
    Stdout carries exactly one JSON envelope. Dot-source safe: without
    -WakeEnvelopeFile, -NextActionFile and -NextActionJson this file
    defines no behavior and executes nothing.
#>
param(
    [string]$WakeEnvelopeFile = '',
    [string]$NextActionFile = '',
    [string]$NextActionJson = '',
    [string]$WaitsDir = '',
    [string]$TasksDir = '',
    [string]$GoalStoreDir = '',
    [string]$CheckpointDir = '',
    [string]$HandoffStateDir = '',
    [string]$ReceiptDir = '',
    [string]$RepoRoot = '',
    [string]$EvidenceStoreDir = '',
    [string]$FlagsPath = '',
    [string]$NowUtc = '',
    [string]$SettleSessionId = '',
    $SettleResultOk = $null,
    [string]$SettleResultSummary = '',
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'

# Dot-sourcing github-wake.ps1 runs its param block in this scope, which
# would overwrite same-named parameters. Save and restore around dot-source.
$GHWC_SavedWakeEnvelopeFile = $WakeEnvelopeFile
$GHWC_SavedNextActionFile = $NextActionFile
$GHWC_SavedNextActionJson = $NextActionJson
$GHWC_SavedWaitsDir = $WaitsDir
$GHWC_SavedTasksDir = $TasksDir
$GHWC_SavedGoalStoreDir = $GoalStoreDir
$GHWC_SavedCheckpointDir = $CheckpointDir
$GHWC_SavedHandoffStateDir = $HandoffStateDir
$GHWC_SavedReceiptDir = $ReceiptDir
$GHWC_SavedRepoRoot = $RepoRoot
$GHWC_SavedEvidenceStoreDir = $EvidenceStoreDir
$GHWC_SavedFlagsPath = $FlagsPath
$GHWC_SavedNowUtc = $NowUtc
$GHWC_SavedSettleSessionId = $SettleSessionId
$GHWC_SavedSettleResultOk = $SettleResultOk
$GHWC_SavedSettleResultSummary = $SettleResultSummary
$GHWC_SavedOutFile = $OutFile
. (Join-Path $PSScriptRoot 'github-wake.ps1')
$WakeEnvelopeFile = $GHWC_SavedWakeEnvelopeFile
$NextActionFile = $GHWC_SavedNextActionFile
$NextActionJson = $GHWC_SavedNextActionJson
$WaitsDir = $GHWC_SavedWaitsDir
$TasksDir = $GHWC_SavedTasksDir
$GoalStoreDir = $GHWC_SavedGoalStoreDir
$CheckpointDir = $GHWC_SavedCheckpointDir
$HandoffStateDir = $GHWC_SavedHandoffStateDir
$ReceiptDir = $GHWC_SavedReceiptDir
$RepoRoot = $GHWC_SavedRepoRoot
$EvidenceStoreDir = $GHWC_SavedEvidenceStoreDir
$FlagsPath = $GHWC_SavedFlagsPath
$NowUtc = $GHWC_SavedNowUtc
$SettleSessionId = $GHWC_SavedSettleSessionId
$SettleResultOk = $GHWC_SavedSettleResultOk
$SettleResultSummary = $GHWC_SavedSettleResultSummary
$OutFile = $GHWC_SavedOutFile
Remove-Variable -Name GHWC_SavedWakeEnvelopeFile, GHWC_SavedNextActionFile, GHWC_SavedNextActionJson, GHWC_SavedWaitsDir, GHWC_SavedTasksDir, GHWC_SavedGoalStoreDir, GHWC_SavedCheckpointDir, GHWC_SavedHandoffStateDir, GHWC_SavedReceiptDir, GHWC_SavedRepoRoot, GHWC_SavedEvidenceStoreDir, GHWC_SavedFlagsPath, GHWC_SavedNowUtc, GHWC_SavedSettleSessionId, GHWC_SavedSettleResultOk, GHWC_SavedSettleResultSummary, GHWC_SavedOutFile -ErrorAction SilentlyContinue

function Get-GHWCValue {
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

function Read-GHWCJsonFile {
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $fi = Get-Item -LiteralPath $Path -Force
        if ([long]$fi.Length -le 0 -or [long]$fi.Length -gt 262144) { return $null }
        return (ConvertFrom-Json ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)))
    }
    catch { return $null }
}

function Invoke-GitHubWakeController {
    [CmdletBinding()]
    param(
        $NextAction = $null,
        [string]$WaitsDir = '',
        [string]$TasksDir = '',
        [string]$GoalStoreDir = '',
        [string]$CheckpointDir = '',
        [string]$HandoffStateDir = '',
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [string]$EvidenceStoreDir = '',
        [string]$FlagsPath = '',
        [string]$NowUtc = '',
        [string]$SettleSessionId = '',
        $SettleResultOk = $null,
        [string]$SettleResultSummary = ''
    )
    try {
        $hsd = ([string]$HandoffStateDir).Trim()
        if ([string]::IsNullOrWhiteSpace($hsd)) { $hsd = ([string]$CheckpointDir).Trim() }
        $res = Invoke-GHWakeControllerHandoff -NextAction $NextAction `
            -WaitsDir $WaitsDir -TasksDir $TasksDir -GoalStoreDir $GoalStoreDir `
            -CheckpointDir $CheckpointDir -FlagsPath $FlagsPath -NowUtc $NowUtc `
            -HandoffStateDir $hsd -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot `
            -EvidenceStoreDir $EvidenceStoreDir
        if ($null -eq $res) {
            return [pscustomobject]@{
                ok = $false; harness = 'github-wake-controller-v1'; verdict = 'CONTROLLER_FAIL'
                dispatched = $false; decision = 'not-dispatched'; reason = 'internal-error'
                controller = 'none'; task_id = ''; idempotency_key = ''
                kernel_state = 'UNKNOWN'; executed = $false
                grants_authority = $false; done_approved = $false; merge_authority = $false
                next_action = $NextAction
            }
        }
        $settleSid = ([string]$SettleSessionId).Trim()
        if (-not [string]::IsNullOrWhiteSpace($settleSid)) {
            $dec0 = ([string](Get-GHWCValue $res 'decision' '')).Trim()
            $rsn0 = ([string](Get-GHWCValue $res 'reason' '')).Trim()
            $mk0 = ([string](Get-GHWCValue $res 'marker_path' '')).Trim()
            $dupNoop = (($dec0 -ceq 'duplicate-noop') -or (($dec0 -ceq 'not-dispatched') -and ($rsn0 -ceq 'duplicate-noop')))
            if ([string]::IsNullOrWhiteSpace($mk0) -and $dupNoop) {
                # Replay of an already-claimed handoff: the fresh claim
                # refused as duplicate before prepare, but the claimed
                # marker + pending receipt are still settleable by the
                # Planner. Derive the deterministic marker path; absence
                # or mismatch stays fail-closed inside the settlement.
                $idem0 = ([string](Get-GHWCValue $res 'idempotency_key' '')).Trim().ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($idem0)) {
                    try { $idem0 = ([string](Get-GHWCValue $NextAction 'idempotency_key' '')).Trim().ToLowerInvariant() } catch { $idem0 = '' }
                }
                if ($idem0 -cmatch '^[a-f0-9]{32}$') {
                    $cand0 = Join-Path $hsd ('ghw-handoff-' + $idem0 + '.json')
                    try {
                        if (Test-Path -LiteralPath $cand0 -PathType Leaf) { $mk0 = $cand0 }
                    }
                    catch { }
                }
            }
            if ((($dec0 -ceq 'intent-ready') -or ($dec0 -ceq 'controller-responded') -or $dupNoop) -and (-not [string]::IsNullOrWhiteSpace($mk0))) {
                $settleOk = $null
                if ($SettleResultOk -is [bool]) { $settleOk = [bool]$SettleResultOk }
                elseif (($SettleResultOk -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$SettleResultOk))) {
                    $st = ([string]$SettleResultOk).Trim().ToLowerInvariant()
                    if (($st -ceq 'true') -or ($st -ceq '$true') -or ($st -ceq '1')) { $settleOk = $true }
                    elseif (($st -ceq 'false') -or ($st -ceq '$false') -or ($st -ceq '0')) { $settleOk = $false }
                }
                if ($null -eq $settleOk) {
                    return [pscustomobject]@{
                        ok = $false; harness = 'github-wake-controller-v1'; verdict = 'CONTROLLER_FAIL'
                        dispatched = $false; decision = 'not-dispatched'; reason = 'settle-result-invalid'
                        controller = ([string](Get-GHWCValue $res 'controller' 'none'))
                        task_id = ([string](Get-GHWCValue $res 'task_id' ''))
                        idempotency_key = ([string](Get-GHWCValue $res 'idempotency_key' ''))
                        kernel_state = ([string](Get-GHWValue $NextAction 'kernel_state' 'UNKNOWN')); executed = $false
                        grants_authority = $false; done_approved = $false; merge_authority = $false
                        marker_path = $mk0
                        next_action = $NextAction
                    }
                }
                $expGoal = ([string](Get-GHWCValue $NextAction 'goal_id' '')).Trim()
                $expTask = ([string](Get-GHWCValue $NextAction 'task_id' '')).Trim()
                $stOut = $null
                try {
                    $stOut = Set-GHWakeDispatchSettlement -MarkerPath $mk0 -SessionId $settleSid `
                        -ResultOk ([bool]$settleOk) -ResultSummary ([string]$SettleResultSummary).Trim() `
                        -ReceiptDir $ReceiptDir -RepoRoot $RepoRoot -GoalStoreDir $GoalStoreDir `
                        -TasksDir $TasksDir -EvidenceStoreDir $EvidenceStoreDir -FlagsPath $FlagsPath `
                        -ExpectedGoalId $expGoal -ExpectedTaskId $expTask
                }
                catch { $stOut = $null }
                if ($null -eq $stOut) {
                    return [pscustomobject]@{
                        ok = $false; harness = 'github-wake-controller-v1'; verdict = 'CONTROLLER_FAIL'
                        dispatched = $false; decision = 'not-dispatched'; reason = 'internal-error'
                        controller = ([string](Get-GHWCValue $res 'controller' 'none'))
                        task_id = ([string](Get-GHWCValue $res 'task_id' ''))
                        idempotency_key = ([string](Get-GHWCValue $res 'idempotency_key' ''))
                        kernel_state = ([string](Get-GHWValue $NextAction 'kernel_state' 'UNKNOWN')); executed = $false
                        grants_authority = $false; done_approved = $false; merge_authority = $false
                        marker_path = $mk0
                        next_action = $NextAction
                    }
                }
                $stOk = $false
                try { $stOk = [bool](Get-GHWCValue $stOut 'ok' $false) } catch { $stOk = $false }
                $stDsp = $false
                try { $stDsp = [bool](Get-GHWCValue $stOut 'dispatched' $false) } catch { $stDsp = $false }
                $stReason = 'settle-refused'
                try {
                    $sr = ([string](Get-GHWCValue $stOut 'reason' ''))
                    if (-not [string]::IsNullOrWhiteSpace($sr)) { $stReason = $sr }
                }
                catch { }
                return [pscustomobject]@{
                    ok = [bool]$stOk; harness = 'github-wake-controller-v1'
                    verdict = $(if ($stOk) { 'CONTROLLER_PASS' } else { 'CONTROLLER_FAIL' })
                    dispatched = [bool]$stDsp
                    decision = $(if ($stDsp) { 'dispatched' } else { 'not-dispatched' })
                    reason = $stReason
                    controller = ([string](Get-GHWCValue $res 'controller' 'none'))
                    task_id = ([string](Get-GHWCValue $res 'task_id' ''))
                    idempotency_key = ([string](Get-GHWCValue $res 'idempotency_key' ''))
                    kernel_state = ([string](Get-GHWValue $NextAction 'kernel_state' 'UNKNOWN'))
                    executed = [bool]$stDsp
                    grants_authority = $false; done_approved = $false; merge_authority = $false
                    marker_path = $mk0
                    next_action = $NextAction
                }
            }
        }
        if ($null -eq $res) {
            return [pscustomobject]@{
                ok = $false; harness = 'github-wake-controller-v1'; verdict = 'CONTROLLER_FAIL'
                dispatched = $false; decision = 'not-dispatched'; reason = 'internal-error'
                controller = 'none'; task_id = ''; idempotency_key = ''
                kernel_state = 'UNKNOWN'; executed = $false
                grants_authority = $false; done_approved = $false; merge_authority = $false
                next_action = $NextAction
            }
        }
        $okv = $false
        try { $okv = [bool](Get-GHWCValue $res 'ok' $false) } catch { $okv = $false }
        $dsp = $false
        try { $dsp = [bool](Get-GHWCValue $res 'dispatched' $false) } catch { $dsp = $false }
        return [pscustomobject]@{
            ok = [bool]$okv; harness = 'github-wake-controller-v1'
            verdict = $(if ($okv) { 'CONTROLLER_PASS' } else { 'CONTROLLER_FAIL' })
            dispatched = [bool]$dsp
            decision = ([string](Get-GHWCValue $res 'decision' 'not-dispatched'))
            reason = ([string](Get-GHWCValue $res 'reason' 'internal-error'))
            controller = ([string](Get-GHWCValue $res 'controller' 'none'))
            task_id = ([string](Get-GHWCValue $res 'task_id' ''))
            idempotency_key = ([string](Get-GHWCValue $res 'idempotency_key' ''))
            kernel_state = ([string](Get-GHWValue $NextAction 'kernel_state' 'UNKNOWN'))
            executed = [bool]$dsp
            grants_authority = $false; done_approved = $false; merge_authority = $false
            marker_path = ([string](Get-GHWCValue $res 'marker_path' ''))
            next_action = $NextAction
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $false; harness = 'github-wake-controller-v1'; verdict = 'CONTROLLER_FAIL'
            dispatched = $false; decision = 'not-dispatched'; reason = 'internal-error'
            controller = 'none'; task_id = ''; idempotency_key = ''
            kernel_state = 'UNKNOWN'; executed = $false
            grants_authority = $false; done_approved = $false; merge_authority = $false
            next_action = $NextAction
        }
    }
}

if ((-not [string]::IsNullOrWhiteSpace($WakeEnvelopeFile)) -or (-not [string]::IsNullOrWhiteSpace($NextActionFile)) -or (-not [string]::IsNullOrWhiteSpace($NextActionJson))) {
    function Write-GHWCEnvelope {
        param($Envelope)
        try {
            Write-Output (ConvertTo-Json -InputObject $Envelope -Depth 10 -Compress)
        }
        catch {
            Write-Output '{"ok":false,"harness":"github-wake-controller-v1","verdict":"CONTROLLER_FAIL","dispatched":false,"decision":"not-dispatched","reason":"encode-failed","controller":"none","executed":false,"grants_authority":false,"done_approved":false,"merge_authority":false}'
        }
    }
    function New-GHWCErrorEnvelope {
        param([string]$Reason)
        return [pscustomobject]@{
            ok = $false; harness = 'github-wake-controller-v1'; verdict = 'CONTROLLER_FAIL'
            dispatched = $false; decision = 'not-dispatched'; reason = $Reason
            controller = 'none'; task_id = ''; idempotency_key = ''
            kernel_state = 'UNKNOWN'; executed = $false
            grants_authority = $false; done_approved = $false; merge_authority = $false
            next_action = $null
        }
    }
    try {
        $effAction = $null
        if (-not [string]::IsNullOrWhiteSpace($NextActionJson)) {
            try { $effAction = ConvertFrom-Json ([string]$NextActionJson) } catch { $effAction = $null }
            if ($null -eq $effAction) {
                Write-GHWCEnvelope (New-GHWCErrorEnvelope -Reason 'invalid-next-action-json')
                exit 2
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($NextActionFile)) {
            $doc = Read-GHWCJsonFile -Path ([string]$NextActionFile).Trim()
            if ($null -eq $doc) {
                Write-GHWCEnvelope (New-GHWCErrorEnvelope -Reason 'invalid-next-action-file')
                exit 2
            }
            $maybe = Get-GHWCValue $doc 'next_action' $null
            if ($null -ne $maybe) { $effAction = $maybe } else { $effAction = $doc }
        }
        else {
            $env2 = Read-GHWCJsonFile -Path ([string]$WakeEnvelopeFile).Trim()
            if ($null -eq $env2) {
                Write-GHWCEnvelope (New-GHWCErrorEnvelope -Reason 'invalid-wake-envelope')
                exit 2
            }
            $effAction = Get-GHWCValue $env2 'next_action' $null
        }
        if ([string]::IsNullOrWhiteSpace($WaitsDir) -or (-not (Test-Path -LiteralPath ([string]$WaitsDir).Trim() -PathType Container))) {
            Write-GHWCEnvelope (New-GHWCErrorEnvelope -Reason 'invalid-waits-dir')
            exit 2
        }
        if ([string]::IsNullOrWhiteSpace($TasksDir) -or (-not (Test-Path -LiteralPath ([string]$TasksDir).Trim() -PathType Container))) {
            Write-GHWCEnvelope (New-GHWCErrorEnvelope -Reason 'invalid-tasks-dir')
            exit 2
        }
        $result = Invoke-GitHubWakeController -NextAction $effAction `
            -WaitsDir ([string]$WaitsDir).Trim() -TasksDir ([string]$TasksDir).Trim() `
            -GoalStoreDir ([string]$GoalStoreDir).Trim() -CheckpointDir ([string]$CheckpointDir).Trim() `
            -HandoffStateDir ([string]$HandoffStateDir).Trim() -ReceiptDir ([string]$ReceiptDir).Trim() `
            -RepoRoot ([string]$RepoRoot).Trim() -EvidenceStoreDir ([string]$EvidenceStoreDir).Trim() `
            -FlagsPath ([string]$FlagsPath).Trim() `
            -NowUtc ([string]$NowUtc).Trim() -SettleSessionId ([string]$SettleSessionId).Trim() `
            -SettleResultOk $SettleResultOk -SettleResultSummary ([string]$SettleResultSummary).Trim()
        if ($null -eq $result) {
            Write-GHWCEnvelope (New-GHWCErrorEnvelope -Reason 'internal-error')
            exit 1
        }
        $effOut = ([string]$OutFile).Trim()
        if (-not [string]::IsNullOrWhiteSpace($effOut)) {
            try {
                $json = ConvertTo-Json -InputObject $result -Depth 10 -Compress
                [IO.File]::WriteAllText($effOut, $json, (New-Object Text.UTF8Encoding $false))
            }
            catch { }
        }
        Write-GHWCEnvelope -Envelope $result
        if ([bool]$result.ok) { exit 0 } else { exit 1 }
    }
    catch {
        try {
            Write-GHWCEnvelope (New-GHWCErrorEnvelope -Reason 'internal-error')
        }
        catch { }
        exit 1
    }
}
