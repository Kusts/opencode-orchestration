<#!
.SYNOPSIS
    V3 Objective continuation kernel: pure next-move controller (SPEC v0.1.0 Phase 5).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Pure functions,
    fail-closed, PS 5.1 compatible, ASCII-only. Never throws on
    operational paths: every failure returns a COMPLETE envelope with a
    valid stop reason. No network, no process, no registry access, no
    grants, no leases, no flags. Completion authority stays with the
    kernel/verifier; this controller only advises the next internal move.

    TDR-F5-01: Get-OrchestrationNextMove maps one objective snapshot to one
    closed move. Evaluation order (fail-closed):
      (1) terminal_blocker set   -> COMPLETE with it when it is a valid
          Fase 2 stop reason, else COMPLETE POLICY_BLOCKED;
      (2) objective_completed     -> COMPLETE OBJECTIVE_COMPLETED;
      (3) not authorized          -> COMPLETE POLICY_BLOCKED when
          blocker_kind is policy, else COMPLETE HUMAN_AUTHORITY_REQUIRED;
      (4) strategy_change         -> REPLAN;
      (5) context_degraded        -> ROTATE_CONTEXT;
      (6) last_failure recoverable with remaining work -> RETRY;
          last_failure terminal -> COMPLETE
          EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE;
      (7) remaining work with progress possible -> CONTINUE;
      (8) remaining work without progress -> REPLAN (no-progress-replan);
      (9) no remaining work but objective incomplete -> REPLAN
          (incomplete-no-remaining).
    The defensive default is DELEGATE (an internal transition).

    TDR-F5-02: this controller has NO user-return state. A settled Task never
    maps to a user return: only COMPLETE (always carrying a valid Fase 2
    stop reason) ends the Objective; every other move (CONTINUE, RETRY,
    REPLAN, DELEGATE, ROTATE_CONTEXT) is an internal continuation.
    ESCALATE_AGENT and WAIT_EXTERNAL from SPEC section 12 belong to the
    Phase 6 Goal Kernel and are never emitted here.

    Stop-reason validity reuses Test-OrchestrationStopReason from the pure
    OrchestrationAutonomy lib (lazy dot-sourced when present); only when
    that lib is unavailable does the local constant fallback list apply
    (TDR-F5-01: never duplicate the list as primary source).

    Accepted -Status fields (hashtable or PSObject; all optional):
      objective_completed, remaining_work (list), authorized (strict bool),
      blocker_kind ('policy' selects POLICY_BLOCKED), progress_possible,
      strategy_change, context_degraded, last_failure ($null, $false,
      'recoverable' or 'terminal'), terminal_blocker ($null, $false or one
      of the 6 Fase 2 codes), consecutive_no_progress (accepted and
      reserved for Phase 6: local worker/task exhaustion never ends the
      Objective, so it never changes the move by itself).
#>
[CmdletBinding()]
param()

# Fallback only: the primary source is Test-OrchestrationStopReason from
# OrchestrationAutonomy.ps1 (lazy dot-sourced by Test-OCStopReason). This
# constant exists so validation stays fail-closed when that lib file is
# absent; it must keep matching the 6 Fase 2 codes (anti-drift asserted in
# the suite).
$script:OCStopReasonsFallback = @(
    'OBJECTIVE_COMPLETED',
    'HUMAN_AUTHORITY_REQUIRED',
    'EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE',
    'GOAL_HARD_BUDGET_EXHAUSTED',
    'POLICY_BLOCKED',
    'CANCELLED'
)

function Test-OCObject {
    param($Value)
    return (($null -ne $Value) -and (($Value -is [System.Collections.IDictionary]) -or ($Value -is [pscustomobject])))
}

function Get-OCField {
    param($Object, [string]$Name)
    try {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) {
                $v = $Object[$Name]
                if ($null -eq $v) { return $null }
                # Comma wrap: a singleton array must reach the caller as
                # an array (type gate rejects it), never unrolled to scalar.
                return ,$v
            }
            return $null
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) {
            $v = $p.Value
            if ($null -eq $v) { return $null }
            return ,$v
        }
        return $null
    }
    catch { return $null }
}

