<#!
.SYNOPSIS
    Tests for lib/OrchestrationExecutionBudget.ps1 + kernel budget seam (Phase 23, FIX1).
.DESCRIPTION
    Hermetic: temp dirs under $env:TEMP, fixture flags files, cleanup in
    finally. Bracketed output the runner parses. Exit 0 on all pass,
    exit 1 on any fail or unexpected exception. PS 5.1. ASCII-only.
    Covers: policy exact defaults, role mapping, valid/invalid budgets
    (bool/string/negative/infinity/bounds/bad-profile/no_progress<=wall/
    soft<hard), worker widen denied, old-record compat (no write), stale
    writes byte-unchanged, attempt snapshots (explicit retained, derived
    resolves role; IMPLEMENTING only; planner/build only; idempotent same
    session; session-mismatch; retry-gate blocked), set-budget PARTIAL
    preserve + strict raw-type rejection (bool/string/fraction/negative),
    full-policy gate (bad fixture create/start no mutation), planner-turn
    event identity (closed charset, distinct, replay/duplicate rejected,
    free-text/canary rejected without logging, untrusted denied).
    Native renderer fields are HOLD (no renderer asserts). Phase 23 is
    shadow/record-only: enforcement always OFF.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$budgetPath = Join-Path $PSScriptRoot 'OrchestrationExecutionBudget.ps1'
. $budgetPath
$kernelPath = Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1'
. $kernelPath

$script:passed = 0
$script:failed = 0

function Assert-Budget {
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

function Write-BudgetFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function New-BudgetTestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('v3-exec-budget-' + [guid]::NewGuid().ToString('N'))
    $tasks = Join-Path $root 'tasks'
    $flags = Join-Path $root 'flags.json'
    New-Item -ItemType Directory -Path $tasks -Force | Out-Null
    Write-BudgetFixture -Path $flags -Text '{"task_kernel":{"enabled":true,"shadow":false}}'
    return @{ root = $root; tasks = $tasks; flags = $flags }
}

function Get-FileBytesHash {
    param([string]$Path)
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash)
}

function New-BudgetTask {
    param([string]$TasksDir, [string]$FlagsPath, [string]$Root, [string]$Id, [string]$Profile = '')
    $args = @{
        TaskId = $Id; Objective = 'Bounded fixture work'; Actor = 'planner'
        RuntimeId = 'opencode-v1'; RuntimeGeneration = 1; RuntimeProfile = 'v1'
        TasksDir = $TasksDir; FlagsPath = $FlagsPath; TelemetryRoot = $Root
    }
    if (-not [string]::IsNullOrWhiteSpace($Profile)) { $args['BudgetProfile'] = $Profile }
    return (New-OrchestrationTask @args)
}

