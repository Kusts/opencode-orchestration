<#!
.SYNOPSIS
    PR-5 Autonomy/Budget/Delivery Wiring: capacity, budget, delivery, stops (HOLD).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Fail-closed, PS 5.1
    compatible, ASCII-only. Never throws on operational paths: every
    failure returns a fail-closed envelope. No network, no process spawn,
    no secret values, no grant issuance, no DONE claim, no merge
    execution: enforcement stays HOLD, the Planner and the kernel remain
    the authority.

    The wiring CONNECTS existing guards instead of duplicating them
    (CORRECTIVE-PLAN Fase 3, PR-5, HOLD mantido):

      - capacity: per-wave planning that estimates workers, reserves
        Tester/Reviewer capacity, shrinks Explorer fan-out under quota,
        applies reuse candidates first; without quota it checkpoints
        and holds (the Planner never assumes all the work itself).
      - budget: per-Goal ledger (worker/task/goal accumulation,
        persisted to a caller-provided store dir); worker/task
        exhaustion means replan, only Goal hard-budget exhaustion is
        terminal, honest (done_approved=false) and resumable.
      - delivery: code->tests->review->PR->CI->findings->repair->merge
        gate decided through OrchestrationDelivery.ps1 eligibility;
        PR opened is never DONE; CI failure or P1 finding means repair
        plus revalidation; a blocked merge preserves state and
        surfaces the blocker; branch protection is never bypassed
        and no authorization is ever invented.
      - stops: the 6 closed stop reasons terminate; anything else
        returns to the control plane.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    foreach ($AWLibName in @('OrchestrationAutonomy.ps1', 'OrchestrationDelivery.ps1')) {
        try {
            $AWLibPath = Join-Path $PSScriptRoot $AWLibName
            if (Test-Path -LiteralPath $AWLibPath -PathType Leaf) { . $AWLibPath }
        }
        catch { }
    }
}
catch { }

function Get-OrchestrationAutonomyWiringVersion {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        schema_version = 1
        contract       = 'UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-AUTONOMY-WIRING'
        phase          = 'PR-5'
    }
}

function Get-AWFieldValue {
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

function Test-OrchestrationAutonomyGoalId {
    [CmdletBinding()]
    param([string]$GoalId = '')
    try {
        $v = ([string]$GoalId).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]{1,128}$')
    }
    catch { return $false }
}

function Test-AWStrictNonNegInt {
    param($Value)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $false }
        if (-not (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [short]) -or ($Value -is [byte]))) { return $false }
        return ([long]$Value -ge 0)
    }
    catch { return $false }
}

function Test-AWStrictPositiveInt {
    param($Value)
    try {
        if (-not (Test-AWStrictNonNegInt -Value $Value)) { return $false }
        return ([long]$Value -ge 1)
    }
    catch { return $false }
}

function New-AWCapacityEnvelope {
    param(
        [string]$Decision = 'checkpoint-hold',
        [bool]$Hold = $true,
        [bool]$Checkpoint = $true,
        [bool]$ValidationPreserved = $true,
        [int]$Coders = 0,
        [int]$Explorers = 0,
        [int]$Testers = 0,
        [int]$Reviewers = 0,
        [bool]$ReuseApplied = $false,
        [bool]$ExplorersReduced = $false,
        [string[]]$Reasons = @()
    )
    try {
        $why = @()
        if ($null -ne $Reasons) { $why = @($Reasons) }
        return [pscustomobject]@{
            ok                   = $true
            decision             = ([string]$Decision)
            hold                 = [bool]$Hold
            checkpoint           = [bool]$Checkpoint
            validation_preserved = [bool]$ValidationPreserved
            planner_assumes_all  = $false
            dispatched           = [pscustomobject]@{
                coders    = [int]$Coders
                explorers = [int]$Explorers
                testers   = [int]$Testers
                reviewers = [int]$Reviewers
            }
            reuse_applied        = [bool]$ReuseApplied
            explorers_reduced    = [bool]$ExplorersReduced
            reasons              = $why
            grants_authority     = $false
            done_approved        = $false
            verified_pass        = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $true; decision = 'checkpoint-hold'; hold = $true
            checkpoint = $true; validation_preserved = $true
            planner_assumes_all = $false
            dispatched = [pscustomobject]@{ coders = 0; explorers = 0; testers = 0; reviewers = 0 }
            reuse_applied = $false; explorers_reduced = $false
            reasons = @('internal-error-checkpoint')
            grants_authority = $false; done_approved = $false; verified_pass = $false
        }
    }
}