# True when a collection (array, list, map) shows up where a scalar is
# expected. $null and strings are not collections for this purpose:
# $null keeps legacy absent handling, strings keep legacy gate handling.
function Test-OCNonScalar {
    param($Value)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [System.Collections.IEnumerable]) { return $true }
        return $false
    }
    catch { return $false }
}

function Get-OCGateBool {
    param($Value)
    if ($Value -is [bool]) { return [bool]$Value }
    return $false
}

function Get-OCInt {
    param($Value)
    try {
        # Int64 end to end: never narrows to [int], so [long]::MaxValue
        # stays inert instead of throwing on overflow (SPEC REV-07).
        if ($Value -is [long] -or $Value -is [int] -or $Value -is [int16] -or $Value -is [byte]) { return [long]$Value }
        return [long]0
    }
    catch { return [long]0 }
}

function Get-OCRemainingCount {
    param($Value)
    try {
        if ($null -eq $Value) { return 0 }
        if ($Value -is [string]) {
            if ([string]::IsNullOrWhiteSpace([string]$Value)) { return 0 }
            return 1
        }
        if ($Value -is [System.Collections.IDictionary]) { return 1 }
        $n = [int]@($Value).Count
        if ($n -lt 0) { return 0 }
        return $n
    }
    catch { return 0 }
}

function Test-OCStopReason {
    [CmdletBinding()]
    param([string]$Reason = '')
    try {
        $r = ([string]$Reason).Trim()
        if ([string]::IsNullOrWhiteSpace($r)) { return $false }
        $cmd = Get-Command Test-OrchestrationStopReason -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            $autoLib = Join-Path $PSScriptRoot 'OrchestrationAutonomy.ps1'
            if (Test-Path -LiteralPath $autoLib) {
                try { . $autoLib } catch { }
                $cmd = Get-Command Test-OrchestrationStopReason -ErrorAction SilentlyContinue
            }
        }
        if ($null -ne $cmd) {
            try { return [bool](Test-OrchestrationStopReason -Reason $r) } catch { }
        }
        foreach ($known in @($script:OCStopReasonsFallback)) {
            if ($r -ieq $known) { return $true }
        }
        return $false
    }
    catch { return $false }
}

function Test-OrchestrationObjectiveStatus {
    <#
    .SYNOPSIS
        Presence/shape gate for the additive dispatch hook (TDR-F5-03).
    .DESCRIPTION
        Returns $true only when -Status is a present objective snapshot
        object (hashtable or PSObject). Semantic validity (unknown enums,
        contradictory flags) is resolved fail-closed inside
        Get-OrchestrationNextMove itself, so the hook only needs this
        presence gate to keep absent/invalid input byte-identical.
        Never throws.
    #>
    [CmdletBinding()]
    param($Status = $null)
    try {
        if (-not (Test-OCObject $Status)) { return $false }
        return $true
    }
    catch { return $false }
}

function New-OCCandidateMove {
    [CmdletBinding()]
    param(
        [string]$Move = '',
        [string]$Reason = '',
        [string]$StopReason = '',
        [int]$RemainingCount = 0
    )
    try {
        $m = ([string]$Move).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($m)) { $m = 'DELEGATE' }
        $r = ([string]$Reason).Trim()
        if ([string]::IsNullOrWhiteSpace($r)) { $r = 'delegate-continue' }
        $n = [int]$RemainingCount
        if ($n -lt 0) { $n = 0 }
        if ($m -ceq 'COMPLETE') {
            $s = ([string]$StopReason).Trim().ToUpperInvariant()
            if (-not (Test-OCStopReason -Reason $s)) { $s = 'POLICY_BLOCKED' }
            return [PSCustomObject][ordered]@{
                move            = 'COMPLETE'
                reason          = $r
                stop_reason     = $s
                remaining_count = $n
            }
        }
        return [PSCustomObject][ordered]@{
            move            = $m
            reason          = $r
            remaining_count = $n
        }
    }
    catch {
        return [PSCustomObject][ordered]@{
            move            = 'COMPLETE'
            reason          = 'invalid-status'
            stop_reason     = 'POLICY_BLOCKED'
            remaining_count = 0
        }
    }
}

