<#!
.SYNOPSIS
    Harness S6 Etapa D: prova 3 fases (harness-only, sem runtime real).
.DESCRIPTION
    Hermetic: temp dirs, cleanup ao final; repo nunca escrito (a
    validation-policy.json real e apenas LIDA). Throw no primeiro FAIL,
    imprime contagem no sucesso. Exit 0 tudo pass, 1 qualquer fail.
    PS 5.1 compatible, ASCII-only. Sem network, sem spawn, sem Executor,
    sem flags/pins, sem commit.
    FASE 1 (RED): fixture com conteudo verificavel (goal/task TEMP +
    arquivo payload com bytes conhecidos); settle via
    Invoke-ProductiveSettleAndContinue com auth explicita + proof
    sintetico; sem verificacao o gate bloqueia CONTINUE
    (continuation-verification-required), com exatamente 1 escrita kernel.
    FASE 2 (RED->GREEN): validacao real detecta erro intencional: review
    changes_required bloqueia CONTINUE (continuation-changes-required) e
    o DONE e recusado (sem false DONE); corrigido com review approved +
    DONE, o harness re-chama a continuacao sozinho (sem comando manual).
    FASE 3 (GREEN): apos gates frescos, a re-chamada prepara exatamente
    1 sucessor via ObjectiveStep SettledKey (advance record unico,
    sucessor intocado, executor_calls 0, goal ainda ACTIVE: sem false
    DONE). Negativos: duplicata (replay unico), task errada (HOLD),
    lease expirada (HOLD), review reject (bloqueado, sem DONE).
    SOFT_ADVISORY: fixtures sintetizam host proofs (source
    plugin-session-get); strictness aqui valida plumbing (binding +
    tier persistido), nunca atestacao real do host.
    VEREDITO: HARNESS_PASS apenas. RUNTIME_REAL_PASS NAO alegado. Gap
    para runtime-real: child session observada no host + proof por canal
    confiavel (host attestation); este harness usa proof sintetico no
    mesmo processo, entao prova o wiring dos gates, nao o transporte.
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
function Assert-H3That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function Write-H3File {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n")
    $lf = ($lf -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}
function New-H3Root {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('pa-h3-' + [guid]::NewGuid().ToString('N'))
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
    Write-H3File -Path $flags -Text '{"task_kernel":{"enabled":true,"shadow":false}}'
    return @{ root = $root; goal = $goal; dispatch = $dispatch; ckpt = $ckpt; tasks = $tasks; tele = $tele; flags = $flags; receipt = $receipt; evidence = $evidence }
}
$script:H3Full = 'ops allow:dispatch allow:settlement allow:checkpoint allow:advance allow:terminalize allow:reconcile'
function New-H3Goal {
    param([string]$Id, [string]$GoalDir)
    $n = New-OrchestrationGoal -GoalId $Id -Objective ('h3 objective ' + $Id) -Criteria @('h3-crit-a', 'h3-crit-b') -StoreDir $GoalDir
    if (-not [bool]$n.ok) { throw "FAIL: setup new goal $Id" }
    $act = Set-OrchestrationGoalState -Goal $n.goal -ToState 'ACTIVE'
    $sv = Save-OrchestrationGoal -Goal $act.goal -StoreDir $GoalDir
    if (-not [bool]$sv.ok) { throw "FAIL: setup save $Id" }
    $own = Acquire-OrchestrationGoalOwnership -GoalId $Id -OwnerId 'owner-h3' -ExpectedRevision ([long]$sv.revision) -StoreDir $GoalDir
    if (-not [bool]$own.ok) { throw "FAIL: setup ownership $Id" }
    return $own
}
function New-H3Task {
    param([string]$Id, [string]$GoalId, [long]$Gen, $F)
    $t = New-OrchestrationTask -TaskId $Id -Objective ('h3 fixture work ' + $Id) -Actor 'owner-h3' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' -TaskType 'implementation' -Risk 'low' -BaseRevision 'h3-base' -ReadScopes @('h3/a.txt') -WriteScopes @('h3/a.txt') -Grants @('fs.read', 'fs.write') -AcceptanceCriteria @('criterion:0') -SettlementPolicy 'canonical-native-settle' -AttemptBudget 3 -TasksDir $F.tasks -FlagsPath $F.flags -TelemetryRoot $F.tele
    if (-not [bool]$t.ok) { throw ("FAIL: setup task " + $Id + " " + [string]$t.error) }
    $r1 = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision ([int]$t.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $F.tasks -FlagsPath $F.flags -TelemetryRoot $F.tele
    if (-not [bool]$r1.ok) { throw ("FAIL: setup planning " + $Id) }
    $r2 = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision ([int]$r1.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $F.tasks -FlagsPath $F.flags -TelemetryRoot $F.tele
    if (-not [bool]$r2.ok) { throw ("FAIL: setup implementing " + $Id) }
    $grev = [long](Get-OrchestrationGoal -GoalId $GoalId -StoreDir $F.goal).goal['revision']
    $add = Add-OrchestrationGoalTaskPersisted -GoalId $GoalId -TaskId $Id -ExpectedRevision $grev -StoreDir $F.goal -OwnerId 'owner-h3' -OwnershipGeneration $Gen
    if (-not [bool]$add.ok) { throw ("FAIL: setup attach " + $Id) }
}
function Get-H3TaskRev {
    param([string]$Id, [string]$TasksDir)
    $rec = Get-OrchestrationTask -TaskId $Id -TasksDir $TasksDir
    if (($null -eq $rec) -or (-not ($rec -is [System.Collections.IDictionary]))) { return -1 }
    if (-not $rec.Contains('revision')) { return -1 }
    return ([int]$rec['revision'])
}
function New-H3NativeFixture {
    param([string]$Tag, [long]$Rev = 1)
    $f = New-H3Root
    $gid = ('PA-H3-' + $Tag)
    $tid = ('pa-task-h3-' + $Tag).ToLowerInvariant()
    $wid = ('w-h3-' + $Tag)
    $sess = ('pa-session-h3-' + $Tag)
    $own = New-H3Goal $gid $f.goal
    $gen = [long]$own.ownership['generation']
    New-H3Task $tid $gid $gen $f
    $payloadText = 'h3-verifiable-payload-3ph'
    $payloadPath = Join-Path $f.evidence 'harness-payload.txt'
    Write-H3File -Path $payloadPath -Text $payloadText
    $payloadBytes = ([Text.Encoding]::UTF8.GetBytes($payloadText)).Length
    $ev = (New-OrchestrationObjectiveEvent -GoalId $gid -Type 'task-settled' -WorkItemId $wid -ActionRevision $Rev).event
    $grevLive = [long](Get-OrchestrationGoal -GoalId $gid -StoreDir $f.goal).goal['revision']
    $res = Invoke-ProductiveObjectiveEvent -Event $ev -GoalStoreDir $f.goal -DispatchStoreDir $f.dispatch -CheckpointStoreDir $f.ckpt -TasksDir $f.tasks -FlagsPath $f.flags -TelemetryRoot $f.tele -TaskId $tid -AttemptRole 'coder' -SessionId $sess -OwnerId 'owner-h3' -Generation $gen -ExpectedRevision $grevLive -User 'u' -Project 'p' -Runtime 'V1' -Grants 'ops allow:dispatch' -Productive
    if ((-not [bool]$res.ok) -or (-not [bool]$res.dispatched)) { throw "FAIL: H3 setup dispatch $Tag" }
    $ndk = Get-NativeDispatchHash32 ('h3-key-' + $Tag)
    $ph = Get-NativeDispatchHash32 ('h3-prompt-' + $Tag)
    $ni = New-OrchestrationNativeDispatchIntent -TaskId $tid -TaskExpectedRevision 4 -Agent 'coder' -PromptHash $ph -Scope @('h3/a.txt') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $ndk -Owner 'owner-h3' -OwnershipGeneration $gen -BaseRevision 'h3-base'
    if (-not [bool]$ni.ok) { throw ("FAIL: H3 setup intent " + $Tag + " " + [string]$ni.reason) }
    $authND = @{ explicit_allow = $true; goal_id = $gid; owner = 'owner-h3'; generation = $gen; source = 'planner' }
    $p = Invoke-OrchestrationNativeDispatchPrepare -Intent $ni.intent -Authorization $authND -SessionId $sess -ReceiptDir $f.receipt -GoalStoreDir $f.goal -TasksDir $f.tasks -FlagsPath $f.flags
    if (-not [bool]$p.ok) { throw ("FAIL: H3 setup prepare " + $Tag + " " + [string]$p.reason) }
    $msg = ('msg-h3-' + $Tag)
    $call = ('call-h3-' + $Tag)
    $child = ('ses-h3-' + $Tag + '-child')
    $c = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $ndk -Authorization $authND -SessionId $sess -MessageId $msg -CallId $call -CallerAgent 'planner' -TargetAgent 'coder' -PreparedFingerprint ([string]$p.prepared_fingerprint) -ReceiptDir $f.receipt -GoalStoreDir $f.goal -TasksDir $f.tasks -FlagsPath $f.flags
    if (-not [bool]$c.ok) { throw ("FAIL: H3 setup claim " + $Tag + " " + [string]$c.reason) }
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
        goal_id = $gid; owner = 'owner-h3'; generation = $gen
        goal_store_dir = $f.goal; evidence_store_dir = $f.evidence
        reference = ([string]$p.reference); goal_revision = $goalRev
        status = 'candidate_pass'; produced_by = 'coder'; claimed_evidence = @('criterion:0')
        authorization = @{ explicit_allow = $true; goal_id = $gid; owner = 'owner-h3'; generation = $gen; source = 'planner' }
        provenance_proof = $proof
    }
    return @{ f = $f; gid = $gid; tid = $tid; wid = $wid; sess = $sess; gen = $gen; ndk = $ndk; msg = $msg; call = $call; child = $child; prep = $p; claim = $c; ctx = $ctx; proof = $proof; authND = $authND; payloadBytes = $payloadBytes; payloadPath = $payloadPath }
}
function New-H3VerifierJson {
    param([int]$Bytes)
    return (@{ ok = $true; task_id = 'h3-verifier'; status = 'verified_pass'; reason = 'h3 verifier read-back'; scope = $null; profiles = @(); evidence = @('criterion:0:artifact-bytes=' + [string]$Bytes + ';expected-match=True', 'criterion:0:file=harness-payload.txt'); command_classes = @('test') } | ConvertTo-Json -Depth 8 -Compress)
}
# --- FASE 1 (RED): fixture verificavel + settle; sem verificacao o gate bloqueia CONTINUE.
$fx = New-H3NativeFixture -Tag '3ph'
Assert-H3That (Test-Path -LiteralPath $fx.payloadPath -PathType Leaf) 'H3 fase1 payload file existe (conteudo verificavel)'
$rawBytes = [IO.File]::ReadAllBytes($fx.payloadPath)
Assert-H3That (($rawBytes.Length -eq [int]$fx.payloadBytes) -and ([int]$fx.payloadBytes -gt 0)) 'H3 fase1 payload bytes conhecidos e nao vazios'
$nextTid = 'pa-task-h3-3ph-next'
New-H3Task $nextTid $fx.gid $fx.gen $fx.f
$nextRev0 = Get-H3TaskRev $nextTid $fx.f.tasks
$nextKey = Get-NativeDispatchHash32 'h3-3ph-next-key'
$nextPh = Get-NativeDispatchHash32 'h3-3ph-next-prompt'
$nextIntentSlot = New-OrchestrationNativeDispatchIntent -TaskId $nextTid -TaskExpectedRevision $nextRev0 -Agent 'coder' -PromptHash $nextPh -Scope @('h3/a.txt') -AcceptanceCriteria @('criterion:0') -IdempotencyKey $nextKey -Owner 'owner-h3' -OwnershipGeneration $fx.gen -BaseRevision 'h3-base'
Assert-H3That ([bool]$nextIntentSlot.ok) 'H3 fase1 sucessor intent construido (Planner CLAIM path)'
$rev0 = Get-H3TaskRev $fx.tid $fx.f.tasks
$liveRev0 = [long](Get-OrchestrationGoal -GoalId $fx.gid -StoreDir $fx.f.goal).goal['revision']
$wA = Invoke-ProductiveSettleAndContinue -GoalId $fx.gid -GoalStoreDir $fx.f.goal -DispatchStoreDir $fx.f.dispatch -TasksDir $fx.f.tasks -FlagsPath $fx.f.flags -TelemetryRoot $fx.f.tele -ReceiptDir $fx.f.receipt -EvidenceStoreDir $fx.f.evidence -CheckpointDir $fx.f.ckpt -TaskId $fx.tid -AttemptRole 'coder' -SessionId $fx.sess -OwnerId 'owner-h3' -Generation $fx.gen -ExpectedRevision $liveRev0 -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:H3Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx.wid -NativeSettlementContext $fx.ctx -ContinuationAuthorization $fx.authND -NextIntent $nextIntentSlot.intent -Productive
Assert-H3That ((($null -ne $wA) -and [bool]$wA.ok) -and [bool]$wA.settled) 'H3 fase1 settle prova via owner canonico (auth explicita + proof)'
Assert-H3That ([string]$wA.settled_key -ceq $fx.ndk) 'H3 fase1 resultado persistido sob a chave nativa'
Assert-H3That (((Get-H3TaskRev $fx.tid $fx.f.tasks) -eq ($rev0 + 1)) -and [bool]$wA.continuation_attempted) 'H3 fase1 exatamente 1 escrita kernel + continuacao tentada'
Assert-H3That (($null -ne $wA.continuation) -and ([string]$wA.continuation.action -ceq 'blocked')) 'H3 fase1 RED: sem verificacao CONTINUE bloqueia'
Assert-H3That ([string]$wA.continuation.reason -ceq 'continuation-verification-required') 'H3 fase1 bloqueio nomeia o gate (verification-required)'
Assert-H3That (((-not [bool]$wA.grants_authority) -and (-not [bool]$wA.done_approved)) -and (-not [bool]$wA.verified_pass)) 'H3 fase1 sem autoridade/DONE/pass forjado'
# --- FASE 2 (RED->GREEN): erro intencional detectado e corrigido.
$vRev = Get-H3TaskRev $fx.tid $fx.f.tasks
$vt = Invoke-OrchestrationTaskTransition -TaskId $fx.tid -ToState 'VALIDATING' -Actor 'planner' -ExpectedRevision $vRev -ActorIdentitySource 'explicit-cli' -TasksDir $fx.f.tasks -FlagsPath $fx.f.flags -TelemetryRoot $fx.f.tele
Assert-H3That ([bool]$vt.ok) 'H3 fase2 task validating'
$rt = Invoke-OrchestrationTaskTransition -TaskId $fx.tid -ToState 'REVIEWING' -Actor 'planner' -ExpectedRevision ([int]$vt.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $fx.f.tasks -FlagsPath $fx.f.flags -TelemetryRoot $fx.f.tele
Assert-H3That ([bool]$rt.ok) 'H3 fase2 task reviewing'
$sv = Set-OrchestrationTaskVerification -TaskId $fx.tid -VerifierEvidenceJson (New-H3VerifierJson -Bytes ([int]$fx.payloadBytes)) -ExpectedRevision ([int]$rt.revision) -TasksDir $fx.f.tasks -FlagsPath $fx.f.flags
Assert-H3That ([bool]$sv.ok) 'H3 fase2 verificacao real registrada (read-back do payload)'
$srBad = Set-OrchestrationTaskReview -TaskId $fx.tid -Kind 'reviewer' -Status 'changes_required' -By 'reviewer-1' -ExpectedRevision ([int]$sv.revision) -TasksDir $fx.f.tasks -FlagsPath $fx.f.flags
Assert-H3That ([bool]$srBad.ok) 'H3 fase2 review registra defeito intencional (changes_required)'
$dnBad = Complete-OrchestrationTask -TaskId $fx.tid -Actor 'planner' -ExpectedRevision ([int]$srBad.revision) -ResidualRisks @('h3-fixture-residual') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $fx.f.tasks -FlagsPath $fx.f.flags -TelemetryRoot $fx.f.tele
Assert-H3That (-not [bool]$dnBad.ok) 'H3 fase2 review reject: DONE recusado (sem false DONE)'
Assert-H3That ((Get-OrchestrationTask -TaskId $fx.tid -TasksDir $fx.f.tasks)['state'] -cne 'DONE') 'H3 fase2 task segue nao-DONE apos reject'
$liveRevB = [long](Get-OrchestrationGoal -GoalId $fx.gid -StoreDir $fx.f.goal).goal['revision']
$wB = Invoke-ProductiveSettleAndContinue -GoalId $fx.gid -GoalStoreDir $fx.f.goal -DispatchStoreDir $fx.f.dispatch -TasksDir $fx.f.tasks -FlagsPath $fx.f.flags -TelemetryRoot $fx.f.tele -ReceiptDir $fx.f.receipt -EvidenceStoreDir $fx.f.evidence -CheckpointDir $fx.f.ckpt -TaskId $fx.tid -AttemptRole 'coder' -SessionId $fx.sess -OwnerId 'owner-h3' -Generation $fx.gen -ExpectedRevision $liveRevB -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:H3Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx.wid -NativeSettlementContext $fx.ctx -ContinuationAuthorization $fx.authND -NextIntent $nextIntentSlot.intent -Productive
Assert-H3That ((($null -ne $wB) -and ($null -ne $wB.continuation)) -and ([string]$wB.continuation.action -ceq 'blocked')) 'H3 fase2 RED: gate detecta review nao aprovado e bloqueia'
Assert-H3That ([string]$wB.continuation.reason -ceq 'continuation-changes-required') 'H3 fase2 bloqueio nomeia changes-required'
$srGood = Set-OrchestrationTaskReview -TaskId $fx.tid -Kind 'reviewer' -Status 'approved' -By 'reviewer-1' -ExpectedRevision ([int]$srBad.revision) -TasksDir $fx.f.tasks -FlagsPath $fx.f.flags
Assert-H3That ([bool]$srGood.ok) 'H3 fase2 correcao: review approved fresco'
$dn = Complete-OrchestrationTask -TaskId $fx.tid -Actor 'planner' -ExpectedRevision ([int]$srGood.revision) -ResidualRisks @('h3-fixture-residual') -OrchestrationCompliance 'COMPLIANT' -ActorIdentitySource 'explicit-cli' -TasksDir $fx.f.tasks -FlagsPath $fx.f.flags -TelemetryRoot $fx.f.tele
Assert-H3That ([bool]$dn.ok) 'H3 fase2 task DONE apos correcao (sem falsificacao: gate passou)'
# --- FASE 3 (GREEN): harness re-chama sozinho via SettledKey; 1 sucessor, sem execucao.
$revBeforeC = Get-H3TaskRev $fx.tid $fx.f.tasks
$liveRevC = [long](Get-OrchestrationGoal -GoalId $fx.gid -StoreDir $fx.f.goal).goal['revision']
$wC = Invoke-ProductiveSettleAndContinue -GoalId $fx.gid -GoalStoreDir $fx.f.goal -DispatchStoreDir $fx.f.dispatch -TasksDir $fx.f.tasks -FlagsPath $fx.f.flags -TelemetryRoot $fx.f.tele -ReceiptDir $fx.f.receipt -EvidenceStoreDir $fx.f.evidence -CheckpointDir $fx.f.ckpt -TaskId $fx.tid -AttemptRole 'coder' -SessionId $fx.sess -OwnerId 'owner-h3' -Generation $fx.gen -ExpectedRevision $liveRevC -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:H3Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx.wid -NativeSettlementContext $fx.ctx -ContinuationAuthorization $fx.authND -NextIntent $nextIntentSlot.intent -Productive
Assert-H3That ((($null -ne $wC) -and [bool]$wC.ok) -and [bool]$wC.settled) 'H3 fase3 re-entrada idempotente apos gates (sem re-settle)'
Assert-H3That (($null -ne $wC.continuation) -and ([string]$wC.continuation.action -ceq 'prepared')) 'H3 fase3 GREEN: CONTINUE prepara exatamente 1 sucessor'
Assert-H3That (([string]$wC.continuation.move -ceq 'CONTINUE') -and ([string]$wC.continuation.next_idempotency_key -ceq $nextKey)) 'H3 fase3 ref preparada e a proxima chave do Planner (sucessor nao executado)'
Assert-H3That (([int]$wC.continuation.executor_calls -eq 0) -and ((Get-H3TaskRev $nextTid $fx.f.tasks) -eq $nextRev0)) 'H3 fase3 zero worker calls; sucessor intocado'
Assert-H3That ((Get-H3TaskRev $fx.tid $fx.f.tasks) -eq $revBeforeC) 'H3 fase3 nenhuma escrita nova no re-settle'
Assert-H3That (([string](Get-OrchestrationGoal -GoalId $fx.gid -StoreDir $fx.f.goal).goal['state'] -ceq 'ACTIVE')) 'H3 fase3 goal segue ACTIVE (task DONE != objective DONE: sem false DONE)'
$advDir = Get-NDAdvanceDir -RootDir $fx.f.receipt -GoalId $fx.gid
Assert-H3That ([bool]$advDir.ok) 'H3 fase3 advance dir resolve'
$advFiles = @(Get-ChildItem -LiteralPath ([string]$advDir.dir) -Filter '*.advance.json' -ErrorAction SilentlyContinue)
Assert-H3That ((@($advFiles).Count -eq 1) -and (([string]$advFiles[0].Name) -ceq ($fx.ndk + '.advance.json'))) 'H3 fase3 transicao: exatamente 1 advance record (1 sucessor)'
$advBytesBefore = [IO.File]::ReadAllText($advFiles[0].FullName, [Text.Encoding]::UTF8)
# --- Negativo: duplicata replaya a decisao unica, sem efeito novo.
$liveRevD = [long](Get-OrchestrationGoal -GoalId $fx.gid -StoreDir $fx.f.goal).goal['revision']
$wD = Invoke-ProductiveSettleAndContinue -GoalId $fx.gid -GoalStoreDir $fx.f.goal -DispatchStoreDir $fx.f.dispatch -TasksDir $fx.f.tasks -FlagsPath $fx.f.flags -TelemetryRoot $fx.f.tele -ReceiptDir $fx.f.receipt -EvidenceStoreDir $fx.f.evidence -CheckpointDir $fx.f.ckpt -TaskId $fx.tid -AttemptRole 'coder' -SessionId $fx.sess -OwnerId 'owner-h3' -Generation $fx.gen -ExpectedRevision $liveRevD -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:H3Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fx.wid -NativeSettlementContext $fx.ctx -ContinuationAuthorization $fx.authND -NextIntent $nextIntentSlot.intent -Productive
Assert-H3That ((($null -ne $wD) -and ($null -ne $wD.continuation)) -and ([string]$wD.continuation.cause_reason -ceq 'advance-record-replay')) 'H3 negativo duplicata: replay da decisao unica'
$advBytesAfter = [IO.File]::ReadAllText($advFiles[0].FullName, [Text.Encoding]::UTF8)
Assert-H3That (($advBytesBefore -ceq $advBytesAfter) -and ((Get-H3TaskRev $fx.tid $fx.f.tasks) -eq $revBeforeC)) 'H3 negativo duplicata: 1 sucessor por goal+settled_key, zero escrita nova'
# --- Negativo: task errada HOLD (sem continuacao, sem escrita).
$fxBad = New-H3NativeFixture -Tag 'badtask'
$revBad0 = Get-H3TaskRev $fxBad.tid $fxBad.f.tasks
$liveRevBad = [long](Get-OrchestrationGoal -GoalId $fxBad.gid -StoreDir $fxBad.f.goal).goal['revision']
$wBad = Invoke-ProductiveSettleAndContinue -GoalId $fxBad.gid -GoalStoreDir $fxBad.f.goal -DispatchStoreDir $fxBad.f.dispatch -TasksDir $fxBad.f.tasks -FlagsPath $fxBad.f.flags -TelemetryRoot $fxBad.f.tele -ReceiptDir $fxBad.f.receipt -EvidenceStoreDir $fxBad.f.evidence -CheckpointDir $fxBad.f.ckpt -TaskId 'pa-task-h3-badtask-wrong' -AttemptRole 'coder' -SessionId $fxBad.sess -OwnerId 'owner-h3' -Generation $fxBad.gen -ExpectedRevision $liveRevBad -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:H3Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fxBad.wid -NativeSettlementContext $fxBad.ctx -ContinuationAuthorization $fxBad.authND -Productive
Assert-H3That ((($null -ne $wBad) -and (-not [bool]$wBad.ok)) -and (-not [bool]$wBad.settled)) 'H3 negativo task errada: HOLD, sem settle'
Assert-H3That ((($null -eq $wBad.continuation) -and (-not [bool]$wBad.continuation_attempted)) -and ((Get-H3TaskRev $fxBad.tid $fxBad.f.tasks) -eq $revBad0)) 'H3 negativo task errada: nada preparado, nada escrito'
# --- Negativo: lease expirada (generation futura) HOLD.
$fxExp = New-H3NativeFixture -Tag 'explease'
$revExp0 = Get-H3TaskRev $fxExp.tid $fxExp.f.tasks
$liveRevExp = [long](Get-OrchestrationGoal -GoalId $fxExp.gid -StoreDir $fxExp.f.goal).goal['revision']
$wExp = Invoke-ProductiveSettleAndContinue -GoalId $fxExp.gid -GoalStoreDir $fxExp.f.goal -DispatchStoreDir $fxExp.f.dispatch -TasksDir $fxExp.f.tasks -FlagsPath $fxExp.f.flags -TelemetryRoot $fxExp.f.tele -ReceiptDir $fxExp.f.receipt -EvidenceStoreDir $fxExp.f.evidence -CheckpointDir $fxExp.f.ckpt -TaskId $fxExp.tid -AttemptRole 'coder' -SessionId $fxExp.sess -OwnerId 'owner-h3' -Generation ([long]$fxExp.gen + 1) -ExpectedRevision $liveRevExp -User 'u' -Project 'p' -Runtime 'V1' -Grants $script:H3Full -WorkerStatus 'candidate_pass' -WorkerProducedBy 'coder' -WorkerEvidence @('criterion:0') -WorkItemId $fxExp.wid -NativeSettlementContext $fxExp.ctx -ContinuationAuthorization $fxExp.authND -Productive
Assert-H3That ((($null -ne $wExp) -and (-not [bool]$wExp.ok)) -and ($null -eq $wExp.continuation)) 'H3 negativo lease expirada: HOLD sem continuacao'
Assert-H3That (((-not [bool]$wExp.settled) -and (-not [bool]$wExp.continuation_attempted)) -and ((Get-H3TaskRev $fxExp.tid $fxExp.f.tasks) -eq $revExp0)) 'H3 negativo lease expirada: fencing nao provado, zero escrita'
try { Remove-Item -LiteralPath $fx.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fxBad.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $fxExp.f.root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
'HARNESS_PASS: {0} checks (harness verdict only; RUNTIME_REAL_PASS NOT claimed - gap: child session observada no host + proof por canal confiavel)' -f $passed
