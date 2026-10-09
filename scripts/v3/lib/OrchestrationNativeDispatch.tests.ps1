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
        function New-NDReceiptPath {
            param([string]$GoalId, [string]$Key)
            try {
                # F3/REV5: recibos isolados por goal autorizado.
                $sub = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId $GoalId
                return (Join-Path $sub ($Key + '.json'))
            }
            catch { return (Join-Path $receiptDir ($Key + '.json')) }
        }


        function New-NDIntent {
            param([string]$Task = 'nd-task-1', [int]$Rev = 1, [string]$Agent = 'coder', [string[]]$Scope = @('src/a.ps1'), [string]$Key = '', [string]$Owner = 'planner-1', [long]$Gen = 0, [string]$Base = 'rev-a', [bool]$Ext = $false, [string]$Proof = '')
            $gg = $Gen
            if ($gg -lt 1) { $gg = $script:genText }
            return (New-OrchestrationNativeDispatchIntent -TaskId $Task -TaskExpectedRevision $Rev -Agent $Agent -PromptHash $script:phText -Scope $Scope -AcceptanceCriteria @('criterion:0', 'criterion:1') -IdempotencyKey $Key -Owner $Owner -OwnershipGeneration $gg -BaseRevision $Base -ExternalIdempotent $Ext -ExternalIdempotencyProof $Proof)
        }

        New-NDKernelTask -Id 'nd-task-1'
        New-NDKernelTask -Id 'nd-task-2'
        New-NDKernelTask -Id 'nd-task-3'

        # ---------- intent validation ----------
        $badTask = New-OrchestrationNativeDispatchIntent -TaskId 'BAD ID!!' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        Assert-ND (((-not [bool]$badTask.ok) -and ([string]$badTask.reason -ceq 'invalid-taskid'))) '[I1] invalid task id refused' ([string]$badTask.reason)
        $badHash = New-OrchestrationNativeDispatchIntent -TaskId 'nd-task-1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash 'segredo-em-texto' -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        Assert-ND (((-not [bool]$badHash.ok) -and ([string]$badHash.reason -ceq 'invalid-prompt-hash'))) '[I1] raw prompt text refused, hash only' ([string]$badHash.reason)
        $badCrit = New-OrchestrationNativeDispatchIntent -TaskId 'nd-task-1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('done') -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        Assert-ND (((-not [bool]$badCrit.ok) -and ([string]$badCrit.reason -ceq 'invalid-acceptance-criteria'))) '[I1] non-criterion refs refused' ([string]$badCrit.reason)
        $badProof = New-OrchestrationNativeDispatchIntent -TaskId 'nd-task-1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a' -ExternalIdempotent $true
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
        $fpFile = (New-NDReceiptPath -GoalId 'nd-goal-1' -Key (([string]$good.intent.idempotency_key)))
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
        # R4/SEC4: razao unica; a comparacao campo a campo com a recusa
        # por identidade fica em OrchestrationNativeDispatchEnvelopes.tests.ps1.
        Assert-ND (((-not [bool]$rCollide.ok) -and ([string]$rCollide.reason -ceq 'duplicate-identity-mismatch') -and ([int]$cstate.calls -eq 0))) '[F7] same key with divergent intent refused, result never reused' ([string]$rCollide.reason)
        Assert-ND (($null -eq $rCollide.worker_result)) '[F7] refused collision leaks no worker result' ''

        # ---------- F3: pending of an uncertain prior run never auto-replays ----------
        New-NDKernelTask -Id 'nd-task-crash1'
        $crashKey = Get-NativeDispatchHash32 'crash-scenario-1'
        $crashIntent = New-NDIntent -Task 'nd-task-crash1' -Key $crashKey
        $crashFp = Get-NDIntentFingerprint -Intent $crashIntent.intent
        $stuck = [ordered]@{ schema_version = 1; idempotency_key = $crashKey; phase = 'pending'; task_id = 'nd-task-crash1'; agent = 'coder'; owner = 'planner-1'; goal_id = 'nd-goal-1'; ownership_generation = $gen; task_expected_revision = 1; intent_fingerprint = $crashFp; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
        [IO.File]::WriteAllText(((New-NDReceiptPath -GoalId 'nd-goal-1' -Key $crashKey)), (ConvertTo-Json -InputObject $stuck -Compress), [Text.UTF8Encoding]::new($false))
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
        [IO.File]::WriteAllText(((New-NDReceiptPath -GoalId 'nd-goal-1' -Key $idemKey)), (ConvertTo-Json -InputObject $stuck2 -Compress), [Text.UTF8Encoding]::new($false))
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
        $pausedIntent = New-OrchestrationNativeDispatchIntent -TaskId 'nd2-task-1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -Owner 'planner-1' -OwnershipGeneration $gen2 -BaseRevision 'rev-a'
        $pstate = @{ calls = 0 }
        $pspy = { param($i) $pstate.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rPaused = Invoke-OrchestrationNativeDispatch -Intent $pausedIntent.intent -Executor $pspy -Authorization $auth2 -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rPaused.ok) -and ([string]$rPaused.reason -like 'post-lock-goal-not-active*') -and ([int]$pstate.calls -eq 0))) '[F2] goal out of ACTIVE refuses before effect' ([string]$rPaused.reason)

        # ---------- result shape gate ----------
        $shapeKey = Get-NativeDispatchHash32 'shape-scenario-1'
        $shapeIntent = New-OrchestrationNativeDispatchIntent -TaskId 'nd-task-2' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $shapeKey -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
        $evil = { param($i) return @{ status = 'verified_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rEvil = Invoke-OrchestrationNativeDispatch -Intent $shapeIntent.intent -Executor $evil -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rEvil.ok) -and ([string]$rEvil.reason -ceq 'status-not-allowed-from-worker') -and ([string]$rEvil.kernel_reason -ceq 'result-shape-invalid'))) '[S1] verified_pass from worker rejected' ([string]$rEvil.reason)
        $doneEvil = { param($i) return @{ status = 'done'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $doneKey = Get-NativeDispatchHash32 'shape-scenario-2'
        $doneIntent = New-OrchestrationNativeDispatchIntent -TaskId 'nd-task-3' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $doneKey -Owner 'planner-1' -OwnershipGeneration $gen -BaseRevision 'rev-a'
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
        [IO.File]::WriteAllText(((New-NDReceiptPath -GoalId 'nd-goal-1' -Key $upKey)), (ConvertTo-Json -InputObject $stuckUp -Compress), [Text.UTF8Encoding]::new($false))
        $upB = New-NDIntent -Task 'nd-task-2' -Key $upKey -Ext $true -Proof 'sink dedupes (test)'
        $upState = @{ calls = 0 }
        $upSpy = { param($i) $upState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rUp = Invoke-OrchestrationNativeDispatch -Intent $upB.intent -Executor $upSpy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        # R4/SEC4: recibo existente nao utilizavel por este chamador usa
        # razao UNICA (identidade antes do fingerprint), sem revelar qual
        # das duas conferencias falhou.
        Assert-ND (((-not [bool]$rUp.ok) -and ([string]$rUp.reason -ceq 'duplicate-identity-mismatch') -and ([int]$upState.calls -eq 0))) '[R2] idempotence upgrade via new Intent is a refused collision' ([string]$rUp.reason)

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
        [IO.File]::WriteAllText(((New-NDReceiptPath -GoalId 'nd-goal-1' -Key $xgKey)), (ConvertTo-Json -InputObject $stuckXg -Compress), [Text.UTF8Encoding]::new($false))
        $xgOutcome = @{ ok = $true; reason = 'claimed-elsewhere'; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; kernel_ok = $true; kernel_reason = 'claimed'; evidence_created = $true; evidence_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
        # F3/REV5: recibos isolados por goal. O Confirm do goal B resolve
        # o caminho do PROPRIO goal, que nao contem a key de A: a resposta
        # e receipt-not-found, generica, igual a de uma key inexistente.
        # Nao ha oraculo de existencia cross-goal e nenhum conteudo vaza.
        $rXg = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey $xgKey -Outcome $xgOutcome -Authorization $authX -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rXg.ok) -and ([string]$rXg.reason -ceq 'receipt-not-found') -and ([int]$rXg.executor_calls -eq 0) -and ($null -eq $rXg.worker_result) -and ([string]$rXg.evidence_id -ceq ''))) '[F3] cross-goal reconciliation sees the receipt as absent' ([string]$rXg.reason)
        $absentXgOutcome = @{ ok = $false; reason = 'outer-failure-apurada'; kernel_reason = 'outer-failure' }
        $rXgAbsent = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey (Get-NativeDispatchHash32 'xgoal-absent-1') -Outcome $absentXgOutcome -Authorization $authX -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rXgAbsent.ok) -and ([string]$rXgAbsent.reason -ceq 'receipt-not-found'))) '[F3] truly absent key refuses the same way' ([string]$rXgAbsent.reason)
        # R3: outcome inventado (sem escrita no kernel, evidence inexistente) recusado
        $invOutcome = @{ ok = $true; reason = 'invented'; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; kernel_ok = $true; kernel_reason = 'invented'; evidence_created = $true; evidence_id = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
        $rInv = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey $xgKey -Outcome $invOutcome -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rInv.ok) -and ([string]$rInv.reason -ceq 'reconcile-unverifiable'))) '[R3] invented outcome refused without kernel-side proof' ([string]$rInv.reason)
        $stillPending = ConvertFrom-Json ([IO.File]::ReadAllText(((New-NDReceiptPath -GoalId 'nd-goal-1' -Key $xgKey)), [Text.Encoding]::UTF8))
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
        $tkIntent = New-OrchestrationNativeDispatchIntent -TaskId 'nd-task-take1' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0', 'criterion:1') -IdempotencyKey $tkKey -Owner 'planner-1' -OwnershipGeneration $genTk -BaseRevision 'rev-a'
        $tkFp = Get-NDIntentFingerprint -Intent $tkIntent.intent
        $stuckTk = [ordered]@{ schema_version = 1; idempotency_key = $tkKey; phase = 'pending'; task_id = 'nd-task-take1'; agent = 'coder'; owner = 'planner-1'; goal_id = 'nd-goal-take'; ownership_generation = $genTk; task_expected_revision = 1; intent_fingerprint = $tkFp; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
        [IO.File]::WriteAllText(((New-NDReceiptPath -GoalId 'nd-goal-take' -Key $tkKey)), (ConvertTo-Json -InputObject $stuckTk -Compress), [Text.UTF8Encoding]::new($false))
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

        # ---------- FIX3-S1: prova vinculada (kernel worker_result + evidencia da task/key) ----------
        function New-FIX3Evidence {
            param([string]$Task, [string]$Key)
            return [ordered]@{
                task_id = $Task; run_id = $Key; worker_id = 'coder'
                provenance = @{ created_by = 'coder'; kernel_task_ref = $Task }
                base_revision = 'rev-a'; criteria_hash = 'crit-a'
                source_fingerprints = @{ 'dispatch-intent' = $Key }
                diff_hash = ''; scope = @('src/a.ps1'); command = 'native-dispatch'
                environment = @{ runtime = 'native-dispatch'; version = '1' }
                result = @{ summary = 'worker:candidate_pass'; raw_ref = '' }
                assumptions = @()
                invalidation_conditions = @(
                    @{ type = 'base-revision'; require_same = $true }
                )
                created_at = ([DateTime]::UtcNow.ToString('o'))
            }
        }
        function New-FIX3Pending {
            param([string]$Task, [string]$Key, [string]$Fp)
            $stuck = [ordered]@{ schema_version = 1; idempotency_key = $Key; phase = 'pending'; task_id = $Task; agent = 'coder'; owner = 'planner-1'; goal_id = 'nd-goal-1'; ownership_generation = $script:genText; task_expected_revision = 1; intent_fingerprint = $Fp; reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
            [IO.File]::WriteAllText(((New-NDReceiptPath -GoalId 'nd-goal-1' -Key $Key)), (ConvertTo-Json -InputObject $stuck -Compress), [Text.UTF8Encoding]::new($false))
        }
        $script:receiptDirText = $receiptDir
        # (i) revisao avancada SEM worker-result + evidencia vinculada existente => recusado
        New-NDKernelTask -Id 'nd-task-s1a'
        $s1aKey = Get-NativeDispatchHash32 'fix3-s1a-scenario'
        $s1aIntent = New-NDIntent -Task 'nd-task-s1a' -Key $s1aKey
        New-FIX3Pending -Task 'nd-task-s1a' -Key $s1aKey -Fp (Get-NDIntentFingerprint -Intent $s1aIntent.intent)
        $s1aVer = Set-OrchestrationTaskVerification -TaskId 'nd-task-s1a' -VerifierEvidenceJson ([pscustomobject]@{ status = 'verified_pass'; evidence = @(); command_classes = @() }) -Passed $true -ExpectedRevision 1 -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND ([bool]$s1aVer.ok) '[FIX3-S1] revision advanced without worker-result' ([string]$s1aVer.error)
        $s1aEv = New-OrchestrationEvidenceRecord -Evidence (New-FIX3Evidence -Task 'nd-task-s1a' -Key $s1aKey) -StoreDir $evDir
        Assert-ND ([bool]$s1aEv.created) '[FIX3-S1] bound evidence recorded' ([string]$s1aEv.reason)
        $s1aOutcome = @{ ok = $true; reason = 'invented-no-worker-result'; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; kernel_ok = $true; kernel_reason = 'invented'; evidence_created = $true; evidence_id = ([string]$s1aEv.record.evidence_id) }
        $rS1a = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey $s1aKey -Outcome $s1aOutcome -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rS1a.ok) -and ([string]$rS1a.reason -ceq 'reconcile-worker-result-missing'))) '[FIX3-S1] revision without worker-result refused despite bound evidence' ([string]$rS1a.reason)
        # (i-b) worker-result kernel-side DIVERGENTE do declarado => recusado
        New-NDKernelTask -Id 'nd-task-s1b'
        $s1bKey = Get-NativeDispatchHash32 'fix3-s1b-scenario'
        $s1bIntent = New-NDIntent -Task 'nd-task-s1b' -Key $s1bKey
        New-FIX3Pending -Task 'nd-task-s1b' -Key $s1bKey -Fp (Get-NDIntentFingerprint -Intent $s1bIntent.intent)
        $s1bW = Set-OrchestrationTaskWorkerResult -TaskId 'nd-task-s1b' -Status 'failed' -ClaimedEvidence @('criterion:1') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-ND ([bool]$s1bW.ok) '[FIX3-S1] divergent kernel worker-result landed' ([string]$s1bW.error)
        $s1bEv = New-OrchestrationEvidenceRecord -Evidence (New-FIX3Evidence -Task 'nd-task-s1b' -Key $s1bKey) -StoreDir $evDir
        Assert-ND ([bool]$s1bEv.created) '[FIX3-S1] bound evidence recorded for divergent case' ([string]$s1bEv.reason)
        $s1bOutcome = @{ ok = $true; reason = 'invented-divergent'; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; kernel_ok = $true; kernel_reason = 'invented'; evidence_created = $true; evidence_id = ([string]$s1bEv.record.evidence_id) }
        $rS1b = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey $s1bKey -Outcome $s1bOutcome -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rS1b.ok) -and ([string]$rS1b.reason -ceq 'reconcile-worker-result-mismatch'))) '[FIX3-S1] divergent declared result refused without field copy' ([string]$rS1b.reason)
        # (ii) evidencia valida mas de OUTRA task/key => recusado
        New-NDKernelTask -Id 'nd-task-s1c'
        $s1cKey = Get-NativeDispatchHash32 'fix3-s1c-scenario'
        $s1cIntent = New-NDIntent -Task 'nd-task-s1c' -Key $s1cKey
        New-FIX3Pending -Task 'nd-task-s1c' -Key $s1cKey -Fp (Get-NDIntentFingerprint -Intent $s1cIntent.intent)
        $s1cW = Set-OrchestrationTaskWorkerResult -TaskId 'nd-task-s1c' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-ND ([bool]$s1cW.ok) '[FIX3-S1] matching kernel worker-result landed' ([string]$s1cW.error)
        $s1cOutcome = @{ ok = $true; reason = 'invented-foreign-evidence'; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; kernel_ok = $true; kernel_reason = 'invented'; evidence_created = $true; evidence_id = $evIdExt }
        $rS1c = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey $s1cKey -Outcome $s1cOutcome -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
        Assert-ND (((-not [bool]$rS1c.ok) -and ([string]$rS1c.reason -ceq 'reconcile-evidence-unbound'))) '[FIX3-S1] foreign evidence refused despite matching kernel result' ([string]$rS1c.reason)
        $s1cRec = ConvertFrom-Json ([IO.File]::ReadAllText(((New-NDReceiptPath -GoalId 'nd-goal-1' -Key $s1cKey)), [Text.Encoding]::UTF8))
        Assert-ND (([string]$s1cRec.phase -ceq 'pending')) '[FIX3-S1] refused foreign-evidence receipt stays pending' ([string]$s1cRec.phase)
        # (iii) caminho feliz: prova vinculada real => aceito, recibo espelha o kernel
        New-NDKernelTask -Id 'nd-task-s1d'
        $s1dKey = Get-NativeDispatchHash32 'fix3-s1d-scenario'
        $s1dIntent = New-NDIntent -Task 'nd-task-s1d' -Key $s1dKey
        New-FIX3Pending -Task 'nd-task-s1d' -Key $s1dKey -Fp (Get-NDIntentFingerprint -Intent $s1dIntent.intent)
        $s1dW = Set-OrchestrationTaskWorkerResult -TaskId 'nd-task-s1d' -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-ND ([bool]$s1dW.ok) '[FIX3-S1] happy-path kernel write landed' ([string]$s1dW.error)
        $s1dEv = New-OrchestrationEvidenceRecord -Evidence (New-FIX3Evidence -Task 'nd-task-s1d' -Key $s1dKey) -StoreDir $evDir
        Assert-ND ([bool]$s1dEv.created) '[FIX3-S1] happy-path evidence recorded' ([string]$s1dEv.reason)
        $s1dOutcome = @{ ok = $true; reason = 'effect-verified-externally'; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; kernel_ok = $true; kernel_reason = 'externally-confirmed'; evidence_created = $true; evidence_id = ([string]$s1dEv.record.evidence_id) }
        $rS1d = Confirm-OrchestrationDispatchReconciliation -IdempotencyKey $s1dKey -Outcome $s1dOutcome -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -TasksDir $tasksDir -FlagsPath $flagsPath -EvidenceStoreDir $evDir
        Assert-ND (([bool]$rS1d.ok -and [bool]$rS1d.reconciled)) '[FIX3-S1] linked proof accepted' ([string]$rS1d.reason)
        $s1dRec = ConvertFrom-Json ([IO.File]::ReadAllText(((New-NDReceiptPath -GoalId 'nd-goal-1' -Key $s1dKey)), [Text.Encoding]::UTF8))
        $s1dTask = Get-OrchestrationTask -TaskId 'nd-task-s1d' -TasksDir $tasksDir
        $s1dKw = Get-NDValue $s1dTask 'worker_result' $null
        Assert-ND (([string]$s1dRec.worker_result.status -ceq [string](Get-NDValue $s1dKw 'status' ''))) '[FIX3-S1] settled receipt mirrors kernel status' ([string]$s1dRec.worker_result.status)
        Assert-ND (((( @($s1dRec.worker_result.claimed_evidence | Sort-Object) -join ',')) -ceq (((@((Get-NDValue $s1dKw 'claimed_evidence' @()) | Sort-Object)) -join ',')))) '[FIX3-S1] settled receipt mirrors kernel refs' ((@($s1dRec.worker_result.claimed_evidence) -join ','))
        Assert-ND (([string]$s1dRec.evidence_id -ceq ([string]$s1dEv.record.evidence_id))) '[FIX3-S1] settled receipt binds the proven evidence' ([string]$s1dRec.evidence_id)

        # ---------- FIX3-S2: duplicata settled vincula a Authorization antes de devolver ----------
        # (i) mesmo owner/goal => duplicata devolve o conteudo, sem novo efeito
        $s2state = @{ calls = 0 }
        $s2spy = { param($i) $s2state.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rS2i = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $s2spy -Authorization $authOk -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (([bool]$rS2i.duplicate -and ([int]$rS2i.executor_calls -eq 0) -and ([int]$s2state.calls -eq 0))) '[FIX3-S2] same owner/goal duplicate returns with no new effect' ('calls=' + [string]$s2state.calls)
        Assert-ND (([string]$rS2i.worker_result.status -ceq 'candidate_pass')) '[FIX3-S2] duplicate returns the stored worker status' ([string]$rS2i.worker_result.status)
        Assert-ND (((@($rS2i.worker_result.claimed_evidence) -join ',') -ceq 'criterion:0')) '[FIX3-S2] duplicate returns the stored refs' ((@($rS2i.worker_result.claimed_evidence) -join ','))
        Assert-ND (([string]$rS2i.evidence_id -ceq [string]$rOk.evidence_id)) '[FIX3-S2] duplicate returns the stored evidence id' ([string]$rS2i.evidence_id)
        # (ii) goal B lendo recibo do goal A => recusado, sem vazar
        $s2g = New-OrchestrationGoal -GoalId 'nd-goal-s2b' -Objective 'goal estranho' -Criteria @('criterio-a') -StoreDir $goalDir
        $s2a = Set-OrchestrationGoalState -Goal $s2g.goal -ToState 'ACTIVE'
        $s2s = Save-OrchestrationGoal -Goal $s2a.goal -StoreDir $goalDir
        $s2o = Acquire-OrchestrationGoalOwnership -GoalId 'nd-goal-s2b' -OwnerId 'planner-9' -ExpectedRevision ([long]$s2s.revision) -StoreDir $goalDir
        Assert-ND ([bool]$s2o.ok) '[FIX3-S2] foreign goal owned' ([string]$s2o.reason)
        $authS2b = @{ explicit_allow = $true; goal_id = 'nd-goal-s2b'; owner = 'planner-9'; generation = [long]$s2o.ownership['generation']; source = 'planner' }
        $s2xstate = @{ calls = 0 }
        $s2xspy = { param($i) $s2xstate.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        # (ii) F3/REV5: o goal B consultando a key de A. O recibo de A
        # vive no caminho do goal A; B resolve o proprio caminho e ve
        # AUSENCIA. A recusa e a do caminho normal de admissao, nunca
        # 'duplicate-identity-mismatch', que revelaria a existencia.
        $rS2ii = Invoke-OrchestrationNativeDispatch -Intent $good.intent -Executor $s2xspy -Authorization $authS2b -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rS2ii.ok) -and ([int]$rS2ii.executor_calls -eq 0) -and ([int]$s2xstate.calls -eq 0) -and (-not [bool]$rS2ii.duplicate))) '[F3] cross-goal read refused like any refused admission' ([string]$rS2ii.reason)
        Assert-ND (([string]$rS2ii.reason -cne 'duplicate-identity-mismatch')) '[F3] cross-goal read never reports identity-mismatch' ([string]$rS2ii.reason)
        Assert-ND ((-not [bool]$rS2ii.duplicate)) '[F3] cross-goal read never reports a duplicate' ''
        Assert-ND (($null -eq $rS2ii.worker_result)) '[FIX3-S2] refused cross-goal read leaks no worker result' ''
        Assert-ND (([string]$rS2ii.evidence_id -ceq '')) '[FIX3-S2] refused cross-goal read leaks no evidence id' ([string]$rS2ii.evidence_id)
        # F3/REV5 (bonus): a MESMA consulta com uma key que nunca existiu
        # em goal nenhum tem de produzir o MESMO envelope, campo a campo.
        # Input identico (intent/task/revisao + Authorization de B): sem
        # oraculo de existencia, nao ha como distinguir os dois casos.
        $neverIntent = New-NDIntent -Task 'nd-task-1' -Key (Get-NativeDispatchHash32 'never-dispatched-s2b-1')
        Assert-ND ([bool]$neverIntent.ok) '[F3] never-used key intent built' ([string]$neverIntent.reason)
        $neverState = @{ calls = 0 }
        $neverSpy = { param($i) $neverState.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rNever = Invoke-OrchestrationNativeDispatch -Intent $neverIntent.intent -Executor $neverSpy -Authorization $authS2b -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rNever.ok) -and ([int]$neverState.calls -eq 0))) '[F3] never-used key refused the same way' ([string]$rNever.reason)
        $sameFields = @('ok', 'reason', 'admitted', 'duplicate', 'reconciled', 'executor_calls', 'worker_result', 'kernel_ok', 'kernel_reason', 'evidence_created', 'evidence_id')
        foreach ($f in $sameFields) {
            $va = Get-NDValue $rS2ii $f $null
            $vb = Get-NDValue $rNever $f $null
            $sa = '<null>'
            $sb = '<null>'
            if ($null -ne $va) { $sa = [string]$va }
            if ($null -ne $vb) { $sb = [string]$vb }
            Assert-ND ($sa -ceq $sb) ('[F3] existing-key refusal and absent-key refusal agree on ' + $f) ($sa + ' vs ' + $sb)
        }
        # (iii) takeover legitimo documentado: novo owner vivo do mesmo goal + prova => permitido
        $t2g = New-OrchestrationGoal -GoalId 'nd-goal-take2' -Objective 'takeover leitura' -Criteria @('criterio-a') -StoreDir $goalDir
        $t2a = Set-OrchestrationGoalState -Goal $t2g.goal -ToState 'ACTIVE'
        $t2s = Save-OrchestrationGoal -Goal $t2a.goal -StoreDir $goalDir
        $t2o = Acquire-OrchestrationGoalOwnership -GoalId 'nd-goal-take2' -OwnerId 'planner-1' -ExpectedRevision ([long]$t2s.revision) -StoreDir $goalDir -LeaseTtlMs 500
        Assert-ND ([bool]$t2o.ok) '[FIX3-S2] takeover goal owned with short lease' ([string]$t2o.reason)
        $t2gen = [long]$t2o.ownership['generation']
        $ct2 = New-OrchestrationTask -TaskId 'nd-task-take2' -Objective 'obj take2' -TaskType 'implementation' `
            -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
            -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
            -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-ND ([bool]$ct2.ok) '[FIX3-S2] takeover kernel task created' ([string]$ct2.error)
        $slotT2 = Get-OrchestrationGoal -GoalId 'nd-goal-take2' -StoreDir $goalDir
        $addT2 = Add-OrchestrationGoalTaskPersisted -GoalId 'nd-goal-take2' -TaskId 'nd-task-take2' -ExpectedRevision ([long]$slotT2.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $t2gen
        Assert-ND ([bool]$addT2.ok) '[FIX3-S2] takeover task attached' ([string]$addT2.reason)
        $t2Key = Get-NativeDispatchHash32 'fix3-s2-takeover-read'
        $t2Intent = New-OrchestrationNativeDispatchIntent -TaskId 'nd-task-take2' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0', 'criterion:1') -IdempotencyKey $t2Key -Owner 'planner-1' -OwnershipGeneration $t2gen -BaseRevision 'rev-a'
        Assert-ND ([bool]$t2Intent.ok) '[FIX3-S2] takeover intent built' ([string]$t2Intent.reason)
        $authT2 = @{ explicit_allow = $true; goal_id = 'nd-goal-take2'; owner = 'planner-1'; generation = $t2gen; source = 'planner' }
        $t2state = @{ calls = 0 }
        $t2spy = { param($i) $t2state.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rT2 = Invoke-OrchestrationNativeDispatch -Intent $t2Intent.intent -Executor $t2spy -Authorization $authT2 -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (([bool]$rT2.ok -and ([int]$t2state.calls -eq 1))) '[FIX3-S2] first dispatch settles before takeover' ([string]$rT2.reason)
        Start-Sleep -Milliseconds 1200
        $tow2 = Takeover-OrchestrationGoalOwnership -GoalId 'nd-goal-take2' -OwnerId 'planner-2' -StoreDir $goalDir -LeaseTtlMs 60000
        Assert-ND ([bool]$tow2.ok) '[FIX3-S2] ownership taken over' ([string]$tow2.reason)
        $authT2b = @{ explicit_allow = $true; goal_id = 'nd-goal-take2'; owner = 'planner-2'; generation = [long]$tow2.ownership['generation']; source = 'planner' }
        $t2bstate = @{ calls = 0 }
        $t2bspy = { param($i) $t2bstate.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rT2b = Invoke-OrchestrationNativeDispatch -Intent $t2Intent.intent -Executor $t2bspy -Authorization $authT2b -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (([bool]$rT2b.duplicate -and ([int]$t2bstate.calls -eq 0) -and ([string]$rT2b.reason -ceq 'idempotent-duplicate-takeover'))) '[FIX3-S2] legitimate takeover reads the settled duplicate with proof' ([string]$rT2b.reason)
        Assert-ND (([string]$rT2b.worker_result.status -ceq 'candidate_pass')) '[FIX3-S2] takeover duplicate carries the proven result' ([string]$rT2b.worker_result.status)
        Assert-ND (([string]$rT2b.evidence_id -ceq [string]$rT2.evidence_id)) '[FIX3-S2] takeover duplicate preserves the evidence id' ([string]$rT2b.evidence_id)
        # (iv) takeover sem prova kernel-side (recibo de falha, sem worker_result) => recusado
        $t3g = New-OrchestrationGoal -GoalId 'nd-goal-take3' -Objective 'takeover sem prova' -Criteria @('criterio-a') -StoreDir $goalDir
        $t3a = Set-OrchestrationGoalState -Goal $t3g.goal -ToState 'ACTIVE'
        $t3s = Save-OrchestrationGoal -Goal $t3a.goal -StoreDir $goalDir
        $t3o = Acquire-OrchestrationGoalOwnership -GoalId 'nd-goal-take3' -OwnerId 'planner-1' -ExpectedRevision ([long]$t3s.revision) -StoreDir $goalDir -LeaseTtlMs 500
        Assert-ND ([bool]$t3o.ok) '[FIX3-S2] proofless goal owned with short lease' ([string]$t3o.reason)
        $t3gen = [long]$t3o.ownership['generation']
        $ct3 = New-OrchestrationTask -TaskId 'nd-task-take3' -Objective 'obj take3' -TaskType 'implementation' `
            -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
            -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
            -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-ND ([bool]$ct3.ok) '[FIX3-S2] proofless kernel task created' ([string]$ct3.error)
        $slotT3 = Get-OrchestrationGoal -GoalId 'nd-goal-take3' -StoreDir $goalDir
        $addT3 = Add-OrchestrationGoalTaskPersisted -GoalId 'nd-goal-take3' -TaskId 'nd-task-take3' -ExpectedRevision ([long]$slotT3.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $t3gen
        Assert-ND ([bool]$addT3.ok) '[FIX3-S2] proofless task attached' ([string]$addT3.reason)
        $t3Key = Get-NativeDispatchHash32 'fix3-s2-takeover-noproof'
        $t3Intent = New-OrchestrationNativeDispatchIntent -TaskId 'nd-task-take3' -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0', 'criterion:1') -IdempotencyKey $t3Key -Owner 'planner-1' -OwnershipGeneration $t3gen -BaseRevision 'rev-a'
        $authT3 = @{ explicit_allow = $true; goal_id = 'nd-goal-take3'; owner = 'planner-1'; generation = $t3gen; source = 'planner' }
        $evilT3 = { param($i) return @{ status = 'verified_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rT3 = Invoke-OrchestrationNativeDispatch -Intent $t3Intent.intent -Executor $evilT3 -Authorization $authT3 -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rT3.ok) -and ([string]$rT3.reason -ceq 'status-not-allowed-from-worker'))) '[FIX3-S2] proofless receipt settles as failure' ([string]$rT3.reason)
        Start-Sleep -Milliseconds 1200
        $tow3 = Takeover-OrchestrationGoalOwnership -GoalId 'nd-goal-take3' -OwnerId 'planner-2' -StoreDir $goalDir -LeaseTtlMs 60000
        Assert-ND ([bool]$tow3.ok) '[FIX3-S2] proofless ownership taken over' ([string]$tow3.reason)
        $authT3b = @{ explicit_allow = $true; goal_id = 'nd-goal-take3'; owner = 'planner-2'; generation = [long]$tow3.ownership['generation']; source = 'planner' }
        $t3bstate = @{ calls = 0 }
        $t3bspy = { param($i) $t3bstate.calls++; return @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') } }.GetNewClosure()
        $rT3b = Invoke-OrchestrationNativeDispatch -Intent $t3Intent.intent -Executor $t3bspy -Authorization $authT3b -ReceiptDir $receiptDir -GoalStoreDir $goalDir -EvidenceStoreDir $evDir -TasksDir $tasksDir -FlagsPath $flagsPath
        Assert-ND (((-not [bool]$rT3b.ok) -and ([string]$rT3b.reason -ceq 'duplicate-identity-mismatch') -and ([int]$t3bstate.calls -eq 0))) '[FIX3-S2] takeover without kernel proof refused' ([string]$rT3b.reason)
        Assert-ND (($null -eq $rT3b.worker_result)) '[FIX3-S2] refused takeover read leaks no worker result' ''
        Assert-ND (([string]$rT3b.evidence_id -ceq '')) '[FIX3-S2] refused takeover read leaks no evidence id' ([string]$rT3b.evidence_id)

        # ---------- F4 (REV5): ownership stale sob o lock no Confirm ----------
        # A autorizacao passa no gate PRE-lock e a ownership pode deixar de
        # valer durante a espera pelo lock (lease expirada). A liquidacao
        # (sucesso E falha) so pode acontecer com a ownership VIVA relida
        # sob o lock, imediatamente antes de persistir. Aqui o teste
        # OCUPA o lock do recibo enquanto o lease expira: o gate roda com o
        # lease vivo, o Confirm espera o lock, e quando o adquire a
        # autorizacao apresentada ja nao e a viva atual. Recusa sem
        # liquidar, recibo permanece pending.
        function New-F4Fixture {
            param([string]$Suffix)
            $gname = ('nd-goal-f4-' + $Suffix)
            $gg = New-OrchestrationGoal -GoalId $gname -Objective ('confirm lock ' + $Suffix) -Criteria @('criterio-a') -StoreDir $goalDir
            Assert-ND ([bool]$gg.ok) ('[F4/' + $Suffix + '] goal created') ([string]$gg.reason)
            $ga = Set-OrchestrationGoalState -Goal $gg.goal -ToState 'ACTIVE'
            $gs = Save-OrchestrationGoal -Goal $ga.goal -StoreDir $goalDir
            Assert-ND ([bool]$gs.ok) ('[F4/' + $Suffix + '] goal active+saved') ([string]$gs.reason)
            # lease curta: cobre a criacao do recibo e o gate, expira
            # durante a espera pelo lock
            $go = Acquire-OrchestrationGoalOwnership -GoalId $gname -OwnerId 'planner-1' -ExpectedRevision ([long]$gs.revision) -StoreDir $goalDir -LeaseTtlMs 5000
            Assert-ND ([bool]$go.ok) ('[F4/' + $Suffix + '] short lease acquired') ([string]$go.reason)
            $ggen = [long]$go.ownership['generation']
            $tid = ('nd-task-f4-' + $Suffix)
            $ct = New-OrchestrationTask -TaskId $tid -Objective ('obj ' + $tid) -TaskType 'implementation' `
                -Risk 'low' -Actor 'planner-1' -RuntimeId 'opencode-v2' -RuntimeGeneration 2 -RuntimeProfile 'v2' `
                -RuntimeVersion '2.0.18' -BaseRevision 'rev-a' -ReadScopes @('src/a.ps1') -Grants @('fs.read') `
                -AcceptanceCriteria @('crit-a') -AttemptBudget 3 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
            Assert-ND ([bool]$ct.ok) ('[F4/' + $Suffix + '] kernel task created') ([string]$ct.error)
            $slotF4 = Get-OrchestrationGoal -GoalId $gname -StoreDir $goalDir
            $add = Add-OrchestrationGoalTaskPersisted -GoalId $gname -TaskId $tid -ExpectedRevision ([long]$slotF4.goal['revision']) -StoreDir $goalDir -OwnerId 'planner-1' -OwnershipGeneration $ggen
            Assert-ND ([bool]$add.ok) ('[F4/' + $Suffix + '] task attached') ([string]$add.reason)
            $ren = Renew-OrchestrationGoalOwnership -GoalId $gname -OwnerId 'planner-1' -Generation $ggen -StoreDir $goalDir -LeaseTtlMs 5000
            Assert-ND ([bool]$ren.ok) ('[F4/' + $Suffix + '] lease refreshed') ([string]$ren.reason)
            $kk = Get-NativeDispatchHash32 ('f4-scenario-' + $Suffix)
            return @{ goal = $gname; gen = $ggen; task = $tid; key = $kk }
        }
        function Invoke-F4ConfirmUnderStaleOwnership {
            param([string]$Suffix, $F4, $Outcome)
            $f4Dir = Get-NDGoalReceiptDir -RootDir $receiptDir -GoalId ([string]$F4.goal)
            $f4Path = Join-Path $f4Dir ([string]$F4.key + '.json')
            # lease folgado o bastante para o gate PRE-lock passar com
            # sobra, e curto o bastante para expirar durante a espera pelo
            # lock que o teste provoca
            $f4Auth = @{ explicit_allow = $true; goal_id = ([string]$F4.goal); owner = 'planner-1'; generation = ([long]$F4.gen); source = 'planner' }
            $f4Intent = New-OrchestrationNativeDispatchIntent -TaskId ([string]$F4.task) -TaskExpectedRevision 1 -Agent 'coder' -PromptHash $ph -Scope @('src/a.ps1') -AcceptanceCriteria @('criterion:0', 'criterion:1') -IdempotencyKey ([string]$F4.key) -Owner 'planner-1' -OwnershipGeneration ([long]$F4.gen) -BaseRevision 'rev-a'
            $f4Stuck = [ordered]@{ schema_version = 1; idempotency_key = ([string]$F4.key); phase = 'pending'; task_id = ([string]$F4.task); agent = 'coder'; owner = 'planner-1'; goal_id = ([string]$F4.goal); ownership_generation = ([long]$F4.gen); task_expected_revision = 1; intent_fingerprint = (Get-NDIntentFingerprint -Intent $f4Intent.intent); reconciled = $false; created_at = ([DateTime]::UtcNow.ToString('o')) }
            [IO.File]::WriteAllText($f4Path, (ConvertTo-Json -InputObject $f4Stuck -Compress), [Text.UTF8Encoding]::new($false))
            Assert-ND ((Test-Path -LiteralPath $f4Path -PathType Leaf)) ('[F4/' + $Suffix + '] pending receipt persisted in the goal namespace') $f4Path
            # ocupa o lock do recibo: o gate (pre-lock) roda com o lease
            # vivo, o Confirm espera o lock e o lease expira nesse Intervalo
            $f4LockPath = Join-Path $f4Dir '.dispatch.lock'
            $f4Stream = $null
            try { $f4Stream = [IO.File]::Open($f4LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { }
            $jb = $null
            if ($null -ne $f4Stream) {
                try {
                    $lib = (Join-Path $PSScriptRoot 'OrchestrationNativeDispatch.ps1')
                    $jb = Start-Job -ScriptBlock {
                        param($Lib, $Key, $ReceiptDir, $GoalStoreDir, $TasksDir, $FlagsPath, $EvidenceStoreDir, $Outcome, $Authorization)
                        $libDir = Split-Path -Parent $Lib
                        . (Join-Path $libDir 'OrchestrationGoalKernel.ps1')
                        . (Join-Path $libDir 'OrchestrationEvidenceStore.ps1')
                        . (Join-Path $libDir 'OrchestrationTaskKernel.ps1')
                        . $Lib
                        $o = ConvertFrom-Json $Outcome
                        return (Confirm-OrchestrationDispatchReconciliation -IdempotencyKey $Key -Outcome $o -Authorization $Authorization -ReceiptDir $ReceiptDir -GoalStoreDir $GoalStoreDir -TasksDir $TasksDir -FlagsPath $FlagsPath -EvidenceStoreDir $EvidenceStoreDir -LockTimeoutMs 30000)
                    } -ArgumentList @($lib, ([string]$F4.key), $receiptDir, $goalDir, $tasksDir, $flagsPath, $evDir, (ConvertTo-Json -InputObject $Outcome -Depth 8 -Compress), $f4Auth)
                }
                catch { $jb = $null }
                Start-Sleep -Milliseconds 5500
                try { $f4Stream.Dispose() } catch { }
                try { Remove-Item -LiteralPath $f4LockPath -Force -ErrorAction SilentlyContinue } catch { }
            }
            $rF4 = $null
            if ($null -ne $jb) {
                try { Wait-Job $jb -Timeout 40000 | Out-Null } catch { }
                $rF4 = Receive-Job $jb
                try { Remove-Job $jb -Force -ErrorAction SilentlyContinue } catch { }
            }
            Assert-ND (($null -ne $f4Stream) -and ($null -ne $jb) -and ($null -ne $rF4)) ('[F4/' + $Suffix + '] locked gate reproduced deterministically') 'job-or-lock unavailable'
            if ($null -eq $rF4) { return }
            Assert-ND (((-not [bool]$rF4.ok) -and ([string]$rF4.reason -ceq 'reconcile-ownership-stale') -and ([int]$rF4.executor_calls -eq 0) -and (-not [bool]$rF4.reconciled))) ('[F4/' + $Suffix + '] stale ownership refuses under the lock') ([string]$rF4.reason)
            Assert-ND (($null -eq $rF4.worker_result) -and ([string]$rF4.evidence_id -ceq '')) ('[F4/' + $Suffix + '] refusal leaks no receipt content') ''
            $f4After = ConvertFrom-Json ([IO.File]::ReadAllText($f4Path, [Text.Encoding]::UTF8))
            Assert-ND (([string]$f4After.phase -ceq 'pending') -and (-not [bool]$f4After.reconciled)) ('[F4/' + $Suffix + '] receipt stays pending, nothing settled') ([string]$f4After.phase)
        }
        # (i) caminho de SUCESSO com prova kernel-side real
        $f4s = New-F4Fixture -Suffix 'success'
        $f4w = Set-OrchestrationTaskWorkerResult -TaskId ([string]$f4s.task) -Status 'candidate_pass' -ClaimedEvidence @('criterion:0') -ProducedBy 'coder' -ExpectedRevision 1 -TasksDir $tasksDir -FlagsPath $flagsPath -TelemetryRoot $tempRoot
        Assert-ND ([bool]$f4w.ok) '[F4/success] external kernel write landed' ([string]$f4w.error)
        $f4ev = New-OrchestrationEvidenceRecord -Evidence (New-FIX3Evidence -Task ([string]$f4s.task) -Key ([string]$f4s.key)) -StoreDir $evDir
        Assert-ND ([bool]$f4ev.created) '[F4/success] bound evidence recorded' ([string]$f4ev.reason)
        $f4OkOutcome = @{ ok = $true; reason = 'verified-externally'; worker_result = @{ status = 'candidate_pass'; claimed_evidence = @('criterion:0') }; kernel_ok = $true; kernel_reason = 'externally-confirmed'; evidence_created = $true; evidence_id = ([string]$f4ev.record.evidence_id) }
        Invoke-F4ConfirmUnderStaleOwnership -Suffix 'success' -F4 $f4s -Outcome $f4OkOutcome
        # (ii) caminho de FALHA externa apurada
        $f4f = New-F4Fixture -Suffix 'failure'
        $f4FailOutcome = @{ ok = $false; reason = 'outer-failure-apurada'; kernel_reason = 'outer-failure' }
        Invoke-F4ConfirmUnderStaleOwnership -Suffix 'failure' -F4 $f4f -Outcome $f4FailOutcome

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
