[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGoalCheckpoint.ps1')
$passed = 0
function Assert-GCThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function New-GCTestGoal {
    param([string]$GoalId = 'UT.goal:1', [long]$Revision = 3)
    return [ordered]@{
        schema_version         = 1
        goal_id                = $GoalId
        objective              = 'Ship the feature'
        criteria               = @('a', 'b')
        verification_surfaces  = @('tests')
        state                  = 'ACTIVE'
        revision               = [long]$Revision
        budget                 = [ordered]@{ soft_cap = [long]0; hard_cap = [long]0; spent = [long]0 }
        progress               = [ordered]@{ satisfied = [long]1; total = [long]2; updated_at = '2026-10-07T00:00:00.0000000Z' }
        plan_progress          = [ordered]@{ phase = [long]1; total_phases = [long]2; done_tasks = [long]1 }
        evidence_refs          = @('ev.1')
        decision_refs          = @('dec.1')
        failed_strategies      = @('s1')
        active_tasks           = @()
        completed_tasks        = @()
        blockers               = @('b1')
        risks                  = @('r1')
        next_move              = [ordered]@{ move = 'delegate' }
        checkpoint_revision    = [long]0
        created_at             = '2026-10-07T00:00:00.0000000Z'
        updated_at             = '2026-10-07T00:00:00.0000000Z'
    }
}
function New-GCTempDir {
    $t = Join-Path ([IO.Path]::GetTempPath()) ('gcp-' + [IO.Path]::GetRandomFileName())
    [void][IO.Directory]::CreateDirectory($t)
    return $t
}
# --- Constructor snapshots every contract field.
$c = New-OrchestrationGoalCheckpoint -GoalRecord (New-GCTestGoal)
Assert-GCThat (($null -ne $c) -and ([string]$c['goal_id'] -ceq 'UT.goal:1') -and ([long]$c['goal_revision'] -eq 3)) 'constructor keeps goal identity and revision'
Assert-GCThat (([string]$c['objective'] -ceq 'Ship the feature') -and ([long]$c['progress']['satisfied'] -eq 1) -and ([long]$c['plan_progress']['phase'] -eq 1)) 'constructor snapshots objective progress and plan'
Assert-GCThat ((@($c['decision_refs']).Count -eq 1) -and (@($c['evidence_refs']).Count -eq 1) -and (@($c['failed_strategies']).Count -eq 1)) 'constructor snapshots refs and failed strategies'
Assert-GCThat ((@($c['blockers']).Count -eq 1) -and (@($c['risks']).Count -eq 1) -and (@($c['waits']).Count -eq 0) -and ([string]$c['next_move']['move'] -ceq 'delegate')) 'constructor snapshots blockers risks waits next-move'
Assert-GCThat (([string]$c['checkpoint_id'] -cmatch '^[a-f0-9]{16}$') -and (-not [string]::IsNullOrWhiteSpace([string]$c['created_at']))) 'checkpoint id is 16-hex and stamped'
Assert-GCThat ((-not [bool]$c['resume_preconditions']['goal_exists']) -and (-not [bool]$c['resume_preconditions']['store_readable'])) 'preconditions start unresolved'
# --- checkpoint_id is deterministic for the same goal content.
$c2 = New-OrchestrationGoalCheckpoint -GoalRecord (New-GCTestGoal)
Assert-GCThat ([string]$c2['checkpoint_id'] -ceq [string]$c['checkpoint_id']) 'same goal content yields same checkpoint id'
$c3 = New-OrchestrationGoalCheckpoint -GoalRecord (New-GCTestGoal -Revision 4)
Assert-GCThat ([string]$c3['checkpoint_id'] -cne [string]$c['checkpoint_id']) 'different revision yields different checkpoint id'
# --- Explicit checkpoint id: valid accepted, invalid rejected.
$c4 = New-OrchestrationGoalCheckpoint -GoalRecord (New-GCTestGoal) -CheckpointId 'abcdef0123456789'
Assert-GCThat (($null -ne $c4) -and ([string]$c4['checkpoint_id'] -ceq 'abcdef0123456789')) 'explicit valid checkpoint id accepted'
Assert-GCThat ($null -eq (New-OrchestrationGoalCheckpoint -GoalRecord (New-GCTestGoal) -CheckpointId 'ZZZ')) 'explicit invalid checkpoint id rejected'
# --- Strict constructor: invalid goal fails closed without throw.
Assert-GCThat ($null -eq (New-OrchestrationGoalCheckpoint -GoalRecord $null)) 'null goal fails closed'
Assert-GCThat ($null -eq (New-OrchestrationGoalCheckpoint -GoalRecord (New-GCTestGoal -GoalId ''))) 'empty goal id fails closed'
Assert-GCThat ($null -eq (New-OrchestrationGoalCheckpoint -GoalRecord (New-GCTestGoal -GoalId 'bad id!'))) 'malformed goal id fails closed'
Assert-GCThat ($null -eq (New-OrchestrationGoalCheckpoint -GoalRecord (New-GCTestGoal -Revision 0))) 'zero revision fails closed'
$gBad = New-GCTestGoal; $gBad['objective'] = '   '
Assert-GCThat ($null -eq (New-OrchestrationGoalCheckpoint -GoalRecord $gBad)) 'blank objective fails closed'
$gBad2 = New-GCTestGoal; $gBad2['blockers'] = @(42)
Assert-GCThat ($null -eq (New-OrchestrationGoalCheckpoint -GoalRecord $gBad2)) 'non-string list item fails closed'
# --- Roundtrip: save/load preserves every field.
$store = New-GCTempDir
try {
    $s = Save-OrchestrationGoalCheckpoint -Checkpoint $c -StoreDir $store
    Assert-GCThat ([bool]$s.ok -and ([string]$s.checkpoint_id -ceq [string]$c['checkpoint_id']) -and (-not [string]::IsNullOrWhiteSpace([string]$s.path))) 'save succeeds with id and path'
    $l = Load-OrchestrationGoalCheckpoint -CheckpointId ([string]$c['checkpoint_id']) -StoreDir $store
    Assert-GCThat ([bool]$l.ok -and ($null -ne $l.checkpoint)) 'load succeeds'
    $lc = $l.checkpoint
    Assert-GCThat (([string]$lc['goal_id'] -ceq 'UT.goal:1') -and ([long]$lc['goal_revision'] -eq 3) -and ([string]$lc['objective'] -ceq 'Ship the feature')) 'roundtrip preserves identity and objective'
    Assert-GCThat (([long]$lc['progress']['satisfied'] -eq 1) -and ([long]$lc['progress']['total'] -eq 2) -and ([long]$lc['plan_progress']['done_tasks'] -eq 1)) 'roundtrip preserves progress and plan'
    Assert-GCThat ((@($lc['decision_refs']) -join ',' -ceq 'dec.1') -and (@($lc['evidence_refs']) -join ',' -ceq 'ev.1') -and (@($lc['blockers']) -join ',' -ceq 'b1') -and (@($lc['risks']) -join ',' -ceq 'r1')) 'roundtrip preserves refs blockers risks'
    Assert-GCThat (([string]$lc['next_move']['move'] -ceq 'delegate') -and ([string]$lc['checkpoint_id'] -ceq [string]$c['checkpoint_id']) -and ([string]$lc['created_at'] -ceq [string]$c['created_at'])) 'roundtrip preserves next-move id and stamp'
    $miss = Load-OrchestrationGoalCheckpoint -CheckpointId '0000000000000000' -StoreDir $store
    Assert-GCThat ((-not [bool]$miss.ok) -and ([string]$miss.reason -ceq 'checkpoint-not-found')) 'missing checkpoint loads fail-closed'
    $badId = Load-OrchestrationGoalCheckpoint -CheckpointId 'nope' -StoreDir $store
    Assert-GCThat ((-not [bool]$badId.ok) -and ([string]$badId.reason -ceq 'invalid-checkpoint-id')) 'malformed id loads fail-closed'
    $badSave = Save-OrchestrationGoalCheckpoint -Checkpoint 'junk' -StoreDir $store
    Assert-GCThat ((-not [bool]$badSave.ok) -and ([string]$badSave.reason -ceq 'invalid-checkpoint')) 'invalid record saves fail-closed'
}
finally { try { Remove-Item -LiteralPath $store -Recurse -Force -ErrorAction Stop } catch { } }
# --- Resume: goal present => resumable with a full resume plan.
$goalDir = New-GCTempDir
try {
    [IO.File]::WriteAllText((Join-Path $goalDir 'ut.goal=1.json'), '{"goal_id":"UT.goal:1","revision":3}', [Text.UTF8Encoding]::new($false))
    $r = Test-OrchestrationCheckpointResume -Checkpoint $c -GoalStoreDir $goalDir
    Assert-GCThat ([bool]$r.resumable -and (@($r.reasons).Count -eq 0)) 'goal present resumes'
    Assert-GCThat ([bool]$r.resume_plan['hydrate_goal'] -and [bool]$r.resume_plan['revalidate_decisions'] -and [bool]$r.resume_plan['recompute_next_move']) 'resume plan hydrates revalidates and recomputes'
    [IO.File]::WriteAllText((Join-Path $goalDir 'ut.goal=1.json'), '{"goal_id":"UT.goal:1","revision":5}', [Text.UTF8Encoding]::new($false))
    $rStale = Test-OrchestrationCheckpointResume -Checkpoint $c -GoalStoreDir $goalDir
    Assert-GCThat ((-not [bool]$rStale.resumable) -and (@($rStale.reasons) -contains 'stale-goal-revision')) 'stale revision does not resume'
    Assert-GCThat ((-not [bool]$rStale.resume_plan['hydrate_goal']) -and (-not [bool]$rStale.resume_plan['revalidate_decisions']) -and (-not [bool]$rStale.resume_plan['recompute_next_move'])) 'stale resume carries no active plan'
    [IO.File]::WriteAllText((Join-Path $goalDir 'ut.goal=1.json'), '{"goal_id":"UT.goal:1"}', [Text.UTF8Encoding]::new($false))
    $rNoRev = Test-OrchestrationCheckpointResume -Checkpoint $c -GoalStoreDir $goalDir
    Assert-GCThat ((-not [bool]$rNoRev.resumable) -and (@($rNoRev.reasons) -contains 'goal-unreadable')) 'live goal without revision never resumes'
    # --- base_revision matrix: both sides declare and diverge => stale.
    $gBase = New-GCTestGoal; $gBase['base_revision'] = 'base-1'
    $cBase = New-OrchestrationGoalCheckpoint -GoalRecord $gBase
    Assert-GCThat (($null -ne $cBase) -and ([string]$cBase['base_revision'] -ceq 'base-1')) 'checkpoint preserves declared base_revision'
    [IO.File]::WriteAllText((Join-Path $goalDir 'ut.goal=1.json'), '{"goal_id":"UT.goal:1","revision":3,"base_revision":"base-2"}', [Text.UTF8Encoding]::new($false))
    $rBase = Test-OrchestrationCheckpointResume -Checkpoint $cBase -GoalStoreDir $goalDir
    Assert-GCThat ((-not [bool]$rBase.resumable) -and (@($rBase.reasons) -contains 'stale-base-revision')) 'divergent base_revision on both sides does not resume'
    # --- base_revision matrix: only one side declares => no false negative.
    [IO.File]::WriteAllText((Join-Path $goalDir 'ut.goal=1.json'), '{"goal_id":"UT.goal:1","revision":3,"base_revision":"base-9"}', [Text.UTF8Encoding]::new($false))
    $rLiveOnly = Test-OrchestrationCheckpointResume -Checkpoint $c -GoalStoreDir $goalDir
    Assert-GCThat ([bool]$rLiveOnly.resumable) 'base_revision declared only live still resumes'
    [IO.File]::WriteAllText((Join-Path $goalDir 'ut.goal=1.json'), '{"goal_id":"UT.goal:1","revision":3}', [Text.UTF8Encoding]::new($false))
    $rCkptOnly = Test-OrchestrationCheckpointResume -Checkpoint $cBase -GoalStoreDir $goalDir
    Assert-GCThat ([bool]$rCkptOnly.resumable) 'base_revision declared only in checkpoint still resumes'
}
finally { try { Remove-Item -LiteralPath $goalDir -Recurse -Force -ErrorAction Stop } catch { } }
# --- Resume: goal absent => not resumable with a reason.
$emptyDir = New-GCTempDir
try {
    $r2 = Test-OrchestrationCheckpointResume -Checkpoint $c -GoalStoreDir $emptyDir
    Assert-GCThat ((-not [bool]$r2.resumable) -and (@($r2.reasons) -contains 'goal-not-found')) 'goal absent does not resume'
    Assert-GCThat ((-not [bool]$r2.resume_plan['hydrate_goal']) -and (-not [bool]$r2.resume_plan['revalidate_decisions']) -and (-not [bool]$r2.resume_plan['recompute_next_move'])) 'failed resume carries no active plan'
}
finally { try { Remove-Item -LiteralPath $emptyDir -Recurse -Force -ErrorAction Stop } catch { } }
# --- Resume: invalid checkpoint and unverifiable store (fail-closed).
$r3 = Test-OrchestrationCheckpointResume -Checkpoint 'junk' -GoalStoreDir $emptyDir
Assert-GCThat ((-not [bool]$r3.resumable) -and (@($r3.reasons) -contains 'invalid-checkpoint')) 'invalid checkpoint never resumes'
$r4 = Test-OrchestrationCheckpointResume -Checkpoint $c -GoalStoreDir ''
Assert-GCThat ((-not [bool]$r4.resumable) -and (@($r4.reasons) -contains 'goal-store-unverifiable')) 'unverifiable store never resumes'
Assert-GCThat ((-not [bool]$r4.resume_plan['hydrate_goal']) -and (-not [bool]$r4.resume_plan['revalidate_decisions']) -and (-not [bool]$r4.resume_plan['recompute_next_move'])) 'unverifiable resume carries no active plan'
$missingDir = Join-Path ([IO.Path]::GetTempPath()) ('gcp-missing-' + [IO.Path]::GetRandomFileName())
$r5 = Test-OrchestrationCheckpointResume -Checkpoint $c -GoalStoreDir $missingDir
Assert-GCThat ((-not [bool]$r5.resumable) -and (@($r5.reasons) -contains 'goal-store-unverifiable')) 'missing dir never resumes'
# --- Strict types: array revision and numeric id fail closed, scalars stay valid.
$gArrRev = New-GCTestGoal; $gArrRev['revision'] = @(3)
Assert-GCThat ($null -eq (New-OrchestrationGoalCheckpoint -GoalRecord $gArrRev)) 'array revision fails closed'
$gNumId = New-GCTestGoal; $gNumId['goal_id'] = 42
Assert-GCThat ($null -eq (New-OrchestrationGoalCheckpoint -GoalRecord $gNumId)) 'numeric goal id fails closed'
$cScalar = New-OrchestrationGoalCheckpoint -GoalRecord (New-GCTestGoal -GoalId 'UT.goal:9' -Revision 5)
Assert-GCThat (($null -ne $cScalar) -and ([string]$cScalar['goal_id'] -ceq 'UT.goal:9') -and ([long]$cScalar['goal_revision'] -eq 5)) 'legit scalars stay valid'
Write-Output "PASS OrchestrationGoalCheckpoint: $passed assertions"
