<#!
.SYNOPSIS
    PR-3 Goal Promotion Wiring: idempotent auto-promotion + lifecycle + resume
    over the restricted executor (CORRECTIVE-PLAN Fase 3, opcao B).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Fail-closed, PS 5.1
    compatible, ASCII-only. Never throws on operational paths: every
    failure returns an object with ok=$false and a machine-readable reason.
    No network, no process spawn, no kill, no secret values, no flags read
    or written, no DONE and no verified_pass ever issued here
    (grants_authority=$false and done_approved=$false on every envelope).

    The wiring CONNECTS GoalPromotion (score-only) / GoalKernel (CRUD+CAS)
    / GoalCheckpoint (save/load) / ObjectiveRuntime (restricted executor)
    and NEVER duplicates Planner reasoning: it never synthesizes content,
    never issues productive effects, and never dispatches by itself.

    Auto-promotion: Test-OrchestrationGoalPromotion scores the signals;
    below threshold the shape stays 'task' and no Goal is created. On
    promote, the goal_id is deterministic ('gp-' + 16 hex of SHA256 over
    the canonical promotion key objective+criteria), so retry / recovery /
    repeated events map to the SAME goal_id: a pre-creation read returns
    the existing Goal as duplicate=$true instead of creating a second
    record (the kernel ALSO rejects a canonical collision).

    Lifecycle: Goals are born DRAFT, activated to ACTIVE, and carry one
    derived work item per phase ('<goal_id>:phase-<n>'). Transitions use
    Set-OrchestrationGoalState + Save (kernel table is the authority).
    Terminal states (COMPLETED EXHAUSTED CANCELLED) prohibit new dispatch;
    reconcile/settlement of a PRIOR effect on a terminal Goal stays
    allowed (executor D4), and this wiring never dispatches after terminal.

    Resume (contract section 5 order): reopen -> revalidate (identity +
    state + daily ownership lease at the live revision) -> reconcile
    pending intents via the executor -> verify effects (goal re-read,
    revision unchanged) -> restore minimum (atomic checkpoint + resume
    preconditions check) -> continue the non-concluded work. A missing
    Goal/session is NOT a failure (resumed=$false with a
    session-missing-not-failure reason, ok=$true).

    D1 (HOLD ENFORCED by construction, GoalKernel gate pending):
    productive acquisition / real dispatch stay HOLD. Effect seams
    (ReconcileImpl / SettleImpl) are TEST-ONLY declared: they are invoked
    ONLY when the caller passes the explicit -TestCallback switch
    (harness only). Without -TestCallback the wiring returns
    hold-productive-disabled:test-callback-absent and no seam is ever
    invoked (spy 0 calls by construction).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    foreach ($GPWLibName in @('OrchestrationGoalPromotion.ps1', 'OrchestrationGoalKernel.ps1', 'OrchestrationGoalCheckpoint.ps1', 'OrchestrationObjectiveRuntime.ps1')) {
        try {
            $GPWLibPath = Join-Path $PSScriptRoot $GPWLibName
            if (Test-Path -LiteralPath $GPWLibPath -PathType Leaf) { . $GPWLibPath }
        }
        catch { }
    }
}
catch { }

function Get-OrchestrationGoalPromotionWiringVersion {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        schema_version = 1
        contract       = 'UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-OBJECTIVE-RUNTIME-CONTRACT'
        phase          = 'PR-3'
    }
}