function New-OrchestrationWaveCapacityPlan {
    [CmdletBinding()]
    param(
        $RequestedCoders = 0,
        $RequestedExplorers = 0,
        $RequestedTesters = 0,
        $RequestedReviewers = 0,
        $AvailableSlots = 0,
        $ReuseCandidateCount = 0,
        [bool]$RequireValidation = $true
    )
    try {
        if ((-not (Test-AWStrictNonNegInt -Value $RequestedCoders)) -or
            (-not (Test-AWStrictNonNegInt -Value $RequestedExplorers)) -or
            (-not (Test-AWStrictNonNegInt -Value $RequestedTesters)) -or
            (-not (Test-AWStrictNonNegInt -Value $RequestedReviewers)) -or
            (-not (Test-AWStrictNonNegInt -Value $AvailableSlots)) -or
            (-not (Test-AWStrictNonNegInt -Value $ReuseCandidateCount))) {
            return (New-AWCapacityEnvelope -Decision 'checkpoint-hold' -Hold $true -Checkpoint $true `
                -ValidationPreserved $true -Coders 0 -Explorers 0 -Testers 0 -Reviewers 0 `
                -ReuseApplied $false -ExplorersReduced $false -Reasons @('invalid-input-checkpoint'))
        }
        $rc = [int][long]$RequestedCoders
        $re = [int][long]$RequestedExplorers
        $rt = [int][long]$RequestedTesters
        $rr = [int][long]$RequestedReviewers
        $av = [int][long]$AvailableSlots
        $reuse = [int][long]$ReuseCandidateCount
        $minT = 0
        $minR = 0
        if ([bool]$RequireValidation) { $minT = 1; $minR = 1 }
        $needT = $rt
        if ($needT -lt $minT) { $needT = $minT }
        $needR = $rr
        if ($needR -lt $minR) { $needR = $minR }
        $effCoders = $rc - $reuse
        if ($effCoders -lt 0) { $effCoders = 0 }
        $reuseOn = ($reuse -gt 0)
        $reserve = $needT + $needR
        if ($av -lt $reserve) {
            return (New-AWCapacityEnvelope -Decision 'checkpoint-hold' -Hold $true -Checkpoint $true `
                -ValidationPreserved $true -Coders 0 -Explorers 0 -Testers $minT -Reviewers $minR `
                -ReuseApplied $reuseOn -ExplorersReduced $false -Reasons @('quota-insufficient-checkpoint'))
        }
        $full = $effCoders + $re + $reserve
        if ($full -le $av) {
            return (New-AWCapacityEnvelope -Decision 'dispatch-full' -Hold $false -Checkpoint $false `
                -ValidationPreserved $true -Coders $effCoders -Explorers $re -Testers $needT -Reviewers $needR `
                -ReuseApplied $reuseOn -ExplorersReduced $false -Reasons @())
        }
        $fitExplorers = $av - $effCoders - $reserve
        if ($fitExplorers -lt 0) {
            return (New-AWCapacityEnvelope -Decision 'checkpoint-hold' -Hold $true -Checkpoint $true `
                -ValidationPreserved $true -Coders 0 -Explorers 0 -Testers $minT -Reviewers $minR `
                -ReuseApplied $reuseOn -ExplorersReduced $false -Reasons @('quota-insufficient-checkpoint'))
        }
        $why = @('explorer-fanout-reduced-under-quota')
        if ($reuseOn) { $why += @('reuse-prioritized') }
        if (($re -gt 0) -and ($fitExplorers -eq 0)) { $why += @('explorer-fanout-collapsed') }
        return (New-AWCapacityEnvelope -Decision 'dispatch-reduced' -Hold $false -Checkpoint $false `
            -ValidationPreserved $true -Coders $effCoders -Explorers $fitExplorers -Testers $needT -Reviewers $needR `
            -ReuseApplied $reuseOn -ExplorersReduced ($fitExplorers -lt $re) -Reasons $why)
    }
    catch {
        return (New-AWCapacityEnvelope -Decision 'checkpoint-hold' -Hold $true -Checkpoint $true `
            -ValidationPreserved $true -Coders 0 -Explorers 0 -Testers 0 -Reviewers 0 `
            -ReuseApplied $false -ExplorersReduced $false -Reasons @('internal-error-checkpoint'))
    }
}