function Move-BudgetTaskToImplementing {
    param([string]$Id, [string]$TasksDir, [string]$FlagsPath, [string]$Root, [int]$FromRev)
    $r1 = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision $FromRev -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Root
    if (-not [bool]$r1.ok) { return $r1 }
    return (Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision ([int]$r1.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $TasksDir -FlagsPath $FlagsPath -TelemetryRoot $Root)
}

$roots = New-Object System.Collections.ArrayList
$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
$repoPolicy = Join-Path $repo 'source\registry\execution-budget-policy.json'
$repoFlags = Join-Path $repo 'source\registry\capability-flags.json'

try {
    # 1. central policy file valid with exact defaults
    $pa = Assert-ExecutionBudgetPolicyJson -Path $repoPolicy
    Assert-Budget ([bool]$pa.valid) 'policy file passes schema assertion' ((@($pa.errors) -join ';'))
    $fb = Get-ExecutionBudgetProfileBudget -Profile 'fast' -PolicyPath $repoPolicy
    Assert-Budget (([bool]$fb.ok) -and ([int]$fb.budget['step_budget'] -eq 16) -and ([int]$fb.budget['wall_clock_seconds'] -eq 600) -and ([int]$fb.budget['no_progress_seconds'] -eq 180)) 'fast profile 16/600/180 exact'
    $sr = Get-ExecutionBudgetProfileBudget -Profile 'standard-read' -PolicyPath $repoPolicy
    Assert-Budget (([bool]$sr.ok) -and ([int]$sr.budget['step_budget'] -eq 24) -and ([int]$sr.budget['wall_clock_seconds'] -eq 900) -and ([int]$sr.budget['no_progress_seconds'] -eq 240)) 'standard-read 24/900/240 exact'
    $sw = Get-ExecutionBudgetProfileBudget -Profile 'standard-write' -PolicyPath $repoPolicy
    Assert-Budget (([bool]$sw.ok) -and ([int]$sw.budget['step_budget'] -eq 32) -and ([int]$sw.budget['wall_clock_seconds'] -eq 1200) -and ([int]$sw.budget['no_progress_seconds'] -eq 300)) 'standard-write 32/1200/300 exact'
    $dp = Get-ExecutionBudgetProfileBudget -Profile 'deep' -PolicyPath $repoPolicy
    Assert-Budget (([bool]$dp.ok) -and ([int]$dp.budget['step_budget'] -eq 40) -and ([int]$dp.budget['wall_clock_seconds'] -eq 1800) -and ([int]$dp.budget['no_progress_seconds'] -eq 360)) 'deep 40/1800/360 exact'
    $pt = Get-ExecutionBudgetProfileBudget -Profile 'planner-turn' -PolicyPath $repoPolicy
    Assert-Budget (([bool]$pt.ok) -and ([int]$pt.budget['step_budget'] -eq 64) -and ([int]$pt.budget['wall_clock_seconds'] -eq 3600) -and ([int]$pt.budget['no_progress_seconds'] -eq 480)) 'planner-turn 64/3600/480 exact'

    # 2. role mapping (central policy)
    $rc = Get-ExecutionBudgetForRole -Role 'coder' -PolicyPath $repoPolicy
    Assert-Budget (([bool]$rc.ok) -and ([string]$rc.profile -ceq 'standard-write')) 'role coder maps to standard-write'
    $re = Get-ExecutionBudgetForRole -Role 'explorer' -PolicyPath $repoPolicy
    Assert-Budget (([bool]$re.ok) -and ([string]$re.profile -ceq 'standard-read')) 'role explorer maps to standard-read'
    $rd = Get-ExecutionBudgetForRole -Role 'debugger' -PolicyPath $repoPolicy
    Assert-Budget (([bool]$rd.ok) -and ([string]$rd.profile -ceq 'deep')) 'role debugger maps to deep'
    $rb = Get-ExecutionBudgetForRole -Role 'build' -PolicyPath $repoPolicy
    Assert-Budget (([bool]$rb.ok) -and ([string]$rb.profile -ceq 'planner-turn')) 'role build maps to planner-turn'

    # 3. valid budget object passes; loop-guard exact
    $good = [ordered]@{
        profile = 'standard-write'; step_budget = 32; wall_clock_seconds = 1200; no_progress_seconds = 300
        repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
    $vg = Test-ExecutionBudgetObject -Budget $good
    Assert-Budget ([bool]$vg.valid) 'valid budget object passes'

    # 4. invalid shapes fail closed
    $badProf = Get-ExecutionBudgetProfileBudget -Profile 'ultra' -PolicyPath $repoPolicy
    Assert-Budget ((-not [bool]$badProf.ok) -and ([string]$badProf.error -ceq 'INVALID_PROFILE')) 'unknown profile rejected'
    $bBool = [ordered]@{
        profile = 'fast'; step_budget = $true; wall_clock_seconds = 600; no_progress_seconds = 180
        repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
    Assert-Budget (-not [bool](Test-ExecutionBudgetObject -Budget $bBool).valid) 'bool step_budget rejected'
    $bStr = [ordered]@{
        profile = 'fast'; step_budget = 16; wall_clock_seconds = '600'; no_progress_seconds = 180
        repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
    Assert-Budget (-not [bool](Test-ExecutionBudgetObject -Budget $bStr).valid) 'string wall_clock rejected'
    $bNeg = [ordered]@{
        profile = 'fast'; step_budget = -4; wall_clock_seconds = 600; no_progress_seconds = 180
        repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
    Assert-Budget (-not [bool](Test-ExecutionBudgetObject -Budget $bNeg).valid) 'negative step_budget rejected'
    $bInf = [ordered]@{
        profile = 'fast'; step_budget = 16; wall_clock_seconds = ([double]::PositiveInfinity); no_progress_seconds = 180
        repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
    Assert-Budget (-not [bool](Test-ExecutionBudgetObject -Budget $bInf).valid) 'infinity wall_clock rejected'
    $bNp = [ordered]@{
        profile = 'fast'; step_budget = 16; wall_clock_seconds = 600; no_progress_seconds = 900
        repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
    Assert-Budget (-not [bool](Test-ExecutionBudgetObject -Budget $bNp).valid) 'no_progress above wall rejected'
    $bSoft = [ordered]@{
        profile = 'fast'; step_budget = 16; wall_clock_seconds = 600; no_progress_seconds = 180
        repeated_action_soft_limit = 5; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
    Assert-Budget (-not [bool](Test-ExecutionBudgetObject -Budget $bSoft).valid) 'soft equal hard rejected'

    # 5. override bounds (worker 45m / planner 90m / steps 96)
    $bBigWall = [ordered]@{
        profile = 'standard-write'; step_budget = 32; wall_clock_seconds = 3000; no_progress_seconds = 300
        repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
    $ob1 = Test-ExecutionBudgetOverride -Budget $bBigWall -PolicyPath $repoPolicy -RepoRoot $repo
    Assert-Budget ((-not [bool]$ob1.valid) -and (@($ob1.errors) -contains 'wall_clock-exceeds-max')) 'worker wall above 2700 rejected'
    $bBigStep = [ordered]@{
        profile = 'standard-write'; step_budget = 500; wall_clock_seconds = 1200; no_progress_seconds = 300
        repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
    $ob2 = Test-ExecutionBudgetOverride -Budget $bBigStep -PolicyPath $repoPolicy -RepoRoot $repo
    Assert-Budget ((-not [bool]$ob2.valid) -and (@($ob2.errors) -contains 'step_budget-exceeds-max')) 'steps above 96 rejected'
    $bPlanOk = [ordered]@{
        profile = 'planner-turn'; step_budget = 64; wall_clock_seconds = 5400; no_progress_seconds = 480
        repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
    $ob3 = Test-ExecutionBudgetOverride -Budget $bPlanOk -IsPlannerTurn -PolicyPath $repoPolicy -RepoRoot $repo
    Assert-Budget ([bool]$ob3.valid) 'planner wall at 5400 allowed'
    $bPlanBig = [ordered]@{
        profile = 'planner-turn'; step_budget = 64; wall_clock_seconds = 5401; no_progress_seconds = 480
        repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
    $ob4 = Test-ExecutionBudgetOverride -Budget $bPlanBig -IsPlannerTurn -PolicyPath $repoPolicy -RepoRoot $repo
    Assert-Budget (-not [bool]$ob4.valid) 'planner wall above 5400 rejected'

    # 6. shadow flags: enabled false, shadow true
    $fl = Get-ExecutionBudgetFlagState -FlagsPath $repoFlags -RepoRoot $repo
    Assert-Budget ((([bool]$fl.enabled -eq $false) -and ([bool]$fl.shadow -eq $true))) 'bounded_execution enabled=false shadow=true'
    $en = Get-ExecutionBudgetEnforcementState -FlagsPath $repoFlags -RepoRoot $repo
    Assert-Budget (([bool]$en.enforce -eq $false)) 'enforcement stays OFF in phase23 shadow'

    # 7. kernel: new task persists canonical budget + source tracking
    $t = New-BudgetTestRoot
    [void]$roots.Add($t.root)
    $c = New-BudgetTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'budget-001' -Profile 'deep'
    Assert-Budget ([bool]$c.ok) 'create with deep profile ok'
    $g = Get-OrchestrationTask -TaskId 'budget-001' -TasksDir $t.tasks
    $bok = (([string]$g['execution_budget']['profile'] -ceq 'deep') -and ([int]$g['execution_budget']['step_budget'] -eq 40) -and ([int]$g['execution_budget']['wall_clock_seconds'] -eq 1800) -and ([int]$g['execution_budget']['no_progress_seconds'] -eq 360))
    Assert-Budget $bok 'created record carries canonical deep budget'
    Assert-Budget (([string]$g['execution_budget_source'] -ceq 'explicit')) 'explicit profile create marks source explicit'
    $cf = New-BudgetTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'budget-fresh-001'
    Assert-Budget ([bool]$cf.ok) 'create without profile ok (provisional default)'
    $gf = Get-OrchestrationTask -TaskId 'budget-fresh-001' -TasksDir $t.tasks
    Assert-Budget ((([string]$gf['execution_budget']['profile'] -ceq 'standard-write') -and ([string]$gf['execution_budget_source'] -ceq 'derived'))) 'default create is derived standard-write'
    $rok = (([string]$g['execution_runtime']['session_id'] -ceq '') -and ([int]$g['execution_runtime']['last_progress_revision'] -eq 0) -and ([string]$g['planner_turn']['turn_id'] -ceq ''))
    Assert-Budget $rok 'runtime/turn start empty on create'

    # 8. invalid profile at create fails closed with no file
    $ci = New-BudgetTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'budget-bad-001' -Profile 'ultra'
    $leftBad = Test-Path -LiteralPath (Join-Path $t.tasks 'budget-bad-001.json')
    Assert-Budget (((-not [bool]$ci.ok)) -and (-not $leftBad)) 'invalid profile create fails closed with no file'

    # 9. worker cannot widen via ProposedBudgetJson (bytes unchanged)
    $file9 = Join-Path $t.tasks 'budget-001.json'
    $before9 = Get-FileBytesHash -Path $file9
    $w9 = Set-OrchestrationTaskWorkerResult -TaskId 'budget-001' -Status 'failed' -ClaimedEvidence @('criterion:0:try') -ProducedBy 'coder' -ExpectedRevision 1 -ProposedBudgetJson '{"wall_clock_seconds":99999}' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    $after9 = Get-FileBytesHash -Path $file9
    Assert-Budget (((-not [bool]$w9.ok) -and ([string]$w9.error -ceq 'BUDGET_IMMUTABLE') -and ($before9 -ceq $after9))) 'worker budget proposal denied without write'

    # 10. old record compat: legacy file without budget derives read-only
    $legacyId = 'legacy-001'
    $legacyFile = Join-Path $t.tasks ($legacyId + '.json')
    $legacyRec = [ordered]@{
        schema_version = 1; task_id = $legacyId; parent_task_id = ''; trace_id = ''
        objective = 'Legacy work'; task_type = 'implementation'; risk = 'low'
        state = 'DISCOVERING'; revision = 1; orchestration_decision = ''; actor = 'planner'; current_owner = 'planner'
        runtime = [ordered]@{ id = 'opencode-v1'; generation = 1; profile = 'v1'; version = '' }
        base_revision = ''; read_scopes = @(); write_scopes = @(); grants = @()
        environment_authorization = [ordered]@{ allowed_environments = @(); production_authorized = $false }
        acceptance_criteria = @('done'); expected_artifacts = @(); attempt_budget = 3
        attempts = @(); worker_result = $null; verification = $null; review = $null; security_review = $null
        blockers = @(); residual_risks = @(); closure_reason = ''; compliance_verdict = ''; worktree = ''; history = @()
        created_at = '2026-09-30T00:00:00Z'; updated_at = '2026-09-30T00:00:00Z'
    }
    $legacyJson = ($legacyRec | ConvertTo-Json -Depth 12 -Compress)
    Write-BudgetFixture -Path $legacyFile -Text $legacyJson
    $before10 = Get-FileBytesHash -Path $legacyFile
    $gb = Get-OrchestrationTaskBudget -TaskId $legacyId -TasksDir $t.tasks -RepoRoot $repo
    $after10 = Get-FileBytesHash -Path $legacyFile
    Assert-Budget (([bool]$gb.ok -and [bool]$gb.derived -and ($before10 -ceq $after10))) 'legacy record derives defaults with zero byte change'

    # 11. start attempt: IMPLEMENTING only, planner/build only, explicit retained
    $file11 = Join-Path $t.tasks 'budget-001.json'
    $pre11 = Get-FileBytesHash -Path $file11
    $early = Start-OrchestrationTaskAttempt -TaskId 'budget-001' -AttemptRole 'coder' -SessionId 'sess-early' -Actor 'planner' -ExpectedRevision 1 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $post11 = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$early.ok) -and ([string]$early.error -ceq 'ILLEGAL_TRANSITION') -and ($pre11 -ceq $post11))) 'attempt from DISCOVERING rejected without write'
    $mv = Move-BudgetTaskToImplementing -Id 'budget-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -FromRev 1
    Assert-Budget ([bool]$mv.ok) 'transition budget-001 to IMPLEMENTING'
    $s11 = Start-OrchestrationTaskAttempt -TaskId 'budget-001' -AttemptRole 'coder' -SessionId 'sess-aaa' -Actor 'planner' -ExpectedRevision ([int]$mv.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget (([bool]$s11.ok) -and ([int]$s11.revision -eq ([int]$mv.revision + 1)) -and (-not [string]::IsNullOrWhiteSpace([string]$s11.deadline_at))) 'start attempt ok with deadline'
    $g11 = Get-OrchestrationTask -TaskId 'budget-001' -TasksDir $t.tasks
    $rt11 = $g11['execution_runtime']
    Assert-Budget ((([string]$rt11['session_id'] -ceq 'sess-aaa') -and ([int]$rt11['budget_snapshot']['step_budget'] -eq 40) -and ([int]$rt11['last_progress_revision'] -eq ([int]$s11.revision)))) 'attempt snapshot retains explicit deep budget'
    $revAfterStart = [int]$s11.revision
    $before11 = Get-FileBytesHash -Path $file11
    $stale = Start-OrchestrationTaskAttempt -TaskId 'budget-001' -AttemptRole 'coder' -SessionId 'sess-bbb' -Actor 'planner' -ExpectedRevision ([int]$mv.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $after11 = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$stale.ok) -and ([string]$stale.error -ceq 'CAS_CONFLICT') -and ($before11 -ceq $after11))) 'stale attempt start leaves bytes unchanged'
    $untrusted = Start-OrchestrationTaskAttempt -TaskId 'budget-001' -AttemptRole 'coder' -SessionId 'sess-ccc' -Actor 'planner' -ExpectedRevision $revAfterStart -ActorIdentitySource 'unknown' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $after11b = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$untrusted.ok) -and ([string]$untrusted.error -ceq 'UNTRUSTED_IDENTITY') -and ($after11 -ceq $after11b))) 'untrusted attempt start denied without write'
    $workerActor = Start-OrchestrationTaskAttempt -TaskId 'budget-001' -AttemptRole 'coder' -SessionId 'sess-ddd' -Actor 'coder' -ExpectedRevision $revAfterStart -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $after11c = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$workerActor.ok) -and ([string]$workerActor.error -ceq 'BUDGET_WIDEN_DENIED') -and ($after11b -ceq $after11c))) 'worker actor attempt start denied without write'
    $idem = Start-OrchestrationTaskAttempt -TaskId 'budget-001' -AttemptRole 'coder' -SessionId 'sess-aaa' -Actor 'planner' -ExpectedRevision $revAfterStart -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $afterIdem = Get-FileBytesHash -Path $file11
    Assert-Budget (([bool]$idem.ok -and [bool]$idem.idempotent -and ([string]$idem.deadline_at -ceq [string]$rt11['deadline_at']) -and ($after11c -ceq $afterIdem))) 'same session same attempt idempotent without deadline extension'
    $mismatch = Start-OrchestrationTaskAttempt -TaskId 'budget-001' -AttemptRole 'coder' -SessionId 'sess-other' -Actor 'planner' -ExpectedRevision $revAfterStart -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $afterMismatch = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$mismatch.ok) -and ([string]$mismatch.error -ceq 'SESSION_MISMATCH') -and ($afterIdem -ceq $afterMismatch))) 'different session same attempt rejected without write'

    # 12. set-budget: worker denied, planner valid ok, partial preserve, strict types, stale unchanged
    $w12 = Set-OrchestrationTaskBudget -TaskId 'budget-001' -BudgetWallSeconds 1500 -Actor 'coder' -ExpectedRevision $revAfterStart -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $after12 = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$w12.ok) -and ([string]$w12.error -ceq 'BUDGET_WIDEN_DENIED') -and ($afterMismatch -ceq $after12))) 'worker budget override denied without write'
    $p12 = Set-OrchestrationTaskBudget -TaskId 'budget-001' -BudgetWallSeconds 1500 -Actor 'planner' -ExpectedRevision $revAfterStart -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget (([bool]$p12.ok) -and ([int]$p12.revision -eq ($revAfterStart + 1))) 'planner override within bounds ok'
    $rev12 = [int]$p12.revision
    $g12 = Get-OrchestrationTask -TaskId 'budget-001' -TasksDir $t.tasks
    Assert-Budget ((([int]$g12['execution_budget']['wall_clock_seconds'] -eq 1500) -and ([int]$g12['execution_budget']['step_budget'] -eq 40))) 'override wall persisted with step preserved'
    $p12b = Set-OrchestrationTaskBudget -TaskId 'budget-001' -BudgetStepBudget 48 -Actor 'planner' -ExpectedRevision $rev12 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget ([bool]$p12b.ok) 'partial step-only update ok'
    $rev12b = [int]$p12b.revision
    $g12b = Get-OrchestrationTask -TaskId 'budget-001' -TasksDir $t.tasks
    Assert-Budget ((([int]$g12b['execution_budget']['step_budget'] -eq 48) -and ([int]$g12b['execution_budget']['wall_clock_seconds'] -eq 1500))) 'partial update preserves wall (no canonical reset)'
    foreach ($case in @(
        @{ name = 'bool step rejected'; args = @{ BudgetStepBudget = $true } },
        @{ name = 'string wall rejected'; args = @{ BudgetWallSeconds = '1500' } },
        @{ name = 'fraction no-progress rejected'; args = @{ BudgetNoProgressSeconds = 12.5 } },
        @{ name = 'negative step rejected'; args = @{ BudgetStepBudget = -4 } },
        @{ name = 'zero wall rejected'; args = @{ BudgetWallSeconds = 0 } }
    )) {
        $bh = Get-FileBytesHash -Path $file11
        $extra = $case.args
        $br = Set-OrchestrationTaskBudget -TaskId 'budget-001' -Actor 'planner' -ExpectedRevision $rev12b -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo @extra
        $ah = Get-FileBytesHash -Path $file11
        Assert-Budget (((-not [bool]$br.ok) -and ([string]$br.error -ceq 'INVALID_BUDGET') -and ($bh -ceq $ah))) ([string]$case.name)
    }
    $before12b = Get-FileBytesHash -Path $file11
    $bad12 = Set-OrchestrationTaskBudget -TaskId 'budget-001' -BudgetWallSeconds 99999 -Actor 'planner' -ExpectedRevision $rev12b -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $after12b = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$bad12.ok) -and ([string]$bad12.error -ceq 'INVALID_BUDGET') -and ($before12b -ceq $after12b))) 'override above bounds fails closed without write'
    $stale12 = Set-OrchestrationTaskBudget -TaskId 'budget-001' -BudgetWallSeconds 1400 -Actor 'planner' -ExpectedRevision $revAfterStart -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $after12c = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$stale12.ok) -and ([string]$stale12.error -ceq 'CAS_CONFLICT') -and ($after12b -ceq $after12c))) 'stale budget override leaves bytes unchanged'
    $revBudget = $rev12b

    # 13. derived default resolves role on start (fresh tasks)
    $f2 = New-BudgetTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'budget-fresh-002'
    Assert-Budget ([bool]$f2.ok) 'fresh task 002 created'
    $m2 = Move-BudgetTaskToImplementing -Id 'budget-fresh-002' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -FromRev 1
    Assert-Budget ([bool]$m2.ok) 'fresh task 002 implementing'
    $a2 = Start-OrchestrationTaskAttempt -TaskId 'budget-fresh-002' -AttemptRole 'explorer' -SessionId 'sess-exp' -Actor 'planner' -ExpectedRevision ([int]$m2.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget ([bool]$a2.ok) 'fresh explorer attempt ok'
    $g2 = Get-OrchestrationTask -TaskId 'budget-fresh-002' -TasksDir $t.tasks
    Assert-Budget ((([string]$g2['execution_runtime']['budget_snapshot']['profile'] -ceq 'standard-read') -and ([int]$g2['execution_runtime']['budget_snapshot']['step_budget'] -eq 24))) 'derived default resolves explorer to standard-read'
    $f3 = New-BudgetTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'budget-fresh-003'
    Assert-Budget ([bool]$f3.ok) 'fresh task 003 created'
    $m3 = Move-BudgetTaskToImplementing -Id 'budget-fresh-003' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -FromRev 1
    Assert-Budget ([bool]$m3.ok) 'fresh task 003 implementing'
    $a3 = Start-OrchestrationTaskAttempt -TaskId 'budget-fresh-003' -AttemptRole 'debugger' -SessionId 'sess-dbg' -Actor 'planner' -ExpectedRevision ([int]$m3.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget ([bool]$a3.ok) 'fresh debugger attempt ok'
    $g3 = Get-OrchestrationTask -TaskId 'budget-fresh-003' -TasksDir $t.tasks
    Assert-Budget ((([string]$g3['execution_runtime']['budget_snapshot']['profile'] -ceq 'deep') -and ([int]$g3['execution_runtime']['budget_snapshot']['step_budget'] -eq 40))) 'derived default resolves debugger to deep'

    # 14. full-policy gate: inconsistent fixture fails create/start with no mutation
    $badPolicyFile = Join-Path $t.root 'bad-policy.json'
    Write-BudgetFixture -Path $badPolicyFile -Text '{"version":1,"profiles":{"fast":{"step_budget":999,"wall_clock_seconds":600,"no_progress_seconds":180},"standard-read":{"step_budget":24,"wall_clock_seconds":900,"no_progress_seconds":240},"standard-write":{"step_budget":32,"wall_clock_seconds":1200,"no_progress_seconds":300},"deep":{"step_budget":40,"wall_clock_seconds":1800,"no_progress_seconds":360},"planner-turn":{"step_budget":64,"wall_clock_seconds":3600,"no_progress_seconds":480}},"loop_guard":{"repeated_action_soft_limit":3,"repeated_action_hard_limit":5,"cycle_repeat_limit":3,"provider_retry_limit":2},"default_profile":"standard-write","role_defaults":{"build":"planner-turn","explorer":"standard-read","coder":"standard-write","debugger":"deep"},"override_bounds":{"max_step_budget":96,"max_wall_clock_seconds_worker":"2700","max_wall_clock_seconds_planner":5400,"max_no_progress_seconds":960},"planner_turn":{"budget_profile":"planner-turn","new_input_signal_required":true,"session_lifetime_unbounded":true,"shadow_record_only":true}}'
    $badCreate = New-OrchestrationTask -TaskId 'budget-badpol-001' -Objective 'Bounded fixture work' -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' -TasksDir $t.tasks -FlagsPath $t.flags -BudgetPolicyPath $badPolicyFile
    $leftBadPol = Test-Path -LiteralPath (Join-Path $t.tasks 'budget-badpol-001.json')
    Assert-Budget (((-not [bool]$badCreate.ok) -and (-not $leftBadPol))) 'inconsistent policy create fails closed with no file'
    $preBadStart = Get-FileBytesHash -Path $file11
    $badStart = Start-OrchestrationTaskAttempt -TaskId 'budget-001' -AttemptRole 'coder' -SessionId 'sess-aaa' -Actor 'planner' -ExpectedRevision $revBudget -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo -BudgetPolicyPath $badPolicyFile
    $postBadStart = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$badStart.ok) -and ([string]$badStart.error -ceq 'BUDGET_POLICY_INVALID') -and ($preBadStart -ceq $postBadStart))) 'inconsistent policy start fails closed without write'

    # 15. planner turn: event identity, task-bound monotonic sequence, replay protection, no secret logging
    $before13 = Get-FileBytesHash -Path $file11
    $nosig = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-001' -Actor 'planner' -ExpectedRevision $revBudget -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $after13 = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$nosig.ok) -and ([string]$nosig.error -ceq 'PLANNER_TURN_SIGNAL_REQUIRED') -and ($before13 -ceq $after13))) 'planner turn without signal rejected without write'
    $noseq = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-001' -UserInputSignal 'evt-001' -Actor 'planner' -ExpectedRevision $revBudget -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $afterNoseq = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$noseq.ok) -and ([string]$noseq.error -ceq 'PLANNER_TURN_SEQUENCE_REQUIRED') -and ($after13 -ceq $afterNoseq))) 'planner turn without sequence rejected without write'
    $free = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-001' -UserInputSignal 'user asked to continue' -UserInputSequence 1 -Actor 'planner' -ExpectedRevision $revBudget -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $afterFree = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$free.ok) -and ([string]$free.error -ceq 'INVALID_SIGNAL') -and ($afterNoseq -ceq $afterFree))) 'free-text signal rejected without write'
    $canarySig = 'sk-SYNTHETICSECRET-001'
    $can = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-001' -UserInputSignal $canarySig -UserInputSequence 1 -Actor 'planner' -ExpectedRevision $revBudget -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $canJson = ($can | ConvertTo-Json -Depth 6 -Compress)
    $afterCan = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$can.ok) -and ($canJson -cnotmatch 'SYNTHETICSECRET') -and ($afterFree -ceq $afterCan))) 'sensitive canary rejected without logging'
    foreach ($scase in @(
        @{ name = 'string sequence rejected'; seq = '2' },
        @{ name = 'bool sequence rejected'; seq = $true },
        @{ name = 'fraction sequence rejected'; seq = 2.5 },
        @{ name = 'zero sequence rejected'; seq = 0 },
        @{ name = 'negative sequence rejected'; seq = -3 }
    )) {
        $sh = Get-FileBytesHash -Path $file11
        $sq = $scase.seq
        $sr = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-001' -UserInputSignal 'evt-001' -UserInputSequence $sq -Actor 'planner' -ExpectedRevision $revBudget -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
        $ah2 = Get-FileBytesHash -Path $file11
        Assert-Budget (((-not [bool]$sr.ok) -and (([string]$sr.error -ceq 'INVALID_SEQUENCE') -or ([string]$sr.error -ceq 'PLANNER_TURN_SEQUENCE_REQUIRED')) -and ($sh -ceq $ah2))) ([string]$scase.name)
    }
    $t1 = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-001' -UserInputSignal 'evt-001' -UserInputSequence 1 -Actor 'planner' -ExpectedRevision $revBudget -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget (([bool]$t1.ok) -and ([int]$t1.revision -eq ($revBudget + 1)) -and ([long]$t1.seq -eq 1)) 'planner turn with new event id ok'
    $revT1 = [int]$t1.revision
    $g13 = Get-OrchestrationTask -TaskId 'budget-001' -TasksDir $t.tasks
    Assert-Budget ((([string]$g13['planner_turn']['turn_id'] -ceq 'turn-001') -and ([string]$g13['planner_turn']['budget_snapshot']['profile'] -ceq 'planner-turn') -and ([long]$g13['planner_turn_seq'] -eq 1))) 'planner turn snapshot uses planner-turn profile with seq high-water 1'
    $before13b = Get-FileBytesHash -Path $file11
    $sameEvtNewTurn = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-002' -UserInputSignal 'evt-001' -UserInputSequence 2 -Actor 'planner' -ExpectedRevision $revT1 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $after13b = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$sameEvtNewTurn.ok) -and ([string]$sameEvtNewTurn.error -ceq 'PLANNER_TURN_SIGNAL_REPLAY') -and ($before13b -ceq $after13b))) 'same event new turn rejected without write'
    $sameTurnNewEvt = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-001' -UserInputSignal 'evt-002' -UserInputSequence 2 -Actor 'planner' -ExpectedRevision $revT1 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $after13c = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$sameTurnNewEvt.ok) -and ([string]$sameTurnNewEvt.error -ceq 'PLANNER_TURN_DUPLICATE') -and ($after13b -ceq $after13c))) 'same turn new event rejected without write'
    $t2 = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-002' -UserInputSignal 'evt-002' -UserInputSequence 2 -Actor 'planner' -ExpectedRevision $revT1 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget ([bool]$t2.ok) 'new event starts new turn id'
    $revT2 = [int]$t2.revision
    $beforeReplay = Get-FileBytesHash -Path $file11
    $replayOld = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-003' -UserInputSignal 'evt-001' -UserInputSequence 3 -Actor 'planner' -ExpectedRevision $revT2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $afterReplay = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$replayOld.ok) -and ([string]$replayOld.error -ceq 'PLANNER_TURN_SIGNAL_REPLAY') -and ($beforeReplay -ceq $afterReplay))) 'replay of earlier event rejected without write'
    $replaySeq = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-003' -UserInputSignal 'evt-003' -UserInputSequence 2 -Actor 'planner' -ExpectedRevision $revT2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $afterReplaySeq = Get-FileBytesHash -Path $file11
    Assert-Budget (((-not [bool]$replaySeq.ok) -and ([string]$replaySeq.error -ceq 'PLANNER_TURN_SEQUENCE_REPLAY') -and ($afterReplay -ceq $afterReplaySeq))) 'replayed sequence with fresh ids rejected without write'
    $wturn = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-009' -UserInputSignal 'evt-009' -UserInputSequence 3 -Actor 'coder' -ExpectedRevision $revT2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget (((-not [bool]$wturn.ok) -and ([string]$wturn.error -ceq 'BUDGET_WIDEN_DENIED'))) 'untrusted worker planner-turn denied'
    $uturn = Start-OrchestrationPlannerTurn -TaskId 'budget-001' -TurnId 'turn-009' -UserInputSignal 'evt-009' -UserInputSequence 3 -Actor 'planner' -ExpectedRevision $revT2 -ActorIdentitySource 'unknown' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget (((-not [bool]$uturn.ok) -and ([string]$uturn.error -ceq 'UNTRUSTED_IDENTITY'))) 'untrusted source planner-turn denied'

    # 16. retry gate: two failures block a bypassing new attempt
    $rg = New-BudgetTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'budget-gate-001' -Profile 'deep'
    Assert-Budget ([bool]$rg.ok) 'gate task created'
    $mg = Move-BudgetTaskToImplementing -Id 'budget-gate-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -FromRev 1
    Assert-Budget ([bool]$mg.ok) 'gate task implementing'
    $ag = Start-OrchestrationTaskAttempt -TaskId 'budget-gate-001' -AttemptRole 'coder' -SessionId 'sess-g1' -Actor 'planner' -ExpectedRevision ([int]$mg.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget ([bool]$ag.ok) 'gate attempt started'
    $rga = Set-OrchestrationTaskWorkerResult -TaskId 'budget-gate-001' -Status 'failed' -ClaimedEvidence @('criterion:0:a') -ProducedBy 'coder' -ExpectedRevision ([int]$ag.revision) -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-Budget ([bool]$rga.ok) 'gate first failure recorded'
    $rgb = Set-OrchestrationTaskWorkerResult -TaskId 'budget-gate-001' -Status 'failed' -ClaimedEvidence @('criterion:0:b') -ProducedBy 'coder' -ExpectedRevision ([int]$rga.revision) -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-Budget ([bool]$rgb.ok) 'gate second failure recorded'
    $gateFile = Join-Path $t.tasks 'budget-gate-001.json'
    $preGate = Get-FileBytesHash -Path $gateFile
    $gateTry = Start-OrchestrationTaskAttempt -TaskId 'budget-gate-001' -AttemptRole 'coder' -SessionId 'sess-g2' -Actor 'planner' -ExpectedRevision ([int]$rgb.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $postGate = Get-FileBytesHash -Path $gateFile
    Assert-Budget (((-not [bool]$gateTry.ok) -and ([string]$gateTry.error -ceq 'ATTEMPT_GATE_FAILED') -and ($preGate -ceq $postGate))) 'retry-gated new attempt rejected without write'

    # 16b. first failure leaves attempt2 open; planner refs unlock the gated third attempt
    $rg2 = New-BudgetTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'budget-gate2-001' -Profile 'deep'
    Assert-Budget ([bool]$rg2.ok) 'second gate task created'
    $mg2 = Move-BudgetTaskToImplementing -Id 'budget-gate2-001' -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -FromRev 1
    Assert-Budget ([bool]$mg2.ok) 'second gate task implementing'
    $ag2 = Start-OrchestrationTaskAttempt -TaskId 'budget-gate2-001' -AttemptRole 'coder' -SessionId 'sess-h1' -Actor 'planner' -ExpectedRevision ([int]$mg2.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget ([bool]$ag2.ok) 'second gate first attempt started'
    $rh1 = Set-OrchestrationTaskWorkerResult -TaskId 'budget-gate2-001' -Status 'failed' -ClaimedEvidence @('criterion:0:h') -ProducedBy 'coder' -ExpectedRevision ([int]$ag2.revision) -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root
    Assert-Budget ([bool]$rh1.ok) 'second gate first failure recorded'
    $ag2b = Start-OrchestrationTaskAttempt -TaskId 'budget-gate2-001' -AttemptRole 'coder' -SessionId 'sess-h2' -Actor 'planner' -ExpectedRevision ([int]$rh1.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget (([bool]$ag2b.ok) -and ([int]$ag2b.revision -eq ([int]$rh1.revision + 1))) 'first failure still allows attempt2 start'
    $preEmpty = Get-FileBytesHash -Path $gateFile
    $emptyRefs = Start-OrchestrationTaskAttempt -TaskId 'budget-gate-001' -AttemptRole 'coder' -SessionId 'sess-g9' -Actor 'planner' -ExpectedRevision ([int]$rgb.revision) -ActorIdentitySource 'explicit-cli' -DebuggerEvidenceRefs @() -NewEvidenceRefs @('criterion:0:n') -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $postEmpty = Get-FileBytesHash -Path $gateFile
    Assert-Budget (((-not [bool]$emptyRefs.ok) -and ([string]$emptyRefs.error -ceq 'ATTEMPT_GATE_FAILED') -and ($preEmpty -ceq $postEmpty))) 'empty debugger refs rejected without write'
    $partialRefs = Start-OrchestrationTaskAttempt -TaskId 'budget-gate-001' -AttemptRole 'coder' -SessionId 'sess-g9' -Actor 'planner' -ExpectedRevision ([int]$rgb.revision) -ActorIdentitySource 'explicit-cli' -DebuggerEvidenceRefs @('criterion:0:d') -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $postPartial = Get-FileBytesHash -Path $gateFile
    Assert-Budget (((-not [bool]$partialRefs.ok) -and ([string]$partialRefs.error -ceq 'ATTEMPT_GATE_FAILED') -and ($postEmpty -ceq $postPartial))) 'debugger refs without novelty refs rejected without write'
    $fullRefs = Start-OrchestrationTaskAttempt -TaskId 'budget-gate-001' -AttemptRole 'coder' -SessionId 'sess-g3' -Actor 'planner' -ExpectedRevision ([int]$rgb.revision) -ActorIdentitySource 'explicit-cli' -DebuggerEvidenceRefs @('criterion:0:d') -NewEvidenceRefs @('criterion:0:n') -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget (([bool]$fullRefs.ok) -and ([int]$fullRefs.revision -eq ([int]$rgb.revision + 1))) 'planner debugger+novelty refs unlock attempt3 start'
    $gg = Get-OrchestrationTask -TaskId 'budget-gate-001' -TasksDir $t.tasks
    $ge = $gg['execution_runtime']['gate_evidence']
    Assert-Budget ((([int]$gg['execution_runtime']['attempt_n'] -eq 3) -and (@($ge['debugger_refs']) -contains 'criterion:0:d') -and (@($ge['new_evidence_refs']) -contains 'criterion:0:n'))) 'gate evidence bound to attempt3 snapshot'

    # 17. sequence high-water closes the bounded-retention replay gap (21+ turns)
    $fs = New-BudgetTask -TasksDir $t.tasks -FlagsPath $t.flags -Root $t.root -Id 'budget-seq-001'
    Assert-Budget ([bool]$fs.ok) 'sequence task created'
    $seqFile = Join-Path $t.tasks 'budget-seq-001.json'
    $revS = 1
    $seqOk = $true
    for ($i = 1; $i -le 22; $i++) {
        $tidN = ('st-{0:D3}' -f $i)
        $evN = ('ev-{0:D3}' -f $i)
        $tr = Start-OrchestrationPlannerTurn -TaskId 'budget-seq-001' -TurnId $tidN -UserInputSignal $evN -UserInputSequence $i -Actor 'planner' -ExpectedRevision $revS -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
        if (-not [bool]$tr.ok) { $seqOk = $false; break }
        $revS = [int]$tr.revision
    }
    Assert-Budget $seqOk '22 sequential turns accepted'
    $gs = Get-OrchestrationTask -TaskId 'budget-seq-001' -TasksDir $t.tasks
    $histCount = 0
    try { $histCount = (@($gs['planner_turn_history'])).Count } catch { $histCount = -1 }
    Assert-Budget (([long]$gs['planner_turn_seq'] -eq 22) -and ($histCount -eq 20)) 'high-water 22 retained with history capped at 20'
    $preSeqReplay = Get-FileBytesHash -Path $seqFile
    $seqReplay = Start-OrchestrationPlannerTurn -TaskId 'budget-seq-001' -TurnId 'st-999' -UserInputSignal 'ev-999' -UserInputSequence 5 -Actor 'planner' -ExpectedRevision $revS -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $postSeqReplay = Get-FileBytesHash -Path $seqFile
    Assert-Budget (((-not [bool]$seqReplay.ok) -and ([string]$seqReplay.error -ceq 'PLANNER_TURN_SEQUENCE_REPLAY') -and ($preSeqReplay -ceq $postSeqReplay))) 'evicted-history old sequence replay rejected without write'
    $seqEq = Start-OrchestrationPlannerTurn -TaskId 'budget-seq-001' -TurnId 'st-998' -UserInputSignal 'ev-998' -UserInputSequence 22 -Actor 'planner' -ExpectedRevision $revS -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    $postSeqEq = Get-FileBytesHash -Path $seqFile
    Assert-Budget (((-not [bool]$seqEq.ok) -and ([string]$seqEq.error -ceq 'PLANNER_TURN_SEQUENCE_REPLAY') -and ($postSeqReplay -ceq $postSeqEq))) 'equal-to-high-water sequence rejected without write'

    # 18. legacy stored budget without source is retained (conservative, no role widen)
    $oldFastId = 'budget-oldfast-001'
    $oldFastFile = Join-Path $t.tasks ($oldFastId + '.json')
    $oldFastRec = [ordered]@{
        schema_version = 1; task_id = $oldFastId; parent_task_id = ''; trace_id = ''
        objective = 'Old fast work'; task_type = 'implementation'; risk = 'low'
        state = 'IMPLEMENTING'; revision = 1; orchestration_decision = ''; actor = 'planner'; current_owner = 'planner'
        runtime = [ordered]@{ id = 'opencode-v1'; generation = 1; profile = 'v1'; version = '' }
        base_revision = ''; read_scopes = @(); write_scopes = @(); grants = @()
        environment_authorization = [ordered]@{ allowed_environments = @(); production_authorized = $false }
        acceptance_criteria = @('done'); expected_artifacts = @(); attempt_budget = 3
        execution_budget = [ordered]@{
            profile = 'fast'; step_budget = 16; wall_clock_seconds = 600; no_progress_seconds = 180
            repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
        }
        attempts = @(); worker_result = $null; verification = $null; review = $null; security_review = $null
        blockers = @(); residual_risks = @(); closure_reason = ''; compliance_verdict = ''; worktree = ''; history = @()
        created_at = '2026-09-30T00:00:00Z'; updated_at = '2026-09-30T00:00:00Z'
    }
    Write-BudgetFixture -Path $oldFastFile -Text ($oldFastRec | ConvertTo-Json -Depth 12 -Compress)
    $ao = Start-OrchestrationTaskAttempt -TaskId $oldFastId -AttemptRole 'coder' -SessionId 'sess-old' -Actor 'planner' -ExpectedRevision 1 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags -TelemetryRoot $t.root -RepoRoot $repo
    Assert-Budget ([bool]$ao.ok) 'old no-source record attempt starts'
    $go = Get-OrchestrationTask -TaskId $oldFastId -TasksDir $t.tasks
    Assert-Budget ((([string]$go['execution_runtime']['budget_snapshot']['profile'] -ceq 'fast') -and ([int]$go['execution_runtime']['budget_snapshot']['step_budget'] -eq 16))) 'stored fast budget retained for coder (no widen to standard-write)'

    # 19. CLI typed rejection: doubles refused before stringification (spawned helper, no shell injection)
    $cliPath = Join-Path $v3 'task-kernel.ps1'
    $helperPath = Join-Path $t.root 'cli-typed-helper.ps1'
    $helperCode = '[CmdletBinding()]param([string]$Cli,[string]$Tasks,[string]$Flags,[string]$Mode)
$ErrorActionPreference = ''Stop''
function Get-CliResult {
    param($Raw)
    if ($null -eq $Raw) { return $null }
    try { return ((($Raw -join "`n") | ConvertFrom-Json)) } catch { return $null }
}
if ($Mode -ceq ''setbudget-double'') {
    $c = Get-CliResult (& $Cli -Action create -TaskId ''cli-dbl-a'' -Objective ''typed smoke'' -Actor ''planner'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $c) -or (-not [bool]$c.ok)) { exit 3 }
    $d = [double]40
    $r = & $Cli -Action set-budget -TaskId ''cli-dbl-a'' -Actor ''planner'' -ExpectedRevision 1 -BudgetWallSeconds $d -ActorIdentitySource ''explicit-cli'' -TasksDir $Tasks -FlagsPath $Flags
    if ($null -eq $r) { exit 2 }
    $rj = Get-CliResult $r
    if (($null -ne $rj) -and [bool]$rj.ok) { exit 10 }
    exit 1
}
elseif ($Mode -ceq ''plannerturn-double'') {
    $c = Get-CliResult (& $Cli -Action create -TaskId ''cli-dbl-b'' -Objective ''typed smoke'' -Actor ''planner'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $c) -or (-not [bool]$c.ok)) { exit 3 }
    $d = [double]2
    $r = & $Cli -Action planner-turn -TaskId ''cli-dbl-b'' -PlannerTurnId ''tt-001'' -UserInputSignal ''ev-001'' -UserInputSequence $d -Actor ''planner'' -ExpectedRevision 1 -ActorIdentitySource ''explicit-cli'' -TasksDir $Tasks -FlagsPath $Flags
    if ($null -eq $r) { exit 2 }
    $rj = Get-CliResult $r
    if (($null -ne $rj) -and [bool]$rj.ok) { exit 10 }
    exit 1
}
elseif ($Mode -ceq ''setbudget-int'') {
    $c = Get-CliResult (& $Cli -Action create -TaskId ''cli-int-a'' -Objective ''typed smoke'' -Actor ''planner'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $c) -or (-not [bool]$c.ok)) { exit 3 }
    $n = [int]1500
    $r = Get-CliResult (& $Cli -Action set-budget -TaskId ''cli-int-a'' -Actor ''planner'' -ExpectedRevision 1 -BudgetWallSeconds $n -ActorIdentitySource ''explicit-cli'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -ne $r) -and [bool]$r.ok) { exit 0 }
    exit 1
}
elseif ($Mode -ceq ''startattempt-blocked'') {
    $c = Get-CliResult (& $Cli -Action create -TaskId ''cli-gate-a'' -Objective ''typed smoke'' -Actor ''planner'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $c) -or (-not [bool]$c.ok)) { exit 3 }
    $p = Get-CliResult (& $Cli -Action transition -TaskId ''cli-gate-a'' -ToState ''PLANNING'' -Actor ''planner'' -ExpectedRevision 1 -ActorIdentitySource ''explicit-cli'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $p) -or (-not [bool]$p.ok)) { exit 3 }
    $q = Get-CliResult (& $Cli -Action transition -TaskId ''cli-gate-a'' -ToState ''IMPLEMENTING'' -Actor ''planner'' -ExpectedRevision 2 -ActorIdentitySource ''explicit-cli'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $q) -or (-not [bool]$q.ok)) { exit 3 }
    $s = Get-CliResult (& $Cli -Action start-attempt -TaskId ''cli-gate-a'' -AttemptRole ''coder'' -SessionId ''sess-g1'' -Actor ''planner'' -ExpectedRevision 3 -ActorIdentitySource ''explicit-cli'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $s) -or (-not [bool]$s.ok)) { exit 3 }
    $f1 = Get-CliResult (& $Cli -Action record-result -TaskId ''cli-gate-a'' -WorkerStatus ''failed'' -ClaimedEvidence @(''criterion:0:a'') -ProducedBy ''coder'' -ExpectedRevision 4 -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $f1) -or (-not [bool]$f1.ok)) { exit 3 }
    $f2 = Get-CliResult (& $Cli -Action record-result -TaskId ''cli-gate-a'' -WorkerStatus ''failed'' -ClaimedEvidence @(''criterion:0:b'') -ProducedBy ''coder'' -ExpectedRevision 5 -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $f2) -or (-not [bool]$f2.ok)) { exit 3 }
    $fp = Join-Path $Tasks ''cli-gate-a.json''
    $h1 = (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash
    $r = & $Cli -Action start-attempt -TaskId ''cli-gate-a'' -AttemptRole ''coder'' -SessionId ''sess-gx'' -Actor ''planner'' -ExpectedRevision 6 -ActorIdentitySource ''explicit-cli'' -TasksDir $Tasks -FlagsPath $Flags
    $h2 = (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash
    if ($h1 -cne $h2) { exit 4 }
    $rj = Get-CliResult $r
    if (($null -ne $rj) -and ([string]$rj.error -ceq ''ATTEMPT_GATE_FAILED'')) { exit 1 }
    exit 10
}
elseif ($Mode -ceq ''startattempt-refs'') {
    $c = Get-CliResult (& $Cli -Action create -TaskId ''cli-gate-b'' -Objective ''typed smoke'' -Actor ''planner'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $c) -or (-not [bool]$c.ok)) { exit 3 }
    $p = Get-CliResult (& $Cli -Action transition -TaskId ''cli-gate-b'' -ToState ''PLANNING'' -Actor ''planner'' -ExpectedRevision 1 -ActorIdentitySource ''explicit-cli'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $p) -or (-not [bool]$p.ok)) { exit 3 }
    $q = Get-CliResult (& $Cli -Action transition -TaskId ''cli-gate-b'' -ToState ''IMPLEMENTING'' -Actor ''planner'' -ExpectedRevision 2 -ActorIdentitySource ''explicit-cli'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $q) -or (-not [bool]$q.ok)) { exit 3 }
    $s = Get-CliResult (& $Cli -Action start-attempt -TaskId ''cli-gate-b'' -AttemptRole ''coder'' -SessionId ''sess-g1'' -Actor ''planner'' -ExpectedRevision 3 -ActorIdentitySource ''explicit-cli'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $s) -or (-not [bool]$s.ok)) { exit 3 }
    $f1 = Get-CliResult (& $Cli -Action record-result -TaskId ''cli-gate-b'' -WorkerStatus ''failed'' -ClaimedEvidence @(''criterion:0:a'') -ProducedBy ''coder'' -ExpectedRevision 4 -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $f1) -or (-not [bool]$f1.ok)) { exit 3 }
    $f2 = Get-CliResult (& $Cli -Action record-result -TaskId ''cli-gate-b'' -WorkerStatus ''failed'' -ClaimedEvidence @(''criterion:0:b'') -ProducedBy ''coder'' -ExpectedRevision 5 -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $f2) -or (-not [bool]$f2.ok)) { exit 3 }
    $r = Get-CliResult (& $Cli -Action start-attempt -TaskId ''cli-gate-b'' -AttemptRole ''coder'' -SessionId ''sess-g3'' -Actor ''planner'' -ExpectedRevision 6 -ActorIdentitySource ''explicit-cli'' -DebuggerEvidenceRefs @(''criterion:0:d'') -NewEvidenceRefs @(''criterion:0:n'') -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -ne $r) -and [bool]$r.ok) { exit 0 }
    exit 1
}
elseif ($Mode -ceq ''startattempt-blankref'') {
    $c = Get-CliResult (& $Cli -Action create -TaskId ''cli-gate-c'' -Objective ''typed smoke'' -Actor ''planner'' -TasksDir $Tasks -FlagsPath $Flags)
    if (($null -eq $c) -or (-not [bool]$c.ok)) { exit 3 }
    $r = & $Cli -Action start-attempt -TaskId ''cli-gate-c'' -AttemptRole ''coder'' -SessionId ''sess-x'' -Actor ''planner'' -ExpectedRevision 1 -ActorIdentitySource ''explicit-cli'' -DebuggerEvidenceRefs @(''criterion:0:x'', '''') -TasksDir $Tasks -FlagsPath $Flags
    if ($null -eq $r) { exit 2 }
    exit 10
}
exit 3'
    Write-BudgetFixture -Path $helperPath -Text $helperCode
    $exeSelf = 'powershell'
    try { $exeSelf = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    & $exeSelf -NoProfile -File $helperPath $cliPath $t.tasks $t.flags 'setbudget-double'
    Assert-Budget ($LASTEXITCODE -eq 2) 'cli set-budget double 40 rejected with exit 2'
    & $exeSelf -NoProfile -File $helperPath $cliPath $t.tasks $t.flags 'plannerturn-double'
    Assert-Budget ($LASTEXITCODE -eq 2) 'cli planner-turn double sequence 2 rejected with exit 2'
    & $exeSelf -NoProfile -File $helperPath $cliPath $t.tasks $t.flags 'setbudget-int'
    Assert-Budget ($LASTEXITCODE -eq 0) 'cli set-budget int 1500 still accepted'
    & $exeSelf -NoProfile -File $helperPath $cliPath $t.tasks $t.flags 'startattempt-blocked'
    Assert-Budget ($LASTEXITCODE -eq 1) 'cli gated start without refs fails GATE_FAILED exit 1 without mutation'
    & $exeSelf -NoProfile -File $helperPath $cliPath $t.tasks $t.flags 'startattempt-refs'
    Assert-Budget ($LASTEXITCODE -eq 0) 'cli gated start with full refs allows attempt3 exit 0'
    & $exeSelf -NoProfile -File $helperPath $cliPath $t.tasks $t.flags 'startattempt-blankref'
    Assert-Budget ($LASTEXITCODE -eq 2) 'cli start-attempt blank ref rejected with exit 2'

    # 20. converter boundaries via real CLI: 7-digit and int32-max accepted, overflow/Max rejected
    & $exeSelf -NoProfile -File $cliPath -Action create -TaskId 'cli-big-a' -Objective 'typed smoke' -Actor 'planner' -TasksDir $t.tasks -FlagsPath $t.flags | Out-Null
    Assert-Budget ($LASTEXITCODE -eq 0) 'cli create cli-big-a ok'
    & $exeSelf -NoProfile -File $cliPath -Action planner-turn -TaskId 'cli-big-a' -PlannerTurnId 'tt-001' -UserInputSignal 'ev-001' -UserInputSequence '1000000' -Actor 'planner' -ExpectedRevision 1 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags | Out-Null
    Assert-Budget ($LASTEXITCODE -eq 0) 'cli planner-turn sequence 1000000 accepted'
    & $exeSelf -NoProfile -File $cliPath -Action create -TaskId 'cli-big-b' -Objective 'typed smoke' -Actor 'planner' -TasksDir $t.tasks -FlagsPath $t.flags | Out-Null
    Assert-Budget ($LASTEXITCODE -eq 0) 'cli create cli-big-b ok'
    & $exeSelf -NoProfile -File $cliPath -Action planner-turn -TaskId 'cli-big-b' -PlannerTurnId 'tt-001' -UserInputSignal 'ev-001' -UserInputSequence '2147483647' -Actor 'planner' -ExpectedRevision 1 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags | Out-Null
    Assert-Budget ($LASTEXITCODE -eq 0) 'cli planner-turn sequence 2147483647 accepted'
    & $exeSelf -NoProfile -File $cliPath -Action planner-turn -TaskId 'cli-big-a' -PlannerTurnId 'tt-002' -UserInputSignal 'ev-002' -UserInputSequence '2147483648' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags | Out-Null
    Assert-Budget ($LASTEXITCODE -eq 2) 'cli planner-turn sequence 2147483648 rejected with exit 2'
    & $exeSelf -NoProfile -File $cliPath -Action planner-turn -TaskId 'cli-big-a' -PlannerTurnId 'tt-003' -UserInputSignal 'ev-003' -UserInputSequence '99999999999' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags | Out-Null
    Assert-Budget ($LASTEXITCODE -eq 2) 'cli planner-turn 11-digit sequence rejected with exit 2'
    & $exeSelf -NoProfile -File $cliPath -Action set-budget -TaskId 'cli-big-a' -Actor 'planner' -ExpectedRevision 2 -BudgetWallSeconds '1000000' -ActorIdentitySource 'explicit-cli' -TasksDir $t.tasks -FlagsPath $t.flags | Out-Null
    Assert-Budget ($LASTEXITCODE -eq 2) 'cli set-budget wall 1000000 rejected by Max with exit 2'
}
catch {
    Write-Host ("[FAIL] unexpected error: {0}" -f $_)
    $script:failed++
}
finally {
    foreach ($rd in $roots) {
        if (Test-Path -LiteralPath $rd) { Remove-Item -LiteralPath $rd -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ("ExecutionBudget: {0} / {1} tests passed" -f $script:passed, ($script:passed + $script:failed))
if ($script:failed -gt 0) { exit 1 }
exit 0