function Get-GPWFieldValue {
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

function Get-GPWGoalId {
    [CmdletBinding()]
    param([string]$Objective = '', [string[]]$Criteria = @())
    try {
        $obj = ([string]$Objective).Trim()
        if ([string]::IsNullOrWhiteSpace($obj)) { return '' }
        $parts = New-Object System.Collections.ArrayList
        [void]$parts.Add($obj)
        foreach ($c in @($Criteria)) {
            if (($null -ne $c) -and ($c -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$c))) {
                [void]$parts.Add(([string]$c).Trim())
            }
        }
        $canon = ([string[]]$parts.ToArray() -join "`0")
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($canon)
            $h = $sha.ComputeHash($bytes)
            $hex = ([BitConverter]::ToString($h)).Replace('-', '').ToLowerInvariant()
            return ('gp-' + $hex.Substring(0, 16))
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function Import-GPWLibFile {
    param([string]$Name)
    try {
        $p = Join-Path $PSScriptRoot ([string]$Name)
        if (Test-Path -LiteralPath $p -PathType Leaf) { . $p }
    }
    catch { }
}

function New-GPWNoAuthorityEnvelope {
    param([string]$Reason)
    try {
        return [pscustomobject]@{
            ok               = $false
            reason           = [string]$Reason
            grants_authority = $false
            done_approved    = $false
            verified_pass    = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ok               = $false
            reason           = 'internal-error'
            grants_authority = $false
            done_approved    = $false
            verified_pass    = $false
        }
    }
}

function Invoke-OrchestrationGoalAutoPromotion {
    [CmdletBinding()]
    param(
        $Signals = $null,
        [string]$Objective = '',
        [string[]]$Criteria = @(),
        [string[]]$VerificationSurfaces = @(),
        [long]$TotalPhases = 0,
        [string]$GoalStoreDir = ''
    )
    try {
        Import-GPWLibFile 'OrchestrationGoalPromotion.ps1'
        Import-GPWLibFile 'OrchestrationGoalKernel.ps1'
        $scoreCmd = Get-Command Test-OrchestrationGoalPromotion -ErrorAction SilentlyContinue
        if ($null -eq $scoreCmd) {
            $e = New-GPWNoAuthorityEnvelope 'promotion-scoring-unavailable'
            return $e
        }
        $scored = $null
        try { $scored = Test-OrchestrationGoalPromotion -Signals $Signals }
        catch { $scored = $null }
        if ($null -eq $scored) {
            $e = New-GPWNoAuthorityEnvelope 'promotion-scoring-unavailable'
            return $e
        }
        $promote = $false
        $score = [long]0
        $shape = 'task'
        try { $promote = [bool](Get-GPWFieldValue $scored 'promote' $false) } catch { $promote = $false }
        try { $score = [long](Get-GPWFieldValue $scored 'score' 0) } catch { $score = 0 }
        try { $shape = [string](Get-GPWFieldValue $scored 'shape' 'task') } catch { $shape = 'task' }
        if (-not $promote) {
            return [pscustomobject]@{
                ok = $true; reason = 'below-threshold-task'; promoted = $false; duplicate = $false
                goal_id = ''; revision = [long]0; shape = 'task'; score = $score
                dispatched = $false; grants_authority = $false; done_approved = $false; verified_pass = $false
            }
        }
        $obj = ([string]$Objective).Trim()
        if ([string]::IsNullOrWhiteSpace($obj)) {
            $e = New-GPWNoAuthorityEnvelope 'invalid-objective'
            return $e
        }
        $gid = Get-GPWGoalId -Objective $obj -Criteria $Criteria
        if ([string]::IsNullOrWhiteSpace($gid)) {
            $e = New-GPWNoAuthorityEnvelope 'invalid-promotion-key'
            return $e
        }
        $getGoal = Get-Command Get-OrchestrationGoal -ErrorAction SilentlyContinue
        if ($null -eq $getGoal) {
            $e = New-GPWNoAuthorityEnvelope 'goal-kernel-unavailable'
            return $e
        }
        try {
            $existing = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir
            if (($null -ne $existing) -and ([bool](Get-GPWFieldValue $existing 'ok' $false)) -and ($null -ne (Get-GPWFieldValue $existing 'goal' $null))) {
                $live = (Get-GPWFieldValue $existing 'goal' $null)
                $liveRev = [long]0
                try { $liveRev = [long](Get-GPWFieldValue $live 'revision' 0) } catch { $liveRev = 0 }
                return [pscustomobject]@{
                    ok = $true; reason = 'duplicate-promotion-same-goal'; promoted = $true; duplicate = $true
                    goal_id = $gid; revision = $liveRev; shape = 'persistent-goal'; score = $score
                    dispatched = $false; grants_authority = $false; done_approved = $false; verified_pass = $false
                }
            }
        }
        catch { }
        $ph = [long]$TotalPhases
        if ($ph -lt 1) {
            try { $ph = [long](Get-GPWFieldValue $Signals 'phase_count' 0) } catch { $ph = 0 }
            if ($ph -lt 0) { $ph = 0 }
        }
        if ($ph -lt 1) { $ph = 1 }
        if ($ph -gt 32) { $ph = 32 }
        $fresh = $null
        try {
            $fresh = New-OrchestrationGoal -GoalId $gid -Objective $obj -Criteria $Criteria -VerificationSurfaces $VerificationSurfaces -TotalPhases $ph -StoreDir $GoalStoreDir
        }
        catch { $fresh = $null }
        if (($null -eq $fresh) -or (-not [bool](Get-GPWFieldValue $fresh 'ok' $false))) {
            $why = 'goal-create-failed'
            try { if (($null -ne $fresh) -and (-not [string]::IsNullOrWhiteSpace([string]$fresh.reason))) { $why = [string]$fresh.reason } } catch { }
            if ($why -ceq 'duplicate-goal-id') {
                try {
                    $retry = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir
                    if (($null -ne $retry) -and ([bool](Get-GPWFieldValue $retry 'ok' $false))) {
                        $liveRev = [long]0
                        try { $liveRev = [long](Get-GPWFieldValue (Get-GPWFieldValue $retry 'goal' $null) 'revision' 0) } catch { $liveRev = 0 }
                        return [pscustomobject]@{
                            ok = $true; reason = 'duplicate-promotion-same-goal'; promoted = $true; duplicate = $true
                            goal_id = $gid; revision = $liveRev; shape = 'persistent-goal'; score = $score
                            dispatched = $false; grants_authority = $false; done_approved = $false; verified_pass = $false
                        }
                    }
                }
                catch { }
            }
            $e = New-GPWNoAuthorityEnvelope $why
            return $e
        }
        $working = (Get-GPWFieldValue $fresh 'goal' $null)
        $step = Set-OrchestrationGoalState -Goal $working -ToState 'ACTIVE'
        if (($null -eq $step) -or (-not [bool](Get-GPWFieldValue $step 'ok' $false))) {
            $e = New-GPWNoAuthorityEnvelope 'goal-activate-failed'
            return $e
        }
        $working = (Get-GPWFieldValue $step 'goal' $null)
        for ($i = 1; $i -le $ph; $i++) {
            $wid = ($gid + ':phase-' + [string]$i)
            $added = Add-OrchestrationGoalTask -Goal $working -TaskId $wid
            if (($null -eq $added) -or (-not [bool](Get-GPWFieldValue $added 'ok' $false))) {
                $e = New-GPWNoAuthorityEnvelope 'goal-work-item-failed'
                return $e
            }
            $working = (Get-GPWFieldValue $added 'goal' $null)
        }
        $saved = Save-OrchestrationGoal -Goal $working -StoreDir $GoalStoreDir
        if (($null -eq $saved) -or (-not [bool](Get-GPWFieldValue $saved 'ok' $false))) {
            $why = 'goal-save-failed'
            try { if (($null -ne $saved) -and (-not [string]::IsNullOrWhiteSpace([string]$saved.reason))) { $why = [string]$saved.reason } } catch { }
            $e = New-GPWNoAuthorityEnvelope $why
            return $e
        }
        return [pscustomobject]@{
            ok = $true; reason = ''; promoted = $true; duplicate = $false
            goal_id = $gid; revision = [long]$saved.revision; shape = 'persistent-goal'; score = $score
            dispatched = $false; grants_authority = $false; done_approved = $false; verified_pass = $false
        }
    }
    catch {
        $e = New-GPWNoAuthorityEnvelope 'internal-error'
        return $e
    }
}

function Test-OrchestrationGoalDispatchAllowed {
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$StoreDir = '')
    try {
        Import-GPWLibFile 'OrchestrationGoalKernel.ps1'
        $gid = ([string]$GoalId).Trim()
        if ([string]::IsNullOrWhiteSpace($gid)) {
            return [pscustomobject]@{ allowed = $false; reason = 'invalid-goal-id'; state = '' }
        }
        $slot = $null
        try { $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $StoreDir }
        catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-GPWFieldValue $slot 'ok' $false))) {
            $why = 'goal-not-found'
            try { if (($null -ne $slot) -and (-not [string]::IsNullOrWhiteSpace([string]$slot.reason))) { $why = [string]$slot.reason } } catch { }
            return [pscustomobject]@{ allowed = $false; reason = $why; state = '' }
        }
        $goal = (Get-GPWFieldValue $slot 'goal' $null)
        $state = ([string](Get-GPWFieldValue $goal 'state' '')).Trim().ToUpperInvariant()
        if ((@('COMPLETED', 'EXHAUSTED', 'CANCELLED') -ccontains $state)) {
            return [pscustomobject]@{ allowed = $false; reason = 'terminal-goal-no-dispatch'; state = $state }
        }
        if (($state -ceq 'ACTIVE') -or ($state -ceq 'BUDGET_LIMITED')) {
            return [pscustomobject]@{ allowed = $true; reason = ''; state = $state }
        }
        return [pscustomobject]@{ allowed = $false; reason = 'goal-not-active'; state = $state }
    }
    catch {
        return [pscustomobject]@{ allowed = $false; reason = 'internal-error'; state = '' }
    }
}