function New-OrchestrationGoalBudgetLedger {
    [CmdletBinding()]
    param($GoalId = '', $WorkerLimit = 0, $TaskLimit = 0, $GoalHardLimit = 0)
    try {
        if ((-not (Test-OrchestrationAutonomyGoalId -GoalId ([string]$GoalId))) -or
            (-not (Test-AWStrictPositiveInt -Value $WorkerLimit)) -or
            (-not (Test-AWStrictPositiveInt -Value $TaskLimit)) -or
            (-not (Test-AWStrictPositiveInt -Value $GoalHardLimit))) {
            return [pscustomobject]@{
                ok = $false; reason = 'invalid-input'
                goal_id = ([string]$GoalId)
                terminal = $false; decision = 'invalid-input'
                done_approved = $false; grants_authority = $false; verified_pass = $false
            }
        }
        return [pscustomobject]@{
            ok = $true; goal_id = ([string]$GoalId).Trim()
            worker_limit = [long]$WorkerLimit; task_limit = [long]$TaskLimit
            goal_hard_limit = [long]$GoalHardLimit
            worker_consumed = [long]0; task_consumed = [long]0; goal_consumed = [long]0
            revision = [long]0
            resumable = $true; terminal = $false; decision = 'continue'; reason = ''
            done_approved = $false; grants_authority = $false; verified_pass = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $false; reason = 'internal-error'
            goal_id = ([string]$GoalId)
            terminal = $false; decision = 'invalid-input'
            done_approved = $false; grants_authority = $false; verified_pass = $false
        }
    }
}

function Test-AWBudgetLedgerShape {
    param($Ledger)
    try {
        if ($null -eq $Ledger) { return $false }
        if (-not (Test-OrchestrationAutonomyGoalId -GoalId ([string](Get-AWFieldValue $Ledger 'goal_id' '')))) { return $false }
        foreach ($f in @('worker_limit', 'task_limit', 'goal_hard_limit', 'worker_consumed', 'task_consumed', 'goal_consumed')) {
            if (-not (Test-AWStrictNonNegInt -Value (Get-AWFieldValue $Ledger $f $null))) { return $false }
        }
        $rev = Get-AWFieldValue $Ledger 'revision' $null
        if (($null -ne $rev) -and (-not (Test-AWStrictNonNegInt -Value $rev))) { return $false }
        return $true
    }
    catch { return $false }
}

if ($null -eq (Get-Variable -Name AWBudgetLedgerLock -Scope Script -ErrorAction SilentlyContinue)) {
    $script:AWBudgetLedgerLock = New-Object Object
}

function New-AWBudgetOutcome {
    param($Ledger, [string]$Decision = 'continue', [string]$Reason = '', [bool]$Terminal = $false, [string]$StopReason = '')
    try {
        return [pscustomobject]@{
            ok = $true; ledger = $Ledger; decision = ([string]$Decision)
            reason = ([string]$Reason); terminal = [bool]$Terminal
            stop_reason = ([string]$StopReason)
            resumable = [bool](Get-AWFieldValue $Ledger 'resumable' $true)
            done_approved = $false; grants_authority = $false; verified_pass = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $false; ledger = $Ledger; decision = 'invalid-input'
            reason = 'internal-error'; terminal = $false; stop_reason = ''
            resumable = $true; done_approved = $false; grants_authority = $false; verified_pass = $false
        }
    }
}

function Test-OrchestrationBudgetExhaustion {
    [CmdletBinding()]
    param($Ledger = $null)
    try {
        if (-not (Test-AWBudgetLedgerShape -Ledger $Ledger)) {
            return (New-AWBudgetOutcome -Ledger $Ledger -Decision 'invalid-input' -Reason 'invalid-ledger' -Terminal $false)
        }
        $wLim = [long](Get-AWFieldValue $Ledger 'worker_limit' 0)
        $tLim = [long](Get-AWFieldValue $Ledger 'task_limit' 0)
        $gLim = [long](Get-AWFieldValue $Ledger 'goal_hard_limit' 0)
        $wCon = [long](Get-AWFieldValue $Ledger 'worker_consumed' 0)
        $tCon = [long](Get-AWFieldValue $Ledger 'task_consumed' 0)
        $gCon = [long](Get-AWFieldValue $Ledger 'goal_consumed' 0)
        if ($gCon -gt $gLim) {
            return (New-AWBudgetOutcome -Ledger $Ledger -Decision 'terminal' -Reason 'goal-hard-budget-exhausted-terminal' -Terminal $true -StopReason 'GOAL_HARD_BUDGET_EXHAUSTED')
        }
        if ($wCon -gt $wLim) {
            return (New-AWBudgetOutcome -Ledger $Ledger -Decision 'replan' -Reason 'worker-budget-exhausted-replan' -Terminal $false)
        }
        if ($tCon -gt $tLim) {
            return (New-AWBudgetOutcome -Ledger $Ledger -Decision 'replan' -Reason 'taskquota-exhausted-replan' -Terminal $false)
        }
        return (New-AWBudgetOutcome -Ledger $Ledger -Decision 'continue' -Reason '' -Terminal $false)
    }
    catch {
        return (New-AWBudgetOutcome -Ledger $Ledger -Decision 'invalid-input' -Reason 'internal-error' -Terminal $false)
    }
}