function Get-OrchestrationNextMove {
    <#
    .SYNOPSIS
        Pure next-move controller (TDR-F5-01, TDR-F5-02).
    .DESCRIPTION
        Maps one objective snapshot to one closed move envelope:
        move, reason, remaining_count, plus stop_reason only on COMPLETE.
        COMPLETE always carries a valid Fase 2 stop reason; no other move
        carries one. Never throws, never returns $null, never emits a
        user-return state. Never throws.
    #>
    [CmdletBinding()]
    param($Status = $null)
    try {
        if (-not (Test-OCObject $Status)) {
            return (New-OCCandidateMove -Move 'COMPLETE' -Reason 'invalid-status' -StopReason 'POLICY_BLOCKED' -RemainingCount 0)
        }
        $rawCompleted = Get-OCField $Status 'objective_completed'
        $rawAuthorized = Get-OCField $Status 'authorized'
        $rawStrategy = Get-OCField $Status 'strategy_change'
        $rawDegraded = Get-OCField $Status 'context_degraded'
        $rawProgress = Get-OCField $Status 'progress_possible'
        $rawRemaining = Get-OCField $Status 'remaining_work'
        $completed = Get-OCGateBool $rawCompleted
        $authorized = Get-OCGateBool $rawAuthorized
        $blockerKind = ([string](Get-OCField $Status 'blocker_kind')).Trim()
        $strategy = Get-OCGateBool $rawStrategy
        $degraded = Get-OCGateBool $rawDegraded
        $progress = Get-OCGateBool $rawProgress
        $remaining = Get-OCRemainingCount $rawRemaining
        # Reserved for Phase 6: read so the contract is explicit, but local
        # exhaustion never ends the Objective by itself (SPEC REV-07).
        $null = Get-OCInt (Get-OCField $Status 'consecutive_no_progress')

        $rawFailure = Get-OCField $Status 'last_failure'
        $failure = ''
        $failureInvalid = $false
        if (($null -ne $rawFailure) -and (($rawFailure -is [bool]) -and ([bool]$rawFailure))) {
            $failureInvalid = $true
        }
        elseif (($null -ne $rawFailure) -and (-not ($rawFailure -is [bool]))) {
            $fs = ([string]$rawFailure).Trim().ToLowerInvariant()
            if (($fs -eq '') -or ($fs -eq 'none') -or ($fs -eq 'null')) { $failure = '' }
            elseif ($fs -eq 'recoverable') { $failure = 'recoverable' }
            elseif ($fs -eq 'terminal') { $failure = 'terminal' }
            else { $failureInvalid = $true }
        }

        $rawBlocker = Get-OCField $Status 'terminal_blocker'
        $blocker = ''
        if (($null -ne $rawBlocker) -and (-not (($rawBlocker -is [bool]) -and (-not [bool]$rawBlocker)))) {
            $blocker = ([string]$rawBlocker).Trim()
        }

        # Collection where a scalar bool is expected, or a string where the
        # remaining-work list is expected: fail closed on the same
        # COMPLETE/POLICY_BLOCKED route as the other invalid inputs above
        # (no new verdict, only a diagnostic reason). last_failure and
        # terminal_blocker are type-gated here too, before any string-cast
        # use: ([string]@('x')) would otherwise coerce to a valid scalar.
        $typeInvalid = (Test-OCNonScalar $rawCompleted) -or (Test-OCNonScalar $rawAuthorized) -or (Test-OCNonScalar $rawStrategy) -or (Test-OCNonScalar $rawDegraded) -or (Test-OCNonScalar $rawProgress) -or (Test-OCNonScalar $rawFailure) -or (Test-OCNonScalar $rawBlocker)
        $remainingInvalid = (($null -ne $rawRemaining) -and ($rawRemaining -is [string]))
        if ($typeInvalid -or $remainingInvalid) {
            return (New-OCCandidateMove -Move 'COMPLETE' -Reason 'invalid-status-type' -StopReason 'POLICY_BLOCKED' -RemainingCount $remaining)
        }
        if ($failureInvalid) {
            return (New-OCCandidateMove -Move 'COMPLETE' -Reason 'invalid-status-last-failure' -StopReason 'POLICY_BLOCKED' -RemainingCount $remaining)
        }
        # (1) terminal blocker wins over everything, including completion.
        if ($blocker -ne '') {
            if (Test-OCStopReason -Reason $blocker) {
                return (New-OCCandidateMove -Move 'COMPLETE' -Reason 'terminal-blocker' -StopReason $blocker -RemainingCount $remaining)
            }
            return (New-OCCandidateMove -Move 'COMPLETE' -Reason 'invalid-terminal-blocker' -StopReason 'POLICY_BLOCKED' -RemainingCount $remaining)
        }
        # (2) objective satisfied.
        if ($completed) {
            return (New-OCCandidateMove -Move 'COMPLETE' -Reason 'objective-completed' -StopReason 'OBJECTIVE_COMPLETED' -RemainingCount $remaining)
        }
        # (3) outside the authorization envelope: stop, never continue blind.
        if (-not $authorized) {
            if ($blockerKind -ieq 'policy') {
                return (New-OCCandidateMove -Move 'COMPLETE' -Reason 'unauthorized-policy' -StopReason 'POLICY_BLOCKED' -RemainingCount $remaining)
            }
            return (New-OCCandidateMove -Move 'COMPLETE' -Reason 'unauthorized-authority' -StopReason 'HUMAN_AUTHORITY_REQUIRED' -RemainingCount $remaining)
        }
        # (4) strategy change required.
        if ($strategy) {
            return (New-OCCandidateMove -Move 'REPLAN' -Reason 'strategy-change' -RemainingCount $remaining)
        }
        # (5) degraded context: rotate, do not stop.
        if ($degraded) {
            return (New-OCCandidateMove -Move 'ROTATE_CONTEXT' -Reason 'context-degraded' -RemainingCount $remaining)
        }
        # (6) failure handling: retry recoverable work, stop only on terminal.
        if (($failure -eq 'recoverable') -and ($remaining -gt 0)) {
            return (New-OCCandidateMove -Move 'RETRY' -Reason 'recoverable-failure-retry' -RemainingCount $remaining)
        }
        if ($failure -eq 'terminal') {
            return (New-OCCandidateMove -Move 'COMPLETE' -Reason 'terminal-failure' -StopReason 'EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE' -RemainingCount $remaining)
        }
        # (7) useful authorized work with a possible path: continue.
        if (($remaining -gt 0) -and ($progress)) {
            return (New-OCCandidateMove -Move 'CONTINUE' -Reason 'progress-continue' -RemainingCount $remaining)
        }
        # (8) remaining work but no possible progress: replan, never stall.
        if ($remaining -gt 0) {
            return (New-OCCandidateMove -Move 'REPLAN' -Reason 'no-progress-replan' -RemainingCount $remaining)
        }
        # (9) nothing remaining yet the objective is incomplete: replan.
        if ($remaining -eq 0) {
            return (New-OCCandidateMove -Move 'REPLAN' -Reason 'incomplete-no-remaining' -RemainingCount $remaining)
        }
        # Defensive default (unreachable in normal operation): an internal
        # transition, never a user return.
        return (New-OCCandidateMove -Move 'DELEGATE' -Reason 'delegate-continue' -RemainingCount $remaining)
    }
    catch {
        return (New-OCCandidateMove -Move 'COMPLETE' -Reason 'invalid-status' -StopReason 'POLICY_BLOCKED' -RemainingCount 0)
    }
}