function Move-OrchestrationGoalLifecycle {
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$ToState = '', [string]$StoreDir = '')
    try {
        Import-GPWLibFile 'OrchestrationGoalKernel.ps1'
        $gid = ([string]$GoalId).Trim()
        $to = ([string]$ToState).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($gid)) {
            $e = New-GPWNoAuthorityEnvelope 'invalid-goal-id'
            return $e
        }
        $slot = $null
        try { $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $StoreDir }
        catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-GPWFieldValue $slot 'ok' $false))) {
            $why = 'goal-not-found'
            try { if (($null -ne $slot) -and (-not [string]::IsNullOrWhiteSpace([string]$slot.reason))) { $why = [string]$slot.reason } } catch { }
            $e = New-GPWNoAuthorityEnvelope $why
            return $e
        }
        $moved = Set-OrchestrationGoalState -Goal (Get-GPWFieldValue $slot 'goal' $null) -ToState $to
        if (($null -eq $moved) -or (-not [bool](Get-GPWFieldValue $moved 'ok' $false))) {
            $why = 'illegal-transition'
            try { if (($null -ne $moved) -and (-not [string]::IsNullOrWhiteSpace([string]$moved.reason))) { $why = [string]$moved.reason } } catch { }
            $e = New-GPWNoAuthorityEnvelope $why
            return $e
        }
        $saved = Save-OrchestrationGoal -Goal (Get-GPWFieldValue $moved 'goal' $null) -StoreDir $StoreDir
        if (($null -eq $saved) -or (-not [bool](Get-GPWFieldValue $saved 'ok' $false))) {
            $why = 'goal-save-failed'
            try { if (($null -ne $saved) -and (-not [string]::IsNullOrWhiteSpace([string]$saved.reason))) { $why = [string]$saved.reason } } catch { }
            $e = New-GPWNoAuthorityEnvelope $why
            return $e
        }
        return [pscustomobject]@{
            ok = $true; reason = ''; goal_id = $gid; state = $to; revision = [long]$saved.revision
            dispatched = $false; grants_authority = $false; done_approved = $false; verified_pass = $false
        }
    }
    catch {
        $e = New-GPWNoAuthorityEnvelope 'internal-error'
        return $e
    }
}