function Add-OrchestrationBudgetConsumption {
    [CmdletBinding()]
    param($Ledger = $null, $WorkerCost = 0, $TaskCost = 0, $GoalCost = 0)
    try {
        if ((-not (Test-AWBudgetLedgerShape -Ledger $Ledger)) -or
            (-not (Test-AWStrictNonNegInt -Value $WorkerCost)) -or
            (-not (Test-AWStrictNonNegInt -Value $TaskCost)) -or
            (-not (Test-AWStrictNonNegInt -Value $GoalCost))) {
            return (New-AWBudgetOutcome -Ledger $Ledger -Decision 'invalid-input' -Reason 'invalid-input' -Terminal $false)
        }
        $next = [pscustomobject]@{
            ok = [bool](Get-AWFieldValue $Ledger 'ok' $true)
            goal_id = ([string](Get-AWFieldValue $Ledger 'goal_id' ''))
            worker_limit = [long](Get-AWFieldValue $Ledger 'worker_limit' 0)
            task_limit = [long](Get-AWFieldValue $Ledger 'task_limit' 0)
            goal_hard_limit = [long](Get-AWFieldValue $Ledger 'goal_hard_limit' 0)
            worker_consumed = ([long](Get-AWFieldValue $Ledger 'worker_consumed' 0) + [long]$WorkerCost)
            task_consumed = ([long](Get-AWFieldValue $Ledger 'task_consumed' 0) + [long]$TaskCost)
            goal_consumed = ([long](Get-AWFieldValue $Ledger 'goal_consumed' 0) + [long]$GoalCost)
            revision = [long](Get-AWFieldValue $Ledger 'revision' 0)
            resumable = [bool](Get-AWFieldValue $Ledger 'resumable' $true)
            terminal = $false; decision = 'continue'; reason = ''
            done_approved = $false; grants_authority = $false; verified_pass = $false
        }
        return (Test-OrchestrationBudgetExhaustion -Ledger $next)
    }
    catch {
        return (New-AWBudgetOutcome -Ledger $Ledger -Decision 'invalid-input' -Reason 'internal-error' -Terminal $false)
    }
}

