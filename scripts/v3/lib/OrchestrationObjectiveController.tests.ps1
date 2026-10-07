[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationObjectiveController.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationAutonomy.ps1')
$passed = 0
function Assert-OCThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function New-OCStatus {
    param([hashtable]$Override = @{})
    $s = @{
        objective_completed      = $false
        remaining_work           = @()
        authorized               = $true
        blocker_kind             = ''
        progress_possible        = $false
        strategy_change          = $false
        context_degraded         = $false
        last_failure             = $null
        terminal_blocker         = $null
        consecutive_no_progress  = 0
    }
    foreach ($k in @($Override.Keys)) { $s[$k] = $Override[$k] }
    return $s
}
# --- R1 terminal blocker (wins over everything, valid or fail-closed).
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ terminal_blocker = 'GOAL_HARD_BUDGET_EXHAUSTED' })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'GOAL_HARD_BUDGET_EXHAUSTED' -and $r.reason -ceq 'terminal-blocker') 'R1 valid blocker completes with itself'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ terminal_blocker = 'CANCELLED'; objective_completed = $true })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'CANCELLED') 'R1 blocker beats completed'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ terminal_blocker = 'TASK_DONE' })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED' -and $r.reason -ceq 'invalid-terminal-blocker') 'R1 invalid blocker fails closed to POLICY_BLOCKED'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ terminal_blocker = 'CI_PASS'; objective_completed = $true })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED') 'R1 invalid blocker beats completed'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ terminal_blocker = 'cancelled' })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'CANCELLED') 'R1 blocker code normalizes to canonical case'
# --- R2 objective completed.
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ objective_completed = $true })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'OBJECTIVE_COMPLETED' -and $r.reason -ceq 'objective-completed') 'R2 completed maps to OBJECTIVE_COMPLETED'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ objective_completed = $true; authorized = $false })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'OBJECTIVE_COMPLETED') 'R2 completed beats unauthorized'
# --- R3 authorization envelope.
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ authorized = $false })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'HUMAN_AUTHORITY_REQUIRED' -and $r.reason -ceq 'unauthorized-authority') 'R3 unauthorized defaults to HUMAN_AUTHORITY_REQUIRED'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ authorized = $false; blocker_kind = 'policy' })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED' -and $r.reason -ceq 'unauthorized-policy') 'R3 policy cause selects POLICY_BLOCKED'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ authorized = $false; strategy_change = $true; remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'HUMAN_AUTHORITY_REQUIRED') 'R3 unauthorized beats strategy change'
# --- R4 strategy change.
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ strategy_change = $true; remaining_work = @('a', 'b'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'REPLAN' -and $r.reason -ceq 'strategy-change' -and $r.remaining_count -eq 2) 'R4 strategy with remaining work replans'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ strategy_change = $true; last_failure = 'recoverable'; remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'REPLAN') 'R4 strategy beats recoverable retry'
# --- R5 degraded context.
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ context_degraded = $true; remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'ROTATE_CONTEXT' -and $r.reason -ceq 'context-degraded') 'R5 degraded context rotates'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ context_degraded = $true; last_failure = 'recoverable'; remaining_work = @('a') })
Assert-OCThat ($r.move -ceq 'ROTATE_CONTEXT') 'R5 rotation beats recoverable retry'
# --- R6 failure handling.
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ last_failure = 'recoverable'; remaining_work = @('a', 'b', 'c'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'RETRY' -and $r.reason -ceq 'recoverable-failure-retry' -and $r.remaining_count -eq 3) 'R6 recoverable with remaining retries'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ last_failure = 'recoverable' })
Assert-OCThat ($r.move -ceq 'REPLAN' -and $r.reason -ceq 'incomplete-no-remaining') 'R6 recoverable without remaining replans'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ last_failure = 'terminal'; remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE') 'R6 terminal with remaining still completes'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ last_failure = 'terminal' })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE') 'R6 terminal without remaining completes'
# --- R7/R8/R9 remaining work and progress.
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ remaining_work = @('a', 'b'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'CONTINUE' -and $r.reason -ceq 'progress-continue' -and $r.remaining_count -eq 2) 'R7 remaining with progress continues'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ remaining_work = @('a', 'b'); progress_possible = $true; consecutive_no_progress = 5 })
Assert-OCThat ($r.move -ceq 'CONTINUE') 'R7 repeated no-progress never ends the objective alone'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ remaining_work = @('a'); progress_possible = $false })
Assert-OCThat ($r.move -ceq 'REPLAN' -and $r.reason -ceq 'no-progress-replan') 'R8 remaining without progress replans'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{})
Assert-OCThat ($r.move -ceq 'REPLAN' -and $r.reason -ceq 'incomplete-no-remaining' -and $r.remaining_count -eq 0) 'R9 empty remaining with incomplete objective replans'
# --- Invalid input fails closed, never throws, never returns null.
$r = Get-OrchestrationNextMove -Status $null
Assert-OCThat (($null -ne $r) -and ($r.move -ceq 'COMPLETE') -and ($r.stop_reason -ceq 'POLICY_BLOCKED') -and ($r.reason -ceq 'invalid-status')) 'INV null status fails closed'
$r = Get-OrchestrationNextMove -Status 'junk'
Assert-OCThat (($null -ne $r) -and ($r.move -ceq 'COMPLETE') -and ($r.stop_reason -ceq 'POLICY_BLOCKED')) 'INV non-object status fails closed'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ last_failure = 'bogus' })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED' -and $r.reason -ceq 'invalid-status-last-failure') 'INV unknown failure class fails closed'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ last_failure = $false; remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'CONTINUE') 'INV explicit false failure reads as no failure'
# --- Output contract: stop_reason only on COMPLETE, always a valid code.
foreach ($stop in @(Get-OrchestrationStopReasons)) {
    Assert-OCThat (Test-OCStopReason -Reason $stop) ("OUT stop validates: $stop")
}
$code = @(Get-OrchestrationStopReasons)
$json = @($code | Sort-Object -Unique)
$onlyCode = @($script:OCStopReasonsFallback | Where-Object { $json -cnotcontains $_ })
$onlyJson = @($json | Where-Object { $script:OCStopReasonsFallback -cnotcontains $_ })
Assert-OCThat ((@($script:OCStopReasonsFallback).Count -eq @($json).Count) -and (@($onlyCode).Count -eq 0) -and (@($onlyJson).Count -eq 0)) 'OUT fallback list matches autonomy codes both directions'
foreach ($mv in @(
    (Get-OrchestrationNextMove -Status (New-OCStatus @{ remaining_work = @('a'); progress_possible = $true })),
    (Get-OrchestrationNextMove -Status (New-OCStatus @{ last_failure = 'recoverable'; remaining_work = @('a') })),
    (Get-OrchestrationNextMove -Status (New-OCStatus @{ strategy_change = $true })),
    (Get-OrchestrationNextMove -Status (New-OCStatus @{ context_degraded = $true }))
)) {
    Assert-OCThat ($null -eq $mv.PSObject.Properties['stop_reason']) ("OUT non-complete carries no stop_reason: $($mv.move)")
}
foreach ($stop in @('OBJECTIVE_COMPLETED', 'HUMAN_AUTHORITY_REQUIRED', 'EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE', 'GOAL_HARD_BUDGET_EXHAUSTED', 'POLICY_BLOCKED', 'CANCELLED')) {
    Assert-OCThat (Test-OrchestrationStopReason -Reason $stop) ("OUT complete stop is valid: $stop")
}
# --- Presence gate for the additive hook.
Assert-OCThat (-not (Test-OrchestrationObjectiveStatus -Status $null)) 'GATE null is absent'
Assert-OCThat (-not (Test-OrchestrationObjectiveStatus -Status 'junk')) 'GATE non-object is absent'
Assert-OCThat (Test-OrchestrationObjectiveStatus -Status (New-OCStatus @{})) 'GATE snapshot object is present'
# --- Additive dispatch hook: byte-identical without status, annotated with it.
. (Join-Path $PSScriptRoot 'OrchestrationDispatchPipeline.ps1')
$hookBundle = [pscustomobject]@{
    completion_gate = [pscustomobject]@{ status = 'ok'; level = 'L1'; required_roles = @('coder'); unknown_required_roles = 0 }
    plan_ref        = [pscustomobject]@{ risk = 'low' }
    generated_at    = '2026-10-07T00:00:00Z'
}
$hookBase = Test-OrchestrationDispatchCompletion $hookBundle @('coder')
Assert-OCThat ($null -eq $hookBase.PSObject.Properties['next_move']) 'HOOK no status leaves no next_move'
$hookDone = Test-OrchestrationDispatchCompletion $hookBundle @('coder') $null (New-OCStatus @{ objective_completed = $true })
Assert-OCThat (($null -ne $hookDone.PSObject.Properties['next_move']) -and ($hookDone.next_move.move -ceq 'COMPLETE') -and ($hookDone.next_move.stop_reason -ceq 'OBJECTIVE_COMPLETED')) 'HOOK completed status annotates next_move'
Assert-OCThat (($hookDone.allowed -eq $hookBase.allowed) -and ($hookDone.reason -ceq $hookBase.reason)) 'HOOK annotation never touches completion authority'
$hookRetry = Test-OrchestrationDispatchCompletion $hookBundle @('coder') $null (New-OCStatus @{ last_failure = 'recoverable'; remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($hookRetry.next_move.move -ceq 'RETRY') 'HOOK retry status annotates RETRY'
$hookInvalid = Test-OrchestrationDispatchCompletion $hookBundle @('coder') $null 'junk'
Assert-OCThat ($null -eq $hookInvalid.PSObject.Properties['next_move']) 'HOOK invalid status stays byte-identical'
$hookJsonBase = ConvertTo-Json -InputObject $hookBase -Depth 12 -Compress
$hookJsonInvalid = ConvertTo-Json -InputObject $hookInvalid -Depth 12 -Compress
$hookJsonNull = ConvertTo-Json -InputObject (Test-OrchestrationDispatchCompletion $hookBundle @('coder') $null $null) -Depth 12 -Compress
Assert-OCThat (($hookJsonInvalid -ceq $hookJsonBase) -and ($hookJsonNull -ceq $hookJsonBase)) 'HOOK absent or invalid status is byte-identical'
# --- FIX review MEDIUM: singleton arrays in scalar fields fail closed; Int64 never overflows.
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ authorized = @($true); remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED') 'FIX singleton array in authorized fails closed, never CONTINUE'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ objective_completed = @($true) })
Assert-OCThat (($r.move -ceq 'COMPLETE') -and ($r.stop_reason -ceq 'POLICY_BLOCKED')) 'FIX singleton array in objective_completed fails closed, never OBJECTIVE_COMPLETED'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ strategy_change = @($true); remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED') 'FIX singleton array in strategy_change fails closed'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ context_degraded = @($true); remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED') 'FIX singleton array in context_degraded fails closed'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ progress_possible = @($true); remaining_work = @('a') })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED') 'FIX singleton array in progress_possible fails closed, never CONTINUE'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ remaining_work = 'abc'; progress_possible = $true })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED') 'FIX string remaining_work fails closed, never CONTINUE'
$r = Get-OrchestrationNextMove -Status ([pscustomobject]@{ objective_completed = $false; remaining_work = @('a'); authorized = @($true); blocker_kind = ''; progress_possible = $true; strategy_change = $false; context_degraded = $false; last_failure = $null; terminal_blocker = $null; consecutive_no_progress = 0 })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED') 'FIX singleton array fails closed via PSObject status too'
# --- FIX2: collections in last_failure/terminal_blocker fail closed before string-cast.
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ terminal_blocker = @('OBJECTIVE_COMPLETED'); objective_completed = $false })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED' -and $r.reason -ceq 'invalid-status-type') 'FIX2 collection terminal_blocker fails closed, never OBJECTIVE_COMPLETED'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ last_failure = @('recoverable'); remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED' -and $r.reason -ceq 'invalid-status-type') 'FIX2 collection last_failure fails closed, never RETRY'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ last_failure = @('bogus') })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'POLICY_BLOCKED' -and $r.reason -ceq 'invalid-status-type') 'FIX2 collection last_failure with unknown content fails closed as type error'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ terminal_blocker = 'OBJECTIVE_COMPLETED'; objective_completed = $false })
Assert-OCThat ($r.move -ceq 'COMPLETE' -and $r.stop_reason -ceq 'OBJECTIVE_COMPLETED') 'FIX2 scalar terminal_blocker unchanged'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ last_failure = 'recoverable'; remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'RETRY') 'FIX2 scalar last_failure unchanged'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ last_failure = ''; remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'CONTINUE') 'FIX2 empty-string last_failure keeps current behavior'
$fixBase = Get-OrchestrationNextMove -Status (New-OCStatus @{ consecutive_no_progress = 0 })
$fixBig = Get-OrchestrationNextMove -Status (New-OCStatus @{ consecutive_no_progress = [long]::MaxValue })
Assert-OCThat (($fixBig.move -ceq $fixBase.move) -and ($fixBig.reason -ceq $fixBase.reason) -and ($fixBig.remaining_count -eq $fixBase.remaining_count) -and ($null -eq $fixBig.PSObject.Properties['stop_reason'])) 'FIX MaxValue consecutive_no_progress is inert, identical to 0'
$r = Get-OrchestrationNextMove -Status (New-OCStatus @{ consecutive_no_progress = [long]42; remaining_work = @('a'); progress_possible = $true })
Assert-OCThat ($r.move -ceq 'CONTINUE' -and $r.remaining_count -eq 1) 'FIX normal Int64 consecutive_no_progress flows normally'
Write-Output "PASS OrchestrationObjectiveController: $passed assertions"
