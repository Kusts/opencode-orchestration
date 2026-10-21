<#!
.SYNOPSIS
    Tests for S6 Etapa C productive settle-and-continue wiring (harness).
.DESCRIPTION
    Hermetic: temp dirs, cleanup at the end; repo tree never written
    (the real validation-policy.json is only READ). Throw on first FAIL,
    print PASS count on success. Exit 0 all pass, 1 any fail. PS 5.1
    compatible. ASCII-only. No network, no spawn, no Executor.
    Covers: strict gate without provenance => HOLD/manual (RED: absent
    proof never auto-advances); provenance transport to the canonical
    ND-Settle owner (strict ok); settlement result kept separate from
    continuation; continuation requires an EXPLICIT authorization bound
    to the goal/fencing (never synthesized: absent auth HOLDS with the
    settlement proven); reconcile refusals (grants/fencing/CAS) are
    preserved and never routed around via the diary; strict replay is
    proven by the correlated native receipt (persisted tier + proof
    binding), never by the diary alone; legacy tier-less receipts replayed
    under strict HOLD; diary consult uses the received revision with an
    exact-key match (revision 1 is never a fallback); continuation
    re-reads gates without re-settling and
    never executes the successor (only PREPAREs the ref for the Planner
    via the real CLAIM path); duplicate settle => idempotent replay
    (1 successor per goal+settled_key); divergent candidate => conflict;
    legacy non-strict settle without proof keeps working. SOFT_ADVISORY
    note: fixtures synthesize host proofs, so strictness here validates
    plumbing (binding + persisted tier), not real host attestation.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\OrchestrationTaskKernel.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationGoalCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationRuntimeAdapterContract.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationObjectiveRuntime.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationProductiveActivation.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationNativeDispatch.ps1')