function Save-OrchestrationGoalBudgetLedger {
    [CmdletBinding()]
    param($Ledger = $null, [string]$StoreDir = '')
    try {
        if (-not (Test-AWBudgetLedgerShape -Ledger $Ledger)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-ledger'; path = '' }
        }
        $dir = ([string]$StoreDir).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'store-dir-missing'; path = '' }
        }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'store-dir-unwritable'; path = '' }
        }
        $gid = ([string](Get-AWFieldValue $Ledger 'goal_id' '')).Trim()
        $path = Join-Path $dir ($gid + '.budget.json')
        $lockTaken = $false
        try {
            try { [void][System.Threading.Monitor]::TryEnter($script:AWBudgetLedgerLock, 5000, [ref]$lockTaken) } catch { $lockTaken = $false }
            if (-not [bool]$lockTaken) {
                return [pscustomobject]@{ ok = $false; reason = 'ledger-lock-busy'; path = '' }
            }
            $callerRev = [long](Get-AWFieldValue $Ledger 'revision' 0)
            $currentRev = [long]-1
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                try {
                    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
                    if ([string]::IsNullOrWhiteSpace($raw)) {
                        return [pscustomobject]@{ ok = $false; reason = 'ledger-corrupt'; path = '' }
                    }
                    $cur = ($raw | ConvertFrom-Json)
                    $currentRev = [long](Get-AWFieldValue $cur 'revision' 0)
                }
                catch {
                    return [pscustomobject]@{ ok = $false; reason = 'ledger-corrupt'; path = '' }
                }
                if ($callerRev -ne $currentRev) {
                    return [pscustomobject]@{ ok = $false; reason = 'revision-conflict'; path = ([string]$path) }
                }
            }
            else {
                if ($callerRev -ne 0) {
                    return [pscustomobject]@{ ok = $false; reason = 'revision-conflict'; path = ([string]$path) }
                }
                $currentRev = [long]-1
            }
            $nextRev = $callerRev + 1
            $doc = [ordered]@{
                goal_id = $gid
                worker_limit = [long](Get-AWFieldValue $Ledger 'worker_limit' 0)
                task_limit = [long](Get-AWFieldValue $Ledger 'task_limit' 0)
                goal_hard_limit = [long](Get-AWFieldValue $Ledger 'goal_hard_limit' 0)
                worker_consumed = [long](Get-AWFieldValue $Ledger 'worker_consumed' 0)
                task_consumed = [long](Get-AWFieldValue $Ledger 'task_consumed' 0)
                goal_consumed = [long](Get-AWFieldValue $Ledger 'goal_consumed' 0)
                revision = [long]$nextRev
                resumable = [bool](Get-AWFieldValue $Ledger 'resumable' $true)
            }
            $tmp = Join-Path $dir ($gid + '.budget.json.tmp-' + [Guid]::NewGuid().ToString('N'))
            try {
                [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
            }
            catch {
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
                return [pscustomobject]@{ ok = $false; reason = 'store-write-failed'; path = '' }
            }
            try {
                [IO.File]::Copy($tmp, $path, $true)
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
            }
            catch {
                try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { }
                return [pscustomobject]@{ ok = $false; reason = 'store-write-failed'; path = '' }
            }
            try {
                $Ledger.revision = [long]$nextRev
            }
            catch { }
            return [pscustomobject]@{ ok = $true; reason = ''; path = ([string]$path); revision = [long]$nextRev }
        }
        finally {
            if ([bool]$lockTaken) { try { [System.Threading.Monitor]::Exit($script:AWBudgetLedgerLock) } catch { } }
        }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'internal-error'; path = '' }
    }
}

function Read-OrchestrationGoalBudgetLedger {
    [CmdletBinding()]
    param([string]$GoalId = '', [string]$StoreDir = '')
    try {
        if (-not (Test-OrchestrationAutonomyGoalId -GoalId ([string]$GoalId))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; ledger = $null }
        }
        $dir = ([string]$StoreDir).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'store-dir-missing'; ledger = $null }
        }
        $path = Join-Path $dir (([string]$GoalId).Trim() + '.budget.json')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [pscustomobject]@{ ok = $false; reason = 'ledger-not-found'; ledger = $null }
        }
        $doc = $null
        try { $doc = ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json) }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'ledger-unreadable'; ledger = $null }
        }
        $led = [pscustomobject]@{
            ok = $true
            goal_id = ([string](Get-AWFieldValue $doc 'goal_id' ''))
            worker_limit = (Get-AWFieldValue $doc 'worker_limit' $null)
            task_limit = (Get-AWFieldValue $doc 'task_limit' $null)
            goal_hard_limit = (Get-AWFieldValue $doc 'goal_hard_limit' $null)
            worker_consumed = (Get-AWFieldValue $doc 'worker_consumed' $null)
            task_consumed = (Get-AWFieldValue $doc 'task_consumed' $null)
            goal_consumed = (Get-AWFieldValue $doc 'goal_consumed' $null)
            revision = (Get-AWFieldValue $doc 'revision' 0)
            resumable = [bool](Get-AWFieldValue $doc 'resumable' $true)
            terminal = $false; decision = 'continue'; reason = ''
            done_approved = $false; grants_authority = $false; verified_pass = $false
        }
        if ((-not (Test-AWBudgetLedgerShape -Ledger $led)) -or ([string]$led.goal_id -cne ([string]$GoalId).Trim())) {
            return [pscustomobject]@{ ok = $false; reason = 'ledger-invalid'; ledger = $null }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; ledger = $led }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'internal-error'; ledger = $null }
    }
}