function Get-GPWPendingIntentCount {
    # Counts diary intents of this Goal still eligible for reconciliation
    # (intended / dispatched-unknown / dispatched / pending). Mirrors the
    # executor scan (hashed file names, canonical goal match); never throws.
    param([string]$GoalId = '', [string]$DispatchStoreDir = '')
    try {
        $gid = ([string]$GoalId).Trim()
        $dir = ([string]$DispatchStoreDir).Trim()
        if ([string]::IsNullOrWhiteSpace($gid) -or [string]::IsNullOrWhiteSpace($dir)) { return [long]-1 }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return [long]0 }
        $canon = $gid.ToLowerInvariant()
        $n = [long]0
        try { $files = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.intent.json' -ErrorAction Stop) }
        catch { return [long]-1 }
        foreach ($f in @($files)) {
            try { $raw = ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)) }
            catch { continue }
            if ($null -eq $raw) { continue }
            $rg = ''
            $st = ''
            try {
                if ($raw -is [System.Collections.IDictionary]) {
                    if ($raw.Contains('goal_id')) { $rg = [string]$raw['goal_id'] }
                    if ($raw.Contains('state')) { $st = ([string]$raw['state']).Trim().ToLowerInvariant() }
                }
                else {
                    $pg = $raw.PSObject.Properties['goal_id']
                    if ($null -ne $pg) { $rg = [string]$pg.Value }
                    $ps = $raw.PSObject.Properties['state']
                    if ($null -ne $ps) { $st = ([string]$ps.Value).Trim().ToLowerInvariant() }
                }
            }
            catch { continue }
            if ([string]::IsNullOrWhiteSpace($rg)) { continue }
            if ($rg.ToLowerInvariant() -cne $canon) { continue }
            if (@('intended', 'dispatched-unknown', 'dispatched', 'pending') -ccontains $st) { $n++ }
        }
        return $n
    }
    catch { return [long]-1 }
}