. (Join-Path $PSScriptRoot 'lib\OrchestrationAutonomousLoop.ps1')
$passed = 0
function Assert-S6That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function Write-S6File {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n")
    $lf = ($lf -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}
function New-S6Root {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('pa-s6-' + [guid]::NewGuid().ToString('N'))
    $goal = Join-Path $root 'goals'
    $dispatch = Join-Path $root 'dispatch'
    $ckpt = Join-Path $root 'checkpoints'
    $tasks = Join-Path $root 'tasks'
    $tele = Join-Path $root 'telemetry'
    $flags = Join-Path $root 'flags.json'
    $receipt = Join-Path $root 'receipts'
    $evidence = Join-Path $root 'evidence'
    foreach ($d in @($goal, $dispatch, $ckpt, $tasks, $tele, $receipt, $evidence)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    Write-S6File -Path $flags -Text '{"task_kernel":{"enabled":true,"shadow":false}}'
    return @{ root = $root; goal = $goal; dispatch = $dispatch; ckpt = $ckpt; tasks = $tasks; tele = $tele; flags = $flags; receipt = $receipt; evidence = $evidence }
}
$script:S6Full = 'ops allow:dispatch allow:settlement allow:checkpoint allow:advance allow:terminalize allow:reconcile'
function New-S6Goal {
    param([string]$Id, [string]$GoalDir)
    $n = New-OrchestrationGoal -GoalId $Id -Objective ('s6 objective ' + $Id) -Criteria @('s6-crit-a', 's6-crit-b') -StoreDir $GoalDir
    if (-not [bool]$n.ok) { throw "FAIL: setup new goal $Id" }
    $act = Set-OrchestrationGoalState -Goal $n.goal -ToState 'ACTIVE'
    $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $GoalDir
    if (-not [bool]$sv.ok) { throw "FAIL: setup save $Id" }
    $own = Acquire-OrchestrationGoalOwnership -GoalId $Id -OwnerId 'owner-s6' -ExpectedRevision ([long]$sv.revision) -StoreDir $GoalDir
    if (-not [bool]$own.ok) { throw "FAIL: setup ownership $Id" }
    return $own
}
function New-S6Task {
    param([string]$Id, [string]$GoalId, [long]$Gen, $F)
    $t = New-OrchestrationTask -TaskId $Id -Objective ('s6 fixture work ' + $Id) -Actor 'owner-s6' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' -TaskType 'implementation' -Risk 'low' -BaseRevision 's6-base' -ReadScopes @('s6/a.txt') -WriteScopes @('s6/a.txt') -Grants @('fs.read', 'fs.write') -AcceptanceCriteria @('criterion:0') -SettlementPolicy 'canonical-native-settle' -AttemptBudget 3 -TasksDir $F.tasks -FlagsPath $F.flags -TelemetryRoot $F.tele
    if (-not [bool]$t.ok) { throw ("FAIL: setup task " + $Id + " " + [string]$t.error) }
    $r1 = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision ([int]$t.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $F.tasks -FlagsPath $F.flags -TelemetryRoot $F.tele
    if (-not [bool]$r1.ok) { throw ("FAIL: setup planning " + $Id) }
    $r2 = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision ([int]$r1.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $F.tasks -FlagsPath $F.flags -TelemetryRoot $F.tele
    if (-not [bool]$r2.ok) { throw ("FAIL: setup implementing " + $Id) }
    $grev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $F.goal).goal['revision']
    $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $Id -ExpectedRevision $grev -StoreDir $F.goal -OwnerId 'owner-s6' -OwnershipGeneration $Gen
    if (-not [bool]$add.ok) { throw ("FAIL: setup attach " + $Id) }
}
function Get-S6TaskRev {
    param([string]$Id, [string]$TasksDir)
    $rec = Get-OrchestrationTask -TaskId $Id -TasksDir $TasksDir
    if (($null -eq $rec) -or (-not ($rec -is [System.Collections.IDictionary]))) { return -1 }
    if (-not $rec.Contains('revision')) { return -1 }
    return ([int]$rec['revision'])
}
function New-S6NativeFixture {
    param([string]$Tag, [long]$Rev = 1)
    $f = New-S6Root
    $gid = ('PA-S6-' + $Tag)
    $tid = ('pa-task-s6-' + $Tag).ToLowerInvariant()
    $wid = ('w-s6-' + $Tag)
    $sess = ('pa-session-s6-' + $Tag)
    $own = New-S6Goal $gid $f.goal
    $gen = [long]$own.ownership['generation']
    New-S6Task $tid $gid $gen $f
    $ev = (New-OrchestrationObjectiveEvent -GoalId $gid -Type 'task-settled' -WorkItemId $wid -ActionRevision $Rev).event
    $grevLive = [long](Get-OrchestrationGoal -GoalId $gid -StoreDir $f.goal).goal['revision']
    $res = Invoke-ProductiveObjectiveEvent -Event $ev -GoalStoreDir $f.goal -DispatchStoreDir $f.dispatch -CheckpointStoreDir $f.ckpt -TasksDir $f.tasks -FlagsPath $f.flags -TelemetryRoot $f.tele -TaskId $tid -AttemptRole 'coder' -SessionId $sess -OwnerId 'owner-s6' -Generation $gen -ExpectedRevision $grevLive -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch' -Productive
    if ((-not [bool]$res.ok) -or (-not [bool]$res.dispatched)) { throw "FAIL: S6 setup dispatch $Tag" }
    $ndk = Get-NativeDispatchHash32 ('s6-key-' + $Tag)
    $ph = Get-NativeDispatchHash32 ('s6-prompt-' + $Tag)
    $ni = New-OrchestrationNativeDispatchIntent -TaskId $tid -TaskExpectedRevision 4 -Agent 'coder' -PromptHash $ph -Scope @('s6/a.txt') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $ndk -Owner 'owner-s6' -OwnershipGeneration $gen -BaseRevision 's6-base'
    if (-not [bool]$ni.ok) { throw ("FAIL: S6 setup intent " + $Tag + " " + [string]$ni.reason) }
    $authND = @{ explicit_allow = $true; goal_id = $gid; owner = 'owner-s6'; generation = $gen; source = 'planner' }
    $p = Invoke-OrchestrationNativeDispatchPrepare -Intent $ni.intent -Authorization $authND -SessionId $sess -ReceiptDir $f.receipt -GoalStoreDir $f.goal -TasksDir $f.tasks -FlagsPath $f.flags
    if (-not [bool]$p.ok) { throw ("FAIL: S6 setup prepare " + $Tag + " " + [string]$p.reason) }
    $msg = ('msg-s6-' + $Tag)
    $call = ('call-s6-' + $Tag)
    $child = ('ses-s6-' + $Tag + '-child')
    $c = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $ndk -Authorization $authND -SessionId $sess -MessageId $msg -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p.prepared_fingerprint) -ReceiptDir $f.receipt -GoalStoreDir $f.goal -TasksDir $f.tasks -FlagsPath $f.flags
    if (-not [bool]$c.ok) { throw ("FAIL: S6 setup claim " + $Tag + " " + [string]$c.reason) }
    $goalRev = [long](Get-OrchestrationGoal -GoalId $gid -StoreDir $f.goal).goal['revision']
    $proof = @{
        child_session_id = $child; parent_session_id = $sess; call_id = $call
        idempotency_key = $ndk; source = 'plugin-session-get'; claimed_evidence = @('criterion:0')
    }
    $ctx = @{
        task_id = $tid; receipt_root = $f.receipt; idempotency_key = $ndk
        prepared_fingerprint = ([string]$p.prepared_fingerprint)
        parent_session_id = $sess; message_id = $msg; call_id = $call
        caller_agent = 'planner'; target_agent = 'coder'; child_session_id = $child
        goal_id = $gid; owner = 'owner-s6'; generation = $gen
        goal_store_dir = $f.goal; evidence_store_dir = $f.evidence
        reference = ([string]$p.reference); goal_revision = $goalRev
        status = 'candidate_pass'; produced_by = 'coder'; claimed_evidence = @('criterion:0')
        authorization = @{ explicit_allow = $true; goal_id = $gid; owner = 'owner-s6'; generation = $gen; source = 'planner' }
        provenance_proof = $proof
    }
    return @{ f = $f; gid = $gid; tid = $tid; wid = $wid; sess = $sess; gen = $gen; ndk = $ndk; msg = $msg; call = $call; child = $child; prep = $p; claim = $c; ctx = $ctx; proof = $proof; authND = $authND }
}
function Copy-S6Ctx {
    param($Src)
    $d = @{}
    foreach ($kk in @($Src.Keys)) { $d[$kk] = $Src[$kk] }
    return $d
}
# --- S6-0: RED - strict gate without provenance => HOLD/manual, zero writes, no continuation.
$fx0 = New-S6NativeFixture -Tag 'hold'
$ctxNoProv = Copy-S6Ctx $fx0.ctx
$ctxNoProv.Remove('provenance_proof')
$rev0 = Get-S6TaskRev $fx0.tid $fx0.f.tasks
$liveRev0 = [long](Get-OrchestrationGoal -GoalId $fx0.gid -StoreDir $fx0.f.goal).goal['revision']
$w0 = Invoke-ProductiveSettleAndContinue -GoalId $fx0.gid -GoalStoreDir $fx0.f.goal -DispatchStoreDir $fx0.f.dispatch -TasksDir $fx0.f.tasks -FlagsPath $fx0.f.flags -TelemetryRoot $fx0.f.tele -ReceiptDir $fx0.f.receipt -EvidenceStoreDir $fx0.f.evidence -CheckpointDir $fx0.f.ckpt -TaskId $fx0.tid -AttemptRole 'coder' -SessionId $fx0.sess -OwnerId 'owner-s6' -Generation $fx0.gen -ExpectedRevision $liveRev0 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx0.wid -NativeSettlementContext $ctxNoProv -ContinuationAuthorization $fx0.authND -Productive
Assert-S6That ((($null -ne $w0) -and (-not [bool]$w0.ok)) -and ([string]$w0.reason -ceq 'hold-productive-disabled:settle-provenance-required')) 'S6 strict without provenance HOLDS manual'
Assert-S6That (((-not [bool]$w0.settled) -and (-not [bool]$w0.continuation_attempted)) -and ($null -eq $w0.continuation)) 'S6 HOLD attempts no continuation'
Assert-S6That (((Get-S6TaskRev $fx0.tid $fx0.f.tasks) -eq $rev0) -and ([int]$w0.executor_calls -eq 0)) 'S6 HOLD writes zero to the kernel'
Assert-S6That (((-not [bool]$w0.grants_authority) -and (-not [bool]$w0.done_approved)) -and (-not [bool]$w0.verified_pass)) 'S6 HOLD claims no authority DONE or verified pass'
# --- S6-0b: RED - direct settle impl strict without proof => HOLD, zero writes.
$snap0 = Get-OrchestrationDispatchIntent -GoalId $fx0.gid -WorkItemId $fx0.wid -ActionRevision 1 -StoreDir $fx0.f.dispatch
$live0 = Get-OrchestrationGoal -GoalId $fx0.gid -StoreDir $fx0.f.goal
$authS0 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -Operation 'settlement' -Resource $fx0.wid -Decision 'settlement'
$st0 = New-ProductiveSettleImpl -TaskId $fx0.tid -AttemptRole 'coder' -SessionId $fx0.sess -TasksDir $fx0.f.tasks -FlagsPath $fx0.f.flags -TelemetryRoot $fx0.f.tele -OwnerId 'owner-s6' -Generation $fx0.gen -GoalStoreDir $fx0.f.goal -DispatchStoreDir $fx0.f.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -Tracker (New-PATracker $null) -NativeSettlement $ctxNoProv -StrictProvenance -Productive
Assert-S6That ([bool]$st0.ok) 'S6 strict settle ctor ok'
Assert-S6That (($null -eq (& $st0.impl $snap0.intent $snap0.intent['receipt'] $live0.goal $authS0))) 'S6 strict settle without proof HOLDS before any ND call'
Assert-S6That ((Get-S6TaskRev $fx0.tid $fx0.f.tasks) -eq $rev0) 'S6 strict HOLD writes zero (rev intact)'
# --- S6-1: GREEN - provenance transported; settlement separate from continuation; no auto-advance.
$fx1 = New-S6NativeFixture -Tag 'sep'
$nextTid1 = 'pa-task-s6-sep-next'
New-S6Task $nextTid1 $fx1.gid $fx1.gen $fx1.f
$nextRev1 = Get-S6TaskRev $nextTid1 $fx1.f.tasks
$nextKey1 = Get-NativeDispatchHash32 's6-sep-next-key'
$nextPh1 = Get-NativeDispatchHash32 's6-sep-next-prompt'
$nextIntent1Slot = New-OrchestrationNativeDispatchIntent -TaskId $nextTid1 -TaskExpectedRevision $nextRev1 -Agent 'coder' -PromptHash $nextPh1 -Scope @('s6/a.txt') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $nextKey1 -Owner 'owner-s6' -OwnershipGeneration $fx1.gen -BaseRevision 's6-base'
Assert-S6That ([bool]$nextIntent1Slot.ok) 'S6 successor intent built'
$rev1 = Get-S6TaskRev $fx1.tid $fx1.f.tasks
$liveRev1 = [long](Get-OrchestrationGoal -GoalId $fx1.gid -StoreDir $fx1.f.goal).goal['revision']
$w1 = Invoke-ProductiveSettleAndContinue -GoalId $fx1.gid -GoalStoreDir $fx1.f.goal -DispatchStoreDir $fx1.f.dispatch -TasksDir $fx1.f.tasks -FlagsPath $fx1.f.flags -TelemetryRoot $fx1.f.tele -ReceiptDir $fx1.f.receipt -EvidenceStoreDir $fx1.f.evidence -CheckpointDir $fx1.f.ckpt -TaskId $fx1.tid -AttemptRole 'coder' -SessionId $fx1.sess -OwnerId 'owner-s6' -Generation $fx1.gen -ExpectedRevision $liveRev1 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx1.wid -NativeSettlementContext $fx1.ctx -ContinuationAuthorization $fx1.authND -NextIntent $nextIntent1Slot.intent -Productive
Assert-S6That ((($null -ne $w1) -and [bool]$w1.ok) -and [bool]$w1.settled) 'S6 provenanced settle lands via the canonical owner'
Assert-S6That (([string]$w1.settled_key -ceq $fx1.ndk) -and ($null -ne $w1.settlement)) 'S6 settlement result carried under the settled native key'
Assert-S6That (((Get-S6TaskRev $fx1.tid $fx1.f.tasks) -eq ($rev1 + 1)) -and [bool]$w1.continuation_attempted) 'S6 exactly one kernel write, continuation attempted outside locks'
Assert-S6That (($null -ne $w1.continuation) -and ([string]$w1.continuation.action -ceq 'blocked')) 'S6 continuation without verification REVIEW blocks instead of advancing'
Assert-S6That (([string]$w1.continuation.reason -ceq 'continuation-verification-required') -and ([int]$w1.continuation.executor_calls -eq 0)) 'S6 blocked continuation executes no worker'
Assert-S6That (((-not [bool]$w1.grants_authority) -and (-not [bool]$w1.done_approved)) -and (-not [bool]$w1.verified_pass)) 'S6 wiring claims no authority DONE or verified pass'
# --- S6-2: divergent candidate for the same claim => conflict, zero new writes.
$snap1 = Get-OrchestrationDispatchIntent -GoalId $fx1.gid -WorkItemId $fx1.wid -ActionRevision 1 -StoreDir $fx1.f.dispatch
$live1 = Get-OrchestrationGoal -GoalId $fx1.gid -StoreDir $fx1.f.goal
$authS1 = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -Operation 'settlement' -Resource $fx1.wid -Decision 'settlement'
$stDiv = New-ProductiveSettleImpl -TaskId $fx1.tid -AttemptRole 'coder' -SessionId $fx1.sess -TasksDir $fx1.f.tasks -FlagsPath $fx1.f.flags -TelemetryRoot $fx1.f.tele -OwnerId 'owner-s6' -Generation $fx1.gen -GoalStoreDir $fx1.f.goal -DispatchStoreDir $fx1.f.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:9:other-evidence') -Tracker (New-PATracker $null) -NativeSettlement $fx1.ctx -Productive
Assert-S6That (($null -eq (& $stDiv.impl $snap1.intent $snap1.intent['receipt'] $live1.goal $authS1))) 'S6 divergent candidate for the same claim is conflict, never overwrite'
Assert-S6That ((Get-S6TaskRev $fx1.tid $fx1.f.tasks) -eq ($rev1 + 1)) 'S6 conflict writes nothing new'
# --- S6-3: legacy compat - non-strict settle without proof still uses the previous contract.
$fxL = New-S6NativeFixture -Tag 'legacy'
$ctxLeg = Copy-S6Ctx $fxL.ctx
$ctxLeg.Remove('provenance_proof')
$snapL = Get-OrchestrationDispatchIntent -GoalId $fxL.gid -WorkItemId $fxL.wid -ActionRevision 1 -StoreDir $fxL.f.dispatch
$liveL = Get-OrchestrationGoal -GoalId $fxL.gid -StoreDir $fxL.f.goal
$authSL = New-OrchestrationObjectiveAuthEnvelope -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -Operation 'settlement' -Resource $fxL.wid -Decision 'settlement'
$revL = Get-S6TaskRev $fxL.tid $fxL.f.tasks
$stL = New-ProductiveSettleImpl -TaskId $fxL.tid -AttemptRole 'coder' -SessionId $fxL.sess -TasksDir $fxL.f.tasks -FlagsPath $fxL.f.flags -TelemetryRoot $fxL.f.tele -OwnerId 'owner-s6' -Generation $fxL.gen -GoalStoreDir $fxL.f.goal -DispatchStoreDir $fxL.f.dispatch -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -Tracker (New-PATracker $null) -NativeSettlement $ctxLeg -Productive
$rL = & $stL.impl $snapL.intent $snapL.intent['receipt'] $liveL.goal $authSL
Assert-S6That ((($null -ne $rL) -and [bool]$rL.ok) -and ([string]$rL.reason -ceq 'productive-settle-canonical')) 'S6 legacy non-strict settle without proof keeps the previous contract'
Assert-S6That ((Get-S6TaskRev $fxL.tid $fxL.f.tasks) -eq ($revL + 1)) 'S6 legacy settle writes the single canonical worker result'
# --- S6-4: full CONTINUE - fresh verification+review+DONE => exactly one prepared successor; replay stays single.
$fx2 = New-S6NativeFixture -Tag 'cont'
$nextTid = 'pa-task-s6-cont-next'
New-S6Task $nextTid $fx2.gid $fx2.gen $fx2.f
$rev2 = Get-S6TaskRev $fx2.tid $fx2.f.tasks
$liveRev2 = [long](Get-OrchestrationGoal -GoalId $fx2.gid -StoreDir $fx2.f.goal).goal['revision']
$w2 = Invoke-ProductiveSettleAndContinue -GoalId $fx2.gid -GoalStoreDir $fx2.f.goal -DispatchStoreDir $fx2.f.dispatch -TasksDir $fx2.f.tasks -FlagsPath $fx2.f.flags -TelemetryRoot $fx2.f.tele -ReceiptDir $fx2.f.receipt -EvidenceStoreDir $fx2.f.evidence -CheckpointDir $fx2.f.ckpt -TaskId $fx2.tid -AttemptRole 'coder' -SessionId $fx2.sess -OwnerId 'owner-s6' -Generation $fx2.gen -ExpectedRevision $liveRev2 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx2.wid -NativeSettlementContext $fx2.ctx -ContinuationAuthorization $fx2.authND -Productive
Assert-S6That ([bool]$w2.settled) 'S6-4 settlement proven before continuation'
$vRev = Get-S6TaskRev $fx2.tid $fx2.f.tasks
$vt = Invoke-OrchestrationTaskTransition -TaskId $fx2.tid -ToState 'VALIDATING' -Actor 'planner' -ExpectedRevision $vRev -ActorIdentitySource 'explicit-cli' -TasksDir $fx2.f.tasks -FlagsPath $fx2.f.flags -TelemetryRoot $fx2.f.tele
Assert-S6That ([bool]$vt.ok) 'S6-4 task validating'
$rt = Invoke-OrchestrationTaskTransition -TaskId $fx2.tid -ToState 'REVIEWING' -Actor 'planner' -ExpectedRevision ([int]$vt.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $fx2.f.tasks -FlagsPath $fx2.f.flags -TelemetryRoot $fx2.f.tele
Assert-S6That ([bool]$rt.ok) 'S6-4 task reviewing'
$verJson = (@{ ok = $true; task_id = 's6-verifier'; status = 'verified_pass'; reason = 's6 verifier read-back'; scope = $null; profiles = @(); evidence = @('criterion:0:artifact-bytes=12;expected-match=True', 'criterion:0:file=s6-a.txt'); command_classes = @('test') } | ConvertTo-Json -Depth 8 -Compress)
$sv2 = Set-OrchestrationTaskVerification -TaskId $fx2.tid -VerifierEvidenceJson $verJson -ExpectedRevision ([int]$rt.revision) -TasksDir $fx2.f.tasks -FlagsPath $fx2.f.flags
Assert-S6That ([bool]$sv2.ok) 'S6-4 fresh verification recorded'
$sr2 = Set-OrchestrationTaskReview -TaskId $fx2.tid -Kind 'reviewer' -Status 'approved' -By 'reviewer-1' -ExpectedRevision ([int]$sv2.revision) -TasksDir $fx2.f.tasks -FlagsPath $fx2.f.flags
Assert-S6That ([bool]$sr2.ok) 'S6-4 fresh review recorded'
$dn2 = Complete-OrchestrationTask -TaskId $fx2.tid -Actor 'planner' -ExpectedRevision ([int]$sr2.revision) -ResidualRisks @('s6-fixture-residual') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $fx2.f.tasks -FlagsPath $fx2.f.flags -TelemetryRoot $fx2.f.tele
Assert-S6That ([bool]$dn2.ok) 'S6-4 task DONE without false completion'
$nextRev = Get-S6TaskRev $nextTid $fx2.f.tasks
$nextKey = Get-NativeDispatchHash32 's6-cont-next-key'
$nextPh = Get-NativeDispatchHash32 's6-cont-next-prompt'
$nextIntentSlot = New-OrchestrationNativeDispatchIntent -TaskId $nextTid -TaskExpectedRevision $nextRev -Agent 'coder' -PromptHash $nextPh -Scope @('s6/a.txt') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $nextKey -Owner 'owner-s6' -OwnershipGeneration $fx2.gen -BaseRevision 's6-base'
Assert-S6That ([bool]$nextIntentSlot.ok) 'S6-4 successor intent built for the Planner CLAIM path'
$liveRev2b = [long](Get-OrchestrationGoal -GoalId $fx2.gid -StoreDir $fx2.f.goal).goal['revision']
$w3 = Invoke-ProductiveSettleAndContinue -GoalId $fx2.gid -GoalStoreDir $fx2.f.goal -DispatchStoreDir $fx2.f.dispatch -TasksDir $fx2.f.tasks -FlagsPath $fx2.f.flags -TelemetryRoot $fx2.f.tele -ReceiptDir $fx2.f.receipt -EvidenceStoreDir $fx2.f.evidence -CheckpointDir $fx2.f.ckpt -TaskId $fx2.tid -AttemptRole 'coder' -SessionId $fx2.sess -OwnerId 'owner-s6' -Generation $fx2.gen -ExpectedRevision $liveRev2b -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx2.wid -NativeSettlementContext $fx2.ctx -ContinuationAuthorization $fx2.authND -NextIntent $nextIntentSlot.intent -Productive
Assert-S6That ((($null -ne $w3) -and [bool]$w3.ok) -and [bool]$w3.settled) 'S6-4 re-entry after gates settles idempotent without re-settling'
Assert-S6That (($null -ne $w3.continuation) -and ([string]$w3.continuation.action -ceq 'prepared')) 'S6-4 CONTINUE prepares exactly one successor for the Planner'
Assert-S6That (([string]$w3.continuation.move -ceq 'CONTINUE') -and ([string]$w3.continuation.next_idempotency_key -ceq $nextKey)) 'S6-4 the prepared ref is the Planner next key (no successor executed)'
Assert-S6That (([int]$w3.continuation.executor_calls -eq 0) -and ((Get-S6TaskRev $nextTid $fx2.f.tasks) -eq $nextRev)) 'S6-4 no worker executed and the successor task untouched'
$advDir2 = Get-NDAdvanceDir -RootDir $fx2.f.receipt -GoalId $fx2.gid
Assert-S6That ([bool]$advDir2.ok) 'S6-4 advance dir resolves'
$advPath2 = Join-Path ([string]$advDir2.dir) ($fx2.ndk + '.advance.json')
$advBefore = [IO.File]::ReadAllText($advPath2, [Text.Encoding]::UTF8)
$liveRev2c = [long](Get-OrchestrationGoal -GoalId $fx2.gid -StoreDir $fx2.f.goal).goal['revision']
$w4 = Invoke-ProductiveSettleAndContinue -GoalId $fx2.gid -GoalStoreDir $fx2.f.goal -DispatchStoreDir $fx2.f.dispatch -TasksDir $fx2.f.tasks -FlagsPath $fx2.f.flags -TelemetryRoot $fx2.f.tele -ReceiptDir $fx2.f.receipt -EvidenceStoreDir $fx2.f.evidence -CheckpointDir $fx2.f.ckpt -TaskId $fx2.tid -AttemptRole 'coder' -SessionId $fx2.sess -OwnerId 'owner-s6' -Generation $fx2.gen -ExpectedRevision $liveRev2c -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx2.wid -NativeSettlementContext $fx2.ctx -ContinuationAuthorization $fx2.authND -NextIntent $nextIntentSlot.intent -Productive
Assert-S6That ((($null -ne $w4) -and ($null -ne $w4.continuation)) -and ([string]$w4.continuation.cause_reason -ceq 'advance-record-replay')) 'S6-4 duplicate continuation replays the single recorded decision'
$advAfter = [IO.File]::ReadAllText($advPath2, [Text.Encoding]::UTF8)
$revAfterFirst = Get-S6TaskRev $fx2.tid $fx2.f.tasks
Assert-S6That (($advBefore -ceq $advAfter) -and ((Get-S6TaskRev $fx2.tid $fx2.f.tasks) -eq $revAfterFirst)) 'S6-4 replay persists one successor per goal+settled_key'
# --- S6-5: RED (HIGH-1) - revoked grants replay must HOLD, never continue.
# Settles strictly first, then replays with a deny grant: the reconcile
# denial (POLICY-BLOCKED) is a refusal to preserve, not a hint to consult
# the diary. Old behavior proceeds via the settled diary + synthesized auth.
$fx5 = New-S6NativeFixture -Tag 'deny'
$liveRev5 = [long](Get-OrchestrationGoal -GoalId $fx5.gid -StoreDir $fx5.f.goal).goal['revision']
$w5a = Invoke-ProductiveSettleAndContinue -GoalId $fx5.gid -GoalStoreDir $fx5.f.goal -DispatchStoreDir $fx5.f.dispatch -TasksDir $fx5.f.tasks -FlagsPath $fx5.f.flags -TelemetryRoot $fx5.f.tele -ReceiptDir $fx5.f.receipt -EvidenceStoreDir $fx5.f.evidence -CheckpointDir $fx5.f.ckpt -TaskId $fx5.tid -AttemptRole 'coder' -SessionId $fx5.sess -OwnerId 'owner-s6' -Generation $fx5.gen -ExpectedRevision $liveRev5 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx5.wid -NativeSettlementContext $fx5.ctx -ContinuationAuthorization $fx5.authND -Productive
Assert-S6That ((($null -ne $w5a) -and [bool]$w5a.ok) -and [bool]$w5a.settled) 'S6-5 fixture settles before the deny replay'
$rev5AfterSettle = Get-S6TaskRev $fx5.tid $fx5.f.tasks
$w5b = Invoke-ProductiveSettleAndContinue -GoalId $fx5.gid -GoalStoreDir $fx5.f.goal -DispatchStoreDir $fx5.f.dispatch -TasksDir $fx5.f.tasks -FlagsPath $fx5.f.flags -TelemetryRoot $fx5.f.tele -ReceiptDir $fx5.f.receipt -EvidenceStoreDir $fx5.f.evidence -CheckpointDir $fx5.f.ckpt -TaskId $fx5.tid -AttemptRole 'coder' -SessionId $fx5.sess -OwnerId 'owner-s6' -Generation $fx5.gen -ExpectedRevision $liveRev5 -User 'u' -Project 'p' -Runtime 'V1' -Grants 'deny' -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx5.wid -NativeSettlementContext $fx5.ctx -ContinuationAuthorization $fx5.authND -Productive
Assert-S6That ((($null -ne $w5b) -and (-not [bool]$w5b.ok)) -and (-not [bool]$w5b.settled)) 'S6-5 revoked grants replay HOLDS, never continues'
Assert-S6That (([string]$w5b.reason -like 'productive-settle-denied:*') -and (-not [bool]$w5b.continuation_attempted)) 'S6-5 denial preserved with no continuation attempted'
Assert-S6That (((Get-S6TaskRev $fx5.tid $fx5.f.tasks) -eq $rev5AfterSettle) -and ($null -eq $w5b.continuation)) 'S6-5 denied replay writes nothing and prepares nothing'
# --- S6-6: RED (HIGH-1) - continuation without explicit authorization HOLDS.
# Fresh fixture, single call, no ContinuationAuthorization: approval is never
# synthesized. Old behavior fabricates explicit_allow source=planner.
$fx6 = New-S6NativeFixture -Tag 'noauth'
$liveRev6 = [long](Get-OrchestrationGoal -GoalId $fx6.gid -StoreDir $fx6.f.goal).goal['revision']
$w6 = Invoke-ProductiveSettleAndContinue -GoalId $fx6.gid -GoalStoreDir $fx6.f.goal -DispatchStoreDir $fx6.f.dispatch -TasksDir $fx6.f.tasks -FlagsPath $fx6.f.flags -TelemetryRoot $fx6.f.tele -ReceiptDir $fx6.f.receipt -EvidenceStoreDir $fx6.f.evidence -CheckpointDir $fx6.f.ckpt -TaskId $fx6.tid -AttemptRole 'coder' -SessionId $fx6.sess -OwnerId 'owner-s6' -Generation $fx6.gen -ExpectedRevision $liveRev6 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx6.wid -NativeSettlementContext $fx6.ctx -Productive
Assert-S6That ((($null -ne $w6) -and (-not [bool]$w6.ok)) -and [bool]$w6.settled) 'S6-6 missing continuation authorization HOLDS after a proven settlement'
Assert-S6That (([string]$w6.reason -ceq 'continuation-authorization-required') -and (-not [bool]$w6.continuation_attempted)) 'S6-6 no synthesized approval, no continuation attempted'
Assert-S6That ($null -eq $w6.continuation) 'S6-6 no continuation envelope without explicit authorization'
# --- S6-7: RED (HIGH-2) - legacy non-strict settle replayed under strict HOLDS.
# The diary alone never authorizes: without a persisted provenance tier the
# replay refuses (ND-Settle 6991-7000: replay never inherits provenance that
# never existed). The legacy settlement below goes through the wrapper
# non-strict so the diary AND the native receipt both reach settled with no
# tier persisted.
$fx7 = New-S6NativeFixture -Tag 'legrep'
$ctxLeg7 = Copy-S6Ctx $fx7.ctx
$ctxLeg7.Remove('provenance_proof')
$liveRev7a = [long](Get-OrchestrationGoal -GoalId $fx7.gid -StoreDir $fx7.f.goal).goal['revision']
$w7a = Invoke-ProductiveSettleAndContinue -GoalId $fx7.gid -GoalStoreDir $fx7.f.goal -DispatchStoreDir $fx7.f.dispatch -TasksDir $fx7.f.tasks -FlagsPath $fx7.f.flags -TelemetryRoot $fx7.f.tele -ReceiptDir $fx7.f.receipt -EvidenceStoreDir $fx7.f.evidence -CheckpointDir $fx7.f.ckpt -TaskId $fx7.tid -AttemptRole 'coder' -SessionId $fx7.sess -OwnerId 'owner-s6' -Generation $fx7.gen -ExpectedRevision $liveRev7a -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx7.wid -NativeSettlementContext $ctxLeg7 -ContinuationAuthorization $fx7.authND -StrictProvenance:$false -Productive
Assert-S6That ((($null -ne $w7a) -and [bool]$w7a.ok) -and [bool]$w7a.settled) 'S6-7 fixture settles legacy non-strict (diary settled, no tier)'
$rev7AfterLegacy = Get-S6TaskRev $fx7.tid $fx7.f.tasks
$liveRev7 = [long](Get-OrchestrationGoal -GoalId $fx7.gid -StoreDir $fx7.f.goal).goal['revision']
$w7 = Invoke-ProductiveSettleAndContinue -GoalId $fx7.gid -GoalStoreDir $fx7.f.goal -DispatchStoreDir $fx7.f.dispatch -TasksDir $fx7.f.tasks -FlagsPath $fx7.f.flags -TelemetryRoot $fx7.f.tele -ReceiptDir $fx7.f.receipt -EvidenceStoreDir $fx7.f.evidence -CheckpointDir $fx7.f.ckpt -TaskId $fx7.tid -AttemptRole 'coder' -SessionId $fx7.sess -OwnerId 'owner-s6' -Generation $fx7.gen -ExpectedRevision $liveRev7 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx7.wid -NativeSettlementContext $fx7.ctx -ContinuationAuthorization $fx7.authND -Productive
Assert-S6That ((($null -ne $w7) -and (-not [bool]$w7.ok)) -and (-not [bool]$w7.continuation_attempted)) 'S6-7 legacy-settled replay under strict HOLDS without a persisted tier'
Assert-S6That (([string]$w7.reason -like '*provenance*') -and ((Get-S6TaskRev $fx7.tid $fx7.f.tasks) -eq $rev7AfterLegacy)) 'S6-7 provenance refusal writes nothing new'
# --- S6-8: RED (MEDIUM) - revision 2 requested with revision 1 settled HOLDS.
# The diary consult uses the received revision with exact-key match; revision
# 1 is never a fallback. Old behavior replays via the settled revision 1.
$fx8 = New-S6NativeFixture -Tag 'revmix'
$liveRev8 = [long](Get-OrchestrationGoal -GoalId $fx8.gid -StoreDir $fx8.f.goal).goal['revision']
$w8a = Invoke-ProductiveSettleAndContinue -GoalId $fx8.gid -GoalStoreDir $fx8.f.goal -DispatchStoreDir $fx8.f.dispatch -TasksDir $fx8.f.tasks -FlagsPath $fx8.f.flags -TelemetryRoot $fx8.f.tele -ReceiptDir $fx8.f.receipt -EvidenceStoreDir $fx8.f.evidence -CheckpointDir $fx8.f.ckpt -TaskId $fx8.tid -AttemptRole 'coder' -SessionId $fx8.sess -OwnerId 'owner-s6' -Generation $fx8.gen -ExpectedRevision $liveRev8 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx8.wid -NativeSettlementContext $fx8.ctx -ContinuationAuthorization $fx8.authND -Productive
Assert-S6That ((($null -ne $w8a) -and [bool]$w8a.ok) -and [bool]$w8a.settled) 'S6-8 fixture settles revision 1 before the revision 2 replay'
$rev8AfterSettle = Get-S6TaskRev $fx8.tid $fx8.f.tasks
$w8b = Invoke-ProductiveSettleAndContinue -GoalId $fx8.gid -GoalStoreDir $fx8.f.goal -DispatchStoreDir $fx8.f.dispatch -TasksDir $fx8.f.tasks -FlagsPath $fx8.f.flags -TelemetryRoot $fx8.f.tele -ReceiptDir $fx8.f.receipt -EvidenceStoreDir $fx8.f.evidence -CheckpointDir $fx8.f.ckpt -TaskId $fx8.tid -AttemptRole 'coder' -SessionId $fx8.sess -OwnerId 'owner-s6' -Generation $fx8.gen -ExpectedRevision $liveRev8 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx8.wid -ActionRevision 2 -NativeSettlementContext $fx8.ctx -ContinuationAuthorization $fx8.authND -Productive
Assert-S6That ((($null -ne $w8b) -and (-not [bool]$w8b.ok)) -and (-not [bool]$w8b.continuation_attempted)) 'S6-8 revision 2 without a revision 2 record HOLDS (no revision 1 fallback)'
Assert-S6That ((([string]$w8b.reason -ceq 'settlement-pending') -and ($null -eq $w8b.continuation)) -and ((Get-S6TaskRev $fx8.tid $fx8.f.tasks) -eq $rev8AfterSettle)) 'S6-8 exact-revision HOLD writes nothing and prepares nothing'
# --- S6-9: RED (MEDIUM) - legitimate revision 2 replay proceeds.
# Revision 2 dispatched, settled strictly and DONE-gated replays through the
# revision 2 record. Old behavior consults revision 1 (absent) and HOLDS.
$fx9 = New-S6NativeFixture -Tag 'revtwo' -Rev 2
$nextTid9 = 'pa-task-s6-rev2-next'
New-S6Task $nextTid9 $fx9.gid $fx9.gen $fx9.f
$liveRev9 = [long](Get-OrchestrationGoal -GoalId $fx9.gid -StoreDir $fx9.f.goal).goal['revision']
$w9a = Invoke-ProductiveSettleAndContinue -GoalId $fx9.gid -GoalStoreDir $fx9.f.goal -DispatchStoreDir $fx9.f.dispatch -TasksDir $fx9.f.tasks -FlagsPath $fx9.f.flags -TelemetryRoot $fx9.f.tele -ReceiptDir $fx9.f.receipt -EvidenceStoreDir $fx9.f.evidence -CheckpointDir $fx9.f.ckpt -TaskId $fx9.tid -AttemptRole 'coder' -SessionId $fx9.sess -OwnerId 'owner-s6' -Generation $fx9.gen -ExpectedRevision $liveRev9 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx9.wid -ActionRevision 2 -NativeSettlementContext $fx9.ctx -ContinuationAuthorization $fx9.authND -Productive
Assert-S6That ((($null -ne $w9a) -and [bool]$w9a.ok) -and [bool]$w9a.settled) 'S6-9 revision 2 settles fresh before gating'
$vRev9 = Get-S6TaskRev $fx9.tid $fx9.f.tasks
$vt9 = Invoke-OrchestrationTaskTransition -TaskId $fx9.tid -ToState 'VALIDATING' -Actor 'planner' -ExpectedRevision $vRev9 -ActorIdentitySource 'explicit-cli' -TasksDir $fx9.f.tasks -FlagsPath $fx9.f.flags -TelemetryRoot $fx9.f.tele
Assert-S6That ([bool]$vt9.ok) 'S6-9 task validating'
$rt9 = Invoke-OrchestrationTaskTransition -TaskId $fx9.tid -ToState 'REVIEWING' -Actor 'planner' -ExpectedRevision ([int]$vt9.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $fx9.f.tasks -FlagsPath $fx9.f.flags -TelemetryRoot $fx9.f.tele
Assert-S6That ([bool]$rt9.ok) 'S6-9 task reviewing'
$verJson9 = (@{ ok = $true; task_id = 's6-verifier'; status = 'verified_pass'; reason = 's6 verifier read-back'; scope = $null; profiles = @(); evidence = @('criterion:0:artifact-bytes=12;expected-match=True', 'criterion:0:file=s6-a.txt'); command_classes = @('test') } | ConvertTo-Json -Depth 8 -Compress)
$sv9 = Set-OrchestrationTaskVerification -TaskId $fx9.tid -VerifierEvidenceJson $verJson9 -ExpectedRevision ([int]$rt9.revision) -TasksDir $fx9.f.tasks -FlagsPath $fx9.f.flags
Assert-S6That ([bool]$sv9.ok) 'S6-9 fresh verification recorded'
$sr9 = Set-OrchestrationTaskReview -TaskId $fx9.tid -Kind 'reviewer' -Status 'approved' -By 'reviewer-1' -ExpectedRevision ([int]$sv9.revision) -TasksDir $fx9.f.tasks -FlagsPath $fx9.f.flags
Assert-S6That ([bool]$sr9.ok) 'S6-9 fresh review recorded'
$dn9 = Complete-OrchestrationTask -TaskId $fx9.tid -Actor 'planner' -ExpectedRevision ([int]$sr9.revision) -ResidualRisks @('s6-fixture-residual') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $fx9.f.tasks -FlagsPath $fx9.f.flags -TelemetryRoot $fx9.f.tele
Assert-S6That ([bool]$dn9.ok) 'S6-9 task DONE without false completion'
$nextRev9 = Get-S6TaskRev $nextTid9 $fx9.f.tasks
$nextKey9 = Get-NativeDispatchHash32 's6-rev2-next-key'
$nextPh9 = Get-NativeDispatchHash32 's6-rev2-next-prompt'
$nextIntent9Slot = New-OrchestrationNativeDispatchIntent -TaskId $nextTid9 -TaskExpectedRevision $nextRev9 -Agent 'coder' -PromptHash $nextPh9 -Scope @('s6/a.txt') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $nextKey9 -Owner 'owner-s6' -OwnershipGeneration $fx9.gen -BaseRevision 's6-base'
Assert-S6That ([bool]$nextIntent9Slot.ok) 'S6-9 successor intent built for the Planner CLAIM path'
$liveRev9b = [long](Get-OrchestrationGoal -GoalId $fx9.gid -StoreDir $fx9.f.goal).goal['revision']
$w9b = Invoke-ProductiveSettleAndContinue -GoalId $fx9.gid -GoalStoreDir $fx9.f.goal -DispatchStoreDir $fx9.f.dispatch -TasksDir $fx9.f.tasks -FlagsPath $fx9.f.flags -TelemetryRoot $fx9.f.tele -ReceiptDir $fx9.f.receipt -EvidenceStoreDir $fx9.f.evidence -CheckpointDir $fx9.f.ckpt -TaskId $fx9.tid -AttemptRole 'coder' -SessionId $fx9.sess -OwnerId 'owner-s6' -Generation $fx9.gen -ExpectedRevision $liveRev9b -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx9.wid -ActionRevision 2 -NativeSettlementContext $fx9.ctx -ContinuationAuthorization $fx9.authND -NextIntent $nextIntent9Slot.intent -Productive
Assert-S6That ((($null -ne $w9b) -and [bool]$w9b.ok) -and [bool]$w9b.settled) 'S6-9 revision 2 replays idempotent without re-settling'
Assert-S6That (($null -ne $w9b.continuation) -and ([string]$w9b.continuation.action -ceq 'prepared')) 'S6-9 revision 2 CONTINUE prepares exactly one successor'
Assert-S6That (([string]$w9b.continuation.next_idempotency_key -ceq $nextKey9) -and ([int]$w9b.continuation.executor_calls -eq 0)) 'S6-9 the prepared ref is the Planner next key, no worker executed'
# --- S6-10: RED (HIGH) - cross-settlement replay HOLDS (diary A + proof B).
# Two strict settlements share one goal. Replaying A's diary with B's
# native context/proof must HOLD with a correlation reason: the diary
# and the receipt are each valid alone, but they never correlate to
# the same requested binding (TaskId/session/call/child/key).
$fxX = New-S6NativeFixture -Tag 'corr'
$liveRevX = [long](Get-OrchestrationGoal -GoalId $fxX.gid -StoreDir $fxX.f.goal).goal['revision']
$wXa = Invoke-ProductiveSettleAndContinue -GoalId $fxX.gid -GoalStoreDir $fxX.f.goal -DispatchStoreDir $fxX.f.dispatch -TasksDir $fxX.f.tasks -FlagsPath $fxX.f.flags -TelemetryRoot $fxX.f.tele -ReceiptDir $fxX.f.receipt -EvidenceStoreDir $fxX.f.evidence -CheckpointDir $fxX.f.ckpt -TaskId $fxX.tid -AttemptRole 'coder' -SessionId $fxX.sess -OwnerId 'owner-s6' -Generation $fxX.gen -ExpectedRevision $liveRevX -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fxX.wid -NativeSettlementContext $fxX.ctx -ContinuationAuthorization $fxX.authND -Productive
Assert-S6That ((($null -ne $wXa) -and [bool]$wXa.ok) -and [bool]$wXa.settled) 'S6-10 fixture settles A strictly before gating'
$vRevX = Get-S6TaskRev $fxX.tid $fxX.f.tasks
$vtX = Invoke-OrchestrationTaskTransition -TaskId $fxX.tid -ToState 'VALIDATING' -Actor 'planner' -ExpectedRevision $vRevX -ActorIdentitySource 'explicit-cli' -TasksDir $fxX.f.tasks -FlagsPath $fxX.f.flags -TelemetryRoot $fxX.f.tele
Assert-S6That ([bool]$vtX.ok) 'S6-10 task A validating'
$rtX = Invoke-OrchestrationTaskTransition -TaskId $fxX.tid -ToState 'REVIEWING' -Actor 'planner' -ExpectedRevision ([int]$vtX.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $fxX.f.tasks -FlagsPath $fxX.f.flags -TelemetryRoot $fxX.f.tele
Assert-S6That ([bool]$rtX.ok) 'S6-10 task A reviewing'
$verJsonX = (@{ ok = $true; task_id = 's6-verifier'; status = 'verified_pass'; reason = 's6 verifier read-back'; scope = $null; profiles = @(); evidence = @('criterion:0:artifact-bytes=12;expected-match=True', 'criterion:0:file=s6-a.txt'); command_classes = @('test') } | ConvertTo-Json -Depth 8 -Compress)
$svX = Set-OrchestrationTaskVerification -TaskId $fxX.tid -VerifierEvidenceJson $verJsonX -ExpectedRevision ([int]$rtX.revision) -TasksDir $fxX.f.tasks -FlagsPath $fxX.f.flags
Assert-S6That ([bool]$svX.ok) 'S6-10 fresh verification recorded for A'
$srX = Set-OrchestrationTaskReview -TaskId $fxX.tid -Kind 'reviewer' -Status 'approved' -By 'reviewer-1' -ExpectedRevision ([int]$svX.revision) -TasksDir $fxX.f.tasks -FlagsPath $fxX.f.flags
Assert-S6That ([bool]$srX.ok) 'S6-10 fresh review recorded for A'
$dnX = Complete-OrchestrationTask -TaskId $fxX.tid -Actor 'planner' -ExpectedRevision ([int]$srX.revision) -ResidualRisks @('s6-fixture-residual') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $fxX.f.tasks -FlagsPath $fxX.f.flags -TelemetryRoot $fxX.f.tele
Assert-S6That ([bool]$dnX.ok) 'S6-10 task A DONE without false completion'
$widB = 'w-s6-corr-b'
$tidB = 'pa-task-s6-corr-b'
$sessB = 'pa-session-s6-corr-b'
New-S6Task $tidB $fxX.gid $fxX.gen $fxX.f
$evB = (New-OrchestrationObjectiveEvent -GoalId $fxX.gid -Type 'task-settled' -WorkItemId $widB -ActionRevision 1).event
$grevLiveB = [long](Get-OrchestrationGoal -GoalId $fxX.gid -StoreDir $fxX.f.goal).goal['revision']
$resB = Invoke-ProductiveObjectiveEvent -Event $evB -GoalStoreDir $fxX.f.goal -DispatchStoreDir $fxX.f.dispatch -CheckpointStoreDir $fxX.f.ckpt -TasksDir $fxX.f.tasks -FlagsPath $fxX.f.flags -TelemetryRoot $fxX.f.tele -TaskId $tidB -AttemptRole 'coder' -SessionId $sessB -OwnerId 'owner-s6' -Generation $fxX.gen -ExpectedRevision $grevLiveB -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch' -Productive
Assert-S6That (([bool]$resB.ok) -and [bool]$resB.dispatched) 'S6-10 setup dispatch B in the same goal'
$ndkB = Get-NativeDispatchHash32 's6-key-corr-b'
$phB = Get-NativeDispatchHash32 's6-prompt-corr-b'
$niB = New-OrchestrationNativeDispatchIntent -TaskId $tidB -TaskExpectedRevision 4 -Agent 'coder' -PromptHash $phB -Scope @('s6/a.txt') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $ndkB -Owner 'owner-s6' -OwnershipGeneration $fxX.gen -BaseRevision 's6-base'
Assert-S6That ([bool]$niB.ok) 'S6-10 successor intent built for B'
$msgB = 'msg-s6-corr-b'
$callB = 'call-s6-corr-b'
$childB = 'ses-s6-corr-b-child'
$pB = Invoke-OrchestrationNativeDispatchPrepare -Intent $niB.intent -Authorization $fxX.authND -SessionId $sessB -ReceiptDir $fxX.f.receipt -GoalStoreDir $fxX.f.goal -TasksDir $fxX.f.tasks -FlagsPath $fxX.f.flags
Assert-S6That ([bool]$pB.ok) 'S6-10 setup prepare B'
$cB = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $ndkB -Authorization $fxX.authND -SessionId $sessB -MessageId $msgB -CallId $callB -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$pB.prepared_fingerprint) -ReceiptDir $fxX.f.receipt -GoalStoreDir $fxX.f.goal -TasksDir $fxX.f.tasks -FlagsPath $fxX.f.flags
Assert-S6That ([bool]$cB.ok) 'S6-10 setup claim B'
$goalRevB = [long](Get-OrchestrationGoal -GoalId $fxX.gid -StoreDir $fxX.f.goal).goal['revision']
$proofB = @{ child_session_id = $childB; parent_session_id = $sessB; call_id = $callB; idempotency_key = $ndkB; source = 'plugin-session-get'; claimed_evidence = @('criterion:0') }
$ctxB = @{ task_id = $tidB; receipt_root = $fxX.f.receipt; idempotency_key = $ndkB; prepared_fingerprint = ([string]$pB.prepared_fingerprint); parent_session_id = $sessB; message_id = $msgB; call_id = $callB; caller_agent = 'planner'; target_agent = 'coder'; child_session_id = $childB; goal_id = $fxX.gid; owner = 'owner-s6'; generation = $fxX.gen; goal_store_dir = $fxX.f.goal; evidence_store_dir = $fxX.f.evidence; reference = ([string]$pB.reference); goal_revision = $goalRevB; status = 'candidate_pass'; produced_by = 'coder'; claimed_evidence = @('criterion:0'); authorization = @{ explicit_allow = $true; goal_id = $fxX.gid; owner = 'owner-s6'; generation = $fxX.gen; source = 'planner' }; provenance_proof = $proofB }
$liveRevXB = [long](Get-OrchestrationGoal -GoalId $fxX.gid -StoreDir $fxX.f.goal).goal['revision']
$wXb = Invoke-ProductiveSettleAndContinue -GoalId $fxX.gid -GoalStoreDir $fxX.f.goal -DispatchStoreDir $fxX.f.dispatch -TasksDir $fxX.f.tasks -FlagsPath $fxX.f.flags -TelemetryRoot $fxX.f.tele -ReceiptDir $fxX.f.receipt -EvidenceStoreDir $fxX.f.evidence -CheckpointDir $fxX.f.ckpt -TaskId $tidB -AttemptRole 'coder' -SessionId $sessB -OwnerId 'owner-s6' -Generation $fxX.gen -ExpectedRevision $liveRevXB -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $widB -NativeSettlementContext $ctxB -ContinuationAuthorization $fxX.authND -Productive
Assert-S6That ((($null -ne $wXb) -and [bool]$wXb.ok) -and [bool]$wXb.settled) 'S6-10 fixture settles B strictly in the same goal'
$nextTidX = 'pa-task-s6-corr-next'
New-S6Task $nextTidX $fxX.gid $fxX.gen $fxX.f
$nextRevX = Get-S6TaskRev $nextTidX $fxX.f.tasks
$nextKeyX = Get-NativeDispatchHash32 's6-corr-next-key'
$nextPhX = Get-NativeDispatchHash32 's6-corr-next-prompt'
$nextIntentXSlot = New-OrchestrationNativeDispatchIntent -TaskId $nextTidX -TaskExpectedRevision $nextRevX -Agent 'coder' -PromptHash $nextPhX -Scope @('s6/a.txt') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $nextKeyX -Owner 'owner-s6' -OwnershipGeneration $fxX.gen -BaseRevision 's6-base'
Assert-S6That ([bool]$nextIntentXSlot.ok) 'S6-10 successor intent built for the cross replay'
$revXBefore = Get-S6TaskRev $fxX.tid $fxX.f.tasks
$revBBefore = Get-S6TaskRev $tidB $fxX.f.tasks
$liveRevXc = [long](Get-OrchestrationGoal -GoalId $fxX.gid -StoreDir $fxX.f.goal).goal['revision']
$wXx = Invoke-ProductiveSettleAndContinue -GoalId $fxX.gid -GoalStoreDir $fxX.f.goal -DispatchStoreDir $fxX.f.dispatch -TasksDir $fxX.f.tasks -FlagsPath $fxX.f.flags -TelemetryRoot $fxX.f.tele -ReceiptDir $fxX.f.receipt -EvidenceStoreDir $fxX.f.evidence -CheckpointDir $fxX.f.ckpt -TaskId $fxX.tid -AttemptRole 'coder' -SessionId $fxX.sess -OwnerId 'owner-s6' -Generation $fxX.gen -ExpectedRevision $liveRevXc -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:S6Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fxX.wid -NativeSettlementContext $ctxB -ContinuationAuthorization $fxX.authND -NextIntent $nextIntentXSlot.intent -Productive
Assert-S6That ((($null -ne $wXx) -and (-not [bool]$wXx.ok)) -and (-not [bool]$wXx.continuation_attempted)) 'S6-10 cross-settlement replay HOLDS, never continues B'
Assert-S6That (([string]$wXx.reason -like '*correlation*') -and ($null -eq $wXx.continuation)) 'S6-10 HOLD names correlation and prepares nothing'
Assert-S6That (((Get-S6TaskRev $fxX.tid $fxX.f.tasks) -eq $revXBefore) -and ((Get-S6TaskRev $tidB $fxX.f.tasks) -eq $revBBefore)) 'S6-10 cross replay writes nothing new'
try { Remove-Item -LiteralPath $fx0.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx1.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fxL.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx2.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx5.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx6.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx7.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx8.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fx9.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fxX.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
'PASS: {0}' -f $passed