function Test-OrchestrationAutonomyActionAllowed {
    [CmdletBinding()]
    param([string]$Action = '', $Authorization = $null)
    try {
        $act = ([string]$Action).Trim()
        if ([string]::IsNullOrWhiteSpace($act)) {
            return [pscustomobject]@{ ok = $true; allowed = $false; blocked = $true; reason = 'action-missing-blocked'; grants_authority = $false }
        }
        $knownCmd = Get-Command Get-OrchestrationAutoAuthorized -ErrorAction SilentlyContinue
        if ($null -ne $knownCmd) {
            $known = @(Get-OrchestrationAutoAuthorized)
            $found = $false
            foreach ($k in @($known)) {
                if ([string]$k -ceq $act) { $found = $true; break }
            }
            if (-not $found) {
                return [pscustomobject]@{ ok = $true; allowed = $false; blocked = $true; reason = 'unknown-action-blocked'; grants_authority = $false }
            }
        }
        if ($null -eq $Authorization) {
            return [pscustomobject]@{ ok = $true; allowed = $false; blocked = $true; reason = 'outside-authorization-blocked'; grants_authority = $false }
        }
        $allowedList = @(Get-AWFieldValue $Authorization 'Allowed' @())
        $deniedList = @(Get-AWFieldValue $Authorization 'Denied' @())
        foreach ($d in @($deniedList)) {
            if ([string]$d -ceq $act) {
                return [pscustomobject]@{ ok = $true; allowed = $false; blocked = $true; reason = 'outside-authorization-blocked'; grants_authority = $false }
            }
        }
        foreach ($a in @($allowedList)) {
            if ([string]$a -ceq $act) {
                return [pscustomobject]@{ ok = $true; allowed = $true; blocked = $false; reason = ''; grants_authority = $false }
            }
        }
        return [pscustomobject]@{ ok = $true; allowed = $false; blocked = $true; reason = 'outside-authorization-blocked'; grants_authority = $false }
    }
    catch {
        return [pscustomobject]@{ ok = $true; allowed = $false; blocked = $true; reason = 'internal-error-blocked'; grants_authority = $false }
    }
}

function Get-AWRequiredAutoAction {
    param([string]$State = '')
    try {
        $s = ([string]$State).Trim().ToUpperInvariant()
        if ($s -ceq 'IMPLEMENTATION') { return 'edit_refactor' }
        if ($s -ceq 'TESTING') { return 'test_build' }
        if ($s -ceq 'PR_READY') { return 'pr_open' }
        if ($s -ceq 'PR_OPEN') { return 'ci_rerun' }
        if ($s -ceq 'REPAIR') { return 'findings_repair' }
        return ''
    }
    catch { return '' }
}

function New-AWDeliveryEnvelope {
    param(
        [string]$State = '',
        [string]$ActionStep = 'preserve-checkpoint',
        [bool]$Blocked = $false,
        [bool]$Terminal = $false,
        [string]$StopReason = '',
        [string]$Reason = '',
        [bool]$RepairRequired = $false,
        [bool]$Revalidate = $false,
        [bool]$StatePreserved = $true,
        [string]$Blocker = '',
        [bool]$Eligible = $false,
        [string[]]$EligibilityReasons = @(),
        [bool]$PrOpened = $false
    )
    try {
        $er = @()
        if ($null -ne $EligibilityReasons) { $er = @($EligibilityReasons) }
        return [pscustomobject]@{
            ok = $true
            state = ([string]$State)
            action_step = ([string]$ActionStep)
            blocked = [bool]$Blocked
            terminal = [bool]$Terminal
            stop_reason = ([string]$StopReason)
            reason = ([string]$Reason)
            repair_required = [bool]$RepairRequired
            revalidate = [bool]$Revalidate
            state_preserved = [bool]$StatePreserved
            blocker = ([string]$Blocker)
            eligible = [bool]$Eligible
            eligibility_reasons = $er
            pr_opened = [bool]$PrOpened
            pr_is_not_done = $true
            branch_protection_bypass = $false
            grants_authority = $false
            done_approved = $false
            verified_pass = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $true; state = ''; action_step = 'preserve-checkpoint'
            blocked = $true; terminal = $false; stop_reason = ''
            reason = 'internal-error-preserve'
            repair_required = $false; revalidate = $false
            state_preserved = $true; blocker = 'internal-error'
            eligible = $false; eligibility_reasons = @()
            pr_opened = $false; pr_is_not_done = $true
            branch_protection_bypass = $false
            grants_authority = $false; done_approved = $false; verified_pass = $false
        }
    }
}

