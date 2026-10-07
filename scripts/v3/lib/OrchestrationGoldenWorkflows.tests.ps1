<#!
.SYNOPSIS
    V3 Golden Workflows: 15 end-to-end workflow asserts over the real libs (SPEC v0.1.0 Phase 13, PR-K).
.DESCRIPTION
    Dot-sourceable test suite (no execution on load beyond the asserts
    below). Uses the REAL libraries (no lib mocks; only a synthetic
    Jev Probe scriptblock where the DecisionProvider seam requires one,
    plus TEMP stores). PS 5.1 compatible, ASCII-only. Fails closed via
    throw on the first violated assert; prints one PASS line with the
    assert count. Each GW carries at least one assert.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationPreflight.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationEvidenceStore.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationDecisionProvider.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationObjectiveController.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalPromotion.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalProgress.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationAutonomy.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationDelivery.ps1')
$passed = 0
function Assert-GWThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function New-GWTempDir {
    param([string]$Prefix)
    $t = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($t)
    return $t
}
function New-GWEvidenceBase {
    param([string]$StoreDir, [string]$RunId, [string]$ExpiresAt, [string]$CreatedAt)
    $raw = Join-Path $StoreDir ('raw-' + $RunId + '.log')
    [IO.File]::WriteAllText($raw, ('gw-' + $RunId))
    return [ordered]@{
        task_id = 'gw-task'; run_id = $RunId; worker_id = 'coder_1'
        provenance = @{ created_by = 'coder'; kernel_task_ref = 'gw-task' }
        base_revision = 'rev-a'; criteria_hash = 'crit-a'
        source_fingerprints = @{'src/a.ps1' = 'sha-a'}; diff_hash = 'diff-a'
        scope = @('src/a.ps1'); command = 'test'
        environment = @{ runtime = 'pwsh'; version = '7' }
        result = @{ summary = 'passed'; raw_ref = $raw }
        assumptions = @()
        invalidation_conditions = @(
            @{ type = 'source-changed'; paths = @('src/a.ps1') },
            @{ type = 'criteria-changed'; hash = 'crit-a' },
            @{ type = 'base-revision'; require_same = $true },
            @{ type = 'env-changed'; runtime = 'pwsh'; version = '7' },
            @{ type = 'ttl'; expires_at = $ExpiresAt }
        )
        created_at = $CreatedAt
    }
}
function Get-GWAllChecksOk {
    param($Policy)
    $out = @()
    foreach ($n in @(Get-OrchestrationDeliveryRequiredChecks $Policy)) {
        $out += @([pscustomobject]@{ name = [string]$n; conclusion = 'success' })
    }
    return $out
}
# --- GW-01: cosmetic typo => SINGLE_WORKER with coder.
$gw01 = Get-OrchestrationPreflight -Objective 'Fix typo in readme footer' -TaskType 'cosmetic' -Domain '' -Risk 'low' -ReadWrite 'read'
Assert-GWThat (([string]$gw01.orchestration_decision -ceq 'SINGLE_WORKER') -and ([string]$gw01.task_class -ceq 'trivial')) 'GW-01 cosmetic typo is single-worker trivial'
Assert-GWThat ((@($gw01.selected_agents) -contains 'coder')) 'GW-01 single worker is coder'
# --- GW-02: bug fix (medium/write) => MULTI_WORKER.
$gw02 = Get-OrchestrationPreflight -Objective 'Fix cart total calculation bug in checkout rendering flow with rounding edge cases covered by unit tests and review' -TaskType 'implementation' -Domain 'backend' -Risk 'medium' -ReadWrite 'write'
Assert-GWThat (([string]$gw02.orchestration_decision -ceq 'MULTI_WORKER') -and ([string]$gw02.task_class -ceq 'non_trivial')) 'GW-02 bug fix is multi-worker non-trivial'
Assert-GWThat ((@($gw02.selected_agents) -contains 'coder')) 'GW-02 multi worker routes coder'
# --- GW-03/GW-04 share one TEMP evidence store.
$gwEvDir = New-GWTempDir 'gw-ev-'
$gwNow = [DateTimeOffset]::UtcNow
$gwCreated = $gwNow.AddMinutes(-1).ToString('o')
$gwExpires = $gwNow.AddMinutes(30).ToString('o')
$gwRec = New-OrchestrationEvidenceRecord (New-GWEvidenceBase $gwEvDir 'gw-run-1' $gwExpires $gwCreated) $gwEvDir
Assert-GWThat ([bool]$gwRec.created) ('GW-03 evidence recorded (' + [string]$gwRec.reason + ')')
$gwHit = Find-ReusableOrchestrationEvidence -StoreDir $gwEvDir -Scope @('src/a.ps1') -CurrentSourceFingerprints @{'src/a.ps1' = 'sha-a'} -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv @{runtime = 'pwsh'; version = '7'} -Now $gwNow.ToString('o') -MaxResults 5
Assert-GWThat ((@($gwHit).Count -eq 1)) 'GW-03 identical query is a hit'
$gwMiss = Find-ReusableOrchestrationEvidence -StoreDir $gwEvDir -Scope @('src/a.ps1') -CurrentSourceFingerprints @{'src/a.ps1' = 'sha-b'} -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv @{runtime = 'pwsh'; version = '7'} -Now $gwNow.ToString('o') -MaxResults 5
Assert-GWThat ((@($gwMiss).Count -eq 0)) 'GW-04 drifted fingerprint misses'
$gwMetrics = Get-OrchestrationEvidenceMetrics -StoreDir $gwEvDir
Assert-GWThat ([bool]$gwMetrics.misses_by_reason.Contains('source-changed:src/a.ps1')) 'GW-04 miss reason is source-changed'
# --- GW-05: routing via healthy synthetic Probe => jev source.
$gwProbeOk = { param($ctx) return @{ decision = 'coder'; confidence = 0.9 } }
$gw05 = Invoke-OrchestrationDecision -QuestionId 'gw05-routing' -QuestionType 'routing' -Alternatives @('coder', 'tester') -State @{ task = 'route-build' } -Risk 'low' -AllowJev $true -JevProbe $gwProbeOk
Assert-GWThat (([string]$gw05.source -ceq 'jev') -and ([string]$gw05.decision -ceq 'coder')) 'GW-05 clean probe advice is jev-sourced'
Assert-GWThat ((-not [bool]$gw05.blocked) -and (-not [bool]$gw05.fallback_used)) 'GW-05 jev advice never blocks and uses no fallback'
# --- GW-06: throwing Probe => honest escalation, still never blocked.
$gwProbeThrow = { param($ctx) throw 'gw06-probe-timeout' }
$gw06 = Invoke-OrchestrationDecision -QuestionId 'gw06-routing' -QuestionType 'routing' -Alternatives @('coder', 'tester') -State @{ task = 'route-build' } -Risk 'low' -AllowJev $true -JevProbe $gwProbeThrow
Assert-GWThat (([string]$gw06.source -ceq 'planner-escalation') -and ([string]$gw06.reason -ceq 'jev-failed-escalation')) 'GW-06 throwing probe escalates honestly'
Assert-GWThat ((-not [bool]$gw06.blocked)) 'GW-06 escalation never blocks'
# --- GW-07: SPEC+PLAN promotes to persistent-goal; goal runs the DRAFT->ACTIVE cycle to COMPLETED.
# Mapeamento: GW-07 => SPEC Sec24 itens 9/20 (SPEC+PLAN executado ate a conclusao: promotion -> DRAFT -> ACTIVE -> tasks+progress -> COMPLETED).
$gw07promo = Test-OrchestrationGoalPromotion -Signals @{ has_spec_plan = $true }
Assert-GWThat (([bool]$gw07promo.promote) -and ([string]$gw07promo.shape -ceq 'persistent-goal')) 'GW-07 spec plus plan promotes'
$gwGoalDir = New-GWTempDir 'gw-goals-'
$gw07new = New-OrchestrationGoal -GoalId 'GW07goal1' -Objective 'Ship the checkout fix end to end' -Criteria @('c1') -StoreDir $gwGoalDir
Assert-GWThat ([bool]$gw07new.ok) 'GW-07 goal drafted'
$gw07sv = Save-OrchestrationGoal -Goal $gw07new.goal -StoreDir $gwGoalDir
Assert-GWThat ([bool]$gw07sv.ok) 'GW-07 goal saved'
$gw07act = Set-OrchestrationGoalState -Goal $gw07new.goal -ToState 'ACTIVE'
Assert-GWThat ([bool]$gw07act.ok) 'GW-07 goal activated'
$gw07sv2 = Save-OrchestrationGoal -Goal $gw07act.goal -StoreDir $gwGoalDir
$gw07got = Get-OrchestrationGoal -GoalId 'GW07goal1' -StoreDir $gwGoalDir
Assert-GWThat (([bool]$gw07sv2.ok) -and ([bool]$gw07got.ok) -and ([string]$gw07got.goal['state'] -ceq 'ACTIVE')) 'GW-07 goal cycle ends ACTIVE'
$gw07t1 = Add-OrchestrationGoalTask -Goal $gw07act.goal -TaskId 'GW07task1'
$gw07t2 = Add-OrchestrationGoalTask -Goal $gw07t1.goal -TaskId 'GW07task2'
Assert-GWThat (([bool]$gw07t1.ok) -and ([bool]$gw07t2.ok)) 'GW-07 wave tasks registered'
$gw07svT = Save-OrchestrationGoal -Goal $gw07t2.goal -StoreDir $gwGoalDir
Assert-GWThat ([bool]$gw07svT.ok) 'GW-07 tasks saved'
$gw07upd = Update-OrchestrationGoal -GoalId 'GW07goal1' -ExpectedRevision ([long]$gw07svT.revision) -Fields @{ progress = @{ satisfied = 1; total = 2 } } -StoreDir $gwGoalDir
Assert-GWThat (([bool]$gw07upd.ok) -and ([long]$gw07upd.goal['progress']['satisfied'] -eq 1)) 'GW-07 partial progress recorded'
$gw07c1 = Complete-OrchestrationGoalTask -Goal $gw07upd.goal -TaskId 'GW07task1'
$gw07c2 = Complete-OrchestrationGoalTask -Goal $gw07c1.goal -TaskId 'GW07task2'
Assert-GWThat (([bool]$gw07c1.ok) -and ([bool]$gw07c2.ok)) 'GW-07 wave tasks completed'
$gw07svC = Save-OrchestrationGoal -Goal $gw07c2.goal -StoreDir $gwGoalDir
Assert-GWThat (([bool]$gw07svC.ok) -and (@($gw07c2.goal['completed_tasks']).Count -eq 2)) 'GW-07 completions saved'
$gw07upd2 = Update-OrchestrationGoal -GoalId 'GW07goal1' -ExpectedRevision ([long]$gw07svC.revision) -Fields @{ progress = @{ satisfied = 2; total = 2 } } -StoreDir $gwGoalDir
Assert-GWThat ([bool]$gw07upd2.ok) 'GW-07 full progress recorded'
$gw07done = Set-OrchestrationGoalState -Goal $gw07upd2.goal -ToState 'COMPLETED'
Assert-GWThat ([bool]$gw07done.ok) 'GW-07 goal completed'
$gw07sv3 = Save-OrchestrationGoal -Goal $gw07done.goal -StoreDir $gwGoalDir
$gw07final = Get-OrchestrationGoal -GoalId 'GW07goal1' -StoreDir $gwGoalDir
Assert-GWThat (([bool]$gw07sv3.ok) -and ([bool]$gw07final.ok) -and ([string]$gw07final.goal['state'] -ceq 'COMPLETED')) 'GW-07 SPEC+PLAN runs to COMPLETED'
Assert-GWThat ((@($gw07final.goal['completed_tasks']).Count -eq 2) -and ([long]$gw07final.goal['progress']['satisfied'] -eq 2)) 'GW-07 completion carries tasks and progress'
# --- GW-08: remaining authorized work with a path => CONTINUE.
# Mapeamento: GW-08 => SPEC Sec24 (wave completion continua: completar 1 de 2 tasks mantem CONTINUE com remaining 1 via GoalKernel + controller).
$gw08 = Get-OrchestrationNextMove -Status @{ objective_completed = $false; remaining_work = @('work-1'); authorized = $true; blocker_kind = ''; progress_possible = $true; strategy_change = $false; context_degraded = $false; last_failure = $null; terminal_blocker = $null; consecutive_no_progress = [long]0 }
Assert-GWThat (([string]$gw08.move -ceq 'CONTINUE')) 'GW-08 remaining work continues'
Assert-GWThat (([long]$gw08.remaining_count -eq 1)) 'GW-08 remaining count is 1'
$gw08new = New-OrchestrationGoal -GoalId 'GW08wave1' -Objective 'Wave with two tasks' -StoreDir $gwGoalDir
Assert-GWThat ([bool]$gw08new.ok) 'GW-08 wave goal drafted'
$gw08a = Set-OrchestrationGoalState -Goal $gw08new.goal -ToState 'ACTIVE'
$gw08t1 = Add-OrchestrationGoalTask -Goal $gw08a.goal -TaskId 'GW08t1'
$gw08t2 = Add-OrchestrationGoalTask -Goal $gw08t1.goal -TaskId 'GW08t2'
Assert-GWThat (([bool]$gw08a.ok) -and ([bool]$gw08t1.ok) -and ([bool]$gw08t2.ok)) 'GW-08 two wave tasks registered'
$gw08svT = Save-OrchestrationGoal -Goal $gw08t2.goal -StoreDir $gwGoalDir
Assert-GWThat ([bool]$gw08svT.ok) 'GW-08 wave tasks saved'
$gw08got = Get-OrchestrationGoal -GoalId 'GW08wave1' -StoreDir $gwGoalDir
$gw08c1 = Complete-OrchestrationGoalTask -Goal $gw08got.goal -TaskId 'GW08t1'
Assert-GWThat ([bool]$gw08c1.ok) 'GW-08 first wave task completed'
$gw08svC = Save-OrchestrationGoal -Goal $gw08c1.goal -StoreDir $gwGoalDir
Assert-GWThat (([bool]$gw08svC.ok) -and (@($gw08c1.goal['active_tasks']).Count -eq 1)) 'GW-08 one wave task remains'
$gw08wave = Get-OrchestrationGoal -GoalId 'GW08wave1' -StoreDir $gwGoalDir
$gw08move = Get-OrchestrationGoalNextMove -Goal $gw08wave.goal
Assert-GWThat (([bool]$gw08move.ok) -and ([string]$gw08move.next_move.move -ceq 'CONTINUE')) 'GW-08 wave completion continues'
Assert-GWThat (([long]$gw08move.next_move.remaining_count -eq 1)) 'GW-08 wave remaining count is 1'
# --- GW-09: repair path with re-review still reaches MERGED.
$gw09 = Get-OrchestrationDeliveryState -Events @('implemented', 'tests_passed', 'review_changes_requested', 'finding_repair', 'implemented', 'tests_passed', 'review_approved', 'pr_opened', 'ci_passed', 'merged')
Assert-GWThat (([string]$gw09.state -ceq 'MERGED')) 'GW-09 repair path merges'
Assert-GWThat ([bool]$gw09.terminal) 'GW-09 merged is terminal'
# --- GW-10: three consecutive stalls require a strategy change.
# Mapeamento: GW-10 => SPEC Sec24 (failure->replan->recovery em nivel lib: 3 stalls exigem troca, a estrategia falha e registrada, a nova estrategia com progresso e meaningful).
# NOTA: Debugger/Architect sao AGENTES (orquestracao), nao libs; este golden exercita apenas as libs (progress delta + goal record).
$gwPrev = @{ satisfied = 1; total = 3; failed_tests = 0; open_p1 = 0; blockers = 0 }
$gwCurr = @{ satisfied = 1; total = 3; failed_tests = 0; open_p1 = 0; blockers = 0 }
$gwD1 = Get-OrchestrationGoalProgressDelta -Previous $gwPrev -Current $gwCurr -StagnationCount 0
Assert-GWThat (([long]$gwD1.stagnation_count -eq 1) -and (-not [bool]$gwD1.strategy_change_required)) 'GW-10 first stall bumps without strategy change'
$gwD2 = Get-OrchestrationGoalProgressDelta -Previous $gwPrev -Current $gwCurr -StagnationCount $gwD1.stagnation_count
$gwD3 = Get-OrchestrationGoalProgressDelta -Previous $gwPrev -Current $gwCurr -StagnationCount $gwD2.stagnation_count
Assert-GWThat (([long]$gwD3.stagnation_count -eq 3) -and [bool]$gwD3.strategy_change_required) 'GW-10 third stall requires strategy change'
$gw10new = New-OrchestrationGoal -GoalId 'GW10goal1' -Objective 'Stalled goal replanned' -Criteria @('c1', 'c2', 'c3') -StoreDir $gwGoalDir
Assert-GWThat ([bool]$gw10new.ok) 'GW-10 stalled goal drafted'
$gw10sv = Save-OrchestrationGoal -Goal $gw10new.goal -StoreDir $gwGoalDir
Assert-GWThat ([bool]$gw10sv.ok) 'GW-10 stalled goal saved'
$gw10fail = Update-OrchestrationGoal -GoalId 'GW10goal1' -ExpectedRevision ([long]$gw10sv.revision) -Fields @{ failed_strategies = @('gw10-old-strategy') } -StoreDir $gwGoalDir
Assert-GWThat (([bool]$gw10fail.ok) -and (@($gw10fail.goal['failed_strategies']) -contains 'gw10-old-strategy')) 'GW-10 failed strategy recorded'
$gwRecovered = @{ satisfied = 2; total = 3; failed_tests = 0; open_p1 = 0; blockers = 0 }
$gwD4 = Get-OrchestrationGoalProgressDelta -Previous $gwCurr -Current $gwRecovered -StagnationCount $gwD3.stagnation_count
Assert-GWThat (([bool]$gwD4.ok) -and [bool]$gwD4.meaningful) 'GW-10 new strategy with progress is meaningful'
Assert-GWThat (([long]$gwD4.stagnation_count -eq 0) -and (-not [bool]$gwD4.strategy_change_required)) 'GW-10 recovery clears the stall'
# --- GW-11: checkpoint save/load/resume roundtrip is resumable.
# Mapeamento: GW-11 => SPEC Sec24 (checkpoint/resume preserva campos: goal com progresso+tasks+decisions sobrevive ao roundtrip sem mutacao).
$gw11new = New-OrchestrationGoal -GoalId 'GW11goal1' -Objective 'Resumable goal' -Criteria @('c1') -StoreDir $gwGoalDir
$gw11sv = Save-OrchestrationGoal -Goal $gw11new.goal -StoreDir $gwGoalDir
Assert-GWThat (([bool]$gw11new.ok) -and ([bool]$gw11sv.ok)) 'GW-11 goal persisted for resume'
$gw11t = Add-OrchestrationGoalTask -Goal $gw11new.goal -TaskId 'GW11task1'
$gw11svT = Save-OrchestrationGoal -Goal $gw11t.goal -StoreDir $gwGoalDir
Assert-GWThat (([bool]$gw11t.ok) -and ([bool]$gw11svT.ok)) 'GW-11 task persisted for resume'
$gw11upd = Update-OrchestrationGoal -GoalId 'GW11goal1' -ExpectedRevision ([long]$gw11svT.revision) -Fields @{ progress = @{ satisfied = 1; total = 1 }; decision_refs = @('gw11-dec1') } -StoreDir $gwGoalDir
Assert-GWThat (([bool]$gw11upd.ok) -and ([long]$gw11upd.goal['progress']['satisfied'] -eq 1)) 'GW-11 progress and decisions persisted for resume'
$gw11pre = Get-OrchestrationGoal -GoalId 'GW11goal1' -StoreDir $gwGoalDir
Assert-GWThat ([bool]$gw11pre.ok) 'GW-11 pre-checkpoint goal readable'
$gwCkDir = New-GWTempDir 'gw-checkpoints-'
$gwCk = New-OrchestrationGoalCheckpoint -GoalRecord $gw11pre.goal
Assert-GWThat (($null -ne $gwCk)) 'GW-11 checkpoint snapshotted'
Assert-GWThat (([string]$gwCk['goal_id'] -ceq 'GW11goal1') -and ([long]$gwCk['goal_revision'] -eq [long]$gw11pre.goal['revision'])) 'GW-11 checkpoint carries goal identity'
Assert-GWThat (([long]$gwCk['progress']['satisfied'] -eq 1) -and (@($gwCk['decision_refs']) -contains 'gw11-dec1')) 'GW-11 checkpoint carries progress and decisions'
$gwCkSv = Save-OrchestrationGoalCheckpoint -Checkpoint $gwCk -StoreDir $gwCkDir
Assert-GWThat ([bool]$gwCkSv.ok) 'GW-11 checkpoint saved'
$gwCkLd = Load-OrchestrationGoalCheckpoint -CheckpointId ([string]$gwCk['checkpoint_id']) -StoreDir $gwCkDir
Assert-GWThat ([bool]$gwCkLd.ok) 'GW-11 checkpoint loaded'
$gwResume = Test-OrchestrationCheckpointResume -Checkpoint $gwCkLd.checkpoint -GoalStoreDir $gwGoalDir
Assert-GWThat (([bool]$gwResume.resumable) -and [bool]$gwResume.resume_plan.hydrate_goal) 'GW-11 checkpoint is resumable'
$gw11post = Get-OrchestrationGoal -GoalId 'GW11goal1' -StoreDir $gwGoalDir
Assert-GWThat ([bool]$gw11post.ok) 'GW-11 post-resume goal readable'
Assert-GWThat (([string]$gw11post.goal['goal_id'] -ceq [string]$gw11pre.goal['goal_id']) -and ([long]$gw11post.goal['revision'] -eq [long]$gw11pre.goal['revision'])) 'GW-11 resume preserves goal identity'
Assert-GWThat (([long]$gw11post.goal['progress']['satisfied'] -eq [long]$gw11pre.goal['progress']['satisfied']) -and ([long]$gw11post.goal['progress']['total'] -eq [long]$gw11pre.goal['progress']['total'])) 'GW-11 resume preserves progress'
Assert-GWThat ((@($gw11post.goal['active_tasks']) -contains 'GW11task1') -and (@($gw11post.goal['decision_refs']) -contains 'gw11-dec1')) 'GW-11 resume preserves tasks and decisions'
# --- GW-12: external-communication boundary and human-authority stop are both known.
Assert-GWThat ([bool](Test-OrchestrationAuthorityBoundary -Boundary 'EXTERNAL_COMMUNICATION_AS_USER')) 'GW-12 external communication boundary is valid'
Assert-GWThat ([bool](Test-OrchestrationStopReason -Reason 'HUMAN_AUTHORITY_REQUIRED')) 'GW-12 human authority stop is valid'
$gw12 = Get-OrchestrationNextMove -Status @{ objective_completed = $false; remaining_work = @('t1'); authorized = $false; blocker_kind = 'other'; progress_possible = $true; strategy_change = $false; context_degraded = $false; last_failure = $null; terminal_blocker = $null; consecutive_no_progress = [long]0 }
Assert-GWThat (([string]$gw12.move -ceq 'COMPLETE') -and ([string]$gw12.stop_reason -ceq 'HUMAN_AUTHORITY_REQUIRED')) 'GW-12 unauthorized work stops for a human'
# --- GW-13: model override attempt is reserved, never decided.
$gw13 = Invoke-OrchestrationDecision -QuestionId 'gw13-q' -QuestionType 'routing' -Alternatives @('use-Muse', 'coder') -State @{ task = 'route-build' } -Risk 'low' -AllowJev $true -JevProbe $gwProbeOk
Assert-GWThat (([string]$gw13.source -ceq 'refused') -and ([string]$gw13.reason -ceq 'model-selection-reserved')) 'GW-13 model override is reserved'
Assert-GWThat ((-not [bool]$gw13.blocked)) 'GW-13 refusal never blocks'
# --- GW-14: happy delivery path is eligible and merges.
$gwPolicyPath = Join-Path $PSScriptRoot '..\..\..\source\registry\delivery-policy.json'
$gwPolicy = ConvertFrom-Json ([IO.File]::ReadAllText([IO.Path]::GetFullPath($gwPolicyPath)))
$gw14elig = Test-OrchestrationMergeEligibility -Policy $gwPolicy -Checks (Get-GWAllChecksOk $gwPolicy) -ReviewerApproved $true -SecurityRequired $false -SecurityApproved $false -UnresolvedP1 0 -Risk 'low'
Assert-GWThat ([bool]$gw14elig.eligible) 'GW-14 green delivery is eligible'
$gw14state = Get-OrchestrationDeliveryState -Events @('implemented', 'tests_passed', 'review_approved', 'pr_opened', 'ci_passed', 'merged')
Assert-GWThat (([string]$gw14state.state -ceq 'MERGED') -and [bool]$gw14state.terminal) 'GW-14 happy path merges'
# --- GW-15: budget exhaustion ends EXHAUSTED (never COMPLETED) and the controller completes on the hard-budget stop.
$gw15new = New-OrchestrationGoal -GoalId 'GW15goal1' -Objective 'Bounded goal' -Criteria @('c1', 'c2') -StoreDir $gwGoalDir
Assert-GWThat ([bool]$gw15new.ok) 'GW-15 goal drafted'
$gw15a = Set-OrchestrationGoalState -Goal $gw15new.goal -ToState 'ACTIVE'
$gw15sv1 = Save-OrchestrationGoal -Goal $gw15a.goal -StoreDir $gwGoalDir
$gw15b = Set-OrchestrationGoalState -Goal $gw15a.goal -ToState 'BUDGET_LIMITED'
Assert-GWThat ((([bool]$gw15a.ok) -and ([bool]$gw15sv1.ok)) -and (([bool]$gw15b.ok) -and ([string]$gw15b.goal['state'] -ceq 'BUDGET_LIMITED'))) 'GW-15 goal hits the soft budget limit'
$gw15sv2 = Save-OrchestrationGoal -Goal $gw15b.goal -StoreDir $gwGoalDir
$gw15c = Set-OrchestrationGoalState -Goal $gw15b.goal -ToState 'EXHAUSTED'
$gw15sv3 = Save-OrchestrationGoal -Goal $gw15c.goal -StoreDir $gwGoalDir
$gw15got = Get-OrchestrationGoal -GoalId 'GW15goal1' -StoreDir $gwGoalDir
Assert-GWThat ((([bool]$gw15sv2.ok) -and ([bool]$gw15sv3.ok)) -and (([bool]$gw15got.ok) -and ([string]$gw15got.goal['state'] -ceq 'EXHAUSTED') -and ([string]$gw15got.goal['state'] -cne 'COMPLETED'))) 'GW-15 goal is exhausted, not completed'
$gw15move = Get-OrchestrationGoalNextMove -Goal $gw15got.goal
Assert-GWThat (([bool]$gw15move.ok) -and ([string]$gw15move.next_move.move -ceq 'COMPLETE') -and ([string]$gw15move.next_move.stop_reason -ceq 'GOAL_HARD_BUDGET_EXHAUSTED')) 'GW-15 controller completes on hard budget exhaustion'
Remove-Item -LiteralPath $gwEvDir -Recurse -Force
Remove-Item -LiteralPath $gwGoalDir -Recurse -Force
Remove-Item -LiteralPath $gwCkDir -Recurse -Force
Write-Output ("OrchestrationGoldenWorkflows: PASS ($passed assertions, 15/15 workflows)")
