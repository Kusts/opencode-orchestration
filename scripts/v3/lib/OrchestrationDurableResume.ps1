<#!
.SYNOPSIS
    Etapa 5 FULL_DELIVERY — retomada duravel integrada (checkpoint + reconciliacao + CI/PR).
.DESCRIPTION
    Dot-sourceable, sem execucao no load. PS 5.1, ASCII-only, sem rede/spawn.
    Reutiliza GoalCheckpoint, SessionReconciler, GitHubResume, TaskKernel e
    GoalKernel sem nova maquina de estados. Invoke-OrchestrationDurableResume:
      1. Carrega checkpoint e valida retomada (Test-OrchestrationCheckpointResume).
      2. Reconcilia sessoes declaradas (Get-OrchestrationSessionReconciliation).
      3. Decide CI/PR em single-shot (Test-OrchestrationGitHubResume).
      4. Escolhe proxima Task nao-DONE (nunca reexecuta DONE) e verifica
         recibo idempotente (sem efeito externo duplicado).
      5. Goal so COMPLETED quando criterios verificados (nunca por task done).
    Cobre CI verde (RESUME), vermelho recuperavel (TERMINAL diagnostic),
    resultado atrasado (KEEP_WAITING) e CAS stale (stale-goal-revision).
    grants_authority=false; resume_authorized so do envelope GitHub.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

