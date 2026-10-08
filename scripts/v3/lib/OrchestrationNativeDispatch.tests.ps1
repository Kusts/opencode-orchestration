<#!
.SYNOPSIS
    Tests for lib/OrchestrationNativeDispatch.ps1 (bridge honesto).
.DESCRIPTION
    Hermetic: temp dirs, cleanup in finally; repo tree never written.
    Bracketed output the runner parses. Exit 0 all pass, 1 any fail.
    PS 5.1 compatible. ASCII-only. No network, no spawn.
    Covers: Gate E (denied before effect, spy 0 calls), intent validation
    (no raw prompt), idempotency (repeat, crash-pending, shape rejection),
    result-shape gate (verified_pass/done rejected), evidence + kernel
    envelopes fail-closed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1')

$script:passed = 0
$script:failed = 0

function Assert-ND {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("[PASS] {0}" -f $Name)
        $script:passed++
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-nativedispatch-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $goalDir = Join-Path $tempRoot 'goals'
    $receiptDir = Join-Path $tempRoot 'receipts'
    $evDir = Join-Path $tempRoot 'evidence'
    New-Item -ItemType Directory -Path $goalDir -Force | Out-Null
    New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
    New-Item -ItemType Directory -Path $evDir -Force | Out-Null

    try {
        # ---------- fixture: live goal + ownership ----------
        $g = New-OrchestrationGoal -GoalId 'nd-goal-1' -Objective 'bridge honesto' -Criteria @('criterio-a', 'criterio-b') -StoreDir $goalDir
        Assert-ND ([bool]$g.ok) '[F] goal created' ([string]$g.reason)
        $act = Set-OrchestrationGoalState -Goal $g.goal -ToState 'ACTIVE'
        Assert-ND ([bool]$act.ok) '[F] goal activated' ([string]$act.reason)
        $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $goalDir
        Assert-ND ([bool]$sv.ok) '[F] goal saved' ([string]$sv.reason)
        $own = Acquire-OrchestrationGoalOwnership -GoalId 'nd-goal-1' -OwnerId 'planner-1' -ExpectedRevision ([long]$sv.revision) -StoreDir $goalDir
        Assert-ND ([bool]$own.ok) '[F] ownership acquired' ([string]$own.reason)
        $gen = [long]$own.ownership['generation']

        $authOk = @{ explicit_allow = $true; goal_id = 'nd-goal-1'; owner = 'planner-1'; generation = $gen; source = 'planner' }
        $ph = Get-NativeDispatchHash32 'prompt-material-do-planner'

        function New-NDSpec {
            param([string]$Key = '')
            return @{
                task_id = 'nd-task-1'; task_expected_revision = 1; agent = 'coder';
                prompt_hash = $script:phText; scope = @('src/a.ps1');
                acceptance_criteria = @('criterion:0', 'criterion:1');
                idempotency_key = $Key; owner = 'planner-1'; ownership_generation = $script:genText;
                base_revision = 'rev-a'
            }
        }
        $script:phText = $ph
        $script:genText = $gen

        # ---------- intent validation ----------
        $badTask = New-OrchestrationDispatchIntent -TaskId 'BAD ID!!' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        Assert-ND (((-not [bool]$badTask.ok) -and ([string]$badTask.reason -ceq 'invalid-taskid'))) '[I1] invalid task id refused' ([string]$badTask.reason)
        $badHash = New-OrchestrationDispatchIntent -TaskId 'nd-task-1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash 'segredo-em-texto' -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        Assert-ND (((-not [bool]$badHash.ok) -and ([string]$badHash.reason -ceq 'invalid-prompt-hash'))) '[I1] raw prompt text refused, hash only' ([string]$badHash.reason)
        $badCrit = New-OrchestrationDispatchIntent -TaskId 'nd-task-1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('done') -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        Assert-ND (((-not [bool]$badCrit.ok) -and ([string]$badCrit.reason -ceq 'invalid-acceptance-criteria'))) '[I1] non-criterion refs refused' ([string]$badCrit.reason)
        $good = New-OrchestrationDispatchIntent -TaskId 'nd-task-1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0', 'criterion:1') -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        Assert-ND ([bool]$good.ok) '[I1] valid intent built' ([string]$good.reason)
        Assert-ND (($null -eq $good.intent.PSObject.Properties['prompt'])) '[I1] intent carries no raw prompt field' ''
        Assert-ND (([string]$good.intent.idempotency_key -cmatch '^[a-f0-9]{32}$')) '[I1] idempotency key derived' ([string]$good.intent.idempotency_key)

        # ---------- Gate E: denied before effect ----------
        $state = @{ calls = 0 }
        $spy = { param($i) $state.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $authDeny = @{ explicit_allow = $false; goal_id = 'nd-goal-1'; owner = 'planner-1'; generation = $gen; source = 'planner' }
        $rDeny = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $spy -Authorization $authDeny -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rDeny.ok) -and (-not [bool]$rDeny.admitted) -and ([int]$rDeny.executor_calls -eq 0) -and ([int]$state.calls -eq 0))) '[E1] denied auth executes nothing' (([string]$rDeny.reason) + ' calls=' + [string]$state.calls)

        $authCb = @{ explicit_allow = $true; goal_id = 'nd-goal-1'; owner = 'planner-1'; generation = $gen; source = 'test-callback' }
        $rCb = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $spy -Authorization $authCb -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rCb.ok) -and ([string]$rCb.reason -ceq 'test-callback-never-authorizes-production') -and ([int]$state.calls -eq 0))) '[E2] TestCallback never authorizes production' ([string]$rCb.reason)

        $authRival = @{ explicit_allow = $true; goal_id = 'nd-goal-1'; owner = 'rival-9'; generation = $gen; source = 'planner' }
        $rRival = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $spy -Authorization $authRival -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rRival.ok) -and ([int]$state.calls -eq 0))) '[E3] fencing conflict executes nothing' ([string]$rRival.reason)

        # ---------- authorized executes exactly once ----------
        $rOk = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir
        Assert-ND (([bool]$rOk.admitted -and ([int]$rOk.executor_calls -eq 1) -and ([int]$state.calls -eq 1))) '[X1] authorized executes once' (([string]$rOk.reason) + ' kernel=' + [string]$rOk.kernel_reason)
        Assert-ND ((-not [bool]$rOk.duplicate)) '[X1] first dispatch is not a duplicate' ''
        Assert-ND (([bool]$rOk.evidence_created -and ([string]$rOk.evidence_id -cmatch '^[a-f0-9]{32}$'))) '[X1] evidence row persisted' ([string]$rOk.evidence_id)
        Assert-ND ((-not [string]::IsNullOrWhiteSpace([string]$rOk.kernel_reason))) '[X1] kernel verdict recorded fail-closed' ([string]$rOk.kernel_reason)

        # ---------- idempotency: repeat + concurrent-style retry ----------
        $rDup = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir
        Assert-ND (([bool]$rDup.duplicate -and ([int]$rDup.executor_calls -eq 0) -and ([int]$state.calls -eq 1))) '[D1] repeat key returns receipt, no re-execution' ('calls=' + [string]$state.calls)
        $rDup2 = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir
        Assert-ND (([bool]$rDup2.duplicate -and ([int]$state.calls -eq 1))) '[D1] concurrent retry never duplicates effect' ('calls=' + [string]$state.calls)

        # ---------- crash between receipt and execution reconciles ----------
        $crashKey = Get-NativeDispatchHash32 'crash-scenario-1'
        $crashSpec = New-NDSpec -Key $crashKey
        $crashIntent = New-OrchestrationDispatchIntent -TaskId $crashSpec.task_id -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $crashSpec.prompt_hash -Scope $crashSpec.scope -AcceptanceCriteria $crashSpec.acceptance_criteria -IdempotencyKey $crashKey -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        $stuck = [ordered]@{ schema_version = 1; idempotency_key = $crashKey; phase = 'pending'; task_id = 'nd-task-1'; agent = 'coder'; owner = 'planner-1'; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
        [IO.File]::WriteAllText((Join-Path $receiptDir ($crashKey + '.json')), (ConvertTo-Json -InputObject $stuck -Compress), [Text.UTF8Encoding]::new($false))
        $rCrash = Invoke-OrchestrationNativeDispatch -Intent $crashIntent.intent -Executor $spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir
        Assert-ND (([bool]$rCrash.reconciled -and ([int]$state.calls -eq 2))) '[D2] pending receipt reconciles with same key' ('reconciled=' + [string]$rCrash.reconciled + ' calls=' + [string]$state.calls)

        # ---------- result shape gate ----------
        $shapeKey = Get-NativeDispatchHash32 'shape-scenario-1'
        $shapeIntent = New-OrchestrationDispatchIntent -TaskId 'nd-task-2' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $shapeKey -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        $evil = { param($i) return @{ status = 'verified_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rEvil = Invoke-OrchestrationNativeDispatch -Intent $shapeIntent.intent -Executor $evil -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rEvil.ok) -and ([string]$rEvil.reason -ceq 'status-not-allowed-from-worker') -and ([string]$rEvil.kernel_reason -ceq 'result-shape-invalid'))) '[S1] verified_pass from worker rejected' ([string]$rEvil.reason)
        $doneEvil = { param($i) return @{ status = 'done'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $doneKey = Get-NativeDispatchHash32 'shape-scenario-2'
        $doneIntent = New-OrchestrationDispatchIntent -TaskId 'nd-task-3' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $doneKey -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        $rDone = Invoke-OrchestrationNativeDispatch -Intent $doneIntent.intent -Executor $doneEvil -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rDone.ok) -and ([string]$rDone.reason -ceq 'status-not-allowed-from-worker'))) '[S1] done from worker rejected' ([string]$rDone.reason)

        # ---------- hygiene ----------
        $ndPath = Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1'
        $ndText = [IO.File]::ReadAllText($ndPath, [Text.UTF8Encoding]::new($false))
        Assert-ND ((($ndText -notmatch 'Start-Process') -and ($ndText -notmatch 'Invoke-WebRequest') -and ($ndText -notmatch 'Invoke-RestMethod') -and ($ndText -notmatch 'HttpClient'))) '[NET] no spawn/network' ''
        Assert-ND (($ndText -notmatch '(?i)sk-[A-Za-z0-9]')) '[SEC] no secret value' ''
        foreach ($p in @($ndPath, (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.tests.ps1'))) {
            $bytes = [IO.File]::ReadAllBytes($p)
            $bad = 0
            foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
            Assert-ND ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
        }
    }
    finally {
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }

    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
}
catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message)
    $script:failed++
    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    exit 1
}