function Resume-OrchestrationGoalSession {
    # Contract section 5 order: reopen -> revalidate (identity + state +
    # daily ownership lease at the live revision) -> reconcile pending
    # intents via the executor -> verify effects (goal re-read, revision
    # unchanged) -> restore minimum (atomic checkpoint + resume
    # preconditions check) -> continue the non-concluded work.
    # F1: ReconcileImpl / SettleImpl are TEST-ONLY seams declared by the
    # explicit -TestCallback switch. Without it they are never invoked
    # (held by construction, spy 0); a missing Goal/session is never a
    # failure (ok=$true, resumed=$false, session-missing reason).
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$GoalStoreDir = '',
        [string]$DispatchStoreDir = '',
        [string]$CheckpointStoreDir = '',
        [string]$OwnerId = '',
        [long]$Generation = 0,
        [string]$User = '',
        [string]$Project = '',
        [string]$Runtime = '',
        [string]$Grants = '',
        $ReconcileImpl = $null,
        $SettleImpl = $null,
        $SettleProof = $null,
        [int]$LockTimeoutMs = 500,
        [switch]$TestCallback
    )
    try {
        Import-GPWLibFile 'OrchestrationGoalKernel.ps1'
        Import-GPWLibFile 'OrchestrationGoalCheckpoint.ps1'
        Import-GPWLibFile 'OrchestrationObjectiveRuntime.ps1'
        $gid = ([string]$GoalId).Trim()
        if ([string]::IsNullOrWhiteSpace($gid)) {
            $e = New-GPWNoAuthorityEnvelope 'invalid-goal-id'
            return $e
        }
        $slot = $null
        try { $slot = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir }
        catch { $slot = $null }
        if (($null -eq $slot) -or (-not [bool](Get-GPWFieldValue $slot 'ok' $false))) {
            $why = 'goal-not-found'
            try { if (($null -ne $slot) -and (-not [string]::IsNullOrWhiteSpace([string]$slot.reason))) { $why = [string]$slot.reason } } catch { }
            if (($why -ceq 'goal-not-found') -or ($why -ceq 'invalid-store-dir')) {
                return [pscustomobject]@{
                    ok = $true; reason = 'goal-not-found-session-missing-not-failure'; resumed = $false
                    session_missing = $true; goal_id = $gid; state = ''; revision = [long]0
                    reconciled = [long]0; settled = [long]0; checkpoint_id = ''; restored = $false
                    dispatched = $false; decision = 'session-missing'; stop_reason = ''
                    grants_authority = $false; done_approved = $false; verified_pass = $false
                }
            }
            $e = New-GPWNoAuthorityEnvelope $why
            return $e
        }
        $goal = (Get-GPWFieldValue $slot 'goal' $null)
        $state = ([string](Get-GPWFieldValue $goal 'state' '')).Trim().ToUpperInvariant()
        $liveRev = [long]0
        try { $liveRev = [long](Get-GPWFieldValue $goal 'revision' 0) } catch { $liveRev = 0 }
        if ($liveRev -lt 1) {
            $e = New-GPWNoAuthorityEnvelope 'goal-read-failed'
            return $e
        }
        $terminal = ((@('COMPLETED', 'EXHAUSTED', 'CANCELLED') -ccontains $state))
        $own = $null
        try {
            $own = Acquire-OrchestrationObjectiveOwnership -GoalId $gid -OwnerId $OwnerId -Generation $Generation -ExpectedRevision $liveRev -StoreDir $DispatchStoreDir -LockTimeoutMs $LockTimeoutMs -GoalStoreDir $GoalStoreDir
        }
        catch { $own = $null }
        if (($null -eq $own) -or (-not [bool](Get-GPWFieldValue $own 'ok' $false))) {
            $why = 'owner-rejected'
            try { if (($null -ne $own) -and (-not [string]::IsNullOrWhiteSpace([string]$own.reason))) { $why = ('owner-' + [string]$own.reason) } } catch { }
            $e = New-GPWNoAuthorityEnvelope $why
            return $e
        }
        if (-not [bool]$TestCallback) {
            $decision = 'continue'
            $stop = ''
            if ($terminal) {
                $decision = 'terminal'
                if ($state -ceq 'COMPLETED') { $stop = 'OBJECTIVE_COMPLETED' }
                elseif ($state -ceq 'EXHAUSTED') { $stop = 'GOAL_HARD_BUDGET_EXHAUSTED' }
                else { $stop = 'CANCELLED' }
            }
            return [pscustomobject]@{
                ok = $true; reason = 'hold-productive-disabled:test-callback-absent'; resumed = $true
                session_missing = $false; goal_id = $gid; state = $state; revision = $liveRev
                reconciled = [long]0; settled = [long]0; checkpoint_id = ''; restored = $false
                dispatched = $false; decision = $decision; stop_reason = $stop
                grants_authority = $false; done_approved = $false; verified_pass = $false
            }
        }
        $reconciled = [long]0
        $settled = [long]0
        $pending = Get-GPWPendingIntentCount -GoalId $gid -DispatchStoreDir $DispatchStoreDir
        if ($pending -lt 0) {
            $e = New-GPWNoAuthorityEnvelope 'dispatch-store-unreadable'
            return $e
        }
        if ($pending -gt 0) {
        $rec = $null
        try {
            $rec = Invoke-OrchestrationObjectiveReconcile -GoalId $gid -OwnerId $OwnerId -Generation $Generation -ExpectedRevision $liveRev -GoalStoreDir $GoalStoreDir -DispatchStoreDir $DispatchStoreDir -ReconcileImpl $ReconcileImpl -SettleImpl $SettleImpl -LockTimeoutMs $LockTimeoutMs -User $User -Project $Project -Runtime $Runtime -Grants $Grants -SettleProof $SettleProof -TestCallback
        }
        catch { $rec = $null }
        if ($null -eq $rec) {
            $e = New-GPWNoAuthorityEnvelope 'reconcile-failed'
            return $e
        }
        if (-not [bool](Get-GPWFieldValue $rec 'ok' $false)) {
            $why = 'reconcile-failed'
            try { if (-not [string]::IsNullOrWhiteSpace([string]$rec.reason)) { $why = ('reconcile-' + [string]$rec.reason) } } catch { }
            $e = New-GPWNoAuthorityEnvelope $why
            return $e
        }
        try { $reconciled = [long](Get-GPWFieldValue $rec 'reconciled' 0) } catch { $reconciled = 0 }
        try { $settled = [long](Get-GPWFieldValue $rec 'settled' 0) } catch { $settled = 0 }
        }
        $reGoal = $null
        try { $reGoal = Get-OrchestrationGoal -GoalId $gid -StoreDir $GoalStoreDir }
        catch { $reGoal = $null }
        if (($null -eq $reGoal) -or (-not [bool](Get-GPWFieldValue $reGoal 'ok' $false))) {
            $e = New-GPWNoAuthorityEnvelope 'goal-read-failed-no-advance'
            return $e
        }
        $nowGoal = (Get-GPWFieldValue $reGoal 'goal' $null)
        $nowRev = [long]0
        try { $nowRev = [long](Get-GPWFieldValue $nowGoal 'revision' 0) } catch { $nowRev = 0 }
        if ($nowRev -ne $liveRev) {
            $e = New-GPWNoAuthorityEnvelope 'revision-changed-no-advance'
            return $e
        }
        $ckpt = $null
        try { $ckpt = New-OrchestrationGoalCheckpoint -GoalRecord $nowGoal }
        catch { $ckpt = $null }
        if ($null -eq $ckpt) {
            $e = New-GPWNoAuthorityEnvelope 'checkpoint-failed'
            return $e
        }
        $savedCk = $null
        try { $savedCk = Save-OrchestrationGoalCheckpoint -Checkpoint $ckpt -StoreDir $CheckpointStoreDir }
        catch { $savedCk = $null }
        if (($null -eq $savedCk) -or (-not [bool](Get-GPWFieldValue $savedCk 'ok' $false))) {
            $why = 'checkpoint-save-failed'
            try { if (($null -ne $savedCk) -and (-not [string]::IsNullOrWhiteSpace([string]$savedCk.reason))) { $why = [string]$savedCk.reason } } catch { }
            $e = New-GPWNoAuthorityEnvelope $why
            return $e
        }
        $cid = ''
        try { $cid = [string](Get-GPWFieldValue $savedCk 'checkpoint_id' '') } catch { $cid = '' }
        $plan = $null
        try { $plan = Test-OrchestrationCheckpointResume -Checkpoint $ckpt -GoalStoreDir $GoalStoreDir }
        catch { $plan = $null }
        $restored = $false
        if (($null -ne $plan) -and ([bool](Get-GPWFieldValue $plan 'resumable' $false))) { $restored = $true }
        if (-not $restored) {
            $e = New-GPWNoAuthorityEnvelope 'checkpoint-not-resumable'
            return $e
        }
        $decision = 'continue'
        $stop = ''
        if ($terminal) {
            $decision = 'terminal'
            if ($state -ceq 'COMPLETED') { $stop = 'OBJECTIVE_COMPLETED' }
            elseif ($state -ceq 'EXHAUSTED') { $stop = 'GOAL_HARD_BUDGET_EXHAUSTED' }
            else { $stop = 'CANCELLED' }
        }
        $remaining = 0
        try { $remaining = [long](@(Get-GPWFieldValue $nowGoal 'active_tasks' @())).Count } catch { $remaining = 0 }
        return [pscustomobject]@{
            ok = $true; reason = ''; resumed = $true
            session_missing = $false; goal_id = $gid; state = $state; revision = $nowRev
            reconciled = $reconciled; settled = $settled; checkpoint_id = $cid; restored = $true
            remaining_work_items = $remaining
            dispatched = $false; decision = $decision; stop_reason = $stop
            grants_authority = $false; done_approved = $false; verified_pass = $false
        }
    }
    catch {
        $e = New-GPWNoAuthorityEnvelope 'internal-error'
        return $e
    }
}