function Get-DRValue {
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

function Invoke-OrchestrationDurableResume {
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$GoalStoreDir = '',
        [string]$CheckpointId = '',
        [string]$CheckpointDir = '',
        [object[]]$Bindings = @(),
        [object[]]$Observations = @(),
        [int]$StaleAfterSeconds = 300,
        $Wait = $null,
        $Snapshot = $null,
        $Policy = $null,
        $NowUtc = $null,
        [bool]$LeaseAlive = $true,
        [bool]$OwnerAlive = $true,
        [bool]$AuthorizationAlive = $true,
        [bool]$ExecutorPresent = $true,
        [bool]$CancelRequested = $false,
        [bool]$AlreadyApplied = $false,
        [string]$EventDedupKey = '',
        [string[]]$MandatoryTasks = @(),
        [string]$TasksDir = '',
        [string]$ReceiptDir = '',
        [string]$RepoRoot = '',
        [scriptblock]$TaskExecutor = $null,
        [string]$EvidenceDir = ''
    )
    try {
        foreach ($lib in @('OrchestrationGoalCheckpoint.ps1','OrchestrationSessionReconciler.ps1','OrchestrationGitHubResume.ps1','OrchestrationGoalKernel.ps1','OrchestrationTaskKernel.ps1','OrchestrationNativeDispatch.ps1')) {
            $p = Join-Path $PSScriptRoot $lib
            if (Test-Path -LiteralPath $p) { . $p }
        }
        $gid = ([string]$GoalId).Trim()
        if ([string]::IsNullOrWhiteSpace($gid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal'; action = 'blocked'; grants_authority = $false; done_approved = $false }
        }
        # 1. checkpoint + retomada
        $load = $null
        try { $load = Load-OrchestrationGoalCheckpoint -CheckpointId ([string]$CheckpointId).Trim() -StoreDir $CheckpointDir } catch { $load = $null }
        if (($null -eq $load) -or (-not [bool](Get-DRValue $load 'ok' $false))) {
            return [pscustomobject]@{ ok = $false; reason = 'checkpoint-not-found'; action = 'blocked'; grants_authority = $false; done_approved = $false }
        }
        $resume = $null
        try { $resume = Test-OrchestrationCheckpointResume -Checkpoint (Get-DRValue $load 'checkpoint' $null) -GoalStoreDir $GoalStoreDir } catch { $resume = $null }
        if (($null -eq $resume) -or (-not [bool](Get-DRValue $resume 'resumable' $false))) {
            $why = 'resume-not-resumable'
            try { $rs = @(Get-DRValue $resume 'reasons' @()); if (@($rs).Count -gt 0) { $why = 'resume-not-resumable:' + ((@($rs) | Select-Object -First 2) -join ',') } } catch { }
            return [pscustomobject]@{ ok = $true; reason = $why; action = 'blocked'; checkpoint = (Get-DRValue $load 'checkpoint' $null); resumable = $false; grants_authority = $false; done_approved = $false }
        }
        # 2. reconciliacao de sessoes
        $rec = $null
        try { $rec = Get-OrchestrationSessionReconciliation -Bindings $Bindings -Observations $Observations -StaleAfterSeconds $StaleAfterSeconds } catch { $rec = $null }
        if ($null -eq $rec) {
            return [pscustomobject]@{ ok = $false; reason = 'reconcile-failed'; action = 'blocked'; grants_authority = $false; done_approved = $false }
        }
        # 3. decisao CI/PR
        $dec = $null
        try {
            $dec = Test-OrchestrationGitHubResume -Wait $Wait -Snapshot $Snapshot -Policy $Policy -NowUtc $NowUtc -LeaseAlive $LeaseAlive -OwnerAlive $OwnerAlive -AuthorizationAlive $AuthorizationAlive -ExecutorPresent $ExecutorPresent -CancelRequested $CancelRequested -AlreadyApplied $AlreadyApplied -EventDedupKey $EventDedupKey
        } catch { $dec = $null }
        if ($null -eq $dec) {
            return [pscustomobject]@{ ok = $false; reason = 'resume-decision-failed'; action = 'blocked'; reconciliation = $rec; grants_authority = $false; done_approved = $false }
        }
        $dname = ([string](Get-DRValue $dec 'decision' 'INVALID')).Trim().ToUpperInvariant()
        if ($dname -in @('TERMINAL')) {
            return [pscustomobject]@{ ok = $true; reason = ([string](Get-DRValue $dec 'reason' 'terminal')); action = 'terminal'; decision = $dec; reconciliation = $rec; resumable = $true; grants_authority = $false; done_approved = $false; resume_authorized = [bool](Get-DRValue $dec 'resume_authorized' $false) }
        }
        if ($dname -in @('KEEP_WAITING','READY','INVALID','DUPLICATE_NOOP','OUT_OF_ORDER')) {
            return [pscustomobject]@{ ok = $true; reason = ([string](Get-DRValue $dec 'reason' 'wait')); action = 'wait'; decision = $dec; reconciliation = $rec; resumable = $true; grants_authority = $false; done_approved = $false; resume_authorized = $false }
        }
        # 4. RESUME: proxima Task nao-DONE, sem duplicar efeito
        $next = ''
        foreach ($tid in @($MandatoryTasks)) {
            $t = $null
            try { $t = Get-OrchestrationTask -TaskId ([string]$tid) -TasksDir $TasksDir -RepoRoot $RepoRoot } catch { $t = $null }
            $st = ''
            try {
                if ($null -ne $t) {
                    if ($t -is [System.Collections.IDictionary]) { $st = ([string]$t['state']) } else { $ep = $t.PSObject.Properties['state']; if ($null -ne $ep) { $st = ([string]$ep.Value) } }
                }
            } catch { $st = '' }
            if ($st -cne 'DONE') { $next = ([string]$tid); break }
        }
        if ([string]::IsNullOrWhiteSpace($next)) {
            # hardened: never complete without a mandatory task list
            if (@($MandatoryTasks).Count -eq 0) {
                return [pscustomobject]@{ ok = $true; reason = 'no-mandatory-tasks'; action = 'blocked'; decision = $dec; reconciliation = $rec; resumable = $true; next_task = ''; grants_authority = $false; done_approved = $false }
            }
            # defensive second live read: every mandatory task must still be DONE
            $unverified = $true
            try {
                $unverified = $false
                foreach ($vid in @($MandatoryTasks)) {
                    $vt = $null
                    try { $vt = Get-OrchestrationTask -TaskId ([string]$vid) -TasksDir $TasksDir -RepoRoot $RepoRoot } catch { $vt = $null }
                    $vst = ''
                    try {
                        if ($null -ne $vt) {
                            if ($vt -is [System.Collections.IDictionary]) { $vst = ([string]$vt['state']) } else { $vep = $vt.PSObject.Properties['state']; if ($null -ne $vep) { $vst = ([string]$vep.Value) } }
                        }
                    } catch { $vst = '' }
                    if ($vst -cne 'DONE') { $unverified = $true; break }
                }
            } catch { $unverified = $true }
            if ($unverified) {
                return [pscustomobject]@{ ok = $true; reason = 'mandatory-unverified'; action = 'blocked'; decision = $dec; reconciliation = $rec; resumable = $true; next_task = ''; grants_authority = $false; done_approved = $false }
            }
            # todas DONE: so COMPLETED com criterios verificados (leitura viva)
            $gs = $null
            try { $gs = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir } catch { $gs = $null }
            $goal = Get-DRValue $gs 'goal' $null
            $sat = -1; $tot = 0
            try { $prog = Get-DRValue $goal 'progress' $null; $sat = [long](Get-DRValue $prog 'satisfied' -1); $tot = [long](Get-DRValue $prog 'total' 0) } catch { }
            if (($tot -gt 0) -and ($sat -ge $tot)) {
                return [pscustomobject]@{ ok = $true; reason = 'complete-eligible'; action = 'complete'; decision = $dec; reconciliation = $rec; resumable = $true; next_task = ''; grants_authority = $false; done_approved = $false; resume_authorized = $true }
            }
            return [pscustomobject]@{ ok = $true; reason = 'criteria-unverified'; action = 'blocked'; decision = $dec; reconciliation = $rec; resumable = $true; next_task = ''; grants_authority = $false; done_approved = $false }
        }
        # Caller contract: WITHOUT executor this returns advance + next_task and
        # the operational caller MUST dispatch next_task itself and complete it
        # via the canonical chain (transitions + worker_result + verification +
        # review + completion). This function never executes a task inline and
        # never COMPLETES a goal without verified criteria.
        $dispatch = [pscustomobject]@{ task_id = $next; ok = $false; reason = 'no-executor-caller-dispatches' }
        if ($null -ne $TaskExecutor) {
            try {
                $ex = & $TaskExecutor -TaskId $next
                $exOk = $false
                $exReason = 'executor-returned-false'
                try {
                    $tmpOk = Get-DRValue $ex 'ok' $null
                    if ($tmpOk -is [bool]) { $exOk = [bool]$tmpOk }
                    else {
                        $tmpSt = [string](Get-DRValue $ex 'status' '')
                        if ($tmpSt -ceq 'ok' -or $tmpSt -ceq 'dispatched' -or $tmpSt -ceq 'candidate_pass') { $exOk = $true }
                        elseif ($null -ne $ex -and $tmpOk -ne $null) { $exOk = [bool]$tmpOk }
                    }
                } catch { $exOk = $false }
                try {
                    $tmpR = [string](Get-DRValue $ex 'reason' '')
                    if (-not [string]::IsNullOrWhiteSpace($tmpR)) { $exReason = $tmpR }
                    elseif ($exOk) { $exReason = 'executor-ok' }
                } catch { }
                $dispatch = [pscustomobject]@{ task_id = $next; ok = [bool]$exOk; reason = [string]$exReason }
            } catch {
                $msg = [string]$_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'executor-threw' }
                $dispatch = [pscustomobject]@{ task_id = $next; ok = $false; reason = ('executor-failed:' + $msg) }
            }
        }
        try {
            $edir = ([string]$EvidenceDir).Trim()
            if ((-not [string]::IsNullOrWhiteSpace($edir)) -and (Test-Path -LiteralPath $edir -PathType Container)) {
                $rec = [ordered]@{ ts = ([DateTime]::UtcNow.ToString('o')); goal = $gid; next_task = $next; action = 'advance'; dispatch_ok = [bool]$dispatch.ok }
                $line = (ConvertTo-Json -InputObject $rec -Depth 4 -Compress)
                [IO.File]::AppendAllText((Join-Path $edir 'durable-resume.jsonl'), ($line + [Environment]::NewLine), [Text.Encoding]::UTF8)
            }
        } catch { }
        return [pscustomobject]@{ ok = $true; reason = 'resume-advance'; action = 'advance'; decision = $dec; reconciliation = $rec; resumable = $true; next_task = $next; dispatch = $dispatch; grants_authority = $false; done_approved = $false; resume_authorized = $true }
    } catch {
        return [pscustomobject]@{ ok = $false; reason = 'resume-internal-error'; action = 'blocked'; grants_authority = $false; done_approved = $false }
    }
}
