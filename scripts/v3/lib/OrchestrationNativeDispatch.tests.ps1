<#!
.SYNOPSIS
    Tests for lib/OrchestrationNativeDispatch.ps1 (bridge honesto).
.DESCRIPTION
    Hermetic: temp dirs, cleanup in finally; repo tree never written.
    Bracketed output the runner parses. Exit 0 all pass, 1 any fail.
    PS 5.1 compatible. ASCII-only. No network, no spawn.
    Covers: Gate E (denied before effect, spy 0 calls), intent validation
    (no raw prompt), F1 live admission (unknown task refused, 0 calls),
    F2 post-lock fencing (stale token and non-ACTIVE refused, 0 calls),
    F3 pending-ambiguous + explicit reconciliation (no auto replay),
    F7 intent fingerprint collision, idempotency (repeat, flag replay),
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
    $tasksDir = Join-Path $tempRoot 'tasks'
    $flagsPath = Join-Path $tempRoot 'flags.json'
    New-Item -ItemType Directory -Path $goalDir -Force | Out-Null
    New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
    New-Item -ItemType Directory -Path $evDir -Force | Out-Null
    New-Item -ItemType Directory -Path $tasksDir -Force | Out-Null
    [IO.File]::WriteAllText($flagsPath, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))

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

        function New-NDKernelTask {
            param([string]$Id, [string]$Base = 'rev-a', [string[]]$Reads = @('src/a.ps1'))
            $c = New-OrchestrationTask -TaskId $Id -Objective ('obj ' + $Id) -TaskType 'implementation' `
                -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
                -RuntimeVersion '2.0.18' -BaseRevision $Base -ReadScopes $Reads -Grants @('fs.read') `
                -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $script:tasksDirText -FlagsPath $script:flagsPathText -TelemetryRoot $script:tempRootText
            Assert-ND ([bool]$c.ok) ('[F] kernel task created ' + $Id) ([string]$c.error)
            $slot = Get-OrchestrationGoal -GoalId 'nd-goal-1' -StoreDir $script:goalDirText
            $add = Add-OrchestrationGoalTaskPersisted -GoalId 'nd-goal-1' -TaskId $Id -ExpectedRevision ([long]$slot.goal['revision']) -StoreDir $script:goalDirText -OwnerId 'planner-1' -OwnershipGeneration $script:genText
            Assert-ND ([bool]$add.ok) ('[F] task attached to goal ' + $Id) ([string]$add.reason)
        }
        $script:phText = $ph
        $script:genText = $gen
        $script:tasksDirText = $tasksDir
        $script:flagsPathText = $flagsPath
        $script:tempRootText = $tempRoot
        $script:goalDirText = $goalDir

        function New-NDIntent {
            param([string]$Task = 'nd-task-1', [int]$Rev = 1, [string]$Agent = 'coder', [string[]]$Scope = @('src/a.ps1'), [string]$Key = '', [string]$Owner = 'planner-1', [long]$Gen = 0, [string]$Base = 'rev-a', [bool]$Ext = $false, [string]$Proof = '')
            $gg = $Gen
            if ($gg -lt 1) { $gg = $script:genText }
            return (New-OrchestrationDispatchIntent -TaskId $Task -TaskExpectedRevision $Rev -Agent $Agent -PromptHash $script:phText -Scope $Scope -AcceptanceCriteria @('criterion:0', 'criterion:1') -IdempotencyKey $Key -Owner $Owner -OwnershipGeneration $gg -BaseRevision $Base -ExternalIdempotent $Ext -ExternalIdempotencyProof $Proof)
        }

        New-NDKernelTask -Id 'nd-task-1'
        New-NDKernelTask -Id 'nd-task-2'
        New-NDKernelTask -Id 'nd-task-3'

        # ---------- intent validation ----------
        $badTask = New-OrchestrationDispatchIntent -TaskId 'BAD ID!!' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        Assert-ND (((-not [bool]$badTask.ok) -and ([string]$badTask.reason -ceq 'invalid-taskid'))) '[I1] invalid task id refused' ([string]$badTask.reason)
        $badHash = New-OrchestrationDispatchIntent -TaskId 'nd-task-1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash 'segredo-em-texto' -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        Assert-ND (((-not [bool]$badHash.ok) -and ([string]$badHash.reason -ceq 'invalid-prompt-hash'))) '[I1] raw prompt text refused, hash only' ([string]$badHash.reason)
        $badCrit = New-OrchestrationDispatchIntent -TaskId 'nd-task-1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('done') -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        Assert-ND (((-not [bool]$badCrit.ok) -and ([string]$badCrit.reason -ceq 'invalid-acceptance-criteria'))) '[I1] non-criterion refs refused' ([string]$badCrit.reason)
        $badProof = New-OrchestrationDispatchIntent -TaskId 'nd-task-1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a' -ExternalIdempotent $true
        Assert-ND (((-not [bool]$badProof.ok) -and ([string]$badProof.reason -ceq 'invalid-idempotency-proof'))) '[I1] external flag without proof refused' ([string]$badProof.reason)
        $good = New-NDIntent
        Assert-ND ([bool]$good.ok) '[I1] valid intent built' ([string]$good.reason)
        Assert-ND (($null -eq $good.intent.PSObject.Properties['prompt'])) '[I1] intent carries no raw prompt field' ''
        Assert-ND (([string]$good.intent.idempotency_key -cmatch '^[a-f0-9]{32}$')) '[I1] idempotency key derived' ([string]$good.intent.idempotency_key)

        # ---------- Gate E: denied before effect ----------
        $state = @{ calls = 0 }
        $spy = { param($i) $state.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $authDeny = @{ explicit_allow = $false; goal_id = 'nd-goal-1'; owner = 'planner-1'; generation = $gen; source = 'planner' }
        $rDeny = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $spy -Authorization $authDeny -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rDeny.ok) -and (-not [bool]$rDeny.admitted) -and ([int]$rDeny.executor_calls -eq 0) -and ([int]$state.calls -eq 0))) '[E1] denied auth executes nothing' (([string]$rDeny.reason) + ' calls=' + [string]$state.calls)

        $authCb = @{ explicit_allow = $true; goal_id = 'nd-goal-1'; owner = 'planner-1'; generation = $gen; source = 'test-callback' }
        $rCb = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $spy -Authorization $authCb -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rCb.ok) -and ([string]$rCb.reason -ceq 'test-callback-never-authorizes-production') -and ([int]$state.calls -eq 0))) '[E2] TestCallback never authorizes production' ([string]$rCb.reason)

        $authRival = @{ explicit_allow = $true; goal_id = 'nd-goal-1'; owner = 'rival-9'; generation = $gen; source = 'planner' }
        $rRival = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $spy -Authorization $authRival -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rRival.ok) -and ([int]$state.calls -eq 0))) '[E3] fencing conflict executes nothing' ([string]$rRival.reason)

        # ---------- F1: live admission before effect ----------
        $f1state = @{ calls = 0 }
        $f1spy = { param($i) $f1state.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $ghost = New-NDIntent -Task 'ghost-task-9'
        $rGhost = Invoke-OrchestrationNativeDispatch -Intent $ghost.intent -Executor $f1spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rGhost.ok) -and ([string]$rGhost.reason -ceq 'task-not-found') -and ([int]$rGhost.executor_calls -eq 0) -and ([int]$f1state.calls -eq 0))) '[F1] unknown task refused with 0 executor calls' ([string]$rGhost.reason)
        New-NDKernelTask -Id 'nd-task-revb' -Base 'rev-b'
        $wrongBase = New-NDIntent -Task 'nd-task-revb' -Base 'rev-a'
        $rBase = Invoke-OrchestrationNativeDispatch -Intent $wrongBase.intent -Executor $f1spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rBase.ok) -and ([string]$rBase.reason -ceq 'base-revision-mismatch') -and ([int]$f1state.calls -eq 0))) '[F1] base revision divergence refused' ([string]$rBase.reason)
        $wrongOwner = New-NDIntent -Owner 'rival-9'
        $rOwner = Invoke-OrchestrationNativeDispatch -Intent $wrongOwner.intent -Executor $f1spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rOwner.ok) -and ([string]$rOwner.reason -ceq 'owner-mismatch') -and ([int]$f1state.calls -eq 0))) '[F1] owner divergence refused' ([string]$rOwner.reason)
        $wrongGen = New-NDIntent -Gen ($gen + 1)
        $rGen = Invoke-OrchestrationNativeDispatch -Intent $wrongGen.intent -Executor $f1spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rGen.ok) -and ([string]$rGen.reason -ceq 'generation-mismatch') -and ([int]$f1state.calls -eq 0))) '[F1] generation divergence refused' ([string]$rGen.reason)
        $wrongRev = New-NDIntent -Rev 99
        $rRev = Invoke-OrchestrationNativeDispatch -Intent $wrongRev.intent -Executor $f1spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rRev.ok) -and ([string]$rRev.reason -ceq 'task-revision-mismatch') -and ([int]$f1state.calls -eq 0))) '[F1] expected revision divergence refused' ([string]$rRev.reason)
        $orphan = New-OrchestrationTask -TaskId 'orphan-task-1' -Objective 'obj orphan' -TaskType 'implementation' `
            -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
            -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
            -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-ND ([bool]$orphan.ok) '[F1] orphan kernel task created' ([string]$orphan.error)
        $orphanIntent = New-NDIntent -Task 'orphan-task-1'
        $rOrphan = Invoke-OrchestrationNativeDispatch -Intent $orphanIntent.intent -Executor $f1spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rOrphan.ok) -and ([string]$rOrphan.reason -ceq 'task-not-in-goal') -and ([int]$f1state.calls -eq 0))) '[F1] task outside the goal refused' ([string]$rOrphan.reason)
        $evilScope = New-NDIntent -Scope @('src/evil.ps1')
        $rScope = Invoke-OrchestrationNativeDispatch -Intent $evilScope.intent -Executor $f1spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rScope.ok) -and ([string]$rScope.reason -ceq 'scope-not-granted') -and ([int]$f1state.calls -eq 0))) '[F1] ungranted scope refused' ([string]$rScope.reason)
        $authScoped = @{ explicit_allow = $true; goal_id = 'nd-goal-1'; owner = 'planner-1'; generation = $gen; source = 'planner'; allowed_agents = @('coder') }
        $testerIntent = New-NDIntent -Agent 'tester'
        $rAgent = Invoke-OrchestrationNativeDispatch -Intent $testerIntent.intent -Executor $f1spy -Authorization $authScoped -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rAgent.ok) -and ([string]$rAgent.reason -ceq 'agent-not-granted') -and ([int]$f1state.calls -eq 0))) '[F1] ungranted agent refused' ([string]$rAgent.reason)

        # ---------- authorized executes exactly once ----------
        $rOk = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (([bool]$rOk.ok -and [bool]$rOk.admitted -and ([int]$rOk.executor_calls -eq 1) -and ([int]$state.calls -eq 1))) '[X1] authorized executes once' (([string]$rOk.reason) + ' kernel=' + [string]$rOk.kernel_reason)
        Assert-ND ((-not [bool]$rOk.duplicate)) '[X1] first dispatch is not a duplicate' ''
        Assert-ND (([bool]$rOk.evidence_created -and ([string]$rOk.evidence_id -cmatch '^[a-f0-9]{32}$'))) '[X1] evidence row persisted' ([string]$rOk.evidence_id)
        Assert-ND ([bool]$rOk.kernel_ok) '[X1] kernel accepted the worker result' ([string]$rOk.kernel_reason)
        $fpFile = Join-Path $receiptDir (([string]$good.intent.idempotency_key) + '.json')
        $fpRec = ConvertFrom-Json ([IO.File]::ReadAllText($fpFile, [Text.Encoding]::UTF8))
        Assert-ND (([string]$fpRec.intent_fingerprint -cmatch '^[a-f0-9]{32}$')) '[F7] receipt binds the canonical intent fingerprint' ([string]$fpRec.intent_fingerprint)

        # ---------- idempotency: repeat returns receipt, no re-execution ----------
        $rDup = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (([bool]$rDup.duplicate -and ([int]$rDup.executor_calls -eq 0) -and ([int]$state.calls -eq 1))) '[D1] repeat key returns receipt, no re-execution' ('calls=' + [string]$state.calls)

        # ---------- F7: same key, divergent intent is a collision ----------
        $evilKey = ([string]$good.intent.idempotency_key)
        $collide = New-NDIntent -Task 'nd-task-2' -Key $evilKey
        Assert-ND ([bool]$collide.ok) '[F7] divergent intent with same key builds' ([string]$collide.reason)
        $cstate = @{ calls = 0 }
        $cspy = { param($i) $cstate.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rCollide = Invoke-OrchestrationNativeDispatch -Intent $collide.intent -Executor $cspy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rCollide.ok) -and ([string]$rCollide.reason -ceq 'idempotency-key-collision') -and ([int]$cstate.calls -eq 0))) '[F7] same key with divergent intent refused, result never reused' ([string]$rCollide.reason)

        # ---------- F3: pending of an uncertain prior run never auto-replays ----------
        New-NDKernelTask -Id 'nd-task-crash1'
        $crashKey = Get-NativeDispatchHash32 'crash-scenario-1'
        $crashIntent = New-NDIntent -Task 'nd-task-crash1' -Key $crashKey
        $crashFp = Get-NDIntentFingerprint -Intent $crashIntent.intent
        $stuck = [ordered]@{ schema_version = 1; idempotency_key = $crashKey; phase = 'pending'; task_id = 'nd-task-crash1'; agent = 'coder'; owner = 'planner-1'; goal_id = 'nd-goal-1'; ownership_generation = $gen; task_expected_revision = 1; intent_fingerprint = $crashFp; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
        [IO.File]::WriteAllText((Join-Path $receiptDir ($crashKey + '.json')), (ConvertTo-Json -InputObject $stuck -Compress), [Text.UTF8Encoding]::new($false))
        $crashState = @{ calls = 0 }
        $crashSpy = { param($i) $crashState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rCrash = Invoke-OrchestrationNativeDispatch -Intent $crashIntent.intent -Executor $crashSpy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rCrash.ok) -and ([string]$rCrash.reason -ceq 'pending-ambiguous') -and ([int]$crashState.calls -eq 0))) '[F3] crash-after-effect pending never replays without reconciliation' ('reason=' + [string]$rCrash.reason + ' calls=' + [string]$crashState.calls)
        # R3: prova honesta externa - escrita real no kernel + evidence
        # real no store; booleans declarados nunca sao prova.
        $kext = Set-OrchestrationTaskWorkerResult -TaskId 'nd-task-crash1' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-ND ([bool]$kext.ok) '[F3] external kernel write landed' ([string]$kext.error)
        $evInput = [ordered]@{
            task_id = 'nd-task-crash1'; run_id = $crashKey; worker_id = 'coder'
            provenance = @{ created_by = 'coder'; kernel_task_ref = 'nd-task-crash1' }
            base_revision = 'rev-a'; criteria_hash = 'crit-a'
            source_fingerprints = @{ 'dispatch-intent' = $crashKey }
            diff_hash = ''; scope = @('src/a.ps1'); command = 'native-dispatch'
            environment = @{ runtime = 'native-dispatch'; version = '1' }
            result = @{ summary = 'worker:candidate_pass'; raw_ref = '' }
            assumptions = @()
            invalidation_conditions = @(
                @{ type = 'base-revision'; require_same = $true }
            )
            created_at = ([DateTime]::UtcNow.ToString('o'))
        }
        $evMade = New-OrchestrationEvidenceRecord -Evidence $evInput -StoreDir $evDir
        Assert-ND ([bool]$evMade.created) '[F3] external evidence recorded' ([string]$evMade.reason)
        $evIdExt = ([string]$evMade.record.evidence_id)
        $outcome = @{ ok = $true; reason = 'effect-verified-externally'; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; kernel_ok = $true; kernel_reason = 'externally-confirmed'; evidence_created = $true; evidence_id = $evIdExt }
        $rRec = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey $crashKey -Outcome $outcome -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
        Assert-ND (([bool]$rRec.ok -and [bool]$rRec.reconciled -and ([int]$crashState.calls -eq 0))) '[F3] explicit reconciliation settles without a second effect' ([string]$rRec.reason)
        $rAfter = Invoke-OrchestrationNativeDispatch -Intent $crashIntent.intent -Executor $crashSpy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (([bool]$rAfter.duplicate -and ([int]$crashState.calls -eq 0))) '[F3] reconciled receipt is idempotent afterwards' ('calls=' + [string]$crashState.calls)

        # ---------- F3: declared external idempotence allows replay with same key ----------
        New-NDKernelTask -Id 'nd-task-crash2'
        $idemKey = Get-NativeDispatchHash32 'idempotent-sink-1'
        $idemIntent = New-NDIntent -Task 'nd-task-crash2' -Key $idemKey -Ext $true -Proof 'sink dedupes by idempotency key (test)'
        Assert-ND ([bool]$idemIntent.ok) '[F3] idempotent intent builds with proof' ([string]$idemIntent.reason)
        $idemFp = Get-NDIntentFingerprint -Intent $idemIntent.intent
        $stuck2 = [ordered]@{ schema_version = 1; idempotency_key = $idemKey; phase = 'pending'; task_id = 'nd-task-crash2'; agent = 'coder'; owner = 'planner-1'; goal_id = 'nd-goal-1'; ownership_generation = $gen; task_expected_revision = 1; intent_fingerprint = $idemFp; external_idempotent = $true; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
        [IO.File]::WriteAllText((Join-Path $receiptDir ($idemKey + '.json')), (ConvertTo-Json -InputObject $stuck2 -Compress), [Text.UTF8Encoding]::new($false))
        $idemState = @{ calls = 0 }
        $idemSpy = { param($i) $idemState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rIdem = Invoke-OrchestrationNativeDispatch -Intent $idemIntent.intent -Executor $idemSpy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (([bool]$rIdem.reconciled -and ([int]$idemState.calls -eq 1))) '[F3] declared idempotent replay reconciles with same key' ('reconciled=' + [string]$rIdem.reconciled + ' calls=' + [string]$idemState.calls)
        $rIdemDup = Invoke-OrchestrationNativeDispatch -Intent $idemIntent.intent -Executor $idemSpy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (([bool]$rIdemDup.duplicate -and ([int]$idemState.calls -eq 1))) '[F3] replayed receipt never duplicates again' ('calls=' + [string]$idemState.calls)

        # ---------- F2: post-lock fencing ----------
        $postOk = Test-NDPostLockFencing -GoalId 'nd-goal-1' -Owner 'planner-1' -Generation $gen -GoalStoreDir $goalDir
        Assert-ND ([bool]$postOk.ok) '[F2] live fencing token passes post-lock' ([string]$postOk.reason)
        $postStale = Test-NDPostLockFencing -GoalId 'nd-goal-1' -Owner 'planner-1' -Generation ($gen + 99) -GoalStoreDir $goalDir
        Assert-ND (((-not [bool]$postStale.ok) -and ([string]$postStale.reason -like 'post-lock-fencing-changed*'))) '[F2] taken-over generation fails post-lock' ([string]$postStale.reason)
        $g2 = New-OrchestrationGoal -GoalId 'nd-goal-2' -Objective 'fencing nao ativa' -Criteria @('criterio-a') -StoreDir $goalDir
        $a2 = Set-OrchestrationGoalState -Goal $g2.goal -ToState 'ACTIVE'
        $s2 = Save-OrchestrationGoal -Goal $a2.goal -StoreDir $goalDir
        $o2 = Acquire-OrchestrationGoalOwnership -GoalId 'nd-goal-2' -OwnerId 'planner-1' -ExpectedRevision ([long]$s2.revision) -StoreDir $goalDir
        $gen2 = [long]$o2.ownership['generation']
        $t2 = New-OrchestrationTask -TaskId 'nd2-task-1' -Objective 'obj nd2' -TaskType 'implementation' `
            -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
            -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
            -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-ND ([bool]$t2.ok) '[F2] second goal task created' ([string]$t2.error)
        $slot2 = Get-OrchestrationGoal -GoalId 'nd-goal-2' -StoreDir $goalDir
        $add2 = Add-OrchestrationGoalTaskPersisted -GoalId 'nd-goal-2' -TaskId 'nd2-task-1' -ExpectedRevision ([long]$slot2.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen2
        Assert-ND ([bool]$add2.ok) '[F2] second goal task attached' ([string]$add2.reason)
        $live2 = Get-OrchestrationGoal -GoalId 'nd-goal-2' -StoreDir $goalDir
        $pz = Set-OrchestrationGoalStatePersisted -GoalId 'nd-goal-2' -ToState 'PAUSED' -ExpectedRevision ([long]$live2.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $gen2
        Assert-ND ([bool]$pz.ok) '[F2] second goal paused' ([string]$pz.reason)
        $auth2 = @{ explicit_allow = $true; goal_id = 'nd-goal-2'; owner = 'planner-1'; generation = $gen2; source = 'planner' }
        $pausedIntent = New-OrchestrationDispatchIntent -TaskId 'nd2-task-1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -Owner 'planner-1' -OwnershipGeneration $gen2 -BaseRevision 'rev-a'
        $pstate = @{ calls = 0 }
        $pspy = { param($i) $pstate.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rPaused = Invoke-OrchestrationNativeDispatch -Intent $pausedIntent.intent -Executor $pspy -Authorization $auth2 -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rPaused.ok) -and ([string]$rPaused.reason -like 'post-lock-goal-not-active*') -and ([int]$pstate.calls -eq 0))) '[F2] goal out of ACTIVE refuses before effect' ([string]$rPaused.reason)

        # ---------- result shape gate ----------
        $shapeKey = Get-NativeDispatchHash32 'shape-scenario-1'
        $shapeIntent = New-OrchestrationDispatchIntent -TaskId 'nd-task-2' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $shapeKey -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        $evil = { param($i) return @{ status = 'verified_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rEvil = Invoke-OrchestrationNativeDispatch -Intent $shapeIntent.intent -Executor $evil -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rEvil.ok) -and ([string]$rEvil.reason -ceq 'status-not-allowed-from-worker') -and ([string]$rEvil.kernel_reason -ceq 'result-shape-invalid'))) '[S1] verified_pass from worker rejected' ([string]$rEvil.reason)
        $doneEvil = { param($i) return @{ status = 'done'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $doneKey = Get-NativeDispatchHash32 'shape-scenario-2'
        $doneIntent = New-OrchestrationDispatchIntent -TaskId 'nd-task-3' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $doneKey -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        $rDone = Invoke-OrchestrationNativeDispatch -Intent $doneIntent.intent -Executor $doneEvil -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rDone.ok) -and ([string]$rDone.reason -ceq 'status-not-allowed-from-worker'))) '[S1] done from worker rejected' ([string]$rDone.reason)

        # ---------- R1: kernel OFF + task existente recusa com 0 calls ----------
        $flagsOff = Join-Path $tempRoot 'flags-off.json'
        [IO.File]::WriteAllText($flagsOff, '{"task_kernel":{"enabled":false,"shadow":false}}', [Text.UTF8Encoding]::new($false))
        New-NDKernelTask -Id 'nd-task-off1'
        $offIntent = New-NDIntent -Task 'nd-task-off1'
        $offState = @{ calls = 0 }
        $offSpy = { param($i) $offState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rOff = Invoke-OrchestrationNativeDispatch -Intent $offIntent.intent -Executor $offSpy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsOff
        Assert-ND (((-not [bool]$rOff.ok) -and ([string]$rOff.reason -ceq 'taskkernel-disabled') -and ([int]$rOff.executor_calls -eq 0) -and ([int]$offState.calls -eq 0))) '[R1] kernel OFF with pre-created task refuses with 0 calls' ([string]$rOff.reason)

        # ---------- R2: fingerprint canonico cobre todos os campos semanticos ----------
        $fpOrd1 = Get-NDIntentFingerprint -Intent (New-NDIntent -Scope @('src/a.ps1', 'src/b.ps1')).intent
        $fpOrd2 = Get-NDIntentFingerprint -Intent (New-NDIntent -Scope @('src/b.ps1', 'src/a.ps1')).intent
        Assert-ND (($fpOrd1 -ceq $fpOrd2)) '[R2] scope order is canonical, same fingerprint' ($fpOrd1 + ' vs ' + $fpOrd2)
        $fpAgent = Get-NDIntentFingerprint -Intent (New-NDIntent -Agent 'tester').intent
        Assert-ND (($fpOrd1 -cne $fpAgent) -and ($fpAgent -cmatch '^[a-f0-9]{32}$')) '[R2] agent divergence changes the fingerprint' ([string]$fpAgent)
        $fpExtA = Get-NDIntentFingerprint -Intent (New-NDIntent).intent
        $fpExtB = Get-NDIntentFingerprint -Intent (New-NDIntent -Ext $true -Proof 'sink dedupes (test)').intent
        Assert-ND (($fpExtA -cne $fpExtB)) '[R2] external idempotence declaration changes the fingerprint' ''
        # R2: upgrade de idempotencia via novo Intent = colisao recusada
        $upKey = Get-NativeDispatchHash32 'ext-upgrade-1'
        $baseA = New-NDIntent -Task 'nd-task-2' -Key $upKey
        $fpUpA = Get-NDIntentFingerprint -Intent $baseA.intent
        $stuckUp = [ordered]@{ schema_version = 1; idempotency_key = $upKey; phase = 'pending'; task_id = 'nd-task-2'; agent = 'coder'; owner = 'planner-1'; goal_id = 'nd-goal-1'; ownership_generation = $gen; task_expected_revision = 1; intent_fingerprint = $fpUpA; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
        [IO.File]::WriteAllText((Join-Path $receiptDir ($upKey + '.json')), (ConvertTo-Json -InputObject $stuckUp -Compress), [Text.UTF8Encoding]::new($false))
        $upB = New-NDIntent -Task 'nd-task-2' -Key $upKey -Ext $true -Proof 'sink dedupes (test)'
        $upState = @{ calls = 0 }
        $upSpy = { param($i) $upState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rUp = Invoke-OrchestrationNativeDispatch -Intent $upB.intent -Executor $upSpy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rUp.ok) -and ([string]$rUp.reason -ceq 'idempotency-key-collision') -and ([int]$upState.calls -eq 0))) '[R2] idempotence upgrade via new Intent is a refused collision' ([string]$rUp.reason)

        # ---------- R3: reconciliacao confere identidade; sucesso exige prova kernel-side ----------
        $xg = New-OrchestrationGoal -GoalId 'nd-goal-3' -Objective 'terceiro goal' -Criteria @('criterio-a') -StoreDir $goalDir
        $axg = Set-OrchestrationGoalState -Goal $xg.goal -ToState 'ACTIVE'
        $sxg = Save-OrchestrationGoal -Goal $axg.goal -StoreDir $goalDir
        $oxg = Acquire-OrchestrationGoalOwnership -GoalId 'nd-goal-3' -OwnerId 'planner-9' -ExpectedRevision ([long]$sxg.revision) -StoreDir $goalDir
        Assert-ND ([bool]$oxg.ok) '[R3] third goal owned' ([string]$oxg.reason)
        $genx = [long]$oxg.ownership['generation']
        $authX = @{ explicit_allow = $true; goal_id = 'nd-goal-3'; owner = 'planner-9'; generation = $genx; source = 'planner' }
        New-NDKernelTask -Id 'nd-task-xgoal'
        $xgKey = Get-NativeDispatchHash32 'xgoal-scenario-1'
        $xgIntent = New-NDIntent -Task 'nd-task-xgoal' -Key $xgKey
        $xgFp = Get-NDIntentFingerprint -Intent $xgIntent.intent
        $stuckXg = [ordered]@{ schema_version = 1; idempotency_key = $xgKey; phase = 'pending'; task_id = 'nd-task-xgoal'; agent = 'coder'; owner = 'planner-1'; goal_id = 'nd-goal-1'; ownership_generation = $gen; task_expected_revision = 1; intent_fingerprint = $xgFp; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
        [IO.File]::WriteAllText((Join-Path $receiptDir ($xgKey + '.json')), (ConvertTo-Json -InputObject $stuckXg -Compress), [Text.UTF8Encoding]::new($false))
        $xgOutcome = @{ ok = $true; reason = 'claimed-elsewhere'; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; kernel_ok = $true; kernel_reason = 'claimed'; evidence_created = $true; evidence_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
        $rXg = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey $xgKey -Outcome $xgOutcome -Authorization $authX -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rXg.ok) -and ([string]$rXg.reason -ceq 'reconcile-identity-mismatch'))) '[R3] cross-goal reconciliation refused' ([string]$rXg.reason)
        # R3: outcome inventado (sem escrita no kernel, evidence inexistente) recusado
        $invOutcome = @{ ok = $true; reason = 'invented'; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; kernel_ok = $true; kernel_reason = 'invented'; evidence_created = $true; evidence_id = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
        $rInv = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey $xgKey -Outcome $invOutcome -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rInv.ok) -and ([string]$rInv.reason -ceq 'reconcile-unverifiable'))) '[R3] invented outcome refused without kernel-side proof' ([string]$rInv.reason)
        $stillPending = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $receiptDir ($xgKey + '.json')), [Text.Encoding]::UTF8))
        Assert-ND (([string]$stillPending.phase -ceq 'pending')) '[R3] refused reconciliation leaves the receipt pending' ([string]$stillPending.phase)
        # R3: takeover reconcilia com prova kernel-side + autorizacao viva do goal atual
        $tk = New-OrchestrationGoal -GoalId 'nd-goal-take' -Objective 'takeover' -Criteria @('criterio-a') -StoreDir $goalDir
        $atk = Set-OrchestrationGoalState -Goal $tk.goal -ToState 'ACTIVE'
        $stk = Save-OrchestrationGoal -Goal $atk.goal -StoreDir $goalDir
        $otk = Acquire-OrchestrationGoalOwnership -GoalId 'nd-goal-take' -OwnerId 'planner-1' -ExpectedRevision ([long]$stk.revision) -StoreDir $goalDir -LeaseTtlMs 500
        Assert-ND ([bool]$otk.ok) '[R3] takeover goal owned with short lease' ([string]$otk.reason)
        $genTk = [long]$otk.ownership['generation']
        $ctk = New-OrchestrationTask -TaskId 'nd-task-take1' -Objective 'obj take1' -TaskType 'implementation' `
            -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
            -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
            -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-ND ([bool]$ctk.ok) '[R3] takeover kernel task created' ([string]$ctk.error)
        $slotTk = Get-OrchestrationGoal -GoalId 'nd-goal-take' -StoreDir $goalDir
        $addTk = Add-OrchestrationGoalTaskPersisted -GoalId 'nd-goal-take' -TaskId 'nd-task-take1' -ExpectedRevision ([long]$slotTk.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $genTk
        Assert-ND ([bool]$addTk.ok) '[R3] takeover task attached' ([string]$addTk.reason)
        $tkKey = Get-NativeDispatchHash32 'takeover-scenario-1'
        $tkIntent = New-OrchestrationDispatchIntent -TaskId 'nd-task-take1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0', 'criterion:1') -IdempotencyKey $tkKey -Owner 'planner-1' -OwnershipGeneration $genTk -BaseRevision 'rev-a'
        $tkFp = Get-NDIntentFingerprint -Intent $tkIntent.intent
        $stuckTk = [ordered]@{ schema_version = 1; idempotency_key = $tkKey; phase = 'pending'; task_id = 'nd-task-take1'; agent = 'coder'; owner = 'planner-1'; goal_id = 'nd-goal-take'; ownership_generation = $genTk; task_expected_revision = 1; intent_fingerprint = $tkFp; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
        [IO.File]::WriteAllText((Join-Path $receiptDir ($tkKey + '.json')), (ConvertTo-Json -InputObject $stuckTk -Compress), [Text.UTF8Encoding]::new($false))
        Start-Sleep -Milliseconds 1200
        $tow = Takeover-OrchestrationGoalOwnership -GoalId 'nd-goal-take' -OwnerId 'planner-2' -StoreDir $goalDir -LeaseTtlMs 60000
        Assert-ND ([bool]$tow.ok) '[R3] ownership taken over after provable expiry' ([string]$tow.reason)
        $genTk2 = [long]$tow.ownership['generation']
        $authTk2 = @{ explicit_allow = $true; goal_id = 'nd-goal-take'; owner = 'planner-2'; generation = $genTk2; source = 'planner' }
        $ktk = Set-OrchestrationTaskWorkerResult -TaskId 'nd-task-take1' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-ND ([bool]$ktk.ok) '[R3] takeover external kernel write landed' ([string]$ktk.error)
        $evTkInput = [ordered]@{
            task_id = 'nd-task-take1'; run_id = $tkKey; worker_id = 'coder'
            provenance = @{ created_by = 'coder'; kernel_task_ref = 'nd-task-take1' }
            base_revision = 'rev-a'; criteria_hash = 'crit-a'
            source_fingerprints = @{ 'dispatch-intent' = $tkKey }
            diff_hash = ''; scope = @('src/a.ps1'); command = 'native-dispatch'
            environment = @{ runtime = 'native-dispatch'; version = '1' }
            result = @{ summary = 'worker:candidate_pass'; raw_ref = '' }
            assumptions = @()
            invalidation_conditions = @(
                @{ type = 'base-revision'; require_same = $true }
            )
            created_at = ([DateTime]::UtcNow.ToString('o'))
        }
        $evTk = New-OrchestrationEvidenceRecord -Evidence $evTkInput -StoreDir $evDir
        Assert-ND ([bool]$evTk.created) '[R3] takeover external evidence recorded' ([string]$evTk.reason)
        $tkOutcome = @{ ok = $true; reason = 'takeover-verified-externally'; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; kernel_ok = $true; kernel_reason = 'externally-confirmed'; evidence_created = $true; evidence_id = ([string]$evTk.record.evidence_id) }
        $rTk = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey $tkKey -Outcome $tkOutcome -Authorization $authTk2 -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
        Assert-ND (([bool]$rTk.ok -and [bool]$rTk.reconciled)) '[R3] new owner reconciles with kernel-side proof and live authorization' ([string]$rTk.reason)

        # ---------- R6: efeito executado e contabilizado mesmo quando falha ----------
        New-NDKernelTask -Id 'nd-task-throw'
        $throwKey = Get-NativeDispatchHash32 'throw-scenario-1'
        $throwIntent = New-NDIntent -Task 'nd-task-throw' -Key $throwKey
        $thrower = { param($i) throw 'boom-pos-efeito' }.GetNewClosure()
        $rThrow = Invoke-OrchestrationNativeDispatch -Intent $throwIntent.intent -Executor $thrower -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rThrow.ok) -and ([string]$rThrow.reason -ceq 'executor-failed') -and ([int]$rThrow.executor_calls -eq 1))) '[R6] post-effect exception reports the occurred effect' (([string]$rThrow.reason) + ' calls=' + [string]$rThrow.executor_calls)
        New-NDKernelTask -Id 'nd-task-kconf'
        $kconfKey = Get-NativeDispatchHash32 'kconf-scenario-1'
        $kconfIntent = New-NDIntent -Task 'nd-task-kconf' -Key $kconfKey
        $kconfTasks = $tasksDir
        $kconfFlags = $flagsPath
        $kconfRoot = $tempRoot
        $kconfSpy = {
            param($i)
            $w = Set-OrchestrationTaskWorkerResult -TaskId 'nd-task-kconf' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $kconfTasks -FlagsPath $kconfFlags -TelemetryRoot $kconfRoot
            return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }
        }.GetNewClosure()
        $rKconf = Invoke-OrchestrationNativeDispatch -Intent $kconfIntent.intent -Executor $kconfSpy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rKconf.ok) -and ([string]$rKconf.reason -like 'kernel:CAS_CONFLICT') -and ([int]$rKconf.executor_calls -eq 1))) '[R6] kernel/persistence failure accounts the executed effect' (([string]$rKconf.reason) + ' calls=' + [string]$rKconf.executor_calls)

        # ---------- hygiene ----------
        $ndPath = Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1'
        $ndText = [IO.File]::ReadAllText($ndPath, [Text.UTF8Encoding]::new($false))
        Assert-ND ((($ndText -notmatch 'Start-Process') -and ($ndText -notmatch 'Invoke-WebRequest') -and ($ndText -notmatch 'Invoke-RestMethod') -and ($ndText -notmatch 'HttpClient'))) '[NET] no spawn/network' ''
        Assert-ND (($ndText -notmatch '(?i)\bsk-[A-Za-z0-9]{20,}')) '[SEC] no secret value' ''
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