function Invoke-OrchestrationDeliveryStep {
    [CmdletBinding()]
    param(
        $Events = @(),
        [string]$CiStatus = '',
        $Checks = @(),
        $ReviewerApproved = $null,
        $SecurityRequired = $null,
        $SecurityApproved = $null,
        $UnresolvedP1 = $null,
        $Risk = '',
        $Policy = $null,
        $Authorization = $null
    )
    try {
        $stateCmd = Get-Command Get-OrchestrationDeliveryState -ErrorAction SilentlyContinue
        if ($null -eq $stateCmd) {
            return (New-AWDeliveryEnvelope -State '' -ActionStep 'preserve-checkpoint' -Blocked $true `
                -Reason 'delivery-lib-unavailable-preserve' -StatePreserved $true -Blocker 'delivery-lib-unavailable')
        }
        $st = $null
        try {
            $list = @()
            if ($null -ne $Events) {
                if ($Events -is [string]) { $list = @([string]$Events) }
                else { $list = @($Events) }
            }
            $st = Get-OrchestrationDeliveryState -Events $list
        }
        catch { $st = $null }
        $state = ([string](Get-AWFieldValue $st 'state' ''))
        if ([string]::IsNullOrWhiteSpace($state) -or ($state -ceq 'INVALID')) {
            return (New-AWDeliveryEnvelope -State 'INVALID' -ActionStep 'preserve-checkpoint' -Blocked $true `
                -Reason 'invalid-event' -StatePreserved $true -Blocker 'invalid-event')
        }
        $need = Get-AWRequiredAutoAction -State $state
        $ci = ([string]$CiStatus).Trim().ToLowerInvariant()
        $ciFailed = (($ci -ceq 'ci_failed') -or ($ci -ceq 'failed') -or ($ci -ceq 'failure'))
        if (-not [string]::IsNullOrWhiteSpace($need)) {
            if ($null -eq $Authorization) {
                return (New-AWDeliveryEnvelope -State $state -ActionStep 'preserve-checkpoint' -Blocked $true `
                    -Reason 'outside-authorization-blocked' -StatePreserved $true -Blocker 'outside-authorization-blocked')
            }
            $effectiveNeed = $need
            if ($state -ceq 'PR_OPEN') {
                if ($ciFailed) { $effectiveNeed = 'findings_repair' }
                else { $effectiveNeed = 'ci_rerun' }
            }
            $gate = Test-OrchestrationAutonomyActionAllowed -Action $effectiveNeed -Authorization $Authorization
            if (-not [bool](Get-AWFieldValue $gate 'allowed' $false)) {
                return (New-AWDeliveryEnvelope -State $state -ActionStep 'preserve-checkpoint' -Blocked $true `
                    -Reason 'outside-authorization-blocked' -StatePreserved $true -Blocker 'outside-authorization-blocked')
            }
        }
        if (($state -ceq 'IMPLEMENTATION')) {
            return (New-AWDeliveryEnvelope -State $state -ActionStep 'implement' -StatePreserved $true)
        }
        if (($state -ceq 'TESTING')) {
            return (New-AWDeliveryEnvelope -State $state -ActionStep 'run-tests' -StatePreserved $true)
        }
        if (($state -ceq 'REVIEW')) {
            return (New-AWDeliveryEnvelope -State $state -ActionStep 'review' -StatePreserved $true)
        }
        if (($state -ceq 'PR_READY')) {
            return (New-AWDeliveryEnvelope -State $state -ActionStep 'open-pr' -StatePreserved $true -PrOpened $false)
        }
        if (($state -ceq 'PR_OPEN')) {
            if ($ciFailed) {
                return (New-AWDeliveryEnvelope -State $state -ActionStep 'repair' -Reason 'ci-failed-repair-not-done' `
                    -RepairRequired $true -Revalidate $true -StatePreserved $true)
            }
            return (New-AWDeliveryEnvelope -State $state -ActionStep 'await-ci' -StatePreserved $true)
        }
        if (($state -ceq 'MERGE_GATE')) {
            if ($ciFailed) {
                return (New-AWDeliveryEnvelope -State $state -ActionStep 'repair' -Reason 'ci-failed-repair-not-done' `
                    -RepairRequired $true -Revalidate $true -StatePreserved $true)
            }
            $eligCmd = Get-Command Test-OrchestrationMergeEligibility -ErrorAction SilentlyContinue
            if ($null -eq $eligCmd) {
                return (New-AWDeliveryEnvelope -State $state -ActionStep 'preserve-checkpoint' -Blocked $true `
                    -Reason 'eligibility-unavailable-preserve' -StatePreserved $true -Blocker 'eligibility-unavailable')
            }
            $elig = $null
            try {
                $elist = @()
                if ($null -ne $Checks) { $elist = @($Checks) }
                $elig = Test-OrchestrationMergeEligibility -Policy $Policy -Checks $elist `
                    -ReviewerApproved $ReviewerApproved -SecurityRequired $SecurityRequired `
                    -SecurityApproved $SecurityApproved -UnresolvedP1 $UnresolvedP1 -Risk $Risk
            }
            catch { $elig = $null }
            if ($null -eq $elig) {
                return (New-AWDeliveryEnvelope -State $state -ActionStep 'preserve-checkpoint' -Blocked $true `
                    -Reason 'eligibility-evaluation-failed' -StatePreserved $true -Blocker 'eligibility-evaluation-failed')
            }
            $er = @(Get-AWFieldValue $elig 'reasons' @())
            if ([bool](Get-AWFieldValue $elig 'eligible' $false)) {
                return (New-AWDeliveryEnvelope -State $state -ActionStep 'await-merge-gate' `
                    -StatePreserved $true -Eligible $true -EligibilityReasons $er)
            }
            return (New-AWDeliveryEnvelope -State $state -ActionStep 'repair' `
                -Reason ('merge-not-eligible-repair:' + ($er -join ',')) `
                -RepairRequired $true -Revalidate $true -StatePreserved $true `
                -Eligible $false -EligibilityReasons $er)
        }
        if (($state -ceq 'REPAIR')) {
            return (New-AWDeliveryEnvelope -State $state -ActionStep 'repair-revalidate' `
                -RepairRequired $true -Revalidate $true -StatePreserved $true)
        }
        if (($state -ceq 'MERGED')) {
            return (New-AWDeliveryEnvelope -State $state -ActionStep 'delivery-terminal-merged' `
                -Terminal $true -StopReason 'OBJECTIVE_COMPLETED' -Reason 'delivery-terminal-observed' -StatePreserved $true)
        }
        if (($state -ceq 'DELIVERY_BLOCKED')) {
            return (New-AWDeliveryEnvelope -State $state -ActionStep 'preserve-blocker' -Blocked $true `
                -Reason 'merge-blocked-state-preserved' -StatePreserved $true -Blocker 'merge-blocked-state-preserved')
        }
        if (($state -ceq 'CANCELLED')) {
            return (New-AWDeliveryEnvelope -State $state -ActionStep 'delivery-terminal-cancelled' `
                -Terminal $true -StopReason 'CANCELLED' -Reason 'delivery-cancelled' -StatePreserved $true)
        }
        return (New-AWDeliveryEnvelope -State $state -ActionStep 'preserve-checkpoint' -Blocked $true `
            -Reason 'unknown-state-preserve' -StatePreserved $true -Blocker 'unknown-state')
    }
    catch {
        return (New-AWDeliveryEnvelope -State '' -ActionStep 'preserve-checkpoint' -Blocked $true `
            -Reason 'internal-error-preserve' -StatePreserved $true -Blocker 'internal-error')
    }
}

function Resolve-OrchestrationStopDecision {
    [CmdletBinding()]
    param([string]$Reason = '', [string]$Detail = '')
    try {
        $r = ([string]$Reason).Trim().ToUpperInvariant()
        $closed = @('OBJECTIVE_COMPLETED', 'HUMAN_AUTHORITY_REQUIRED', 'EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE', 'GOAL_HARD_BUDGET_EXHAUSTED', 'POLICY_BLOCKED', 'CANCELLED')
        $stopCmd = Get-Command Get-OrchestrationStopReasons -ErrorAction SilentlyContinue
        if ($null -ne $stopCmd) {
            try {
                $fromLib = @(Get-OrchestrationStopReasons)
                if (@($fromLib).Count -gt 0) { $closed = @($fromLib) }
            }
            catch { }
        }
        $hit = $false
        foreach ($c in @($closed)) {
            if ($r -ceq ([string]$c).Trim().ToUpperInvariant()) { $hit = $true; break }
        }
        if ($hit) {
            return [pscustomobject]@{
                ok = $true; terminal = $true; stop_reason = ([string]$r)
                detail = ([string]$Detail); return_to = ''
                done_approved = $false; grants_authority = $false; verified_pass = $false
            }
        }
        return [pscustomobject]@{
            ok = $true; terminal = $false; stop_reason = ''
            detail = ([string]$Detail); return_to = 'control-plane'
            reason = 'unknown-stop-returns-to-control-plane'
            done_approved = $false; grants_authority = $false; verified_pass = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $true; terminal = $false; stop_reason = ''
            detail = ([string]$Detail); return_to = 'control-plane'
            reason = 'internal-error-returns-to-control-plane'
            done_approved = $false; grants_authority = $false; verified_pass = $false
        }
    }
}
